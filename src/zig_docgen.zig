// zig_docgen.zig — Generate Markdown docs from Zig stdlib files
// Parses .zig files with std.zig.Ast and extracts pub declarations + /// doc comments.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// A documented declaration.
const DocEntry = struct {
    kind: enum { function, constant, type_decl },
    name: []const u8,
    signature: []const u8,
    doc: ?[]const u8, // merged /// lines
    is_method: bool,  // inside a struct/type
    parent: ?[]const u8, // parent type name for methods
};

/// Generate docs for all .zig files in a directory.
pub fn generateStdDocs(allocator: Allocator, std_dir: []const u8, output_dir: []const u8) !void {
    std.fs.cwd().makePath(output_dir) catch {};

    var dir = try std.fs.cwd().openDir(std_dir, .{ .iterate = true });
    defer dir.close();

    var module_names = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (module_names.items) |n| allocator.free(n);
        module_names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        // Skip _prefixed private files
        if (entry.name[0] == '_') continue;

        const mod_name = entry.name[0 .. entry.name.len - 4]; // strip .zig

        // Read file content
        const path = try std.fs.path.join(allocator, &.{ std_dir, entry.name });
        defer allocator.free(path);
        const source = try std.fs.cwd().readFileAllocOptions(allocator, path, 1024 * 1024, null, .@"1", 0);
        defer allocator.free(source);

        // Parse with Zig AST
        var tree = try Ast.parse(allocator, source, .zig);
        defer tree.deinit(allocator);

        if (tree.errors.len > 0) continue; // skip files with parse errors

        // Extract entries
        var entries = std.ArrayListUnmanaged(DocEntry){};
        defer {
            for (entries.items) |e| {
                allocator.free(e.signature);
                if (e.doc) |d| allocator.free(d);
            }
            entries.deinit(allocator);
        }

        try extractDecls(&tree, allocator, &entries, null);

        if (entries.items.len == 0) continue;

        // Generate markdown
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "# std::");
        try buf.appendSlice(allocator, mod_name);
        try buf.appendSlice(allocator, "\n\n");

        // Separate top-level functions from type methods
        var has_functions = false;
        for (entries.items) |e| {
            if (!e.is_method and e.kind == .function) { has_functions = true; break; }
        }
        var has_constants = false;
        for (entries.items) |e| {
            if (!e.is_method and e.kind == .constant) { has_constants = true; break; }
        }
        var has_types = false;
        for (entries.items) |e| {
            if (!e.is_method and e.kind == .type_decl) { has_types = true; break; }
        }

        // Types section
        if (has_types) {
            try buf.appendSlice(allocator, "## Types\n\n");
            for (entries.items) |e| {
                if (e.is_method or e.kind != .type_decl) continue;
                try writeEntry(allocator, &buf, e);
            }
        }

        // Constants section
        if (has_constants) {
            try buf.appendSlice(allocator, "## Constants\n\n");
            for (entries.items) |e| {
                if (e.is_method or e.kind != .constant) continue;
                try writeEntry(allocator, &buf, e);
            }
        }

        // Functions section
        if (has_functions) {
            try buf.appendSlice(allocator, "## Functions\n\n");
            for (entries.items) |e| {
                if (e.is_method or e.kind != .function) continue;
                try writeEntry(allocator, &buf, e);
            }
        }

        // Methods grouped by parent type
        var seen_parents = std.StringHashMapUnmanaged(void){};
        defer seen_parents.deinit(allocator);
        for (entries.items) |e| {
            if (!e.is_method) continue;
            const parent = e.parent orelse continue;
            if (seen_parents.contains(parent)) continue;
            try seen_parents.put(allocator, parent, {});

            try buf.appendSlice(allocator, "## ");
            try buf.appendSlice(allocator, parent);
            try buf.appendSlice(allocator, " Methods\n\n");

            for (entries.items) |e2| {
                if (!e2.is_method) continue;
                const p2 = e2.parent orelse continue;
                if (!std.mem.eql(u8, p2, parent)) continue;
                try writeEntry(allocator, &buf, e2);
            }
        }

        // Write file
        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.md", .{ output_dir, mod_name });
        defer allocator.free(out_path);
        const file = try std.fs.cwd().createFile(out_path, .{});
        defer file.close();
        try file.writeAll(buf.items);

        try module_names.append(allocator, try allocator.dupe(u8, mod_name));
    }

    // Sort module names
    std.mem.sort([]const u8, module_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Generate index
    var idx = std.ArrayListUnmanaged(u8){};
    defer idx.deinit(allocator);
    try idx.appendSlice(allocator, "# Orhon Standard Library Reference\n\n");
    try idx.appendSlice(allocator, "> Auto-generated from `src/std/*.zig`.\n\n");
    for (module_names.items) |name| {
        try idx.appendSlice(allocator, "- [[");
        try idx.appendSlice(allocator, name);
        try idx.appendSlice(allocator, "|std::");
        try idx.appendSlice(allocator, name);
        try idx.appendSlice(allocator, "]]\n");
    }

    const idx_path = try std.fmt.allocPrint(allocator, "{s}/index.md", .{output_dir});
    defer allocator.free(idx_path);
    const idx_file = try std.fs.cwd().createFile(idx_path, .{});
    defer idx_file.close();
    try idx_file.writeAll(idx.items);

    std.debug.print("Generated: {s}/ ({d} modules)\n", .{ output_dir, module_names.items.len });
}

fn writeEntry(allocator: Allocator, buf: *std.ArrayListUnmanaged(u8), e: DocEntry) !void {
    try buf.appendSlice(allocator, "### `");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, "`\n\n");
    if (e.doc) |doc| {
        try buf.appendSlice(allocator, doc);
        try buf.appendSlice(allocator, "\n\n");
    }
    try buf.appendSlice(allocator, "```zig\n");
    try buf.appendSlice(allocator, e.signature);
    try buf.appendSlice(allocator, "\n```\n\n");
}

/// Extract pub declarations from a Zig AST.
fn extractDecls(tree: *const Ast, allocator: Allocator, entries: *std.ArrayListUnmanaged(DocEntry), parent_name: ?[]const u8) !void {
    const decls = tree.rootDecls();

    for (decls) |node| {
        try extractNode(tree, node, allocator, entries, parent_name);
    }
}

fn extractNode(tree: *const Ast, node: Ast.Node.Index, allocator: Allocator, entries: *std.ArrayListUnmanaged(DocEntry), parent_name: ?[]const u8) !void {
    const tag = tree.nodeTag(node);

    switch (tag) {
        .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
            const main_token = tree.nodeMainToken(node);
            // Check if pub: look back for 'pub' keyword
            if (!isPub(tree, main_token)) return;
            const name = getFnName(tree, main_token) orelse return;
            const sig = try buildFnSignature(tree, node, allocator);
            const doc = try getDocComment(tree, main_token, allocator);
            try entries.append(allocator, .{
                .kind = .function,
                .name = name,
                .signature = sig,
                .doc = doc,
                .is_method = parent_name != null,
                .parent = parent_name,
            });
        },
        .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
            const var_decl = tree.fullVarDecl(node) orelse return;
            if (var_decl.visib_token == null) return; // not pub
            const main_token = tree.nodeMainToken(node);
            const name_tok = var_decl.ast.mut_token + 1;
            if (name_tok >= tree.tokens.len) return;
            const name = tree.tokenSlice(name_tok);

            // Check if this is a type (struct, enum) via init node
            if (var_decl.ast.init_node.unwrap()) |init| {
                if (isContainerDecl(tree.nodeTag(init))) {
                    const doc = try getDocComment(tree, main_token, allocator);
                    const sig = try std.fmt.allocPrint(allocator, "pub const {s} = struct {{ ... }}", .{name});
                    try entries.append(allocator, .{
                        .kind = .type_decl,
                        .name = name,
                        .signature = sig,
                        .doc = doc,
                        .is_method = parent_name != null,
                        .parent = parent_name,
                    });
                    // Extract struct members
                    var container_buf: [2]Ast.Node.Index = undefined;
                    if (tree.fullContainerDecl(&container_buf, init)) |container| {
                        for (container.ast.members) |member| {
                            try extractNode(tree, member, allocator, entries, name);
                        }
                    }
                    return;
                }
            }

            const doc = try getDocComment(tree, main_token, allocator);
            const sig = try buildVarSignature(name, allocator);
            try entries.append(allocator, .{
                .kind = .constant,
                .name = name,
                .signature = sig,
                .doc = doc,
                .is_method = parent_name != null,
                .parent = parent_name,
            });
        },
        else => {},
    }
}

fn isContainerDecl(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl_two, .container_decl_two_trailing,
        .container_decl, .container_decl_trailing,
        .container_decl_arg, .container_decl_arg_trailing,
        => true,
        else => false,
    };
}

/// Check if the token before main_token is 'pub'
fn isPub(tree: *const Ast, main_token: Ast.TokenIndex) bool {
    if (main_token == 0) return false;
    return tree.tokenTag(main_token - 1) == .keyword_pub;
}

/// Get function name from fn token
fn getFnName(tree: *const Ast, fn_token: Ast.TokenIndex) ?[]const u8 {
    // fn token is followed by the name identifier
    const name_tok = fn_token + 1;
    if (name_tok >= tree.tokens.len) return null;
    if (tree.tokenTag(name_tok) != .identifier) return null;
    return tree.tokenSlice(name_tok);
}

/// Extract consecutive /// doc comment lines before a declaration.
fn getDocComment(tree: *const Ast, decl_token: Ast.TokenIndex, allocator: Allocator) !?[]const u8 {
    // Walk backwards from the pub keyword (or fn keyword) to find doc_comment tokens
    if (decl_token < 1) return null;
    var start = if (decl_token > 1 and tree.tokenTag(decl_token - 1) == .keyword_pub)
        decl_token - 2
    else
        decl_token - 1;

    // Find consecutive doc_comment tokens going backwards
    var first_doc: ?Ast.TokenIndex = null;
    while (true) {
        if (tree.tokenTag(start) == .doc_comment) {
            first_doc = start;
            if (start == 0) break;
            start -= 1;
        } else break;
    }

    if (first_doc == null) return null;

    // Collect doc comment text
    var doc_buf = std.ArrayListUnmanaged(u8){};
    errdefer doc_buf.deinit(allocator);
    var tok = first_doc.?;
    while (tok < tree.tokens.len and tree.tokenTag(tok) == .doc_comment) : (tok += 1) {
        const text = tree.tokenSlice(tok);
        // Strip leading "/// " or "///"
        const content = if (text.len > 4 and std.mem.startsWith(u8, text, "/// "))
            text[4..]
        else if (text.len >= 3 and std.mem.startsWith(u8, text, "///"))
            text[3..]
        else
            text;
        if (doc_buf.items.len > 0) try doc_buf.append(allocator, '\n');
        try doc_buf.appendSlice(allocator, content);
    }

    if (doc_buf.items.len == 0) {
        doc_buf.deinit(allocator);
        return null;
    }
    return try doc_buf.toOwnedSlice(allocator);
}

/// Build function signature string
fn buildFnSignature(tree: *const Ast, node: Ast.Node.Index, allocator: Allocator) ![]const u8 {
    // Use source range from fn token to end of return type
    const main_token = tree.nodeMainToken(node);
    const pub_start = if (main_token > 0 and tree.tokenTag(main_token - 1) == .keyword_pub)
        main_token - 1
    else
        main_token;

    // Find the opening brace or semicolon to determine signature end
    var end_tok = main_token;
    while (end_tok < tree.tokens.len) : (end_tok += 1) {
        const ttag = tree.tokenTag(end_tok);
        if (ttag == .l_brace or ttag == .semicolon) break;
    }

    // Build from token slices
    var sig = std.ArrayListUnmanaged(u8){};
    errdefer sig.deinit(allocator);

    var tok = pub_start;
    while (tok < end_tok and tok < tree.tokens.len) : (tok += 1) {
        const ttag = tree.tokenTag(tok);
        if (ttag == .doc_comment or ttag == .container_doc_comment) continue;
        if (sig.items.len > 0) try sig.append(allocator, ' ');
        try sig.appendSlice(allocator, tree.tokenSlice(tok));
    }

    return try sig.toOwnedSlice(allocator);
}

/// Build variable/constant signature
fn buildVarSignature(name: []const u8, allocator: Allocator) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "pub const {s}", .{name});
}

test "zig_docgen basic parse" {
    // Verify the module compiles and basic functions work
    const allocator = std.testing.allocator;
    const source = "/// Add two numbers.\npub fn add(a: i32, b: i32) i32 { return a + b; }\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expect(tree.errors.len == 0);
}

test "zig_docgen extractDecls - pub fn" {
    const allocator = std.testing.allocator;
    const source = "pub fn add(a: i32, b: i32) i32 { return a + b; }\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer {
        for (entries.items) |e| {
            if (e.doc) |d| allocator.free(d);
            allocator.free(e.signature);
        }
        entries.deinit(allocator);
    }
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("add", entries.items[0].name);
    try std.testing.expect(entries.items[0].kind == .function);
    try std.testing.expect(!entries.items[0].is_method);
}

test "zig_docgen extractDecls - non-pub skipped" {
    const allocator = std.testing.allocator;
    const source = "fn helper() void {}\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer entries.deinit(allocator);
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "zig_docgen extractDecls - pub const" {
    const allocator = std.testing.allocator;
    const source = "pub const MAGIC = 42;\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer {
        for (entries.items) |e| {
            if (e.doc) |d| allocator.free(d);
            allocator.free(e.signature);
        }
        entries.deinit(allocator);
    }
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("MAGIC", entries.items[0].name);
    try std.testing.expect(entries.items[0].kind == .constant);
}

test "zig_docgen getDocComment - single line" {
    const allocator = std.testing.allocator;
    const source = "/// Hello world.\npub fn f() void {}\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer {
        for (entries.items) |e| {
            if (e.doc) |d| allocator.free(d);
            allocator.free(e.signature);
        }
        entries.deinit(allocator);
    }
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("Hello world.", entries.items[0].doc.?);
}

test "zig_docgen getDocComment - multi line" {
    const allocator = std.testing.allocator;
    const source = "/// Line 1.\n/// Line 2.\npub fn f() void {}\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer {
        for (entries.items) |e| {
            if (e.doc) |d| allocator.free(d);
            allocator.free(e.signature);
        }
        entries.deinit(allocator);
    }
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("Line 1.\nLine 2.", entries.items[0].doc.?);
}

test "zig_docgen getDocComment - no doc" {
    const allocator = std.testing.allocator;
    const source = "pub fn f() void {}\n";
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    var entries: std.ArrayListUnmanaged(DocEntry) = .{};
    defer {
        for (entries.items) |e| {
            if (e.doc) |d| allocator.free(d);
            allocator.free(e.signature);
        }
        entries.deinit(allocator);
    }
    try extractDecls(&tree, allocator, &entries, null);

    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(entries.items[0].doc == null);
}
