// simd.zig — SIMD vector intrinsics sidecar for std::simd
// Wraps Zig's @reduce, @splat, @shuffle builtins for common vector types.

// ── Reduction ──

pub fn reduceAddF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Add, v);
}

pub fn reduceAddF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Add, v);
}

pub fn reduceAddI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Add, v);
}

pub fn reduceMulF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Mul, v);
}

pub fn reduceMulF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Mul, v);
}

pub fn reduceMinF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Min, v);
}

pub fn reduceMinF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Min, v);
}

pub fn reduceMinI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Min, v);
}

pub fn reduceMaxF32(v: @Vector(4, f32)) f32 {
    return @reduce(.Max, v);
}

pub fn reduceMaxF64(v: @Vector(2, f64)) f64 {
    return @reduce(.Max, v);
}

pub fn reduceMaxI32(v: @Vector(4, i32)) i32 {
    return @reduce(.Max, v);
}

// ── Splat ──

pub fn splatF32(val: f32) @Vector(4, f32) {
    return @splat(val);
}

pub fn splatF64(val: f64) @Vector(2, f64) {
    return @splat(val);
}

pub fn splatI32(val: i32) @Vector(4, i32) {
    return @splat(val);
}

// ── Wide splat ──

pub fn splatF32x8(val: f32) @Vector(8, f32) {
    return @splat(val);
}

pub fn splatI32x8(val: i32) @Vector(8, i32) {
    return @splat(val);
}

// ── Reverse ──

pub fn reverseF32(v: @Vector(4, f32)) @Vector(4, f32) {
    return @shuffle(f32, v, undefined, [4]i32{ 3, 2, 1, 0 });
}

pub fn reverseF64(v: @Vector(2, f64)) @Vector(2, f64) {
    return @shuffle(f64, v, undefined, [2]i32{ 1, 0 });
}

pub fn reverseI32(v: @Vector(4, i32)) @Vector(4, i32) {
    return @shuffle(i32, v, undefined, [4]i32{ 3, 2, 1, 0 });
}
