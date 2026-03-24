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
    ) !bool {
        // Generate unified build.zig
        const content = try buildZigContentMulti(self.allocator, targets);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

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
    pub fn runTests(self: *ZigRunner, module_name: []const u8, project_name: []const u8) !bool {
        // Generate build.zig with test step included
        try self.generateBuildZigWithTests(module_name, "exe", project_name, null, &.{});

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
    ) !void {
        return self.generateBuildZigWithTests(module_name, build_type, project_name, project_version, link_libs);
    }

    fn generateBuildZigWithTests(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
        project_version: ?[3]u64,
        link_libs: []const []const u8,
    ) !void {
        const content = try buildZigContent(self.allocator, module_name, build_type, project_name, project_version, link_libs);
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
    project_version: ?[3]u64,
    link_libs: []const []const u8,
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
    }

    // Emit C library linking for the target artifact
    const artifact_name: []const u8 = if (std.mem.eql(u8, build_type, "exe")) "exe" else "lib";
    try emitLinkLibs(&buf, allocator, link_libs, artifact_name);

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

    // Link C libraries for tests too
    try emitLinkLibs(&buf, allocator, link_libs, "unit_tests");

    try buf.appendSlice(allocator,
        \\}
        \\
    );

    return buf.toOwnedSlice(allocator);
}

/// Emit linkSystemLibrary + linkLibC calls for an artifact.
fn emitLinkLibs(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    link_libs: []const []const u8,
    artifact_name: []const u8,
) !void {
    if (link_libs.len == 0) return;
    for (link_libs) |lib_name| {
        const chunk = try std.fmt.allocPrint(allocator,
            \\    {s}.root_module.linkSystemLibrary("{s}", .{{}});
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

/// Descriptor for a build target in a multi-target project
pub const MultiTarget = struct {
    module_name: []const u8,
    project_name: []const u8,
    build_type: []const u8, // "exe", "static", "dynamic"
    lib_imports: []const []const u8, // names of imported lib modules (for linking)
    version: ?[3]u64 = null,
};

/// Build a unified build.zig for multiple targets.
/// Libs are defined first, then exes link against them via addImport + linkLibrary.
pub fn buildZigContentMulti(
    allocator: std.mem.Allocator,
    targets: []const MultiTarget,
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

    // Pass 1: emit all lib targets first
    for (targets) |t| {
        if (std.mem.eql(u8, t.build_type, "exe")) continue;

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
            \\    b.installArtifact(lib_{s});
            \\
        , .{ t.module_name, t.project_name, linkage, t.module_name, t.module_name, t.module_name, t.module_name });
        defer allocator.free(lib_chunk);
        try buf.appendSlice(allocator, lib_chunk);

        try lib_targets.put(allocator, t.module_name, t.project_name);
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
            }
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
                \\    const run_tests = b.addRunArtifact(unit_tests);
                \\    const test_step = b.step("test", "Run tests");
                \\    test_step.dependOn(&run_tests.step);
                \\
            , .{t.module_name});
            defer allocator.free(test_chunk);
            try buf.appendSlice(allocator, test_chunk);
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
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &.{});
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
    const content = try buildZigContent(alloc, "mylib", "static", "mylib", null, &.{});
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
    const content = try buildZigContent(alloc, "mylib", "dynamic", "mylib", null, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - project name in exe artifact" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "calculator", null, &.{});
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"calculator\"") != null);
}

test "buildZigContent - linkC emits linkSystemLibrary and linkLibC" {
    const alloc = std.testing.allocator;
    const libs = [_][]const u8{"SDL3"};
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &libs);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary(\"SDL3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC()") != null);
}

test "buildZigContent - no linkC means no linkLibC" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "main", "exe", "myapp", null, &.{});
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
    const content = try buildZigContentMulti(alloc, &targets);
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
    const content = try buildZigContentMulti(alloc, &targets);
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
    const content = try buildZigContentMulti(alloc, &targets);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") == null);
    // Runtime module has been removed — must NOT be present
    try std.testing.expect(std.mem.indexOf(u8, content, "addImport(\"_orhon_rt\"") == null);
}
