// pipeline.zig — Compilation pipeline orchestration (runPipeline)

const std = @import("std");
const parser = @import("parser.zig");
const module = @import("module.zig");
const declarations = @import("declarations.zig");
const zig_runner = @import("zig_runner/zig_runner.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const _cli = @import("cli.zig");
const _std_bundle = @import("std_bundle.zig");
const _interface = @import("interface.zig");
const _commands = @import("commands.zig");
const build_helpers = @import("pipeline_build.zig");
const passes = @import("pipeline_passes.zig");
const zig_module = @import("zig_module.zig");
const constants = @import("constants.zig");

pub fn runPipeline(allocator: std.mem.Allocator, cli: *_cli.CliArgs, reporter: *errors.Reporter) !?[]const u8 {

    // Ensure embedded std files exist in .orh-cache/std/
    try _std_bundle.ensureStdFiles(allocator);

    // ── Stdlib Zig Conversion ────────────────────────────────
    // Convert stdlib .zig files (in .orh-cache/std/) to .orh declarations,
    // writing generated .orh back to .orh-cache/std/ so preScanImports finds them.
    const std_dir = cache.CACHE_DIR ++ "/std";
    const std_zig_converted = try zig_module.discoverAndConvert(allocator, std_dir, std_dir);
    defer {
        for (std_zig_converted) |*cm| cm.deinit(allocator);
        allocator.free(std_zig_converted);
    }

    // Build set of converted std module names for import rewriting
    var std_mod_names = std.StringHashMapUnmanaged(void){};
    defer std_mod_names.deinit(allocator);
    for (std_zig_converted) |cm| {
        try std_mod_names.put(allocator, cm.name, {});
    }

    // Copy stdlib .zig files to .orh-cache/generated/{name}_zig.zig for the build system.
    // Rewrite @import("sibling.zig") → @import("sibling_zig") for sibling std modules,
    // since the files are renamed to {name}_zig.zig in the generated dir.
    try cache.ensureGeneratedDir();
    for (std_zig_converted) |cm| {
        const name = cm.name;
        const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ std_dir, name });
        defer allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}_zig.zig", .{ cache.GENERATED_DIR, name });
        defer allocator.free(dst_path);

        const content = std.fs.cwd().readFileAlloc(allocator, src_path, 1024 * 1024) catch continue;
        defer allocator.free(content);

        // Rewrite sibling @import("x.zig") → @import("x_zig") for known std modules
        var rewritten: std.ArrayListUnmanaged(u8) = .{};
        defer rewritten.deinit(allocator);
        var pos: usize = 0;
        while (pos < content.len) {
            const needle = "@import(\"";
            const idx = std.mem.indexOfPos(u8, content, pos, needle) orelse {
                try rewritten.appendSlice(allocator, content[pos..]);
                break;
            };
            // Copy everything up to and including @import("
            try rewritten.appendSlice(allocator, content[pos .. idx + needle.len]);
            const start = idx + needle.len;
            const end = std.mem.indexOfPos(u8, content, start, "\"") orelse {
                try rewritten.appendSlice(allocator, content[start..]);
                break;
            };
            const import_path = content[start..end];

            if (std.mem.endsWith(u8, import_path, ".zig") and
                std.mem.indexOf(u8, import_path, "/") == null)
            {
                const stem = import_path[0 .. import_path.len - 4];
                if (!std.mem.eql(u8, stem, "std") and std_mod_names.contains(stem)) {
                    // Rewrite: "allocator.zig" → "allocator_zig"
                    try rewritten.appendSlice(allocator, stem);
                    try rewritten.appendSlice(allocator, "_zig");
                    pos = end; // skip the old import path, keep the closing "
                    continue;
                }
            }
            // No rewrite — copy the import path as-is
            try rewritten.appendSlice(allocator, import_path);
            pos = end;
        }

        const dst_file = std.fs.cwd().createFile(dst_path, .{}) catch continue;
        defer dst_file.close();
        dst_file.writeAll(rewritten.items) catch {};
    }

    // ── Zig Module Discovery ─────────────────────────────────
    // Discover .zig files in src/, parse them, generate .orh into .orh-cache/zig_modules/
    const zig_mod_converted = try zig_module.discoverAndConvert(allocator, cli.source_dir, null);
    defer {
        for (zig_mod_converted) |*cm| cm.deinit(allocator);
        allocator.free(zig_mod_converted);
    }

    // Build a map from module name → zon config for use when assembling build targets.
    // Includes both user zig modules and stdlib zig modules.
    var zon_configs = std.StringHashMapUnmanaged(zig_module.ZonConfig){};
    defer zon_configs.deinit(allocator);
    // Note: we do NOT deinit the ZonConfig values here — they are borrowed from
    // std_zig_converted / zig_mod_converted which own them via their defer blocks.
    for (std_zig_converted) |cm| {
        try zon_configs.put(allocator, cm.name, cm.config);
    }
    for (zig_mod_converted) |cm| {
        try zon_configs.put(allocator, cm.name, cm.config);
    }

    // ── Pass 3: Module Resolution ──────────────────────────────
    var mod_resolver = module.Resolver.init(allocator, reporter);
    defer mod_resolver.deinit();

    // Check source dir exists before scanning — give a clear error if not
    std.fs.cwd().access(cli.source_dir, .{}) catch {
        std.debug.print("error: source directory '{s}' not found\n", .{cli.source_dir});
        std.debug.print("  run `orhon build` from inside an orhon project directory\n", .{});
        std.debug.print("  expected: {s}/<project_name>.orh with #build = exe\n", .{cli.source_dir});
        return null;
    };

    // Derive project folder name for primary module detection
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const project_folder_name = std.fs.path.basename(cwd_path);

    try mod_resolver.scanDirectory(cli.source_dir);

    // Scan generated zig module .orh files (user .orh files take precedence — already registered)
    if (std.fs.cwd().openDir(cache.ZIG_MODULES_DIR, .{})) |dir| {
        var d = dir;
        d.close();
        try mod_resolver.scanDirectory(cache.ZIG_MODULES_DIR);
    } else |_| {}

    if (reporter.hasErrors()) return null;

    // Load incremental cache
    var comp_cache = cache.Cache.init(allocator);
    defer comp_cache.deinit();
    try comp_cache.loadHashes();
    try comp_cache.loadDeps();
    try comp_cache.loadInterfaceHashes();

    // Pre-scan imports to discover std modules before full parsing.
    // This avoids the need for a second parse pass.
    try mod_resolver.preScanImports();

    // Parse all modules — single pass (std modules already in module map)
    try mod_resolver.parseModules(allocator);
    if (reporter.hasErrors()) return null;

    // Mark discovered zig modules with is_zig_module flag and store original .zig path.
    // Done after parseModules. Skip modules that have user-authored .orh files — those
    // are Orhon modules, and any co-located .zig file is just additional source, not a
    // zig-as-module replacement. Only pure .zig modules (no user .orh files) get marked.
    for (zig_mod_converted) |cm| {
        const name = cm.name;
        if (mod_resolver.modules.getPtr(name)) |mod_ptr| {
            // Check if the module has user-authored .orh files outside the zig_modules cache.
            // The auto-generated .orh from zig discovery lives in .orh-cache/zig_modules/.
            // If all .orh files are from the cache, this is a pure zig module.
            const has_user_orh = for (mod_ptr.files) |file| {
                if (std.mem.endsWith(u8, file, ".orh") and
                    !std.mem.startsWith(u8, file, cache.ZIG_MODULES_DIR))
                    break true;
            } else false;
            if (!has_user_orh) {
                mod_ptr.is_zig_module = true;
                mod_ptr.zig_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ cli.source_dir, name });
            }
        }
    }

    // Mark stdlib zig modules (auto-generated from .zig files in .orh-cache/std/)
    for (std_zig_converted) |cm| {
        const name = cm.name;
        if (mod_resolver.modules.getPtr(name)) |mod_ptr| {
            mod_ptr.is_zig_module = true;
            mod_ptr.zig_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ std_dir, name });
        }
    }

    // Scan and parse any #dep directories declared in the root module
    try mod_resolver.scanAndParseDeps(allocator, cli.source_dir);
    if (reporter.hasErrors()) return null;

    // Check circular imports — must run after parseModules/scanAndParseDeps
    // which populate each module's imports list
    try mod_resolver.checkCircularImports();
    if (reporter.hasErrors()) return null;

    // Validate all imports — report any modules that were imported but not found
    try mod_resolver.validateImports(reporter);
    if (reporter.hasErrors()) return null;

    // Get compilation order
    const order = try mod_resolver.topologicalOrder(allocator);
    defer allocator.free(order);

    // Build module build-type map for codegen — lets import generation
    // distinguish lib targets (linked via build system) from source modules
    var module_builds = std.StringHashMapUnmanaged(module.BuildType){};
    defer module_builds.deinit(allocator);
    {
        var mbi = mod_resolver.modules.iterator();
        while (mbi.next()) |entry| {
            const bt = entry.value_ptr.build_type;
            if (bt != .none) {
                try module_builds.put(allocator, entry.key_ptr.*, bt);
            }
        }
    }

    // Load cached warnings for incremental builds
    var cached_warnings = try cache.loadWarnings(allocator);
    defer {
        for (cached_warnings.items) |w| {
            allocator.free(w.module);
            allocator.free(w.file);
            allocator.free(w.message);
        }
        cached_warnings.deinit(allocator);
    }

    // Track all warnings for saving at end
    var all_warnings: std.ArrayListUnmanaged(cache.CachedWarning) = .{};
    defer {
        for (all_warnings.items) |w| {
            allocator.free(w.module);
            allocator.free(w.file);
            allocator.free(w.message);
        }
        all_warnings.deinit(allocator);
    }

    // Accumulate declaration tables across modules for cross-module default arg resolution
    var all_module_decls = std.StringHashMap(*declarations.DeclTable).init(allocator);
    defer all_module_decls.deinit();
    var decl_collector_ptrs = std.ArrayListUnmanaged(*declarations.DeclCollector){};
    defer {
        for (decl_collector_ptrs.items) |dc| {
            dc.deinit();
            allocator.destroy(dc);
        }
        decl_collector_ptrs.deinit(allocator);
    }

    // Snapshot the interface hashes as they were at the start of this build.
    // Used to detect whether a dependency's interface changed during this build:
    // compare against comp_cache.interface_hashes (updated as each module is compiled).
    var prev_iface_hashes = std.StringHashMap(u64).init(allocator);
    defer prev_iface_hashes.deinit();
    {
        var it = comp_cache.interface_hashes.iterator();
        while (it.next()) |entry| {
            try prev_iface_hashes.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // Process each module in dependency order
    for (order) |mod_name| {
        const mod_ptr = mod_resolver.modules.getPtr(mod_name) orelse continue;
        const ast = mod_ptr.ast orelse continue;

        // Get source location map and file offsets for error reporting
        const locs_ptr: ?*const parser.LocMap = if (mod_ptr.locs) |*l| l else null;
        const file_offsets = mod_ptr.file_offsets;

        // ── Pass 4: Declaration Collection ────────────────────
        // Always collect declarations so cross-module type resolution works
        // (e.g., `use std::collections` needs collections DeclTable in all_module_decls)
        const decl_collector = try allocator.create(declarations.DeclCollector);
        decl_collector.* = declarations.DeclCollector.init(allocator, reporter);
        try decl_collector_ptrs.append(allocator, decl_collector);
        decl_collector.locs = locs_ptr;
        decl_collector.file_offsets = file_offsets;

        try decl_collector.collect(ast);
        if (reporter.hasErrors()) return null;
        try all_module_decls.put(mod_name, &decl_collector.table);

        // ── Validate 'main' as reserved name ─────────────────
        if (try passes.validateMainReserved(ast, mod_ptr, locs_ptr, file_offsets, reporter))
            return null;

        // Compute this module's current interface hash (after pass 4, before skip decision).
        // Stored here so it is available whether or not we recompile.
        const current_iface_hash = cache.hashInterface(&decl_collector.table);

        // Check if module needs recompilation (passes 5–12).
        // Interface-aware logic:
        //   a) If any own source file changed → must recompile.
        //   b) If own sources unchanged, check dependency interfaces: if any dep's
        //      interface hash changed (or has no cached hash), recompile.
        //   c) If nothing changed, skip passes 5–12.
        var own_source_changed = false;
        for (mod_ptr.files) |file| {
            if (try comp_cache.hasChanged(file)) {
                own_source_changed = true;
                break;
            }
        }

        var dep_interface_changed = false;
        if (!own_source_changed) {
            if (comp_cache.deps.get(mod_name)) |dep_list| {
                for (dep_list.items) |dep_name| {
                    // Check if dep's generated .zig file exists
                    const zig_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ cache.GENERATED_DIR, dep_name });
                    defer allocator.free(zig_path);
                    std.fs.cwd().access(zig_path, .{}) catch {
                        dep_interface_changed = true;
                        break;
                    };
                    // Compare dep's current interface hash (in comp_cache.interface_hashes,
                    // updated when the dep was processed this build) against the previous
                    // build's value (in prev_iface_hashes, snapshotted before the loop).
                    const prev_hash = prev_iface_hashes.get(dep_name);
                    const curr_hash = comp_cache.interface_hashes.get(dep_name);
                    if (prev_hash == null or curr_hash == null or prev_hash.? != curr_hash.?) {
                        dep_interface_changed = true;
                        break;
                    }
                }
            }
        }

        const needs_recompile = own_source_changed or dep_interface_changed;
        if (!needs_recompile) {
            // Store the current interface hash for this skipped module so that
            // downstream dependents can compare against it this build.
            const skip_iface_result = try comp_cache.interface_hashes.getOrPut(mod_name);
            if (!skip_iface_result.found_existing) {
                skip_iface_result.key_ptr.* = try allocator.dupe(u8, mod_name);
            }
            skip_iface_result.value_ptr.* = current_iface_hash;

            // Replay cached warnings for this module
            for (cached_warnings.items) |w| {
                if (std.mem.eql(u8, w.module, mod_name)) {
                    try reporter.warn(.{
                        .message = w.message,
                        .loc = .{ .file = w.file, .line = w.line, .col = 0 },
                    });
                    try all_warnings.append(allocator, .{
                        .module = try allocator.dupe(u8, w.module),
                        .file = try allocator.dupe(u8, w.file),
                        .line = w.line,
                        .message = try allocator.dupe(u8, w.message),
                    });
                }
            }
            continue;
        }

        // Snapshot warning count to capture new warnings from this module
        const warn_start = reporter.warnings.items.len;

        // ── Zig Module Source Copy ──────────────────────────────
        // Copy the original .zig file to .orh-cache/generated/{name}_zig.zig
        // so the build system can register it as a named module.
        // Skip std modules — already copied with import rewriting in the early pipeline.
        if (mod_ptr.is_zig_module) {
            if (mod_ptr.zig_source_path) |zig_src| {
                if (!std.mem.startsWith(u8, zig_src, cache.CACHE_DIR)) {
                    try cache.ensureGeneratedDir();
                    const zig_dst = try std.fmt.allocPrint(allocator, "{s}/{s}_zig.zig", .{ cache.GENERATED_DIR, mod_name });
                    defer allocator.free(zig_dst);

                    const content = try std.fs.cwd().readFileAlloc(allocator, zig_src, 1024 * 1024);
                    defer allocator.free(content);

                    const dst_file = try std.fs.cwd().createFile(zig_dst, .{});
                    defer dst_file.close();
                    try dst_file.writeAll(content);
                }
            }
        }

        // ── Passes 5–11: Type Resolution through Zig Code Generation ──
        _ = try passes.runSemanticAndCodegen(
            allocator, ast, mod_name, decl_collector, &all_module_decls,
            locs_ptr, file_offsets, &module_builds, reporter, cli,
            mod_ptr.is_zig_module,
        ) orelse return null;

        // Capture new warnings from this module for caching
        for (reporter.warnings.items[warn_start..]) |w| {
            try all_warnings.append(allocator, .{
                .module = try allocator.dupe(u8, mod_name),
                .file = if (w.loc) |loc| try allocator.dupe(u8, loc.file) else try allocator.dupe(u8, ""),
                .line = if (w.loc) |loc| loc.line else 0,
                .message = try allocator.dupe(u8, w.message),
            });
        }

        // Update content hash cache
        for (mod_ptr.files) |file| {
            try comp_cache.updateHash(file);
        }

        // Store the freshly computed interface hash for this module.
        // Downstream modules processed later in topological order will see this
        // updated value when checking dep_interface_changed.
        const iface_result = try comp_cache.interface_hashes.getOrPut(mod_name);
        if (!iface_result.found_existing) {
            iface_result.key_ptr.* = try allocator.dupe(u8, mod_name);
        }
        iface_result.value_ptr.* = current_iface_hash;
    }

    // Save updated cache
    try comp_cache.saveHashes();
    try comp_cache.saveDeps();
    try comp_cache.saveInterfaceHashes();
    try cache.saveWarnings(all_warnings.items);

    if (cli.command == .@"test") {
        var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.verbose) catch |err| {
            if (err == error.ZigNotFound) return null;
            return err;
        };
        defer runner.deinit();

        var last_binary_name: []const u8 = project_folder_name;
        var any_failed = false;
        var mod_it2 = mod_resolver.modules.iterator();
        while (mod_it2.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;
            var project_name: []const u8 = "";
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (meta.metadata.field == .name) {
                        if (meta.metadata.value.* == .string_literal) {
                            project_name = constants.stripQuotes(meta.metadata.value.string_literal);
                        }
                    }
                }
            }
            const binary_name2 = if (project_name.len > 0) project_name else mod.name;
            last_binary_name = binary_name2;
            // Collect module imports, zig module names, and cross-zig deps for test build.zig
            var test_zig_mods = std.ArrayListUnmanaged([]const u8){};
            defer test_zig_mods.deinit(allocator);
            var test_mod_imports = std.ArrayListUnmanaged([]const u8){};
            defer test_mod_imports.deinit(allocator);
            var test_zig_deps = std.ArrayListUnmanaged(zig_runner.ZigDep){};
            defer test_zig_deps.deinit(allocator);
            {
                var bmod_it = mod_resolver.modules.iterator();
                while (bmod_it.next()) |bmod_entry| {
                    const bmod = bmod_entry.value_ptr;
                    if (bmod.is_root) continue;
                    try test_mod_imports.append(allocator, bmod.name);
                    if (bmod.is_zig_module) {
                        try test_zig_mods.append(allocator, bmod.name);
                        for (bmod.imports) |sub_imp| {
                            const sub_mod = mod_resolver.modules.get(sub_imp) orelse continue;
                            if (sub_mod.is_zig_module) {
                                try test_zig_deps.append(allocator, .{
                                    .mod_name = bmod.name,
                                    .dep_name = sub_imp,
                                });
                            }
                        }
                    }
                }
            }
            const passed = try runner.runTests(mod.name, binary_name2, test_mod_imports.items, test_zig_mods.items, test_zig_deps.items);
            if (!passed) any_failed = true;
        }
        return if (!any_failed) try allocator.dupe(u8, last_binary_name) else null;
    }

    // ── Pass 12: Zig Compiler ──────────────────────────────────
    var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.verbose) catch |err| {
        if (err == error.ZigNotFound) return null;
        return err;
    };
    defer runner.deinit();

    // Default to native if no targets specified
    if (cli.targets.items.len == 0)
        try cli.targets.append(allocator, .native);

    const opt_str: []const u8 = switch (cli.optimize) {
        .fast => "fast",
        .small => "small",
        .debug => "",
    };

    // Build every root module (all those with a #build declaration).
    // A project can have multiple build targets — e.g. an exe + a dynamic lib.

    // Collect target descriptors for all root modules — unified path for single and multi-target.
    var multi_targets = std.ArrayListUnmanaged(zig_runner.MultiTarget){};
    defer multi_targets.deinit(allocator);
    // Temporary storage for lib_imports and link_libs slices
    var lib_import_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (lib_import_lists.items) |li| allocator.free(li);
        lib_import_lists.deinit(allocator);
    }
    var link_lib_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (link_lib_lists.items) |li| allocator.free(li);
        link_lib_lists.deinit(allocator);
    }
    var c_include_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (c_include_lists.items) |li| allocator.free(li);
        c_include_lists.deinit(allocator);
    }
    var c_source_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (c_source_lists.items) |li| {
            for (li) |s| allocator.free(s);
            allocator.free(li);
        }
        c_source_lists.deinit(allocator);
    }
    var include_dir_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (include_dir_lists.items) |li| {
            for (li) |s| allocator.free(s);
            allocator.free(li);
        }
        include_dir_lists.deinit(allocator);
    }
    var mod_import_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (mod_import_lists.items) |li| allocator.free(li);
        mod_import_lists.deinit(allocator);
    }
    var zig_dep_lists = std.ArrayListUnmanaged([]const zig_runner.ZigDep){};
    defer {
        for (zig_dep_lists.items) |s| allocator.free(s);
        zig_dep_lists.deinit(allocator);
    }

    var exe_binary_name: ?[]const u8 = null; // tracked for `orhon run`
    errdefer if (exe_binary_name) |n| allocator.free(n);

    // Collect a MultiTarget descriptor for each root module
    {
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;

            var build_type: module.BuildType = .exe;
            var project_name: []const u8 = "";
            var mt_version: ?[3]u64 = null;
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (meta.metadata.field == .build) {
                        if (meta.metadata.value.* == .identifier) {
                            build_type = module.parseBuildType(meta.metadata.value.identifier);
                        }
                    }
                    if (meta.metadata.field == .name) {
                        if (meta.metadata.value.* == .string_literal) {
                            project_name = constants.stripQuotes(meta.metadata.value.string_literal);
                        }
                    }
                    if (meta.metadata.field == .version) {
                        mt_version = module.extractVersion(meta.metadata.value);
                    }
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            if (build_type == .exe) {
                // Primary module (name matches folder) gets priority for orhon run
                if (std.mem.eql(u8, mod.name, project_folder_name)) {
                    if (exe_binary_name) |old| allocator.free(old);
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                } else if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            }

            // Transitive closure over imports: classify lib vs shared module imports
            var lib_imports = std.ArrayListUnmanaged([]const u8){};
            defer lib_imports.deinit(allocator);
            var mod_imports = std.ArrayListUnmanaged([]const u8){};
            defer mod_imports.deinit(allocator);
            var seen_imports = std.StringHashMapUnmanaged(void){};
            defer seen_imports.deinit(allocator);
            var mt_work_queue = std.ArrayListUnmanaged([]const u8){};
            defer mt_work_queue.deinit(allocator);
            for (mod.imports) |imp_name| try mt_work_queue.append(allocator, imp_name);
            while (mt_work_queue.pop()) |imp_name| {
                if (seen_imports.contains(imp_name)) continue;
                try seen_imports.put(allocator, imp_name, {});
                if (module_builds.get(imp_name)) |bt| {
                    if (bt == .static or bt == .dynamic) {
                        try lib_imports.append(allocator, imp_name);
                        continue;
                    }
                }
                const dep_mod = mod_resolver.modules.get(imp_name) orelse continue;
                if (dep_mod.is_root) continue;
                try mod_imports.append(allocator, imp_name);
                for (dep_mod.imports) |sub_imp| {
                    if (!seen_imports.contains(sub_imp)) {
                        try mt_work_queue.append(allocator, sub_imp);
                    }
                }
            }
            const lib_slice = try allocator.dupe([]const u8, lib_imports.items);
            try lib_import_lists.append(allocator, lib_slice);
            const mod_slice = try allocator.dupe([]const u8, mod_imports.items);
            try mod_import_lists.append(allocator, mod_slice);

            // Collect C dependency info from .zon configs
            var mt_link_libs: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_link_libs.deinit(allocator);
            var mt_c_includes: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_c_includes.deinit(allocator);
            var mt_c_sources: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_c_sources.deinit(allocator);
            var mt_include_dirs: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_include_dirs.deinit(allocator);
            var mt_needs_cpp = false;

            try mergeZonConfigs(allocator, mod.name, mod.imports, &zon_configs,
                &mt_link_libs, &mt_c_sources, &mt_include_dirs, &mt_needs_cpp);

            const link_slice = try allocator.dupe([]const u8, mt_link_libs.items);
            try link_lib_lists.append(allocator, link_slice);
            const c_include_slice = try allocator.dupe([]const u8, mt_c_includes.items);
            try c_include_lists.append(allocator, c_include_slice);
            const c_source_slice = try allocator.dupe([]const u8, mt_c_sources.items);
            try c_source_lists.append(allocator, c_source_slice);
            const include_dir_slice = try allocator.dupe([]const u8, mt_include_dirs.items);
            try include_dir_lists.append(allocator, include_dir_slice);

            // Build zig cross-dependency list: for each zig-backed module in this
            // target's imports, check if it imports other zig-backed modules.
            var zig_deps_list = std.ArrayListUnmanaged(zig_runner.ZigDep){};
            defer zig_deps_list.deinit(allocator);
            for (mod_imports.items) |imp_name| {
                const imp_mod = mod_resolver.modules.get(imp_name) orelse continue;
                if (!imp_mod.is_zig_module) continue;
                for (imp_mod.imports) |sub_imp| {
                    const sub_mod = mod_resolver.modules.get(sub_imp) orelse continue;
                    if (!sub_mod.is_zig_module) continue;
                    try zig_deps_list.append(allocator, .{
                        .mod_name = imp_name,
                        .dep_name = sub_imp,
                    });
                }
            }
            const zig_deps_slice = try allocator.dupe(zig_runner.ZigDep, zig_deps_list.items);
            try zig_dep_lists.append(allocator, zig_deps_slice);

            try multi_targets.append(allocator, .{
                .module_name = mod.name,
                .project_name = binary_name,
                .build_type = build_type,
                .lib_imports = lib_slice,
                .mod_imports = mod_slice,
                .version = mt_version,
                .link_libs = link_slice,
                .c_includes = c_include_slice,
                .c_source_files = c_source_slice,
                .needs_cpp = mt_needs_cpp,
                .include_dirs = include_dir_slice,
                .zig_deps = zig_deps_slice,
            });
        }
    }

    // Collect non-root zig-backed modules for named module registration
    var extra_zig_mods = std.ArrayListUnmanaged([]const u8){};
    defer extra_zig_mods.deinit(allocator);
    {
        var bmod_it = mod_resolver.modules.iterator();
        while (bmod_it.next()) |bmod_entry| {
            const bmod = bmod_entry.value_ptr;
            if (bmod.is_root) continue;
            if (bmod.is_zig_module) {
                try extra_zig_mods.append(allocator, bmod.name);
            }
        }
    }

    // Build all targets via unified multi-target path
    for (cli.targets.items) |build_target| {
        const target_str = build_target.toZigTriple();

        if (build_target == .zig) {
            try _commands.emitZigProject(allocator);
            continue;
        }

        const use_subfolder = cli.targets.items.len > 1;
        const built = try runner.buildAll(target_str, opt_str, multi_targets.items, extra_zig_mods.items);
        if (!built) return null;

        if (use_subfolder) {
            try _commands.moveArtifactsToSubfolder(allocator, build_target.folderName());
        }
    }

    // Generate interface files for lib targets
    for (multi_targets.items) |t| {
        if (t.build_type != .exe) {
            const mod = mod_resolver.modules.get(t.module_name) orelse continue;
            if (mod.ast) |ast| {
                try _interface.generateInterface(allocator, t.module_name, t.project_name, ast);
            }
        }
    }

    // Return exe name for `orhon run`; empty string signals lib-only success
    return exe_binary_name orelse try allocator.dupe(u8, "");
}

/// Merges .zon build configs from zig-backed modules into the accumulator lists.
/// Checks the module itself and all its imports against the zon_configs map.
/// Appends link, include, and source entries (deduplicating), and sets needs_cpp
/// when C++ source files are present.
fn mergeZonConfigs(
    allocator: std.mem.Allocator,
    mod_name: []const u8,
    mod_imports: [][]const u8,
    zon_configs: *const std.StringHashMapUnmanaged(zig_module.ZonConfig),
    link_libs: *std.ArrayListUnmanaged([]const u8),
    c_sources: *std.ArrayListUnmanaged([]const u8),
    include_dirs: *std.ArrayListUnmanaged([]const u8),
    needs_cpp: *bool,
) !void {
    // Helper to merge a single config
    const mergeOne = struct {
        fn run(
            alloc: std.mem.Allocator,
            config: zig_module.ZonConfig,
            libs: *std.ArrayListUnmanaged([]const u8),
            srcs: *std.ArrayListUnmanaged([]const u8),
            inc_dirs: *std.ArrayListUnmanaged([]const u8),
            cpp: *bool,
        ) !void {
            for (config.link) |lib| {
                if (!contains(libs.items, lib)) try libs.append(alloc, lib);
            }
            // .include paths are directories for addIncludePath, not header names.
            // Prefix with ../../ because zig build runs from .orh-cache/generated/.
            for (config.include) |inc| {
                const prefixed = try std.fmt.allocPrint(alloc, "../../{s}", .{inc});
                if (!contains(inc_dirs.items, prefixed)) {
                    try inc_dirs.append(alloc, prefixed);
                } else {
                    alloc.free(prefixed);
                }
            }
            // .source paths need ../../ prefix for the same reason.
            for (config.source) |src| {
                const prefixed = try std.fmt.allocPrint(alloc, "../../{s}", .{src});
                if (!contains(srcs.items, prefixed)) {
                    try srcs.append(alloc, prefixed);
                } else {
                    alloc.free(prefixed);
                }
                if (std.mem.endsWith(u8, src, ".cpp") or
                    std.mem.endsWith(u8, src, ".cc") or
                    std.mem.endsWith(u8, src, ".cxx"))
                {
                    cpp.* = true;
                }
            }
        }

        fn contains(slice: []const []const u8, needle: []const u8) bool {
            for (slice) |item| {
                if (std.mem.eql(u8, item, needle)) return true;
            }
            return false;
        }
    }.run;

    // Check the module itself
    if (zon_configs.get(mod_name)) |config| {
        try mergeOne(allocator, config, link_libs, c_sources, include_dirs, needs_cpp);
    }
    // Check all imports
    for (mod_imports) |imp_name| {
        if (zon_configs.get(imp_name)) |config| {
            try mergeOne(allocator, config, link_libs, c_sources, include_dirs, needs_cpp);
        }
    }
}

// Satellite modules
test {
    _ = build_helpers;
    _ = passes;
}
