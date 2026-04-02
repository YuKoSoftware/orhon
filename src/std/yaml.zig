// yaml.zig — YAML parsing sidecar for std::yaml
// Supports: mappings, sequences, scalars (strings, integers, floats, booleans, null),
//           nested indentation, quoted strings, comments, multi-level dot-path access.
// Does NOT support: anchors/aliases, tags, flow mappings/sequences, multi-line scalars,
//                   merge keys, complex keys, multiple documents.

const std = @import("std");

const alloc = std.heap.smp_allocator;

// ── Value Types ──

const ValueTag = enum { string, integer, float, boolean, null_val, sequence, mapping };

const Value = struct {
    tag: ValueTag,
    string: []const u8 = "",
    integer: i64 = 0,
    float: f64 = 0,
    boolean: bool = false,
    sequence_items: []const Value = &.{},
    mapping_entries: []const MappingEntry = &.{},
};

const MappingEntry = struct {
    key: []const u8,
    value: Value,
};

// ── Parser ──

const Line = struct {
    indent: usize,
    content: []const u8,
};

fn countIndent(raw: []const u8) usize {
    var count: usize = 0;
    for (raw) |c| {
        if (c == ' ') {
            count += 1;
        } else if (c == '\t') {
            count += 2;
        } else break;
    }
    return count;
}

fn tokenizeLines(source: []const u8) []const Line {
    var lines = std.ArrayListUnmanaged(Line){};
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trimRight(u8, raw, " \t\r");
        const indent = countIndent(trimmed);
        const content = std.mem.trimLeft(u8, trimmed, " \t");
        // Skip empty lines and comments
        if (content.len == 0) continue;
        if (content[0] == '#') continue;
        lines.append(alloc, .{ .indent = indent, .content = content }) catch continue;
    }
    return lines.items;
}

fn parseYaml(source: []const u8) Value {
    const lines = tokenizeLines(source);
    if (lines.len == 0) return .{ .tag = .mapping };
    var pos: usize = 0;
    return parseBlock(lines, &pos, 0);
}

fn parseBlock(lines: []const Line, pos: *usize, min_indent: usize) Value {
    if (pos.* >= lines.len) return .{ .tag = .mapping };

    const first = lines[pos.*];
    if (first.indent < min_indent) return .{ .tag = .mapping };

    // Sequence (starts with "- ")
    if (std.mem.startsWith(u8, first.content, "- ") or std.mem.eql(u8, first.content, "-")) {
        return parseSequence(lines, pos, first.indent);
    }

    // Mapping (contains ": " or ends with ":")
    if (findKeyDelimiter(first.content) != null) {
        return parseMapping(lines, pos, first.indent);
    }

    // Bare scalar
    const val = parseScalar(first.content);
    pos.* += 1;
    return val;
}

fn parseMapping(lines: []const Line, pos: *usize, base_indent: usize) Value {
    var entries = std.ArrayListUnmanaged(MappingEntry){};

    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (line.indent < base_indent) break;
        if (line.indent > base_indent) break;

        // Sequence items at same level are not mapping entries
        if (std.mem.startsWith(u8, line.content, "- ")) break;

        const delim = findKeyDelimiter(line.content) orelse break;
        const key = alloc.dupe(u8, std.mem.trim(u8, line.content[0..delim], " \t")) catch "";
        const after_colon = std.mem.trim(u8, line.content[delim + 1 ..], " \t");

        if (after_colon.len > 0) {
            // Inline value: "key: value"
            const value = parseScalar(after_colon);
            entries.append(alloc, .{ .key = key, .value = value }) catch continue;
            pos.* += 1;
        } else {
            // Block value: children on next lines with deeper indent
            pos.* += 1;
            if (pos.* < lines.len and lines[pos.*].indent > base_indent) {
                const child = parseBlock(lines, pos, lines[pos.*].indent);
                entries.append(alloc, .{ .key = key, .value = child }) catch continue;
            } else {
                // Empty value
                entries.append(alloc, .{ .key = key, .value = .{ .tag = .null_val } }) catch continue;
            }
        }
    }

    return .{ .tag = .mapping, .mapping_entries = entries.items };
}

fn parseSequence(lines: []const Line, pos: *usize, base_indent: usize) Value {
    var items = std.ArrayListUnmanaged(Value){};

    while (pos.* < lines.len) {
        const line = lines[pos.*];
        if (line.indent < base_indent) break;
        if (line.indent > base_indent) break;

        if (std.mem.eql(u8, line.content, "-")) {
            // Bare dash — block child on next line
            pos.* += 1;
            if (pos.* < lines.len and lines[pos.*].indent > base_indent) {
                const child = parseBlock(lines, pos, lines[pos.*].indent);
                items.append(alloc, child) catch continue;
            } else {
                items.append(alloc, .{ .tag = .null_val }) catch continue;
            }
            continue;
        }

        if (!std.mem.startsWith(u8, line.content, "- ")) break;

        const after_dash = line.content[2..];

        // Check if this sequence item starts a nested mapping: "- key: value"
        if (findKeyDelimiter(after_dash)) |_| {
            // Inline mapping entry as sequence item
            const item_indent = line.indent + 2;
            // Rewrite this line without "- " for the mapping parser
            var nested_lines = std.ArrayListUnmanaged(Line){};
            nested_lines.append(alloc, .{ .indent = item_indent, .content = after_dash }) catch continue;
            // Collect continuation lines that belong to this item
            var look: usize = pos.* + 1;
            while (look < lines.len and lines[look].indent > base_indent) : (look += 1) {
                nested_lines.append(alloc, lines[look]) catch continue;
            }
            var nested_pos: usize = 0;
            const child = parseMapping(nested_lines.items, &nested_pos, item_indent);
            items.append(alloc, child) catch continue;
            pos.* = pos.* + 1 + nested_pos - 1;
            // Skip consumed continuation lines
            while (pos.* < lines.len and lines[pos.*].indent > base_indent and
                !std.mem.startsWith(u8, lines[pos.*].content, "- "))
            {
                pos.* += 1;
            }
        } else {
            // Simple scalar: "- value"
            items.append(alloc, parseScalar(after_dash)) catch continue;
            pos.* += 1;
        }
    }

    return .{ .tag = .sequence, .sequence_items = items.items };
}

fn findKeyDelimiter(content: []const u8) ?usize {
    // Find ": " or trailing ":" — but not inside quoted strings
    if (content.len == 0) return null;
    if (content[0] == '"' or content[0] == '\'') return null;

    if (std.mem.indexOf(u8, content, ": ")) |idx| return idx + 1;
    if (content[content.len - 1] == ':' and content.len > 1) return content.len - 1;
    return null;
}

fn parseScalar(src: []const u8) Value {
    if (src.len == 0) return .{ .tag = .null_val };

    // Null
    if (std.mem.eql(u8, src, "null") or std.mem.eql(u8, src, "~")) {
        return .{ .tag = .null_val };
    }

    // Boolean
    if (std.mem.eql(u8, src, "true") or std.mem.eql(u8, src, "True") or std.mem.eql(u8, src, "TRUE")) {
        return .{ .tag = .boolean, .boolean = true };
    }
    if (std.mem.eql(u8, src, "false") or std.mem.eql(u8, src, "False") or std.mem.eql(u8, src, "FALSE")) {
        return .{ .tag = .boolean, .boolean = false };
    }

    // Quoted string
    if ((src[0] == '"' and src.len >= 2 and src[src.len - 1] == '"') or
        (src[0] == '\'' and src.len >= 2 and src[src.len - 1] == '\''))
    {
        return .{ .tag = .string, .string = alloc.dupe(u8, src[1 .. src.len - 1]) catch "" };
    }

    // Integer
    if (std.fmt.parseInt(i64, src, 10)) |n| {
        return .{ .tag = .integer, .integer = n };
    } else |_| {}

    // Float
    if (std.fmt.parseFloat(f64, src)) |f| {
        return .{ .tag = .float, .float = f };
    } else |_| {}

    // Bare string
    return .{ .tag = .string, .string = alloc.dupe(u8, src) catch "" };
}

// ── Path Resolution ──

fn resolveValue(root: Value, path: []const u8) ?Value {
    if (path.len == 0) return root;

    var current = root;
    var iter = std.mem.splitScalar(u8, path, '.');

    while (iter.next()) |segment| {
        if (current.tag != .mapping) return null;
        var found = false;
        for (current.mapping_entries) |entry| {
            if (std.mem.eql(u8, entry.key, segment)) {
                current = entry.value;
                found = true;
                break;
            }
        }
        if (!found) return null;
    }

    return current;
}

fn valueToString(val: Value) []const u8 {
    return switch (val.tag) {
        .string => val.string,
        .integer => std.fmt.allocPrint(alloc, "{d}", .{val.integer}) catch "",
        .float => std.fmt.allocPrint(alloc, "{d}", .{val.float}) catch "",
        .boolean => if (val.boolean) "true" else "false",
        .null_val => "null",
        .sequence, .mapping => "",
    };
}

// ── Public API ──

pub fn get(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseYaml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    const s = valueToString(val);
    if (s.len == 0 and val.tag != .string) return error.value_is_not_a_string;
    return s;
}

pub fn getInt(source: []const u8, path: []const u8) anyerror!i64 {
    const root = parseYaml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .integer => val.integer,
        .float => @intFromFloat(val.float),
        else => return error.value_is_not_an_integer,
    };
}

pub fn getFloat(source: []const u8, path: []const u8) anyerror!f64 {
    const root = parseYaml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .float => val.float,
        .integer => @floatFromInt(val.integer),
        else => return error.value_is_not_a_float,
    };
}

pub fn getBool(source: []const u8, path: []const u8) anyerror!bool {
    const root = parseYaml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    return switch (val.tag) {
        .boolean => val.boolean,
        else => return error.value_is_not_a_boolean,
    };
}

pub fn getArray(source: []const u8, path: []const u8) anyerror![]const u8 {
    const root = parseYaml(source);
    const val = resolveValue(root, path) orelse return error.key_not_found;
    if (val.tag != .sequence) return error.value_is_not_a_sequence;

    var buf = std.ArrayListUnmanaged(u8){};
    for (val.sequence_items, 0..) |item, i| {
        if (i > 0) buf.append(alloc, '\n') catch continue;
        buf.appendSlice(alloc, valueToString(item)) catch continue;
    }
    return if (buf.items.len > 0) buf.items else "";
}

pub fn hasKey(source: []const u8, path: []const u8) bool {
    const root = parseYaml(source);
    return resolveValue(root, path) != null;
}

pub fn getKeys(source: []const u8, mapping: []const u8) anyerror![]const u8 {
    const root = parseYaml(source);

    const target = if (mapping.len > 0)
        resolveValue(root, mapping) orelse return error.mapping_not_found
    else
        root;

    if (target.tag != .mapping) return error.value_is_not_a_mapping;

    var buf = std.ArrayListUnmanaged(u8){};
    for (target.mapping_entries, 0..) |entry, i| {
        if (i > 0) buf.append(alloc, '\n') catch continue;
        buf.appendSlice(alloc, entry.key) catch continue;
    }
    if (target.mapping_entries.len == 0) return error.mapping_not_found;
    return buf.items;
}

// ── Tests ──

test "get string" {
    const yaml =
        \\server:
        \\  host: "localhost"
        \\  port: 8080
    ;
    const r = try get(yaml, "server.host");
    try std.testing.expect(std.mem.eql(u8, r, "localhost"));
}

test "getInt" {
    const yaml =
        \\server:
        \\  port: 8080
    ;
    const r = try getInt(yaml, "server.port");
    try std.testing.expectEqual(@as(i64, 8080), r);
}

test "getFloat" {
    const yaml =
        \\math:
        \\  pi: 3.14159
    ;
    const r = try getFloat(yaml, "math.pi");
    try std.testing.expect(r > 3.14 and r < 3.15);
}

test "getBool" {
    const yaml =
        \\app:
        \\  debug: true
    ;
    const r = try getBool(yaml, "app.debug");
    try std.testing.expect(r);
}

test "getBool case variants" {
    const yaml =
        \\a: True
        \\b: FALSE
    ;
    const ra = try getBool(yaml, "a");
    try std.testing.expect(ra);
    const rb = try getBool(yaml, "b");
    try std.testing.expect(!rb);
}

test "getArray" {
    const yaml =
        \\project:
        \\  tags:
        \\    - orhon
        \\    - language
        \\    - zig
    ;
    const r = try getArray(yaml, "project.tags");
    try std.testing.expect(std.mem.eql(u8, r, "orhon\nlanguage\nzig"));
}

test "hasKey" {
    const yaml =
        \\db:
        \\  name: orhon
    ;
    try std.testing.expect(hasKey(yaml, "db.name"));
    try std.testing.expect(!hasKey(yaml, "db.port"));
}

test "getKeys" {
    const yaml =
        \\server:
        \\  host: "0.0.0.0"
        \\  port: 3000
        \\  debug: false
    ;
    const r = try getKeys(yaml, "server");
    try std.testing.expect(std.mem.eql(u8, r, "host\nport\ndebug"));
}

test "top-level keys" {
    const yaml =
        \\name: orhon
        \\version: "0.7.6"
    ;
    const r = try get(yaml, "name");
    try std.testing.expect(std.mem.eql(u8, r, "orhon"));
}

test "null values" {
    const yaml =
        \\empty: null
        \\tilde: ~
    ;
    const r = try get(yaml, "empty");
    try std.testing.expect(std.mem.eql(u8, r, "null"));
}

test "comments ignored" {
    const yaml =
        \\# This is a comment
        \\main:
        \\  key: value
    ;
    const r = try get(yaml, "main.key");
    try std.testing.expect(std.mem.eql(u8, r, "value"));
}

test "missing key" {
    const yaml =
        \\db:
        \\  host: localhost
    ;
    try std.testing.expectError(error.key_not_found, get(yaml, "db.port"));
}

test "deeply nested" {
    const yaml =
        \\a:
        \\  b:
        \\    c:
        \\      d: deep
    ;
    const r = try get(yaml, "a.b.c.d");
    try std.testing.expect(std.mem.eql(u8, r, "deep"));
}

test "integer array" {
    const yaml =
        \\data:
        \\  ports:
        \\    - 80
        \\    - 443
        \\    - 8080
    ;
    const r = try getArray(yaml, "data.ports");
    try std.testing.expect(std.mem.eql(u8, r, "80\n443\n8080"));
}

test "single-quoted string" {
    const yaml =
        \\paths:
        \\  root: '/usr/local'
    ;
    const r = try get(yaml, "paths.root");
    try std.testing.expect(std.mem.eql(u8, r, "/usr/local"));
}

test "root-level getKeys" {
    const yaml =
        \\name: orhon
        \\version: "0.7.6"
        \\lang: zig
    ;
    const r = try getKeys(yaml, "");
    try std.testing.expect(std.mem.eql(u8, r, "name\nversion\nlang"));
}
