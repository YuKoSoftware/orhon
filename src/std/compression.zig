// compression.zig — gzip and zlib compression sidecar for std::compression
// Wraps Zig's std.compress for Orhon bridge.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Gzip Compress ──

pub fn gzipCompress(data: []const u8) OrhonResult([]const u8) {
    var buf = std.ArrayListUnmanaged(u8){};
    var compressor = std.compress.gzip.compressor(.write_to_buffer, &buf, .{
        .allocator = alloc,
    }) catch {
        return .{ .err = .{ .message = "could not create gzip compressor" } };
    };
    _ = compressor.write(data) catch {
        return .{ .err = .{ .message = "gzip compression failed" } };
    };
    compressor.close() catch {
        return .{ .err = .{ .message = "gzip compression failed" } };
    };
    return .{ .ok = buf.items };
}

// ── Gzip Decompress ──

pub fn gzipDecompress(data: []const u8) OrhonResult([]const u8) {
    var stream = std.io.fixedBufferStream(data);
    var decompressor = std.compress.gzip.decompressor(stream.reader()) catch {
        return .{ .err = .{ .message = "invalid gzip data" } };
    };
    const result = decompressor.reader().readAllAlloc(alloc, 100 * 1024 * 1024) catch {
        return .{ .err = .{ .message = "gzip decompression failed" } };
    };
    return .{ .ok = result };
}

// ── Zlib Compress ──

pub fn zlibCompress(data: []const u8) OrhonResult([]const u8) {
    var buf = std.ArrayListUnmanaged(u8){};
    var compressor = std.compress.zlib.compressor(.write_to_buffer, &buf, .{
        .allocator = alloc,
    }) catch {
        return .{ .err = .{ .message = "could not create zlib compressor" } };
    };
    _ = compressor.write(data) catch {
        return .{ .err = .{ .message = "zlib compression failed" } };
    };
    compressor.close() catch {
        return .{ .err = .{ .message = "zlib compression failed" } };
    };
    return .{ .ok = buf.items };
}

// ── Zlib Decompress ──

pub fn zlibDecompress(data: []const u8) OrhonResult([]const u8) {
    var stream = std.io.fixedBufferStream(data);
    var decompressor = std.compress.zlib.decompressor(stream.reader());
    const result = decompressor.reader().readAllAlloc(alloc, 100 * 1024 * 1024) catch {
        return .{ .err = .{ .message = "zlib decompression failed" } };
    };
    return .{ .ok = result };
}

// ── Tests ──

test "gzip roundtrip" {
    const original = "hello from orhon compression";
    const compressed = gzipCompress(original);
    try std.testing.expect(compressed == .ok);
    try std.testing.expect(compressed.ok.len > 0);
    const decompressed = gzipDecompress(compressed.ok);
    try std.testing.expect(decompressed == .ok);
    try std.testing.expect(std.mem.eql(u8, decompressed.ok, original));
}

test "zlib roundtrip" {
    const original = "zlib test data for orhon";
    const compressed = zlibCompress(original);
    try std.testing.expect(compressed == .ok);
    const decompressed = zlibDecompress(compressed.ok);
    try std.testing.expect(decompressed == .ok);
    try std.testing.expect(std.mem.eql(u8, decompressed.ok, original));
}

test "gzip compresses" {
    const data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const compressed = gzipCompress(data);
    try std.testing.expect(compressed == .ok);
    try std.testing.expect(compressed.ok.len < data.len);
}

test "gzip decompress invalid" {
    const result = gzipDecompress("not gzip data at all");
    try std.testing.expect(result == .err);
}
