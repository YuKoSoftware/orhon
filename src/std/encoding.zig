// encoding.zig — base64 and hex encoding/decoding sidecar for std::encoding
// Pure transforms on byte slices. No state, no allocation ownership.

const std = @import("std");

const alloc = std.heap.smp_allocator;

// ── Base64 Encode ──

pub fn base64Encode(data: []const u8) []const u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    const dest = alloc.alloc(u8, size) catch return "";
    _ = std.base64.standard.Encoder.encode(dest, data);
    return dest;
}

// ── Base64 Decode ──

pub fn base64Decode(data: []const u8) anyerror![]const u8 {
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch {
        return error.invalid_base64_length;
    };
    const dest = alloc.alloc(u8, size) catch {
        return error.out_of_memory;
    };
    std.base64.standard.Decoder.decode(dest, data) catch {
        alloc.free(dest);
        return error.invalid_base64_data;
    };
    return dest;
}

// ── Hex Encode ──

pub fn hexEncode(data: []const u8) []const u8 {
    return std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(data)}) catch return "";
}

// ── Hex Decode ──

pub fn hexDecode(data: []const u8) anyerror![]const u8 {
    if (data.len % 2 != 0) {
        return error.hex_string_must_have_even_length;
    }
    const dest = alloc.alloc(u8, data.len / 2) catch {
        return error.out_of_memory;
    };
    _ = std.fmt.hexToBytes(dest, data) catch {
        alloc.free(dest);
        return error.invalid_hex_data;
    };
    return dest;
}

// ── Tests ──

test "base64 encode" {
    const encoded = base64Encode("hello");
    try std.testing.expect(std.mem.eql(u8, encoded, "aGVsbG8="));
}

test "base64 decode" {
    const result = try base64Decode("aGVsbG8=");
    try std.testing.expect(std.mem.eql(u8, result, "hello"));
}

test "base64 decode invalid" {
    const result = base64Decode("!!!invalid!!!");
    try std.testing.expectError(error.invalid_base64_length, result);
}

test "hex encode" {
    const encoded = hexEncode("hi");
    try std.testing.expect(std.mem.eql(u8, encoded, "6869"));
}

test "hex decode" {
    const result = try hexDecode("6869");
    try std.testing.expect(std.mem.eql(u8, result, "hi"));
}

test "hex decode odd length" {
    const result = hexDecode("abc");
    try std.testing.expectError(error.hex_string_must_have_even_length, result);
}

test "roundtrip base64" {
    const original = "Orhon language 2026";
    const encoded = base64Encode(original);
    const decoded = try base64Decode(encoded);
    try std.testing.expect(std.mem.eql(u8, decoded, original));
}

test "roundtrip hex" {
    const original = "Orhon";
    const encoded = hexEncode(original);
    const decoded = try hexDecode(encoded);
    try std.testing.expect(std.mem.eql(u8, decoded, original));
}
