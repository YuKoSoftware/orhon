// math.zig — mathematical functions sidecar for std::math
// Wraps Zig's std.math. Pure functions, no allocation, no state.
// All functions are generic — work with any numeric type (f32, f64, i32, i64, etc.).

const std = @import("std");

// ── Basic ──

pub fn abs(x: anytype) @TypeOf(x) {
    return @abs(x);
}

pub fn min(a: anytype, b: anytype) @TypeOf(a, b) {
    return @min(a, b);
}

pub fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    return @max(a, b);
}

pub fn clamp(x: anytype, lo: anytype, hi: anytype) @TypeOf(x, lo, hi) {
    return @max(lo, @min(x, hi));
}

// ── Rounding (float types) ──

pub fn floor(x: anytype) @TypeOf(x) {
    return @floor(x);
}

pub fn ceil(x: anytype) @TypeOf(x) {
    return @ceil(x);
}

pub fn round(x: anytype) @TypeOf(x) {
    return @round(x);
}

// ── Powers and roots (float types) ──

pub fn sqrt(x: anytype) @TypeOf(x) {
    return @sqrt(x);
}

pub fn pow(base: anytype, exponent: anytype) @TypeOf(base, exponent) {
    return std.math.pow(@TypeOf(base, exponent), base, exponent);
}

pub fn log(x: anytype) @TypeOf(x) {
    return @log(x);
}

pub fn log2(x: anytype) @TypeOf(x) {
    return @log2(x);
}

pub fn log10(x: anytype) @TypeOf(x) {
    return @log10(x);
}

pub fn exp(x: anytype) @TypeOf(x) {
    return @exp(x);
}

// ── Trigonometry (float types) ──

pub fn sin(x: anytype) @TypeOf(x) {
    return @sin(x);
}

pub fn cos(x: anytype) @TypeOf(x) {
    return @cos(x);
}

pub fn tan(x: anytype) @TypeOf(x) {
    return @tan(x);
}

pub fn asin(x: anytype) @TypeOf(x) {
    return std.math.asin(x);
}

pub fn acos(x: anytype) @TypeOf(x) {
    return std.math.acos(x);
}

pub fn atan(x: anytype) @TypeOf(x) {
    return std.math.atan(x);
}

pub fn atan2(y: anytype, x: anytype) @TypeOf(x, y) {
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

// ── Tests ──

test "abs f64" {
    try std.testing.expectEqual(@as(f64, 5.0), abs(@as(f64, -5.0)));
}

test "abs i32" {
    try std.testing.expectEqual(@as(i32, 5), abs(@as(i32, -5)));
}

test "min max f64" {
    try std.testing.expectEqual(@as(f64, 3.0), min(@as(f64, 3.0), @as(f64, 7.0)));
    try std.testing.expectEqual(@as(f64, 7.0), max(@as(f64, 3.0), @as(f64, 7.0)));
}

test "min max i32" {
    try std.testing.expectEqual(@as(i32, 3), min(@as(i32, 3), @as(i32, 7)));
    try std.testing.expectEqual(@as(i32, 7), max(@as(i32, 3), @as(i32, 7)));
}

test "floor ceil round" {
    try std.testing.expectEqual(@as(f64, 3.0), floor(@as(f64, 3.7)));
    try std.testing.expectEqual(@as(f64, 4.0), ceil(@as(f64, 3.2)));
    try std.testing.expectEqual(@as(f64, 4.0), round(@as(f64, 3.5)));
}

test "sqrt f64" {
    try std.testing.expectEqual(@as(f64, 3.0), sqrt(@as(f64, 9.0)));
}

test "sqrt f32" {
    try std.testing.expectEqual(@as(f32, 3.0), sqrt(@as(f32, 9.0)));
}

test "clamp i32" {
    try std.testing.expectEqual(@as(i32, 5), clamp(@as(i32, 5), @as(i32, 0), @as(i32, 10)));
}
