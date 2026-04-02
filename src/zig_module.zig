// zig_module.zig — Zig-to-Orhon automatic module converter
// Walks Zig AST (std.zig.Ast) to extract pub declarations and produce .orh module text.
// Self-contained: depends only on std.zig.Ast, no Orhon compiler modules.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

/// Primitives that pass through unchanged from Zig to Orhon.
const PASSTHROUGH_PRIMITIVES = [_][]const u8{
    "u8",    "i8",   "i16",  "i32",  "i64",
    "u16",   "u32",  "u64",  "f32",  "f64",
    "bool",  "void", "usize",
};

/// Output buffer for type mapping. Wraps an unmanaged ArrayList(u8).
pub const TypeBuf = struct {
    buf: std.ArrayList(u8) = .{},

    pub fn append(self: *TypeBuf, allocator: Allocator, data: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(allocator, data);
    }

    pub fn deinit(self: *TypeBuf, allocator: Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn items(self: *const TypeBuf) []const u8 {
        return self.buf.items;
    }
};

/// Writes the Orhon type string for the given Zig AST type node into `out`.
/// Returns `true` if the type was successfully mapped, `false` if unmappable.
pub fn mapType(tree: *const Ast, node: Node.Index, allocator: Allocator, out: *TypeBuf) anyerror!bool {
    const tag = tree.nodeTag(node);

    switch (tag) {
        // --- identifier: primitive passthrough or user-defined type ---
        .identifier => {
            const token = tree.nodeMainToken(node);
            const name = tree.tokenSlice(token);

            // anytype → any
            if (std.mem.eql(u8, name, "anytype")) {
                try out.append(allocator, "any");
                return true;
            }

            // Check primitives
            for (PASSTHROUGH_PRIMITIVES) |prim| {
                if (std.mem.eql(u8, name, prim)) {
                    try out.append(allocator, name);
                    return true;
                }
            }

            // A bare identifier that isn't a primitive is a user-defined type.
            // Qualified names (std.mem.Allocator) are caught by field_access.
            try out.append(allocator, name);
            return true;
        },

        // --- ?T → NullUnion(T) ---
        .optional_type => {
            const child = tree.nodeData(node).node;
            try out.append(allocator, "NullUnion(");
            const ok = try mapType(tree, child, allocator, out);
            if (!ok) return false;
            try out.append(allocator, ")");
            return true;
        },

        // --- lhs!rhs → ErrorUnion(rhs) ---
        // For `anyerror!T`, lhs is the error set, rhs is the payload type.
        .error_union => {
            const rhs = tree.nodeData(node).node_and_node[1];
            try out.append(allocator, "ErrorUnion(");
            const ok = try mapType(tree, rhs, allocator, out);
            if (!ok) return false;
            try out.append(allocator, ")");
            return true;
        },

        // --- pointer types: *T, *const T, []const u8, []T ---
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        .ptr_type_bit_range,
        => {
            const ptr_info = tree.fullPtrType(node) orelse return false;

            switch (ptr_info.size) {
                // []T or []const T — slice types
                .slice => {
                    const is_const = ptr_info.const_token != null;
                    // Check for []const u8 → String
                    if (is_const) {
                        if (tree.nodeTag(ptr_info.ast.child_type) == .identifier) {
                            const child_name = tree.tokenSlice(tree.nodeMainToken(ptr_info.ast.child_type));
                            if (std.mem.eql(u8, child_name, "u8")) {
                                try out.append(allocator, "String");
                                return true;
                            }
                        }
                    }
                    // Other slices are unmappable for now
                    return false;
                },

                // *T or *const T — single-item pointer
                .one => {
                    const is_const = ptr_info.const_token != null;
                    if (is_const) {
                        try out.append(allocator, "const& ");
                    } else {
                        try out.append(allocator, "mut& ");
                    }
                    return try mapType(tree, ptr_info.ast.child_type, allocator, out);
                },

                // [*]T, [*c]T — many-item and c pointers are unmappable
                .many, .c => return false,
            }
        },

        // --- field_access: lhs.rhs — qualified names like std.mem.Allocator ---
        .field_access => {
            // Qualified names are unmappable (std.mem.Allocator, etc.)
            return false;
        },

        else => return false,
    }
}

// ---------------------------------------------------------------------------
// Declaration extraction
// ---------------------------------------------------------------------------

/// Extracts a pub fn signature and returns the Orhon declaration string.
/// Returns null if the function has unmappable parameter types or return type.
pub fn extractFn(tree: *const Ast, node: Node.Index, allocator: Allocator) anyerror!?[]const u8 {
    return extractFnInner(tree, node, "", "pub func ", allocator);
}

/// Shared fn extraction logic used by both extractFn and extractStructFn.
/// `struct_name` is non-empty for struct methods (enables self-parameter mapping).
/// `prefix` is the line prefix ("pub func " or "    pub func ").
fn extractFnInner(
    tree: *const Ast,
    node: Node.Index,
    struct_name: []const u8,
    prefix: []const u8,
    allocator: Allocator,
) anyerror!?[]const u8 {
    var buf: [1]Node.Index = undefined;
    var proto = tree.fullFnProto(&buf, node) orelse return null;

    // Must be pub
    if (proto.visib_token == null) return null;

    // Get function name
    const name_token = proto.name_token orelse return null;
    const fn_name = tree.tokenSlice(name_token);

    // Build parameter list
    var params: std.ArrayList(u8) = .{};
    defer params.deinit(allocator);

    var param_iter = proto.iterate(tree);
    var first_param = true;
    while (param_iter.next()) |param| {
        if (!first_param) {
            try params.appendSlice(allocator, ", ");
        }
        first_param = false;

        // Parameter name
        if (param.name_token) |name_tok| {
            try params.appendSlice(allocator, tree.tokenSlice(name_tok));
        } else {
            try params.appendSlice(allocator, "_");
        }
        try params.appendSlice(allocator, ": ");

        // Check for comptime keyword
        const is_comptime = if (param.comptime_noalias) |cn_tok|
            tree.tokenTag(cn_tok) == .keyword_comptime
        else
            false;

        if (is_comptime) {
            try params.appendSlice(allocator, "compt ");
        }

        // Parameter type
        if (param.anytype_ellipsis3 != null) {
            try params.appendSlice(allocator, "any");
        } else if (param.type_expr) |type_node| {
            // For struct methods, handle self-parameter mapping
            if (struct_name.len > 0) {
                const mapped = try mapSelfParam(tree, type_node, struct_name, allocator);
                if (mapped) |m| {
                    defer allocator.free(m);
                    try params.appendSlice(allocator, m);
                } else {
                    return null;
                }
            } else {
                var type_buf: TypeBuf = .{};
                defer type_buf.deinit(allocator);
                const ok = try mapType(tree, type_node, allocator, &type_buf);
                if (!ok) return null;
                try params.appendSlice(allocator, type_buf.items());
            }
        } else {
            return null;
        }
    }

    // Return type
    const ret_node = proto.ast.return_type.unwrap() orelse return null;
    var ret_buf: TypeBuf = .{};
    defer ret_buf.deinit(allocator);
    const ret_ok = try mapType(tree, ret_node, allocator, &ret_buf);
    if (!ret_ok) return null;

    // Build final signature
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, prefix);
    try result.appendSlice(allocator, fn_name);
    try result.append(allocator, '(');
    try result.appendSlice(allocator, params.items);
    try result.appendSlice(allocator, ") ");
    try result.appendSlice(allocator, ret_buf.items());

    return try result.toOwnedSlice(allocator);
}

/// Extracts a pub fn inside a struct, mapping self parameters to Orhon borrow syntax.
fn extractStructFn(
    tree: *const Ast,
    node: Node.Index,
    struct_name: []const u8,
    allocator: Allocator,
) anyerror!?[]const u8 {
    return extractFnInner(tree, node, struct_name, "    pub func ", allocator);
}

/// Maps a parameter type, handling self-parameter patterns for struct methods.
/// *StructName → mut& StructName, *const StructName → const& StructName
fn mapSelfParam(
    tree: *const Ast,
    type_node: Node.Index,
    struct_name: []const u8,
    allocator: Allocator,
) anyerror!?[]const u8 {
    const tag = tree.nodeTag(type_node);

    // Check for pointer-to-self patterns
    if (tag == .ptr_type_aligned or tag == .ptr_type_sentinel or
        tag == .ptr_type or tag == .ptr_type_bit_range)
    {
        const ptr_info = tree.fullPtrType(type_node) orelse {
            return try mapTypeAlloc(tree, type_node, allocator);
        };

        if (ptr_info.size == .one) {
            // Check if child type is our struct name
            if (tree.nodeTag(ptr_info.ast.child_type) == .identifier) {
                const child_name = tree.tokenSlice(tree.nodeMainToken(ptr_info.ast.child_type));
                if (std.mem.eql(u8, child_name, struct_name)) {
                    const is_const = ptr_info.const_token != null;
                    if (is_const) {
                        return try std.fmt.allocPrint(allocator, "const& {s}", .{struct_name});
                    } else {
                        return try std.fmt.allocPrint(allocator, "mut& {s}", .{struct_name});
                    }
                }
            }
        }
    }

    // Fall through to normal mapType
    return try mapTypeAlloc(tree, type_node, allocator);
}

/// Convenience wrapper: calls mapType and returns an owned string, or null if unmappable.
fn mapTypeAlloc(tree: *const Ast, node: Node.Index, allocator: Allocator) anyerror!?[]const u8 {
    var out: TypeBuf = .{};
    defer out.deinit(allocator);
    const ok = try mapType(tree, node, allocator, &out);
    if (!ok) return null;
    return try allocator.dupe(u8, out.items());
}

/// Extracts a pub const declaration. Handles struct values, string literals,
/// and number literals. Returns null for unmappable values.
pub fn extractConst(tree: *const Ast, node: Node.Index, allocator: Allocator) anyerror!?[]const u8 {
    const var_decl = tree.fullVarDecl(node) orelse return null;

    // Must be pub
    if (var_decl.visib_token == null) return null;

    // Must be const (not var)
    if (tree.tokenTag(var_decl.ast.mut_token) != .keyword_const) return null;

    // Get the name — token after `const`
    const name_token = var_decl.ast.mut_token + 1;
    if (tree.tokenTag(name_token) != .identifier) return null;
    const name = tree.tokenSlice(name_token);

    // Check the init value
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const init_tag = tree.nodeTag(init_node);

    // If it's a struct/enum/union container → delegate to extractStruct
    if (isContainerDecl(init_tag)) {
        return try extractStruct(tree, init_node, name, allocator);
    }

    // String literal → String type
    if (init_tag == .string_literal or init_tag == .multiline_string_literal) {
        return try std.fmt.allocPrint(allocator, "pub const {s}: String", .{name});
    }

    // Number literal → i64 type
    if (init_tag == .number_literal) {
        return try std.fmt.allocPrint(allocator, "pub const {s}: i64", .{name});
    }

    // Negation of number literal → i64 type
    if (init_tag == .negation) {
        const operand = tree.nodeData(init_node).node;
        if (tree.nodeTag(operand) == .number_literal) {
            return try std.fmt.allocPrint(allocator, "pub const {s}: i64", .{name});
        }
    }

    return null;
}

/// Returns true if the node tag is a container declaration (struct, enum, union).
fn isContainerDecl(tag: Node.Tag) bool {
    return switch (tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => true,
        else => false,
    };
}

/// Extracts a struct definition, including its pub fn members.
/// Returns the full Orhon struct block string.
pub fn extractStruct(
    tree: *const Ast,
    node: Node.Index,
    name: []const u8,
    allocator: Allocator,
) anyerror!?[]const u8 {
    // Verify the container is a struct (not enum/union)
    const main_token = tree.nodeMainToken(node);
    if (tree.tokenTag(main_token) != .keyword_struct) return null;

    var container_buf: [2]Node.Index = undefined;
    const container = tree.fullContainerDecl(&container_buf, node) orelse return null;

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "pub struct ");
    try result.appendSlice(allocator, name);
    try result.appendSlice(allocator, " {\n");

    var has_members = false;
    for (container.ast.members) |member| {
        const member_tag = tree.nodeTag(member);
        // Only handle fn_decl and fn_proto variants
        if (member_tag == .fn_decl or member_tag == .fn_proto or
            member_tag == .fn_proto_multi or member_tag == .fn_proto_one or
            member_tag == .fn_proto_simple)
        {
            if (try extractStructFn(tree, member, name, allocator)) |sig| {
                defer allocator.free(sig);
                if (has_members) try result.append(allocator, '\n');
                try result.appendSlice(allocator, sig);
                try result.append(allocator, '\n');
                has_members = true;
            }
        }
    }

    try result.append(allocator, '}');

    if (!has_members) {
        result.deinit(allocator);
        return null;
    }

    return try result.toOwnedSlice(allocator);
}

/// Produces a complete .orh module from a Zig AST.
/// Returns null if no declarations could be extracted.
pub fn generateModule(
    mod_name: []const u8,
    tree: *const Ast,
    allocator: Allocator,
) anyerror!?[]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "module ");
    try result.appendSlice(allocator, mod_name);
    try result.appendSlice(allocator, "\n\n");

    const header_len = result.items.len;

    const root_decls = tree.rootDecls();
    for (root_decls) |decl_node| {
        const tag = tree.nodeTag(decl_node);

        const decl_str: ?[]const u8 = switch (tag) {
            // Function declarations
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => try extractFn(tree, decl_node, allocator),

            // Variable declarations (const/var)
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => try extractConst(tree, decl_node, allocator),

            else => null,
        };

        if (decl_str) |s| {
            defer allocator.free(s);
            try result.appendSlice(allocator, s);
            try result.appendSlice(allocator, "\n\n");
        }
    }

    // If nothing was extracted beyond the header, return null
    if (result.items.len == header_len) {
        result.deinit(allocator);
        return null;
    }

    return try result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Parse a Zig type expression wrapped in a variable declaration,
/// extract the type node, and run mapType on it.
fn testMapType(source: [:0]const u8) !?[]const u8 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    // The source is `const _: TYPE = undefined;`
    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return null;

    const decl_node = root_decls[0];
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const type_node = var_decl.ast.type_node.unwrap() orelse return null;

    var out: TypeBuf = .{};
    defer out.deinit(allocator);

    const ok = try mapType(&tree, type_node, allocator, &out);
    if (!ok) return null;

    return try allocator.dupe(u8, out.items());
}

fn expectMapping(source: [:0]const u8, expected: []const u8) !void {
    const result = try testMapType(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    } else {
        std.debug.print("Expected '{s}' but got null (unmappable)\n", .{expected});
        return error.TestUnexpectedResult;
    }
}

fn expectUnmappable(source: [:0]const u8) !void {
    const result = try testMapType(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        std.debug.print("Expected unmappable but got '{s}'\n", .{actual});
        return error.TestUnexpectedResult;
    }
}

test "primitive passthrough" {
    try expectMapping("const _: i32 = undefined;", "i32");
    try expectMapping("const _: u8 = undefined;", "u8");
    try expectMapping("const _: i8 = undefined;", "i8");
    try expectMapping("const _: i16 = undefined;", "i16");
    try expectMapping("const _: i64 = undefined;", "i64");
    try expectMapping("const _: u16 = undefined;", "u16");
    try expectMapping("const _: u32 = undefined;", "u32");
    try expectMapping("const _: u64 = undefined;", "u64");
    try expectMapping("const _: f32 = undefined;", "f32");
    try expectMapping("const _: f64 = undefined;", "f64");
    try expectMapping("const _: bool = undefined;", "bool");
    try expectMapping("const _: void = undefined;", "void");
    try expectMapping("const _: usize = undefined;", "usize");
}

test "[]const u8 maps to String" {
    try expectMapping("const _: []const u8 = undefined;", "String");
}

test "?T maps to NullUnion(T)" {
    try expectMapping("const _: ?i32 = undefined;", "NullUnion(i32)");
    try expectMapping("const _: ?bool = undefined;", "NullUnion(bool)");
}

test "anyerror!T maps to ErrorUnion(T)" {
    try expectMapping("const _: anyerror!i32 = undefined;", "ErrorUnion(i32)");
    try expectMapping("const _: anyerror!void = undefined;", "ErrorUnion(void)");
}

test "*T maps to mut& T" {
    try expectMapping("const _: *i32 = undefined;", "mut& i32");
}

test "*const T maps to const& T" {
    try expectMapping("const _: *const i32 = undefined;", "const& i32");
}

test "user-defined types pass through" {
    try expectMapping("const _: MyStruct = undefined;", "MyStruct");
    try expectMapping("const _: SomeEnum = undefined;", "SomeEnum");
}

test "qualified names are unmappable" {
    try expectUnmappable("const _: std.mem.Allocator = undefined;");
}

test "non-u8 slices are unmappable" {
    try expectUnmappable("const _: []const i32 = undefined;");
    try expectUnmappable("const _: []u8 = undefined;");
}

test "nested types" {
    try expectMapping("const _: ?[]const u8 = undefined;", "NullUnion(String)");
    try expectMapping("const _: anyerror![]const u8 = undefined;", "ErrorUnion(String)");
    try expectMapping("const _: *const []const u8 = undefined;", "const& String");
}

// ---------------------------------------------------------------------------
// Declaration extraction tests
// ---------------------------------------------------------------------------

/// Helper: parse Zig source and run extractFn on the first root declaration.
fn testExtractFn(source: [:0]const u8) !?[]const u8 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return null;
    return try extractFn(&tree, root_decls[0], allocator);
}

/// Helper: parse Zig source and run extractConst on the first root declaration.
fn testExtractConst(source: [:0]const u8) !?[]const u8 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return null;
    return try extractConst(&tree, root_decls[0], allocator);
}

/// Helper: parse Zig source and run generateModule.
fn testGenerateModule(mod_name: []const u8, source: [:0]const u8) !?[]const u8 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    return try generateModule(mod_name, &tree, allocator);
}

test "extractFn — simple pub fn" {
    const result = try testExtractFn("pub fn add(a: i32, b: i32) i32 { return a + b; }");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub func add(a: i32, b: i32) i32", actual);
    } else return error.TestUnexpectedResult;
}

test "extractFn — pub fn with no params" {
    const result = try testExtractFn("pub fn init() void {}");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub func init() void", actual);
    } else return error.TestUnexpectedResult;
}

test "extractFn — non-pub fn skipped" {
    const result = try testExtractFn("fn helper() void {}");
    try std.testing.expect(result == null);
}

test "extractFn — comptime param mapped to compt" {
    const result = try testExtractFn("pub fn create(comptime T: type) void {}");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub func create(T: compt type) void", actual);
    } else return error.TestUnexpectedResult;
}

test "extractFn — anytype param mapped to any" {
    const result = try testExtractFn("pub fn print(value: anytype) void {}");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub func print(value: any) void", actual);
    } else return error.TestUnexpectedResult;
}

test "extractFn — unmappable param skips function" {
    // std.mem.Allocator is a qualified name → unmappable
    const result = try testExtractFn("pub fn create(alloc: std.mem.Allocator) void {}");
    try std.testing.expect(result == null);
}

test "extractFn — unmappable return type skips function" {
    const result = try testExtractFn("pub fn get() std.mem.Allocator {}");
    try std.testing.expect(result == null);
}

test "extractConst — string literal" {
    const result = try testExtractConst("pub const NAME = \"hello\";");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub const NAME: String", actual);
    } else return error.TestUnexpectedResult;
}

test "extractConst — number literal" {
    const result = try testExtractConst("pub const MAGIC = 42;");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub const MAGIC: i64", actual);
    } else return error.TestUnexpectedResult;
}

test "extractConst — non-pub const skipped" {
    const result = try testExtractConst("const PRIVATE = 42;");
    try std.testing.expect(result == null);
}

test "extractConst — pub const struct with methods" {
    const source =
        \\pub const SMP = struct {
        \\    pub fn create() SMP { return .{}; }
        \\    pub fn deinit(self: *SMP) void { _ = self; }
        \\};
    ;
    const result = try testExtractConst(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "pub struct SMP {\n    pub func create() SMP\n\n    pub func deinit(self: mut& SMP) void\n}",
            actual,
        );
    } else return error.TestUnexpectedResult;
}

test "extractConst — struct with const self" {
    const source =
        \\pub const Point = struct {
        \\    pub fn mag(self: *const Point) f64 { _ = self; return 0; }
        \\};
    ;
    const result = try testExtractConst(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "pub struct Point {\n    pub func mag(self: const& Point) f64\n}",
            actual,
        );
    } else return error.TestUnexpectedResult;
}

test "extractConst — struct with non-pub methods skipped" {
    const source =
        \\pub const Foo = struct {
        \\    fn helper() void {}
        \\};
    ;
    const result = try testExtractConst(source);
    // No pub methods → null
    try std.testing.expect(result == null);
}

test "generateModule — end-to-end" {
    const source =
        \\pub fn add(a: i32, b: i32) i32 { return a + b; }
        \\pub const MAGIC = 42;
        \\fn helper() void {}
    ;
    const result = try testGenerateModule("mylib", source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "module mylib\n\npub func add(a: i32, b: i32) i32\n\npub const MAGIC: i64\n\n",
            actual,
        );
    } else return error.TestUnexpectedResult;
}

test "generateModule — empty file returns null" {
    const result = try testGenerateModule("empty", "");
    try std.testing.expect(result == null);
}

test "generateModule — no pub declarations returns null" {
    const result = try testGenerateModule("priv", "fn helper() void {} const x = 5;");
    try std.testing.expect(result == null);
}
