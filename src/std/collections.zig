// collections.zig — generic data structures sidecar for std::collections
// Provides List(T), Map(K, V), Set(T) as Zig generic type functions.
// Structs self-initialize with .{} and default to the global SMP allocator.
//
// OOM policy: mutations return early on OOM; iteration builders return partial results.
// Use allocator-aware Zig collections directly for hard guarantees.

const std = @import("std");

const _default_alloc = std.heap.smp_allocator;

// ── List(T) — dynamic array ──

pub fn List(comptime T: type) type {
    return struct {
        inner: std.ArrayListUnmanaged(T) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        pub fn add(self: *Self, item: T) void {
            self.inner.append(self.alloc, item) catch return; // OOM: cannot add item
        }

        pub fn get(self: *const Self, index: i32) T {
            const i: usize = @intCast(index);
            return self.inner.items[i];
        }

        pub fn set(self: *Self, index: i32, item: T) void {
            const i: usize = @intCast(index);
            self.inner.items[i] = item;
        }

        pub fn remove(self: *Self, index: i32) void {
            const i: usize = @intCast(index);
            _ = self.inner.orderedRemove(i);
        }

        pub fn pop(self: *Self) T {
            return self.inner.pop();
        }

        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.items.len);
        }

        pub fn items(self: *const Self) []const T {
            return self.inner.items;
        }

        pub fn free(self: *Self) void {
            self.inner.deinit(self.alloc);
        }
    };
}

// ── Map(K, V) — hash map ──

pub fn Map(comptime K: type, comptime V: type) type {
    const Context = if (K == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(K);
    const Eql = if (K == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(K);
    _ = Eql;

    return struct {
        inner: std.HashMapUnmanaged(K, V, Context, 80) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        pub fn put(self: *Self, key: K, value: V) void {
            self.inner.put(self.alloc, key, value) catch return; // OOM: cannot put entry
        }

        pub fn get(self: *const Self, key: K) ?V {
            return self.inner.get(key);
        }

        pub fn has(self: *const Self, key: K) bool {
            return self.inner.contains(key);
        }

        pub fn remove(self: *Self, key: K) void {
            _ = self.inner.remove(key);
        }

        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.count());
        }

        pub fn keys(self: *const Self) []const K {
            var result = std.ArrayListUnmanaged(K){};
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                result.append(self.alloc, entry.key_ptr.*) catch break; // OOM: return partial keys
            }
            return result.items;
        }

        pub fn values(self: *const Self) []const V {
            var result = std.ArrayListUnmanaged(V){};
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                result.append(self.alloc, entry.value_ptr.*) catch break; // OOM: return partial values
            }
            return result.items;
        }

        pub fn free(self: *Self) void {
            self.inner.deinit(self.alloc);
        }
    };
}

// ── Set(T) — hash set ──

pub fn Set(comptime T: type) type {
    const Context = if (T == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(T);

    return struct {
        inner: std.HashMapUnmanaged(T, void, Context, 80) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        pub fn add(self: *Self, item: T) void {
            self.inner.put(self.alloc, item, {}) catch return; // OOM: cannot add item
        }

        pub fn has(self: *const Self, item: T) bool {
            return self.inner.contains(item);
        }

        pub fn remove(self: *Self, item: T) void {
            _ = self.inner.remove(item);
        }

        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.count());
        }

        pub fn items(self: *const Self) []const T {
            var result = std.ArrayListUnmanaged(T){};
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                result.append(self.alloc, entry.key_ptr.*) catch break; // OOM: return partial items
            }
            return result.items;
        }

        pub fn free(self: *Self) void {
            self.inner.deinit(self.alloc);
        }
    };
}

// ── Tests ──

test "List basic" {
    var list = List(i32){};
    defer list.free();
    list.add(10);
    list.add(20);
    list.add(30);
    try std.testing.expectEqual(@as(i32, 3), list.len());
    try std.testing.expectEqual(@as(i32, 10), list.get(0));
    try std.testing.expectEqual(@as(i32, 20), list.get(1));
    list.set(1, 99);
    try std.testing.expectEqual(@as(i32, 99), list.get(1));
    list.remove(0);
    try std.testing.expectEqual(@as(i32, 2), list.len());
}

test "List items iteration" {
    var list = List(i32){};
    defer list.free();
    list.add(1);
    list.add(2);
    list.add(3);
    var sum: i32 = 0;
    for (list.items()) |item| sum += item;
    try std.testing.expectEqual(@as(i32, 6), sum);
}

test "Map basic" {
    var map = Map([]const u8, i32){};
    defer map.free();
    map.put("a", 1);
    map.put("b", 2);
    try std.testing.expectEqual(@as(i32, 2), map.len());
    try std.testing.expect(map.has("a"));
    try std.testing.expectEqual(@as(i32, 1), map.get("a").?);
    map.remove("a");
    try std.testing.expect(!map.has("a"));
}

test "Set basic" {
    var set = Set(i32){};
    defer set.free();
    set.add(1);
    set.add(2);
    set.add(1); // duplicate
    try std.testing.expectEqual(@as(i32, 2), set.len());
    try std.testing.expect(set.has(1));
    try std.testing.expect(!set.has(3));
    set.remove(1);
    try std.testing.expect(!set.has(1));
}
