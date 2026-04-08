// simd.zig — SIMD vector intrinsics sidecar for std::simd
// Wraps Zig's @reduce, @splat, @shuffle builtins for common vector types.

// ── Reduction ──

/// Sums all 4 elements of an f32x4 vector.
pub fn reduceAddF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Add, v);
}

/// Sums both elements of an f64x2 vector.
pub fn reduceAddF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Add, v);
}

/// Sums all 4 elements of an i32x4 vector.
pub fn reduceAddI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Add, v);
}

/// Multiplies all 4 elements of an f32x4 vector.
pub fn reduceMulF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Mul, v);
}

/// Multiplies both elements of an f64x2 vector.
pub fn reduceMulF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Mul, v);
}

/// Returns the minimum element of an f32x4 vector.
pub fn reduceMinF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Min, v);
}

/// Returns the minimum element of an f64x2 vector.
pub fn reduceMinF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Min, v);
}

/// Returns the minimum element of an i32x4 vector.
pub fn reduceMinI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Min, v);
}

/// Returns the maximum element of an f32x4 vector.
pub fn reduceMaxF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Max, v);
}

/// Returns the maximum element of an f64x2 vector.
pub fn reduceMaxF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Max, v);
}

/// Returns the maximum element of an i32x4 vector.
pub fn reduceMaxI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Max, v);
}

// ── Splat ──

/// Broadcasts a scalar f32 to all 4 lanes of an f32x4 vector.
pub fn splatF32(val: f32) @Vector(4, f32) {
    return @splat(val);
}

/// Broadcasts a scalar f64 to both lanes of an f64x2 vector.
pub fn splatF64(val: f64) @Vector(2, f64) {
    return @splat(val);
}

/// Broadcasts a scalar i32 to all 4 lanes of an i32x4 vector.
pub fn splatI32(val: i32) @Vector(4, i32) {
    return @splat(val);
}

// ── Wide splat ──

/// Broadcasts a scalar f32 to all 8 lanes of an f32x8 vector.
pub fn splatF32x8(val: f32) @Vector(8, f32) {
    return @splat(val);
}

/// Broadcasts a scalar i32 to all 8 lanes of an i32x8 vector.
pub fn splatI32x8(val: i32) @Vector(8, i32) {
    return @splat(val);
}

// ── Reverse ──

/// Reverses the lane order of an f32x4 vector.
pub fn reverseF32(v: @Vector(4, f32)) @Vector(4, f32) {
    return @shuffle(f32, v, undefined, [4]i32{ 3, 2, 1, 0 });
}

/// Reverses the lane order of an f64x2 vector.
pub fn reverseF64(v: @Vector(2, f64)) @Vector(2, f64) {
    return @shuffle(f64, v, undefined, [2]i32{ 1, 0 });
}

/// Reverses the lane order of an i32x4 vector.
pub fn reverseI32(v: @Vector(4, i32)) @Vector(4, i32) {
    return @shuffle(i32, v, undefined, [4]i32{ 3, 2, 1, 0 });
}
