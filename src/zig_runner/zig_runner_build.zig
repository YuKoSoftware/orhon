// zig_runner_build.zig — Single-target build.zig generation + shared helpers
// Generates the build.zig content for single-target (exe, static, dynamic) projects.

const std = @import("std");
const errors = @import("../errors.zig");
const cache = @import("../cache.zig");
const module = @import("../module.zig");

/// Sanitize a C header filename into a valid Zig identifier.
/// Returns the sanitized stem as a slice into the returned buffer.
/// e.g. "vk_mem_alloc.h" → "vk_mem_alloc"
pub const StemResult = struct {
    buf: [64]u8,
    len: usize,

    pub fn slice(self: *const StemResult) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn sanitizeHeaderStem(hdr: []const u8) StemResult {
    const base = std.fs.path.basename(hdr);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
        base[0..dot]
    else
        base;
    var result = StemResult{ .buf = undefined, .len = @min(stem.len, 63) };
    for (0..result.len) |i| {
        result.buf[i] = if (std.ascii.isAlphanumeric(stem[i])) stem[i] else '_';
    }
    return result;
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
    source_dir: ?[]const u8,
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
        const stem_result = sanitizeHeaderStem(hdr);
        const safe_stem = stem_result.slice();
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
            const stem_result = sanitizeHeaderStem(hdr);
            const safe_stem = stem_result.slice();
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
        // Apply addIncludePath so module-relative headers resolve (BLD-02)
        if (c_includes.len > 0) {
            if (source_dir) |sdir| {
                try emitIncludePath(&buf, allocator, sdir, artifact_name);
            }
        }
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
    // Apply addIncludePath so module-relative headers resolve in tests (BLD-02)
    if (c_includes.len > 0) {
        if (source_dir) |sdir| {
            try emitIncludePath(&buf, allocator, sdir, "unit_tests");
        }
    }
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
pub fn emitLinkLibs(
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

/// Emit addIncludePath for a Step.Compile artifact so module-relative headers resolve.
pub fn emitIncludePath(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    source_dir: []const u8,
    artifact_name: []const u8,
) !void {
    const chunk = try std.fmt.allocPrint(allocator,
        \\    {s}.root_module.addIncludePath(.{{ .cwd_relative = "{s}" }});
        \\
    , .{ artifact_name, source_dir });
    defer allocator.free(chunk);
    try buf.appendSlice(allocator, chunk);
}

/// Generate shared @cImport wrapper .zig files for all unique #cimport include headers.
/// Each file is written to the generated cache dir as _{stem}_c.zig and exposes:
///   pub const c = @cImport({ @cInclude("header.h"); });
/// Sidecars use: const c = @import("{stem}_c").c;
/// Note: `usingnamespace` was removed from file scope in Zig 0.15; callers access
/// the cImport result via the `.c` field on the imported module.
pub fn generateSharedCImportFiles(allocator: std.mem.Allocator, targets: anytype) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    for (targets) |*t| {
        for (t.c_includes) |hdr| {
            if (seen.contains(hdr)) continue;
            try seen.put(allocator, hdr, {});

            const stem_result = sanitizeHeaderStem(hdr);
            const safe_stem = stem_result.slice();

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
pub fn emitCSourceFiles(
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

test "buildZigContent - exe" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addRunArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"myapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"myapp.zig\"") != null);
    // test step always present
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - static" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "mylib", "static", "mylib", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
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
    const content = try buildZigContent(alloc, "mylib", "dynamic", "mylib", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}

test "buildZigContent - project name in exe artifact" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "myapp", "exe", "calculator", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"calculator\"") != null);
}

test "buildZigContent - cimport link libs emit linkSystemLibrary and linkLibC" {
    const alloc = std.testing.allocator;
    const libs = [_][]const u8{"SDL3"};
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &libs, &.{}, &.{}, &.{}, &.{}, false, null);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary(\"SDL3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC()") != null);
}

test "buildZigContent - no cimport link libs means no linkLibC" {
    const alloc = std.testing.allocator;
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC") == null);
}
