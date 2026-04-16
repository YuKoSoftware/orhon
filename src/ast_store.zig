// ast_store.zig — index-based struct-of-arrays AST store (Phase A scaffold)
// No population yet; types and helpers only.

const std = @import("std");
const StringPool = @import("string_pool.zig").StringPool;

pub const StringIndex = @import("string_pool.zig").StringIndex;

// ---------------------------------------------------------------------------
// Index types — all enum(u32) with none=0 sentinel
// ---------------------------------------------------------------------------

pub const AstNodeIndex = enum(u32) { none = 0, _ };
pub const ExtraIndex = enum(u32) { none = 0, _ };
pub const TokenIndex = enum(u32) { none = 0, _ };

// Source span index (into a SourceMap, owned by pipeline — not stored here)
pub const SourceSpanIndex = enum(u32) { none = 0, _ };

// ---------------------------------------------------------------------------
// AstKind — mirrors NodeKind from parser.zig exactly
// ---------------------------------------------------------------------------

pub const AstKind = enum {
    program,
    module_decl,
    import_decl,
    metadata,
    func_decl,
    struct_decl,
    blueprint_decl,
    enum_decl,
    handle_decl,
    var_decl,
    destruct_decl,
    test_decl,
    field_decl,
    enum_variant,
    param,
    block,
    return_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    defer_stmt,
    match_stmt,
    match_arm,
    break_stmt,
    continue_stmt,
    assignment,
    binary_expr,
    unary_expr,
    call_expr,
    index_expr,
    slice_expr,
    field_expr,
    mut_borrow_expr,
    const_borrow_expr,
    compiler_func,
    identifier,
    int_literal,
    float_literal,
    string_literal,
    bool_literal,
    null_literal,
    array_literal,
    tuple_literal,
    version_literal,
    error_literal,
    range_expr,
    interpolated_string,
    type_slice,
    type_array,
    type_ptr,
    type_union,
    type_tuple_named,
    type_func,
    type_generic,
    type_named,
    struct_type,
};

// ---------------------------------------------------------------------------
// Data — covers all node storage patterns
// ---------------------------------------------------------------------------

pub const Data = union(enum) {
    none: void,
    node: AstNodeIndex,
    two_nodes: struct { lhs: AstNodeIndex, rhs: AstNodeIndex },
    node_and_extra: struct { node: AstNodeIndex, extra: ExtraIndex },
    extra: ExtraIndex,
    str_and_node: struct { str: StringIndex, node: AstNodeIndex },
    str: StringIndex,
    token: TokenIndex,
    bool_val: bool,
    str_and_extra: struct { str: StringIndex, extra: ExtraIndex },
};

pub const AstNode = struct {
    tag: AstKind,
    span: SourceSpanIndex,
    data: Data,
};

// ---------------------------------------------------------------------------
// AstStore
// ---------------------------------------------------------------------------

pub const AstStore = struct {
    nodes: std.MultiArrayList(AstNode),
    extra_data: std.ArrayListUnmanaged(u32),
    strings: StringPool,

    pub fn init() AstStore {
        return .{
            .nodes = .{},
            .extra_data = .{},
            .strings = StringPool.init(),
        };
    }

    pub fn deinit(store: *AstStore, allocator: std.mem.Allocator) void {
        store.nodes.deinit(allocator);
        store.extra_data.deinit(allocator);
        store.strings.deinit(allocator);
    }

    // Append a node; returns its index. Real nodes start at 1 (index 0 = none).
    // The caller is responsible for ensuring index 0 is never used as a real node.
    // appendNode returns @enumFromInt(len_before_append + 1) by occupying slot
    // len_before_append; since we initialise no dummy node, the first append
    // returns index 1.  We simply reserve 0 by treating it as the sentinel and
    // starting real indices at 1: append the node, then return
    // @enumFromInt(nodes.len) which equals (old_len + 1) = new last index.
    pub fn appendNode(store: *AstStore, allocator: std.mem.Allocator, node: AstNode) !AstNodeIndex {
        // Before appending, current len equals the index the new node will have
        // after the append (1-based: first real node → index 1, so we ensure
        // the first append results in index 1 by skipping index 0).
        // Strategy: reserve slot 0 lazily on the very first append.
        if (store.nodes.len == 0) {
            // Slot 0 is the none sentinel — never a real node. .tag = .program
            // here is an arbitrary placeholder; this slot must never be accessed
            // through the public API (getNode asserts idx != .none).
            try store.nodes.append(allocator, .{
                .tag = .program,
                .span = .none,
                .data = .none,
            });
        }
        // Now nodes.len >= 1; the new node will occupy index nodes.len.
        const idx: AstNodeIndex = @enumFromInt(store.nodes.len);
        try store.nodes.append(allocator, node);
        return idx;
    }

    pub fn getNode(store: *const AstStore, idx: AstNodeIndex) AstNode {
        std.debug.assert(idx != .none);
        return store.nodes.get(@intFromEnum(idx));
    }

    // Append a packed extra record; T must have all u32-sized fields.
    // Returns the ExtraIndex of the first word appended.
    pub fn appendExtra(store: *AstStore, allocator: std.mem.Allocator, value: anytype) !ExtraIndex {
        const T = @TypeOf(value);
        const idx: ExtraIndex = @enumFromInt(store.extra_data.items.len);
        // Encode each field as a u32 word.
        const fields = @typeInfo(T).@"struct".fields;
        comptime std.debug.assert(@sizeOf(T) == fields.len * @sizeOf(u32));
        inline for (fields) |f| {
            const field_val = @field(value, f.name);
            const as_u32: u32 = switch (@typeInfo(f.type)) {
                .@"enum" => @intFromEnum(field_val),
                .int => @intCast(field_val),
                else => @bitCast(field_val),
            };
            try store.extra_data.append(allocator, as_u32);
        }
        return idx;
    }

    // Read an extra record back.
    pub fn extraData(store: *const AstStore, comptime T: type, idx: ExtraIndex) T {
        const raw_idx = @intFromEnum(idx);
        const fields = @typeInfo(T).@"struct".fields;
        var result: T = undefined;
        inline for (fields, 0..) |f, i| {
            const word = store.extra_data.items[raw_idx + i];
            @field(result, f.name) = switch (@typeInfo(f.type)) {
                .@"enum" => @enumFromInt(word),
                .int => @intCast(word),
                else => @bitCast(word),
            };
        }
        return result;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "appendNode / getNode round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const node = AstNode{
        .tag = .var_decl,
        .span = .none,
        .data = .{ .bool_val = true },
    };
    const idx = try store.appendNode(std.testing.allocator, node);
    const got = store.getNode(idx);
    try std.testing.expectEqual(AstKind.var_decl, got.tag);
    try std.testing.expect(got.data == .bool_val);
    try std.testing.expectEqual(true, got.data.bool_val);
}

test "appendNode never returns index 0" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const idx = try store.appendNode(std.testing.allocator, .{
        .tag = .identifier,
        .span = .none,
        .data = .none,
    });
    try std.testing.expect(idx != .none);
    try std.testing.expect(@intFromEnum(idx) != 0);
}

test "appendExtra / extraData round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const Extra = struct { a: u32, b: u32 };
    const idx = try store.appendExtra(std.testing.allocator, Extra{ .a = 42, .b = 99 });
    const got = store.extraData(Extra, idx);
    try std.testing.expectEqual(@as(u32, 42), got.a);
    try std.testing.expectEqual(@as(u32, 99), got.b);
}

test "StringPool integration via node data" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const si = try store.strings.intern(std.testing.allocator, "hello");
    const node = AstNode{
        .tag = .string_literal,
        .span = .none,
        .data = .{ .str = si },
    };
    const idx = try store.appendNode(std.testing.allocator, node);
    const got = store.getNode(idx);
    try std.testing.expect(got.data == .str);
    const s = store.strings.get(got.data.str);
    try std.testing.expectEqualStrings("hello", s);
}
