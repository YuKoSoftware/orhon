// math.zig — mathematical functions sidecar for std::math
// Wraps Zig's std.math. Pure functions, no allocation, no state.

const std = @import("std");

// ── Basic ──

pub fn abs(x: f64) f64 {
    return @abs(x);
}

pub fn min(a: f64, b: f64) f64 {
    return @min(a, b);
}

pub fn max(a: f64, b: f64) f64 {
    return @max(a, b);
}

pub fn clamp(x: f64, lo: f64, hi: f64) f64 {
    return @max(lo, @min(x, hi));
}

// ── Rounding ──

pub fn floor(x: f64) f64 {
    return @floor(x);
}

pub fn ceil(x: f64) f64 {
    return @ceil(x);
}

pub fn round(x: f64) f64 {
    return @round(x);
}

// ── Powers and roots ──

pub fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

pub fn pow(base: f64, exponent: f64) f64 {
    return std.math.pow(f64, base, exponent);
}

pub fn log(x: f64) f64 {
    return @log(x);
}

pub fn log2(x: f64) f64 {
    return @log2(x);
}

pub fn log10(x: f64) f64 {
    return @log10(x);
}

pub fn exp(x: f64) f64 {
    return @exp(x);
}

// ── Trigonometry ──

pub fn sin(x: f64) f64 {
    return @sin(x);
}

pub fn cos(x: f64) f64 {
    return @cos(x);
}

pub fn tan(x: f64) f64 {
    return @tan(x);
}

pub fn asin(x: f64) f64 {
    return std.math.asin(x);
}

pub fn acos(x: f64) f64 {
    return std.math.acos(x);
}

pub fn atan(x: f64) f64 {
    return std.math.atan(x);
}

pub fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}

// ── Constants ──

pub fn pi() f64 {
    return std.math.pi;
}

pub fn e() f64 {
    return std.math.e;
}

pub fn inf() f64 {
    return std.math.inf(f64);
}

// ── Integer math ──

pub fn absInt(x: i32) i32 {
    return if (x < 0) -x else x;
}

pub fn minInt(a: i32, b: i32) i32 {
    return @min(a, b);
}

pub fn maxInt(a: i32, b: i32) i32 {
    return @max(a, b);
}

pub fn clampInt(x: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(x, hi));
}

// ── Tests ──

test "abs" {
    try std.testing.expectEqual(@as(f64, 5.0), abs(-5.0));
}

test "min max" {
    try std.testing.expectEqual(@as(f64, 3.0), min(3.0, 7.0));
    try std.testing.expectEqual(@as(f64, 7.0), max(3.0, 7.0));
}

test "floor ceil round" {
    try std.testing.expectEqual(@as(f64, 3.0), floor(3.7));
    try std.testing.expectEqual(@as(f64, 4.0), ceil(3.2));
    try std.testing.expectEqual(@as(f64, 4.0), round(3.5));
}

test "sqrt" {
    try std.testing.expectEqual(@as(f64, 3.0), sqrt(9.0));
}

test "int math" {
    try std.testing.expectEqual(@as(i32, 5), absInt(-5));
    try std.testing.expectEqual(@as(i32, 3), minInt(3, 7));
    try std.testing.expectEqual(@as(i32, 5), clampInt(5, 0, 10));
}
