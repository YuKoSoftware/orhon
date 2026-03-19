// zig_runner.zig — Zig Compiler Runner pass (pass 12)
// Invokes the Zig compiler on generated .zig files.
// Captures stdout/stderr — never shown to user unless -zig flag is set.
// Finds Zig binary in: 1) same dir as kodr binary, 2) PATH

const std = @import("std");
const errors = @import("errors.zig");
const cache = @import("cache.zig");

/// Result of a Zig compiler invocation
pub const ZigResult = struct {
    success: bool,
    stdout: []u8,
    stderr: []u8,
    exit_code: u32,

    pub fn deinit(self: *ZigResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// The Zig runner
pub const ZigRunner = struct {
    zig_path: []const u8,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    show_zig_output: bool, // -zig flag

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *errors.Reporter,
        show_zig_output: bool,
    ) !ZigRunner {
        const zig_path = try findZig(allocator);
        return .{
            .zig_path = zig_path,
            .reporter = reporter,
            .allocator = allocator,
            .show_zig_output = show_zig_output,
        };
    }

    pub fn deinit(self: *ZigRunner) void {
        self.allocator.free(self.zig_path);
    }

    /// Build the generated Zig project
    /// Build the generated Zig project
    pub fn build(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8) !bool {
        var args: std.ArrayListUnmanaged([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, self.zig_path);
        try args.append(self.allocator, "build");

        if (target.len > 0) {
            const target_flag = try std.fmt.allocPrint(self.allocator, "-Dtarget={s}", .{target});
            defer self.allocator.free(target_flag);
            try args.append(self.allocator, target_flag);
        }

        if (std.mem.eql(u8, optimize, "release")) {
            try args.append(self.allocator, "-Doptimize=ReleaseSafe");
        } else if (std.mem.eql(u8, optimize, "fast")) {
            try args.append(self.allocator, "-Doptimize=ReleaseFast");
        }

        // zig build runs from the directory containing build.zig
        var result = try self.runZigIn(args.items, cache.GENERATED_DIR);
        defer result.deinit(self.allocator);

        if (self.show_zig_output) {
            try self.printRaw(result.stdout);
            try self.printRaw(result.stderr);
        }

        if (!result.success) {
            if (!self.show_zig_output) {
                try self.reformatZigErrors(result.stderr);
            }
            return false;
        }

        // Copy binary from .kodr-cache/generated/zig-out/bin/<project_name> to ./bin/<project_name>
        const src_bin = try std.fs.path.join(self.allocator, &.{
            cache.GENERATED_DIR, "zig-out", "bin", project_name,
        });
        defer self.allocator.free(src_bin);

        try std.fs.cwd().makePath("bin");

        const dst_bin = try std.fs.path.join(self.allocator, &.{ "bin", project_name });
        defer self.allocator.free(dst_bin);

        try std.fs.cwd().copyFile(src_bin, std.fs.cwd(), dst_bin, .{});

        // Remove generated zig-out — bin/ now has the only copy
        const generated_zig_out = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, "zig-out" });
        defer self.allocator.free(generated_zig_out);
        std.fs.cwd().deleteTree(generated_zig_out) catch {};

        _ = module_name;
        std.debug.print("Built: bin/{s}\n", .{project_name});
        return true;
    }

    /// Run Zig and capture output
    fn runZig(self: *ZigRunner, args: []const []const u8) !ZigResult {
        var child = std.process.Child.init(args, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);

        const term = try child.wait();
        const exit_code: u32 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return ZigResult{
            .success = exit_code == 0,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
        };
    }

    /// Like runZig but runs from a specific working directory
    fn runZigIn(self: *ZigRunner, args: []const []const u8, cwd: []const u8) !ZigResult {
        var child = std.process.Child.init(args, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = cwd;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);

        const term = try child.wait();
        const exit_code: u32 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return ZigResult{
            .success = exit_code == 0,
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
        };
    }

    /// Print raw output to stderr (for -zig flag)
    fn printRaw(self: *ZigRunner, output: []const u8) !void {
        _ = self;
        if (output.len == 0) return;
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const stderr = &w.interface;
        try stderr.print("{s}", .{output});
        try stderr.flush();
    }

    /// Parse Zig compiler errors and reformat as Kodr errors
    /// This should ideally never trigger in a correct compiler implementation
    fn reformatZigErrors(self: *ZigRunner, stderr: []const u8) !void {
        // Zig errors look like: path/to/file.zig:line:col: error: message
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Try to parse Zig error format
            if (std.mem.indexOf(u8, line, ": error:")) |_| {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "internal codegen error (please report): {s}", .{line});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            }
        }
    }

    /// Generate the build.zig file for the generated Zig project
    pub fn generateBuildZig(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
    ) !void {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {
            \\    const target = b.standardTargetOptions(.{});
            \\    const optimize = b.standardOptimizeOption(.{});
            \\
        );

        if (std.mem.eql(u8, build_type, "exe")) {
            const exe_chunk = try std.fmt.allocPrint(self.allocator,
                \\    const exe = b.addExecutable(.{{
                \\        .name = "{s}",
                \\        .root_module = b.createModule(.{{
                \\            .root_source_file = b.path("{s}.zig"),
                \\            .target = target,
                \\            .optimize = optimize,
                \\        }}),
                \\    }});
                \\    b.installArtifact(exe);
                \\
                \\    const run_cmd = b.addRunArtifact(exe);
                \\    run_cmd.step.dependOn(b.getInstallStep());
                \\    const run_step = b.step("run", "Run");
                \\    run_step.dependOn(&run_cmd.step);
                \\
            , .{ project_name, module_name });
            defer self.allocator.free(exe_chunk);
            try buf.appendSlice(self.allocator, exe_chunk);
        } else if (std.mem.eql(u8, build_type, "static")) {
            const lib_chunk = try std.fmt.allocPrint(self.allocator,
                \\    const lib = b.addLibrary(.{{
                \\        .name = "{s}",
                \\        .linkage = .static,
                \\        .root_module = b.createModule(.{{
                \\            .root_source_file = b.path("{s}.zig"),
                \\            .target = target,
                \\            .optimize = optimize,
                \\        }}),
                \\    }});
                \\    b.installArtifact(lib);
                \\
            , .{ project_name, module_name });
            defer self.allocator.free(lib_chunk);
            try buf.appendSlice(self.allocator, lib_chunk);
        }

        try buf.appendSlice(self.allocator,
            \\}
            \\
        );

        try cache.writeGeneratedZig("build", buf.items, self.allocator);
    }
};

/// Find the Zig binary
/// 1. Check same directory as kodr binary
/// 2. Check PATH
pub fn findZig(allocator: std.mem.Allocator) ![]const u8 {
    // Get path to kodr binary
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
        return errors.fatal("zig compiler not found\n  place zig binary ({s}) next to kodr, or install zig globally\n  download zig at: https://ziglang.org/download", .{zigBinaryName()});
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

    return errors.fatal("zig compiler not found\n  place zig binary ({s}) next to kodr, or install zig globally\n  download zig at: https://ziglang.org/download", .{zigBinaryName()});
}

fn zigBinaryName() []const u8 {
    return if (builtin.os.tag == .windows) "zig.exe" else "zig";
}

const builtin = @import("builtin");

test "zig runner - find zig path format" {
    // Just test that the function exists and returns something
    // Can't actually test finding zig in CI without it being installed
    const alloc = std.testing.allocator;

    // Test that zigBinaryName works
    const name = zigBinaryName();
    try std.testing.expect(name.len > 0);
    _ = alloc;
}
