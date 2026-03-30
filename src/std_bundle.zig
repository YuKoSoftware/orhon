// std_bundle.zig — Embedded stdlib files and extraction logic

const std = @import("std");
const cache = @import("cache.zig");

// ============================================================
// EMBEDDED STDLIB CONSTANTS
// ============================================================

const ASYNC_ORH      = @embedFile("std/async.orh");
const ASYNC_ZIG      = @embedFile("std/async.zig");
const COLLECTIONS_ORH = @embedFile("std/collections.orh");
pub const COLLECTIONS_ZIG = @embedFile("std/collections.zig");
const ALLOCATOR_ORH = @embedFile("std/allocator.orh");
const ALLOCATOR_ZIG = @embedFile("std/allocator.zig");
const CONSOLE_ORH = @embedFile("std/console.orh");
const CONSOLE_ZIG = @embedFile("std/console.zig");
const FS_ORH      = @embedFile("std/fs.orh");
const FS_ZIG      = @embedFile("std/fs.zig");
const MATH_ORH    = @embedFile("std/math.orh");
const MATH_ZIG    = @embedFile("std/math.zig");
const STR_ORH     = @embedFile("std/str.orh");
pub const STR_ZIG = @embedFile("std/str.zig");
const SYSTEM_ORH  = @embedFile("std/system.orh");
const SYSTEM_ZIG  = @embedFile("std/system.zig");
const TIME_ORH    = @embedFile("std/time.orh");
const TIME_ZIG    = @embedFile("std/time.zig");
const JSON_ORH    = @embedFile("std/json.orh");
const JSON_ZIG    = @embedFile("std/json.zig");
const SORT_ORH    = @embedFile("std/sort.orh");
const SORT_ZIG    = @embedFile("std/sort.zig");
const RANDOM_ORH  = @embedFile("std/random.orh");
const RANDOM_ZIG  = @embedFile("std/random.zig");
const ENCODING_ORH = @embedFile("std/encoding.orh");
const ENCODING_ZIG = @embedFile("std/encoding.zig");
const STREAM_ORH   = @embedFile("std/stream.orh");
const STREAM_ZIG   = @embedFile("std/stream.zig");
const CRYPTO_ORH   = @embedFile("std/crypto.orh");
const CRYPTO_ZIG   = @embedFile("std/crypto.zig");
const COMPRESS_ORH = @embedFile("std/compression.orh");
const COMPRESS_ZIG = @embedFile("std/compression.zig");
const XML_ORH      = @embedFile("std/xml.orh");
const XML_ZIG      = @embedFile("std/xml.zig");
const CSV_ORH      = @embedFile("std/csv.orh");
const CSV_ZIG      = @embedFile("std/csv.zig");
const TESTING_ORH  = @embedFile("std/testing.orh");
const TESTING_ZIG  = @embedFile("std/testing.zig");
const NET_ORH      = @embedFile("std/net.orh");
const NET_ZIG      = @embedFile("std/net.zig");
const HTTP_ORH     = @embedFile("std/http.orh");
const HTTP_ZIG     = @embedFile("std/http.zig");
const REGEX_ORH    = @embedFile("std/regex.orh");
const REGEX_ZIG    = @embedFile("std/regex.zig");
const INI_ORH      = @embedFile("std/ini.orh");
const INI_ZIG      = @embedFile("std/ini.zig");
const TOML_ORH     = @embedFile("std/toml.orh");
const TOML_ZIG     = @embedFile("std/toml.zig");
const SIMD_ORH     = @embedFile("std/simd.orh");
const SIMD_ZIG     = @embedFile("std/simd.zig");
const TUI_ORH      = @embedFile("std/tui.orh");
const TUI_ZIG      = @embedFile("std/tui.zig");
const YAML_ORH     = @embedFile("std/yaml.orh");
const YAML_ZIG     = @embedFile("std/yaml.zig");
const LINEAR_ORH   = @embedFile("std/linear.orh");

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
        .{ .name = "async.orh",       .content = ASYNC_ORH },
        .{ .name = "async.zig",       .content = ASYNC_ZIG },
        .{ .name = "collections.orh", .content = COLLECTIONS_ORH },
        .{ .name = "collections.zig", .content = COLLECTIONS_ZIG },
        .{ .name = "allocator.orh", .content = ALLOCATOR_ORH },
        .{ .name = "allocator.zig", .content = ALLOCATOR_ZIG },
        .{ .name = "console.orh", .content = CONSOLE_ORH },
        .{ .name = "console.zig", .content = CONSOLE_ZIG },
        .{ .name = "fs.orh",      .content = FS_ORH },
        .{ .name = "fs.zig",      .content = FS_ZIG },
        .{ .name = "math.orh",    .content = MATH_ORH },
        .{ .name = "math.zig",    .content = MATH_ZIG },
        .{ .name = "str.orh",     .content = STR_ORH },
        .{ .name = "str.zig",     .content = STR_ZIG },
        .{ .name = "system.orh",  .content = SYSTEM_ORH },
        .{ .name = "system.zig",  .content = SYSTEM_ZIG },
        .{ .name = "time.orh",    .content = TIME_ORH },
        .{ .name = "time.zig",    .content = TIME_ZIG },
        .{ .name = "json.orh",    .content = JSON_ORH },
        .{ .name = "json.zig",    .content = JSON_ZIG },
        .{ .name = "sort.orh",    .content = SORT_ORH },
        .{ .name = "sort.zig",    .content = SORT_ZIG },
        .{ .name = "random.orh",  .content = RANDOM_ORH },
        .{ .name = "random.zig",  .content = RANDOM_ZIG },
        .{ .name = "encoding.orh", .content = ENCODING_ORH },
        .{ .name = "encoding.zig", .content = ENCODING_ZIG },
        .{ .name = "stream.orh",   .content = STREAM_ORH },
        .{ .name = "stream.zig",   .content = STREAM_ZIG },
        .{ .name = "crypto.orh",   .content = CRYPTO_ORH },
        .{ .name = "crypto.zig",   .content = CRYPTO_ZIG },
        .{ .name = "compression.orh", .content = COMPRESS_ORH },
        .{ .name = "compression.zig", .content = COMPRESS_ZIG },
        .{ .name = "xml.orh",         .content = XML_ORH },
        .{ .name = "xml.zig",         .content = XML_ZIG },
        .{ .name = "csv.orh",         .content = CSV_ORH },
        .{ .name = "csv.zig",         .content = CSV_ZIG },
        .{ .name = "testing.orh",     .content = TESTING_ORH },
        .{ .name = "testing.zig",     .content = TESTING_ZIG },
        .{ .name = "net.orh",         .content = NET_ORH },
        .{ .name = "net.zig",         .content = NET_ZIG },
        .{ .name = "http.orh",        .content = HTTP_ORH },
        .{ .name = "http.zig",        .content = HTTP_ZIG },
        .{ .name = "regex.orh",       .content = REGEX_ORH },
        .{ .name = "regex.zig",       .content = REGEX_ZIG },
        .{ .name = "ini.orh",         .content = INI_ORH },
        .{ .name = "ini.zig",         .content = INI_ZIG },
        .{ .name = "toml.orh",        .content = TOML_ORH },
        .{ .name = "toml.zig",        .content = TOML_ZIG },
        .{ .name = "simd.orh",        .content = SIMD_ORH },
        .{ .name = "simd.zig",        .content = SIMD_ZIG },
        .{ .name = "tui.orh",         .content = TUI_ORH },
        .{ .name = "tui.zig",         .content = TUI_ZIG },
        .{ .name = "yaml.orh",        .content = YAML_ORH },
        .{ .name = "yaml.zig",        .content = YAML_ZIG },
        .{ .name = "linear.orh",      .content = LINEAR_ORH },
    };

    for (files) |f| {
        try writeStdFile(std_dir, f.name, f.content, allocator);
    }
}
