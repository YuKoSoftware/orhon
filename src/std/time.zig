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

// ── Date Operations ──

fn epochFromMs(ms: i64) std.time.epoch.EpochSeconds {
    return .{ .secs = @intCast(@divTrunc(ms, 1000)) };
}

pub fn parseDate(date: []const u8) anyerror!i64 {
    // Parse "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SSZ"
    if (date.len < 10) return error.invalid_date_format;
    const y = std.fmt.parseInt(i32, date[0..4], 10) catch return error.invalid_year;
    if (date[4] != '-') return error.invalid_date_format;
    const m = std.fmt.parseInt(u32, date[5..7], 10) catch return error.invalid_month;
    if (date[7] != '-') return error.invalid_date_format;
    const d = std.fmt.parseInt(u32, date[8..10], 10) catch return error.invalid_day;

    if (m < 1 or m > 12 or d < 1 or d > 31) return error.date_out_of_range;

    var h: u32 = 0;
    var min: u32 = 0;
    var sec: u32 = 0;
    if (date.len >= 19 and date[10] == 'T') {
        h = std.fmt.parseInt(u32, date[11..13], 10) catch 0;
        min = std.fmt.parseInt(u32, date[14..16], 10) catch 0;
        sec = std.fmt.parseInt(u32, date[17..19], 10) catch 0;
    }

    // Calculate days from epoch using Zig's epoch utilities
    // Days from year 0 to epoch (1970-01-01)
    const year_u: u32 = @intCast(y);
    const leap_years = (year_u - 1) / 4 - (year_u - 1) / 100 + (year_u - 1) / 400;
    const epoch_leap = (1969) / 4 - (1969) / 100 + (1969) / 400;
    const year_days = @as(i64, year_u - 1970) * 365 + @as(i64, leap_years) - @as(i64, epoch_leap);

    const is_leap = (year_u % 4 == 0 and year_u % 100 != 0) or (year_u % 400 == 0);
    const month_days_normal = [_]u32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const month_days_leap = [_]u32{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 };
    const md = if (is_leap) month_days_leap else month_days_normal;
    const day_of_year: i64 = @intCast(md[m - 1] + d - 1);

    const total_secs = (year_days + day_of_year) * 86400 + @as(i64, h) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
    return total_secs * 1000;
}

pub fn year(ms: i64) i32 {
    const es = epochFromMs(ms);
    const yd = es.getEpochDay().calculateYearDay();
    return @intCast(yd.year);
}

pub fn month(ms: i64) i32 {
    const es = epochFromMs(ms);
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return @intCast(md.month.numeric());
}

pub fn day(ms: i64) i32 {
    const es = epochFromMs(ms);
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return @intCast(md.day_index + 1);
}

pub fn weekday(ms: i64) i32 {
    // 1970-01-01 was a Thursday (3). Days since epoch mod 7.
    const days = @divTrunc(ms, 86400 * 1000);
    const wd = @mod(days + 3, 7); // 0=Monday, 6=Sunday
    return @intCast(wd);
}

pub fn addDays(ms: i64, days: i32) i64 {
    return ms + @as(i64, days) * 86400 * 1000;
}

pub fn addHours(ms: i64, hours: i32) i64 {
    return ms + @as(i64, hours) * 3600 * 1000;
}

pub fn diffDays(a: i64, b: i64) i32 {
    const diff = @divTrunc(a - b, 86400 * 1000);
    return @intCast(diff);
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

test "parseDate" {
    const r = try parseDate("1970-01-01");
    try std.testing.expectEqual(@as(i64, 0), r);
}

test "parseDate with time" {
    const r = try parseDate("1970-01-01T00:00:01Z");
    try std.testing.expectEqual(@as(i64, 1000), r);
}

test "year month day" {
    const r = try parseDate("2026-03-23");
    try std.testing.expectEqual(@as(i32, 2026), year(r));
    try std.testing.expectEqual(@as(i32, 3), month(r));
    try std.testing.expectEqual(@as(i32, 23), day(r));
}

test "weekday" {
    // 1970-01-01 was Thursday = 3
    try std.testing.expectEqual(@as(i32, 3), weekday(0));
}

test "addDays" {
    const one_day = addDays(0, 1);
    try std.testing.expectEqual(@as(i64, 86400 * 1000), one_day);
}

test "diffDays" {
    const day_ms: i64 = 86400 * 1000;
    try std.testing.expectEqual(@as(i32, 7), diffDays(7 * day_ms, 0));
}
