// json.zig — JSON parsing, querying, and building sidecar for std::json
// Supports dot-path traversal for nested access.

const std = @import("std");

const alloc = std.heap.page_allocator;

// ── Dot-Path Resolver ──
// Walks a parsed JSON value by splitting path on '.'

fn resolve(root: std.json.Value, path: []const u8) ?std.json.Value {
    var current = root;
    var remaining = path;

    while (remaining.len > 0) {
        // Find the next dot or take the rest
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const segment = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else "";

        switch (current) {
            .object => |obj| {
                if (obj.get(segment)) |val| {
                    current = val;
                } else {
                    return null;
                }
            },
            else => return null,
        }
    }
    return current;
}

fn valueToString(val: std.json.Value) anyerror![]const u8 {
    return switch (val) {
        .string => |s| alloc.dupe(u8, s) catch return error.out_of_memory,
        .integer => |n| std.fmt.allocPrint(alloc, "{d}", .{n}) catch return error.out_of_memory,
        .float => |f| std.fmt.allocPrint(alloc, "{d}", .{f}) catch return error.out_of_memory,
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => return error.unsupported_value_type,
    };
}

// ── Get ──
// Extract a value at a dot-path as a string.

pub fn get(source: []const u8, path: []const u8) anyerror![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    const val = resolve(parsed.value, path) orelse {
        return error.path_not_found;
    };
    return valueToString(val);
}

// ── GetInt ──

pub fn getInt(source: []const u8, path: []const u8) anyerror!i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    const val = resolve(parsed.value, path) orelse {
        return error.path_not_found;
    };
    return switch (val) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => return error.value_is_not_an_integer,
    };
}

// ── GetFloat ──

pub fn getFloat(source: []const u8, path: []const u8) anyerror!f64 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    const val = resolve(parsed.value, path) orelse {
        return error.path_not_found;
    };
    return switch (val) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => return error.value_is_not_a_float,
    };
}

// ── GetBool ──

pub fn getBool(source: []const u8, path: []const u8) anyerror!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    const val = resolve(parsed.value, path) orelse {
        return error.path_not_found;
    };
    return switch (val) {
        .bool => |b| b,
        else => return error.value_is_not_a_boolean,
    };
}

// ── GetArray ──
// Returns newline-separated string representations of array elements.

pub fn getArray(source: []const u8, path: []const u8) anyerror![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    const val = resolve(parsed.value, path) orelse {
        return error.path_not_found;
    };
    return switch (val) {
        .array => |arr| {
            var buf = std.ArrayListUnmanaged(u8){};
            for (arr.items, 0..) |item, i| {
                if (i > 0) buf.append(alloc, '\n') catch {};
                const s = valueToString(item) catch continue;
                buf.appendSlice(alloc, s) catch {};
            }
            return if (buf.items.len > 0) buf.items else "";
        },
        else => return error.value_is_not_an_array,
    };
}

// ── HasKey ──

pub fn hasKey(source: []const u8, key: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch return false;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |obj| obj.contains(key),
        else => false,
    };
}

// ── Object ──
// Build a JSON object string from parallel key/value slices.
// Values are auto-detected: numbers, booleans, null stay unquoted.

pub fn object(keys: anytype, values: anytype) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.append(alloc, '{') catch return "{}";
    for (keys, 0..) |key, i| {
        if (i > 0) buf.append(alloc, ',') catch {};
        buf.append(alloc, '"') catch {};
        buf.appendSlice(alloc, key) catch {};
        buf.appendSlice(alloc, "\":") catch {};
        const val: []const u8 = values[i];
        if (isJsonLiteral(val)) {
            buf.appendSlice(alloc, val) catch {};
        } else {
            buf.append(alloc, '"') catch {};
            buf.appendSlice(alloc, val) catch {};
            buf.append(alloc, '"') catch {};
        }
    }
    buf.append(alloc, '}') catch {};
    return buf.items;
}

fn isJsonLiteral(val: []const u8) bool {
    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "null")) return true;
    // Check if it looks like a number
    if (val.len == 0) return false;
    var i: usize = 0;
    if (val[0] == '-') i = 1;
    if (i >= val.len) return false;
    var has_dot = false;
    while (i < val.len) : (i += 1) {
        if (val[i] == '.' and !has_dot) {
            has_dot = true;
        } else if (val[i] < '0' or val[i] > '9') {
            return false;
        }
    }
    return true;
}

// ── Stringify ──

pub fn stringify(value: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, "{any}", .{value}) catch return "";
}

// ── Pretty ──
// Re-parse and emit with 4-space indentation.

pub fn pretty(source: []const u8) anyerror![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return error.invalid_json;
    };
    defer parsed.deinit();

    var buf = std.ArrayListUnmanaged(u8){};
    std.json.stringify(parsed.value, .{ .whitespace = .{ .indent = .{ .space = 4 } } }, buf.writer(alloc)) catch {
        return error.formatting_failed;
    };
    return buf.items;
}

// ── Tests ──

test "get top-level string" {
    const result = try get("{\"name\":\"orhon\"}", "name");
    try std.testing.expect(std.mem.eql(u8, result, "orhon"));
}

test "get nested value" {
    const result = try get("{\"user\":{\"name\":\"yunus\"}}", "user.name");
    try std.testing.expect(std.mem.eql(u8, result, "yunus"));
}

test "get deeply nested" {
    const result = try get("{\"a\":{\"b\":{\"c\":\"deep\"}}}", "a.b.c");
    try std.testing.expect(std.mem.eql(u8, result, "deep"));
}

test "get missing path" {
    const result = get("{\"a\":{\"b\":1}}", "a.c");
    try std.testing.expectError(error.path_not_found, result);
}

test "getInt" {
    const result = try getInt("{\"count\":42}", "count");
    try std.testing.expectEqual(@as(i64, 42), result);
}

test "getFloat" {
    const result = try getFloat("{\"pi\":3.14}", "pi");
    try std.testing.expect(result > 3.13 and result < 3.15);
}

test "getBool" {
    const result = try getBool("{\"active\":true}", "active");
    try std.testing.expect(result);
}

test "getArray" {
    const result = try getArray("{\"tags\":[\"a\",\"b\",\"c\"]}", "tags");
    try std.testing.expect(std.mem.eql(u8, result, "a\nb\nc"));
}

test "getArray nested" {
    const result = try getArray("{\"data\":{\"ids\":[1,2,3]}}", "data.ids");
    try std.testing.expect(std.mem.eql(u8, result, "1\n2\n3"));
}

test "hasKey" {
    try std.testing.expect(hasKey("{\"name\":\"orhon\"}", "name"));
    try std.testing.expect(!hasKey("{\"name\":\"orhon\"}", "age"));
}

test "object with typed values" {
    const keys = [_][]const u8{ "name", "count", "active" };
    const vals = [_][]const u8{ "orhon", "42", "true" };
    const result = object(&keys, &vals);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"orhon\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"count\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"active\":true") != null);
}

test "pretty" {
    const result = try pretty("{\"a\":1}");
    try std.testing.expect(std.mem.indexOf(u8, result, "\n") != null);
}

test "invalid json" {
    const result = get("not json", "key");
    try std.testing.expectError(error.invalid_json, result);
}
