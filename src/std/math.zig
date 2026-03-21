// math.zig — extern func sidecar for std::math module

const std = @import("std");

pub fn pow(base: anytype, exp: anytype) @TypeOf(base) {
    // Use @exp(@log(x) * y) — works with comptime and runtime floats
    return @exp(@log(base) * exp);
}

pub fn sqrt(x: anytype) @TypeOf(x) {
    return @sqrt(x);
}

pub fn abs(x: anytype) @TypeOf(x) {
    return @abs(x);
}

pub fn min(a: anytype, b: anytype) @TypeOf(a) {
    return @min(a, b);
}

pub fn max(a: anytype, b: anytype) @TypeOf(a) {
    return @max(a, b);
}

pub fn floor(x: anytype) @TypeOf(x) {
    return @floor(x);
}

pub fn ceil(x: anytype) @TypeOf(x) {
    return @ceil(x);
}

pub fn sin(x: anytype) @TypeOf(x) {
    return @sin(x);
}

pub fn cos(x: anytype) @TypeOf(x) {
    return @cos(x);
}

pub fn tan(x: anytype) @TypeOf(x) {
    return @tan(x);
}

pub fn ln(x: anytype) @TypeOf(x) {
    return @log(x);
}

pub fn log2(x: anytype) @TypeOf(x) {
    return @log2(x);
}

pub const PI: f64 = std.math.pi;
pub const E: f64 = std.math.e;
