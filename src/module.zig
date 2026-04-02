// module.zig — Module resolution pass (pass 3)
// Groups .orh files by module name, builds dependency graph,
// detects circular imports, checks incremental cache.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");
const constants = @import("constants.zig");

const parse_impl = @import("module_parse.zig");

pub const MODULE_KEYWORD = "module ";

pub const BuildType = enum { none, exe, static, dynamic };

/// Parse a build type string from metadata (e.g. "exe", "static", "dynamic").
/// Returns `.exe` for unrecognized values.
pub fn parseBuildType(raw: []const u8) BuildType {
    const map = std.StaticStringMap(BuildType).initComptime(.{
        .{ "exe", .exe },
        .{ "static", .static },
        .{ "dynamic", .dynamic },
    });
    return map.get(raw) orelse .exe;
}

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
pub fn formatExpectedSet(alloc: std.mem.Allocator, set: std.EnumSet(lexer.TokenKind)) ![]u8 {
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

/// Resolve an AST node to its original source location via the location map.
/// Single implementation shared by all compiler passes.
pub fn resolveNodeLoc(locs: ?*const parser.LocMap, file_offsets: []const FileOffset, node: *parser.Node) ?errors.SourceLoc {
    if (locs) |l| {
        if (l.get(node)) |loc| {
            const resolved = resolveFileLoc(file_offsets, loc.line);
            return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
        }
    }
    return null;
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
    is_zig_module: bool = false, // true if auto-generated from .zig file
    zig_source_path: ?[]const u8 = null, // path to original .zig file
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
            // Free zig source path (allocated with allocPrint in pipeline zig module wiring)
            if (mod.zig_source_path) |zp| self.allocator.free(zp);
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

            // Skip if this module is already registered (user .orh files take precedence)
            if (self.modules.contains(mod_name)) {
                for (entry.value_ptr.items) |f| self.allocator.free(f);
                self.allocator.free(mod_name);
                continue;
            }

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
                try self.reporter.reportFmt(null, "module '{s}' has no anchor file — expected '{s}'", .{ mod_name, anchor_name });
            } else if (anchor_count > 1) {
                try self.reporter.reportFmt(null, "module '{s}' has {d} anchor files — only one '{s}' allowed per module", .{ mod_name, anchor_count, anchor_name });
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

                // Reject 'module main' — reserved for the executable entry point
                if (std.mem.eql(u8, mod_name, "main")) {
                    try self.reporter.reportFmt(.{ .file = full_path, .line = 1, .col = 1 }, constants.Err.MAIN_RESERVED ++ " — use your project name as the module name", .{});
                    self.allocator.free(mod_name);
                    self.allocator.free(full_path);
                    continue;
                }

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

    pub fn readModuleName(self: *Resolver, path: []const u8) !?[]const u8 {
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
        return parse_impl.parseModules(self, alloc);
    }

    /// Validate that all imported modules were actually found
    pub fn validateImports(self: *Resolver, reporter: *errors.Reporter) !void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            const mod = entry.value_ptr;
            for (mod.imports) |imp_name| {
                if (!self.modules.contains(imp_name)) {
                    try reporter.reportFmt(null, "module '{s}' not found — add '{s}.orh' to src/", .{ imp_name, imp_name });
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
                try self.reporter.reportFmt(null, "circular import detected: {s} → {s}", .{ mod_name, imp });
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
        return parse_impl.scanAndParseDeps(self, alloc, project_dir);
    }
};

/// Extract (major, minor, patch) from a Version(x, y, z) call node.
/// Returns null if the node is not a well-formed Version call.
pub fn extractVersion(node: *parser.Node) ?[3]u64 {
    if (node.* != .call_expr) return null;
    const call = node.call_expr;
    if (call.callee.* != .identifier) return null;
    if (!std.mem.eql(u8, call.callee.identifier, builtins.BT.VERSION)) return null;
    if (call.args.len != 3) return null;

    var parts: [3]u64 = undefined;
    for (call.args, 0..) |arg, i| {
        if (arg.* != .int_literal) return null;
        parts[i] = std.fmt.parseInt(u64, arg.int_literal, 10) catch return null;
    }
    return parts;
}

/// Returns negative if a < b, 0 if equal, positive if a > b.
pub fn compareVersions(a: [3]u64, b: [3]u64) i64 {
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
