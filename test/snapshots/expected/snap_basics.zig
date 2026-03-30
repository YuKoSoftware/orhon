// generated from module snap_basics — do not edit
const std = @import("std");
const str = @import("_orhon_str");

fn _OrhonHandle(comptime T: type) type { return struct { thread: std.Thread, state: *SharedState, pub const SharedState = struct { result: T = undefined, completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false) }; const Self = @This(); pub fn getValue(self_h: *Self) T { self_h.thread.join(); const result = self_h.state.result; std.heap.page_allocator.destroy(self_h.state); return result; } pub fn wait(self_h: *Self) void { self_h.thread.join(); } pub fn done(self_h: *const Self) bool { return self_h.state.completed.load(.acquire); } pub fn join(self_h: *Self) void { self_h.thread.join(); std.heap.page_allocator.destroy(self_h.state); } }; }

const MAX_COUNT: i32 = 100;

const APP_NAME: []const u8 = "orhon";

const RETRY_COUNT: i32 = 3;

const Speed = i32;

pub fn add(a: i32, b: i32) i32 {
    return (a + b);
}

pub fn greet(name: []const u8) []const u8 {
    return (("hello" ++ " ") ++ name);
}

pub inline fn doubled(n: i32) i32 {
    return (n * 2);
}

