// fs.zig — filesystem operations sidecar for std::fs
// All functions operate on paths as []const u8 (Orhon String).

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;

const OrhonError = _rt.OrhonError;
const OrhonResult = _rt.OrhonResult;

// ── Read ──

pub fn readFile(path: []const u8) OrhonResult([]const u8) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{ .err = .{ .message = "could not open file" } };
    };
    defer file.close();
    const content = file.readToEndAlloc(alloc, 100 * 1024 * 1024) catch {
        return .{ .err = .{ .message = "could not read file" } };
    };
    return .{ .ok = content };
}

// ── Write ──

pub fn writeFile(path: []const u8, content: []const u8) OrhonResult(void) {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        return .{ .err = .{ .message = "could not create file" } };
    };
    defer file.close();
    file.writeAll(content) catch {
        return .{ .err = .{ .message = "could not write file" } };
    };
    return .{ .ok = {} };
}

// ── Append ──

pub fn appendFile(path: []const u8, content: []const u8) OrhonResult(void) {
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch {
        // File doesn't exist — create it
        return writeFile(path, content);
    };
    defer file.close();
    file.seekTo(std.math.maxInt(u64)) catch {};
    const end = file.getPos() catch {
        return .{ .err = .{ .message = "could not seek to end" } };
    };
    _ = end;
    file.seekFromEnd(0) catch {};
    file.writeAll(content) catch {
        return .{ .err = .{ .message = "could not append to file" } };
    };
    return .{ .ok = {} };
}

// ── Exists ──

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Remove ──

pub fn remove(path: []const u8) OrhonResult(void) {
    std.fs.cwd().deleteFile(path) catch {
        return .{ .err = .{ .message = "could not delete file" } };
    };
    return .{ .ok = {} };
}

// ── Size ──

pub fn fileSize(path: []const u8) OrhonResult(i64) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return .{ .err = .{ .message = "could not open file" } };
    };
    defer file.close();
    const stat = file.stat() catch {
        return .{ .err = .{ .message = "could not stat file" } };
    };
    return .{ .ok = @intCast(stat.size) };
}

// ── Mkdir ──

pub fn mkdir(path: []const u8) OrhonResult(void) {
    std.fs.cwd().makePath(path) catch {
        return .{ .err = .{ .message = "could not create directory" } };
    };
    return .{ .ok = {} };
}

// ── ReadDir ──
// Returns newline-separated list of entry names

pub fn readDir(path: []const u8) OrhonResult([]const u8) {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        return .{ .err = .{ .message = "could not open directory" } };
    };
    defer dir.close();

    var buf = std.ArrayListUnmanaged(u8){};
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        buf.appendSlice(alloc, entry.name) catch return .{ .err = .{ .message = "out of memory" } };
        buf.append(alloc, '\n') catch return .{ .err = .{ .message = "out of memory" } };
    }
    return .{ .ok = buf.items };
}

// ── Path: Join ──

pub fn joinPath(a: []const u8, b: []const u8) []const u8 {
    return std.fs.path.join(alloc, &.{ a, b }) catch return "";
}

// ── Path: Dirname ──

pub fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

// ── Path: Basename ──

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// ── Path: Extension ──

pub fn extension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}

// ── Tests ──

test "writeFile and readFile" {
    const tmp = "/tmp/_orhon_fs_test.txt";
    const w = writeFile(tmp, "hello orhon");
    try std.testing.expect(w == .ok);
    const r = readFile(tmp);
    try std.testing.expect(r == .ok);
    try std.testing.expect(std.mem.eql(u8, r.ok, "hello orhon"));
    _ = remove(tmp);
}

test "exists" {
    const tmp = "/tmp/_orhon_fs_test2.txt";
    try std.testing.expect(!exists(tmp));
    _ = writeFile(tmp, "test");
    try std.testing.expect(exists(tmp));
    _ = remove(tmp);
    try std.testing.expect(!exists(tmp));
}

test "size" {
    const tmp = "/tmp/_orhon_fs_test3.txt";
    _ = writeFile(tmp, "12345");
    const s = fileSize(tmp);
    try std.testing.expect(s == .ok);
    try std.testing.expectEqual(@as(i64, 5), s.ok);
    _ = remove(tmp);
}

test "mkdir" {
    const tmp = "/tmp/_orhon_fs_testdir";
    _ = mkdir(tmp);
    try std.testing.expect(exists(tmp));
    std.fs.cwd().deleteDir(tmp) catch {};
}

test "joinPath" {
    const result = joinPath("/home/user", "file.txt");
    try std.testing.expect(std.mem.eql(u8, result, "/home/user/file.txt"));
}

test "dirname" {
    try std.testing.expect(std.mem.eql(u8, dirname("/home/user/file.txt"), "/home/user"));
}

test "basename" {
    try std.testing.expect(std.mem.eql(u8, basename("/home/user/file.txt"), "file.txt"));
}

test "extension" {
    try std.testing.expect(std.mem.eql(u8, extension("file.txt"), ".txt"));
    try std.testing.expect(std.mem.eql(u8, extension("archive.tar.gz"), ".gz"));
    try std.testing.expect(std.mem.eql(u8, extension("noext"), ""));
}
