// toml.zig — TOML parsing sidecar for std::toml
// Supports: strings, integers, floats, booleans, arrays, tables, nested dot-keys.
// Does NOT support: inline tables, datetime, multiline strings, array of tables.

const std = @import("std");
const allocator = @import("allocator.zig");

const alloc = allocator.default;

// ── Value Types ──

const ValueTag = enum { string, integer, float, boolean, array, table };

const Value = struct {
    tag: ValueTag,
    string: []const u8 = "",
    integer: i64 = 0,
    float: f64 = 0,
    boolean: bool = false,
    array_items: []const Value = &.{},
    table_entries: []const TableEntry = &.{},
};

const TableEntry = struct {
    key: []const u8,
    value: Value,
};

// ── Parser ──

fn parseToml(source: []const u8) Value {
    var root_entries = std.ArrayListUnmanaged(TableEntry){};
    var current_path: []const u8 = "";

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Table header [table.name]
        if (line[0] == '[' and (line.len < 2 or line[1] != '[')) {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current_path = alloc.dupe(u8, std.mem.trim(u8, line[1..end], " \t")) catch "";
            continue;
        }

        // Key = Value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val_str = std.mem.trim(u8, line[eq + 1 ..], " \t");
            const value = parseValue(val_str);

            const full_key = if (current_path.len > 0)
                std.fmt.allocPrint(alloc, "{s}.{s}", .{ current_path, key }) catch key
            else
                alloc.dupe(u8, key) catch key;

            root_entries.append(alloc, .{ .key = full_key, .value = value }) catch continue;
        }
    }

    return .{ .tag = .table, .table_entries = root_entries.items };
}

fn parseValue(src: []const u8) Value {
    if (src.len == 0) return .{ .tag = .string };

    // Boolean
    if (std.mem.eql(u8, src, "true")) return .{ .tag = .boolean, .boolean = true };
    if (std.mem.eql(u8, src, "false")) return .{ .tag = .boolean, .boolean = false };

    // Quoted string
    if (src[0] == '"' and src.len >= 2 and src[src.len - 1] == '"') {
        return .{ .tag = .string, .string = alloc.dupe(u8, src[1 .. src.len - 1]) catch "" };
    }
    if (src[0] == '\'' and src.len >= 2 and src[src.len - 1] == '\'') {
        return .{ .tag = .string, .string = alloc.dupe(u8, src[1 .. src.len - 1]) catch "" };
    }

    // Array [a, b, c]
    if (src[0] == '[' and src[src.len - 1] == ']') {
        return parseArray(src[1 .. src.len - 1]);
    }

    // Integer
    if (std.fmt.parseInt(i64, src, 10)) |n| {
        return .{ .tag = .integer, .integer = n };
    } else |_| {}

    // Float
    if (std.fmt.parseFloat(f64, src)) |f| {
        return .{ .tag = .float, .float = f };
    } else |_| {}

    // Bare string (unquoted value)
    return .{ .tag = .string, .string = alloc.dupe(u8, src) catch "" };
}

fn parseArray(inner: []const u8) Value {
    var items = std.ArrayListUnmanaged(Value){};
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i < inner.len) : (i += 1) {
        if (inner[i] == '[') depth += 1;
        if (inner[i] == ']') depth -= 1;
        if (inner[i] == ',' and depth == 0) {
            const elem = std.mem.trim(u8, inner[start..i], " \t");
            if (elem.len > 0) items.append(alloc, parseValue(elem)) catch continue;
            start = i + 1;
        }
    }
    // Last element
    const last = std.mem.trim(u8, inner[start..], " \t");
    if (last.len > 0) items.append(alloc, parseValue(last)) catch return .{ .tag = .array, .array_items = items.items };

    return .{ .tag = .array, .array_items = items.items };
}

// ── Path Resolution ──

fn resolveValue(root: Value, path: []const u8) ?Value {
    if (root.tag != .table) return null;
    // First try exact match on flattened keys
    for (root.table_entries) |entry| {
        if (std.mem.eql(u8, entry.key, path)) return entry.value;
    }
    // Try prefix match for nested table access
    const prefix = std.fmt.allocPrint(alloc, "{s}.", .{path}) catch return null;
    var found = false;
    for (root.table_entries) |entry| {
        if (std.mem.startsWith(u8, entry.key, prefix)) {
            found = true;
            break;
        }
    }
    if (found) {
        // Return a synthetic table with matching entries
        var sub_entries = std.ArrayListUnmanaged(TableEntry){};
        for (root.table_entries) |entry| {
            if (std.mem.startsWith(u8, entry.key, prefix)) {
                sub_entries.append(alloc, .{
                    .key = entry.key[prefix.len..],
                    .value = entry.value,
                }) catch continue;
            }
        }
        return .{ .tag = .table, .table_entries = sub_entries.items };
    }
    return null;
}

fn valueToString(val: Value) []const u8 {
    return switch (val.tag) {
        .string => val.string,
        .integer => std.fmt.allocPrint(alloc, "{d}", .{val.integer}) catch "",
        .float => std.fmt.allocPrint(alloc, "{d}", .{val.float}) catch "",
        .boolean => if (val.boolean) "true" else "false",
        .array, .table => "",
    };
}

// ── Public API ──

/// Returns the string value at the given dot-separated TOML key path.
pub fn get(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseToml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    const s = valueToString(val);
    if (s.len == 0 and val.tag != .string) return error.value_is_not_a_string;
    return s;
}

/// Returns the integer value at the given TOML key path.
pub fn getInt(source: []const u8, path: []const u8) anyerror!i64 {
    const root = parseToml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => return error.value_is_not_an_integer,
    };
}

/// Returns the float value at the given TOML key path.
pub fn getFloat(source: []const u8, path: []const u8) anyerror!f64 {
    const root = parseToml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => return error.value_is_not_a_float,
    };
}

/// Returns the boolean value at the given TOML key path.
pub fn getBool(source: []const u8, path: []const u8) anyerror!bool {
    const root = parseToml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .boolean => val.boolean,
        else => return error.value_is_not_a_boolean,
    };
}

/// Returns the array elements at the given TOML key path as a newline-separated string.
pub fn getArray(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseToml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    if (val.tag != .array) return error.value_is_not_an_array;

    var buf = std.ArrayListUnmanaged(u8){};
    for (val.array_items, 0..) |item, i| {
        if (i > 0) buf.append(alloc, '\n') catch continue;
        buf.appendSlice(alloc, valueToString(item)) catch continue;
    }
    return if (buf.items.len > 0) buf.items else "";
}

/// Returns true if the given dot-separated key path exists in the TOML source.
pub fn hasKey(source: []const u8, path: []const u8) bool {
    const root = parseToml(source);
    return resolveValue(root, path) != null;
}

/// Returns all direct key names within the given TOML table, newline-separated.
pub fn getKeys(source: []const u8, table: []const u8) anyerror![]const u8 {
    const root = parseToml(source);

    const prefix = if (table.len > 0)
        std.fmt.allocPrint(alloc, "{s}.", .{table}) catch return error.out_of_memory
    else
        "";

    var buf = std.ArrayListUnmanaged(u8){};
    var key_count: usize = 0;
    for (root.table_entries) |entry| {
        const key = if (prefix.len > 0) blk: {
            if (std.mem.startsWith(u8, entry.key, prefix)) {
                const remainder = entry.key[prefix.len..];
                // Only direct children (no more dots)
                if (std.mem.indexOfScalar(u8, remainder, '.') == null) {
                    break :blk remainder;
                }
            }
            continue;
        } else blk: {
            if (std.mem.indexOfScalar(u8, entry.key, '.') == null) {
                break :blk entry.key;
            }
            continue;
        };
        if (key_count > 0) buf.append(alloc, '\n') catch continue;
        buf.appendSlice(alloc, key) catch continue;
        key_count += 1;
    }
    if (key_count == 0) return error.table_not_found;
    return buf.items;
}

// ── Tests ──

test "get string" {
    const toml =
        \\[server]
        \\host = "localhost"
        \\port = 8080
    ;
    const r = try get(toml, "server.host");
    try std.testing.expect(std.mem.eql(u8, r, "localhost"));
}

test "getInt" {
    const toml =
        \\[server]
        \\port = 8080
    ;
    const r = try getInt(toml, "server.port");
    try std.testing.expectEqual(@as(i64, 8080), r);
}

test "getFloat" {
    const toml =
        \\[math]
        \\pi = 3.14159
    ;
    const r = try getFloat(toml, "math.pi");
    try std.testing.expect(r > 3.14 and r < 3.15);
}

test "getBool" {
    const toml =
        \\[app]
        \\debug = true
    ;
    const r = try getBool(toml, "app.debug");
    try std.testing.expect(r);
}

test "getArray" {
    const toml =
        \\[project]
        \\tags = ["orhon", "language", "zig"]
    ;
    const r = try getArray(toml, "project.tags");
    try std.testing.expect(std.mem.eql(u8, r, "orhon\nlanguage\nzig"));
}

test "hasKey" {
    const toml =
        \\[db]
        \\name = "orhon"
    ;
    try std.testing.expect(hasKey(toml, "db.name"));
    try std.testing.expect(!hasKey(toml, "db.port"));
}

test "getKeys" {
    const toml =
        \\[server]
        \\host = "0.0.0.0"
        \\port = 3000
        \\debug = false
    ;
    const r = try getKeys(toml, "server");
    try std.testing.expect(std.mem.eql(u8, r, "host\nport\ndebug"));
}

test "top-level keys" {
    const toml =
        \\name = "orhon"
        \\version = "0.7.1"
    ;
    const r = try get(toml, "name");
    try std.testing.expect(std.mem.eql(u8, r, "orhon"));
}

test "integer array" {
    const toml =
        \\[data]
        \\ports = [80, 443, 8080]
    ;
    const r = try getArray(toml, "data.ports");
    try std.testing.expect(std.mem.eql(u8, r, "80\n443\n8080"));
}

test "single-quoted string" {
    const toml =
        \\[paths]
        \\root = '/usr/local'
    ;
    const r = try get(toml, "paths.root");
    try std.testing.expect(std.mem.eql(u8, r, "/usr/local"));
}

test "comments ignored" {
    const toml =
        \\# This is a comment
        \\[main]
        \\key = "value"
    ;
    const r = try get(toml, "main.key");
    try std.testing.expect(std.mem.eql(u8, r, "value"));
}

test "missing key" {
    const toml =
        \\[db]
        \\host = "localhost"
    ;
    try std.testing.expectError(error.key_not_found, get(toml, "db.port"));
}
