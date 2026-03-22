// system.zig — OS interaction sidecar for std::system

const std = @import("std");
const _rt = @import("_orhon_rt");

const alloc = std.heap.page_allocator;
const OrhonResult = _rt.OrhonResult;

// ── RunResult ──

pub const RunResult = struct {
    code: i32,
    stdout: []const u8,
    stderr: []const u8,
};

// ── Run ──

pub fn run(cmd: []const u8, args: []const []const u8) RunResult {
    var argv = std.ArrayListUnmanaged([]const u8){};
    argv.append(alloc, cmd) catch return .{ .code = -1, .stdout = "", .stderr = "out of memory" };
    for (args) |arg| {
        argv.append(alloc, arg) catch {};
    }

    var child = std.process.Child.init(argv.items, alloc);
    child.stdout_behavior = .Buffer;
    child.stderr_behavior = .Buffer;

    child.spawn() catch {
        return .{ .code = -1, .stdout = "", .stderr = "could not spawn process" };
    };
    const result = child.wait() catch {
        return .{ .code = -1, .stdout = "", .stderr = "could not wait for process" };
    };

    const code: i32 = switch (result.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };

    return .{
        .code = code,
        .stdout = child.stdout.items,
        .stderr = child.stderr.items,
    };
}

// ── GetEnv ──

pub fn getEnv(name: []const u8) OrhonResult([]const u8) {
    const env = std.process.getEnvMap(alloc) catch {
        return .{ .err = .{ .message = "could not read environment" } };
    };
    if (env.get(name)) |val| {
        return .{ .ok = alloc.dupe(u8, val) catch return .{ .err = .{ .message = "out of memory" } } };
    }
    return .{ .err = .{ .message = "environment variable not found" } };
}

// ── Cwd ──

pub fn cwd() []const u8 {
    var buf: [4096]u8 = undefined;
    const path = std.fs.cwd().realpath(".", &buf) catch return ".";
    return alloc.dupe(u8, path) catch return ".";
}

// ── Exit ──

pub fn exit(code: i32) void {
    std.process.exit(@intCast(code));
}

// ── Tests ──

test "run echo" {
    const result = run("echo", &.{"hello"});
    try std.testing.expectEqual(@as(i32, 0), result.code);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "hello"));
}

test "cwd" {
    const c = cwd();
    try std.testing.expect(c.len > 0);
}
