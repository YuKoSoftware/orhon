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

/// Parse all modules and extract their imports.
/// Uses an iterative worklist: parse a module, discover its imports, add newly-
/// discovered modules to the worklist, repeat until empty. This handles transitive
/// dependencies at any depth — no pre-scan or second-pass needed.
pub fn parseModules(self: *Resolver, alloc: std.mem.Allocator) !void {
    // Worklist of module names to parse. Grows when import scanning discovers
    // new modules (e.g. std modules referenced by other std modules).
    var worklist = std.ArrayListUnmanaged([]const u8){};
    defer worklist.deinit(self.allocator);
    {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ast == null) {
                try worklist.append(self.allocator, entry.key_ptr.*);
            }
        }
    }

    while (worklist.items.len > 0) {
        const mod_name = worklist.items[worklist.items.len - 1];
        worklist.items.len -= 1;
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
                        _ = try self.reporter.reportFmt(.metadata_in_non_anchor, null, "metadata (#{s}...) only allowed in anchor file '{s}.orh', found in '{s}'",
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
            _ = try self.reporter.report(.{ .code = .internal_grammar_load, .message = "internal: could not load PEG grammar" });
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
            } else if (err_info.found_kind == .kw_if and err_info.pos > 0 and
                tokens.items[err_info.pos - 1].kind == .kw_else) blk:
            {
                break :blk try std.fmt.allocPrint(alloc, "'else if' is not valid \u{2014} use 'elif' for chained conditions", .{});
            } else if (err_info.found_kind == .semicolon) blk: {
                break :blk try std.fmt.allocPrint(alloc, "unexpected ';' \u{2014} Orhon does not use semicolons", .{});
            } else if ((err_info.found_kind == .identifier or
                err_info.found_kind == .int_literal or
                err_info.found_kind == .kw_true or
                err_info.found_kind == .kw_false) and
                err_info.pos > 0 and
                (tokens.items[err_info.pos - 1].kind == .kw_if or
                tokens.items[err_info.pos - 1].kind == .kw_while or
                tokens.items[err_info.pos - 1].kind == .kw_for)) blk:
            {
                break :blk try std.fmt.allocPrint(alloc,
                    "missing '(' after '{s}' \u{2014} conditions require parentheses: {s}(...)", .{
                    tokens.items[err_info.pos - 1].text,
                    tokens.items[err_info.pos - 1].text,
                });
            } else if (err_info.label) |label| blk: {
                // Human-readable label from grammar annotation
                break :blk try std.fmt.allocPrint(alloc, "expected {s}, found '{s}'", .{ label, err_info.found });
            } else if (err_info.expected_set.count() > 1) blk: {
                break :blk try module.formatExpectedSet(alloc, err_info.expected_set);
            } else try std.fmt.allocPrint(alloc, "unexpected '{s}'", .{err_info.found});
            // msg is allocated with alloc (== reporter.allocator) — pass ownership directly.
            const resolved = module.resolveFileLoc(mod.file_offsets, err_info.line);
            _ = try self.reporter.reportOwned(.{
                .code = .parse_failure,
                .message = msg,
                .loc = .{ .file = resolved.file, .line = resolved.line, .col = err_info.col },
            });
            if (mod.ast_arena) |*a| a.deinit();
            mod.ast_arena = null;
            mod.locs = null;
            continue;
        };

        // Build AST into the module's arena
        const build_result = peg_mod.buildASTWithArena(&cap, tokens.items, mod.ast_arena.?, alloc) catch {
            _ = try self.reporter.report(.{ .code = .internal_ast_build, .message = "internal: AST builder failed" });
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
            const resolved = module.resolveFileLoc(mod.file_offsets, err.line);
            _ = try self.reporter.report(.{
                .code = .parse_failure,
                .message = err.message,
                .loc = .{ .file = resolved.file, .line = resolved.line, .col = err.col },
            });
        }
        // Free the syntax_errors list — arena + locs were moved to mod above,
        // but syntax_errors.items lives on the child allocator and must be freed
        // separately to avoid a leak on every file that triggers error recovery.
        var syn_errs = build_result.ctx.syntax_errors;
        syn_errs.deinit(alloc);

        // Extract imports — scan scoped ones from std/ or global/
        // Capture stable values before the import loop — getOrPut during
        // import scanning can rehash the modules map, invalidating the mod pointer.
        var mod_locs = mod.locs;
        const mod_file_offsets = mod.file_offsets;
        const mod_files = mod.files;
        var imports: std.ArrayListUnmanaged([]const u8) = .{};
        for (build_result.node.program.imports) |imp| {
            const decl = imp.import_decl;
            // String-literal imports (import "header.h") are not supported
            if (decl.path.len > 0 and decl.path[0] == '"') {
                _ = try self.reporter.reportFmt(.c_import_not_supported, null, "import \"{s}\" is not supported — use a .zig + .zon module for C interop (see docs/14-zig-bridge.md)", .{constants.stripQuotes(decl.path)});
                continue;
            }

            const imp_loc = module.resolveNodeLoc(
                if (mod_locs != null) &mod_locs.? else null,
                mod_file_offsets,
                imp,
            );

            if (decl.scope) |sc| {
                // std::mem is a built-in compiler module — no .orh file needed
                if (std.mem.eql(u8, sc, "std") and std.mem.eql(u8, decl.path, "mem")) continue;

                // Only std:: imports are supported
                if (!std.mem.eql(u8, sc, "std")) {
                    _ = try self.reporter.reportFmt(.unknown_import_scope, imp_loc, "unknown import scope '{s}' — only 'std' is supported", .{sc});
                    continue;
                }

                // std:: resolves from .orh-cache/std/ (embedded in compiler)
                const scope_dir = try std.fs.path.join(self.allocator, &.{ cache.CACHE_DIR, "std" });
                defer self.allocator.free(scope_dir);

                const file_path = try std.fmt.allocPrint(self.allocator,
                    "{s}/{s}.orh", .{ scope_dir, decl.path });

                // Check the .orh file exists
                std.fs.cwd().access(file_path, .{}) catch {
                    _ = try self.reporter.reportFmt(.std_module_not_found, imp_loc, "module '{s}::{s}' not found",
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
                    // New module discovered — add to worklist for parsing
                    try worklist.append(self.allocator, imp_mod_name);
                } else {
                    self.allocator.free(imp_mod_name);
                    self.allocator.free(file_path);
                }
                try imports.append(self.allocator, try self.allocator.dupe(u8, decl.path));
            } else {
                // Bare import (no scope prefix). If the importing module lives in
                // .orh-cache/std/, resolve against the std directory (sibling import).
                // Otherwise it's a project-local import.
                const is_std_module = mod_files.len > 0 and isStdPath(mod_files[0]);
                if (is_std_module and !self.modules.contains(decl.path)) {
                    try addStdModule(self, &worklist, decl.path);
                }
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

        // Hard-error: #build and #version must be in orhon.project, not in source files
        for (build_result.node.program.metadata) |meta| {
            if (meta.metadata.field == .build or meta.metadata.field == .version) {
                const key = if (meta.metadata.field == .build) "build" else "version";
                const anchor = if (mod.files.len > 0) mod.files[0] else mod_name;
                _ = try self.reporter.reportFmt(.metadata_in_source,
                    .{ .file = anchor, .line = 1, .col = 1 },
                    "#{s} belongs in orhon.project, not in source files — move it to orhon.project",
                    .{key});
            }
        }

    }

}

/// Returns true if the file path is under the std cache directory (.orh-cache/std/).
fn isStdPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, cache.CACHE_DIR ++ "/std/") or
        std.mem.startsWith(u8, path, ".orh-cache/std/");
}

/// Add a std module to the resolver map and worklist. Used when a bare `import X`
/// is discovered in a std module (sibling resolution — no `std::` prefix needed).
fn addStdModule(self: *Resolver, worklist: *std.ArrayListUnmanaged([]const u8), mod_name: []const u8) !void {
    const scope_dir = try std.fs.path.join(self.allocator, &.{ cache.CACHE_DIR, "std" });
    defer self.allocator.free(scope_dir);

    const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.orh", .{ scope_dir, mod_name });

    // Verify the .orh file exists
    std.fs.cwd().access(file_path, .{}) catch {
        self.allocator.free(file_path);
        return;
    };

    const duped_name = try self.allocator.dupe(u8, mod_name);
    const result = try self.modules.getOrPut(duped_name);
    if (!result.found_existing) {
        result.key_ptr.* = duped_name;
        const files = try self.allocator.alloc([]const u8, 1);
        files[0] = file_path;
        result.value_ptr.* = .{
            .name = duped_name,
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
        try worklist.append(self.allocator, duped_name);
    } else {
        self.allocator.free(duped_name);
        self.allocator.free(file_path);
    }
}


