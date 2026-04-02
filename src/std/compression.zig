// compression.zig — gzip and zlib compression implementation for std::compression
// Wraps Zig's std.compress for Orhon.

const std = @import("std");

const alloc = std.heap.smp_allocator;

// ── Gzip Compress ──

pub fn gzipCompress(data: []const u8) anyerror![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var compressor = std.compress.gzip.compressor(.write_to_buffer, &buf, .{
        .allocator = alloc,
    }) catch {
        return error.could_not_create_gzip_compressor;
    };
    _ = compressor.write(data) catch {
        return error.gzip_compression_failed;
    };
    compressor.close() catch {
        return error.gzip_compression_failed;
    };
    return buf.items;
}

// ── Gzip Decompress ──

pub fn gzipDecompress(data: []const u8) anyerror![]const u8 {
    var stream = std.io.fixedBufferStream(data);
    var decompressor = std.compress.gzip.decompressor(stream.reader()) catch {
        return error.invalid_gzip_data;
    };
    const result = decompressor.reader().readAllAlloc(alloc, 100 * 1024 * 1024) catch {
        return error.gzip_decompression_failed;
    };
    return result;
}

// ── Zlib Compress ──

pub fn zlibCompress(data: []const u8) anyerror![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    var compressor = std.compress.zlib.compressor(.write_to_buffer, &buf, .{
        .allocator = alloc,
    }) catch {
        return error.could_not_create_zlib_compressor;
    };
    _ = compressor.write(data) catch {
        return error.zlib_compression_failed;
    };
    compressor.close() catch {
        return error.zlib_compression_failed;
    };
    return buf.items;
}

// ── Zlib Decompress ──

pub fn zlibDecompress(data: []const u8) anyerror![]const u8 {
    var stream = std.io.fixedBufferStream(data);
    var decompressor = std.compress.zlib.decompressor(stream.reader());
    const result = decompressor.reader().readAllAlloc(alloc, 100 * 1024 * 1024) catch {
        return error.zlib_decompression_failed;
    };
    return result;
}

// ── Tests ──

test "gzip roundtrip" {
    const original = "hello from orhon compression";
    const compressed = try gzipCompress(original);
    try std.testing.expect(compressed.len > 0);
    const decompressed = try gzipDecompress(compressed);
    try std.testing.expect(std.mem.eql(u8, decompressed, original));
}

test "zlib roundtrip" {
    const original = "zlib test data for orhon";
    const compressed = try zlibCompress(original);
    const decompressed = try zlibDecompress(compressed);
    try std.testing.expect(std.mem.eql(u8, decompressed, original));
}

test "gzip compresses" {
    const data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const compressed = try gzipCompress(data);
    try std.testing.expect(compressed.len < data.len);
}

test "gzip decompress invalid" {
    const result = gzipDecompress("not gzip data at all");
    try std.testing.expectError(error.invalid_gzip_data, result);
}
