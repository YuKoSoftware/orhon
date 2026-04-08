// string.zig — string utilities for std::string
// Operates on []const u8 (Orhon str type). All functions are pure — no side effects.

const std = @import("std");
const allocator = @import("allocator.zig");

const alloc = allocator.default;

// ── Comparison ──

/// Compare two strings for content equality.
pub fn equals(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ── Search ──

/// Check if a string contains a substring.
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Check if a string starts with the given prefix.
pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, s, prefix);
}

/// Check if a string ends with the given suffix.
pub fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

/// Return the first index of a substring, or null if not found.
pub fn indexOf(haystack: []const u8, needle: []const u8) ?i32 {
    if (std.mem.indexOf(u8, haystack, needle)) |pos| {
        return @intCast(pos);
    }
    return null;
}

/// Return the last index of a substring, or null if not found.
pub fn lastIndexOf(haystack: []const u8, needle: []const u8) ?i32 {
    if (std.mem.lastIndexOf(u8, haystack, needle)) |pos| {
        return @intCast(pos);
    }
    return null;
}

// ── Case ──

/// Convert all ASCII characters in the string to uppercase.
pub fn toUpper(s: []const u8) []const u8 {
    const buf = alloc.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toUpper(c);
    }
    return buf;
}

/// Convert all ASCII characters in the string to lowercase.
pub fn toLower(s: []const u8) []const u8 {
    const buf = alloc.alloc(u8, s.len) catch return s;
    for (s, 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    return buf;
}

// ── Transform ──

/// Replace all occurrences of a substring with another string.
pub fn replace(s: []const u8, old: []const u8, new: []const u8) []const u8 {
    const result = std.mem.replaceOwned(u8, alloc, s, old, new) catch return s;
    return result;
}

/// Repeat a string the given number of times.
pub fn repeat(s: []const u8, times: i32) []const u8 {
    if (times <= 0) return "";
    const n: usize = @intCast(times);
    const buf = alloc.alloc(u8, s.len * n) catch return s;
    for (0..n) |i| {
        @memcpy(buf[i * s.len .. (i + 1) * s.len], s);
    }
    return buf;
}

/// Strip leading and trailing whitespace from the string.
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\n\r");
}

/// Strip leading whitespace from the string.
pub fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimLeft(u8, s, " \t\n\r");
}

/// Strip trailing whitespace from the string.
pub fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\n\r");
}

// ── Join ──

/// Join a slice of strings with the given separator.
pub fn join(parts: anytype, separator: []const u8) []const u8 {
    return std.mem.join(alloc, separator, parts) catch return "";
}

// ── Parse ──

/// Parse a decimal integer string, returning 0 on failure.
pub fn parseInt(s: []const u8) i32 {
    return std.fmt.parseInt(i32, s, 10) catch 0;
}

/// Parse a floating-point string, returning 0.0 on failure.
pub fn parseFloat(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, s) catch 0.0;
}

// ── Convert ──

/// Convert any value to its string representation.
pub fn toString(value: anytype) []const u8 {
    return std.fmt.allocPrint(alloc, "{any}", .{value}) catch return "";
}

// ── Length ──

/// Return the codepoint count of a UTF-8 string (not byte count).
pub fn len(s: []const u8) i32 {
    const count = std.unicode.utf8CountCodepoints(s) catch return @intCast(s.len);
    return @intCast(count);
}

/// Return the byte length of the string.
pub fn byteLen(s: []const u8) i32 {
    return @intCast(s.len);
}

/// Return the nth codepoint as a string slice (0-based index).
pub fn charAt(s: []const u8, index: i32) []const u8 {
    if (index < 0) return "";
    const target: usize = @intCast(index);
    var view = std.unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    var i: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (i == target) return slice;
        i += 1;
    }
    return "";
}

// ── Formatting ──

/// Pad the string on the left to the given width using the fill character.
pub fn padLeft(s: []const u8, width: i32, fill: []const u8) []const u8 {
    const w: usize = @intCast(@max(0, width));
    const cp_count = std.unicode.utf8CountCodepoints(s) catch return s;
    if (cp_count >= w) return s;
    const pad_len = w - cp_count;
    const fill_char = if (fill.len > 0) fill[0] else @as(u8, ' ');
    const buf = alloc.alloc(u8, pad_len + s.len) catch return s;
    @memset(buf[0..pad_len], fill_char);
    @memcpy(buf[pad_len..], s);
    return buf;
}

/// Pad the string on the right to the given width using the fill character.
pub fn padRight(s: []const u8, width: i32, fill: []const u8) []const u8 {
    const w: usize = @intCast(@max(0, width));
    const cp_count = std.unicode.utf8CountCodepoints(s) catch return s;
    if (cp_count >= w) return s;
    const pad_len = w - cp_count;
    const fill_char = if (fill.len > 0) fill[0] else @as(u8, ' ');
    const buf = alloc.alloc(u8, s.len + pad_len) catch return s;
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len..], fill_char);
    return buf;
}

/// Truncate to max codepoints, appending "..." if the string was shortened.
pub fn truncate(s: []const u8, max_len: i32) []const u8 {
    if (max_len <= 0) return "";
    const m: usize = @intCast(max_len);
    const cp_count = std.unicode.utf8CountCodepoints(s) catch return s;
    if (cp_count <= m) return s;
    if (m <= 3) {
        // Just return first m codepoints
        return cpSlice(s, m);
    }
    // Return first (m-3) codepoints + "..."
    const prefix = cpSlice(s, m - 3);
    const buf = alloc.alloc(u8, prefix.len + 3) catch return s;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..], "...");
    return buf;
}

/// Reverse the string by codepoints, preserving multi-byte characters.
pub fn reverse(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    // Collect codepoint slices
    var view = std.unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    var slices = std.ArrayListUnmanaged([]const u8){};
    while (iter.nextCodepointSlice()) |slice| {
        slices.append(alloc, slice) catch return s;
    }
    // Write in reverse order
    const buf = alloc.alloc(u8, s.len) catch return s;
    var pos: usize = 0;
    var i = slices.items.len;
    while (i > 0) {
        i -= 1;
        @memcpy(buf[pos .. pos + slices.items[i].len], slices.items[i]);
        pos += slices.items[i].len;
    }
    return buf;
}

/// Split the string by a separator and return parts joined by newlines.
pub fn splitBy(s: []const u8, sep: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var first = true;
    var iter = std.mem.splitSequence(u8, s, sep);
    while (iter.next()) |part| {
        if (!first) buf.append(alloc, '\n') catch continue;
        first = false;
        buf.appendSlice(alloc, part) catch continue;
    }
    return if (buf.items.len > 0) buf.items else "";
}

/// Count the number of non-overlapping occurrences of a substring.
pub fn countOccurrences(s: []const u8, sub: []const u8) i32 {
    if (sub.len == 0) return 0;
    var n: i32 = 0;
    var i: usize = 0;
    while (i + sub.len <= s.len) {
        if (std.mem.eql(u8, s[i .. i + sub.len], sub)) {
            n += 1;
            i += sub.len;
        } else {
            i += 1;
        }
    }
    return n;
}

// ── Internal Helpers ──

// Return the first n codepoints of a UTF-8 string as a byte slice
fn cpSlice(s: []const u8, n: usize) []const u8 {
    var view = std.unicode.Utf8View.initUnchecked(s);
    var iter = view.iterator();
    var count: usize = 0;
    var byte_end: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (count >= n) break;
        byte_end += slice.len;
        count += 1;
    }
    return s[0..byte_end];
}

// ── Tests ──

test "contains" {
    try std.testing.expect(contains("hello world", "world"));
    try std.testing.expect(!contains("hello world", "xyz"));
}

test "startsWith and endsWith" {
    try std.testing.expect(startsWith("hello", "hel"));
    try std.testing.expect(endsWith("hello", "llo"));
}

test "indexOf" {
    const result = indexOf("hello", "ll");
    try std.testing.expectEqual(@as(i32, 2), result.?);
    const none = indexOf("hello", "xyz");
    try std.testing.expect(none == null);
}

test "toUpper and toLower" {
    const upper = toUpper("hello");
    try std.testing.expect(std.mem.eql(u8, upper, "HELLO"));
    const lower = toLower("HELLO");
    try std.testing.expect(std.mem.eql(u8, lower, "hello"));
}

test "replace" {
    const result = replace("hello world", "world", "orhon");
    try std.testing.expect(std.mem.eql(u8, result, "hello orhon"));
}

test "repeat" {
    const result = repeat("ha", 3);
    try std.testing.expect(std.mem.eql(u8, result, "hahaha"));
}

test "trim" {
    const result = trim("  hello  ");
    try std.testing.expect(std.mem.eql(u8, result, "hello"));
}

test "parseInt and parseFloat" {
    try std.testing.expectEqual(@as(i32, 42), parseInt("42"));
    try std.testing.expectEqual(@as(f64, 3.14), parseFloat("3.14"));
}

test "len and charAt" {
    try std.testing.expectEqual(@as(i32, 5), len("hello"));
    try std.testing.expect(std.mem.eql(u8, charAt("hello", 1), "e"));
}

test "len counts codepoints not bytes" {
    // "café" = c(1) + a(1) + f(1) + é(2) = 5 bytes, 4 codepoints
    try std.testing.expectEqual(@as(i32, 4), len("caf\xc3\xa9"));
    try std.testing.expectEqual(@as(i32, 5), byteLen("caf\xc3\xa9"));
}

test "charAt on multi-byte" {
    // "café" — charAt(3) should return "é" (2 bytes), not a broken byte
    const ch = charAt("caf\xc3\xa9", 3);
    try std.testing.expect(std.mem.eql(u8, ch, "\xc3\xa9"));
}

test "reverse preserves multi-byte" {
    // reverse("café") should be "éfac" not broken bytes
    const result = reverse("caf\xc3\xa9");
    try std.testing.expect(std.mem.eql(u8, result, "\xc3\xa9" ++ "fac"));
}

test "truncate on multi-byte" {
    // truncate "cafébar" (7 codepoints) to 5 should be "ca..."
    const result = truncate("caf\xc3\xa9bar", 5);
    try std.testing.expect(std.mem.eql(u8, result, "ca..."));
}

test "padLeft with multi-byte" {
    // "café" is 4 codepoints, pad to 6 should add 2 fill chars
    const result = padLeft("caf\xc3\xa9", 6, ".");
    try std.testing.expect(std.mem.eql(u8, result, "..caf\xc3\xa9"));
}

test "padLeft" {
    try std.testing.expect(std.mem.eql(u8, padLeft("42", 5, "0"), "00042"));
    try std.testing.expect(std.mem.eql(u8, padLeft("hello", 3, " "), "hello"));
}

test "padRight" {
    try std.testing.expect(std.mem.eql(u8, padRight("hi", 5, "."), "hi..."));
}

test "truncate" {
    try std.testing.expect(std.mem.eql(u8, truncate("hello world", 8), "hello..."));
    try std.testing.expect(std.mem.eql(u8, truncate("hi", 10), "hi"));
}

test "reverse" {
    try std.testing.expect(std.mem.eql(u8, reverse("hello"), "olleh"));
    try std.testing.expect(std.mem.eql(u8, reverse(""), ""));
}

test "splitBy" {
    try std.testing.expect(std.mem.eql(u8, splitBy("a,b,c", ","), "a\nb\nc"));
    try std.testing.expect(std.mem.eql(u8, splitBy("hello", ","), "hello"));
}

test "countOccurrences" {
    try std.testing.expectEqual(@as(i32, 3), countOccurrences("abababab", "ab"));
    try std.testing.expectEqual(@as(i32, 0), countOccurrences("hello", "xyz"));
}

test "equals" {
    try std.testing.expect(equals("hello", "hello"));
    try std.testing.expect(!equals("hello", "world"));
    try std.testing.expect(!equals("hello", "hell"));
    try std.testing.expect(equals("", ""));
}
