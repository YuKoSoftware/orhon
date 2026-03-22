// time.zig — time and duration sidecar for std::time

const std = @import("std");

const alloc = std.heap.page_allocator;

// ── Now ──

pub fn now() i64 {
    return @divTrunc(std.time.milliTimestamp(), 1);
}

pub fn nowNano() i64 {
    return @intCast(@as(i128, std.time.nanoTimestamp()));
}

// ── Sleep ──

pub fn sleepMs(ms: i32) void {
    if (ms <= 0) return;
    const ns: u64 = @intCast(ms);
    std.time.sleep(ns * std.time.ns_per_ms);
}

pub fn sleepSec(sec: i32) void {
    if (sec <= 0) return;
    const ns: u64 = @intCast(sec);
    std.time.sleep(ns * std.time.ns_per_s);
}

// ── Elapsed ──

pub fn elapsed(start: i64) i64 {
    const now_ns: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
    return now_ns - start;
}

// ── Format ──
// Simple ISO 8601 date/time from milliseconds since epoch

pub fn format(ms: i64) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    }) catch return "";
}

// ── Tests ──

test "now is positive" {
    try std.testing.expect(now() > 0);
}

test "nowNano is positive" {
    try std.testing.expect(nowNano() > 0);
}

test "elapsed" {
    const start = nowNano();
    const e = elapsed(start);
    try std.testing.expect(e >= 0);
}

test "format" {
    const s = format(0);
    try std.testing.expect(std.mem.eql(u8, s, "1970-01-01T00:00:00Z"));
}
