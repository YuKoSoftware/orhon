// string_pool.zig — interning pool for strings, used by AstStore

const std = @import("std");

pub const StringIndex = enum(u32) {
    none = 0,
    _,
};

pub const StringPool = struct {
    entries: std.ArrayListUnmanaged([]const u8),
    map: std.StringHashMapUnmanaged(StringIndex),

    pub fn init() StringPool {
        return .{
            .entries = .{},
            .map = .{},
        };
    }

    pub fn deinit(pool: *StringPool, allocator: std.mem.Allocator) void {
        for (pool.entries.items) |s| allocator.free(s);
        pool.entries.deinit(allocator);
        pool.map.deinit(allocator);
        pool.* = StringPool.init();
    }

    pub fn intern(pool: *StringPool, allocator: std.mem.Allocator, str: []const u8) !StringIndex {
        if (pool.map.get(str)) |idx| return idx;

        const owned = try allocator.dupe(u8, str);
        errdefer allocator.free(owned);
        const idx: StringIndex = @enumFromInt(pool.entries.items.len + 1);
        try pool.entries.append(allocator, owned);
        errdefer _ = pool.entries.pop();
        try pool.map.put(allocator, owned, idx);
        return idx;
    }

    pub fn get(pool: *const StringPool, idx: StringIndex) []const u8 {
        std.debug.assert(idx != .none);
        const raw = @intFromEnum(idx);
        return pool.entries.items[raw - 1];
    }
};

test "intern same string twice returns same index" {
    var pool = StringPool.init();
    defer pool.deinit(std.testing.allocator);

    const a = try pool.intern(std.testing.allocator, "hello");
    const b = try pool.intern(std.testing.allocator, "hello");
    try std.testing.expectEqual(a, b);
}

test "intern different strings returns different indices" {
    var pool = StringPool.init();
    defer pool.deinit(std.testing.allocator);

    const a = try pool.intern(std.testing.allocator, "foo");
    const b = try pool.intern(std.testing.allocator, "bar");
    try std.testing.expect(a != b);
}

test "get round-trip" {
    var pool = StringPool.init();
    defer pool.deinit(std.testing.allocator);

    const idx = try pool.intern(std.testing.allocator, "round-trip");
    try std.testing.expectEqualStrings("round-trip", pool.get(idx));
}

test "none index is never returned by intern" {
    var pool = StringPool.init();
    defer pool.deinit(std.testing.allocator);

    const idx = try pool.intern(std.testing.allocator, "something");
    try std.testing.expect(idx != .none);
}

test "intern empty string" {
    var pool = StringPool.init();
    defer pool.deinit(std.testing.allocator);

    const a = try pool.intern(std.testing.allocator, "");
    const b = try pool.intern(std.testing.allocator, "");
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqualStrings("", pool.get(a));
}
