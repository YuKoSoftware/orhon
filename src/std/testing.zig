// testing.zig — test assertion helpers sidecar for std::testing
// All assertions panic on failure. Designed for use in Orhon test blocks.

const std = @import("std");

// ── AssertTrue ──

pub fn assertTrue(value: bool) void {
    if (!value) @panic("assertTrue failed: expected true, got false");
}

// ── AssertFalse ──

pub fn assertFalse(value: bool) void {
    if (value) @panic("assertFalse failed: expected false, got true");
}

// ── AssertEq ──

pub fn assertEq(a: []const u8, b: []const u8) void {
    if (!std.mem.eql(u8, a, b)) @panic("assertEq failed: strings not equal");
}

// ── AssertNe ──

pub fn assertNe(a: []const u8, b: []const u8) void {
    if (std.mem.eql(u8, a, b)) @panic("assertNe failed: strings are equal");
}

// ── AssertContains ──

pub fn assertContains(text: []const u8, sub: []const u8) void {
    if (std.mem.indexOf(u8, text, sub) == null) @panic("assertContains failed: substring not found");
}

// ── Fail ──

pub fn fail(msg: []const u8) void {
    _ = msg;
    @panic("test failed");
}

// ── Tests ──

test "assertTrue" {
    assertTrue(true);
    assertTrue(1 == 1);
}

test "assertFalse" {
    assertFalse(false);
    assertFalse(1 == 2);
}

test "assertEq" {
    assertEq("hello", "hello");
    assertEq("", "");
}

test "assertNe" {
    assertNe("hello", "world");
    assertNe("a", "b");
}

test "assertContains" {
    assertContains("hello world", "world");
    assertContains("orhon language", "orhon");
}
