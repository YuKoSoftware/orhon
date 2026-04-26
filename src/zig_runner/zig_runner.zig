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
pub const ZigDep = _zig_runner_multi.ZigDep;
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
    /// Per-module source maps: module_name → sorted SourceMapEntry slice.
    /// Slices are arena-owned by ModuleCompile; ZigRunner does not free them.
    source_maps: std.StringHashMapUnmanaged([]const module.SourceMapEntry) = .{},

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
        self.source_maps.deinit(self.allocator);
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

        // Determine platform-specific artifact extensions from target triple
        const is_windows = std.mem.indexOf(u8, target, "windows") != null;
        const exe_ext: []const u8 = if (is_windows) ".exe" else "";
        const static_ext: []const u8 = if (is_windows) ".lib" else ".a";
        const dynamic_ext: []const u8 = if (is_windows) ".dll" else ".so";
        const lib_prefix: []const u8 = if (is_windows) "" else "lib";

        // Copy all artifacts to bin/
        try std.fs.cwd().makePath("bin");

        for (targets) |t| {
            const is_lib = t.build_type != .exe;
            const ext: []const u8 = if (t.build_type == .dynamic) dynamic_ext else static_ext;

            const src_bin = if (is_lib)
                try std.fmt.allocPrint(self.allocator, "{s}/zig-out/lib/{s}{s}{s}", .{ cache.GENERATED_DIR, lib_prefix, t.project_name, ext })
            else
                try std.fmt.allocPrint(self.allocator, "{s}/zig-out/bin/{s}{s}", .{ cache.GENERATED_DIR, t.project_name, exe_ext });
            defer self.allocator.free(src_bin);

            const dst_name = if (is_lib)
                try std.fmt.allocPrint(self.allocator, "bin/{s}{s}{s}", .{ lib_prefix, t.project_name, ext })
            else
                try std.fmt.allocPrint(self.allocator, "bin/{s}{s}", .{ t.project_name, exe_ext });
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
    fn printRaw(_: *ZigRunner, output: []const u8) !void {
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

    /// Parse a Zig error line ("path:line:col: …") and return the mapped .orh SourceLoc.
    /// Returns null if the path is not in source_maps or has no entry ≤ zig_line.
    fn mapZigLine(self: *const ZigRunner, line: []const u8) ?errors.SourceLoc {
        const first_colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const path = line[0..first_colon];
        const after_path = line[first_colon + 1..];
        const second_colon = std.mem.indexOfScalar(u8, after_path, ':') orelse return null;
        const zig_line = std.fmt.parseInt(u32, after_path[0..second_colon], 10) catch return null;
        const module_name = std.fs.path.stem(std.fs.path.basename(path));
        const entries = self.source_maps.get(module_name) orelse return null;
        const entry = floorEntry(entries, zig_line) orelse return null;
        return errors.SourceLoc{ .file = entry.orh_file, .line = entry.orh_line, .col = 1 };
    }

    /// Parse Zig compiler errors and reformat as Orhon errors.
    /// For errors in generated modules, maps zig_line → orh_file:orh_line via source_maps.
    /// Falls through to generic internal error for paths not in source_maps.
    fn reformatZigErrors(self: *ZigRunner, stderr: []const u8) !void {
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (std.mem.indexOf(u8, line, ": error:")) |marker_pos| {
                const loc = self.mapZigLine(line);
                if (loc != null) {
                    const msg_text = std.mem.trimLeft(u8, line[marker_pos + 8..], " ");
                    _ = try self.reporter.reportFmt(.zig_compile_error, loc, "{s}", .{msg_text});
                    continue;
                }
                // Not a mapped module — existing fallback behaviour
                if (self.reformatNoMember(line)) |msg| {
                    _ = try self.reporter.reportOwned(.{ .code = .zig_compile_error, .message = msg });
                    continue;
                }
                _ = try self.reporter.reportFmt(.internal_zig_codegen, null, "internal codegen error (please report): {s}", .{line});
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
    pub fn runTests(self: *ZigRunner, module_name: []const u8, project_name: []const u8, shared_modules: []const []const u8, zig_modules: []const []const u8, zig_deps: []const ZigDep) !bool {
        // Generate build.zig with test step included
        try self.generateBuildZig(module_name, .exe, project_name, null, &.{}, shared_modules, &.{}, &.{}, false, zig_modules, &.{}, zig_deps);

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
        zig_deps: []const ZigDep,
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
            .zig_deps = zig_deps,
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

/// Floor binary search: return the entry with the largest zig_line ≤ query.
/// Assumes entries are sorted ascending by zig_line (guaranteed by emission order).
fn floorEntry(entries: []const module.SourceMapEntry, zig_line: u32) ?module.SourceMapEntry {
    if (entries.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].zig_line <= zig_line) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    if (entries[lo].zig_line <= zig_line) return entries[lo];
    return null;
}

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

test "floorEntry returns null for empty slice" {
    const entries: []const module.SourceMapEntry = &.{};
    try std.testing.expect(floorEntry(entries, 42) == null);
}

test "floorEntry returns null when zig_line before first entry" {
    const entries = [_]module.SourceMapEntry{
        .{ .zig_line = 10, .orh_file = "a.orh", .orh_line = 5 },
    };
    try std.testing.expect(floorEntry(&entries, 5) == null);
}

test "floorEntry returns exact match" {
    const entries = [_]module.SourceMapEntry{
        .{ .zig_line = 10, .orh_file = "a.orh", .orh_line = 5 },
    };
    const result = floorEntry(&entries, 10).?;
    try std.testing.expectEqual(@as(u32, 10), result.zig_line);
    try std.testing.expectEqualStrings("a.orh", result.orh_file);
}

test "floorEntry returns entry below zig_line" {
    const entries = [_]module.SourceMapEntry{
        .{ .zig_line = 5,  .orh_file = "a.orh", .orh_line = 1 },
        .{ .zig_line = 10, .orh_file = "a.orh", .orh_line = 5 },
        .{ .zig_line = 20, .orh_file = "a.orh", .orh_line = 10 },
    };
    const result = floorEntry(&entries, 15).?;
    try std.testing.expectEqual(@as(u32, 10), result.zig_line);
    try std.testing.expectEqual(@as(u32, 5), result.orh_line);
}

test "floorEntry returns last entry when zig_line past all entries" {
    const entries = [_]module.SourceMapEntry{
        .{ .zig_line = 5,  .orh_file = "a.orh", .orh_line = 1 },
        .{ .zig_line = 10, .orh_file = "a.orh", .orh_line = 5 },
    };
    const result = floorEntry(&entries, 999).?;
    try std.testing.expectEqual(@as(u32, 10), result.zig_line);
}
