// zig_runner.zig — Zig Compiler Runner pass (pass 12)
// Invokes the Zig compiler on generated .zig files.
// Captures stdout/stderr — never shown to user unless -zig flag is set.
// Finds Zig binary in: 1) same dir as orhon binary, 2) PATH

const std = @import("std");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const module = @import("module.zig");

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

    /// Build all targets in a multi-target project with a single zig build invocation.
    /// Generates a unified build.zig, runs zig build once, copies all artifacts to bin/.
    pub fn buildAll(
        self: *ZigRunner,
        target: []const u8,
        optimize: []const u8,
        targets: []const MultiTarget,
        extra_bridge_modules: []const []const u8,
    ) !bool {
        // Generate unified build.zig
        const content = try buildZigContentMulti(self.allocator, targets, extra_bridge_modules);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

        // Generate shared @cImport wrapper files for all unique #cInclude headers.
        // Each shared file is named _{stem}_c.zig and exposes:
        //   pub const c = @cImport({ @cInclude("header.h"); });
        //   pub usingnamespace c;
        try generateSharedCImportFiles(self.allocator, targets);

        // Run zig build once
        var args: std.ArrayListUnmanaged([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, self.zig_path);
        try args.append(self.allocator, "build");

        if (target.len > 0) {
            const target_flag = try std.fmt.allocPrint(self.allocator, "-Dtarget={s}", .{target});
            defer self.allocator.free(target_flag);
            try args.append(self.allocator, target_flag);
        }

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
            const is_lib = !std.mem.eql(u8, t.build_type, "exe");
            const ext: []const u8 = if (std.mem.eql(u8, t.build_type, "dynamic")) ".so" else ".a";

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

        // Clean up generated zig-out
        const generated_zig_out = try std.fs.path.join(self.allocator,
            &.{ cache.GENERATED_DIR, "zig-out" });
        defer self.allocator.free(generated_zig_out);
        std.fs.cwd().deleteTree(generated_zig_out) catch {};

        return true;
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
                const msg = try std.fmt.allocPrint(self.allocator,
                    "internal codegen error (please report): {s}", .{line});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
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
    pub fn runTests(self: *ZigRunner, module_name: []const u8, project_name: []const u8, bridge_modules: []const []const u8) !bool {
        // Generate build.zig with test step included
        try self.generateBuildZigWithTests(module_name, "exe", project_name, null, &.{}, bridge_modules, &.{}, &.{}, &.{}, false);

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
        project_version: ?[3]u64,
        link_libs: []const []const u8,
        bridge_modules: []const []const u8,
        shared_modules: []const []const u8,
        c_includes: []const []const u8,
        c_source_files: []const []const u8,
        needs_cpp: bool,
    ) !void {
        return self.generateBuildZigWithTests(module_name, build_type, project_name, project_version, link_libs, bridge_modules, shared_modules, c_includes, c_source_files, needs_cpp);
    }

    fn generateBuildZigWithTests(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
        project_version: ?[3]u64,
        link_libs: []const []const u8,
        bridge_modules: []const []const u8,
        shared_modules: []const []const u8,
        c_includes: []const []const u8,
        c_source_files: []const []const u8,
        needs_cpp: bool,
    ) !void {
        const content = try buildZigContent(self.allocator, module_name, build_type, project_name, project_version, link_libs, bridge_modules, shared_modules, c_includes, c_source_files, needs_cpp);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

        // Generate shared @cImport wrapper files on disk (same as multi-target path)
        if (c_includes.len > 0) {
            const synthetic = [1]MultiTarget{.{
                .module_name = module_name,
                .project_name = module_name,
                .build_type = build_type,
                .lib_imports = &.{},
                .c_includes = c_includes,
                .c_source_files = c_source_files,
                .needs_cpp = needs_cpp,
            }};
            try generateSharedCImportFiles(self.allocator, &synthetic);
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

/// Build the content of build.zig for the given build type.
/// Caller owns the returned slice.
pub fn buildZigContent(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    build_type: []const u8,
    project_name: []const u8,
    project_version: ?[3]u64,
    link_libs: []const []const u8,
    bridge_modules: []const []const u8,
    shared_modules: []const []const u8,
    c_includes: []const []const u8,
    c_source_files: []const []const u8,
    needs_cpp: bool,
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
        \\    // Orhon internal modules — shared across all targets
        \\    const str_mod = b.createModule(.{
        \\        .root_source_file = b.path("_orhon_str.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const coll_mod = b.createModule(.{
        \\        .root_source_file = b.path("_orhon_collections.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
    );

    // Create named bridge modules for all modules that have bridge declarations
    for (bridge_modules) |bmod_name| {
        const bridge_chunk = try std.fmt.allocPrint(allocator,
            \\    const bridge_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("{s}_bridge.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
        , .{ bmod_name, bmod_name });
        defer allocator.free(bridge_chunk);
        try buf.appendSlice(allocator, bridge_chunk);
    }

    // #cimport is applied to the artifact (lib/exe), not the bridge module.
    // Build.Module doesn't have linkSystemLibrary/linkLibC — only Step.Compile does.

    // Shared @cImport module generation — one module per unique #cimport header.
    // Same logic as buildZigContentMulti so single-target projects get proper type identity.
    var seen_cimport = std.StringHashMapUnmanaged(void){};
    defer seen_cimport.deinit(allocator);
    for (c_includes) |hdr| {
        if (seen_cimport.contains(hdr)) continue;
        try seen_cimport.put(allocator, hdr, {});
        const base = std.fs.path.basename(hdr);
        const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
            base[0..dot]
        else
            base;
        var stem_buf: [64]u8 = undefined;
        const stem_len = @min(stem.len, 63);
        for (0..stem_len) |i| {
            stem_buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
        }
        const safe_stem = stem_buf[0..stem_len];
        const cimport_chunk = try std.fmt.allocPrint(allocator,
            \\    const cimport_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("_{s}_c.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
        , .{ safe_stem, safe_stem });
        defer allocator.free(cimport_chunk);
        try buf.appendSlice(allocator, cimport_chunk);
    }

    // Wire shared @cImport modules into all bridge modules that use them
    for (bridge_modules) |bmod_name| {
        for (c_includes) |hdr| {
            const base = std.fs.path.basename(hdr);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
                base[0..dot]
            else
                base;
            var stem_buf: [64]u8 = undefined;
            const stem_len = @min(stem.len, 63);
            for (0..stem_len) |i| {
                stem_buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
            }
            const safe_stem = stem_buf[0..stem_len];
            const wire_chunk = try std.fmt.allocPrint(allocator,
                \\    bridge_{s}.addImport("{s}_c", cimport_{s});
                \\
            , .{ bmod_name, safe_stem, safe_stem });
            defer allocator.free(wire_chunk);
            try buf.appendSlice(allocator, wire_chunk);
        }
    }

    // For bridge modules that are NOT already in shared_modules (i.e. they are
    // transitive imports — e.g. tester imports allocator, but root only imports tester),
    // we still need a named module so @import("allocator") resolves inside tester.zig.
    // Create mod_{name} for each such bridge module, wire its bridge sidecar into it.
    for (bridge_modules) |bmod_name| {
        // Skip if already covered by shared_modules — it gets its mod_ created there
        var already_shared = false;
        for (shared_modules) |smod_name| {
            if (std.mem.eql(u8, smod_name, bmod_name)) {
                already_shared = true;
                break;
            }
        }
        if (already_shared) continue;

        const extra_mod_chunk = try std.fmt.allocPrint(allocator,
            \\    const mod_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("{s}.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    mod_{s}.addImport("_orhon_str", str_mod);
            \\    mod_{s}.addImport("_orhon_collections", coll_mod);
            \\    mod_{s}.addImport("{s}_bridge", bridge_{s});
            \\
        , .{ bmod_name, bmod_name, bmod_name, bmod_name, bmod_name, bmod_name, bmod_name });
        defer allocator.free(extra_mod_chunk);
        try buf.appendSlice(allocator, extra_mod_chunk);
    }

    // Shared module creation — non-root, non-lib modules that are imported
    // by the root. Named modules prevent "file exists in two modules" in
    // multi-target builds and ensure @import("mod") resolves correctly.
    for (shared_modules) |smod_name| {
        const smod_chunk = try std.fmt.allocPrint(allocator,
            \\    const mod_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("{s}.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    mod_{s}.addImport("_orhon_str", str_mod);
            \\    mod_{s}.addImport("_orhon_collections", coll_mod);
            \\
        , .{ smod_name, smod_name, smod_name, smod_name });
        defer allocator.free(smod_chunk);
        try buf.appendSlice(allocator, smod_chunk);

        // Wire bridge and named module imports into this shared module.
        // This covers two cases:
        //   1. The shared module IS a bridge module itself (e.g. console) — wire its own bridge
        //   2. The shared module imports OTHER bridge modules (e.g. tester imports allocator)
        // All bridge modules are wired to all shared modules. Unused imports are harmless in Zig.
        for (bridge_modules) |bmod_name| {
            if (std.mem.eql(u8, bmod_name, smod_name)) {
                // This shared module has its own bridge — wire bridge only (mod_ = this module itself)
                const smod_own_bridge = try std.fmt.allocPrint(allocator,
                    \\    mod_{s}.addImport("{s}_bridge", bridge_{s});
                    \\
                , .{ smod_name, bmod_name, bmod_name });
                defer allocator.free(smod_own_bridge);
                try buf.appendSlice(allocator, smod_own_bridge);
            } else {
                // Wire the bridge-backed named module so @import("{name}") resolves
                const smod_bmod_key = try std.fmt.allocPrint(allocator,
                    "    mod_{s}.addImport(\"{s}\", mod_{s});\n",
                    .{ smod_name, bmod_name, bmod_name });
                defer allocator.free(smod_bmod_key);
                try buf.appendSlice(allocator, smod_bmod_key);
            }
        }
    }

    if (std.mem.eql(u8, build_type, "exe")) {
        // Version line for addExecutable
        var ver_buf: [128]u8 = undefined;
        const ver_line: []const u8 = if (project_version) |v|
            std.fmt.bufPrint(&ver_buf, "\n        .version = .{{ .major = {d}, .minor = {d}, .patch = {d} }},", .{ v[0], v[1], v[2] }) catch ""
        else
            "";

        const exe_chunk = try std.fmt.allocPrint(allocator,
            \\    const exe = b.addExecutable(.{{
            \\        .name = "{s}",{s}
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("{s}.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\    exe.root_module.addImport("_orhon_str", str_mod);
            \\    exe.root_module.addImport("_orhon_collections", coll_mod);
            \\    b.installArtifact(exe);
            \\
            \\    const run_cmd = b.addRunArtifact(exe);
            \\    run_cmd.step.dependOn(b.getInstallStep());
            \\    const run_step = b.step("run", "Run");
            \\    run_step.dependOn(&run_cmd.step);
            \\
        , .{ project_name, ver_line, module_name });
        defer allocator.free(exe_chunk);
        try buf.appendSlice(allocator, exe_chunk);

        for (bridge_modules) |bmod_name| {
            const bridge_import = try std.fmt.allocPrint(allocator,
                \\    exe.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ bmod_name, bmod_name });
            defer allocator.free(bridge_import);
            try buf.appendSlice(allocator, bridge_import);
        }

        // Wire extra bridge-backed named modules (transitive bridge deps) into the root
        for (bridge_modules) |bmod_name| {
            var already_shared = false;
            for (shared_modules) |smod_name| {
                if (std.mem.eql(u8, smod_name, bmod_name)) {
                    already_shared = true;
                    break;
                }
            }
            if (already_shared) continue;
            const extra_import = try std.fmt.allocPrint(allocator,
                "    exe.root_module.addImport(\"{s}\", mod_{s});\n",
                .{ bmod_name, bmod_name });
            defer allocator.free(extra_import);
            try buf.appendSlice(allocator, extra_import);
        }

        for (shared_modules) |smod_name| {
            const smod_import = try std.fmt.allocPrint(allocator,
                \\    exe.root_module.addImport("{s}", mod_{s});
                \\
            , .{ smod_name, smod_name });
            defer allocator.free(smod_import);
            try buf.appendSlice(allocator, smod_import);
        }

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
            \\    lib.root_module.addImport("_orhon_str", str_mod);
            \\    lib.root_module.addImport("_orhon_collections", coll_mod);
            \\    b.installArtifact(lib);
            \\
        , .{ project_name, module_name });
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);

        for (bridge_modules) |bmod_name| {
            const bridge_import = try std.fmt.allocPrint(allocator,
                \\    lib.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ bmod_name, bmod_name });
            defer allocator.free(bridge_import);
            try buf.appendSlice(allocator, bridge_import);
        }

        for (shared_modules) |smod_name| {
            const smod_import = try std.fmt.allocPrint(allocator,
                \\    lib.root_module.addImport("{s}", mod_{s});
                \\
            , .{ smod_name, smod_name });
            defer allocator.free(smod_import);
            try buf.appendSlice(allocator, smod_import);
        }

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
            \\    lib.root_module.addImport("_orhon_str", str_mod);
            \\    lib.root_module.addImport("_orhon_collections", coll_mod);
            \\    b.installArtifact(lib);
            \\
        , .{ project_name, module_name });
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);

        for (bridge_modules) |bmod_name| {
            const bridge_import = try std.fmt.allocPrint(allocator,
                \\    lib.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ bmod_name, bmod_name });
            defer allocator.free(bridge_import);
            try buf.appendSlice(allocator, bridge_import);
        }

        for (shared_modules) |smod_name| {
            const smod_import = try std.fmt.allocPrint(allocator,
                \\    lib.root_module.addImport("{s}", mod_{s});
                \\
            , .{ smod_name, smod_name });
            defer allocator.free(smod_import);
            try buf.appendSlice(allocator, smod_import);
        }

    }

    // Apply #cimport link libs and C source files to the artifact (lib/exe).
    // linkSystemLibrary/linkLibC/addCSourceFiles/linkLibCpp are on Step.Compile, not Build.Module.
    {
        const artifact_name: []const u8 = if (std.mem.eql(u8, build_type, "exe")) "exe" else "lib";
        try emitLinkLibs(&buf, allocator, link_libs, artifact_name);
        if (c_source_files.len > 0 or needs_cpp) {
            try emitCSourceFiles(&buf, allocator, c_source_files, needs_cpp, artifact_name);
        }
    }

    // Always include test step so `orhon test` works
    const test_chunk = try std.fmt.allocPrint(allocator,
        \\    const unit_tests = b.addTest(.{{
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("{s}.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }}),
        \\    }});
        \\    unit_tests.root_module.addImport("_orhon_str", str_mod);
        \\    unit_tests.root_module.addImport("_orhon_collections", coll_mod);
        \\    const run_tests = b.addRunArtifact(unit_tests);
        \\    const test_step = b.step("test", "Run tests");
        \\    test_step.dependOn(&run_tests.step);
        \\
    , .{module_name});
    defer allocator.free(test_chunk);
    try buf.appendSlice(allocator, test_chunk);

    // Add bridge imports to test target
    for (bridge_modules) |bmod_name| {
        const test_bridge = try std.fmt.allocPrint(allocator,
            \\    unit_tests.root_module.addImport("{s}_bridge", bridge_{s});
            \\
        , .{ bmod_name, bmod_name });
        defer allocator.free(test_bridge);
        try buf.appendSlice(allocator, test_bridge);
    }

    // Wire extra bridge-backed named modules into the test target
    for (bridge_modules) |bmod_name| {
        var already_shared = false;
        for (shared_modules) |smod_name| {
            if (std.mem.eql(u8, smod_name, bmod_name)) {
                already_shared = true;
                break;
            }
        }
        if (already_shared) continue;
        const test_extra = try std.fmt.allocPrint(allocator,
            "    unit_tests.root_module.addImport(\"{s}\", mod_{s});\n",
            .{ bmod_name, bmod_name });
        defer allocator.free(test_extra);
        try buf.appendSlice(allocator, test_extra);
    }

    // Add shared module imports to test target
    for (shared_modules) |smod_name| {
        const test_mod = try std.fmt.allocPrint(allocator,
            \\    unit_tests.root_module.addImport("{s}", mod_{s});
            \\
        , .{ smod_name, smod_name });
        defer allocator.free(test_mod);
        try buf.appendSlice(allocator, test_mod);
    }

    // Link C libraries and C source files for tests too
    try emitLinkLibs(&buf, allocator, link_libs, "unit_tests");
    if (c_source_files.len > 0 or needs_cpp) {
        try emitCSourceFiles(&buf, allocator, c_source_files, needs_cpp, "unit_tests");
    }

    try buf.appendSlice(allocator,
        \\}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

/// Emit linkSystemLibrary + linkLibC calls for a Step.Compile artifact.
fn emitLinkLibs(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    link_libs: []const []const u8,
    artifact_name: []const u8,
) !void {
    if (link_libs.len == 0) return;
    for (link_libs) |lib_name| {
        const chunk = try std.fmt.allocPrint(allocator,
            \\    {s}.linkSystemLibrary("{s}");
            \\
        , .{ artifact_name, lib_name });
        defer allocator.free(chunk);
        try buf.appendSlice(allocator, chunk);
    }
    const libc_chunk = try std.fmt.allocPrint(allocator,
        \\    {s}.linkLibC();
        \\
    , .{artifact_name});
    defer allocator.free(libc_chunk);
    try buf.appendSlice(allocator, libc_chunk);
}

/// Generate shared @cImport wrapper .zig files for all unique #cInclude headers.
/// Each file is written to the generated cache dir as _{stem}_c.zig and exposes:
///   pub const c = @cImport({ @cInclude("header.h"); });
/// Sidecars use: const c = @import("{stem}_c").c;
/// Note: `usingnamespace` was removed from file scope in Zig 0.15; callers access
/// the cImport result via the `.c` field on the imported module.
fn generateSharedCImportFiles(allocator: std.mem.Allocator, targets: []const MultiTarget) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    for (targets) |*t| {
        for (t.c_includes) |hdr| {
            if (seen.contains(hdr)) continue;
            try seen.put(allocator, hdr, {});

            // Derive safe stem from header filename (same logic as in buildZigContentMulti)
            const base = std.fs.path.basename(hdr);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
                base[0..dot]
            else
                base;
            var stem_buf: [64]u8 = undefined;
            const stem_len = @min(stem.len, 63);
            for (0..stem_len) |i| {
                stem_buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
            }
            const safe_stem = stem_buf[0..stem_len];

            // Generate wrapper content.
            // Callers use: const c = @import("{stem}_c").c;
            // `usingnamespace` was removed from file scope in Zig 0.15 — callers must
            // access the cImport result via the `.c` field on the imported module.
            const wrapper_content = try std.fmt.allocPrint(allocator,
                \\// Shared @cImport wrapper for {s}
                \\// Auto-generated by orhon compiler — do not edit.
                \\// Usage in sidecars: const c = @import("{s}_c").c;
                \\pub const c = @cImport({{
                \\    @cInclude("{s}");
                \\}});
                \\
            , .{ hdr, safe_stem, hdr });
            defer allocator.free(wrapper_content);

            // Write to cache as _{stem}_c.zig
            const file_stem = try std.fmt.allocPrint(allocator, "_{s}_c", .{safe_stem});
            defer allocator.free(file_stem);
            try cache.writeGeneratedZig(file_stem, wrapper_content, allocator);
        }
    }
}

/// Emit addCSourceFiles + linkLibCpp calls for a Step.Compile artifact.
fn emitCSourceFiles(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    c_source_files: []const []const u8,
    needs_cpp: bool,
    artifact_name: []const u8,
) !void {
    if (c_source_files.len == 0 and !needs_cpp) return;

    var has_cpp = needs_cpp;
    for (c_source_files) |src_file| {
        // Determine flags: .cpp/.cc files get -std=c++17
        const is_cpp = std.mem.endsWith(u8, src_file, ".cpp") or std.mem.endsWith(u8, src_file, ".cc");
        if (is_cpp) has_cpp = true;
        const flags = if (is_cpp) "\"-std=c++17\"" else "";
        if (is_cpp) {
            const chunk = try std.fmt.allocPrint(allocator,
                \\    {s}.root_module.addCSourceFiles(.{{
                \\        .files = &.{{"{s}"}},
                \\        .flags = &.{{{s}}},
                \\    }});
                \\
            , .{ artifact_name, src_file, flags });
            defer allocator.free(chunk);
            try buf.appendSlice(allocator, chunk);
        } else {
            const chunk = try std.fmt.allocPrint(allocator,
                \\    {s}.root_module.addCSourceFiles(.{{
                \\        .files = &.{{"{s}"}},
                \\        .flags = &.{{}},
                \\    }});
                \\
            , .{ artifact_name, src_file });
            defer allocator.free(chunk);
            try buf.appendSlice(allocator, chunk);
        }
    }

    if (has_cpp) {
        const chunk = try std.fmt.allocPrint(allocator,
            \\    {s}.linkLibCpp();
            \\
        , .{artifact_name});
        defer allocator.free(chunk);
        try buf.appendSlice(allocator, chunk);
    }
}

/// Descriptor for a build target in a multi-target project
pub const MultiTarget = struct {
    module_name: []const u8,
    project_name: []const u8,
    build_type: []const u8, // "exe", "static", "dynamic"
    lib_imports: []const []const u8, // names of imported lib modules (for linking)
    mod_imports: []const []const u8 = &.{}, // names of non-lib imported modules (for named module refs)
    version: ?[3]u64 = null,
    link_libs: []const []const u8 = &.{}, // C libraries from #linkC metadata
    c_includes: []const []const u8 = &.{}, // C headers from #cInclude metadata (for shared @cImport module)
    c_source_files: []const []const u8 = &.{}, // C/C++ source files from #csource metadata
    needs_cpp: bool = false, // true when #linkCpp is present or any .cpp/.cc source files
    has_bridges: bool = false, // module has bridge declarations needing named Zig modules
};

/// Build a unified build.zig for multiple targets.
/// Libs are defined first, then exes link against them via addImport + linkLibrary.
pub fn buildZigContentMulti(
    allocator: std.mem.Allocator,
    targets: []const MultiTarget,
    extra_bridge_modules: []const []const u8,
) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    // Preamble
    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    // Orhon internal modules — shared across all targets
        \\    const str_mod = b.createModule(.{
        \\        .root_source_file = b.path("_orhon_str.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\    const coll_mod = b.createModule(.{
        \\        .root_source_file = b.path("_orhon_collections.zig"),
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
    );

    // Build a map from module_name → project_name for lib targets (used by exe linking)
    var lib_targets = std.StringHashMapUnmanaged([]const u8){};
    defer lib_targets.deinit(allocator);

    // Collect all lib targets for topological sort
    var all_lib_targets = std.ArrayListUnmanaged(*const MultiTarget){};
    defer all_lib_targets.deinit(allocator);
    for (targets) |*t| {
        if (!std.mem.eql(u8, t.build_type, "exe")) {
            try all_lib_targets.append(allocator, t);
            try lib_targets.put(allocator, t.module_name, t.project_name);
        }
    }

    // Topological sort: emit libs whose lib_imports are all already emitted.
    // Iteratively move "ready" libs (all deps emitted) to sorted output.
    var sorted_libs = std.ArrayListUnmanaged(*const MultiTarget){};
    defer sorted_libs.deinit(allocator);
    var emitted_libs = std.StringHashMapUnmanaged(void){};
    defer emitted_libs.deinit(allocator);

    var remaining = all_lib_targets.items.len;
    while (remaining > 0) {
        const before = sorted_libs.items.len;
        for (all_lib_targets.items) |t| {
            if (emitted_libs.contains(t.module_name)) continue;
            // Check if all lib_imports for this lib have been emitted
            var deps_ready = true;
            for (t.lib_imports) |dep_name| {
                if (lib_targets.contains(dep_name) and !emitted_libs.contains(dep_name)) {
                    deps_ready = false;
                    break;
                }
            }
            if (deps_ready) {
                try sorted_libs.append(allocator, t);
                try emitted_libs.put(allocator, t.module_name, {});
            }
        }
        const after = sorted_libs.items.len;
        // If no progress in a full pass, there is a circular lib dependency — emit remainder as-is
        if (after == before) {
            for (all_lib_targets.items) |t| {
                if (!emitted_libs.contains(t.module_name)) {
                    try sorted_libs.append(allocator, t);
                    try emitted_libs.put(allocator, t.module_name, {});
                }
            }
            break;
        }
        remaining = all_lib_targets.items.len - sorted_libs.items.len;
    }

    // Build a lookup: module_name → has_bridges for quick access
    var bridge_set = std.StringHashMapUnmanaged(void){};
    defer bridge_set.deinit(allocator);
    for (targets) |*t| {
        if (t.has_bridges) {
            try bridge_set.put(allocator, t.module_name, {});
        }
    }
    // Include non-root modules that have bridges (not represented as targets)
    for (extra_bridge_modules) |bmod_name| {
        try bridge_set.put(allocator, bmod_name, {});
    }

    // Bridge module creation — register bridge .zig files as named Zig modules
    // so that @import("module_bridge") resolves through the build graph.
    for (targets) |t| {
        if (!t.has_bridges) continue;

        const bridge_chunk = try std.fmt.allocPrint(allocator,
            \\    const bridge_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("{s}_bridge.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
        , .{ t.module_name, t.module_name });
        defer allocator.free(bridge_chunk);
        try buf.appendSlice(allocator, bridge_chunk);
    }

    // Also create bridge modules for non-root modules
    for (extra_bridge_modules) |bmod_name| {
        const bridge_chunk = try std.fmt.allocPrint(allocator,
            \\    const bridge_{s} = b.createModule(.{{
            \\        .root_source_file = b.path("{s}_bridge.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
        , .{ bmod_name, bmod_name });
        defer allocator.free(bridge_chunk);
        try buf.appendSlice(allocator, bridge_chunk);
    }

    // Wire bridge-to-bridge imports: if target A has bridges and imports target B
    // which also has bridges, bridge_A needs addImport for bridge_B.
    for (targets) |t| {
        if (!t.has_bridges) continue;
        for (t.lib_imports) |dep_name| {
            if (bridge_set.contains(dep_name)) {
                const b2b_chunk = try std.fmt.allocPrint(allocator,
                    \\    bridge_{s}.addImport("{s}_bridge", bridge_{s});
                    \\
                , .{ t.module_name, dep_name, dep_name });
                defer allocator.free(b2b_chunk);
                try buf.appendSlice(allocator, b2b_chunk);
            }
        }
    }

    // #linkC is applied to lib/exe artifacts below, not to bridge modules.
    // Build.Module doesn't have linkSystemLibrary/linkLibC — only Step.Compile does.

    // Shared @cImport module generation (Bug 8 fix):
    // When multiple modules declare #cInclude for the same header, generate a shared
    // wrapper module so all sidecars reference the same @cImport unit. This gives
    // type identity across module boundaries (VkBuffer from A == VkBuffer from B).
    //
    // Map: header_path → list of module_names that include it.
    // For headers used by 2+ modules (or any module with c_includes), emit a shared module.
    //
    // Naming: the shared module is named after the lib (derived from the header path).
    // E.g. "vulkan/vulkan.h" → "vulkan_c", "SDL3/SDL.h" → "SDL3_c".
    var shared_cimport_set = std.StringHashMapUnmanaged(void){};
    defer shared_cimport_set.deinit(allocator);

    // Build map: header_path → count of modules using it
    var header_use_count = std.StringHashMapUnmanaged(usize){};
    defer header_use_count.deinit(allocator);
    for (targets) |*t| {
        for (t.c_includes) |hdr| {
            const entry = try header_use_count.getOrPut(allocator, hdr);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }
    }

    // Emit a shared @cImport module for each header that appears in any target
    for (targets) |*t| {
        for (t.c_includes) |hdr| {
            if (shared_cimport_set.contains(hdr)) continue;
            try shared_cimport_set.put(allocator, hdr, {});

            // Derive a Zig identifier from the header path: take the last segment,
            // strip the extension, replace non-alphanumeric with '_'.
            // E.g. "vulkan/vulkan.h" → "vulkan_c", "SDL3/SDL.h" → "SDL3_c"
            const base = std.fs.path.basename(hdr);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
                base[0..dot]
            else
                base;

            // Sanitize stem into a valid Zig identifier
            var stem_buf: [64]u8 = undefined;
            const stem_len = @min(stem.len, 63);
            for (0..stem_len) |i| {
                stem_buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
            }
            const safe_stem = stem_buf[0..stem_len];

            const cimport_chunk = try std.fmt.allocPrint(allocator,
                \\    const cimport_{s} = b.createModule(.{{
                \\        .root_source_file = b.path("_{s}_c.zig"),
                \\        .target = target,
                \\        .optimize = optimize,
                \\    }});
                \\
            , .{ safe_stem, safe_stem });
            defer allocator.free(cimport_chunk);
            try buf.appendSlice(allocator, cimport_chunk);
        }
    }

    // Wire shared @cImport modules into bridge modules that use them
    for (targets) |*t| {
        if (!t.has_bridges) continue;
        for (t.c_includes) |hdr| {
            const base = std.fs.path.basename(hdr);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
                base[0..dot]
            else
                base;
            var stem_buf: [64]u8 = undefined;
            const stem_len = @min(stem.len, 63);
            for (0..stem_len) |i| {
                stem_buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
            }
            const safe_stem = stem_buf[0..stem_len];

            const wire_chunk = try std.fmt.allocPrint(allocator,
                \\    bridge_{s}.addImport("{s}_c", cimport_{s});
                \\
            , .{ t.module_name, safe_stem, safe_stem });
            defer allocator.free(wire_chunk);
            try buf.appendSlice(allocator, wire_chunk);
        }
    }

    // Shared module creation — non-root, non-lib modules that are imported by
    // multiple targets need named modules to avoid "file exists in two modules".
    var shared_set = std.StringHashMapUnmanaged(void){};
    defer shared_set.deinit(allocator);
    for (targets) |t| {
        for (t.mod_imports) |mod_name| {
            if (!shared_set.contains(mod_name) and !lib_targets.contains(mod_name)) {
                try shared_set.put(allocator, mod_name, {});
                const shared_chunk = try std.fmt.allocPrint(allocator,
                    \\    const mod_{s} = b.createModule(.{{
                    \\        .root_source_file = b.path("{s}.zig"),
                    \\        .target = target,
                    \\        .optimize = optimize,
                    \\    }});
                    \\    mod_{s}.addImport("_orhon_str", str_mod);
                    \\    mod_{s}.addImport("_orhon_collections", coll_mod);
                    \\
                , .{ mod_name, mod_name, mod_name, mod_name });
                defer allocator.free(shared_chunk);
                try buf.appendSlice(allocator, shared_chunk);

                // If this shared module has a bridge, wire it
                if (bridge_set.contains(mod_name)) {
                    const smod_bridge = try std.fmt.allocPrint(allocator,
                        \\    mod_{s}.addImport("{s}_bridge", bridge_{s});
                        \\
                    , .{ mod_name, mod_name, mod_name });
                    defer allocator.free(smod_bridge);
                    try buf.appendSlice(allocator, smod_bridge);
                }
            }
        }
    }

    // Pass 1: emit all lib targets in dependency order
    for (sorted_libs.items) |t| {
        const linkage: []const u8 = if (std.mem.eql(u8, t.build_type, "dynamic")) ".dynamic" else ".static";

        const lib_chunk = try std.fmt.allocPrint(allocator,
            \\    const lib_{s} = b.addLibrary(.{{
            \\        .name = "{s}",
            \\        .linkage = {s},
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("{s}.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\    lib_{s}.root_module.addImport("_orhon_str", str_mod);
            \\    lib_{s}.root_module.addImport("_orhon_collections", coll_mod);
            \\
        , .{ t.module_name, t.project_name, linkage, t.module_name, t.module_name, t.module_name });
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);

        // Add bridge module import for this lib target
        if (t.has_bridges) {
            const bridge_import = try std.fmt.allocPrint(allocator,
                \\    lib_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ t.module_name, t.module_name, t.module_name });
            defer allocator.free(bridge_import);
            try buf.appendSlice(allocator, bridge_import);
        }

        // Add imports for non-root bridge modules used by this target
        for (extra_bridge_modules) |bmod_name| {
            const extra_import = try std.fmt.allocPrint(allocator,
                \\    lib_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ t.module_name, bmod_name, bmod_name });
            defer allocator.free(extra_import);
            try buf.appendSlice(allocator, extra_import);
        }

        // Emit addImport for lib-to-lib dependencies so Zig resolves them via the
        // build system module graph rather than falling back to file-path lookup.
        for (t.lib_imports) |dep_name| {
            if (lib_targets.contains(dep_name)) {
                const dep_chunk = try std.fmt.allocPrint(allocator,
                    \\    lib_{s}.root_module.addImport("{s}", lib_{s}.root_module);
                    \\
                , .{ t.module_name, dep_name, dep_name });
                defer allocator.free(dep_chunk);
                try buf.appendSlice(allocator, dep_chunk);

                // Also add bridge import for the dependency if it has bridges
                if (bridge_set.contains(dep_name)) {
                    const dep_bridge = try std.fmt.allocPrint(allocator,
                        \\    lib_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                        \\
                    , .{ t.module_name, dep_name, dep_name });
                    defer allocator.free(dep_bridge);
                    try buf.appendSlice(allocator, dep_bridge);
                }
            }
        }

        // Add shared (non-lib) module imports
        for (t.mod_imports) |mod_name| {
            if (shared_set.contains(mod_name)) {
                const mod_import = try std.fmt.allocPrint(allocator,
                    \\    lib_{s}.root_module.addImport("{s}", mod_{s});
                    \\
                , .{ t.module_name, mod_name, mod_name });
                defer allocator.free(mod_import);
                try buf.appendSlice(allocator, mod_import);
            }
        }

        // Apply #linkC to this lib artifact
        if (t.link_libs.len > 0) {
            const lib_art_name = try std.fmt.allocPrint(allocator, "lib_{s}", .{t.module_name});
            defer allocator.free(lib_art_name);
            try emitLinkLibs(&buf, allocator, t.link_libs, lib_art_name);
        }

        // Apply #csource / #linkCpp to this lib artifact
        if (t.c_source_files.len > 0 or t.needs_cpp) {
            const lib_art_name = try std.fmt.allocPrint(allocator, "lib_{s}", .{t.module_name});
            defer allocator.free(lib_art_name);
            try emitCSourceFiles(&buf, allocator, t.c_source_files, t.needs_cpp, lib_art_name);
        }

        const install_chunk = try std.fmt.allocPrint(allocator,
            \\    b.installArtifact(lib_{s});
            \\
        , .{t.module_name});
        defer allocator.free(install_chunk);
        try buf.appendSlice(allocator, install_chunk);
    }

    // Wire lib modules into bridge modules so sidecars can @import("lib_name").
    // This must come after Pass 1 since lib_* variables are declared there.
    for (targets) |t| {
        if (!t.has_bridges) continue;
        for (t.lib_imports) |dep_name| {
            if (lib_targets.contains(dep_name)) {
                const b2l_chunk = try std.fmt.allocPrint(allocator,
                    \\    bridge_{s}.addImport("{s}", lib_{s}.root_module);
                    \\
                , .{ t.module_name, dep_name, dep_name });
                defer allocator.free(b2l_chunk);
                try buf.appendSlice(allocator, b2l_chunk);
            }
        }
        // Also wire shared modules into bridge modules
        for (t.mod_imports) |mod_name| {
            if (shared_set.contains(mod_name)) {
                const b2m_chunk = try std.fmt.allocPrint(allocator,
                    \\    bridge_{s}.addImport("{s}", mod_{s});
                    \\
                , .{ t.module_name, mod_name, mod_name });
                defer allocator.free(b2m_chunk);
                try buf.appendSlice(allocator, b2m_chunk);
            }
        }
    }

    // Pass 2: emit all exe targets, linking against libs
    for (targets) |t| {
        if (!std.mem.eql(u8, t.build_type, "exe")) continue;

        var ver_buf: [128]u8 = undefined;
        const ver_line: []const u8 = if (t.version) |v|
            std.fmt.bufPrint(&ver_buf, "\n        .version = .{{ .major = {d}, .minor = {d}, .patch = {d} }},", .{ v[0], v[1], v[2] }) catch ""
        else
            "";

        const exe_chunk = try std.fmt.allocPrint(allocator,
            \\    const exe_{s} = b.addExecutable(.{{
            \\        .name = "{s}",{s}
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("{s}.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\    exe_{s}.root_module.addImport("_orhon_str", str_mod);
            \\    exe_{s}.root_module.addImport("_orhon_collections", coll_mod);
            \\
        , .{ t.module_name, t.project_name, ver_line, t.module_name, t.module_name, t.module_name });
        defer allocator.free(exe_chunk);
        try buf.appendSlice(allocator, exe_chunk);

        // Add bridge module import for this exe target
        if (t.has_bridges) {
            const bridge_import = try std.fmt.allocPrint(allocator,
                \\    exe_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ t.module_name, t.module_name, t.module_name });
            defer allocator.free(bridge_import);
            try buf.appendSlice(allocator, bridge_import);
        }

        // Add imports for non-root bridge modules used by this target
        for (extra_bridge_modules) |bmod_name| {
            const extra_import = try std.fmt.allocPrint(allocator,
                \\    exe_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                \\
            , .{ t.module_name, bmod_name, bmod_name });
            defer allocator.free(extra_import);
            try buf.appendSlice(allocator, extra_import);
        }

        // Link imported lib modules
        for (t.lib_imports) |lib_name| {
            if (lib_targets.contains(lib_name)) {
                const link_chunk = try std.fmt.allocPrint(allocator,
                    \\    exe_{s}.root_module.addImport("{s}", lib_{s}.root_module);
                    \\    exe_{s}.linkLibrary(lib_{s});
                    \\
                , .{ t.module_name, lib_name, lib_name, t.module_name, lib_name });
                defer allocator.free(link_chunk);
                try buf.appendSlice(allocator, link_chunk);

                // Also add bridge import for the dependency if it has bridges
                if (bridge_set.contains(lib_name)) {
                    const dep_bridge = try std.fmt.allocPrint(allocator,
                        \\    exe_{s}.root_module.addImport("{s}_bridge", bridge_{s});
                        \\
                    , .{ t.module_name, lib_name, lib_name });
                    defer allocator.free(dep_bridge);
                    try buf.appendSlice(allocator, dep_bridge);
                }
            }
        }

        // Add shared (non-lib) module imports
        for (t.mod_imports) |mod_name| {
            if (shared_set.contains(mod_name)) {
                const mod_import = try std.fmt.allocPrint(allocator,
                    \\    exe_{s}.root_module.addImport("{s}", mod_{s});
                    \\
                , .{ t.module_name, mod_name, mod_name });
                defer allocator.free(mod_import);
                try buf.appendSlice(allocator, mod_import);
            }
        }

        // Apply #linkC to this exe artifact
        if (t.link_libs.len > 0) {
            const exe_art_name = try std.fmt.allocPrint(allocator, "exe_{s}", .{t.module_name});
            defer allocator.free(exe_art_name);
            try emitLinkLibs(&buf, allocator, t.link_libs, exe_art_name);
        }

        // Apply #csource / #linkCpp to this exe artifact
        if (t.c_source_files.len > 0 or t.needs_cpp) {
            const exe_art_name = try std.fmt.allocPrint(allocator, "exe_{s}", .{t.module_name});
            defer allocator.free(exe_art_name);
            try emitCSourceFiles(&buf, allocator, t.c_source_files, t.needs_cpp, exe_art_name);
        }

        const install_chunk = try std.fmt.allocPrint(allocator,
            \\    b.installArtifact(exe_{s});
            \\
            \\    const run_cmd_{s} = b.addRunArtifact(exe_{s});
            \\    run_cmd_{s}.step.dependOn(b.getInstallStep());
            \\    const run_step = b.step("run", "Run");
            \\    run_step.dependOn(&run_cmd_{s}.step);
            \\
        , .{ t.module_name, t.module_name, t.module_name, t.module_name, t.module_name });
        defer allocator.free(install_chunk);
        try buf.appendSlice(allocator, install_chunk);
    }

    // Test step — use the first exe target's module for tests
    for (targets) |t| {
        if (std.mem.eql(u8, t.build_type, "exe")) {
            const test_chunk = try std.fmt.allocPrint(allocator,
                \\    const unit_tests = b.addTest(.{{
                \\        .root_module = b.createModule(.{{
                \\            .root_source_file = b.path("{s}.zig"),
                \\            .target = target,
                \\            .optimize = optimize,
                \\        }}),
                \\    }});
                \\
            , .{t.module_name});
            defer allocator.free(test_chunk);
            try buf.appendSlice(allocator, test_chunk);

            // Add bridge imports to test target
            if (t.has_bridges) {
                const test_bridge = try std.fmt.allocPrint(allocator,
                    \\    unit_tests.root_module.addImport("{s}_bridge", bridge_{s});
                    \\
                , .{ t.module_name, t.module_name });
                defer allocator.free(test_bridge);
                try buf.appendSlice(allocator, test_bridge);
            }
            for (t.lib_imports) |lib_name| {
                if (bridge_set.contains(lib_name)) {
                    const test_dep_bridge = try std.fmt.allocPrint(allocator,
                        \\    unit_tests.root_module.addImport("{s}_bridge", bridge_{s});
                        \\
                    , .{ lib_name, lib_name });
                    defer allocator.free(test_dep_bridge);
                    try buf.appendSlice(allocator, test_dep_bridge);
                }
            }

            // Add imports for non-root bridge modules
            for (extra_bridge_modules) |bmod_name| {
                const extra_test = try std.fmt.allocPrint(allocator,
                    \\    unit_tests.root_module.addImport("{s}_bridge", bridge_{s});
                    \\
                , .{ bmod_name, bmod_name });
                defer allocator.free(extra_test);
                try buf.appendSlice(allocator, extra_test);
            }

            // Add shared module imports to test target
            for (t.mod_imports) |mod_name| {
                if (shared_set.contains(mod_name)) {
                    const test_mod = try std.fmt.allocPrint(allocator,
                        \\    unit_tests.root_module.addImport("{s}", mod_{s});
                        \\
                    , .{ mod_name, mod_name });
                    defer allocator.free(test_mod);
                    try buf.appendSlice(allocator, test_mod);
                }
            }

            try buf.appendSlice(allocator,
                \\    const run_tests = b.addRunArtifact(unit_tests);
                \\    const test_step = b.step("test", "Run tests");
                \\    test_step.dependOn(&run_tests.step);
                \\
            );
            break;
        }
    }

    try buf.appendSlice(allocator,
        \\}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

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

const builtin = @import("builtin");

test "zig runner - find zig path format" {
    const alloc = std.testing.allocator;
    const name = zigBinaryName();
    try std.testing.expect(name.len > 0);
    _ = alloc;
}

test "buildZigContent - exe" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false);
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
    const content = try buildZigContent(alloc, "mylib", "static", "mylib", null, &.{}, &.{}, &.{}, &.{}, &.{}, false);
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
    const content = try buildZigContent(alloc, "mylib", "dynamic", "mylib", null, &.{}, &.{}, &.{}, &.{}, &.{}, false);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - project name in exe artifact" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "calculator", null, &.{}, &.{}, &.{}, &.{}, &.{}, false);
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"calculator\"") != null);
}

test "buildZigContent - linkC emits linkSystemLibrary and linkLibC" {
    const alloc = std.testing.allocator;
    const libs = [_][]const u8{"SDL3"};
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &libs, &.{}, &.{}, &.{}, &.{}, false);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary(\"SDL3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC()") != null);
}

test "buildZigContent - no linkC means no linkLibC" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC") == null);
}

test "buildZigContentMulti - exe with dynamic lib" {
    const alloc = std.testing.allocator;
    const lib_name: []const u8 = "mathlib";
    const targets = [_]MultiTarget{
        .{ .module_name = "mathlib", .project_name = "mathlib", .build_type = "dynamic", .lib_imports = &.{} },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = @constCast(&[_][]const u8{lib_name}) },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    // Lib target present
    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    // Exe target present
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    // Linking: addImport + linkLibrary
    try std.testing.expect(std.mem.indexOf(u8, content, "addImport(\"mathlib\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibrary(lib_mathlib)") != null);
    // Test step present
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContentMulti - exe with static lib" {
    const alloc = std.testing.allocator;
    const lib_name: []const u8 = "utils";
    const targets = [_]MultiTarget{
        .{ .module_name = "utils", .project_name = "utils", .build_type = "static", .lib_imports = &.{} },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = @constCast(&[_][]const u8{lib_name}) },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .static") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addImport(\"utils\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibrary(lib_utils)") != null);
}

test "buildZigContentMulti - single exe (no libs)" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") == null);
    // Runtime module has been removed — must NOT be present
    try std.testing.expect(std.mem.indexOf(u8, content, "addImport(\"_orhon_rt\"") == null);
}

test "buildZigContentMulti - lib-to-lib imports added to prevent file-module conflicts" {
    // When lib A imports lib B, build.zig must emit addImport for B in A's section.
    // Without this, Zig falls back to file-path resolution and reports "file exists in modules".
    const alloc = std.testing.allocator;
    const sdl3_name: []const u8 = "tamga_sdl3";
    const vk3d_imports = [_][]const u8{sdl3_name};
    const targets = [_]MultiTarget{
        .{ .module_name = "tamga_sdl3", .project_name = "tamga_sdl3", .build_type = "static", .lib_imports = &.{} },
        .{ .module_name = "tamga_vk3d", .project_name = "tamga_vk3d", .build_type = "static", .lib_imports = @constCast(&vk3d_imports) },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    // lib_tamga_vk3d must have tamga_sdl3 as an addImport
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_vk3d.root_module.addImport(\"tamga_sdl3\"") != null);
    // tamga_sdl3 must be defined before tamga_vk3d in the output (topological order)
    const sdl3_pos = std.mem.indexOf(u8, content, "lib_tamga_sdl3 = b.addLibrary") orelse unreachable;
    const vk3d_pos = std.mem.indexOf(u8, content, "lib_tamga_vk3d = b.addLibrary") orelse unreachable;
    try std.testing.expect(sdl3_pos < vk3d_pos);
}

test "buildZigContentMulti - bridge modules registered as named modules" {
    const alloc = std.testing.allocator;
    const sdl3_name: []const u8 = "tamga_sdl3";
    const vk3d_name: []const u8 = "tamga_vk3d";
    const sdl3_libs = [_][]const u8{"SDL3"};
    const vk3d_imports = [_][]const u8{sdl3_name};
    const exe_imports = [_][]const u8{vk3d_name};
    const vk_libs = [_][]const u8{"vulkan"};
    const targets = [_]MultiTarget{
        .{ .module_name = "tamga_sdl3", .project_name = "tamga_sdl3", .build_type = "static", .lib_imports = &.{}, .has_bridges = true, .link_libs = @constCast(&sdl3_libs) },
        .{ .module_name = "tamga_vk3d", .project_name = "tamga_vk3d", .build_type = "static", .lib_imports = @constCast(&vk3d_imports), .has_bridges = true, .link_libs = @constCast(&vk_libs) },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = @constCast(&exe_imports), .has_bridges = false },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    // Bridge modules created
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_tamga_sdl3 = b.createModule") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_tamga_vk3d = b.createModule") != null);
    // No bridge for main (has_bridges = false)
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_main") == null);
    // Bridge-to-bridge wiring
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_tamga_vk3d.addImport(\"tamga_sdl3_bridge\"") != null);
    // linkSystemLibrary on lib artifact, not on bridge module
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_sdl3.linkSystemLibrary(\"SDL3\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_vk3d.linkSystemLibrary(\"vulkan\")") != null);
    // linkLibC on lib artifact
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_sdl3.linkLibC()") != null);
    // Lib targets get bridge addImport
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_sdl3.root_module.addImport(\"tamga_sdl3_bridge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_vk3d.root_module.addImport(\"tamga_vk3d_bridge\"") != null);
    // Exe target gets bridge import for its dependency (tamga_vk3d has bridges)
    try std.testing.expect(std.mem.indexOf(u8, content, "exe_main.root_module.addImport(\"tamga_vk3d_bridge\"") != null);
}

test "buildZigContentMulti - shared cImport module for cross-module C type identity" {
    // Bug 8: when multiple modules declare #cInclude for the same header, a shared
    // cimport_* module must be created and wired into each module's bridge.
    const alloc = std.testing.allocator;
    const vk_libs = [_][]const u8{"vulkan"};
    const vk_includes = [_][]const u8{"vulkan/vulkan.h"};
    const vma_imports = [_][]const u8{};
    const vk3d_imports = [_][]const u8{"tamga_vma"};
    const targets = [_]MultiTarget{
        .{ .module_name = "tamga_vma", .project_name = "tamga_vma", .build_type = "static", .lib_imports = @constCast(&vma_imports), .has_bridges = true, .link_libs = @constCast(&vk_libs), .c_includes = @constCast(&vk_includes) },
        .{ .module_name = "tamga_vk3d", .project_name = "tamga_vk3d", .build_type = "static", .lib_imports = @constCast(&vk3d_imports), .has_bridges = true, .link_libs = @constCast(&vk_libs), .c_includes = @constCast(&vk_includes) },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    // Shared cImport module created exactly once (not twice for the same header)
    const first = std.mem.indexOf(u8, content, "cimport_vulkan = b.createModule") orelse {
        std.debug.print("content:\n{s}\n", .{content});
        return error.TestUnexpectedResult;
    };
    const second = std.mem.indexOf(u8, content[first + 1 ..], "cimport_vulkan = b.createModule");
    try std.testing.expect(second == null); // only created once

    // Shared cImport module wired into both bridge modules
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_tamga_vma.addImport(\"vulkan_c\", cimport_vulkan)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bridge_tamga_vk3d.addImport(\"vulkan_c\", cimport_vulkan)") != null);
}

test "buildZigContentMulti - csource directive emits addCSourceFiles and linkLibCpp" {
    // Bug 9: when a module declares #csource with a .cpp file, the generated build.zig
    // must contain addCSourceFiles with -std=c++17 flags and linkLibCpp().
    const alloc = std.testing.allocator;
    const csources = [_][]const u8{"../../src/TamgaVMA/vma_impl.cpp"};
    const targets = [_]MultiTarget{
        .{ .module_name = "tamga_vma", .project_name = "tamga_vma", .build_type = "static", .lib_imports = &.{}, .c_source_files = @constCast(&csources), .needs_cpp = true },
        .{ .module_name = "main", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    // addCSourceFiles emitted for the lib artifact
    try std.testing.expect(std.mem.indexOf(u8, content, "addCSourceFiles") != null);
    // -std=c++17 flag present for .cpp file
    try std.testing.expect(std.mem.indexOf(u8, content, "-std=c++17") != null);
    // linkLibCpp emitted
    try std.testing.expect(std.mem.indexOf(u8, content, "lib_tamga_vma.linkLibCpp()") != null);
    // vma_impl.cpp path present
    try std.testing.expect(std.mem.indexOf(u8, content, "vma_impl.cpp") != null);
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
