// ini.zig — INI file parsing sidecar for std::ini
// Supports [section] headers, key=value pairs, and # ; comments.

const std = @import("std");

const alloc = std.heap.smp_allocator;

// ── Internal: Parse into section→key→value map ──

const IniMap = struct {
    sections: []const Section,
};

const Section = struct {
    name: []const u8,
    keys: []const Entry,
};

const Entry = struct {
    key: []const u8,
    value: []const u8,
};

fn parseIni(source: []const u8) IniMap {
    var sections = std.ArrayListUnmanaged(Section){};
    var current_name: []const u8 = "";
    var current_entries = std.ArrayListUnmanaged(Entry){};

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        // Section header
        if (line[0] == '[') {
            // Flush previous section
            if (current_name.len > 0 or current_entries.items.len > 0) {
                sections.append(alloc, .{
                    .name = current_name,
                    .keys = alloc.dupe(Entry, current_entries.items) catch &.{},
                }) catch continue;
                current_entries.clearRetainingCapacity();
            }
            const end = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
            current_name = alloc.dupe(u8, line[1..end]) catch "";
            continue;
        }

        // Key = Value
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            current_entries.append(alloc, .{
                .key = alloc.dupe(u8, key) catch "",
                .value = alloc.dupe(u8, value) catch "",
            }) catch continue;
        }
    }

    // Flush last section — best-effort: OOM silently drops the final section
    if (current_name.len > 0 or current_entries.items.len > 0) {
        sections.append(alloc, .{
            .name = current_name,
            .keys = alloc.dupe(Entry, current_entries.items) catch &.{},
        }) catch return .{ .sections = sections.items };
    }

    return .{ .sections = sections.items };
}

fn findValue(ini: IniMap, section: []const u8, key: []const u8) ?[]const u8 {
    for (ini.sections) |sec| {
        if (std.mem.eql(u8, sec.name, section)) {
            for (sec.keys) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
        }
    }
    return null;
}

// ── Get ──

pub fn get(source: []const u8, path: []const u8) anyerror![]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse {
        return error.path_must_be_section_dot_key;
    };
    const section = path[0..dot];
    const key = path[dot + 1 ..];
    const ini = parseIni(source);
    if (findValue(ini, section, key)) |val| {
        return val;
    }
    return error.key_not_found;
}

// ── HasKey ──

pub fn hasKey(source: []const u8, path: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return false;
    const section = path[0..dot];
    const key = path[dot + 1 ..];
    const ini = parseIni(source);
    return findValue(ini, section, key) != null;
}

// ── GetKeys ──

pub fn getKeys(source: []const u8, section: []const u8) anyerror![]const u8 {
    const ini = parseIni(source);
    for (ini.sections) |sec| {
        if (std.mem.eql(u8, sec.name, section)) {
            var buf = std.ArrayListUnmanaged(u8){};
            for (sec.keys, 0..) |entry, i| {
                if (i > 0) buf.append(alloc, '\n') catch continue;
                buf.appendSlice(alloc, entry.key) catch continue;
            }
            return if (buf.items.len > 0) buf.items else "";
        }
    }
    return error.section_not_found;
}

// ── GetSections ──

pub fn getSections(source: []const u8) []const u8 {
    const ini = parseIni(source);
    var buf = std.ArrayListUnmanaged(u8){};
    for (ini.sections, 0..) |sec, i| {
        if (sec.name.len == 0) continue;
        if (i > 0 and buf.items.len > 0) buf.append(alloc, '\n') catch continue;
        buf.appendSlice(alloc, sec.name) catch continue;
    }
    return if (buf.items.len > 0) buf.items else "";
}

// ── Tests ──

test "get value" {
    const ini =
        \\[database]
        \\host = localhost
        \\port = 5432
    ;
    const r = try get(ini, "database.host");
    try std.testing.expect(std.mem.eql(u8, r, "localhost"));
    const r2 = try get(ini, "database.port");
    try std.testing.expect(std.mem.eql(u8, r2, "5432"));
}

test "hasKey" {
    const ini =
        \\[app]
        \\name = orhon
    ;
    try std.testing.expect(hasKey(ini, "app.name"));
    try std.testing.expect(!hasKey(ini, "app.version"));
    try std.testing.expect(!hasKey(ini, "other.name"));
}

test "getKeys" {
    const ini =
        \\[server]
        \\host = 0.0.0.0
        \\port = 8080
        \\debug = true
    ;
    const r = try getKeys(ini, "server");
    try std.testing.expect(std.mem.eql(u8, r, "host\nport\ndebug"));
}

test "getSections" {
    const ini =
        \\[a]
        \\x = 1
        \\[b]
        \\y = 2
    ;
    const s = getSections(ini);
    try std.testing.expect(std.mem.eql(u8, s, "a\nb"));
}

test "comments ignored" {
    const ini =
        \\# This is a comment
        \\; Another comment
        \\[main]
        \\key = value
    ;
    const r = try get(ini, "main.key");
    try std.testing.expect(std.mem.eql(u8, r, "value"));
}

test "missing key" {
    const ini =
        \\[db]
        \\host = localhost
    ;
    try std.testing.expectError(error.key_not_found, get(ini, "db.port"));
}
