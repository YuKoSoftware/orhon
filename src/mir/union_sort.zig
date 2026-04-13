// union_sort.zig — Canonical sort and positional tag lookup for arbitrary unions.
//
// Single source of truth: every emission site (registry, codegen, match arms,
// coercion tag inference) must use this helper so positional tags agree.

const std = @import("std");

/// Sort a slice of member type-name strings in lexicographic order, in place.
pub fn sortMemberNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

/// Return a freshly allocated slice containing the input names in canonical
/// (sorted) order. Caller owns the returned slice but not the inner strings.
pub fn sortedCopy(allocator: std.mem.Allocator, names: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |n, i| out[i] = n;
    sortMemberNames(out);
    return out;
}

/// Find the positional tag index of `target` within a sorted member list.
/// Returns null if not found. Comparison is byte-wise equality.
pub fn positionalIndex(sorted_members: []const []const u8, target: []const u8) ?usize {
    for (sorted_members, 0..) |m, i| {
        if (std.mem.eql(u8, m, target)) return i;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────

test "sortMemberNames - basic lex order" {
    const alloc = std.testing.allocator;
    var names = try alloc.alloc([]const u8, 3);
    defer alloc.free(names);
    names[0] = "str";
    names[1] = "i32";
    names[2] = "f64";
    sortMemberNames(names);
    try std.testing.expectEqualStrings("f64", names[0]);
    try std.testing.expectEqualStrings("i32", names[1]);
    try std.testing.expectEqualStrings("str", names[2]);
}

test "sortedCopy - does not mutate input" {
    const alloc = std.testing.allocator;
    const input = [_][]const u8{ "str", "i32" };
    const sorted = try sortedCopy(alloc, &input);
    defer alloc.free(sorted);
    try std.testing.expectEqualStrings("str", input[0]);
    try std.testing.expectEqualStrings("i32", input[1]);
    try std.testing.expectEqualStrings("i32", sorted[0]);
    try std.testing.expectEqualStrings("str", sorted[1]);
}

test "positionalIndex - found" {
    const sorted = [_][]const u8{ "f64", "i32", "str" };
    try std.testing.expectEqual(@as(?usize, 0), positionalIndex(&sorted, "f64"));
    try std.testing.expectEqual(@as(?usize, 1), positionalIndex(&sorted, "i32"));
    try std.testing.expectEqual(@as(?usize, 2), positionalIndex(&sorted, "str"));
}

test "positionalIndex - not found" {
    const sorted = [_][]const u8{ "i32", "str" };
    try std.testing.expectEqual(@as(?usize, null), positionalIndex(&sorted, "f64"));
}
