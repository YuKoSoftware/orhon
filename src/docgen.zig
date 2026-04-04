// docgen.zig — Documentation generator
// Walks parsed ASTs and emits Markdown documentation for pub declarations.

const std = @import("std");
const parser = @import("parser.zig");
const module = @import("module.zig");

const Node = parser.Node;

/// Generate Markdown documentation for all modules in the resolver.
/// Creates one .md file per module plus an index.md in output_dir.
pub fn generateDocs(
    allocator: std.mem.Allocator,
    mod_resolver: *module.Resolver,
    output_dir: []const u8,
) !void {
    // Create output directory (and parents)
    std.fs.cwd().makePath(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Collect and sort module names
    var names = std.ArrayListUnmanaged([]const u8){};
    defer names.deinit(allocator);
    {
        var it = mod_resolver.modules.iterator();
        while (it.next()) |entry| {
            try names.append(allocator, entry.key_ptr.*);
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Generate per-module docs
    var index_entries = std.ArrayListUnmanaged(IndexEntry){};
    defer index_entries.deinit(allocator);

    for (names.items) |mod_name| {
        const mod_ptr = mod_resolver.modules.getPtr(mod_name) orelse continue;
        const ast = mod_ptr.ast orelse continue;

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        try writeModuleDoc(allocator, &buf, mod_name, ast);

        if (buf.items.len == 0) continue; // no pub items

        // Write module file
        const file_name = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ output_dir, mod_name });
        defer allocator.free(file_name);
        const file = try std.fs.cwd().createFile(file_name, .{});
        defer file.close();
        try file.writeAll(buf.items);

        // Get module doc for index
        const mod_doc = ast.program.module.module_decl.doc;
        try index_entries.append(allocator, .{ .name = mod_name, .doc = mod_doc });
    }

    // Write index.md
    if (index_entries.items.len > 0) {
        var idx_buf = std.ArrayListUnmanaged(u8){};
        defer idx_buf.deinit(allocator);

        try idx_buf.appendSlice(allocator, "# Documentation\n\n");
        try idx_buf.appendSlice(allocator, "| Module | Description |\n");
        try idx_buf.appendSlice(allocator, "|--------|-------------|\n");

        for (index_entries.items) |entry| {
            try idx_buf.appendSlice(allocator, "| [");
            try idx_buf.appendSlice(allocator, entry.name);
            try idx_buf.appendSlice(allocator, "](");
            try idx_buf.appendSlice(allocator, entry.name);
            try idx_buf.appendSlice(allocator, ".md) | ");
            if (entry.doc) |d| {
                // Use first line of doc as description
                const first_line = if (std.mem.indexOfScalar(u8, d, '\n')) |nl| d[0..nl] else d;
                try idx_buf.appendSlice(allocator, first_line);
            }
            try idx_buf.appendSlice(allocator, " |\n");
        }

        const idx_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{output_dir});
        defer allocator.free(idx_path);
        const idx_file = try std.fs.cwd().createFile(idx_path, .{});
        defer idx_file.close();
        try idx_file.writeAll(idx_buf.items);
    }

    std.debug.print("generated docs for {d} module(s) in {s}/\n", .{ index_entries.items.len, output_dir });
}

const IndexEntry = struct {
    name: []const u8,
    doc: ?[]const u8,
};

fn writeModuleDoc(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), mod_name: []const u8, ast: *Node) !void {
    const program = ast.program;

    // Classify top-level pub declarations
    var functions = std.ArrayListUnmanaged(*Node){};
    defer functions.deinit(allocator);
    var types_list = std.ArrayListUnmanaged(*Node){};
    defer types_list.deinit(allocator);
    var constants = std.ArrayListUnmanaged(*Node){};
    defer constants.deinit(allocator);

    for (program.top_level) |node| {
        switch (node.*) {
            .func_decl => |f| if (f.is_pub) try functions.append(allocator, node),
            .struct_decl => |s| if (s.is_pub) try types_list.append(allocator, node),
            .enum_decl => |e| if (e.is_pub) try types_list.append(allocator, node),
            .var_decl => |v| if (v.is_pub and v.mutability == .constant) try constants.append(allocator, node),
            else => {},
        }
    }

    // Skip modules with no pub items
    if (functions.items.len == 0 and types_list.items.len == 0 and constants.items.len == 0) return;

    // Module header
    try buf.appendSlice(allocator, "# ");
    try buf.appendSlice(allocator, mod_name);
    try buf.appendSlice(allocator, "\n\n");

    if (program.module.module_decl.doc) |doc| {
        try buf.appendSlice(allocator, doc);
        try buf.appendSlice(allocator, "\n\n");
    }

    // Functions section
    if (functions.items.len > 0) {
        try buf.appendSlice(allocator, "## Functions\n\n");
        for (functions.items) |node| {
            const f = node.func_decl;
            try buf.appendSlice(allocator, "### `");
            try buf.appendSlice(allocator, f.name);
            try buf.append(allocator, '(');
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, p.param.name);
                try buf.appendSlice(allocator, ": ");
                try formatType(p.param.type_annotation, buf, allocator);
            }
            try buf.appendSlice(allocator, ") ");
            try formatType(f.return_type, buf, allocator);
            try buf.appendSlice(allocator, "`\n\n");
            if (f.doc) |doc| {
                try buf.appendSlice(allocator, doc);
                try buf.appendSlice(allocator, "\n\n");
            }
            try buf.appendSlice(allocator, "---\n\n");
        }
    }

    // Types section
    if (types_list.items.len > 0) {
        try buf.appendSlice(allocator, "## Types\n\n");
        for (types_list.items) |node| {
            switch (node.*) {
                .struct_decl => |s| try writeStructDoc(allocator, buf, s),
                .enum_decl => |e| try writeEnumDoc(allocator, buf, e),
                else => {},
            }
        }
    }

    // Constants section
    if (constants.items.len > 0) {
        try buf.appendSlice(allocator, "## Constants\n\n");
        for (constants.items) |node| {
            const c = node.var_decl;
            try buf.appendSlice(allocator, "### `");
            try buf.appendSlice(allocator, c.name);
            if (c.type_annotation) |t| {
                try buf.appendSlice(allocator, ": ");
                try formatType(t, buf, allocator);
            }
            try buf.appendSlice(allocator, "`\n\n");
            if (c.doc) |doc| {
                try buf.appendSlice(allocator, doc);
                try buf.appendSlice(allocator, "\n\n");
            }
            try buf.appendSlice(allocator, "---\n\n");
        }
    }
}

fn writeStructDoc(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), s: parser.StructDecl) !void {
    try buf.appendSlice(allocator, "### `struct ");
    try buf.appendSlice(allocator, s.name);
    if (s.type_params.len > 0) {
        try buf.append(allocator, '(');
        for (s.type_params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.appendSlice(allocator, p.param.name);
            try buf.appendSlice(allocator, ": ");
            try formatType(p.param.type_annotation, buf, allocator);
        }
        try buf.append(allocator, ')');
    }
    try buf.appendSlice(allocator, "`\n\n");

    if (s.doc) |doc| {
        try buf.appendSlice(allocator, doc);
        try buf.appendSlice(allocator, "\n\n");
    }

    // Fields
    var has_fields = false;
    for (s.members) |m| {
        if (m.* == .field_decl) {
            if (!has_fields) {
                try buf.appendSlice(allocator, "**Fields:**\n\n");
                has_fields = true;
            }
            const f = m.field_decl;
            try buf.appendSlice(allocator, "- `");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, ": ");
            try formatType(f.type_annotation, buf, allocator);
            try buf.append(allocator, '`');
            if (f.doc) |doc| {
                try buf.appendSlice(allocator, " — ");
                // Use first line only for inline doc
                const first_line = if (std.mem.indexOfScalar(u8, doc, '\n')) |nl| doc[0..nl] else doc;
                try buf.appendSlice(allocator, first_line);
            }
            try buf.append(allocator, '\n');
        }
    }
    if (has_fields) try buf.append(allocator, '\n');

    try writeMethods(allocator, buf, s.members);

    try buf.appendSlice(allocator, "---\n\n");
}

fn writeEnumDoc(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), e: parser.EnumDecl) !void {
    try buf.appendSlice(allocator, "### `enum ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, "`\n\n");

    if (e.doc) |doc| {
        try buf.appendSlice(allocator, doc);
        try buf.appendSlice(allocator, "\n\n");
    }

    // Variants
    var has_variants = false;
    for (e.members) |m| {
        if (m.* == .enum_variant) {
            if (!has_variants) {
                try buf.appendSlice(allocator, "**Variants:**\n\n");
                has_variants = true;
            }
            const v = m.enum_variant;
            try buf.appendSlice(allocator, "- `");
            try buf.appendSlice(allocator, v.name);
            if (v.value) |val| {
                try buf.appendSlice(allocator, " = ");
                if (val.* == .int_literal) {
                    try buf.appendSlice(allocator, val.int_literal);
                }
            }
            if (v.fields.len > 0) {
                try buf.append(allocator, '(');
                for (v.fields, 0..) |f, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    try buf.appendSlice(allocator, f.param.name);
                    try buf.appendSlice(allocator, ": ");
                    try formatType(f.param.type_annotation, buf, allocator);
                }
                try buf.append(allocator, ')');
            }
            try buf.append(allocator, '`');
            if (v.doc) |doc| {
                try buf.appendSlice(allocator, " — ");
                const first_line = if (std.mem.indexOfScalar(u8, doc, '\n')) |nl| doc[0..nl] else doc;
                try buf.appendSlice(allocator, first_line);
            }
            try buf.append(allocator, '\n');
        }
    }
    if (has_variants) try buf.append(allocator, '\n');

    try writeMethods(allocator, buf, e.members);

    try buf.appendSlice(allocator, "---\n\n");
}

/// Write the "Methods" section for struct or enum members.
fn writeMethods(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), members: []*Node) !void {
    var has_methods = false;
    for (members) |m| {
        if (m.* == .func_decl and m.func_decl.is_pub) {
            if (!has_methods) {
                try buf.appendSlice(allocator, "**Methods:**\n\n");
                has_methods = true;
            }
            const f = m.func_decl;
            try buf.appendSlice(allocator, "- `");
            try buf.appendSlice(allocator, f.name);
            try buf.append(allocator, '(');
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                try buf.appendSlice(allocator, p.param.name);
                try buf.appendSlice(allocator, ": ");
                try formatType(p.param.type_annotation, buf, allocator);
            }
            try buf.appendSlice(allocator, ") ");
            try formatType(f.return_type, buf, allocator);
            try buf.append(allocator, '`');
            if (f.doc) |doc| {
                try buf.appendSlice(allocator, " — ");
                const first_line = if (std.mem.indexOfScalar(u8, doc, '\n')) |nl| doc[0..nl] else doc;
                try buf.appendSlice(allocator, first_line);
            }
            try buf.append(allocator, '\n');
        }
    }
    if (has_methods) try buf.append(allocator, '\n');
}

/// Render a type AST node as a readable string
fn formatType(node: *Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .type_primitive => |s| try buf.appendSlice(alloc, s),
        .type_named => |s| try buf.appendSlice(alloc, s),
        .type_slice => |elem| {
            try buf.appendSlice(alloc, "[]");
            try formatType(elem, buf, alloc);
        },
        .type_array => |a| {
            try buf.append(alloc, '[');
            try formatExpr(a.size, buf, alloc);
            try buf.append(alloc, ']');
            try formatType(a.elem, buf, alloc);
        },
        .type_ptr => |p| {
            try buf.appendSlice(alloc, if (p.kind == .mut_ref) "mut&" else "const&");
            try formatType(p.elem, buf, alloc);
        },
        .type_union => |arms| {
            try buf.append(alloc, '(');
            for (arms, 0..) |arm, i| {
                if (i > 0) try buf.appendSlice(alloc, " | ");
                try formatType(arm, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_func => |f| {
            try buf.appendSlice(alloc, "func(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.appendSlice(alloc, ") ");
            try formatType(f.ret, buf, alloc);
        },
        .type_generic => |g| {
            try buf.appendSlice(alloc, g.name);
            try buf.append(alloc, '(');
            for (g.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_named => |fields| {
            try buf.append(alloc, '(');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try buf.appendSlice(alloc, f.name);
                try buf.appendSlice(alloc, ": ");
                try formatType(f.type_node, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_anon => |parts| {
            try buf.append(alloc, '(');
            for (parts, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => try buf.appendSlice(alloc, "any"),
    }
}

fn formatExpr(node: *Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .int_literal => |s| try buf.appendSlice(alloc, s),
        .float_literal => |s| try buf.appendSlice(alloc, s),
        .identifier => |s| try buf.appendSlice(alloc, s),
        else => try buf.appendSlice(alloc, "_"),
    }
}
