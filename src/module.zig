// module.zig — Module resolution pass (pass 3)
// Groups .kodr files by module name, builds dependency graph,
// detects circular imports, checks incremental cache.

const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");

/// A resolved module — one or more .kodr files sharing the same module name
pub const Module = struct {
    name: []const u8,
    files: [][]const u8,
    imports: [][]const u8,    // names of imported modules
    is_root: bool,            // has buildtype declaration
    ast: ?*parser.Node,       // parsed AST (null if cached/unchanged)
    ast_arena: ?std.heap.ArenaAllocator, // owns the AST memory; null until parsed
    locs: ?parser.LocMap,     // AST node → source location map
};
/// The module resolver
pub const Resolver = struct {
    modules: std.StringHashMap(Module),
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,
    kodr_dir: []const u8, // directory containing the kodr binary — for std/ and global/

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) Resolver {
        // Resolve the kodr binary directory at init time
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_path = std.fs.selfExePath(&exe_buf) catch "";
        const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
        const kodr_dir = allocator.dupe(u8, exe_dir) catch ".";
        return .{
            .modules = std.StringHashMap(Module).init(allocator),
            .allocator = allocator,
            .reporter = reporter,
            .kodr_dir = kodr_dir,
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
            // Free import name slices (only if dynamically allocated, not comptime &.{})
            if (mod.imports.len > 0) {
                for (mod.imports) |imp| self.allocator.free(imp);
                self.allocator.free(mod.imports);
            }
        }
        self.modules.deinit();
        self.allocator.free(self.kodr_dir);
    }

    /// Scan a directory for .kodr files and group by module name
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

            // Put anchor file (module_name.kodr) first in the list
            const anchor_name = try std.fmt.allocPrint(self.allocator, "{s}.kodr", .{mod_name});
            defer self.allocator.free(anchor_name);
            var has_anchor = false;
            for (files, 0..) |f, i| {
                const is_anchor = std.mem.endsWith(u8, f, anchor_name) and
                    (f.len == anchor_name.len or f[f.len - anchor_name.len - 1] == '/');
                if (is_anchor) {
                    has_anchor = true;
                    if (i > 0) {
                        const tmp = files[0];
                        files[0] = f;
                        files[i] = tmp;
                    }
                    break;
                }
            }

            if (!has_anchor) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "module '{s}' has no anchor file — expected '{s}'", .{ mod_name, anchor_name });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            }

            try self.modules.put(mod_name, .{
                .name = mod_name,
                .files = files,
                .imports = &.{},
                .is_root = false,
                .ast = null,
                .ast_arena = null,
                .locs = null,
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
                if (std.mem.eql(u8, entry.name, ".kodr-cache")) continue;

                var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();
                const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                try self.scanDirRecursive(&sub_dir, sub_path, file_map);
            } else if (entry.kind == .file) {
                if (!std.mem.endsWith(u8, entry.name, ".kodr")) continue;

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

        var buf: [256]u8 = undefined;
        const n = try file.read(&buf);
        const content = buf[0..n];

        // Find "module " prefix
        if (!std.mem.startsWith(u8, std.mem.trimLeft(u8, content, " \t"), "module ")) {
            return null;
        }

        // Extract module name
        var start: usize = 0;
        while (start < content.len and (content[start] == ' ' or content[start] == '\t')) start += 1;
        start += 7; // skip "module "
        var end = start;
        while (end < content.len and content[end] != '\n' and content[end] != '\r' and content[end] != ' ') end += 1;

        if (start >= end) return null;

        return try self.allocator.dupe(u8, content[start..end]);
    }

    /// Parse all modules and extract their imports
    pub fn parseModules(self: *Resolver, alloc: std.mem.Allocator) !void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            var mod = entry.value_ptr;

            // Skip already-parsed modules (e.g. dep modules parsed in a prior call)
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
            for (mod.files, 0..) |file_path, file_idx| {
                const file = try std.fs.cwd().openFile(file_path, .{});
                defer file.close();
                const content = try file.readToEndAlloc(arena_alloc, 10 * 1024 * 1024);

                if (file_idx > 0) {
                    // Skip the `module X` line from non-first files
                    const trimmed = std.mem.trimLeft(u8, content, " \t");
                    if (std.mem.startsWith(u8, trimmed, "module ")) {
                        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
                            try combined.appendSlice(arena_alloc, trimmed[nl + 1 ..]);
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
            }

            // Lex — token list is temporary (freed after parsing), but token.text
            // slices point into combined which lives in the arena. Safe.
            var lex = lexer.Lexer.init(combined.items);
            var tokens = try lex.tokenize(alloc);
            defer tokens.deinit(alloc);

            var rep = errors.Reporter.init(alloc, .debug);
            defer rep.deinit();

            // Use initWithArena so the parser allocates AST nodes into mod.ast_arena.
            // Do NOT call p.deinit() — that would free mod.ast_arena.
            // After parsing, move the arena back out of the parser into the module.
            var p = parser.Parser.initWithArena(tokens.items, mod.ast_arena.?, alloc, &rep);

            const ast = p.parseProgram() catch {
                // Propagate errors then free the arena since we won't store the AST
                for (rep.errors.items) |err| {
                    try self.reporter.report(err);
                }
                // Move the arena back so we can deinit it cleanly
                mod.ast_arena = p.arena;
                if (mod.ast_arena) |*a| a.deinit();
                mod.ast_arena = null;
                p.locs.deinit();
                mod.locs = null;
                continue;
            };

            // Move the arena and locs from parser back into the module
            mod.ast_arena = p.arena;
            mod.ast = ast;

            // Move locs into module — file paths stay as "" from parser
            // Later passes use the module's file list for error reporting
            mod.locs = p.locs;

            // Extract imports — scan scoped ones from std/ or global/
            var imports: std.ArrayListUnmanaged([]const u8) = .{};
            for (ast.program.imports) |imp| {
                const decl = imp.import_decl;
                if (decl.is_c_header) continue;

                if (decl.scope) |sc| {
                    // std::mem is a built-in compiler module — no .kodr file needed
                    if (std.mem.eql(u8, sc, "std") and std.mem.eql(u8, decl.path, "mem")) continue;

                    // Scoped import: std::name or global::name
                    const scope_dir = try std.fs.path.join(self.allocator, &.{ self.kodr_dir, sc });
                    defer self.allocator.free(scope_dir);

                    const file_path = try std.fmt.allocPrint(self.allocator,
                        "{s}/{s}.kodr", .{ scope_dir, decl.path });

                    // Check the .kodr file exists
                    std.fs.cwd().access(file_path, .{}) catch {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "module '{s}::{s}' not found — run `kodr initstd` to install the stdlib",
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
                            "{s}/{s}_extern.zig", .{ cache.GENERATED_DIR, decl.path });
                        defer self.allocator.free(sidecar_dst);
                        try std.fs.cwd().copyFile(sidecar_src, std.fs.cwd(), sidecar_dst, .{});
                    }

                    // Add to the file map so it gets parsed and compiled
                    const mod_name = try self.allocator.dupe(u8, decl.path);
                    const result = try self.modules.getOrPut(mod_name);
                    if (!result.found_existing) {
                        result.key_ptr.* = mod_name;
                        const files = try self.allocator.alloc([]const u8, 1);
                        files[0] = file_path;
                        result.value_ptr.* = .{
                            .name = mod_name,
                            .files = files,
                            .imports = &.{},
                            .is_root = false,
                            .ast = null,
                            .ast_arena = null,
                            .locs = null,
                        };
                    } else {
                        self.allocator.free(mod_name);
                        self.allocator.free(file_path);
                    }
                    try imports.append(self.allocator, try self.allocator.dupe(u8, decl.path));
                } else {
                    // Project-local import — file must exist in src/
                    try imports.append(self.allocator, try self.allocator.dupe(u8, decl.path));
                }
            }
            mod.imports = try imports.toOwnedSlice(self.allocator);

            // Check if root module (has build declaration in metadata)
            for (ast.program.metadata) |meta| {
                if (std.mem.eql(u8, meta.metadata.field, "build")) {
                    mod.is_root = true;
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
                        "module '{s}' not found — add '{s}.kodr' to src/", .{ imp_name, imp_name });
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
fn extractVersion(node: *parser.Node) ?[3]u64 {
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
    // Create a temp file
    const tmp_path = "/tmp/test_module.kodr";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module testmod\n\nfunc main() void {}\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var resolver = Resolver.init(std.testing.allocator, &reporter);
    defer resolver.deinit();

    const name = try resolver.readModuleName(tmp_path);
    defer if (name) |n| std.testing.allocator.free(n);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("testmod", name.?);
}
