// module_parse.zig — Module parsing and dependency scanning
// Satellite of module.zig — all functions take *Resolver as first parameter.

const std = @import("std");
const module = @import("module.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");
const constants = @import("constants.zig");
const peg_mod = @import("peg.zig");

const Resolver = module.Resolver;
const Module = module.Module;
const FileOffset = module.FileOffset;

/// Parse all modules and extract their imports
pub fn parseModules(self: *Resolver, alloc: std.mem.Allocator) !void {
    // Collect module names first — we can't iterate the HashMap while mutating it
    // (getOrPut during import scanning can trigger a rehash, invalidating pointers).
    var names_to_parse = std.ArrayListUnmanaged([]const u8){};
    defer names_to_parse.deinit(self.allocator);
    {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ast == null) {
                try names_to_parse.append(self.allocator, entry.key_ptr.*);
            }
        }
    }

    for (names_to_parse.items) |mod_name| {
        var mod = self.modules.getPtr(mod_name) orelse continue;

        // Skip if already parsed (another module's import scan may have triggered parsing)
        if (mod.ast != null) continue;

        // Create the module arena FIRST — the source buffer and AST both
        // live here, so all token text slices in the AST remain valid.
        mod.ast_arena = std.heap.ArenaAllocator.init(alloc);
        const arena_alloc = mod.ast_arena.?.allocator();
        errdefer {
            if (mod.ast_arena) |*a| a.deinit();
            mod.ast_arena = null;
        }

        // Combine all files into one source buffer — allocated into the arena
        // so token.text slices (which point into this buffer) stay valid for
        // the lifetime of the AST.
        // The first file keeps its `module X` declaration; subsequent files
        // have their `module X` line stripped to avoid duplicate declarations.
        var combined = std.ArrayListUnmanaged(u8){};
        var offsets = std.ArrayListUnmanaged(FileOffset){};
        var current_line: usize = 1; // 1-based line tracking
        for (mod.files, 0..) |file_path, file_idx| {
            // Record where this file starts in the combined buffer
            try offsets.append(arena_alloc, .{ .file = file_path, .start_line = current_line, .original_start = 1 });
            const file = try std.fs.cwd().openFile(file_path, .{});
            defer file.close();
            const content = try file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024);

            // Non-anchor files must not contain metadata
            if (file_idx > 0) {
                var lines_iter = std.mem.splitSequence(u8, content, "\n");
                while (lines_iter.next()) |line| {
                    const trimmed_line = std.mem.trimLeft(u8, line, " \t");
                    if (trimmed_line.len > 0 and trimmed_line[0] == '#' and
                        !std.mem.startsWith(u8, trimmed_line, "//"))
                    {
                        try self.reporter.reportFmt(null, "metadata (#{s}...) only allowed in anchor file '{s}.orh', found in '{s}'",
                            .{ trimmed_line[1..@min(trimmed_line.len, 10)], mod_name, file_path });
                        break;
                    }
                }
            }

            const len_before = combined.items.len;
            if (file_idx > 0) {
                // Skip the `module X` line from non-first files
                const trimmed = std.mem.trimLeft(u8, content, " \t");
                if (std.mem.startsWith(u8, trimmed, module.MODULE_KEYWORD)) {
                    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
                        try combined.appendSlice(arena_alloc, trimmed[nl + 1 ..]);
                        // The module line was stripped, so the first line in the
                        // combined buffer corresponds to line 2 of the original file
                        offsets.items[file_idx].original_start = 2;
                    } else {
                        // File only has the module line — nothing to add
                    }
                } else {
                    try combined.appendSlice(arena_alloc, content);
                }
            } else {
                try combined.appendSlice(arena_alloc, content);
            }
            try combined.append(arena_alloc, '\n');

            // Count newlines in appended content to track line position
            const appended = combined.items[len_before..];
            for (appended) |c| {
                if (c == '\n') current_line += 1;
            }
        }

        // Store file offset map for error reporting
        mod.file_offsets = offsets.items;

        // Lex — token list is temporary (freed after parsing), but token.text
        // slices point into combined which lives in the arena. Safe.
        var lex = lexer.Lexer.init(combined.items);
        var tokens = try lex.tokenize(alloc);
        defer tokens.deinit(alloc);

        // PEG engine: grammar validation + capture + AST building
        var grammar = peg_mod.loadGrammar(alloc) catch {
            try self.reporter.report(.{ .message = "internal: could not load PEG grammar" });
            continue;
        };
        defer grammar.deinit();

        // Validate and capture
        var engine = peg_mod.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
        defer engine.deinit();

        const cap = engine.captureProgram() orelse {
            // Parse failed — report error with location from validation engine
            var val_engine = peg_mod.Engine.init(&grammar, tokens.items, alloc);
            defer val_engine.deinit();
            _ = val_engine.matchRule("program", 0);
            const err_info = val_engine.getError();
            const msg = if (err_info.found_kind == .kw_var) blk: {
                // Check if next token is & — common mistake: var &T instead of mut& T
                const next_pos = err_info.pos + 1;
                if (next_pos < tokens.items.len and tokens.items[next_pos].kind == .ampersand)
                    break :blk try std.fmt.allocPrint(alloc, "var &T is not valid — use mut& T for mutable references", .{})
                else
                    break :blk try std.fmt.allocPrint(alloc, "unexpected '{s}'", .{err_info.found});
            } else if (err_info.label) |label| blk: {
                // Human-readable label from grammar annotation
                break :blk try std.fmt.allocPrint(alloc, "expected {s}, found '{s}'", .{ label, err_info.found });
            } else if (err_info.expected_set.count() > 1) blk: {
                break :blk try module.formatExpectedSet(alloc, err_info.expected_set);
            } else try std.fmt.allocPrint(alloc, "unexpected '{s}'", .{err_info.found});
            defer alloc.free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = err_info.line, .col = err_info.col },
            });
            if (mod.ast_arena) |*a| a.deinit();
            mod.ast_arena = null;
            mod.locs = null;
            continue;
        };

        // Build AST into the module's arena
        const build_result = peg_mod.buildASTWithArena(&cap, tokens.items, mod.ast_arena.?, alloc) catch {
            try self.reporter.report(.{ .message = "internal: AST builder failed" });
            if (mod.ast_arena) |*a| a.deinit();
            mod.ast_arena = null;
            mod.locs = null;
            continue;
        };

        // Move arena and locs into module
        mod.ast_arena = build_result.ctx.arena;
        mod.ast = build_result.node;
        mod.locs = build_result.ctx.locs;

        // Report syntax errors from error recovery (skipped tokens)
        for (build_result.ctx.syntax_errors.items) |err| {
            try self.reporter.report(.{
                .message = err.message,
                .loc = .{ .file = "", .line = err.line, .col = err.col },
            });
        }

        // Extract imports — scan scoped ones from std/ or global/
        var imports: std.ArrayListUnmanaged([]const u8) = .{};
        for (build_result.node.program.imports) |imp| {
            const decl = imp.import_decl;
            if (decl.is_c_header) continue;

            if (decl.scope) |sc| {
                // std::mem is a built-in compiler module — no .orh file needed
                if (std.mem.eql(u8, sc, "std") and std.mem.eql(u8, decl.path, "mem")) continue;

                // Only std:: imports are supported
                if (!std.mem.eql(u8, sc, "std")) {
                    try self.reporter.reportFmt(null, "unknown import scope '{s}' — only 'std' is supported", .{sc});
                    continue;
                }

                // std:: resolves from .orh-cache/std/ (embedded in compiler)
                const scope_dir = try std.fs.path.join(self.allocator, &.{ cache.CACHE_DIR, "std" });
                defer self.allocator.free(scope_dir);

                const file_path = try std.fmt.allocPrint(self.allocator,
                    "{s}/{s}.orh", .{ scope_dir, decl.path });

                // Check the .orh file exists
                std.fs.cwd().access(file_path, .{}) catch {
                    try self.reporter.reportFmt(null, "module '{s}::{s}' not found",
                        .{ sc, decl.path });
                    self.allocator.free(file_path);
                    continue;
                };

                // Add to the file map so it gets parsed and compiled
                const imp_mod_name = try self.allocator.dupe(u8, decl.path);
                const result = try self.modules.getOrPut(imp_mod_name);
                if (!result.found_existing) {
                    result.key_ptr.* = imp_mod_name;

                    // Scan std directory for additional files declaring the same module
                    var file_list = std.ArrayListUnmanaged([]const u8){};
                    try file_list.append(self.allocator, file_path); // anchor first

                    const anchor_basename = try std.fmt.allocPrint(self.allocator, "{s}.orh", .{decl.path});
                    defer self.allocator.free(anchor_basename);

                    var std_dir = std.fs.cwd().openDir(scope_dir, .{ .iterate = true }) catch null;
                    if (std_dir) |*sd| {
                        defer sd.close();
                        var dir_iter = sd.iterate();
                        while (try dir_iter.next()) |dir_entry| {
                            if (dir_entry.kind != .file) continue;
                            if (!std.mem.endsWith(u8, dir_entry.name, ".orh")) continue;
                            if (std.mem.eql(u8, dir_entry.name, anchor_basename)) continue;
                            // Skip internal files
                            if (dir_entry.name[0] == '_') continue;

                            const extra_path = try std.fmt.allocPrint(self.allocator,
                                "{s}/{s}", .{ scope_dir, dir_entry.name });
                            const extra_mod = try self.readModuleName(extra_path) orelse {
                                self.allocator.free(extra_path);
                                continue;
                            };
                            defer self.allocator.free(extra_mod);

                            if (std.mem.eql(u8, extra_mod, decl.path)) {
                                try file_list.append(self.allocator, extra_path);
                            } else {
                                self.allocator.free(extra_path);
                            }
                        }
                    }

                    const files = try file_list.toOwnedSlice(self.allocator);
                    result.value_ptr.* = .{
                        .name = imp_mod_name,
                        .files = files,
                        .imports = &.{},
                        .imports_owned = false,
                        .is_root = false,
                        .build_type = .none,
                        .ast = null,
                        .ast_arena = null,
                        .locs = null,
                        .file_offsets = &.{},
                    };
                } else {
                    self.allocator.free(imp_mod_name);
                    self.allocator.free(file_path);
                }
                try imports.append(self.allocator, try self.allocator.dupe(u8, decl.path));
            } else {
                // Project-local import — file must exist in src/
                try imports.append(self.allocator, try self.allocator.dupe(u8, decl.path));
            }
        }
        // Re-fetch mod pointer — getOrPut during import scanning may have rehashed the map
        mod = self.modules.getPtr(mod_name) orelse continue;
        // Free previous imports if owned (from a prior parse pass)
        if (mod.imports_owned) {
            for (mod.imports) |imp| self.allocator.free(imp);
            self.allocator.free(mod.imports);
        }
        if (imports.items.len > 0) {
            mod.imports = try imports.toOwnedSlice(self.allocator);
            mod.imports_owned = true;
        } else {
            imports.deinit(self.allocator);
            mod.imports = &.{};
            mod.imports_owned = false;
        }

        // Check if root module (has build declaration in metadata)
        for (build_result.node.program.metadata) |meta| {
            if (std.mem.eql(u8, meta.metadata.field, "build")) {
                mod.is_root = true;
                if (meta.metadata.value.* == .identifier) {
                    const val = meta.metadata.value.identifier;
                    if (std.mem.eql(u8, val, "static")) {
                        mod.build_type = .static;
                    } else if (std.mem.eql(u8, val, "dynamic")) {
                        mod.build_type = .dynamic;
                    } else {
                        mod.build_type = .exe;
                    }
                } else {
                    mod.build_type = .exe;
                }
            }
        }

    }

    // Validate exe layout — exe modules with anchor file directly in src/ must
    // match the project folder name (only the primary module gets #build = exe at root)
    const project_folder = blk: {
        const cwd_path = try std.fs.cwd().realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd_path);
        break :blk try self.allocator.dupe(u8, std.fs.path.basename(cwd_path));
    };
    defer self.allocator.free(project_folder);

    var exe_it = self.modules.iterator();
    while (exe_it.next()) |entry| {
        const mod = entry.value_ptr;
        if (mod.build_type != .exe) continue;

        // Check if anchor file is directly in src/ (not in a subdirectory)
        if (mod.files.len > 0) {
            const anchor = mod.files[0];
            const dir = std.fs.path.dirname(anchor) orelse "";
            // Anchor is directly in src/ if its directory is exactly "src"
            if (std.mem.eql(u8, dir, "src")) {
                if (!std.mem.eql(u8, entry.key_ptr.*, project_folder)) {
                    try self.reporter.reportFmt(.{ .file = anchor, .line = 1, .col = 1 }, "only the primary module '{s}' may use #build = exe in src/ — move '{s}' to a subdirectory",
                        .{ project_folder, entry.key_ptr.* });
                }
            }
        }
    }
}

/// Process #dep declarations in the root module:
/// scan each dep directory, parse its modules, and validate versions.
/// Call this after parseModules() and before validateImports().
pub fn scanAndParseDeps(self: *Resolver, alloc: std.mem.Allocator, project_dir: []const u8) !void {
    // Find the root module's AST to read #dep entries
    var root_ast: ?*parser.Node = null;
    var mod_it = self.modules.iterator();
    while (mod_it.next()) |entry| {
        if (entry.value_ptr.is_root) {
            root_ast = entry.value_ptr.ast;
            break;
        }
    }
    const ast = root_ast orelse return; // no root yet — nothing to do

    for (ast.program.metadata) |meta| {
        if (!std.mem.eql(u8, meta.metadata.field, "dep")) continue;

        // Extract the dep path string
        const path_node = meta.metadata.value;
        if (path_node.* != .string_literal) continue;
        const raw = path_node.string_literal;
        const dep_path_rel = if (raw.len >= 2 and raw[0] == '"')
            raw[1 .. raw.len - 1]
        else
            raw;

        // Resolve relative to project dir
        const dep_path = if (std.fs.path.isAbsolute(dep_path_rel))
            try alloc.dupe(u8, dep_path_rel)
        else
            try std.fs.path.join(alloc, &.{ project_dir, dep_path_rel });
        defer alloc.free(dep_path);

        // Verify the dep directory exists
        std.fs.cwd().access(dep_path, .{}) catch {
            try self.reporter.reportFmt(null, "#dep: directory '{s}' not found", .{dep_path_rel});
            continue;
        };

        // Scan the dep directory — adds its modules to self.modules
        try self.scanDirectory(dep_path);
        if (self.reporter.hasErrors()) continue;

        // Parse any newly added (unparsed) dep modules
        try parseModules(self, alloc);
        if (self.reporter.hasErrors()) continue;

        // Version validation: if #dep carried a version requirement,
        // find the dep's root module and compare versions.
        const required = meta.metadata.extra; // ?*Node — Version(x,y,z) or null
        if (required == null) continue;

        // Find the dep's root module (the one with #build in the dep dir)
        var dep_root: ?*parser.Node = null;
        var dep_root_name: []const u8 = "";
        var search_it = self.modules.iterator();
        while (search_it.next()) |entry| {
            const search_mod = entry.value_ptr;
            // Only consider modules whose files live under dep_path
            if (search_mod.files.len == 0) continue;
            if (!std.mem.startsWith(u8, search_mod.files[0], dep_path)) continue;
            if (!search_mod.is_root) continue;
            dep_root = search_mod.ast;
            dep_root_name = search_mod.name;
            break;
        }

        const dep_ast = dep_root orelse continue;

        // Extract dep's declared version from #version = Version(x,y,z)
        var dep_ver: ?*parser.Node = null;
        for (dep_ast.program.metadata) |dmeta| {
            if (std.mem.eql(u8, dmeta.metadata.field, "version")) {
                dep_ver = dmeta.metadata.value;
                break;
            }
        }

        const actual = dep_ver orelse continue;

        const req = module.extractVersion(required.?) orelse continue;
        const act = module.extractVersion(actual) orelse continue;

        // act < req → error; act > req → warn
        const cmp = module.compareVersions(act, req);
        if (cmp < 0) {
            try self.reporter.reportFmt(null, "#dep '{s}': requires version {d}.{d}.{d} but found {d}.{d}.{d}",
                .{ dep_path_rel, req[0], req[1], req[2], act[0], act[1], act[2] });
        } else if (cmp > 0) {
            const msg = try std.fmt.allocPrint(alloc,
                "#dep '{s}': expected version {d}.{d}.{d}, found newer {d}.{d}.{d} — ok",
                .{ dep_path_rel, req[0], req[1], req[2], act[0], act[1], act[2] });
            defer alloc.free(msg);
            try self.reporter.warn(.{ .message = msg });
        }
    }
}
