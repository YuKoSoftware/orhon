// fs.zig — filesystem operations sidecar for std::fs
// All functions operate on paths as []const u8 (Orhon str).

const std = @import("std");

const alloc = std.heap.smp_allocator;

// ── Read ──

/// Reads the entire contents of a file at the given path into memory.
pub fn readFile(path: []const u8) anyerror![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.could_not_open_file;
    };
    defer file.close();
    const content = file.readToEndAlloc(alloc, 100 * 1024 * 1024) catch {
        return error.could_not_read_file;
    };
    return content;
}

// ── Write ──

/// Creates or overwrites a file at the given path with the provided content.
pub fn writeFile(path: []const u8, content: []const u8) anyerror!void {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        return error.could_not_create_file;
    };
    defer file.close();
    file.writeAll(content) catch {
        return error.could_not_write_file;
    };
}

// ── Append ──

/// Appends content to the end of an existing file, or creates it if it does not exist.
pub fn appendFile(path: []const u8, content: []const u8) anyerror!void {
    const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch {
        // File doesn't exist — create it
        return writeFile(path, content);
    };
    defer file.close();
    file.seekTo(std.math.maxInt(u64)) catch {}; // best-effort: seek/cleanup failure is non-fatal
    file.seekFromEnd(0) catch {};
    file.writeAll(content) catch {
        return error.could_not_append_to_file;
    };
}

// ── Exists ──

/// Returns true if a file or directory exists at the given path.
pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Remove ──

/// Deletes the file at the given path.
pub fn remove(path: []const u8) anyerror!void {
    std.fs.cwd().deleteFile(path) catch {
        return error.could_not_delete_file;
    };
}

// ── Size ──

/// Returns the size of the file at the given path in bytes.
pub fn fileSize(path: []const u8) anyerror!i64 {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.could_not_open_file;
    };
    defer file.close();
    const stat = file.stat() catch {
        return error.could_not_stat_file;
    };
    return @intCast(stat.size);
}

// ── Mkdir ──

/// Creates a directory at the given path, including any missing parent directories.
pub fn mkdir(path: []const u8) anyerror!void {
    std.fs.cwd().makePath(path) catch {
        return error.could_not_create_directory;
    };
}

// ── ReadDir ──
// Returns newline-separated list of entry names

/// Lists the entries in a directory, returned as a newline-separated string of names.
pub fn readDir(path: []const u8) anyerror![]const u8 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        return error.could_not_open_directory;
    };
    defer dir.close();

    var buf = std.ArrayListUnmanaged(u8){};
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        buf.appendSlice(alloc, entry.name) catch return error.out_of_memory;
        buf.append(alloc, '\n') catch return error.out_of_memory;
    }
    return buf.items;
}

// ── Path: Join ──

/// Joins two path components with the platform path separator.
pub fn joinPath(a: []const u8, b: []const u8) []const u8 {
    return std.fs.path.join(alloc, &.{ a, b }) catch return "";
}

// ── Path: Dirname ──

/// Returns the directory portion of a path, or empty string if none.
pub fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse "";
}

// ── Path: Basename ──

/// Returns the final component of a path (the file or directory name).
pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

// ── Path: Extension ──

/// Returns the file extension including the leading dot, or empty string if none.
pub fn extension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}

// ── Tests ──

test "writeFile and readFile" {
    const tmp = "/tmp/_orhon_fs_test.txt";
    try writeFile(tmp, "hello orhon");
    const content = try readFile(tmp);
    try std.testing.expect(std.mem.eql(u8, content, "hello orhon"));
    try remove(tmp);
}

test "exists" {
    const tmp = "/tmp/_orhon_fs_test2.txt";
    try std.testing.expect(!exists(tmp));
    try writeFile(tmp, "test");
    try std.testing.expect(exists(tmp));
    try remove(tmp);
    try std.testing.expect(!exists(tmp));
}

test "size" {
    const tmp = "/tmp/_orhon_fs_test3.txt";
    try writeFile(tmp, "12345");
    const s = try fileSize(tmp);
    try std.testing.expectEqual(@as(i64, 5), s);
    try remove(tmp);
}

test "mkdir" {
    const tmp = "/tmp/_orhon_fs_testdir";
    try mkdir(tmp);
    try std.testing.expect(exists(tmp));
    std.fs.cwd().deleteDir(tmp) catch {}; // best-effort: seek/cleanup failure is non-fatal
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
