// math.zig — mathematical functions sidecar for std::math
// Wraps Zig's std.math. Pure functions, no allocation, no state.
// All functions are generic — work with any numeric type (f32, f64, i32, i64, etc.).

const std = @import("std");

// ── Basic ──

/// Returns the absolute value of x.
pub fn abs(x: anytype) @TypeOf(x) {
    return @abs(x);
}

/// Returns the smaller of a and b.
pub fn min(a: anytype, b: anytype) @TypeOf(a, b) {
    return @min(a, b);
}

/// Returns the larger of a and b.
pub fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    return @max(a, b);
}

/// Clamps x to the range [lo, hi].
pub fn clamp(x: anytype, lo: anytype, hi: anytype) @TypeOf(x, lo, hi) {
    return @max(lo, @min(x, hi));
}

// ── Rounding (float types) ──

/// Rounds x down to the nearest integer toward negative infinity.
pub fn floor(x: anytype) @TypeOf(x) {
    return @floor(x);
}

/// Rounds x up to the nearest integer toward positive infinity.
pub fn ceil(x: anytype) @TypeOf(x) {
    return @ceil(x);
}

/// Rounds x to the nearest integer, ties away from zero.
pub fn round(x: anytype) @TypeOf(x) {
    return @round(x);
}

// ── Powers and roots (float types) ──

/// Returns the square root of x.
pub fn sqrt(x: anytype) @TypeOf(x) {
    return @sqrt(x);
}

/// Returns base raised to the power of exponent.
pub fn pow(base: anytype, exponent: anytype) @TypeOf(base, exponent) {
    return std.math.pow(@TypeOf(base, exponent), base, exponent);
}

/// Returns the natural logarithm of x.
pub fn log(x: anytype) @TypeOf(x) {
    return @log(x);
}

/// Returns the base-2 logarithm of x.
pub fn log2(x: anytype) @TypeOf(x) {
    return @log2(x);
}

/// Returns the base-10 logarithm of x.
pub fn log10(x: anytype) @TypeOf(x) {
    return @log10(x);
}

/// Returns e raised to the power of x.
pub fn exp(x: anytype) @TypeOf(x) {
    return @exp(x);
}

// ── Trigonometry (float types) ──

/// Returns the sine of x in radians.
pub fn sin(x: anytype) @TypeOf(x) {
    return @sin(x);
}

/// Returns the cosine of x in radians.
pub fn cos(x: anytype) @TypeOf(x) {
    return @cos(x);
}

/// Returns the tangent of x in radians.
pub fn tan(x: anytype) @TypeOf(x) {
    return @tan(x);
}

/// Returns the arc sine of x in radians.
pub fn asin(x: anytype) @TypeOf(x) {
    return std.math.asin(x);
}

/// Returns the arc cosine of x in radians.
pub fn acos(x: anytype) @TypeOf(x) {
    return std.math.acos(x);
}

/// Returns the arc tangent of x in radians.
pub fn atan(x: anytype) @TypeOf(x) {
    return std.math.atan(x);
}

/// Returns the arc tangent of y/x, using signs to determine the quadrant.
pub fn atan2(y: anytype, x: anytype) @TypeOf(x, y) {
    return std.math.atan2(y, x);
}

// ── Constants ──

/// Returns the mathematical constant pi.
pub fn pi() f64 {
    return std.math.pi;
}

/// Returns Euler's number (e).
pub fn e() f64 {
    return std.math.e;
}

/// Returns positive infinity as f64.
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

test "pow f64" {
    try std.testing.expectEqual(@as(f64, 8.0), pow(@as(f64, 2.0), @as(f64, 3.0)));
}

test "log and exp roundtrip" {
    const x: f64 = 10.0;
    try std.testing.expectApproxEqAbs(x, exp(log(x)), 1e-10);
}

test "log2 f64" {
    try std.testing.expectEqual(@as(f64, 3.0), log2(@as(f64, 8.0)));
}

test "log10 f64" {
    try std.testing.expectEqual(@as(f64, 2.0), log10(@as(f64, 100.0)));
}

test "sin cos identity" {
    const x: f64 = 1.0;
    const s = sin(x);
    const c = cos(x);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), s * s + c * c, 1e-10);
}

test "pi and e constants" {
    try std.testing.expectApproxEqAbs(@as(f64, 3.14159), pi(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.71828), e(), 0.001);
}

test "inf is infinite" {
    try std.testing.expect(std.math.isInf(inf()));
}
