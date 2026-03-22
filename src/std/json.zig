// json.zig — JSON parsing and serialization sidecar for std::json
// Minimal JSON operations on raw strings. No DOM tree.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Get ──
// Extract a string value for a key from a JSON object string.
// Only handles top-level string values: {"key": "value"}

pub fn get(source: []const u8, key: []const u8) OrhonResult([]const u8) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return .{ .err = .{ .message = "invalid JSON" } };
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |obj| {
            if (obj.get(key)) |val| {
                switch (val) {
                    .string => |s| {
                        return .{ .ok = alloc.dupe(u8, s) catch return .{ .err = .{ .message = "out of memory" } } };
                    },
                    .integer => |n| {
                        return .{ .ok = std.fmt.allocPrint(alloc, "{d}", .{n}) catch return .{ .err = .{ .message = "out of memory" } } };
                    },
                    .float => |f| {
                        return .{ .ok = std.fmt.allocPrint(alloc, "{d}", .{f}) catch return .{ .err = .{ .message = "out of memory" } } };
                    },
                    .bool => |b| {
                        return .{ .ok = if (b) "true" else "false" };
                    },
                    .null => return .{ .ok = "null" },
                    else => return .{ .err = .{ .message = "unsupported value type" } },
                }
            }
            return .{ .err = .{ .message = "key not found" } };
        },
        else => return .{ .err = .{ .message = "not a JSON object" } },
    }
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

pub fn object(keys: anytype, values: anytype) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    buf.append(alloc, '{') catch return "{}";
    for (keys, 0..) |key, i| {
        if (i > 0) buf.append(alloc, ',') catch {};
        buf.append(alloc, '"') catch {};
        buf.appendSlice(alloc, key) catch {};
        buf.appendSlice(alloc, "\":\"") catch {};
        buf.appendSlice(alloc, values[i]) catch {};
        buf.append(alloc, '"') catch {};
    }
    buf.append(alloc, '}') catch {};
    return buf.items;
}

// ── Stringify ──

pub fn stringify(value: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, "{any}", .{value}) catch return "";
}

// ── Tests ──

test "get string value" {
    const result = get("{\"name\":\"orhon\"}", "name");
    try std.testing.expect(result == .ok);
    try std.testing.expect(std.mem.eql(u8, result.ok, "orhon"));
}

test "get missing key" {
    const result = get("{\"name\":\"orhon\"}", "age");
    try std.testing.expect(result == .err);
}

test "hasKey" {
    try std.testing.expect(hasKey("{\"name\":\"orhon\"}", "name"));
    try std.testing.expect(!hasKey("{\"name\":\"orhon\"}", "age"));
}
