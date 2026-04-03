// generated from module snap_structs — do not edit
const std = @import("std");

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

