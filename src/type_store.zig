// type_store.zig — interning pool for ResolvedType values, indexed by TypeId

const std = @import("std");
const types = @import("types.zig");
const ResolvedType = types.ResolvedType;

pub const TypeId = enum(u32) {
    none = 0,
    _,
};

pub const TypeStore = struct {
    entries: std.ArrayListUnmanaged(ResolvedType) = .{},
    map: std.StringHashMapUnmanaged(TypeId) = .{},

    pub fn init() TypeStore {
        return .{};
    }

    pub fn deinit(store: *TypeStore, allocator: std.mem.Allocator) void {
        var iter = store.map.keyIterator();
        while (iter.next()) |key| allocator.free(key.*);
        store.map.deinit(allocator);
        store.entries.deinit(allocator);
        store.* = TypeStore.init();
    }

    pub fn intern(store: *TypeStore, allocator: std.mem.Allocator, type_: ResolvedType) !TypeId {
        const key = try canonicalKey(allocator, type_);
        if (store.map.get(key)) |id| {
            allocator.free(key);
            return id;
        }
        errdefer allocator.free(key);
        const id: TypeId = @enumFromInt(store.entries.items.len + 1);
        try store.entries.append(allocator, type_);
        errdefer _ = store.entries.pop();
        try store.map.put(allocator, key, id);
        return id;
    }

    pub fn get(store: *const TypeStore, id: TypeId) ResolvedType {
        std.debug.assert(id != .none);
        return store.entries.items[@intFromEnum(id) - 1];
    }
};

fn canonicalKey(allocator: std.mem.Allocator, type_: ResolvedType) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    try writeCanonical(buf.writer(allocator), type_);
    return buf.toOwnedSlice(allocator);
}

fn writeCanonical(writer: anytype, type_: ResolvedType) !void {
    switch (type_) {
        .primitive => |p| try writer.print("0:{s}", .{p.toName()}),
        .named => |n| try writer.print("1:{s}", .{n}),
        .err => try writer.writeAll("2"),
        .null_type => try writer.writeAll("3"),
        .inferred => try writer.writeAll("4"),
        .unknown => try writer.writeAll("5"),
        .slice => |inner| {
            try writer.writeAll("6:");
            try writeCanonical(writer, inner.*);
        },
        .array => |a| {
            try writer.print("7:{x}:", .{@intFromPtr(a.size)});
            try writeCanonical(writer, a.elem.*);
        },
        .union_type => |members| {
            try writer.writeAll("8:[");
            for (members, 0..) |m, i| {
                if (i > 0) try writer.writeByte(',');
                try writeCanonical(writer, m);
            }
            try writer.writeByte(']');
        },
        .tuple => |fields| {
            try writer.writeAll("9:[");
            for (fields, 0..) |f, i| {
                if (i > 0) try writer.writeByte(',');
                try writer.print("{s}:", .{f.name});
                try writeCanonical(writer, f.type_);
            }
            try writer.writeByte(']');
        },
        .func_ptr => |fp| {
            try writer.writeAll("10:[");
            for (fp.params, 0..) |p, i| {
                if (i > 0) try writer.writeByte(',');
                try writeCanonical(writer, p);
            }
            try writer.writeAll("]:");
            try writeCanonical(writer, fp.return_type.*);
        },
        .generic => |g| {
            try writer.print("11:{s}:[", .{g.name});
            for (g.args, 0..) |a, i| {
                if (i > 0) try writer.writeByte(',');
                try writeCanonical(writer, a);
            }
            try writer.writeByte(']');
        },
        .ptr => |p| {
            const tag: u8 = if (p.kind == .mut_ref) 'm' else 'c';
            try writer.print("12:{c}:", .{tag});
            try writeCanonical(writer, p.elem.*);
        },
        .type_param => |tp| {
            try writer.print("13:T:{s}:{d}", .{ tp.name, @intFromEnum(tp.binder) });
        },
    }
}

test "TypeStore: intern primitive round-trips" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const id = try store.intern(std.testing.allocator, .{ .primitive = .i32 });
    try std.testing.expect(id != .none);
    const result = store.get(id);
    try std.testing.expect(result == .primitive);
    try std.testing.expectEqual(.i32, result.primitive);
}

test "TypeStore: same type interns to same id" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const id1 = try store.intern(std.testing.allocator, .{ .primitive = .i32 });
    const id2 = try store.intern(std.testing.allocator, .{ .primitive = .i32 });
    try std.testing.expectEqual(id1, id2);
}

test "TypeStore: different primitives get different ids" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const id1 = try store.intern(std.testing.allocator, .{ .primitive = .i32 });
    const id2 = try store.intern(std.testing.allocator, .{ .primitive = .bool });
    try std.testing.expect(id1 != id2);
    try std.testing.expect(id1 != .none);
    try std.testing.expect(id2 != .none);
}

test "TypeStore: named types intern by string content" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const id1 = try store.intern(std.testing.allocator, .{ .named = "Foo" });
    const id2 = try store.intern(std.testing.allocator, .{ .named = "Foo" });
    const id3 = try store.intern(std.testing.allocator, .{ .named = "Bar" });
    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);
}

test "TypeStore: special types (err, null, inferred, unknown)" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const err1 = try store.intern(std.testing.allocator, .err);
    const err2 = try store.intern(std.testing.allocator, .err);
    const null1 = try store.intern(std.testing.allocator, .null_type);
    const inf = try store.intern(std.testing.allocator, .inferred);
    const unk = try store.intern(std.testing.allocator, .unknown);

    try std.testing.expectEqual(err1, err2);
    try std.testing.expect(err1 != null1);
    try std.testing.expect(err1 != inf);
    try std.testing.expect(err1 != unk);
    try std.testing.expect(null1 != inf);
    try std.testing.expect(inf != unk);
}

test "TypeStore: none is never returned by intern" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const id = try store.intern(std.testing.allocator, .{ .primitive = .bool });
    try std.testing.expect(id != .none);
}

test "TypeStore: slice type deduplicates by inner type" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const i32_type = ResolvedType{ .primitive = .i32 };
    const bool_type = ResolvedType{ .primitive = .bool };

    const id1 = try store.intern(std.testing.allocator, .{ .slice = &i32_type });
    const id2 = try store.intern(std.testing.allocator, .{ .slice = &i32_type });
    const id3 = try store.intern(std.testing.allocator, .{ .slice = &bool_type });

    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);
}

test "TypeStore: generic type deduplicates by name and args" {
    var store = TypeStore.init();
    defer store.deinit(std.testing.allocator);

    const i32_type = ResolvedType{ .primitive = .i32 };
    const bool_type = ResolvedType{ .primitive = .bool };

    const id1 = try store.intern(std.testing.allocator, .{ .generic = .{ .name = "List", .args = &.{i32_type} } });
    const id2 = try store.intern(std.testing.allocator, .{ .generic = .{ .name = "List", .args = &.{i32_type} } });
    const id3 = try store.intern(std.testing.allocator, .{ .generic = .{ .name = "List", .args = &.{bool_type} } });
    const id4 = try store.intern(std.testing.allocator, .{ .generic = .{ .name = "Map", .args = &.{i32_type} } });

    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id1 != id4);
}
