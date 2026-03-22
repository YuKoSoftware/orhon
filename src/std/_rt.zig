// _rt.zig — Orhon compiler runtime sidecar
// Bridge implementation for the _rt module.
// Paired with _rt.orh — loaded automatically by the compiler.

const std = @import("std");

// ── Allocator ──
// Debug builds: GPA (leak detection, use-after-free checks)
// Release builds: page allocator (fast, zero overhead)

pub const alloc = if (@import("builtin").mode == .Debug)
    gpa.allocator()
else
    std.heap.page_allocator;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// ── Type helpers ──

pub fn OrhonNullable(comptime T: type) type {
    return union(enum) { some: T, none: void };
}

pub fn orhonTypeId(comptime T: type) usize {
    return @intFromPtr(@typeName(T).ptr);
}

// ── Error type ──

pub const OrhonError = struct { message: []const u8 };

pub fn OrhonResult(comptime T: type) type {
    return union(enum) { ok: T, err: OrhonError };
}

// ── Tests ──

test "alloc works" {
    const ptr = try alloc.create(i32);
    ptr.* = 42;
    try std.testing.expectEqual(42, ptr.*);
    alloc.destroy(ptr);
}

test "OrhonNullable" {
    const N = OrhonNullable(i32);
    const some: N = .{ .some = 42 };
    const none: N = .{ .none = {} };
    try std.testing.expectEqual(42, some.some);
    _ = none;
}

test "OrhonResult" {
    const R = OrhonResult(i32);
    const ok: R = .{ .ok = 42 };
    const err: R = .{ .err = .{ .message = "fail" } };
    try std.testing.expectEqual(42, ok.ok);
    try std.testing.expect(std.mem.eql(u8, err.err.message, "fail"));
}

test "orhonTypeId distinct" {
    try std.testing.expect(orhonTypeId(i32) != orhonTypeId(f64));
}
