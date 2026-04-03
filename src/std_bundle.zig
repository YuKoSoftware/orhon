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

// ============================================================
// STDLIB FILE EXTRACTION
// ============================================================

/// Write an embedded file to .orh-cache/std/ if it doesn't already exist
pub fn writeStdFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    };
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
    };

    for (files) |f| {
        try writeStdFile(std_dir, f.name, f.content, allocator);
    }
}
