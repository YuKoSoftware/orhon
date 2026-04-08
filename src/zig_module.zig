// zig_module.zig — Zig-to-Orhon automatic module converter
// Walks Zig AST (std.zig.Ast) to extract pub declarations and produce .orh module text.
// Self-contained: depends only on std.zig.Ast, no Orhon compiler modules.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const constants = @import("constants.zig");

/// Primitives that pass through unchanged from Zig to Orhon.
const PASSTHROUGH_PRIMITIVES = std.StaticStringMap(void).initComptime(.{
    .{ "u8", {} },  .{ "i8", {} },  .{ "i16", {} }, .{ "i32", {} }, .{ "i64", {} },
    .{ "u16", {} }, .{ "u32", {} }, .{ "u64", {} }, .{ "f32", {} }, .{ "f64", {} },
    .{ "bool", {} }, .{ "void", {} }, .{ "usize", {} },
});

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
/// `self_replacement` — when non-null, bare `Self` identifiers are replaced with this string
/// (e.g., "List(T)") for return types and non-self params of generic inner structs.
pub fn mapType(tree: *const Ast, node: Node.Index, allocator: Allocator, out: *TypeBuf) anyerror!bool {
    return mapTypeEx(tree, node, allocator, out, null);
}

fn mapTypeEx(tree: *const Ast, node: Node.Index, allocator: Allocator, out: *TypeBuf, self_replacement: ?[]const u8) anyerror!bool {
    const tag = tree.nodeTag(node);

    switch (tag) {
        // --- identifier: primitive passthrough or user-defined type ---
        .identifier => {
            const token = tree.nodeMainToken(node);
            const name = tree.tokenSlice(token);

            // Self → replacement (e.g., "List(T)") in generic inner struct context
            if (self_replacement) |replacement| {
                if (std.mem.eql(u8, name, "Self")) {
                    try out.append(allocator, replacement);
                    return true;
                }
            }

            // anytype → any
            if (std.mem.eql(u8, name, "anytype")) {
                try out.append(allocator, "any");
                return true;
            }

            // Check primitives
            if (PASSTHROUGH_PRIMITIVES.has(name)) {
                try out.append(allocator, name);
                return true;
            }

            // A bare identifier that isn't a primitive is a user-defined type.
            // Qualified names (std.mem.Allocator) are caught by field_access.
            try out.append(allocator, name);
            return true;
        },

        // --- ?T → (null | T) ---
        .optional_type => {
            const child = tree.nodeData(node).node;
            try out.append(allocator, "(null | ");
            const ok = try mapTypeEx(tree, child, allocator, out, self_replacement);
            if (!ok) return false;
            try out.append(allocator, ")");
            return true;
        },

        // --- lhs!rhs → (Error | rhs) ---
        // For `anyerror!T`, lhs is the error set, rhs is the payload type.
        .error_union => {
            const rhs = tree.nodeData(node).node_and_node[1];
            try out.append(allocator, "(Error | ");
            const ok = try mapTypeEx(tree, rhs, allocator, out, self_replacement);
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
                    // Check for []const u8 → str
                    if (is_const) {
                        if (tree.nodeTag(ptr_info.ast.child_type) == .identifier) {
                            const child_name = tree.tokenSlice(tree.nodeMainToken(ptr_info.ast.child_type));
                            if (std.mem.eql(u8, child_name, "u8")) {
                                try out.append(allocator, "str");
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
                    return try mapTypeEx(tree, ptr_info.ast.child_type, allocator, out, self_replacement);
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
/// `self_replacement` — when non-null, bare `Self` in return types/non-self params is replaced
/// (e.g., "List(T)"). Used for methods of generic inner structs.
fn extractFnInner(
    tree: *const Ast,
    node: Node.Index,
    struct_name: []const u8,
    prefix: []const u8,
    allocator: Allocator,
) anyerror!?[]const u8 {
    return extractFnInnerEx(tree, node, struct_name, prefix, allocator, null, false);
}

fn extractFnInnerEx(
    tree: *const Ast,
    node: Node.Index,
    struct_name: []const u8,
    prefix: []const u8,
    allocator: Allocator,
    self_replacement: ?[]const u8,
    allow_unmappable_as_any: bool,
) anyerror!?[]const u8 {
    var buf: [1]Node.Index = undefined;
    var proto = tree.fullFnProto(&buf, node) orelse return null;

    // Must be pub
    if (proto.visib_token == null) return null;

    // Skip extern and export functions — C ABI, not for Orhon
    if (proto.extern_export_inline_token) |t| {
        const tag = tree.tokenTag(t);
        if (tag == .keyword_extern or tag == .keyword_export) return null;
    }

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

        // Note: Zig `comptime` parameters are not emitted as `compt` here.
        // In Orhon, `type` as a parameter type already implies comptime semantics.

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
                } else if (allow_unmappable_as_any) {
                    try params.appendSlice(allocator, "any");
                } else {
                    return null;
                }
            } else {
                var type_buf: TypeBuf = .{};
                defer type_buf.deinit(allocator);
                const ok = try mapTypeEx(tree, type_node, allocator, &type_buf, self_replacement);
                if (!ok) {
                    if (allow_unmappable_as_any) {
                        // Discard any partial output from failed mapping
                        type_buf.buf.clearRetainingCapacity();
                        try params.appendSlice(allocator, "any");
                    } else {
                        return null;
                    }
                } else {
                    try params.appendSlice(allocator, type_buf.items());
                }
            }
        } else {
            return null;
        }
    }

    // Return type
    const ret_node = proto.ast.return_type.unwrap() orelse return null;
    var ret_buf: TypeBuf = .{};
    defer ret_buf.deinit(allocator);
    const ret_ok = try mapTypeEx(tree, ret_node, allocator, &ret_buf, self_replacement);
    if (!ret_ok) {
        if (allow_unmappable_as_any) {
            // Discard any partial output from failed mapping
            ret_buf.buf.clearRetainingCapacity();
            try ret_buf.append(allocator, "any");
        } else {
            return null;
        }
    }

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

/// Extracts a generic struct from a `pub fn Foo(comptime T: type) type { return struct { ... }; }` pattern.
/// Returns the Orhon `pub struct Foo(T: type) { ... }` string, or null if the pattern doesn't match.
pub fn extractGenericStruct(tree: *const Ast, node: Node.Index, allocator: Allocator) anyerror!?[]const u8 {
    const tag = tree.nodeTag(node);
    // Must be fn_decl (has a body), not just fn_proto
    if (tag != .fn_decl) return null;

    var buf: [1]Node.Index = undefined;
    var proto = tree.fullFnProto(&buf, node) orelse return null;

    // Must be pub
    if (proto.visib_token == null) return null;

    // Return type must be `type`
    const ret_node = proto.ast.return_type.unwrap() orelse return null;
    if (tree.nodeTag(ret_node) != .identifier) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(ret_node)), "type")) return null;

    // All params must be comptime type params (comptime T: type) or (comptime T: anytype)
    // Collect param names and types for the struct declaration
    var param_names: std.ArrayList([]const u8) = .{};
    defer param_names.deinit(allocator);
    var param_types: std.ArrayList([]const u8) = .{};
    defer param_types.deinit(allocator);

    var param_iter = proto.iterate(tree);
    while (param_iter.next()) |param| {
        // Must have a type expression
        const type_expr = param.type_expr orelse {
            if (param.anytype_ellipsis3 != null) {
                // anytype param (e.g., comptime flags: anytype)
                const pname = if (param.name_token) |nt| tree.tokenSlice(nt) else "_";
                try param_names.append(allocator, pname);
                try param_types.append(allocator, "any");
                continue;
            }
            return null;
        };
        // Check if type is `type` identifier
        if (tree.nodeTag(type_expr) == .identifier) {
            const type_name = tree.tokenSlice(tree.nodeMainToken(type_expr));
            if (std.mem.eql(u8, type_name, "type") or std.mem.eql(u8, type_name, "anytype")) {
                const pname = if (param.name_token) |nt| tree.tokenSlice(nt) else "_";
                try param_names.append(allocator, pname);
                try param_types.append(allocator, type_name);
                continue;
            }
        }
        // Not a comptime type param — not a generic struct pattern
        return null;
    }

    if (param_names.items.len == 0) return null;

    // Get function name
    const name_token = proto.name_token orelse return null;
    const fn_name = tree.tokenSlice(name_token);

    // Walk the function body to find `return struct { ... };`
    const body = tree.nodeData(node).node_and_node[1];
    const container_node = findReturnStruct(tree, body) orelse return null;

    // Verify it's a struct (not enum/union)
    const container_main = tree.nodeMainToken(container_node);
    if (tree.tokenTag(container_main) != .keyword_struct) return null;

    // Build the Self replacement string: "Name(T)" or "Name(K, V)"
    var self_rep: std.ArrayList(u8) = .{};
    defer self_rep.deinit(allocator);
    try self_rep.appendSlice(allocator, fn_name);
    try self_rep.append(allocator, '(');
    for (param_names.items, 0..) |pname, i| {
        if (i > 0) try self_rep.appendSlice(allocator, ", ");
        try self_rep.appendSlice(allocator, pname);
    }
    try self_rep.append(allocator, ')');
    const self_replacement = self_rep.items;

    // Build the type param string: "(T: type)" or "(K: type, V: type)"
    var type_params: std.ArrayList(u8) = .{};
    defer type_params.deinit(allocator);
    try type_params.append(allocator, '(');
    for (param_names.items, param_types.items, 0..) |pname, ptype, i| {
        if (i > 0) try type_params.appendSlice(allocator, ", ");
        try type_params.appendSlice(allocator, pname);
        try type_params.appendSlice(allocator, ": ");
        try type_params.appendSlice(allocator, ptype);
    }
    try type_params.append(allocator, ')');

    // Extract inner struct members
    var container_buf: [2]Node.Index = undefined;
    const container = tree.fullContainerDecl(&container_buf, container_node) orelse return null;

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "pub struct ");
    try result.appendSlice(allocator, fn_name);
    try result.appendSlice(allocator, type_params.items);
    try result.appendSlice(allocator, " {\n");

    var has_members = false;
    for (container.ast.members) |member| {
        const member_tag = tree.nodeTag(member);
        // Only handle fn_decl and fn_proto variants
        if (member_tag == .fn_decl or member_tag == .fn_proto or
            member_tag == .fn_proto_multi or member_tag == .fn_proto_one or
            member_tag == .fn_proto_simple)
        {
            if (try extractFnInnerEx(tree, member, fn_name, "    pub func ", allocator, self_replacement, true)) |sig| {
                defer allocator.free(sig);
                if (has_members) try result.append(allocator, '\n');
                try result.appendSlice(allocator, sig);
                try result.append(allocator, '\n');
                has_members = true;
            }
        }
        // Skip const Self = @This(), nested types, fields — all implementation details
    }

    try result.append(allocator, '}');

    if (!has_members) {
        result.deinit(allocator);
        return null;
    }

    return try result.toOwnedSlice(allocator);
}

/// Walks a function body block to find a `return struct { ... };` statement.
/// Returns the container_decl node index, or null if not found.
fn findReturnStruct(tree: *const Ast, body: Node.Index) ?Node.Index {
    const tag = tree.nodeTag(body);
    switch (tag) {
        .block_two_semicolon, .block_two => {
            const data = tree.nodeData(body);
            inline for (data.opt_node_and_opt_node) |opt| {
                if (opt.unwrap()) |s| {
                    if (tree.nodeTag(s) == .@"return") {
                        if (tree.nodeData(s).opt_node.unwrap()) |ret_expr| {
                            if (isContainerDecl(tree.nodeTag(ret_expr))) return ret_expr;
                        }
                    }
                }
            }
        },
        .block, .block_semicolon => {
            const data = tree.nodeData(body);
            const range = data.extra_range;
            const start = @intFromEnum(range.start);
            const end = @intFromEnum(range.end);
            for (start..end) |idx| {
                const s: Node.Index = @enumFromInt(tree.extra_data[idx]);
                if (tree.nodeTag(s) == .@"return") {
                    if (tree.nodeData(s).opt_node.unwrap()) |ret_expr| {
                        if (isContainerDecl(tree.nodeTag(ret_expr))) return ret_expr;
                    }
                }
            }
        },
        else => {},
    }
    return null;
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
            // Check if child type is our struct name or Self (inner anonymous structs use const Self = @This())
            if (tree.nodeTag(ptr_info.ast.child_type) == .identifier) {
                const child_name = tree.tokenSlice(tree.nodeMainToken(ptr_info.ast.child_type));
                if (std.mem.eql(u8, child_name, struct_name) or std.mem.eql(u8, child_name, "Self")) {
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

    // Bare Self (non-pointer) → struct name
    if (tag == .identifier) {
        const name = tree.tokenSlice(tree.nodeMainToken(type_node));
        if (std.mem.eql(u8, name, "Self")) {
            return try allocator.dupe(u8, struct_name);
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

    // String literal → str type with value
    if (init_tag == .string_literal or init_tag == .multiline_string_literal) {
        const value = tree.tokenSlice(tree.nodeMainToken(init_node));
        return try std.fmt.allocPrint(allocator, "pub const {s}: str = {s}", .{ name, value });
    }

    // Number literal → i64 type with value
    if (init_tag == .number_literal) {
        const value = tree.tokenSlice(tree.nodeMainToken(init_node));
        return try std.fmt.allocPrint(allocator, "pub const {s}: i64 = {s}", .{ name, value });
    }

    // Negation of number literal → i64 type with value
    if (init_tag == .negation) {
        const operand = tree.nodeData(init_node).node;
        if (tree.nodeTag(operand) == .number_literal) {
            const value = tree.tokenSlice(tree.nodeMainToken(operand));
            return try std.fmt.allocPrint(allocator, "pub const {s}: i64 = -{s}", .{ name, value });
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
            // Function declarations — try generic struct extraction first, fall back to plain fn
            .fn_decl, .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => try extractGenericStruct(tree, decl_node, allocator) orelse try extractFn(tree, decl_node, allocator),

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

/// Scans Zig source text for @import("sibling.zig") patterns where sibling
/// is another .zig file in the same directory. Returns owned slice of module names.
fn scanZigImports(source: []const u8, source_dir: []const u8, allocator: Allocator) ![][]const u8 {
    var imports: std.ArrayList([]const u8) = .{};
    errdefer {
        for (imports.items) |item| allocator.free(item);
        imports.deinit(allocator);
    }

    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    var pos: usize = 0;
    while (pos < source.len) {
        const needle = "@import(\"";
        const idx = std.mem.indexOfPos(u8, source, pos, needle) orelse break;
        const start = idx + needle.len;
        const end = std.mem.indexOfPos(u8, source, start, "\"") orelse break;
        const import_path = source[start..end];
        pos = end + 1;

        if (!std.mem.endsWith(u8, import_path, ".zig")) continue;
        if (std.mem.indexOf(u8, import_path, "/") != null) continue;

        const mod_name = import_path[0 .. import_path.len - 4];

        if (std.mem.eql(u8, mod_name, "std")) continue;
        if (seen.contains(mod_name)) continue;

        const sibling_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ source_dir, import_path }) catch continue;
        defer allocator.free(sibling_path);
        std.fs.cwd().access(sibling_path, .{}) catch continue;

        try seen.put(allocator, mod_name, {});
        try imports.append(allocator, try allocator.dupe(u8, mod_name));
    }

    return imports.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// File discovery and cache writing
// ---------------------------------------------------------------------------

/// A discovered .zig file with its relative path and derived module name.
pub const ZigModuleEntry = struct {
    file_path: []const u8, // relative path: "src/mylib.zig"
    module_name: []const u8, // stem: "mylib"
};

/// Recursively discovers .zig files in `source_dir`, skipping underscore-prefixed files.
/// Returns an owned slice of ZigModuleEntry. Caller owns all strings and the slice.
pub fn discoverZigFiles(allocator: Allocator, source_dir: []const u8) ![]ZigModuleEntry {
    var entries: std.ArrayList(ZigModuleEntry) = .{};
    errdefer {
        for (entries.items) |entry| {
            allocator.free(entry.file_path);
            allocator.free(entry.module_name);
        }
        entries.deinit(allocator);
    }

    var dir = std.fs.cwd().openDir(source_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try entries.toOwnedSlice(allocator),
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const basename = std.fs.path.basename(entry.path);

        // Skip non-.zig files
        if (!std.mem.endsWith(u8, basename, ".zig")) continue;

        // Skip underscore-prefixed files
        if (basename[0] == '_') continue;

        // Module name = filename stem
        const stem = basename[0 .. basename.len - 4];

        // Build the full relative path: source_dir/entry.path
        const file_path = try std.fs.path.join(allocator, &.{ source_dir, entry.path });
        errdefer allocator.free(file_path);

        const module_name = try allocator.dupe(u8, stem);

        try entries.append(allocator, .{
            .file_path = file_path,
            .module_name = module_name,
        });
    }

    return try entries.toOwnedSlice(allocator);
}

/// A successfully converted zig module with its name and optional .zon build config.
pub const ConvertedModule = struct {
    name: []const u8,
    config: ZonConfig,

    pub fn deinit(self: *const ConvertedModule, allocator: Allocator) void {
        allocator.free(self.name);
        self.config.deinit(allocator);
    }
};

/// C/C++ source file extensions recognised during auto-detection.
const C_SOURCE_EXTENSIONS = [_][]const u8{ ".c", ".cpp", ".cc", ".cxx" };

/// Discovers .zig files in `source_dir`, converts each to .orh, writes to `output_dir`.
/// If `output_dir` is null, defaults to `cache.ZIG_MODULES_DIR`.
/// For each converted module, reads a paired `.zon` config (if present) and auto-detects
/// adjacent C/C++ source files.
/// Returns an owned slice of ConvertedModule. Caller owns the slice and all inner allocations.
pub fn discoverAndConvert(allocator: Allocator, source_dir: []const u8, output_dir: ?[]const u8) ![]ConvertedModule {
    const entries = try discoverZigFiles(allocator, source_dir);
    defer {
        for (entries) |entry| {
            allocator.free(entry.file_path);
            allocator.free(entry.module_name);
        }
        allocator.free(entries);
    }

    const out_dir = output_dir orelse cache.ZIG_MODULES_DIR;

    // Ensure output directory exists
    std.fs.cwd().makePath(out_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var converted: std.ArrayList(ConvertedModule) = .{};
    errdefer {
        for (converted.items) |*cm| cm.deinit(allocator);
        converted.deinit(allocator);
    }

    for (entries) |entry| {
        // Read the .zig file
        const source_bytes = std.fs.cwd().readFileAlloc(allocator, entry.file_path, 10 * 1024 * 1024) catch continue;
        defer allocator.free(source_bytes);

        // Add sentinel for Ast.parse
        const source_z = allocator.dupeZ(u8, source_bytes) catch continue;
        defer allocator.free(source_z);

        // Parse the Zig AST
        var tree = std.zig.Ast.parse(allocator, source_z, .zig) catch continue;
        defer tree.deinit(allocator);

        // Generate the .orh module text
        const orh_text = generateModule(entry.module_name, &tree, allocator) catch continue orelse continue;
        defer allocator.free(orh_text);

        // Scan for sibling @import("x.zig") references
        const zig_imports = scanZigImports(source_bytes, source_dir, allocator) catch &.{};
        defer {
            for (zig_imports) |imp| allocator.free(imp);
            if (zig_imports.len > 0) allocator.free(zig_imports);
        }

        // If there are sibling imports, inject import declarations after module header
        const final_orh = if (zig_imports.len > 0) blk: {
            var combined: std.ArrayList(u8) = .{};
            errdefer combined.deinit(allocator);

            const newline = std.mem.indexOf(u8, orh_text, "\n") orelse orh_text.len;
            try combined.appendSlice(allocator, orh_text[0 .. newline + 1]);

            for (zig_imports) |imp| {
                try combined.appendSlice(allocator, "import ");
                try combined.appendSlice(allocator, imp);
                try combined.appendSlice(allocator, "\n");
            }

            try combined.appendSlice(allocator, orh_text[newline + 1 ..]);
            break :blk try combined.toOwnedSlice(allocator);
        } else orh_text;
        defer if (zig_imports.len > 0) allocator.free(final_orh);

        // Write to output directory
        const out_filename = std.fmt.allocPrint(allocator, "{s}/{s}.orh", .{ out_dir, entry.module_name }) catch continue;
        defer allocator.free(out_filename);

        const out_file = std.fs.cwd().createFile(out_filename, .{}) catch continue;
        defer out_file.close();
        out_file.writeAll(final_orh) catch continue;

        // Read paired .zon config (replace .zig extension with .zon)
        var config = readZonForZigFile(allocator, entry.file_path) catch ZonConfig{};

        // Auto-detect adjacent C/C++ source files and merge into config
        mergeAdjacentCSources(allocator, entry.file_path, &config) catch {};

        // Track the converted module
        const name_copy = allocator.dupe(u8, entry.module_name) catch continue;
        converted.append(allocator, .{
            .name = name_copy,
            .config = config,
        }) catch {
            allocator.free(name_copy);
            config.deinit(allocator);
            continue;
        };
    }

    return try converted.toOwnedSlice(allocator);
}

/// Reads a `.zon` file paired with a `.zig` file (same directory, same stem).
/// Returns a default empty config if no `.zon` file exists.
fn readZonForZigFile(allocator: Allocator, zig_path: []const u8) !ZonConfig {
    // Replace .zig extension with .zon
    if (!std.mem.endsWith(u8, zig_path, ".zig")) return .{};
    const stem = zig_path[0 .. zig_path.len - 4];
    const zon_path = try std.fmt.allocPrint(allocator, "{s}.zon", .{stem});
    defer allocator.free(zon_path);

    const zon_bytes = std.fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024) catch return .{};
    defer allocator.free(zon_bytes);

    const zon_z = try allocator.dupeZ(u8, zon_bytes);
    defer allocator.free(zon_z);

    return try parseZonConfig(allocator, zon_z);
}

/// Scans the directory containing `zig_path` for C/C++ source files and merges
/// any found into `config.source`, avoiding duplicates.
fn mergeAdjacentCSources(allocator: Allocator, zig_path: []const u8, config: *ZonConfig) !void {
    const dir_path = std.fs.path.dirname(zig_path) orelse ".";

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var new_sources: std.ArrayListUnmanaged([]const u8) = .{};
    defer new_sources.deinit(allocator);

    // Copy existing sources to the new list
    for (config.source) |s| {
        try new_sources.append(allocator, s);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;

        const is_c_source = for (C_SOURCE_EXTENSIONS) |ext| {
            if (std.mem.endsWith(u8, name, ext)) break true;
        } else false;
        if (!is_c_source) continue;

        // Build path relative to project root (dir_path/filename)
        const full_path = try std.fs.path.join(allocator, &.{ dir_path, name });

        // Check for duplicate
        var already = false;
        for (new_sources.items) |existing| {
            if (std.mem.eql(u8, existing, full_path)) {
                already = true;
                break;
            }
        }
        if (already) {
            allocator.free(full_path);
            continue;
        }

        try new_sources.append(allocator, full_path);
    }

    // Only replace if we added new entries
    if (new_sources.items.len > config.source.len) {
        // Free the old slice (but not the individual strings — they are now in new_sources)
        if (config.source.len > 0) allocator.free(config.source);
        config.source = try new_sources.toOwnedSlice(allocator);
    }
}

// ---------------------------------------------------------------------------
// .zon build config parsing
// ---------------------------------------------------------------------------

/// Per-module build configuration parsed from a `.zon` file.
/// All fields are optional — an empty `.zon` file produces all-empty slices.
pub const ZonConfig = struct {
    link: []const []const u8 = &.{},
    include: []const []const u8 = &.{},
    source: []const []const u8 = &.{},
    define: []const []const u8 = &.{},

    pub fn deinit(self: *const ZonConfig, allocator: Allocator) void {
        inline for (.{ self.link, self.include, self.source, self.define }) |slice| {
            for (slice) |s| allocator.free(s);
            allocator.free(slice);
        }
    }
};

/// Parse a `.zon` source string and extract build configuration fields.
/// Unknown fields are silently ignored. On parse error, returns an empty default config.
pub fn parseZonConfig(allocator: Allocator, zon_source: [:0]const u8) !ZonConfig {
    var tree = Ast.parse(allocator, zon_source, .zon) catch return .{};
    defer tree.deinit(allocator);

    if (tree.errors.len > 0) return .{};

    const root_nodes = tree.rootDecls();
    if (root_nodes.len == 0) return .{};

    const root_node = root_nodes[0];
    var buf: [2]Ast.Node.Index = undefined;
    const si = tree.fullStructInit(&buf, root_node) orelse return .{};

    var config: ZonConfig = .{};
    errdefer config.deinit(allocator);

    for (si.ast.fields) |field| {
        // Field name is the identifier token 3 positions before the value's main token.
        // Token layout: . identifier = . { (main_tok)
        //               -4   -3      -2 -1  0
        const fmain = tree.nodeMainToken(field);
        if (fmain < 3) continue;
        const name_tok = fmain - 3;
        if (tree.tokenTag(name_tok) != .identifier) continue;
        const name = tree.tokenSlice(name_tok);

        if (std.mem.eql(u8, name, "link")) {
            config.link = extractStringTuple(allocator, &tree, field) catch continue;
        } else if (std.mem.eql(u8, name, "include")) {
            config.include = extractStringTuple(allocator, &tree, field) catch continue;
        } else if (std.mem.eql(u8, name, "source")) {
            config.source = extractStringTuple(allocator, &tree, field) catch continue;
        } else if (std.mem.eql(u8, name, "define")) {
            config.define = extractStringTuple(allocator, &tree, field) catch continue;
        }
        // Unknown fields: silently ignored
    }

    return config;
}

/// Extract string literals from a `.zon` tuple expression: `.{ "a", "b" }` → `["a", "b"]`.
/// String literals in the AST include quotes; this function strips them.
fn extractStringTuple(allocator: Allocator, tree: *const Ast, node: Ast.Node.Index) ![]const []const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const ai = tree.fullArrayInit(&buf, node) orelse return &.{};

    var strings: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (strings.items) |s| allocator.free(s);
        strings.deinit(allocator);
    }

    for (ai.ast.elements) |elem| {
        if (tree.nodeTag(elem) != .string_literal) continue;
        const raw = tree.tokenSlice(tree.nodeMainToken(elem));
        const stripped = constants.stripQuotes(raw);
        if (stripped.len != raw.len) {
            try strings.append(allocator, try allocator.dupe(u8, stripped));
        }
    }

    return try strings.toOwnedSlice(allocator);
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

test "[]const u8 maps to str" {
    try expectMapping("const _: []const u8 = undefined;", "str");
}

test "?T maps to (null | T)" {
    try expectMapping("const _: ?i32 = undefined;", "(null | i32)");
    try expectMapping("const _: ?bool = undefined;", "(null | bool)");
}

test "anyerror!T maps to (Error | T)" {
    try expectMapping("const _: anyerror!i32 = undefined;", "(Error | i32)");
    try expectMapping("const _: anyerror!void = undefined;", "(Error | void)");
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
    try expectMapping("const _: ?[]const u8 = undefined;", "(null | str)");
    try expectMapping("const _: anyerror![]const u8 = undefined;", "(Error | str)");
    try expectMapping("const _: *const []const u8 = undefined;", "const& str");
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

test "extractFn — extern fn skipped" {
    const result = try testExtractFn("pub extern \"c\" fn ext() void;");
    try std.testing.expect(result == null);
}

test "extractFn — export fn skipped" {
    const result = try testExtractFn("pub export fn exp() void {}");
    try std.testing.expect(result == null);
}

test "extractFn — comptime param (type implies comptime)" {
    const result = try testExtractFn("pub fn create(comptime T: type) void {}");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub func create(T: type) void", actual);
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
        try std.testing.expectEqualStrings("pub const NAME: str = \"hello\"", actual);
    } else return error.TestUnexpectedResult;
}

test "extractConst — number literal" {
    const result = try testExtractConst("pub const MAGIC = 42;");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub const MAGIC: i64 = 42", actual);
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

test "extractConst — negated number literal" {
    const result = try testExtractConst("pub const NEG = -99;");
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings("pub const NEG: i64 = -99", actual);
    } else return error.TestUnexpectedResult;
}

test "extractConst — pub var skipped" {
    const result = try testExtractConst("pub var X: i32 = 42;");
    try std.testing.expect(result == null);
}

test "extractConst — enum skipped" {
    const result = try testExtractConst("pub const E = enum { a, b, c };");
    try std.testing.expect(result == null);
}

/// Helper: parse Zig source and run extractGenericStruct on the first root declaration.
fn testExtractGeneric(source: [:0]const u8) !?[]const u8 {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const root_decls = tree.rootDecls();
    if (root_decls.len == 0) return null;
    return try extractGenericStruct(&tree, root_decls[0], allocator);
}

test "extractGenericStruct — simple single type param" {
    const source =
        \\pub fn Wrapper(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub fn new() Self { return .{}; }
        \\        pub fn get(self: *const Self) T { _ = self; return undefined; }
        \\    };
        \\}
    ;
    const result = try testExtractGeneric(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "pub struct Wrapper(T: type) {\n    pub func new() Wrapper(T)\n\n    pub func get(self: const& Wrapper) T\n}",
            actual,
        );
    } else return error.TestUnexpectedResult;
}

test "extractGenericStruct — multi type param" {
    const source =
        \\pub fn Pair(comptime K: type, comptime V: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub fn create(key: K, val: V) Self { _ = key; _ = val; return .{}; }
        \\    };
        \\}
    ;
    const result = try testExtractGeneric(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "pub struct Pair(K: type, V: type) {\n    pub func create(key: K, val: V) Pair(K, V)\n}",
            actual,
        );
    } else return error.TestUnexpectedResult;
}

test "extractGenericStruct — non-pub skipped" {
    const source =
        \\fn Hidden(comptime T: type) type {
        \\    return struct { pub fn new() T { return undefined; } };
        \\}
    ;
    const result = try testExtractGeneric(source);
    try std.testing.expect(result == null);
}

test "extractGenericStruct — non-type return skipped" {
    const source =
        \\pub fn helper(comptime T: type) i32 {
        \\    return 42;
        \\}
    ;
    const result = try testExtractGeneric(source);
    try std.testing.expect(result == null);
}

test "extractGenericStruct — bare Self param" {
    const source =
        \\pub fn Box(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        pub fn has(self: Self, f: u32) bool { _ = self; _ = f; return false; }
        \\    };
        \\}
    ;
    const result = try testExtractGeneric(source);
    if (result) |actual| {
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(
            "pub struct Box(T: type) {\n    pub func has(self: Box, f: u32) bool\n}",
            actual,
        );
    } else return error.TestUnexpectedResult;
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
            "module mylib\n\npub func add(a: i32, b: i32) i32\n\npub const MAGIC: i64 = 42\n\n",
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

// ---------------------------------------------------------------------------
// File discovery tests
// ---------------------------------------------------------------------------

test "discoverZigFiles — skips underscore-prefixed files" {
    const allocator = std.testing.allocator;

    // Create a temp directory with test files
    const tmp_dir = "/tmp/orhon_test_discover";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create test .zig files
    {
        const f1 = try std.fs.cwd().createFile(tmp_dir ++ "/mylib.zig", .{});
        defer f1.close();
        try f1.writeAll("pub fn add(a: i32, b: i32) i32 { return a + b; }");
    }
    {
        const f2 = try std.fs.cwd().createFile(tmp_dir ++ "/_private.zig", .{});
        defer f2.close();
        try f2.writeAll("fn secret() void {}");
    }
    {
        const f3 = try std.fs.cwd().createFile(tmp_dir ++ "/utils.zig", .{});
        defer f3.close();
        try f3.writeAll("pub fn helper() void {}");
    }

    const entries = try discoverZigFiles(allocator, tmp_dir);
    defer {
        for (entries) |entry| {
            allocator.free(entry.file_path);
            allocator.free(entry.module_name);
        }
        allocator.free(entries);
    }

    // Should have 2 entries (mylib, utils), not _private
    try std.testing.expectEqual(@as(usize, 2), entries.len);

    // Verify no underscore-prefixed files
    for (entries) |entry| {
        try std.testing.expect(entry.module_name[0] != '_');
    }
}

test "discoverZigFiles — nonexistent directory returns empty" {
    const allocator = std.testing.allocator;
    const entries = try discoverZigFiles(allocator, "/tmp/orhon_test_nonexistent_dir_xyz");
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "discoverAndConvert — end-to-end" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/orhon_test_convert";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create a .zig file with pub declarations
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/testmod.zig", .{});
        defer f.close();
        try f.writeAll("pub fn greet(name: []const u8) void { _ = name; }");
    }

    // Clean up any previous output
    std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};
    defer std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};

    const modules = try discoverAndConvert(allocator, tmp_dir, null);
    defer {
        for (modules) |*cm| cm.deinit(allocator);
        allocator.free(modules);
    }

    try std.testing.expectEqual(@as(usize, 1), modules.len);
    try std.testing.expectEqualStrings("testmod", modules[0].name);

    // Verify the .orh file was written
    const orh_path = cache.ZIG_MODULES_DIR ++ "/testmod.orh";
    const content = try std.fs.cwd().readFileAlloc(allocator, orh_path, 1024 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.startsWith(u8, content, "module testmod\n"));
}

test "discoverAndConvert — reads paired .zon config" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/orhon_test_zon_pair";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create a .zig file
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/mylib.zig", .{});
        defer f.close();
        try f.writeAll("pub fn init() void {}");
    }
    // Create a paired .zon config
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/mylib.zon", .{});
        defer f.close();
        try f.writeAll(".{\n    .link = .{ \"SDL2\" },\n    .include = .{ \"vendor/\" },\n}");
    }

    std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};
    defer std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};

    const modules = try discoverAndConvert(allocator, tmp_dir, null);
    defer {
        for (modules) |*cm| cm.deinit(allocator);
        allocator.free(modules);
    }

    try std.testing.expectEqual(@as(usize, 1), modules.len);
    try std.testing.expectEqualStrings("mylib", modules[0].name);
    try std.testing.expectEqual(@as(usize, 1), modules[0].config.link.len);
    try std.testing.expectEqualStrings("SDL2", modules[0].config.link[0]);
    try std.testing.expectEqual(@as(usize, 1), modules[0].config.include.len);
    try std.testing.expectEqualStrings("vendor/", modules[0].config.include[0]);
}

test "discoverAndConvert — auto-detects adjacent C files" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/orhon_test_c_detect";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create a .zig file
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/native.zig", .{});
        defer f.close();
        try f.writeAll("pub fn run() void {}");
    }
    // Create adjacent C/C++ files
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/helper.c", .{});
        defer f.close();
        try f.writeAll("void helper() {}");
    }
    {
        const f = try std.fs.cwd().createFile(tmp_dir ++ "/bridge.cpp", .{});
        defer f.close();
        try f.writeAll("void bridge() {}");
    }

    std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};
    defer std.fs.cwd().deleteTree(cache.ZIG_MODULES_DIR) catch {};

    const modules = try discoverAndConvert(allocator, tmp_dir, null);
    defer {
        for (modules) |*cm| cm.deinit(allocator);
        allocator.free(modules);
    }

    try std.testing.expectEqual(@as(usize, 1), modules.len);
    // Should have auto-detected 2 C/C++ source files
    try std.testing.expectEqual(@as(usize, 2), modules[0].config.source.len);
    // Verify both files are found (order may vary)
    var found_c = false;
    var found_cpp = false;
    for (modules[0].config.source) |src| {
        if (std.mem.endsWith(u8, src, "helper.c")) found_c = true;
        if (std.mem.endsWith(u8, src, "bridge.cpp")) found_cpp = true;
    }
    try std.testing.expect(found_c);
    try std.testing.expect(found_cpp);
}

// ---------------------------------------------------------------------------
// .zon config tests
// ---------------------------------------------------------------------------

test "parseZonConfig — full config with all fields" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "SDL2", "openssl" },
        \\    .include = .{ "vendor/", "/usr/include" },
        \\    .source = .{ "vendor/stb.c" },
        \\    .define = .{ "SDL_MAIN_HANDLED", "USE_OPENSSL" },
        \\}
    ;
    const config = try parseZonConfig(allocator, source);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.link.len);
    try std.testing.expectEqualStrings("SDL2", config.link[0]);
    try std.testing.expectEqualStrings("openssl", config.link[1]);

    try std.testing.expectEqual(@as(usize, 2), config.include.len);
    try std.testing.expectEqualStrings("vendor/", config.include[0]);
    try std.testing.expectEqualStrings("/usr/include", config.include[1]);

    try std.testing.expectEqual(@as(usize, 1), config.source.len);
    try std.testing.expectEqualStrings("vendor/stb.c", config.source[0]);

    try std.testing.expectEqual(@as(usize, 2), config.define.len);
    try std.testing.expectEqualStrings("SDL_MAIN_HANDLED", config.define[0]);
    try std.testing.expectEqualStrings("USE_OPENSSL", config.define[1]);
}

test "parseZonConfig — empty config" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 = ".{}";
    const config = try parseZonConfig(allocator, source);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), config.link.len);
    try std.testing.expectEqual(@as(usize, 0), config.include.len);
    try std.testing.expectEqual(@as(usize, 0), config.source.len);
    try std.testing.expectEqual(@as(usize, 0), config.define.len);
}

test "parseZonConfig — partial config (only link)" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "z", "pthread" },
        \\}
    ;
    const config = try parseZonConfig(allocator, source);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.link.len);
    try std.testing.expectEqualStrings("z", config.link[0]);
    try std.testing.expectEqualStrings("pthread", config.link[1]);
    try std.testing.expectEqual(@as(usize, 0), config.include.len);
    try std.testing.expectEqual(@as(usize, 0), config.source.len);
    try std.testing.expectEqual(@as(usize, 0), config.define.len);
}

test "parseZonConfig — unknown fields ignored" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "SDL2" },
        \\    .unknown = .{ "ignored" },
        \\    .define = .{ "FOO" },
        \\}
    ;
    const config = try parseZonConfig(allocator, source);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.link.len);
    try std.testing.expectEqualStrings("SDL2", config.link[0]);
    try std.testing.expectEqual(@as(usize, 1), config.define.len);
    try std.testing.expectEqualStrings("FOO", config.define[0]);
    try std.testing.expectEqual(@as(usize, 0), config.include.len);
    try std.testing.expectEqual(@as(usize, 0), config.source.len);
}

test "parseZonConfig — single-element tuple" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "one" },
        \\}
    ;
    const config = try parseZonConfig(allocator, source);
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), config.link.len);
    try std.testing.expectEqualStrings("one", config.link[0]);
}
