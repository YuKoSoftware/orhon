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
    pub fn build(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8) !bool {
        return self.buildWithType(target, optimize, module_name, project_name, "exe");
    }

    pub fn buildLib(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8, build_type: []const u8) !bool {
        return self.buildWithType(target, optimize, module_name, project_name, build_type);
    }

    fn buildWithType(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8, build_type: []const u8) !bool {
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

        // Determine source and destination paths based on build type.
        // exe  → zig-out/bin/<name>     → bin/<name>
        // static/dynamic → zig-out/lib/lib<name>.a → bin/lib<name>.a
        const is_lib = !std.mem.eql(u8, build_type, "exe");
        const ext: []const u8 = if (std.mem.eql(u8, build_type, "dynamic")) ".so" else ".a";

        const src_bin = if (is_lib)
            try std.fmt.allocPrint(self.allocator, "{s}/zig-out/lib/lib{s}{s}", .{ cache.GENERATED_DIR, project_name, ext })
        else
            try std.fs.path.join(self.allocator, &.{ cache.GENERATED_DIR, "zig-out", "bin", project_name });
        defer self.allocator.free(src_bin);

        try std.fs.cwd().makePath("bin");

        const dst_name = if (is_lib)
            try std.fmt.allocPrint(self.allocator, "bin/lib{s}{s}", .{ project_name, ext })
        else
            try std.fs.path.join(self.allocator, &.{ "bin", project_name });
        defer self.allocator.free(dst_name);

        try std.fs.cwd().copyFile(src_bin, std.fs.cwd(), dst_name, .{});

        // Remove generated zig-out — bin/ now has the only copy
        const generated_zig_out = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, "zig-out" });
        defer self.allocator.free(generated_zig_out);
        std.fs.cwd().deleteTree(generated_zig_out) catch {};

        _ = module_name;
        if (is_lib) {
            std.debug.print("Built: {s}\n", .{dst_name});
        } else {
            std.debug.print("Built: bin/{s}\n", .{project_name});
        }
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

    /// Format Zig test output into clean PASS/FAIL lines
    fn formatTestOutput(self: *ZigRunner, stderr: []const u8, all_passed: bool) !void {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const out = &w.interface;

        var lines = std.mem.splitScalar(u8, stderr, '\n');
        var passed: usize = 0;
        var failed: usize = 0;
        var failed_names = std.ArrayListUnmanaged([]const u8){};
        defer failed_names.deinit(self.allocator);

        // Parse Zig test output lines like:
        // "test\n+- run test 2/2 passed" or "'module.test.name' failed"
        while (lines.next()) |line| {
            // Detect passed tests: "N/M passed"
            if (std.mem.indexOf(u8, line, " passed") != null) {
                if (std.mem.indexOf(u8, line, "/")) |slash_pos| {
                    const before_slash = line[0..slash_pos];
                    var i = before_slash.len;
                    while (i > 0 and before_slash[i - 1] >= '0' and before_slash[i - 1] <= '9') i -= 1;
                    passed = std.fmt.parseInt(usize, before_slash[i..], 10) catch passed;
                }
            }
            // Detect failed test name: "'module.test.NAME' failed"
            if (std.mem.indexOf(u8, line, "' failed:") != null or
                std.mem.indexOf(u8, line, "' failed") != null)
            {
                if (std.mem.indexOf(u8, line, ".test.")) |test_pos| {
                    const name_start = test_pos + 6;
                    const name_end = std.mem.indexOf(u8, line[name_start..], "'") orelse line[name_start..].len;
                    const name = try self.allocator.dupe(u8, line[name_start .. name_start + name_end]);
                    try failed_names.append(self.allocator, name);
                    failed += 1;
                }
            }
        }

        // Print clean results
        if (all_passed) {
            try out.print("  PASS  all tests passed\n", .{});
        } else {
            for (failed_names.items) |name| {
                try out.print("  FAIL  {s}\n", .{name});
                self.allocator.free(name);
            }
            const pass_count = if (passed > failed) passed - failed else 0;
            try out.print("\n{d} passed, {d} failed\n", .{ pass_count, failed });
        }
        try out.flush();
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

    /// Run all test blocks in the generated Zig project
    pub fn runTests(self: *ZigRunner, module_name: []const u8, project_name: []const u8) !bool {
        // Generate build.zig with test step included
        try self.generateBuildZigWithTests(module_name, "exe", project_name);

        var args: std.ArrayListUnmanaged([]const u8) = .{};
        defer args.deinit(self.allocator);
        try args.append(self.allocator, self.zig_path);
        try args.append(self.allocator, "build");
        try args.append(self.allocator, "test");

        var result = try self.runZigIn(args.items, cache.GENERATED_DIR);
        defer result.deinit(self.allocator);

        if (self.show_zig_output) {
            try self.printRaw(result.stdout);
            try self.printRaw(result.stderr);
            return result.success;
        }

        try self.formatTestOutput(result.stderr, result.success);
        return result.success;
    }

    /// Generate the build.zig file for the generated Zig project
    pub fn generateBuildZig(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
    ) !void {
        return self.generateBuildZigWithTests(module_name, build_type, project_name);
    }

    fn generateBuildZigWithTests(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
    ) !void {
        const content = try buildZigContent(self.allocator, module_name, build_type, project_name);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);
    }
};

/// Build the content of build.zig for the given build type.
/// Caller owns the returned slice.
pub fn buildZigContent(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    build_type: []const u8,
    project_name: []const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
    );

    if (std.mem.eql(u8, build_type, "exe")) {
        const exe_chunk = try std.fmt.allocPrint(allocator,
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
        defer allocator.free(exe_chunk);
        try buf.appendSlice(allocator, exe_chunk);
    } else if (std.mem.eql(u8, build_type, "static")) {
        const lib_chunk = try std.fmt.allocPrint(allocator,
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
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);
    } else if (std.mem.eql(u8, build_type, "dynamic")) {
        const lib_chunk = try std.fmt.allocPrint(allocator,
            \\    const lib = b.addLibrary(.{{
            \\        .name = "{s}",
            \\        .linkage = .dynamic,
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("{s}.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\    b.installArtifact(lib);
            \\
        , .{ project_name, module_name });
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);
    }

    // Always include test step so `kodr test` works
    const test_chunk = try std.fmt.allocPrint(allocator,
        \\    const unit_tests = b.addTest(.{{
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("{s}.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\    const run_tests = b.addRunArtifact(unit_tests);
        \\    const test_step = b.step("test", "Run tests");
        \\    test_step.dependOn(&run_tests.step);
        \\
    , .{module_name});
    defer allocator.free(test_chunk);
    try buf.appendSlice(allocator, test_chunk);

    try buf.appendSlice(allocator,
        \\}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

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
    const alloc = std.testing.allocator;
    const name = zigBinaryName();
    try std.testing.expect(name.len > 0);
    _ = alloc;
}

test "buildZigContent - exe" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "myapp");
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addRunArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"myapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"main.zig\"") != null);
    // test step always present
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - static" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "mylib", "static", "mylib");
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .static") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    // exe-specific fields must NOT appear
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addRunArtifact(exe)") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - dynamic" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "mylib", "dynamic", "mylib");
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - project name in exe artifact" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "calculator");
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"calculator\"") != null);
}
