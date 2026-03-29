// zig_runner_multi.zig — Multi-target build.zig generation
// Generates the unified build.zig content for multi-target (multi-lib/exe) projects.

const std = @import("std");
const errors = @import("../errors.zig");
const cache = @import("../cache.zig");
const module = @import("../module.zig");
const _build = @import("zig_runner_build.zig");

/// Descriptor for a build target in a multi-target project
pub const MultiTarget = struct {
    module_name: []const u8,
    project_name: []const u8,
    build_type: []const u8, // "exe", "static", "dynamic"
    lib_imports: []const []const u8, // names of imported lib modules (for linking)
    mod_imports: []const []const u8 = &.{}, // names of non-lib imported modules (for named module refs)
    version: ?[3]u64 = null,
    link_libs: []const []const u8 = &.{}, // C libraries from #cimport metadata
    c_includes: []const []const u8 = &.{}, // C headers from #cimport include field (for shared @cImport module)
    c_source_files: []const []const u8 = &.{}, // C/C++ source files from #cimport source field
    needs_cpp: bool = false, // true when C++ source files are present (.cpp/.cc)
    has_bridges: bool = false, // module has bridge declarations needing named Zig modules
    source_dir: ?[]const u8 = null, // source directory for addIncludePath (cimport module-relative headers)
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

    // #cimport link libs are applied to lib/exe artifacts below, not to bridge modules.
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

        // Apply #cimport link libs to this lib artifact
        if (t.link_libs.len > 0) {
            const lib_art_name = try std.fmt.allocPrint(allocator, "lib_{s}", .{t.module_name});
            defer allocator.free(lib_art_name);
            try _build.emitLinkLibs(&buf, allocator, t.link_libs, lib_art_name);
        }

        // Apply addIncludePath so module-relative headers resolve (BLD-02)
        if (t.c_includes.len > 0) {
            if (t.source_dir) |sdir| {
                const lib_art_name = try std.fmt.allocPrint(allocator, "lib_{s}", .{t.module_name});
                defer allocator.free(lib_art_name);
                try _build.emitIncludePath(&buf, allocator, sdir, lib_art_name);
            }
        }

        // Apply #cimport source files to this lib artifact
        if (t.c_source_files.len > 0 or t.needs_cpp) {
            const lib_art_name = try std.fmt.allocPrint(allocator, "lib_{s}", .{t.module_name});
            defer allocator.free(lib_art_name);
            try _build.emitCSourceFiles(&buf, allocator, t.c_source_files, t.needs_cpp, lib_art_name);
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

        // Apply #cimport link libs to this exe artifact
        if (t.link_libs.len > 0) {
            const exe_art_name = try std.fmt.allocPrint(allocator, "exe_{s}", .{t.module_name});
            defer allocator.free(exe_art_name);
            try _build.emitLinkLibs(&buf, allocator, t.link_libs, exe_art_name);
        }

        // Apply addIncludePath so module-relative headers resolve (BLD-02)
        if (t.c_includes.len > 0) {
            if (t.source_dir) |sdir| {
                const exe_art_name = try std.fmt.allocPrint(allocator, "exe_{s}", .{t.module_name});
                defer allocator.free(exe_art_name);
                try _build.emitIncludePath(&buf, allocator, sdir, exe_art_name);
            }
        }

        // Apply #cimport source files to this exe artifact
        if (t.c_source_files.len > 0 or t.needs_cpp) {
            const exe_art_name = try std.fmt.allocPrint(allocator, "exe_{s}", .{t.module_name});
            defer allocator.free(exe_art_name);
            try _build.emitCSourceFiles(&buf, allocator, t.c_source_files, t.needs_cpp, exe_art_name);
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
