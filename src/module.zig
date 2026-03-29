// module.zig — Module resolution pass (pass 3)
// Groups .orh files by module name, builds dependency graph,
// detects circular imports, checks incremental cache.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");

const MODULE_KEYWORD = "module ";

pub const BuildType = enum { none, exe, static, dynamic };

/// Maps combined-buffer line numbers back to the original source file + local line.
/// Each entry marks where a file begins in the combined buffer.
pub const FileOffset = struct {
    file: []const u8,       // source file path
    start_line: usize,      // line number in combined buffer where this file starts (1-based)
    original_start: usize,  // line number in original file that maps to start_line (1 if no lines stripped, 2 if module line stripped)
};

/// Resolve a combined-buffer line number to (file_path, local_line).
/// Format a set of expected token kinds as a human-readable string.
/// Produces: "expected 'X'" for 1 item, "expected 'X' or 'Y'" for 2,
/// and "expected 'X', 'Y', or 'Z'" for 3+.
fn formatExpectedSet(alloc: std.mem.Allocator, set: std.EnumSet(lexer.TokenKind)) ![]u8 {
    const engine_mod = @import("peg/engine.zig");
    const total = set.count();
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "expected ");
    var it = set.iterator();
    var i: usize = 0;
    while (it.next()) |kind| {
        if (i > 0 and i < total - 1) try buf.appendSlice(alloc, ", ");
        if (i > 0 and i == total - 1) {
            if (total > 2) try buf.appendSlice(alloc, ", or ") else try buf.appendSlice(alloc, " or ");
        }
        try buf.append(alloc, '\'');
        try buf.appendSlice(alloc, engine_mod.kindDisplayName(kind));
        try buf.append(alloc, '\'');
        i += 1;
    }
    return buf.toOwnedSlice(alloc);
}

pub fn resolveFileLoc(file_offsets: []const FileOffset, combined_line: usize) struct { file: []const u8, line: usize } {
    if (file_offsets.len == 0) return .{ .file = "", .line = combined_line };

    // Find the last offset whose start_line <= combined_line
    var best: usize = 0;
    for (file_offsets, 0..) |off, i| {
        if (off.start_line <= combined_line) {
            best = i;
        } else {
            break;
        }
    }
    const off = file_offsets[best];
    return .{ .file = off.file, .line = combined_line - off.start_line + off.original_start };
}

/// A resolved module — one or more .orh files sharing the same module name
pub const Module = struct {
    name: []const u8,
    files: [][]const u8,
    imports: [][]const u8,    // names of imported modules
    imports_owned: bool,      // true if imports slice was heap-allocated (needs freeing)
    is_root: bool,            // has buildtype declaration
    build_type: BuildType,    // what artifact this module builds into
    ast: ?*parser.Node,       // parsed AST (null if cached/unchanged)
    ast_arena: ?std.heap.ArenaAllocator, // owns the AST memory; null until parsed
    locs: ?parser.LocMap,     // AST node → source location map
    file_offsets: []FileOffset, // maps combined-buffer lines → original files
    has_bridges: bool = false, // true if module has bridge declarations (detected during parsing)
    sidecar_path: ?[]const u8 = null, // validated .zig sidecar path (set during parsing if has_bridges)
};
/// The module resolver
pub const Resolver = struct {
    modules: std.StringHashMap(Module),
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) Resolver {
        return .{
            .modules = std.StringHashMap(Module).init(allocator),
            .allocator = allocator,
            .reporter = reporter,
        };
    }

    pub fn deinit(self: *Resolver) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            var mod = entry.value_ptr;
            // Free the module name key (duped in readModuleName)
            self.allocator.free(entry.key_ptr.*);
            // Free the AST arena (frees the entire parsed AST tree)
            if (mod.ast_arena) |*a| a.deinit();
            // Free the location map
            if (mod.locs) |*l| l.deinit();
            // Free file path slices
            for (mod.files) |f| self.allocator.free(f);
            self.allocator.free(mod.files);
            // Free import name slices
            if (mod.imports_owned) {
                for (mod.imports) |imp| self.allocator.free(imp);
                self.allocator.free(mod.imports);
            }
            // Free sidecar path (allocated with allocPrint in bridge detection)
            if (mod.sidecar_path) |sp| self.allocator.free(sp);
        }
        self.modules.deinit();
    }

    /// Scan a directory for .orh files and group by module name
    pub fn scanDirectory(self: *Resolver, dir_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var file_map = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(self.allocator);
        defer {
            var it = file_map.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
            file_map.deinit();
        }

        try self.scanDirRecursive(&dir, dir_path, &file_map);

        // For each module, create a Module entry with the anchor file first
        var it = file_map.iterator();
        while (it.next()) |entry| {
            const mod_name = entry.key_ptr.*;
            const files = try entry.value_ptr.toOwnedSlice(self.allocator);

            // Put anchor file (module_name.orh) first in the list
            const anchor_name = try std.fmt.allocPrint(self.allocator, "{s}.orh", .{mod_name});
            defer self.allocator.free(anchor_name);
            var anchor_count: usize = 0;
            var anchor_idx: usize = 0;
            for (files, 0..) |f, i| {
                const is_anchor = std.mem.endsWith(u8, f, anchor_name) and
                    (f.len == anchor_name.len or f[f.len - anchor_name.len - 1] == '/');
                if (is_anchor) {
                    anchor_count += 1;
                    anchor_idx = i;
                }
            }

            if (anchor_count == 0) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "module '{s}' has no anchor file — expected '{s}'", .{ mod_name, anchor_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            } else if (anchor_count > 1) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "module '{s}' has {d} anchor files — only one '{s}' allowed per module", .{ mod_name, anchor_count, anchor_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            } else if (anchor_idx > 0) {
                // Swap anchor to front
                const tmp = files[0];
                files[0] = files[anchor_idx];
                files[anchor_idx] = tmp;
            }

            try self.modules.put(mod_name, .{
                .name = mod_name,
                .files = files,
                .imports = &.{},
                .imports_owned = false,
                .is_root = false,
                .build_type = .none,
                .ast = null,
                .ast_arena = null,
                .locs = null,
                .file_offsets = &.{},
            });
        }
    }

    fn scanDirRecursive(
        self: *Resolver,
        dir: *std.fs.Dir,
        dir_path: []const u8,
        file_map: *std.StringHashMap(std.ArrayListUnmanaged([]const u8))
    ) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                // Skip cache directory
                if (std.mem.eql(u8, entry.name, ".orh-cache")) continue;

                var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();
                const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                try self.scanDirRecursive(&sub_dir, sub_path, file_map);
            } else if (entry.kind == .file) {
                if (!std.mem.endsWith(u8, entry.name, ".orh")) continue;

                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });

                // Read first line to get module name
                const mod_name = try self.readModuleName(full_path) orelse {
                    // full_path is leaked here intentionally — error path, compilation will abort
                    try self.reporter.report(.{
                        .message = "file missing module declaration",
                        .loc = .{ .file = full_path, .line = 1, .col = 1 },
                    });
                    continue;
                };

                const result = try file_map.getOrPut(mod_name);
                if (!result.found_existing) {
                    result.value_ptr.* = .{};
                } else {
                    // Key already exists — free the duplicate we just allocated
                    self.allocator.free(mod_name);
                }
                try result.value_ptr.append(self.allocator, full_path);
            }
        }
    }

    fn readModuleName(self: *Resolver, path: []const u8) !?[]const u8 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        var buf: [512]u8 = undefined;
        const n = try file.read(&buf);
        const content = buf[0..n];

        // Skip blank lines and comment lines to find "module " declaration
        var pos: usize = 0;
        while (pos < content.len) {
            // Skip whitespace
            while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t')) pos += 1;
            if (pos >= content.len) return null;
            // Skip blank lines
            if (content[pos] == '\n') { pos += 1; continue; }
            if (content[pos] == '\r') { pos += 1; if (pos < content.len and content[pos] == '\n') pos += 1; continue; }
            // Skip line comments
            if (pos + 1 < content.len and content[pos] == '/' and content[pos + 1] == '/') {
                while (pos < content.len and content[pos] != '\n') pos += 1;
                continue;
            }
            break; // found a non-comment, non-blank line
        }

        const rest = content[pos..];
        if (!std.mem.startsWith(u8, rest, MODULE_KEYWORD)) return null;

        // Extract module name
        const start = pos + MODULE_KEYWORD.len;
        var end = start;
        while (end < content.len and content[end] != '\n' and content[end] != '\r' and content[end] != ' ') end += 1;

        if (start >= end) return null;

        return try self.allocator.dupe(u8, content[start..end]);
    }

    /// Pre-scan all .orh files for import statements (text-level, no full parse).
    /// Discovers std imports and adds them to the module map so parseModules only
    /// needs one pass. Replaces the two-pass parse hack.
    pub fn preScanImports(self: *Resolver) !void {
        // Collect existing module files to scan
        var files_to_scan = std.ArrayListUnmanaged([]const u8){};
        defer files_to_scan.deinit(self.allocator);
        {
            var it = self.modules.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.files) |f| {
                    try files_to_scan.append(self.allocator, f);
                }
            }
        }

        for (files_to_scan.items) |file_path| {
            const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
            defer file.close();
            // Read just the first 4KB — imports are always at the top
            var buf: [4096]u8 = undefined;
            const n = file.readAll(&buf) catch continue;
            const content = buf[0..n];

            var lines_iter = std.mem.splitSequence(u8, content, "\n");
            while (lines_iter.next()) |line| {
                const trimmed = std.mem.trimLeft(u8, line, " \t");
                // Quick check: line starts with "import " or "use "
                const after_keyword = if (std.mem.startsWith(u8, trimmed, "import "))
                    trimmed["import ".len..]
                else if (std.mem.startsWith(u8, trimmed, "use "))
                    trimmed["use ".len..]
                else
                    continue;
                const after_import = std.mem.trimLeft(u8, after_keyword, " \t");
                // Check for std:: prefix
                if (std.mem.startsWith(u8, after_import, "std::")) {
                    const mod_part = after_import["std::".len..];
                    // Extract module name (stop at whitespace, newline, or end)
                    var end: usize = 0;
                    while (end < mod_part.len and mod_part[end] != ' ' and
                        mod_part[end] != '\n' and mod_part[end] != '\r' and
                        mod_part[end] != '\t') : (end += 1)
                    {}
                    if (end == 0) continue;
                    const std_mod_name = mod_part[0..end];
                    // Skip std::mem (compiler built-in, no .orh file)
                    if (std.mem.eql(u8, std_mod_name, "mem")) continue;
                    // Add std module if not already known
                    if (!self.modules.contains(std_mod_name)) {
                        const scope_dir = try std.fs.path.join(self.allocator, &.{ cache.CACHE_DIR, "std" });
                        defer self.allocator.free(scope_dir);
                        const orh_path = try std.fmt.allocPrint(self.allocator,
                            "{s}/{s}.orh", .{ scope_dir, std_mod_name });
                        // Verify the file exists before adding
                        std.fs.cwd().access(orh_path, .{}) catch {
                            self.allocator.free(orh_path);
                            continue;
                        };
                        // Dupe the name — it points into a stack buffer
                        const duped_name = try self.allocator.dupe(u8, std_mod_name);
                        const files = try self.allocator.alloc([]const u8, 1);
                        files[0] = orh_path;
                        try self.modules.put(duped_name, .{
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
                        });
                    }
                }
            }
        }
    }

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

                // Non-anchor files must not contain metadata or bridge declarations
                if (file_idx > 0) {
                    var lines_iter = std.mem.splitSequence(u8, content, "\n");
                    while (lines_iter.next()) |line| {
                        const trimmed_line = std.mem.trimLeft(u8, line, " \t");
                        if (trimmed_line.len > 0 and trimmed_line[0] == '#' and
                            !std.mem.startsWith(u8, trimmed_line, "//"))
                        {
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "metadata (#{s}...) only allowed in anchor file '{s}.orh', found in '{s}'",
                                .{ trimmed_line[1..@min(trimmed_line.len, 10)], mod_name, file_path });
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg });
                            break;
                        }
                        // bridge declarations only allowed in anchor file
                        if ((std.mem.startsWith(u8, trimmed_line, "bridge ") or
                            std.mem.startsWith(u8, trimmed_line, "pub bridge ")) and
                            !std.mem.startsWith(u8, trimmed_line, "//"))
                        {
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "bridge declarations only allowed in anchor file '{s}.orh', found in '{s}'",
                                .{ mod_name, file_path });
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg });
                            break;
                        }
                    }
                }

                const len_before = combined.items.len;
                if (file_idx > 0) {
                    // Skip the `module X` line from non-first files
                    const trimmed = std.mem.trimLeft(u8, content, " \t");
                    if (std.mem.startsWith(u8, trimmed, MODULE_KEYWORD)) {
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
            const peg_mod = @import("peg.zig");

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
                    // Check if next token is & — common mistake: var &T instead of &T
                    const next_pos = err_info.pos + 1;
                    if (next_pos < tokens.items.len and tokens.items[next_pos].kind == .ampersand)
                        break :blk try std.fmt.allocPrint(alloc, "var &T is not valid — use &T for mutable references", .{})
                    else
                        break :blk try std.fmt.allocPrint(alloc, "unexpected '{s}'", .{err_info.found});
                } else if (err_info.label) |label| blk: {
                    // Human-readable label from grammar annotation
                    break :blk try std.fmt.allocPrint(alloc, "expected {s}, found '{s}'", .{ label, err_info.found });
                } else if (err_info.expected_set.count() > 1) blk: {
                    break :blk try formatExpectedSet(alloc, err_info.expected_set);
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
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "unknown import scope '{s}' — only 'std' is supported", .{sc});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg });
                        continue;
                    }

                    // std:: resolves from .orh-cache/std/ (embedded in compiler)
                    const scope_dir = try std.fs.path.join(self.allocator, &.{ cache.CACHE_DIR, "std" });
                    defer self.allocator.free(scope_dir);

                    const file_path = try std.fmt.allocPrint(self.allocator,
                        "{s}/{s}.orh", .{ scope_dir, decl.path });

                    // Check the .orh file exists
                    std.fs.cwd().access(file_path, .{}) catch {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "module '{s}::{s}' not found",
                            .{ sc, decl.path });
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg });
                        self.allocator.free(file_path);
                        continue;
                    };

                    // If a paired .zig sidecar exists, copy it to the generated dir
                    // so that @import("name.zig") in generated code resolves correctly
                    const sidecar_src = try std.fmt.allocPrint(self.allocator,
                        "{s}/{s}.zig", .{ scope_dir, decl.path });
                    defer self.allocator.free(sidecar_src);

                    const sidecar_exists = blk: {
                        std.fs.cwd().access(sidecar_src, .{}) catch break :blk false;
                        break :blk true;
                    };

                    if (sidecar_exists) {
                        try cache.ensureGeneratedDir();
                        const sidecar_dst = try std.fmt.allocPrint(self.allocator,
                            "{s}/{s}_bridge.zig", .{ cache.GENERATED_DIR, decl.path });
                        defer self.allocator.free(sidecar_dst);
                        try std.fs.cwd().copyFile(sidecar_src, std.fs.cwd(), sidecar_dst, .{});
                    }

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

            // Detect bridge declarations — scan AST top-level for bridge func/const/struct
            for (build_result.node.program.top_level) |node| {
                const is_bridge = switch (node.*) {
                    .func_decl => |f| f.is_bridge,
                    .const_decl, .var_decl => |v| v.is_bridge,
                    .struct_decl => |s| s.is_bridge,
                    else => false,
                };
                if (is_bridge) {
                    mod.has_bridges = true;
                    // Find anchor directory and validate sidecar exists
                    var anchor_dir: []const u8 = ".";
                    for (mod.files) |file| {
                        const stem = std.fs.path.stem(file);
                        if (std.mem.eql(u8, stem, mod_name)) {
                            anchor_dir = std.fs.path.dirname(file) orelse ".";
                            break;
                        }
                    }
                    const sidecar = try std.fmt.allocPrint(self.allocator,
                        "{s}/{s}.zig", .{ anchor_dir, mod_name });
                    std.fs.cwd().access(sidecar, .{}) catch {
                        const bridge_name = switch (node.*) {
                            .func_decl => |f| f.name,
                            .const_decl, .var_decl => |v| v.name,
                            .struct_decl => |s| s.name,
                            else => "unknown",
                        };
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "bridge '{s}': missing sidecar file '{s}'",
                            .{ bridge_name, sidecar });
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg });
                        self.allocator.free(sidecar);
                        break;
                    };
                    mod.sidecar_path = sidecar;
                    break;
                }
            }
        }
    }

    /// Validate that all imported modules were actually found
    pub fn validateImports(self: *Resolver, reporter: *errors.Reporter) !void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            const mod = entry.value_ptr;
            for (mod.imports) |imp_name| {
                if (!self.modules.contains(imp_name)) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "module '{s}' not found — add '{s}.orh' to src/", .{ imp_name, imp_name });
                    defer self.allocator.free(msg);
                    try reporter.report(.{ .message = msg });
                }
            }
        }
    }

    /// Check for circular imports using DFS
    pub fn checkCircularImports(self: *Resolver) !void {
        var visited = std.StringHashMap(bool).init(self.allocator);
        defer visited.deinit();
        var in_stack = std.StringHashMap(bool).init(self.allocator);
        defer in_stack.deinit();

        var it = self.modules.iterator();
        while (it.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                try self.dfsCircularCheck(entry.key_ptr.*, &visited, &in_stack);
            }
        }
    }

    fn dfsCircularCheck(
        self: *Resolver,
        mod_name: []const u8,
        visited: *std.StringHashMap(bool),
        in_stack: *std.StringHashMap(bool),
    ) anyerror!void {
        try visited.put(mod_name, true);
        try in_stack.put(mod_name, true);

        const mod = self.modules.get(mod_name) orelse return;
        for (mod.imports) |imp| {
            if (!visited.contains(imp)) {
                try self.dfsCircularCheck(imp, visited, in_stack);
            } else if (in_stack.get(imp) orelse false) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "circular import detected: {s} → {s}", .{ mod_name, imp });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            }
        }

        try in_stack.put(mod_name, false);
    }

    /// Get modules in topological order (dependencies first)
    pub fn topologicalOrder(self: *Resolver, allocator: std.mem.Allocator) ![][]const u8 {
        var visited = std.StringHashMap(bool).init(allocator);
        defer visited.deinit();
        var result: std.ArrayListUnmanaged([]const u8) = .{};

        var it = self.modules.iterator();
        while (it.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                try self.topoVisit(entry.key_ptr.*, &visited, &result, allocator);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    fn topoVisit(
        self: *Resolver,
        mod_name: []const u8,
        visited: *std.StringHashMap(bool),
        result: *std.ArrayListUnmanaged([]const u8),
        allocator: std.mem.Allocator,
    ) anyerror!void {
        try visited.put(mod_name, true);
        const mod = self.modules.get(mod_name) orelse return;
        for (mod.imports) |imp| {
            if (!visited.contains(imp)) {
                try self.topoVisit(imp, visited, result, allocator);
            }
        }
        try result.append(allocator, mod_name);
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
                const msg = try std.fmt.allocPrint(alloc,
                    "#dep: directory '{s}' not found", .{dep_path_rel});
                defer alloc.free(msg);
                try self.reporter.report(.{ .message = msg });
                continue;
            };

            // Scan the dep directory — adds its modules to self.modules
            try self.scanDirectory(dep_path);
            if (self.reporter.hasErrors()) continue;

            // Parse any newly added (unparsed) dep modules
            try self.parseModules(alloc);
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
                const mod = entry.value_ptr;
                // Only consider modules whose files live under dep_path
                if (mod.files.len == 0) continue;
                if (!std.mem.startsWith(u8, mod.files[0], dep_path)) continue;
                if (!mod.is_root) continue;
                dep_root = mod.ast;
                dep_root_name = mod.name;
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

            const req = extractVersion(required.?) orelse continue;
            const act = extractVersion(actual) orelse continue;

            // act < req → error; act > req → warn
            const cmp = compareVersions(act, req);
            if (cmp < 0) {
                const msg = try std.fmt.allocPrint(alloc,
                    "#dep '{s}': requires version {d}.{d}.{d} but found {d}.{d}.{d}",
                    .{ dep_path_rel, req[0], req[1], req[2], act[0], act[1], act[2] });
                defer alloc.free(msg);
                try self.reporter.report(.{ .message = msg });
            } else if (cmp > 0) {
                const msg = try std.fmt.allocPrint(alloc,
                    "#dep '{s}': expected version {d}.{d}.{d}, found newer {d}.{d}.{d} — ok",
                    .{ dep_path_rel, req[0], req[1], req[2], act[0], act[1], act[2] });
                defer alloc.free(msg);
                try self.reporter.warn(.{ .message = msg });
            }
        }
    }
};

/// Extract (major, minor, patch) from a Version(x, y, z) call node.
/// Returns null if the node is not a well-formed Version call.
pub fn extractVersion(node: *parser.Node) ?[3]u64 {
    if (node.* != .call_expr) return null;
    const call = node.call_expr;
    if (call.callee.* != .identifier) return null;
    if (!std.mem.eql(u8, call.callee.identifier, "Version")) return null;
    if (call.args.len != 3) return null;

    var parts: [3]u64 = undefined;
    for (call.args, 0..) |arg, i| {
        if (arg.* != .int_literal) return null;
        parts[i] = std.fmt.parseInt(u64, arg.int_literal, 10) catch return null;
    }
    return parts;
}

/// Returns negative if a < b, 0 if equal, positive if a > b.
fn compareVersions(a: [3]u64, b: [3]u64) i64 {
    for (a, b) |av, bv| {
        if (av < bv) return -1;
        if (av > bv) return 1;
    }
    return 0;
}

test "resolveFileLoc - single file" {
    const offsets = [_]FileOffset{
        .{ .file = "src/main.orh", .start_line = 1, .original_start = 1 },
    };
    const r = resolveFileLoc(&offsets, 10);
    try std.testing.expectEqualStrings("src/main.orh", r.file);
    try std.testing.expectEqual(@as(usize, 10), r.line);
}

test "resolveFileLoc - multi file" {
    const offsets = [_]FileOffset{
        .{ .file = "src/main.orh", .start_line = 1, .original_start = 1 },
        .{ .file = "src/utils.orh", .start_line = 20, .original_start = 2 }, // module line stripped
        .{ .file = "src/extra.orh", .start_line = 50, .original_start = 2 },
    };

    // Line in first file
    const r1 = resolveFileLoc(&offsets, 5);
    try std.testing.expectEqualStrings("src/main.orh", r1.file);
    try std.testing.expectEqual(@as(usize, 5), r1.line);

    // Line in second file (stripped module line, so original_start = 2)
    const r2 = resolveFileLoc(&offsets, 25);
    try std.testing.expectEqualStrings("src/utils.orh", r2.file);
    try std.testing.expectEqual(@as(usize, 7), r2.line); // 25 - 20 + 2 = 7

    // Line in third file
    const r3 = resolveFileLoc(&offsets, 50);
    try std.testing.expectEqualStrings("src/extra.orh", r3.file);
    try std.testing.expectEqual(@as(usize, 2), r3.line); // 50 - 50 + 2 = 2
}

test "resolveFileLoc - empty offsets" {
    const r = resolveFileLoc(&.{}, 42);
    try std.testing.expectEqualStrings("", r.file);
    try std.testing.expectEqual(@as(usize, 42), r.line);
}

test "module resolver init" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var resolver = Resolver.init(std.testing.allocator, &reporter);
    defer resolver.deinit();

    try std.testing.expectEqual(@as(usize, 0), resolver.modules.count());
}

test "extractVersion - valid" {
    // Build a synthetic Version(1, 2, 3) call_expr node inline
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const major = try a.create(parser.Node);
    major.* = .{ .int_literal = "1" };
    const minor = try a.create(parser.Node);
    minor.* = .{ .int_literal = "2" };
    const patch = try a.create(parser.Node);
    patch.* = .{ .int_literal = "3" };

    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "Version" };

    const args = try a.alloc(*parser.Node, 3);
    args[0] = major;
    args[1] = minor;
    args[2] = patch;

    var call_node = parser.Node{ .call_expr = .{
        .callee = callee,
        .args = args,
        .arg_names = &.{},
    } };

    const ver = extractVersion(&call_node);
    try std.testing.expect(ver != null);
    try std.testing.expectEqual(@as(u64, 1), ver.?[0]);
    try std.testing.expectEqual(@as(u64, 2), ver.?[1]);
    try std.testing.expectEqual(@as(u64, 3), ver.?[2]);
}

test "compareVersions" {
    try std.testing.expect(compareVersions(.{ 1, 0, 0 }, .{ 1, 0, 0 }) == 0);
    try std.testing.expect(compareVersions(.{ 1, 0, 0 }, .{ 2, 0, 0 }) < 0);
    try std.testing.expect(compareVersions(.{ 2, 0, 0 }, .{ 1, 9, 9 }) > 0);
    try std.testing.expect(compareVersions(.{ 1, 2, 3 }, .{ 1, 2, 4 }) < 0);
}

test "read module name" {
    // Use an isolated temp directory to avoid races under parallel test execution.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const f = try tmp.dir.createFile("test_module.orh", .{});
        defer f.close();
        try f.writeAll("module testmod\n\nfunc main() void {}\n");
    }

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, "test_module.orh");
    defer std.testing.allocator.free(tmp_path);

    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var resolver = Resolver.init(std.testing.allocator, &reporter);
    defer resolver.deinit();

    const name = try resolver.readModuleName(tmp_path);
    defer if (name) |n| std.testing.allocator.free(n);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("testmod", name.?);
}
