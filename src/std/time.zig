// time.zig — time operations implementation for Kodr's std::time
// Hand-written implementation. Paired with time.kodr.
// Do not edit the generated time.zig in .kodr-cache/generated/ —
// edit this source file and run kodr initstd to update.

const std = @import("std");

pub fn now() i64 {
    return std.time.timestamp();
}

pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}

pub fn sleep(ms: i64) void {
    const ns: u64 = if (ms > 0) @intCast(@as(i64, ms) * std.time.ns_per_ms) else 0;
    std.time.sleep(ns);
}

pub fn elapsed(start: i64, end: i64) i64 {
    return end - start;
}
