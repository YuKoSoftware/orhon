// system.zig — OS interaction sidecar for std::system

const std = @import("std");

const alloc = std.heap.page_allocator;

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

pub fn getEnv(name: []const u8) anyerror![]const u8 {
    const env = std.process.getEnvMap(alloc) catch {
        return error.could_not_read_environment;
    };
    if (env.get(name)) |val| {
        return alloc.dupe(u8, val) catch return error.out_of_memory;
    }
    return error.environment_variable_not_found;
}

// ── SetEnv ──

pub fn setEnv(name: []const u8, value: []const u8) anyerror!void {
    // Convert to null-terminated strings for POSIX setenv
    const name_z = alloc.dupeZ(u8, name) catch return error.out_of_memory;
    const value_z = alloc.dupeZ(u8, value) catch return error.out_of_memory;
    const result = std.c.setenv(name_z, value_z, 1);
    if (result != 0) return error.could_not_set_environment_variable;
}

// ── HasEnv ──

pub fn hasEnv(name: []const u8) bool {
    const env = std.process.getEnvMap(alloc) catch return false;
    return env.get(name) != null;
}

// ── AllEnv ──

pub fn allEnv() []const u8 {
    const env = std.process.getEnvMap(alloc) catch return "";
    var buf = std.ArrayListUnmanaged(u8){};
    var iter = env.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) buf.append(alloc, '\n') catch {};
        first = false;
        buf.appendSlice(alloc, entry.key_ptr.*) catch {};
        buf.append(alloc, '=') catch {};
        buf.appendSlice(alloc, entry.value_ptr.*) catch {};
    }
    return if (buf.items.len > 0) buf.items else "";
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

// ── Signals ──

const posix = std.posix;

var signal_flags: [32]bool = .{false} ** 32;

fn signalHandler(sig: i32) callconv(.c) void {
    const idx: usize = @intCast(sig);
    if (idx < signal_flags.len) {
        signal_flags[idx] = true;
    }
}

pub fn trapSignal(sig: i32) void {
    const s: u6 = @intCast(sig);
    const act = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.empty_sigset,
        .flags = .{ .RESTART = true },
    };
    posix.sigaction(s, &act, null) catch {};
}

pub fn checkSignal(sig: i32) bool {
    const idx: usize = @intCast(sig);
    if (idx < signal_flags.len) {
        return signal_flags[idx];
    }
    return false;
}

pub fn clearSignal(sig: i32) void {
    const idx: usize = @intCast(sig);
    if (idx < signal_flags.len) {
        signal_flags[idx] = false;
    }
}

pub fn raise(sig: i32) void {
    const s: u6 = @intCast(sig);
    _ = posix.raise(s) catch {};
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

test "setEnv and getEnv" {
    try setEnv("_ORHON_TEST_VAR", "hello");
    const g = try getEnv("_ORHON_TEST_VAR");
    try std.testing.expect(std.mem.eql(u8, g, "hello"));
}

test "hasEnv" {
    try setEnv("_ORHON_TEST_HAS", "1");
    try std.testing.expect(hasEnv("_ORHON_TEST_HAS"));
    try std.testing.expect(!hasEnv("_ORHON_NONEXISTENT_VAR_12345"));
}

test "allEnv contains PATH" {
    const env = allEnv();
    try std.testing.expect(std.mem.indexOf(u8, env, "PATH=") != null);
}

test "trap and raise signal" {
    trapSignal(10); // SIGUSR1
    try std.testing.expect(!checkSignal(10));
    raise(10);
    try std.testing.expect(checkSignal(10));
    clearSignal(10);
    try std.testing.expect(!checkSignal(10));
}
