// crypto.zig — hashing, HMAC, and AES-GCM sidecar for std::crypto
// All hash functions return lowercase hex digest strings.

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── Helpers ──

fn hexDigest(comptime Hash: type, data: []const u8) []const u8 {
    var hasher = Hash.init(.{});
    hasher.update(data);
    const digest = hasher.finalResult();
    return std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch return "";
}

// ── Hashing ──

pub fn sha256(data: []const u8) []const u8 {
    return hexDigest(std.crypto.hash.sha2.Sha256, data);
}

pub fn sha512(data: []const u8) []const u8 {
    return hexDigest(std.crypto.hash.sha2.Sha512, data);
}

pub fn md5(data: []const u8) []const u8 {
    return hexDigest(std.crypto.hash.Md5, data);
}

pub fn blake3(data: []const u8) []const u8 {
    return hexDigest(std.crypto.hash.Blake3, data);
}

// ── HMAC ──

pub fn hmacSha256(data: []const u8, key: []const u8) []const u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, data, key);
    return std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&mac)}) catch return "";
}

// ── AES-GCM ──

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub fn encrypt(plaintext: []const u8, key: []const u8) OrhonResult([]const u8) {
    if (key.len != 32) {
        return .{ .err = .{ .message = "key must be exactly 32 bytes" } };
    }

    // Generate random nonce
    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    // Allocate output: nonce ++ ciphertext ++ tag
    const ct_len = plaintext.len;
    const blob_len = Aes256Gcm.nonce_length + ct_len + Aes256Gcm.tag_length;
    const blob = alloc.alloc(u8, blob_len) catch {
        return .{ .err = .{ .message = "out of memory" } };
    };

    // Encrypt in place
    const ct_slice = blob[Aes256Gcm.nonce_length .. Aes256Gcm.nonce_length + ct_len];
    const tag_slice = blob[Aes256Gcm.nonce_length + ct_len ..][0..Aes256Gcm.tag_length];
    Aes256Gcm.encrypt(ct_slice, tag_slice, plaintext, "", nonce, key[0..32].*);

    // Prepend nonce
    @memcpy(blob[0..Aes256Gcm.nonce_length], &nonce);

    // Base64 encode the blob
    const b64_size = std.base64.standard.Encoder.calcSize(blob_len);
    const encoded = alloc.alloc(u8, b64_size) catch {
        alloc.free(blob);
        return .{ .err = .{ .message = "out of memory" } };
    };
    _ = std.base64.standard.Encoder.encode(encoded, blob);
    alloc.free(blob);

    return .{ .ok = encoded };
}

pub fn decrypt(ciphertext: []const u8, key: []const u8) OrhonResult([]const u8) {
    if (key.len != 32) {
        return .{ .err = .{ .message = "key must be exactly 32 bytes" } };
    }

    // Base64 decode
    const blob_size = std.base64.standard.Decoder.calcSizeForSlice(ciphertext) catch {
        return .{ .err = .{ .message = "invalid base64" } };
    };
    const min_size = Aes256Gcm.nonce_length + Aes256Gcm.tag_length;
    if (blob_size < min_size) {
        return .{ .err = .{ .message = "ciphertext too short" } };
    }
    const blob = alloc.alloc(u8, blob_size) catch {
        return .{ .err = .{ .message = "out of memory" } };
    };
    defer alloc.free(blob);
    std.base64.standard.Decoder.decode(blob, ciphertext) catch {
        return .{ .err = .{ .message = "invalid base64" } };
    };

    // Split: nonce ++ ciphertext ++ tag
    const nonce = blob[0..Aes256Gcm.nonce_length].*;
    const ct_len = blob_size - Aes256Gcm.nonce_length - Aes256Gcm.tag_length;
    const ct = blob[Aes256Gcm.nonce_length .. Aes256Gcm.nonce_length + ct_len];
    const tag = blob[Aes256Gcm.nonce_length + ct_len ..][0..Aes256Gcm.tag_length].*;

    // Decrypt
    const plaintext = alloc.alloc(u8, ct_len) catch {
        return .{ .err = .{ .message = "out of memory" } };
    };
    Aes256Gcm.decrypt(plaintext, ct, tag, "", nonce, key[0..32].*) catch {
        alloc.free(plaintext);
        return .{ .err = .{ .message = "decryption failed — wrong key or corrupted data" } };
    };

    return .{ .ok = plaintext };
}

// ── UUID v4 ──

pub fn uuid() []const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    // Set version (4) and variant (RFC 4122)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(alloc, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    }) catch return "";
}

// ── Tests ──

test "sha256" {
    const hash = sha256("hello");
    // SHA-256 of "hello" is well-known
    try std.testing.expect(std.mem.eql(u8, hash, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"));
}

test "md5" {
    const hash = md5("hello");
    try std.testing.expect(std.mem.eql(u8, hash, "5d41402abc4b2a76b9719d911017c592"));
}

test "hmacSha256" {
    const mac = hmacSha256("hello", "secret");
    try std.testing.expect(mac.len == 64); // 32 bytes = 64 hex chars
}

test "encrypt and decrypt roundtrip" {
    const key = "01234567890123456789012345678901"; // 32 bytes
    const plaintext = "secret message from orhon";
    const enc = encrypt(plaintext, key);
    try std.testing.expect(enc == .ok);
    const dec = decrypt(enc.ok, key);
    try std.testing.expect(dec == .ok);
    try std.testing.expect(std.mem.eql(u8, dec.ok, plaintext));
}

test "encrypt bad key length" {
    const result = encrypt("data", "short");
    try std.testing.expect(result == .err);
}

test "decrypt bad key" {
    const key1 = "01234567890123456789012345678901";
    const key2 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345";
    const enc = encrypt("hello", key1);
    try std.testing.expect(enc == .ok);
    const dec = decrypt(enc.ok, key2);
    try std.testing.expect(dec == .err);
}

test "uuid format" {
    const id = uuid();
    try std.testing.expectEqual(@as(usize, 36), id.len); // 8-4-4-4-12
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    // Version nibble must be '4'
    try std.testing.expectEqual(@as(u8, '4'), id[14]);
}

test "uuid uniqueness" {
    const a = uuid();
    const b = uuid();
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
