// mir_store.zig — index-based struct-of-arrays MIR store (Phase B scaffold)
// No population yet; types and helpers only.
// Contract: AstStore must outlive MirStore (span back-pointers into AstStore
// are AstNodeIndex values; MirStore does not own the AstStore).

const std = @import("std");
const StringPool = @import("string_pool.zig").StringPool;
const StringIndex = @import("string_pool.zig").StringIndex;
const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
const TypeStore = @import("type_store.zig").TypeStore;
const TypeId = @import("type_store.zig").TypeId;
const mir_types = @import("mir/mir_types.zig");

pub const MirKind = mir_types.MirKind;
pub const TypeClass = mir_types.TypeClass;
pub const Coercion = mir_types.Coercion;

// ---------------------------------------------------------------------------
// Index types — all enum(u32) with none=0 sentinel
// ---------------------------------------------------------------------------

pub const MirNodeIndex = enum(u32) { none = 0, _ };
pub const MirExtraIndex = enum(u32) { none = 0, _ };

// ---------------------------------------------------------------------------
// MirData — covers all node storage patterns (parallel to AstStore.Data)
// ---------------------------------------------------------------------------

pub const MirData = union(enum) {
    none: void,
    node: MirNodeIndex,
    two_nodes: struct { lhs: MirNodeIndex, rhs: MirNodeIndex },
    node_and_extra: struct { node: MirNodeIndex, extra: MirExtraIndex },
    extra: MirExtraIndex,
    str: StringIndex,
    str_and_node: struct { str: StringIndex, node: MirNodeIndex },
    bool_val: bool,
    str_and_extra: struct { str: StringIndex, extra: MirExtraIndex },
};

// ---------------------------------------------------------------------------
// MirEntry — the per-node record stored in MirStore's MultiArrayList
// ---------------------------------------------------------------------------

pub const MirEntry = struct {
    tag: MirKind,
    type_class: TypeClass,
    /// Back-pointer into AstStore for source location queries.
    /// The AstStore must outlive this MirStore.
    span: AstNodeIndex,
    /// Interned type of this node (index into MirStore.types).
    type_id: TypeId,
    /// 0=none; see coercionToKind/coercionFromKind for encoding.
    coercion_kind: u8 = 0,
    data: MirData,
};

// ---------------------------------------------------------------------------
// MirStore
// ---------------------------------------------------------------------------

pub const MirStore = struct {
    nodes: std.MultiArrayList(MirEntry),
    extra_data: std.ArrayListUnmanaged(u32),
    types: TypeStore,
    strings: StringPool,

    pub fn init() MirStore {
        return .{
            .nodes = .{},
            .extra_data = .{},
            .types = TypeStore.init(),
            .strings = StringPool.init(),
        };
    }

    pub fn deinit(store: *MirStore, allocator: std.mem.Allocator) void {
        store.nodes.deinit(allocator);
        store.extra_data.deinit(allocator);
        store.types.deinit(allocator);
        store.strings.deinit(allocator);
    }

    /// Append a node; returns its 1-based index (index 0 == .none sentinel).
    /// On the very first append, slot 0 is reserved as the sentinel.
    pub fn appendNode(store: *MirStore, allocator: std.mem.Allocator, entry: MirEntry) !MirNodeIndex {
        if (store.nodes.len == 0) {
            try store.nodes.append(allocator, .{
                .tag = .passthrough,
                .type_class = .plain,
                .span = .none,
                .type_id = .none,
                .data = .none,
            });
        }
        const idx: MirNodeIndex = @enumFromInt(store.nodes.len);
        try store.nodes.append(allocator, entry);
        return idx;
    }

    pub fn getNode(store: *const MirStore, idx: MirNodeIndex) MirEntry {
        std.debug.assert(idx != .none);
        return store.nodes.get(@intFromEnum(idx));
    }

    /// Append a packed extra record; T must have all u32-sized fields.
    /// Returns the MirExtraIndex of the first word appended.
    pub fn appendExtra(store: *MirStore, allocator: std.mem.Allocator, value: anytype) !MirExtraIndex {
        const T = @TypeOf(value);
        const idx: MirExtraIndex = @enumFromInt(store.extra_data.items.len);
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

    /// Read an extra record back.
    pub fn extraData(store: *const MirStore, comptime T: type, idx: MirExtraIndex) T {
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
// Coercion encoding helpers
// ---------------------------------------------------------------------------

/// Encode a Coercion value into a u8 for storage in MirEntry.coercion_kind.
/// Encoding: 0=none, 1=array_to_slice, 2=null_wrap, 3=error_wrap,
/// 4=optional_unwrap, 5=value_to_const_ref, 6+tag=arbitrary_union_wrap.
pub fn coercionToKind(c: Coercion) u8 {
    return switch (c) {
        .array_to_slice => 1,
        .null_wrap => 2,
        .error_wrap => 3,
        .optional_unwrap => 4,
        .value_to_const_ref => 5,
        .arbitrary_union_wrap => |tag| 6 + tag,
    };
}

/// Decode a u8 coercion_kind back into an optional Coercion.
pub fn coercionFromKind(k: u8) ?Coercion {
    return switch (k) {
        0 => null,
        1 => .array_to_slice,
        2 => .null_wrap,
        3 => .error_wrap,
        4 => .optional_unwrap,
        5 => .value_to_const_ref,
        else => .{ .arbitrary_union_wrap = k - 6 },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MirStore: appendNode / getNode round-trip" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const entry = MirEntry{
        .tag = .var_decl,
        .type_class = .plain,
        .span = .none,
        .type_id = .none,
        .data = .{ .bool_val = true },
    };
    const idx = try store.appendNode(std.testing.allocator, entry);
    const got = store.getNode(idx);
    try std.testing.expectEqual(MirKind.var_decl, got.tag);
    try std.testing.expectEqual(TypeClass.plain, got.type_class);
    try std.testing.expect(got.data == .bool_val);
    try std.testing.expectEqual(true, got.data.bool_val);
}

test "MirStore: appendNode never returns index 0" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const idx = try store.appendNode(std.testing.allocator, .{
        .tag = .identifier,
        .type_class = .plain,
        .span = .none,
        .type_id = .none,
        .data = .none,
    });
    try std.testing.expect(idx != .none);
    try std.testing.expect(@intFromEnum(idx) != 0);
}

test "MirStore: multiple nodes get sequential indices" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const idx1 = try store.appendNode(std.testing.allocator, .{
        .tag = .literal,
        .type_class = .plain,
        .span = .none,
        .type_id = .none,
        .data = .none,
    });
    const idx2 = try store.appendNode(std.testing.allocator, .{
        .tag = .binary,
        .type_class = .plain,
        .span = .none,
        .type_id = .none,
        .data = .none,
    });
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(idx1));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(idx2));
}

test "MirStore: span stores AstNodeIndex back-pointer" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const fake_span: AstNodeIndex = @enumFromInt(42);
    const idx = try store.appendNode(std.testing.allocator, .{
        .tag = .identifier,
        .type_class = .plain,
        .span = fake_span,
        .type_id = .none,
        .data = .none,
    });
    const got = store.getNode(idx);
    try std.testing.expectEqual(fake_span, got.span);
}

test "MirStore: appendExtra / extraData round-trip" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const Extra = struct { a: u32, b: u32 };
    const eidx = try store.appendExtra(std.testing.allocator, Extra{ .a = 7, .b = 13 });
    const got = store.extraData(Extra, eidx);
    try std.testing.expectEqual(@as(u32, 7), got.a);
    try std.testing.expectEqual(@as(u32, 13), got.b);
}

test "MirStore: TypeStore integration via type_id" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const types = @import("types.zig");
    const tid = try store.types.intern(std.testing.allocator, .{ .primitive = .i32 });
    const idx = try store.appendNode(std.testing.allocator, .{
        .tag = .var_decl,
        .type_class = .plain,
        .span = .none,
        .type_id = tid,
        .data = .none,
    });
    const got = store.getNode(idx);
    try std.testing.expectEqual(tid, got.type_id);
    const resolved = store.types.get(got.type_id);
    try std.testing.expect(resolved == .primitive);
    try std.testing.expectEqual(types.Primitive.i32, resolved.primitive);
}

test "MirStore: StringPool integration via node data" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const si = try store.strings.intern(std.testing.allocator, "my_var");
    const idx = try store.appendNode(std.testing.allocator, .{
        .tag = .identifier,
        .type_class = .plain,
        .span = .none,
        .type_id = .none,
        .data = .{ .str = si },
    });
    const got = store.getNode(idx);
    try std.testing.expect(got.data == .str);
    try std.testing.expectEqualStrings("my_var", store.strings.get(got.data.str));
}

test "coercionToKind / coercionFromKind round-trip: none" {
    try std.testing.expectEqual(@as(?Coercion, null), coercionFromKind(0));
}

test "coercionToKind / coercionFromKind round-trip: simple variants" {
    const cases = [_]Coercion{
        .array_to_slice,
        .null_wrap,
        .error_wrap,
        .optional_unwrap,
        .value_to_const_ref,
    };
    for (cases) |c| {
        const k = coercionToKind(c);
        try std.testing.expect(k >= 1 and k <= 5);
        try std.testing.expectEqual(@as(?Coercion, c), coercionFromKind(k));
    }
}

test "coercionToKind / coercionFromKind round-trip: arbitrary_union_wrap" {
    const c = Coercion{ .arbitrary_union_wrap = 7 };
    const k = coercionToKind(c);
    try std.testing.expectEqual(@as(u8, 13), k); // 6 + 7
    const back = coercionFromKind(k);
    try std.testing.expectEqual(@as(?Coercion, c), back);
}
