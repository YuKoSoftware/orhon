// stream.zig — in-memory byte buffer sidecar for std::stream
// Growable byte array with a read cursor.

const std = @import("std");

const alloc = std.heap.page_allocator;

// ── Buffer ──

pub const Buffer = struct {
    data: std.ArrayListUnmanaged(u8),
    cursor: usize,

    pub fn create() Buffer {
        return .{ .data = .{}, .cursor = 0 };
    }

    pub fn fromString(src: []const u8) Buffer {
        var buf = Buffer.create();
        buf.data.appendSlice(alloc, src) catch {};
        return buf;
    }

    pub fn write(self: *Buffer, src: []const u8) void {
        self.data.appendSlice(alloc, src) catch {};
    }

    pub fn read(self: *Buffer, n: i32) []const u8 {
        const count: usize = @intCast(@max(0, n));
        if (self.cursor >= self.data.items.len) return "";
        const end = @min(self.cursor + count, self.data.items.len);
        const slice = alloc.dupe(u8, self.data.items[self.cursor..end]) catch return "";
        self.cursor = end;
        return slice;
    }

    pub fn toString(self: *Buffer) []const u8 {
        if (self.data.items.len == 0) return "";
        return alloc.dupe(u8, self.data.items) catch return "";
    }

    pub fn size(self: *Buffer) i32 {
        return @intCast(self.data.items.len);
    }

    pub fn clear(self: *Buffer) void {
        self.data.clearRetainingCapacity();
        self.cursor = 0;
    }

    pub fn seek(self: *Buffer, pos: i32) void {
        const p: usize = @intCast(@max(0, pos));
        self.cursor = @min(p, self.data.items.len);
    }

    pub fn deinit(self: *Buffer) void {
        self.data.deinit(alloc);
    }
};

// ── Tests ──

test "create and write" {
    var buf = Buffer.create();
    defer buf.deinit();
    buf.write("hello");
    buf.write(" world");
    try std.testing.expectEqual(@as(i32, 11), buf.size());
}

test "fromString" {
    var buf = Buffer.fromString("orhon");
    defer buf.deinit();
    try std.testing.expectEqual(@as(i32, 5), buf.size());
    try std.testing.expect(std.mem.eql(u8, buf.toString(), "orhon"));
}

test "read advances cursor" {
    var buf = Buffer.fromString("abcdef");
    defer buf.deinit();
    const first = buf.read(3);
    try std.testing.expect(std.mem.eql(u8, first, "abc"));
    const second = buf.read(3);
    try std.testing.expect(std.mem.eql(u8, second, "def"));
    const empty = buf.read(1);
    try std.testing.expect(std.mem.eql(u8, empty, ""));
}

test "seek and read" {
    var buf = Buffer.fromString("hello");
    defer buf.deinit();
    _ = buf.read(5); // consume all
    buf.seek(0);     // rewind
    const data = buf.read(5);
    try std.testing.expect(std.mem.eql(u8, data, "hello"));
}

test "clear resets" {
    var buf = Buffer.fromString("data");
    defer buf.deinit();
    buf.clear();
    try std.testing.expectEqual(@as(i32, 0), buf.size());
    try std.testing.expect(std.mem.eql(u8, buf.toString(), ""));
}
