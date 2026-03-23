// encoding.zig — base64 and hex encoding/decoding sidecar for std::encoding
// Pure transforms on byte slices. No state, no allocation ownership.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Base64 Encode ──

pub fn base64Encode(data: []const u8) []const u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    const dest = alloc.alloc(u8, size) catch return "";
    _ = std.base64.standard.Encoder.encode(dest, data);
    return dest;
}

// ── Base64 Decode ──

pub fn base64Decode(data: []const u8) OrhonResult([]const u8) {
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch {
        return .{ .err = .{ .message = "invalid base64 length" } };
    };
    const dest = alloc.alloc(u8, size) catch {
        return .{ .err = .{ .message = "out of memory" } };
    };
    std.base64.standard.Decoder.decode(dest, data) catch {
        alloc.free(dest);
        return .{ .err = .{ .message = "invalid base64 data" } };
    };
    return .{ .ok = dest };
}

// ── Hex Encode ──

pub fn hexEncode(data: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(data)}) catch return "";
}

// ── Hex Decode ──

pub fn hexDecode(data: []const u8) OrhonResult([]const u8) {
    if (data.len % 2 != 0) {
        return .{ .err = .{ .message = "hex string must have even length" } };
    }
    const dest = alloc.alloc(u8, data.len / 2) catch {
        return .{ .err = .{ .message = "out of memory" } };
    };
    _ = std.fmt.hexToBytes(dest, data) catch {
        alloc.free(dest);
        return .{ .err = .{ .message = "invalid hex data" } };
    };
    return .{ .ok = dest };
}

// ── Tests ──

test "base64 encode" {
    const encoded = base64Encode("hello");
    try std.testing.expect(std.mem.eql(u8, encoded, "aGVsbG8="));
}

test "base64 decode" {
    const result = base64Decode("aGVsbG8=");
    try std.testing.expect(result == .ok);
    try std.testing.expect(std.mem.eql(u8, result.ok, "hello"));
}

test "base64 decode invalid" {
    const result = base64Decode("!!!invalid!!!");
    try std.testing.expect(result == .err);
}

test "hex encode" {
    const encoded = hexEncode("hi");
    try std.testing.expect(std.mem.eql(u8, encoded, "6869"));
}

test "hex decode" {
    const result = hexDecode("6869");
    try std.testing.expect(result == .ok);
    try std.testing.expect(std.mem.eql(u8, result.ok, "hi"));
}

test "hex decode odd length" {
    const result = hexDecode("abc");
    try std.testing.expect(result == .err);
}

test "roundtrip base64" {
    const original = "Orhon language 2026";
    const encoded = base64Encode(original);
    const decoded = base64Decode(encoded);
    try std.testing.expect(decoded == .ok);
    try std.testing.expect(std.mem.eql(u8, decoded.ok, original));
}

test "roundtrip hex" {
    const original = "Orhon";
    const encoded = hexEncode(original);
    const decoded = hexDecode(encoded);
    try std.testing.expect(decoded == .ok);
    try std.testing.expect(std.mem.eql(u8, decoded.ok, original));
}
