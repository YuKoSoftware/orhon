// generated from module snap_structs — do not edit
const std = @import("std");

fn _OrhonHandle(comptime T: type) type { return struct { thread: std.Thread, state: *SharedState, pub const SharedState = struct { result: T = undefined, completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false) }; const Self = @This(); pub fn getValue(self_h: *Self) T { self_h.thread.join(); const result = self_h.state.result; std.heap.page_allocator.destroy(self_h.state); return result; } pub fn wait(self_h: *Self) void { self_h.thread.join(); } pub fn done(self_h: *const Self) bool { return self_h.state.completed.load(.acquire); } pub fn join(self_h: *Self) void { self_h.thread.join(); std.heap.page_allocator.destroy(self_h.state); } }; }

pub const Point = struct {
    x: f32,
    y: f32,
    label: []const u8,
};

pub const Circle = struct {
    radius: f32,
pub fn area(self: *const Circle) f32 {
        return (self.radius * self.radius);
    }
};

pub const Config = struct {
    name: []const u8,
    count: i32 = 0,
    enabled: bool = true,
};

pub const Direction = enum(u8) {
    North,
    South,
    East,
};

pub const Color = enum(u8) {
    Red,
    Green,
    Blue,
pub fn is_warm(self: *const Color) bool {
        switch (self.*) {
            .Red => {
                return true;
            },
            .Green => {
                return false;
            },
            .Blue => {
                return false;
            },
        }
        return false;
    }
};

