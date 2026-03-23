// csv.zig — CSV parsing sidecar for std::csv
// RFC 4180 compatible: handles quoted fields, embedded commas, escaped quotes.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Internal: Parse CSV into rows of fields ──

const ParsedCsv = struct {
    rows: []const []const []const u8,
};

fn parseCsv(source: []const u8) ParsedCsv {
    var rows = std.ArrayListUnmanaged([]const []const u8){};
    var fields = std.ArrayListUnmanaged([]const u8){};
    var field = std.ArrayListUnmanaged(u8){};
    var in_quotes = false;
    var i: usize = 0;

    while (i < source.len) : (i += 1) {
        const c = source[i];

        if (in_quotes) {
            if (c == '"') {
                // Check for escaped quote ("")
                if (i + 1 < source.len and source[i + 1] == '"') {
                    field.append(alloc, '"') catch {};
                    i += 1;
                } else {
                    in_quotes = false;
                }
            } else {
                field.append(alloc, c) catch {};
            }
        } else {
            if (c == '"') {
                in_quotes = true;
            } else if (c == ',') {
                fields.append(alloc, dupe(field.items)) catch {};
                field.clearRetainingCapacity();
            } else if (c == '\n' or (c == '\r' and i + 1 < source.len and source[i + 1] == '\n')) {
                fields.append(alloc, dupe(field.items)) catch {};
                field.clearRetainingCapacity();
                rows.append(alloc, dupeSlice(fields.items)) catch {};
                fields.clearRetainingCapacity();
                if (c == '\r') i += 1; // skip \n after \r
            } else if (c == '\r') {
                fields.append(alloc, dupe(field.items)) catch {};
                field.clearRetainingCapacity();
                rows.append(alloc, dupeSlice(fields.items)) catch {};
                fields.clearRetainingCapacity();
            } else {
                field.append(alloc, c) catch {};
            }
        }
    }

    // Last field and row
    if (field.items.len > 0 or fields.items.len > 0) {
        fields.append(alloc, dupe(field.items)) catch {};
        rows.append(alloc, dupeSlice(fields.items)) catch {};
    }

    return .{ .rows = rows.items };
}

fn dupe(src: []const u8) []const u8 {
    return alloc.dupe(u8, src) catch return "";
}

fn dupeSlice(src: []const []const u8) []const []const u8 {
    return alloc.dupe([]const u8, src) catch return &.{};
}

// ── GetField ──

pub fn getField(source: []const u8, row: i32, col: i32) OrhonResult([]const u8) {
    const csv = parseCsv(source);
    const r: usize = std.math.cast(usize, row) orelse return .{ .err = .{ .message = "invalid row" } };
    const c: usize = std.math.cast(usize, col) orelse return .{ .err = .{ .message = "invalid column" } };
    if (r >= csv.rows.len) return .{ .err = .{ .message = "row out of range" } };
    const fields = csv.rows[r];
    if (c >= fields.len) return .{ .err = .{ .message = "column out of range" } };
    return .{ .ok = fields[c] };
}

// ── GetRow ──

pub fn getRow(source: []const u8, row: i32) OrhonResult([]const u8) {
    const csv = parseCsv(source);
    const r: usize = std.math.cast(usize, row) orelse return .{ .err = .{ .message = "invalid row" } };
    if (r >= csv.rows.len) return .{ .err = .{ .message = "row out of range" } };
    const fields = csv.rows[r];

    var buf = std.ArrayListUnmanaged(u8){};
    for (fields, 0..) |f, i| {
        if (i > 0) buf.append(alloc, '\t') catch {};
        buf.appendSlice(alloc, f) catch {};
    }
    return .{ .ok = if (buf.items.len > 0) buf.items else "" };
}

// ── RowCount ──

pub fn rowCount(source: []const u8) i32 {
    const csv = parseCsv(source);
    return @intCast(csv.rows.len);
}

// ── ColCount ──

pub fn colCount(source: []const u8) i32 {
    const csv = parseCsv(source);
    if (csv.rows.len == 0) return 0;
    return @intCast(csv.rows[0].len);
}

// ── Tests ──

test "basic csv" {
    const data = "name,age,city\nalice,30,berlin\nbob,25,tokyo";
    try std.testing.expectEqual(@as(i32, 3), rowCount(data));
    try std.testing.expectEqual(@as(i32, 3), colCount(data));
}

test "getField" {
    const data = "name,age\nalice,30\nbob,25";
    const r = getField(data, 1, 0);
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "alice"));
    const r2 = getField(data, 2, 1);
    try std.testing.expect(r2 == .ok);
    try std.testing.expect(std.mem.eql(u8, r2.ok, "25"));
}

test "getRow" {
    const data = "a,b,c\n1,2,3";
    const r = getRow(data, 1);
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "1\t2\t3"));
}

test "quoted fields" {
    const data = "name,bio\nalice,\"likes, commas\"\nbob,\"says \"\"hi\"\"\"";
    const r1 = getField(data, 1, 1);
    try std.testing.expect(r1 == .ok);
    try std.testing.expect(std.mem.eql(u8, r1.ok, "likes, commas"));
    const r2 = getField(data, 2, 1);
    try std.testing.expect(r2 == .ok);
    try std.testing.expect(std.mem.eql(u8, r2.ok, "says \"hi\""));
}

test "out of range" {
    const data = "a,b\n1,2";
    try std.testing.expect(getField(data, 5, 0) == .err);
    try std.testing.expect(getField(data, 0, 5) == .err);
}
