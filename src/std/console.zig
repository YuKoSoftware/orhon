// console.zig — terminal I/O implementation for Kodr's std::console
// Hand-written implementation. Paired with console.kodr.
// Do not edit the generated console.zig in .kodr-cache/generated/ —
// edit this source file and run kodr initstd to update.

const std = @import("std");

const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

pub fn print(msg: []const u8) void {
    stdout.writeAll(msg) catch {};
}

pub fn println(msg: []const u8) void {
    stdout.writeAll(msg) catch {};
    stdout.writeAll("\n") catch {};
}

pub fn debugPrint(msg: []const u8) void {
    stderr.writeAll(msg) catch {};
}

// GetResult mirrors (Error | string) as the codegen expects: .ok and .err tags
const GetError = struct { message: []const u8 };
const GetResult = union(enum) { ok: []const u8, err: GetError };

var get_buf: [4096]u8 = undefined;

pub fn get() GetResult {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const line = stdin.reader().readUntilDelimiterOrEof(&get_buf, '\n') catch {
        return .{ .err = .{ .message = "stdin read error" } };
    };
    if (line) |l| {
        return .{ .ok = l };
    } else {
        return .{ .err = .{ .message = "end of input" } };
    }
}
