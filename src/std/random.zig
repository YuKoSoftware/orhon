// random.zig — random number generation sidecar for std::random
// Uses Zig's xoshiro256 PRNG. Seeded from system entropy by default.

const std = @import("std");

var rng: std.Random.Xoshiro256 = std.Random.Xoshiro256.init(0);
var initialized = false;

fn ensureInit() void {
    if (!initialized) {
        rng = std.Random.Xoshiro256.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
        initialized = true;
    }
}

// ── Integer ──

pub fn int(lo: i32, hi: i32) i32 {
    ensureInit();
    if (lo >= hi) return lo;
    const range: u32 = @intCast(hi - lo + 1);
    const r: i32 = @intCast(rng.random().uintLessThan(u32, range));
    return lo + r;
}

// ── Float ──

pub fn float() f64 {
    ensureInit();
    return rng.random().float(f64);
}

pub fn floatRange(lo: f64, hi: f64) f64 {
    ensureInit();
    return lo + rng.random().float(f64) * (hi - lo);
}

// ── Bool ──

pub fn boolean() bool {
    ensureInit();
    return rng.random().boolean();
}

// ── Seed ──

pub fn seed(s: u64) void {
    if (s == 0) {
        rng = std.Random.Xoshiro256.init(@truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    } else {
        rng = std.Random.Xoshiro256.init(s);
    }
    initialized = true;
}

// ── Tests ──

test "int in range" {
    seed(42);
    const v = int(1, 10);
    try std.testing.expect(v >= 1 and v <= 10);
}

test "float in 0..1" {
    seed(42);
    const v = float();
    try std.testing.expect(v >= 0.0 and v < 1.0);
}

test "boolean" {
    seed(42);
    _ = boolean(); // just verify it doesn't crash
}
