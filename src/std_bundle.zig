// std_bundle.zig — Embedded stdlib files and extraction logic

const std = @import("std");
const cache = @import("cache.zig");

// ============================================================
// EMBEDDED STDLIB CONSTANTS
// ============================================================

const THREAD_ZIG     = @embedFile("std/thread.zig");
const COLLECTIONS_ZIG = @embedFile("std/collections.zig");
const ALLOCATOR_ZIG = @embedFile("std/allocator.zig");
const CONSOLE_ZIG = @embedFile("std/console.zig");
const FS_ZIG      = @embedFile("std/fs.zig");
const MATH_ZIG    = @embedFile("std/math.zig");
const STRING_ZIG = @embedFile("std/string.zig");
const SYSTEM_ZIG  = @embedFile("std/system.zig");
const TIME_ZIG    = @embedFile("std/time.zig");
const JSON_ZIG    = @embedFile("std/json.zig");
const SORT_ZIG    = @embedFile("std/sort.zig");
const RANDOM_ZIG  = @embedFile("std/random.zig");
const ENCODING_ZIG = @embedFile("std/encoding.zig");
const STREAM_ZIG   = @embedFile("std/stream.zig");
const CRYPTO_ZIG   = @embedFile("std/crypto.zig");
const COMPRESS_ZIG = @embedFile("std/compression.zig");
const XML_ZIG      = @embedFile("std/xml.zig");
const CSV_ZIG      = @embedFile("std/csv.zig");
const TESTING_ZIG  = @embedFile("std/testing.zig");
const NET_ZIG      = @embedFile("std/net.zig");
const HTTP_ZIG     = @embedFile("std/http.zig");
const REGEX_ZIG    = @embedFile("std/regex.zig");
const INI_ZIG      = @embedFile("std/ini.zig");
const TOML_ZIG     = @embedFile("std/toml.zig");
const SIMD_ZIG     = @embedFile("std/simd.zig");
const TUI_ZIG      = @embedFile("std/tui.zig");
const YAML_ZIG     = @embedFile("std/yaml.zig");
const LINEAR_ORH   = @embedFile("std/linear.orh");
const PTR_ZIG      = @embedFile("std/ptr.zig");
const BITFIELD_ZIG = @embedFile("std/bitfield.zig");

// ============================================================
// STDLIB FILE EXTRACTION
// ============================================================

/// Write an embedded file to .orh-cache/std/, overwriting if content has changed
pub fn writeStdFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);

    // Check if existing file matches embedded content
    if (std.fs.cwd().openFile(path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        if (stat.size == content.len) {
            const existing = try allocator.alloc(u8, content.len);
            defer allocator.free(existing);
            const bytes_read = try file.readAll(existing);
            if (bytes_read == content.len and std.mem.eql(u8, existing, content)) return;
        }
    } else |_| {}

    // File missing or content differs — write fresh copy
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Ensure all embedded std files exist in .orh-cache/std/
pub fn ensureStdFiles(allocator: std.mem.Allocator) !void {
    const std_dir = cache.CACHE_DIR ++ "/std";
    try std.fs.cwd().makePath(std_dir);

    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "thread.zig",      .content = THREAD_ZIG },
        .{ .name = "collections.zig", .content = COLLECTIONS_ZIG },
        .{ .name = "allocator.zig",   .content = ALLOCATOR_ZIG },
        .{ .name = "console.zig",     .content = CONSOLE_ZIG },
        .{ .name = "fs.zig",          .content = FS_ZIG },
        .{ .name = "math.zig",        .content = MATH_ZIG },
        .{ .name = "string.zig",      .content = STRING_ZIG },
        .{ .name = "system.zig",      .content = SYSTEM_ZIG },
        .{ .name = "time.zig",        .content = TIME_ZIG },
        .{ .name = "json.zig",        .content = JSON_ZIG },
        .{ .name = "sort.zig",        .content = SORT_ZIG },
        .{ .name = "random.zig",      .content = RANDOM_ZIG },
        .{ .name = "encoding.zig",    .content = ENCODING_ZIG },
        .{ .name = "stream.zig",      .content = STREAM_ZIG },
        .{ .name = "crypto.zig",      .content = CRYPTO_ZIG },
        .{ .name = "compression.zig", .content = COMPRESS_ZIG },
        .{ .name = "xml.zig",         .content = XML_ZIG },
        .{ .name = "csv.zig",         .content = CSV_ZIG },
        .{ .name = "testing.zig",     .content = TESTING_ZIG },
        .{ .name = "net.zig",         .content = NET_ZIG },
        .{ .name = "http.zig",        .content = HTTP_ZIG },
        .{ .name = "regex.zig",       .content = REGEX_ZIG },
        .{ .name = "ini.zig",         .content = INI_ZIG },
        .{ .name = "toml.zig",        .content = TOML_ZIG },
        .{ .name = "simd.zig",        .content = SIMD_ZIG },
        .{ .name = "tui.zig",         .content = TUI_ZIG },
        .{ .name = "yaml.zig",        .content = YAML_ZIG },
        .{ .name = "linear.orh",      .content = LINEAR_ORH },
        .{ .name = "ptr.zig",         .content = PTR_ZIG },
        .{ .name = "bitfield.zig",   .content = BITFIELD_ZIG },
    };

    for (files) |f| {
        try writeStdFile(std_dir, f.name, f.content, allocator);
    }
}

// ============================================================
// TESTS
// ============================================================

test "writeStdFile overwrites stale content" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // Write initial content
    try writeStdFile(dir_path, "test.zig", "old content", allocator);

    // Write updated content — should overwrite
    try writeStdFile(dir_path, "test.zig", "new content", allocator);

    // Verify new content was written
    const file = try tmp.dir.openFile("test.zig", .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("new content", buf[0..n]);
}

test "writeStdFile creates missing file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    // Write to non-existent file
    try writeStdFile(dir_path, "new.zig", "fresh content", allocator);

    const file = try tmp.dir.openFile("new.zig", .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("fresh content", buf[0..n]);
}
