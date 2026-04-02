// zig_runner.zig — Zig Compiler Runner pass (pass 12)
// Invokes the Zig compiler on generated .zig files.
// Captures stdout/stderr — never shown to user unless -zig flag is set.
// Re-export hub — satellite files contain build/multi/discovery implementations.

const std = @import("std");
const errors = @import("../errors.zig");
const cache = @import("../cache.zig");
const module = @import("../module.zig");

const _zig_runner_build = @import("zig_runner_build.zig");
const _zig_runner_multi = @import("zig_runner_multi.zig");
const _zig_runner_discovery = @import("zig_runner_discovery.zig");

// Re-exports for backward compatibility with pipeline.zig and other callers
pub const MultiTarget = _zig_runner_multi.MultiTarget;
pub const buildZigContentMulti = _zig_runner_multi.buildZigContentMulti;
pub const findZig = _zig_runner_discovery.findZig;
pub const generateSharedCImportFiles = _zig_runner_build.generateSharedCImportFiles;

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
        const zig_path = try _zig_runner_discovery.findZig(allocator);
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

    /// Build all targets in a multi-target project with a single zig build invocation.
    /// Generates a unified build.zig, runs zig build once, copies all artifacts to bin/.
    pub fn buildAll(
        self: *ZigRunner,
        target: []const u8,
        optimize: []const u8,
        targets: []const MultiTarget,
        extra_zig_modules: []const []const u8,
    ) !bool {
        // Generate unified build.zig
        const content = try _zig_runner_multi.buildZigContentMulti(self.allocator, targets, extra_zig_modules);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

        // Generate shared @cImport wrapper files for all unique #cInclude headers.
        // Each shared file is named _{stem}_c.zig and exposes:
        //   pub const c = @cImport({ @cInclude("header.h"); });
        //   pub usingnamespace c;
        try _zig_runner_build.generateSharedCImportFiles(self.allocator, targets);

        // Run zig build once
        var args: std.ArrayListUnmanaged([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, self.zig_path);
        try args.append(self.allocator, "build");

        var target_flag_alloc: ?[]const u8 = null;
        if (target.len > 0) {
            target_flag_alloc = try std.fmt.allocPrint(self.allocator, "-Dtarget={s}", .{target});
            try args.append(self.allocator, target_flag_alloc.?);
        }
        defer if (target_flag_alloc) |tf| self.allocator.free(tf);

        if (std.mem.eql(u8, optimize, "fast")) {
            try args.append(self.allocator, "-Doptimize=ReleaseFast");
        } else if (std.mem.eql(u8, optimize, "small")) {
            try args.append(self.allocator, "-Doptimize=ReleaseSmall");
        }

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

        // Copy all artifacts to bin/
        try std.fs.cwd().makePath("bin");

        for (targets) |t| {
            const is_lib = t.build_type != .exe;
            const ext: []const u8 = if (t.build_type == .dynamic) ".so" else ".a";

            const src_bin = if (is_lib)
                try std.fmt.allocPrint(self.allocator, "{s}/zig-out/lib/lib{s}{s}", .{ cache.GENERATED_DIR, t.project_name, ext })
            else
                try std.fs.path.join(self.allocator, &.{ cache.GENERATED_DIR, "zig-out", "bin", t.project_name });
            defer self.allocator.free(src_bin);

            const dst_name = if (is_lib)
                try std.fmt.allocPrint(self.allocator, "bin/lib{s}{s}", .{ t.project_name, ext })
            else
                try std.fs.path.join(self.allocator, &.{ "bin", t.project_name });
            defer self.allocator.free(dst_name);

            try std.fs.cwd().copyFile(src_bin, std.fs.cwd(), dst_name, .{});

            std.debug.print("Built: {s}\n", .{dst_name});
        }

        // Clean up generated zig-out and zig-cache
        const generated_zig_out = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, "zig-out" });
        defer self.allocator.free(generated_zig_out);
        std.fs.cwd().deleteTree(generated_zig_out) catch {};

        const generated_zig_cache = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, ".zig-cache" });
        defer self.allocator.free(generated_zig_cache);
        std.fs.cwd().deleteTree(generated_zig_cache) catch {};

        std.fs.cwd().deleteTree("zig-cache") catch {};
        std.fs.cwd().deleteTree(".zig-cache") catch {};

        return true;
    }

    /// Build the generated Zig project
    pub fn build(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8) !bool {
        return self.buildWithType(target, optimize, module_name, project_name, .exe);
    }

    pub fn buildLib(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8, build_type: module.BuildType) !bool {
        return self.buildWithType(target, optimize, module_name, project_name, build_type);
    }

    fn buildWithType(self: *ZigRunner, target: []const u8, optimize: []const u8, module_name: []const u8, project_name: []const u8, build_type: module.BuildType) !bool {
        var args: std.ArrayListUnmanaged([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, self.zig_path);
        try args.append(self.allocator, "build");

        var target_flag_alloc: ?[]const u8 = null;
        if (target.len > 0) {
            target_flag_alloc = try std.fmt.allocPrint(self.allocator, "-Dtarget={s}", .{target});
            try args.append(self.allocator, target_flag_alloc.?);
        }
        defer if (target_flag_alloc) |tf| self.allocator.free(tf);

        if (std.mem.eql(u8, optimize, "fast")) {
            try args.append(self.allocator, "-Doptimize=ReleaseFast");
        } else if (std.mem.eql(u8, optimize, "small")) {
            try args.append(self.allocator, "-Doptimize=ReleaseSmall");
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
        const is_lib = build_type != .exe;
        const ext: []const u8 = if (build_type == .dynamic) ".so" else ".a";

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

        // Remove generated zig-out and zig-cache — bin/ now has the only copy
        const generated_zig_out = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, "zig-out" });
        defer self.allocator.free(generated_zig_out);
        std.fs.cwd().deleteTree(generated_zig_out) catch {};

        const generated_zig_cache = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, ".zig-cache" });
        defer self.allocator.free(generated_zig_cache);
        std.fs.cwd().deleteTree(generated_zig_cache) catch {};

        std.fs.cwd().deleteTree("zig-cache") catch {};
        std.fs.cwd().deleteTree(".zig-cache") catch {};

        _ = module_name;
        if (is_lib) {
            std.debug.print("Built: {s}\n", .{dst_name});
        } else {
            std.debug.print("Built: bin/{s}\n", .{project_name});
        }
        return true;
    }

    /// Run Zig from a specific working directory and capture output
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

    /// Format Zig test output into clean PASS/FAIL lines, writing to stderr.
    fn formatTestOutput(self: *ZigRunner, stderr: []const u8, all_passed: bool) !void {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const out = &w.interface;
        try writeTestOutput(self.allocator, stderr, all_passed, out);
        try out.flush();
    }

    /// Parse Zig compiler errors and reformat as Orhon errors
    /// This should ideally never trigger in a correct compiler implementation
    fn reformatZigErrors(self: *ZigRunner, stderr: []const u8) !void {
        // Zig errors look like: path/to/file.zig:line:col: error: message
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Try to parse Zig error format
            if (std.mem.indexOf(u8, line, ": error:")) |_| {
                // "has no member named 'X'" → module has no function 'X'
                if (self.reformatNoMember(line)) |msg| {
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg });
                    continue;
                }
                try self.reporter.reportFmt(null, "internal codegen error (please report): {s}", .{line});
            }
        }
    }

    /// Try to reformat "has no member named 'X'" into a user-friendly message
    fn reformatNoMember(self: *ZigRunner, line: []const u8) ?[]const u8 {
        // Pattern: "struct 'module_name' has no member named 'func_name'"
        const marker = "has no member named '";
        const struct_marker = "struct '";
        const idx = std.mem.indexOf(u8, line, marker) orelse return null;
        const func_start = idx + marker.len;
        const func_end = std.mem.indexOfPos(u8, line, func_start, "'") orelse return null;
        const func_name = line[func_start..func_end];

        // Extract module name from "struct 'name'"
        const struct_idx = std.mem.indexOf(u8, line, struct_marker) orelse return null;
        const mod_start = struct_idx + struct_marker.len;
        const mod_end = std.mem.indexOfPos(u8, line, mod_start, "'") orelse return null;
        const mod_name = line[mod_start..mod_end];

        return std.fmt.allocPrint(self.allocator,
            "module '{s}' has no function '{s}'", .{ mod_name, func_name }) catch null;
    }

    /// Run all test blocks in the generated Zig project
    pub fn runTests(self: *ZigRunner, module_name: []const u8, project_name: []const u8, zig_modules: []const []const u8) !bool {
        // Generate build.zig with test step included
        try self.generateBuildZig(module_name, .exe, project_name, null, &.{}, &.{}, &.{}, &.{}, false, zig_modules, &.{});

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

    /// Generate the build.zig file for a single-target project.
    /// Constructs a MultiTarget and routes through the unified multi-target path.
    pub fn generateBuildZig(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: module.BuildType,
        project_name: []const u8,
        project_version: ?[3]u64,
        link_libs: []const []const u8,
        shared_modules: []const []const u8,
        c_includes: []const []const u8,
        c_source_files: []const []const u8,
        needs_cpp: bool,
        zig_modules: []const []const u8,
        include_dirs: []const []const u8,
    ) !void {
        const target = MultiTarget{
            .module_name = module_name,
            .project_name = project_name,
            .build_type = build_type,
            .lib_imports = &.{},
            .mod_imports = shared_modules,
            .version = project_version,
            .link_libs = link_libs,
            .c_includes = c_includes,
            .c_source_files = c_source_files,
            .needs_cpp = needs_cpp,
            .include_dirs = include_dirs,
        };
        const targets = [1]MultiTarget{target};
        const content = try _zig_runner_multi.buildZigContentMulti(self.allocator, &targets, zig_modules);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

        // Generate shared @cImport wrapper files on disk
        if (c_includes.len > 0) {
            try _zig_runner_build.generateSharedCImportFiles(self.allocator, &targets);
        }
    }
};

/// Parse Zig test output and write clean PASS/FAIL lines to the given writer.
/// Extracted for testability — formatTestOutput calls this with a stderr writer.
fn writeTestOutput(allocator: std.mem.Allocator, stderr: []const u8, all_passed: bool, out: anytype) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var passed: usize = 0;
    var failed: usize = 0;
    var failed_names = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (failed_names.items) |name| allocator.free(name);
        failed_names.deinit(allocator);
    }

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
                const name = try allocator.dupe(u8, line[name_start .. name_start + name_end]);
                try failed_names.append(allocator, name);
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
        }
        const pass_count = if (passed > failed) passed - failed else 0;
        try out.print("\n{d} passed, {d} failed\n", .{ pass_count, failed });
    }
}

test "formatTestOutput - all passed prints all tests passed" {
    const alloc = std.testing.allocator;
    var out_buf = std.ArrayListUnmanaged(u8){};
    defer out_buf.deinit(alloc);

    try writeTestOutput(alloc, "", true, out_buf.writer(alloc));

    const output = out_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "all tests passed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "FAIL") == null);
}

test "formatTestOutput - failure reports FAIL and counts" {
    const alloc = std.testing.allocator;
    var out_buf = std.ArrayListUnmanaged(u8){};
    defer out_buf.deinit(alloc);

    const sample_stderr =
        \\test
        \\+- run test 1/2 passed, 1 failed
        \\error: 'main.test.wrong' failed: TestUnexpectedResult
    ;

    try writeTestOutput(alloc, sample_stderr, false, out_buf.writer(alloc));

    const output = out_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "FAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "wrong") != null);
}
