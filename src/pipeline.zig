// pipeline.zig — Compilation pipeline orchestration (runPipeline)

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const module = @import("module.zig");
const declarations = @import("declarations.zig");
const resolver = @import("resolver.zig");
const ownership = @import("ownership.zig");
const borrow = @import("borrow.zig");
const thread_safety = @import("thread_safety.zig");
const propagation = @import("propagation.zig");
const sema = @import("sema.zig");
const mir = @import("mir/mir.zig");
const codegen = @import("codegen/codegen.zig");
const zig_runner = @import("zig_runner/zig_runner.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");
const peg = @import("peg.zig");
const _cli = @import("cli.zig");
const _std_bundle = @import("std_bundle.zig");
const _interface = @import("interface.zig");
const _commands = @import("commands.zig");

pub fn runPipeline(allocator: std.mem.Allocator, cli: *_cli.CliArgs, reporter: *errors.Reporter) !?[]const u8 {

    // Ensure embedded std files exist in .orh-cache/std/
    try _std_bundle.ensureStdFiles(allocator);

    // Copy internal bridges to generated dir — always available for all modules
    try cache.ensureGeneratedDir();
    {
        const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_str.zig", .{});
        defer file.close();
        try file.writeAll(_std_bundle.STR_ZIG);
    }
    {
        const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_collections.zig", .{});
        defer file.close();
        try file.writeAll(_std_bundle.COLLECTIONS_ZIG);
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

    if (reporter.hasErrors()) return null;

    // Check circular imports
    try mod_resolver.checkCircularImports();
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

    // Scan and parse any #dep directories declared in the root module
    try mod_resolver.scanAndParseDeps(allocator, cli.source_dir);
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
        // Check top-level declarations for misuse of the name "main"
        {
            const is_exe = mod_ptr.build_type == .exe;
            var has_func_main = false;


            for (ast.program.top_level) |node| {
                switch (node.*) {
                    .var_decl, .const_decl, .compt_decl => |v| {
                        if (std.mem.eql(u8, v.name, "main")) {
                            const msg = try std.fmt.allocPrint(allocator,
                                "'main' is reserved for the executable entry point", .{});
                            defer allocator.free(msg);
                            try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                        }
                    },
                    .struct_decl => |s| {
                        if (std.mem.eql(u8, s.name, "main")) {
                            const msg = try std.fmt.allocPrint(allocator,
                                "'main' is reserved for the executable entry point", .{});
                            defer allocator.free(msg);
                            try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                        }
                    },
                    .enum_decl => |e| {
                        if (std.mem.eql(u8, e.name, "main")) {
                            const msg = try std.fmt.allocPrint(allocator,
                                "'main' is reserved for the executable entry point", .{});
                            defer allocator.free(msg);
                            try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                        }
                    },
                    .blueprint_decl => |b| {
                        if (std.mem.eql(u8, b.name, "main")) {
                            const msg = try std.fmt.allocPrint(allocator,
                                "'main' is reserved for the executable entry point", .{});
                            defer allocator.free(msg);
                            try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                        }
                    },
                    .bitfield_decl => |bf| {
                        if (std.mem.eql(u8, bf.name, "main")) {
                            const msg = try std.fmt.allocPrint(allocator,
                                "'main' is reserved for the executable entry point", .{});
                            defer allocator.free(msg);
                            try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                        }
                    },
                    .func_decl => |f| {
                        if (std.mem.eql(u8, f.name, "main")) {
                            if (!is_exe) {
                                const msg = try std.fmt.allocPrint(allocator,
                                    "func main() is only allowed in executable modules", .{});
                                defer allocator.free(msg);
                                try reporter.report(.{ .message = msg, .loc = module.resolveNodeLoc(locs_ptr, file_offsets, node) });
                            } else {
                                has_func_main = true;
                            }
                        }
                    },
                    else => {},
                }
            }

            // Exe modules must have func main() in the anchor file
            if (is_exe and !has_func_main) {
                const msg = try std.fmt.allocPrint(allocator,
                    "executable module '{s}' requires func main() in anchor file", .{mod_name});
                defer allocator.free(msg);
                try reporter.report(.{ .message = msg });
            }
        }
        if (reporter.hasErrors()) return null;

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

        // ── Pass 5: Type Resolution ────────────────────────────
        var type_resolver = resolver.TypeResolver.init(allocator, &decl_collector.table, reporter);
        defer type_resolver.deinit();
        type_resolver.locs = locs_ptr;
        type_resolver.file_offsets = file_offsets;
        type_resolver.all_decls = &all_module_decls;

        try type_resolver.resolve(ast);
        if (reporter.hasErrors()) return null;

        // ── Shared context for validation passes 6–9 ───────────
        const sema_ctx = sema.SemanticContext{
            .allocator = allocator,
            .reporter = reporter,
            .decls = &decl_collector.table,
            .locs = locs_ptr,
            .file_offsets = file_offsets,
        };

        // ── Pass 6: Ownership Analysis ─────────────────────────
        var ownership_checker = ownership.OwnershipChecker.init(allocator, &sema_ctx);
        try ownership_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 7: Borrow Checking ────────────────────────────
        var borrow_checker = borrow.BorrowChecker.init(allocator, &sema_ctx);
        defer borrow_checker.deinit();
        try borrow_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 8: Thread Safety ──────────────────────────────
        var thread_checker = thread_safety.ThreadSafetyChecker.init(allocator, &sema_ctx);
        defer thread_checker.deinit();
        try thread_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 9: Error Propagation ──────────────────────────
        var prop_checker = propagation.PropagationChecker.init(allocator, &sema_ctx);
        try prop_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 10: MIR Annotation ─────────────────────────────
        var mir_annotator = mir.MirAnnotator.init(allocator, reporter, &decl_collector.table, &type_resolver.type_map);
        defer mir_annotator.deinit();
        mir_annotator.all_decls = &all_module_decls;

        try mir_annotator.annotate(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 10b: MIR Tree Lowering ───────────────────────
        var mir_lowerer = mir.MirLowerer.init(
            allocator,
            &mir_annotator.node_map,
            &mir_annotator.union_registry,
            &decl_collector.table,
            &mir_annotator.var_types,
        );
        defer mir_lowerer.deinit();
        const mir_root = try mir_lowerer.lower(ast);

        // ── Bridge Sidecar Copy ─────────────────────────────────
        // Validation already happened during module resolution (pass 3).
        // Here we copy the validated sidecar to the generated dir, fixing up any
        // `export fn` that lacks `pub` visibility so @import can resolve the symbol.
        if (mod_ptr.has_bridges) {
            if (mod_ptr.sidecar_path) |sidecar_src| {
                try cache.ensureGeneratedDir();
                const sidecar_dst = try std.fmt.allocPrint(allocator, "{s}/{s}_bridge.zig", .{ cache.GENERATED_DIR, mod_name });
                defer allocator.free(sidecar_dst);
                // Read sidecar content
                const content = try std.fs.cwd().readFileAlloc(allocator, sidecar_src, 1024 * 1024);
                defer allocator.free(content);
                // Ensure all `export fn` have pub visibility
                var result = std.ArrayListUnmanaged(u8){};
                defer result.deinit(allocator);
                var pos: usize = 0;
                const needle = "export fn";
                while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
                    // Check if already preceded by "pub "
                    const already_pub = idx >= 4 and std.mem.eql(u8, content[idx - 4 .. idx], "pub ");
                    // Append content up to (but not including) this occurrence
                    try result.appendSlice(allocator, content[pos..idx]);
                    if (!already_pub) {
                        try result.appendSlice(allocator, "pub ");
                    }
                    // Append "export fn" itself and advance past it
                    try result.appendSlice(allocator, needle);
                    pos = idx + needle.len;
                }
                try result.appendSlice(allocator, content[pos..]);
                // Write modified sidecar
                const dst_file = try std.fs.cwd().createFile(sidecar_dst, .{});
                defer dst_file.close();
                try dst_file.writeAll(result.items);
            }
        }
        if (reporter.hasErrors()) return null;

        // ── Pass 11: Zig Code Generation ───────────────────────
        const is_debug = cli.optimize == .debug;
        var cg = codegen.CodeGen.init(allocator, reporter, is_debug);
        defer cg.deinit();
        cg.decls = &decl_collector.table;
        cg.all_decls = &all_module_decls;
        cg.locs = locs_ptr;
        cg.file_offsets = file_offsets;
        cg.module_builds = &module_builds;
        cg.node_map = &mir_annotator.node_map;
        cg.union_registry = &mir_annotator.union_registry;
        cg.var_types = &mir_annotator.var_types;
        cg.const_ref_params = &mir_annotator.const_ref_params;
        cg.mir_root = mir_root;

        try cg.generate(ast, mod_name);
        if (reporter.hasErrors()) return null;

        // Write generated .zig file to cache
        try cache.writeGeneratedZig(mod_name, cg.getOutput(), allocator);

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
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                }
            }
            const binary_name2 = if (project_name.len > 0) project_name else mod.name;
            last_binary_name = binary_name2;
            // Collect bridge module names for test build.zig
            var test_bridge_mods = std.ArrayListUnmanaged([]const u8){};
            defer test_bridge_mods.deinit(allocator);
            {
                var bmod_it = mod_resolver.modules.iterator();
                while (bmod_it.next()) |bmod_entry| {
                    const bmod = bmod_entry.value_ptr;
                    if (bmod.has_bridges) {
                        try test_bridge_mods.append(allocator, bmod.name);
                    }
                }
            }
            const passed = try runner.runTests(mod.name, binary_name2, test_bridge_mods.items);
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

    // Count root modules and collect target descriptors
    var root_count: usize = 0;
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
        for (c_source_lists.items) |li| allocator.free(li);
        c_source_lists.deinit(allocator);
    }
    var mod_import_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (mod_import_lists.items) |li| allocator.free(li);
        mod_import_lists.deinit(allocator);
    }

    var exe_binary_name: ?[]const u8 = null; // tracked for `orhon run`

    {
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;
            root_count += 1;
        }
    }

    if (root_count > 1) {
        // Multi-target build: collect all targets, build once
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;

            var build_type: []const u8 = "exe";
            var project_name: []const u8 = "";
            var mt_version: ?[3]u64 = null;
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (std.mem.eql(u8, meta.metadata.field, "build")) {
                        if (meta.metadata.value.* == .identifier) {
                            build_type = meta.metadata.value.identifier;
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "version")) {
                        mt_version = module.extractVersion(meta.metadata.value);
                    }
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            if (std.mem.eql(u8, build_type, "exe")) {
                // Primary module (name matches folder) gets priority for orhon run
                if (std.mem.eql(u8, mod.name, project_folder_name)) {
                    if (exe_binary_name) |old| allocator.free(old);
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                } else if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            }

            // Find which of this module's imports are lib targets — deduplicate to
            // prevent multiple .orh files in the same module from adding the same
            // lib import multiple times (which would emit duplicate addImport calls).
            var lib_imports = std.ArrayListUnmanaged([]const u8){};
            defer lib_imports.deinit(allocator);
            var mod_imports = std.ArrayListUnmanaged([]const u8){};
            defer mod_imports.deinit(allocator);
            var seen_imports = std.StringHashMapUnmanaged(void){};
            defer seen_imports.deinit(allocator);
            for (mod.imports) |imp_name| {
                if (seen_imports.contains(imp_name)) continue;
                try seen_imports.put(allocator, imp_name, {});
                if (module_builds.get(imp_name)) |bt| {
                    if (bt == .static or bt == .dynamic) {
                        try lib_imports.append(allocator, imp_name);
                    }
                } else {
                    // Non-lib, non-root module — needs named module registration
                    const dep_mod = mod_resolver.modules.get(imp_name) orelse continue;
                    if (!dep_mod.is_root) {
                        try mod_imports.append(allocator, imp_name);
                    }
                }
            }
            const lib_slice = try allocator.dupe([]const u8, lib_imports.items);
            try lib_import_lists.append(allocator, lib_slice);
            const mod_slice = try allocator.dupe([]const u8, mod_imports.items);
            try mod_import_lists.append(allocator, mod_slice);

            // Collect #cimport metadata from this module and its imported modules.
            // One loop replaces the old separate #linkc / #cinclude / #csource / #linkcpp loops.
            // Per D-08: duplicate #cimport for the same library is a compile error.
            var mt_link_libs: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_link_libs.deinit(allocator);
            var mt_c_includes: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_c_includes.deinit(allocator);
            var mt_c_sources: std.ArrayListUnmanaged([]const u8) = .{};
            defer mt_c_sources.deinit(allocator);
            var mt_needs_cpp = false;

            // Registry maps lib name → module name for duplicate detection
            var cimport_registry = std.StringHashMapUnmanaged([]const u8){};
            defer cimport_registry.deinit(allocator);

            // Helper: collect from one AST
            const collectCimport = struct {
                fn run(
                    ast: *parser.Node,
                    mod_name_inner: []const u8,
                    alloc: std.mem.Allocator,
                    rep: *errors.Reporter,
                    registry: *std.StringHashMapUnmanaged([]const u8),
                    link_libs: *std.ArrayListUnmanaged([]const u8),
                    c_includes: *std.ArrayListUnmanaged([]const u8),
                    c_sources: *std.ArrayListUnmanaged([]const u8),
                    needs_cpp: *bool,
                ) !void {
                    for (ast.program.metadata) |meta| {
                        if (!std.mem.eql(u8, meta.metadata.field, "cimport")) continue;
                        if (meta.metadata.value.* != .string_literal) continue;
                        const raw = meta.metadata.value.string_literal;
                        const lib_name = if (raw.len >= 2 and raw[0] == '"')
                            raw[1 .. raw.len - 1]
                        else
                            raw;

                        // Split comma-separated library names and emit linkSystemLibrary for each (BLD-03)
                        var lib_segments = std.ArrayListUnmanaged([]const u8){};
                        defer lib_segments.deinit(alloc);
                        try splitCimportLibNames(alloc, lib_name, &lib_segments);
                        for (lib_segments.items) |seg| {
                            // Duplicate detection per individual library name (D-08 / CIMP-03)
                            if (registry.get(seg)) |existing_mod| {
                                const msg = try std.fmt.allocPrint(alloc,
                                    "duplicate #cimport \"{s}\" — already declared in module '{s}'",
                                    .{ seg, existing_mod });
                                defer alloc.free(msg);
                                try rep.report(.{ .message = msg });
                                continue;
                            }
                            try registry.put(alloc, seg, mod_name_inner);
                            try link_libs.append(alloc, seg);
                        }

                        // include: always required (D-06, validated earlier in declarations pass)
                        if (meta.metadata.cimport_include) |inc| {
                            var already = false;
                            for (c_includes.items) |h| {
                                if (std.mem.eql(u8, h, inc)) { already = true; break; }
                            }
                            if (!already) try c_includes.append(alloc, inc);
                        }

                        // source: optional
                        if (meta.metadata.cimport_source) |src| {
                            try c_sources.append(alloc, src);
                            if (std.mem.endsWith(u8, src, ".cpp") or
                                std.mem.endsWith(u8, src, ".cc") or
                                std.mem.endsWith(u8, src, ".cxx"))
                            {
                                needs_cpp.* = true;
                            }
                        }
                    }
                }
            }.run;

            if (mod.ast) |ast| {
                try collectCimport(ast, mod.name, allocator, reporter, &cimport_registry,
                    &mt_link_libs, &mt_c_includes, &mt_c_sources, &mt_needs_cpp);
            }
            // Also collect from non-root modules imported by this root module
            for (mod.imports) |imp_name| {
                const dep_mod = mod_resolver.modules.get(imp_name) orelse continue;
                if (dep_mod.is_root) continue;
                if (dep_mod.ast) |ast| {
                    try collectCimport(ast, dep_mod.name, allocator, reporter, &cimport_registry,
                        &mt_link_libs, &mt_c_includes, &mt_c_sources, &mt_needs_cpp);
                }
            }

            const link_slice = try allocator.dupe([]const u8, mt_link_libs.items);
            try link_lib_lists.append(allocator, link_slice);
            const c_include_slice = try allocator.dupe([]const u8, mt_c_includes.items);
            try c_include_lists.append(allocator, c_include_slice);
            const c_source_slice = try allocator.dupe([]const u8, mt_c_sources.items);
            try c_source_lists.append(allocator, c_source_slice);

            const mt_source_dir: ?[]const u8 = if (mod.sidecar_path) |sp|
                std.fs.path.dirname(sp)
            else
                null;
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
                .has_bridges = mod.has_bridges,
                .source_dir = mt_source_dir,
            });
        }

        // Collect non-root modules with bridges for named module registration
        var extra_bridge_mods = std.ArrayListUnmanaged([]const u8){};
        defer extra_bridge_mods.deinit(allocator);
        {
            var bmod_it = mod_resolver.modules.iterator();
            while (bmod_it.next()) |bmod_entry| {
                const bmod = bmod_entry.value_ptr;
                if (bmod.is_root) continue;
                if (bmod.has_bridges) {
                    try extra_bridge_mods.append(allocator, bmod.name);
                }
            }
        }

        for (cli.targets.items) |build_target| {
            const target_str = build_target.toZigTriple();

            // -zig target: copy generated Zig source to bin/zig/
            if (build_target == .zig) {
                try _commands.emitZigProject(allocator);
                continue;
            }

            const use_subfolder = cli.targets.items.len > 1;
            const built = try runner.buildAll(target_str, opt_str, multi_targets.items, extra_bridge_mods.items);
            if (!built) return null;

            // Move artifacts to target subfolder if multi-target
            if (use_subfolder) {
                try _commands.moveArtifactsToSubfolder(allocator, build_target.folderName());
            }
        }

        // Generate interface files for lib targets
        for (multi_targets.items) |t| {
            if (!std.mem.eql(u8, t.build_type, "exe")) {
                const mod = mod_resolver.modules.get(t.module_name) orelse continue;
                if (mod.ast) |ast| {
                    try _interface.generateInterface(allocator, t.module_name, t.project_name, ast);
                }
            }
        }
    } else {
        // Single-target build: use existing path (no behavior change)
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;

            var build_type: []const u8 = "exe";
            var project_name: []const u8 = "";
            var project_version: ?[3]u64 = null;
            var link_libs: std.ArrayListUnmanaged([]const u8) = .{};
            defer link_libs.deinit(allocator);
            var c_includes_st: std.ArrayListUnmanaged([]const u8) = .{};
            defer c_includes_st.deinit(allocator);
            var c_sources_st: std.ArrayListUnmanaged([]const u8) = .{};
            defer c_sources_st.deinit(allocator);
            var needs_cpp_st = false;

            // Collect build/name/version from root module only; collect #cimport from all modules.
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (std.mem.eql(u8, meta.metadata.field, "build")) {
                        if (meta.metadata.value.* == .identifier) {
                            build_type = meta.metadata.value.identifier;
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "version")) {
                        project_version = module.extractVersion(meta.metadata.value);
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "cimport")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            const lib_name = if (raw.len >= 2 and raw[0] == '"')
                                raw[1 .. raw.len - 1]
                            else
                                raw;
                            // Split comma-separated library names and emit linkSystemLibrary for each (BLD-03)
                            var lib_segments = std.ArrayListUnmanaged([]const u8){};
                            defer lib_segments.deinit(allocator);
                            try splitCimportLibNames(allocator, lib_name, &lib_segments);
                            for (lib_segments.items) |seg| {
                                try link_libs.append(allocator, seg);
                            }
                            if (meta.metadata.cimport_include) |inc| {
                                try c_includes_st.append(allocator, inc);
                            }
                            if (meta.metadata.cimport_source) |src| {
                                try c_sources_st.append(allocator, src);
                                if (std.mem.endsWith(u8, src, ".cpp") or
                                    std.mem.endsWith(u8, src, ".cc") or
                                    std.mem.endsWith(u8, src, ".cxx"))
                                {
                                    needs_cpp_st = true;
                                }
                            }
                        }
                    }
                }
            }

            // Collect #cimport from all non-root modules (bridge modules declare their C deps).
            var all_mod_it = mod_resolver.modules.iterator();
            while (all_mod_it.next()) |all_entry| {
                const dep_mod = all_entry.value_ptr;
                if (dep_mod.is_root) continue;
                if (dep_mod.ast) |ast| {
                    for (ast.program.metadata) |meta| {
                        if (std.mem.eql(u8, meta.metadata.field, "cimport")) {
                            if (meta.metadata.value.* == .string_literal) {
                                const raw = meta.metadata.value.string_literal;
                                const lib_name = if (raw.len >= 2 and raw[0] == '"')
                                    raw[1 .. raw.len - 1]
                                else
                                    raw;
                                // Split comma-separated library names and emit linkSystemLibrary for each (BLD-03)
                                var lib_segments = std.ArrayListUnmanaged([]const u8){};
                                defer lib_segments.deinit(allocator);
                                try splitCimportLibNames(allocator, lib_name, &lib_segments);
                                for (lib_segments.items) |seg| {
                                    var lib_already = false;
                                    for (link_libs.items) |existing| {
                                        if (std.mem.eql(u8, existing, seg)) { lib_already = true; break; }
                                    }
                                    if (!lib_already) try link_libs.append(allocator, seg);
                                }
                                if (meta.metadata.cimport_include) |inc| {
                                    var inc_already = false;
                                    for (c_includes_st.items) |existing| {
                                        if (std.mem.eql(u8, existing, inc)) { inc_already = true; break; }
                                    }
                                    if (!inc_already) try c_includes_st.append(allocator, inc);
                                }
                                if (meta.metadata.cimport_source) |src| {
                                    try c_sources_st.append(allocator, src);
                                    if (std.mem.endsWith(u8, src, ".cpp") or
                                        std.mem.endsWith(u8, src, ".cc") or
                                        std.mem.endsWith(u8, src, ".cxx"))
                                    {
                                        needs_cpp_st = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            // Collect all modules with bridges for named module registration
            var bridge_mods = std.ArrayListUnmanaged([]const u8){};
            defer bridge_mods.deinit(allocator);
            if (mod.has_bridges) {
                try bridge_mods.append(allocator, mod.name);
            }
            {
                var bmod_it = mod_resolver.modules.iterator();
                while (bmod_it.next()) |bmod_entry| {
                    const bmod = bmod_entry.value_ptr;
                    if (bmod.is_root) continue;
                    if (bmod.has_bridges) {
                        try bridge_mods.append(allocator, bmod.name);
                    }
                }
            }

            // Collect shared (non-root, non-lib) modules imported by this root
            var shared_mods = std.ArrayListUnmanaged([]const u8){};
            defer shared_mods.deinit(allocator);
            for (mod.imports) |imp_name| {
                const dep_mod = mod_resolver.modules.get(imp_name) orelse continue;
                if (dep_mod.is_root) continue;
                if (module_builds.get(imp_name)) |bt| {
                    if (bt == .static or bt == .dynamic) continue;
                }
                try shared_mods.append(allocator, imp_name);
            }

            const single_source_dir: ?[]const u8 = if (mod.sidecar_path) |sp|
                std.fs.path.dirname(sp)
            else
                null;
            try runner.generateBuildZig(mod.name, build_type, binary_name, project_version, link_libs.items, bridge_mods.items, shared_mods.items, c_includes_st.items, c_sources_st.items, needs_cpp_st, single_source_dir);

            for (cli.targets.items) |build_target| {
                const target_str = build_target.toZigTriple();

                if (build_target == .zig) {
                    try _commands.emitZigProject(allocator);
                    continue;
                }

                const use_subfolder = cli.targets.items.len > 1;
                const built = if (std.mem.eql(u8, build_type, "exe"))
                    try runner.build(target_str, opt_str, mod.name, binary_name)
                else
                    try runner.buildLib(target_str, opt_str, mod.name, binary_name, build_type);
                if (!built) return null;

                if (use_subfolder) {
                    try _commands.moveArtifactsToSubfolder(allocator, build_target.folderName());
                }
            }

            if (std.mem.eql(u8, build_type, "exe")) {
                // Primary module (name matches folder) gets priority for orhon run
                if (std.mem.eql(u8, mod.name, project_folder_name)) {
                    if (exe_binary_name) |old| allocator.free(old);
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                } else if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            } else {
                if (mod.ast) |ast| {
                    try _interface.generateInterface(allocator, mod.name, binary_name, ast);
                }
            }
        }
    }

    // Return exe name for `orhon run`; empty string signals lib-only success
    return exe_binary_name orelse try allocator.dupe(u8, "");
}

/// Collect the names of all bridge declarations in an AST.
/// Returns an allocated slice of duped name strings, or an error.
/// Caller must free each name and the slice itself.
fn collectBridgeNames(ast: *parser.Node, allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    if (ast.* != .program) return names.toOwnedSlice(allocator);
    for (ast.program.top_level) |node| {
        switch (node.*) {
            .func_decl => |f| {
                if (f.context == .bridge) try names.append(allocator, try allocator.dupe(u8, f.name));
            },
            .const_decl => |v| {
                if (v.is_bridge) try names.append(allocator, try allocator.dupe(u8, v.name));
            },
            .var_decl => |v| {
                if (v.is_bridge) try names.append(allocator, try allocator.dupe(u8, v.name));
            },
            .struct_decl => |s| {
                if (s.is_bridge) {
                    try names.append(allocator, try allocator.dupe(u8, s.name));
                } else {
                    for (s.members) |m| {
                        if (m.* == .func_decl and m.func_decl.context == .bridge)
                            try names.append(allocator, try allocator.dupe(u8, m.func_decl.name));
                    }
                }
            },
            else => {},
        }
    }
    return names.toOwnedSlice(allocator);
}

/// Split a #cimport `name` field value on commas, trim whitespace from each segment,
/// and append non-empty segments to `out`. Supports both single and multi-library names.
/// Segments are slices into `name` — no allocation is performed.
/// Example: "vulkan, SDL3" → ["vulkan", "SDL3"]
fn splitCimportLibNames(
    allocator: std.mem.Allocator,
    name: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var it = std.mem.splitScalar(u8, name, ',');
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len > 0) try out.append(allocator, trimmed);
    }
}

// ============================================================
// TESTS — pipeline and codegen integration tests
// ============================================================

test "pipeline - imports all passes" {
    // Verify all pipeline modules are importable
    _ = lexer;
    _ = parser;
    _ = module;
    _ = declarations;
    _ = resolver;
    _ = ownership;
    _ = borrow;
    _ = thread_safety;
    _ = propagation;
    _ = mir;
    _ = codegen;
    _ = zig_runner;
    _ = errors;
    _ = cache;
    _ = builtins;
    try std.testing.expect(true);
}

test "full pipeline - hello world" {
    const alloc = std.testing.allocator;

    const source =
        \\module testmod
        \\
        \\func main() void {
        \\    var x: i32 = 42
        \\}
        \\
    ;

    // Lex
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    // Parse (PEG engine)
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var grammar = try peg.loadGrammar(alloc);
    defer grammar.deinit();
    var cap_engine = peg.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
    defer cap_engine.deinit();
    const cap = cap_engine.captureProgram() orelse return error.ParseError;
    var build_result = try peg.buildAST(&cap, tokens.items, alloc);
    defer build_result.ctx.deinit();
    const ast = build_result.node;
    try std.testing.expect(!reporter.hasErrors());

    // Declaration pass
    var decl_collector = declarations.DeclCollector.init(alloc, &reporter);
    defer decl_collector.deinit();
    try decl_collector.collect(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Type resolution
    var type_resolver = resolver.TypeResolver.init(alloc, &decl_collector.table, &reporter);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Shared context for validation passes
    const sema_ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &decl_collector.table,
        .locs = null,
        .file_offsets = &.{},
    };

    // Ownership check
    var ownership_checker = ownership.OwnershipChecker.init(alloc, &sema_ctx);
    try ownership_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Borrow check
    var borrow_checker = borrow.BorrowChecker.init(alloc, &sema_ctx);
    defer borrow_checker.deinit();
    try borrow_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Thread safety
    var thread_checker = thread_safety.ThreadSafetyChecker.init(alloc, &sema_ctx);
    defer thread_checker.deinit();
    try thread_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Propagation
    var prop_checker = propagation.PropagationChecker.init(alloc, &sema_ctx);
    try prop_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, &reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    try std.testing.expect(!reporter.hasErrors());
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);

    // Codegen
    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
    try cg.generate(ast, "testmod");
    try std.testing.expect(!reporter.hasErrors());

    const output = cg.getOutput();
    try std.testing.expect(output.len > 0);

    // Verify the generated Zig output contains the expected structure
    try std.testing.expect(std.mem.indexOf(u8, output, "// generated from module testmod") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x: i32 = 42;") != null);
}

test "codegen - var never reassigned becomes const" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const output = try codegenSource(alloc,
        \\module testmod
        \\
        \\func main() void {
        \\    var a: i32 = 1
        \\    var b: i32 = 2
        \\    b = 3
        \\}
        \\
    , &reporter);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "const a: i32 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var b: i32 = 2;") != null);
}

/// Full pipeline test helper: source → lex → parse → declarations → resolve → MIR → codegen → Zig.
/// Returns owned output slice — caller must free.
fn codegenSource(alloc: std.mem.Allocator, source: []const u8, reporter: *errors.Reporter) ![]const u8 {
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var grammar = try peg.loadGrammar(alloc);
    defer grammar.deinit();
    var cap_engine = peg.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
    defer cap_engine.deinit();
    const cap = cap_engine.captureProgram() orelse return error.ParseError;
    var build_result = try peg.buildAST(&cap, tokens.items, alloc);
    defer build_result.ctx.deinit();
    const ast = build_result.node;
    var decl_collector = declarations.DeclCollector.init(alloc, reporter);
    defer decl_collector.deinit();
    try decl_collector.collect(ast);
    // Type resolution
    var type_resolver = resolver.TypeResolver.init(alloc, &decl_collector.table, reporter);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);
    // Codegen with full MIR context
    var cg = codegen.CodeGen.init(alloc, reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
    try cg.generate(ast, "testmod");
    return try alloc.dupe(u8, cg.getOutput());
}

test "codegen - struct with method" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\pub struct Vec2 {
        \\    pub x: f32
        \\    pub y: f32
        \\    pub func new(x: f32, y: f32) Vec2 {
        \\        return Vec2(x, y)
        \\    }
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Vec2 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "y: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn new(") != null);
}

test "codegen - enum with match" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\enum(u8) Color {
        \\    Red
        \\    Green
        \\    Blue
        \\}
        \\func describe(c: Color) void {
        \\    match c {
        \\        Red => {}
        \\        else => {}
        \\    }
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Color = enum") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "switch") != null);
}

test "codegen - bitfield declaration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\bitfield(u8) Perms {
        \\    Read
        \\    Write
        \\    Execute
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Write") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Execute") != null);
}

test "splitCimportLibNames - single name" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "SDL3", &result);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("SDL3", result.items[0]);
}

test "splitCimportLibNames - two names with space" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "vulkan, SDL3", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - two names no spaces" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "vulkan,SDL3", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - extra whitespace" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, " vulkan , SDL3 ", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - empty segments skipped" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "a,,b", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("a", result.items[0]);
    try std.testing.expectEqualStrings("b", result.items[1]);
}
