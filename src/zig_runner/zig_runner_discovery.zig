// zig_runner_discovery.zig — Zig binary discovery
// Locates the zig binary in the same directory as the orhon binary, or in PATH.

const std = @import("std");
const errors = @import("../errors.zig");
const builtin = @import("builtin");

/// Find the Zig binary
/// 1. Check same directory as orhon binary
/// 2. Check PATH
pub fn findZig(allocator: std.mem.Allocator) ![]const u8 {
    // Get path to orhon binary
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_path_buf) catch null;

    if (exe_path) |path| {
        const dir = std.fs.path.dirname(path) orelse "";
        const local_zig = try std.fs.path.join(allocator, &.{ dir, zigBinaryName() });

        // Check if zig exists in same directory
        std.fs.cwd().access(local_zig, .{}) catch {
            allocator.free(local_zig);
            return findZigInPath(allocator);
        };

        return local_zig;
    }

    return findZigInPath(allocator);
}

fn findZigInPath(allocator: std.mem.Allocator) ![]const u8 {
    // Search PATH for zig binary
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch {
        return errors.fatal("zig compiler not found\n  place zig binary ({s}) next to orhon, or install zig globally\n  download zig at: https://ziglang.org/download", .{zigBinaryName()});
    };
    defer allocator.free(path_env);

    var paths = std.mem.splitScalar(u8, path_env, if (builtin.os.tag == .windows) ';' else ':');
    while (paths.next()) |dir| {
        const zig_path = try std.fs.path.join(allocator, &.{ dir, zigBinaryName() });
        std.fs.cwd().access(zig_path, .{}) catch {
            allocator.free(zig_path);
            continue;
        };
        return zig_path;
    }

    return errors.fatal("zig compiler not found\n  place zig binary ({s}) next to orhon, or install zig globally\n  download zig at: https://ziglang.org/download", .{zigBinaryName()});
}

fn zigBinaryName() []const u8 {
    return if (builtin.os.tag == .windows) "zig.exe" else "zig";
}

test "zig runner - find zig path format" {
    const name = zigBinaryName();
    try std.testing.expect(name.len > 0);
}
