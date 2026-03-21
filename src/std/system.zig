// system.zig — OS/system operations implementation for Kodr's std::system
// Hand-written implementation. Paired with system.kodr.
// Do not edit the generated system.zig in .kodr-cache/generated/ —
// edit this source file and run kodr initstd to update.

const std = @import("std");

fn KodrNullable(comptime T: type) type {
    return union(enum) { some: T, none: void };
}

pub fn getEnv(key: []const u8) KodrNullable([]const u8) {
    const val = std.process.getEnvVarOwned(std.heap.smp_allocator, key) catch {
        return .{ .none = {} };
    };
    return .{ .some = val };
}

pub fn setEnv(key: []const u8, value: []const u8) void {
    std.posix.setenv(key, value) catch {};
}

pub fn args() []const []const u8 {
    const argv = std.process.argsAlloc(std.heap.smp_allocator) catch return &.{};
    return argv;
}

pub fn cwd() []const u8 {
    const dir = std.process.getCwdAlloc(std.heap.smp_allocator) catch return "";
    return dir;
}

pub fn exit(code: i32) void {
    std.process.exit(@intCast(code));
}

pub fn pid() i32 {
    return @intCast(std.os.linux.getpid());
}
