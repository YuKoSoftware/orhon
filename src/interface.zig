// interface.zig — Public interface file generation for library modules
//
// When a module is compiled as static or dynamic, emit a pub-only
// `.orh` file into bin/ so consumers can type-check against the API.
// The interface file is valid Orhon — it has the module declaration,
// version, and all pub signatures, but no bodies or private members.

const std = @import("std");
const parser = @import("parser.zig");

// ============================================================
// INTERFACE FILE GENERATION
// ============================================================

/// Write a type node as Orhon source syntax into a buffer
fn formatType(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .type_primitive => |s| try buf.appendSlice(alloc, s),
        .type_named     => |s| try buf.appendSlice(alloc, s),
        .type_slice     => |elem| {
            try buf.appendSlice(alloc, "[]");
            try formatType(elem, buf, alloc);
        },
        .type_array     => |a| {
            try buf.append(alloc, '[');
            try formatExprSimple(a.size, buf, alloc);
            try buf.append(alloc, ']');
            try formatType(a.elem, buf, alloc);
        },
        .type_ptr       => |p| {
            try buf.appendSlice(alloc, if (p.kind == .mut_ref) "mut&" else "const&");
            try formatType(p.elem, buf, alloc);
        },
        .type_union     => |arms| {
            try buf.append(alloc, '(');
            for (arms, 0..) |arm, i| {
                if (i > 0) try buf.appendSlice(alloc, " | ");
                try formatType(arm, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_func      => |f| {
            try buf.appendSlice(alloc, "func(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.appendSlice(alloc, ") ");
            try formatType(f.ret, buf, alloc);
        },
        .type_generic   => |g| {
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

/// Write simple expressions that appear in type contexts (array sizes, version numbers)
fn formatExprSimple(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .int_literal   => |s| try buf.appendSlice(alloc, s),
        .float_literal => |s| try buf.appendSlice(alloc, s),
        .identifier    => |s| try buf.appendSlice(alloc, s),
        .call_expr     => |c| {
            // Version(1, 2, 3) etc.
            if (c.callee.* == .identifier) try buf.appendSlice(alloc, c.callee.identifier);
            try buf.append(alloc, '(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatExprSimple(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => {},
    }
}

/// Write a function signature (no body) into a buffer
fn emitFuncSig(f: parser.FuncDecl, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, indent: []const u8) anyerror!void {
    try buf.appendSlice(alloc, indent);
    if (f.is_pub) try buf.appendSlice(alloc, "pub ");
    if (f.context == .compt) try buf.appendSlice(alloc, "compt ");
    try buf.appendSlice(alloc, "func ");
    try buf.appendSlice(alloc, f.name);
    try buf.append(alloc, '(');
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        const param = p.param;
        try buf.appendSlice(alloc, param.name);
        try buf.appendSlice(alloc, ": ");
        try formatType(param.type_annotation, buf, alloc);
    }
    try buf.appendSlice(alloc, ") ");
    try formatType(f.return_type, buf, alloc);
    try buf.append(alloc, '\n');
}

/// Emit one top-level pub declaration into a buffer (skip private)
fn emitInterfaceDecl(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .func_decl => |f| {
            if (!f.is_pub) return;
            try emitFuncSig(f, buf, alloc, "");
            try buf.append(alloc, '\n');
        },
        .struct_decl => |s| {
            if (!s.is_pub) return;
            try buf.appendSlice(alloc, "pub struct ");
            try buf.appendSlice(alloc, s.name);
            try buf.appendSlice(alloc, " {\n");
            for (s.members) |m| {
                switch (m.*) {
                    .field_decl => |fd| {
                        if (!fd.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub ");
                        try buf.appendSlice(alloc, fd.name);
                        try buf.appendSlice(alloc, ": ");
                        try formatType(fd.type_annotation, buf, alloc);
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    .const_decl => |v| {
                        if (!v.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub const ");
                        try buf.appendSlice(alloc, v.name);
                        if (v.type_annotation) |t| {
                            try buf.appendSlice(alloc, ": ");
                            try formatType(t, buf, alloc);
                        }
                        try buf.append(alloc, '\n');
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .enum_decl => |e| {
            if (!e.is_pub) return;
            try buf.appendSlice(alloc, "pub enum ");
            try buf.appendSlice(alloc, e.name);
            try buf.append(alloc, '(');
            try formatType(e.backing_type, buf, alloc);
            try buf.appendSlice(alloc, ") {\n");
            for (e.members) |m| {
                switch (m.*) {
                    .enum_variant => |v| {
                        try buf.appendSlice(alloc, "    ");
                        try buf.appendSlice(alloc, v.name);
                        if (v.value) |val| {
                            try buf.appendSlice(alloc, " = ");
                            if (val.* == .int_literal) {
                                try buf.appendSlice(alloc, val.int_literal);
                            }
                        }
                        if (v.fields.len > 0) {
                            try buf.append(alloc, '(');
                            for (v.fields, 0..) |f, i| {
                                if (i > 0) try buf.appendSlice(alloc, ", ");
                                const p = f.param;
                                try buf.appendSlice(alloc, p.name);
                                try buf.appendSlice(alloc, ": ");
                                try formatType(p.type_annotation, buf, alloc);
                            }
                            try buf.append(alloc, ')');
                        }
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .bitfield_decl => |b| {
            if (!b.is_pub) return;
            try buf.appendSlice(alloc, "pub bitfield ");
            try buf.appendSlice(alloc, b.name);
            try buf.append(alloc, '(');
            try formatType(b.backing_type, buf, alloc);
            try buf.appendSlice(alloc, ") {\n");
            for (b.members) |flag| {
                try buf.appendSlice(alloc, "    ");
                try buf.appendSlice(alloc, flag);
                try buf.append(alloc, '\n');
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .const_decl => |v| {
            if (!v.is_pub) return;
            try buf.appendSlice(alloc, "pub const ");
            try buf.appendSlice(alloc, v.name);
            if (v.type_annotation) |t| {
                try buf.appendSlice(alloc, ": ");
                try formatType(t, buf, alloc);
            }
            try buf.appendSlice(alloc, " = ");
            try formatExprSimple(v.value, buf, alloc);
            try buf.append(alloc, '\n');
            try buf.append(alloc, '\n');
        },
        else => {},
    }
}

/// Generate a pub-only interface `.orh` file into `bin/<binary_name>.orh`.
/// Called after a successful static or dynamic library build.
pub fn generateInterface(
    alloc: std.mem.Allocator,
    mod_name: []const u8,
    binary_name: []const u8,
    ast: *parser.Node,
) !void {
    if (ast.* != .program) return;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    // Header comment + module declaration
    try buf.appendSlice(alloc, "// Orhon interface file — generated by orhon, do not edit\n\n");
    try buf.appendSlice(alloc, "module ");
    try buf.appendSlice(alloc, mod_name);
    try buf.appendSlice(alloc, "\n\n");

    // Version from metadata
    for (ast.program.metadata) |meta| {
        if (std.mem.eql(u8, meta.metadata.field, "version")) {
            try buf.appendSlice(alloc, "#version = ");
            try formatExprSimple(meta.metadata.value, &buf, alloc);
            try buf.appendSlice(alloc, "\n\n");
            break;
        }
    }

    // Public declarations
    for (ast.program.top_level) |node| {
        try emitInterfaceDecl(node, &buf, alloc);
    }

    // Write to bin/<binary_name>.orh
    try std.fs.cwd().makePath("bin");
    const path = try std.fmt.allocPrint(alloc, "bin/{s}.orh", .{binary_name});
    defer alloc.free(path);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}
