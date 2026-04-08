// console.zig — terminal I/O implementation for Orhon's std::console
// Hand-written implementation. .orh declarations auto-generated from this file.
// Do not edit the generated console.zig in .orh-cache/generated/ —
// edit this source file — embedded into the compiler at build time.

const std = @import("std");

const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
const stderr = std.fs.File{ .handle = std.posix.STDERR_FILENO };

var buf: [4096]u8 = undefined;
var w: std.fs.File.Writer = stdout.writer(&buf);

/// Writes a string to stdout without a trailing newline.
pub fn print(msg: []const u8) void {
    w.interface.writeAll(msg) catch {}; // fire-and-forget: I/O in void fn
}

/// Writes a string to stdout followed by a newline and flushes.
pub fn println(msg: []const u8) void {
    w.interface.writeAll(msg) catch {}; // fire-and-forget: I/O in void fn
    w.interface.writeAll("\n") catch {};
    w.interface.flush() catch {};
}

/// Flushes the stdout write buffer.
pub fn flush() void {
    w.interface.flush() catch {}; // fire-and-forget: I/O in void fn
}

/// Writes a string to stderr for debug output.
pub fn debugPrint(msg: []const u8) void {
    stderr.writeAll(msg) catch {}; // fire-and-forget: I/O in void fn
}

var get_buf: [4096]u8 = undefined;

/// Returns true if stdout is a terminal that supports ANSI colors.
pub fn supportsColor() bool {
    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

// ANSI color constants
/// ANSI reset sequence.
pub const RESET = "\x1b[0m";
/// ANSI bold text sequence.
pub const BOLD = "\x1b[1m";
/// ANSI dim text sequence.
pub const DIM = "\x1b[2m";
/// ANSI underline text sequence.
pub const UNDERLINE = "\x1b[4m";

/// ANSI red foreground sequence.
pub const RED = "\x1b[31m";
/// ANSI green foreground sequence.
pub const GREEN = "\x1b[32m";
/// ANSI yellow foreground sequence.
pub const YELLOW = "\x1b[33m";
/// ANSI blue foreground sequence.
pub const BLUE = "\x1b[34m";
/// ANSI magenta foreground sequence.
pub const MAGENTA = "\x1b[35m";
/// ANSI cyan foreground sequence.
pub const CYAN = "\x1b[36m";
/// ANSI white foreground sequence.
pub const WHITE = "\x1b[37m";

/// Prints a message wrapped in the given ANSI color, then resets.
pub fn printColored(color: []const u8, msg: []const u8) void {
    print(color);
    print(msg);
    print(RESET);
}

/// Prints a message wrapped in the given ANSI color, then resets and adds a newline.
pub fn printColoredLn(color: []const u8, msg: []const u8) void {
    print(color);
    print(msg);
    println(RESET);
}

/// Reads a line from stdin, blocking until a newline or EOF.
pub fn get() anyerror![]const u8 {
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const line = try stdin.reader().readUntilDelimiterOrEof(&get_buf, '\n');
    return line orelse error.EndOfInput;
}
