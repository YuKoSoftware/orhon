// collections.zig — generic data structures sidecar for std::collections
// Provides List(T), Map(K, V), Set(T) as Zig generic type functions.
// Structs self-initialize with .{} and default to the global SMP allocator.
//
// OOM policy: mutations return early on OOM; iteration builders return partial results.
// Use allocator-aware Zig collections directly for hard guarantees.

const std = @import("std");
const allocator = @import("allocator.zig");

const _default_alloc = allocator.default;

// ── List(T) — dynamic array ──

/// Returns a dynamically-sized array type parameterized over element type T.
pub fn List(comptime T: type) type {
    return struct {
        inner: std.ArrayListUnmanaged(T) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        /// Create a new list with the default allocator.
        pub fn new() Self {
            return .{};
        }

        /// Create a new list with a custom allocator.
        pub fn withAlloc(alloc_arg: std.mem.Allocator) Self {
            return .{ .alloc = alloc_arg };
        }

        /// Appends an item to the end of the list.
        pub fn add(self: *Self, item: T) void {
            self.inner.append(self.alloc, item) catch return; // OOM: cannot add item
        }

        /// Returns the item at the given index.
        pub fn get(self: *const Self, index: i32) T {
            const i: usize = @intCast(index);
            return self.inner.items[i];
        }

        /// Replaces the item at the given index with a new value.
        pub fn set(self: *Self, index: i32, item: T) void {
            const i: usize = @intCast(index);
            self.inner.items[i] = item;
        }

        /// Removes the item at the given index, preserving order.
        pub fn remove(self: *Self, index: i32) void {
            const i: usize = @intCast(index);
            _ = self.inner.orderedRemove(i);
        }

        /// Removes and returns the last item in the list.
        pub fn pop(self: *Self) T {
            return self.inner.pop();
        }

        /// Returns the number of items in the list.
        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.items.len);
        }

        /// Returns a slice of all items for iteration.
        pub fn items(self: *const Self) []const T {
            return self.inner.items;
        }

        /// Releases all memory owned by the list.
        pub fn free(self: *Self) void {
            self.inner.deinit(self.alloc);
        }
    };
}

// ── Map(K, V) — hash map ──

/// Returns a hash map type parameterized over key type K and value type V.
pub fn Map(comptime K: type, comptime V: type) type {
    const Context = if (K == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(K);

    return struct {
        inner: std.HashMapUnmanaged(K, V, Context, 80) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        /// Create a new map with the default allocator.
        pub fn new() Self {
            return .{};
        }

        /// Create a new map with a custom allocator.
        pub fn withAlloc(alloc_arg: std.mem.Allocator) Self {
            return .{ .alloc = alloc_arg };
        }

        /// Inserts or updates a key-value pair in the map.
        pub fn put(self: *Self, key: K, value: V) void {
            self.inner.put(self.alloc, key, value) catch return; // OOM: cannot put entry
        }

        /// Returns the value for the given key, or null if not found.
        pub fn get(self: *const Self, key: K) ?V {
            return self.inner.get(key);
        }

        /// Returns true if the map contains the given key.
        pub fn has(self: *const Self, key: K) bool {
            return self.inner.contains(key);
        }

        /// Removes the entry with the given key from the map.
        pub fn remove(self: *Self, key: K) void {
            _ = self.inner.remove(key);
        }

        /// Returns the number of entries in the map.
        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.count());
        }

        /// Returns a caller-owned slice of all keys in the map. Free with `alloc.free()`.
        pub fn keys(self: *const Self) []const K {
            const count = self.inner.count();
            if (count == 0) return &.{};
            const buf = self.alloc.alloc(K, count) catch return &.{};
            var i: usize = 0;
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                buf[i] = entry.key_ptr.*;
                i += 1;
            }
            return buf;
        }

        /// Returns a caller-owned slice of all values in the map. Free with `alloc.free()`.
        pub fn values(self: *const Self) []const V {
            const count = self.inner.count();
            if (count == 0) return &.{};
            const buf = self.alloc.alloc(V, count) catch return &.{};
            var i: usize = 0;
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                buf[i] = entry.value_ptr.*;
                i += 1;
            }
            return buf;
        }

        /// Releases all memory owned by the map.
        pub fn free(self: *Self) void {
            self.inner.deinit(self.alloc);
        }
    };
}

// ── Set(T) — hash set ──

/// Returns a hash set type parameterized over element type T.
pub fn Set(comptime T: type) type {
    const Context = if (T == []const u8) std.hash_map.StringContext else std.hash_map.AutoContext(T);

    return struct {
        inner: std.HashMapUnmanaged(T, void, Context, 80) = .{},
        alloc: std.mem.Allocator = _default_alloc,

        const Self = @This();

        /// Create a new set with the default allocator.
        pub fn new() Self {
            return .{};
        }

        /// Create a new set with a custom allocator.
        pub fn withAlloc(alloc_arg: std.mem.Allocator) Self {
            return .{ .alloc = alloc_arg };
        }

        /// Adds an item to the set; duplicates are ignored.
        pub fn add(self: *Self, item: T) void {
            self.inner.put(self.alloc, item, {}) catch return; // OOM: cannot add item
        }

        /// Returns true if the set contains the given item.
        pub fn has(self: *const Self, item: T) bool {
            return self.inner.contains(item);
        }

        /// Removes the given item from the set.
        pub fn remove(self: *Self, item: T) void {
            _ = self.inner.remove(item);
        }

        /// Returns the number of items in the set.
        pub fn len(self: *const Self) i32 {
            return @intCast(self.inner.count());
        }

        /// Returns a caller-owned slice of all items in the set. Free with `alloc.free()`.
        pub fn items(self: *const Self) []const T {
            const count = self.inner.count();
            if (count == 0) return &.{};
            const buf = self.alloc.alloc(T, count) catch return &.{};
            var i: usize = 0;
            var iter = self.inner.iterator();
            while (iter.next()) |entry| {
                buf[i] = entry.key_ptr.*;
                i += 1;
            }
            return buf;
        }

        /// Releases all memory owned by the set.
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

test "List set and remove" {
    var list = List(i32){};
    defer list.free();
    list.add(10);
    list.add(20);
    list.add(30);
    list.set(1, 25);
    try std.testing.expectEqual(@as(i32, 25), list.get(1));
    list.remove(0);
    try std.testing.expectEqual(@as(i32, 2), list.len());
    try std.testing.expectEqual(@as(i32, 25), list.get(0));
}

test "List pop" {
    var list = List(i32){};
    defer list.free();
    list.add(1);
    list.add(2);
    const popped = list.pop();
    try std.testing.expectEqual(@as(i32, 2), popped);
    try std.testing.expectEqual(@as(i32, 1), list.len());
}

test "Map keys and values" {
    var map = Map(i32, i32){};
    defer map.free();
    map.put(1, 10);
    map.put(2, 20);
    const ks = map.keys();
    try std.testing.expectEqual(@as(usize, 2), ks.len);
    const vs = map.values();
    try std.testing.expectEqual(@as(usize, 2), vs.len);
}

test "Map remove" {
    var map = Map(i32, i32){};
    defer map.free();
    map.put(1, 10);
    map.put(2, 20);
    map.remove(1);
    try std.testing.expect(map.get(1) == null);
    try std.testing.expectEqual(@as(i32, 1), map.len());
}
