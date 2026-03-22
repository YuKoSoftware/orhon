// sort.zig — sorting utilities sidecar for std::sort
// Returns new sorted slices. Originals are not modified.

const std = @import("std");

const alloc = std.heap.page_allocator;

// ── Integer sorting ──

pub fn intAsc(items: []const i32) []const i32 {
    const copy = alloc.dupe(i32, items) catch return items;
    std.mem.sort(i32, copy, {}, std.sort.asc(i32));
    return copy;
}

pub fn intDesc(items: []const i32) []const i32 {
    const copy = alloc.dupe(i32, items) catch return items;
    std.mem.sort(i32, copy, {}, std.sort.desc(i32));
    return copy;
}

// ── Float sorting ──

pub fn floatAsc(items: []const f64) []const f64 {
    const copy = alloc.dupe(f64, items) catch return items;
    std.mem.sort(f64, copy, {}, std.sort.asc(f64));
    return copy;
}

pub fn floatDesc(items: []const f64) []const f64 {
    const copy = alloc.dupe(f64, items) catch return items;
    std.mem.sort(f64, copy, {}, std.sort.desc(f64));
    return copy;
}

// ── String sorting ──

pub fn strAsc(items: []const []const u8) []const []const u8 {
    const copy = alloc.dupe([]const u8, items) catch return items;
    std.mem.sort([]const u8, copy, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) std.math.Order {
            return std.mem.order(u8, a, b);
        }
    }.cmp);
    return copy;
}

// ── Reverse ──

pub fn reverse(items: anytype) @TypeOf(items) {
    const T = std.meta.Elem(@TypeOf(items));
    const copy = alloc.dupe(T, items) catch return items;
    std.mem.reverse(T, copy);
    return copy;
}

// ── Tests ──

test "intAsc" {
    const input = [_]i32{ 3, 1, 2 };
    const sorted = intAsc(&input);
    try std.testing.expectEqual(@as(i32, 1), sorted[0]);
    try std.testing.expectEqual(@as(i32, 2), sorted[1]);
    try std.testing.expectEqual(@as(i32, 3), sorted[2]);
}

test "intDesc" {
    const input = [_]i32{ 1, 3, 2 };
    const sorted = intDesc(&input);
    try std.testing.expectEqual(@as(i32, 3), sorted[0]);
    try std.testing.expectEqual(@as(i32, 2), sorted[1]);
    try std.testing.expectEqual(@as(i32, 1), sorted[2]);
}
