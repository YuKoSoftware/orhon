// cache.zig — Orhon incremental compilation cache (semantic hashing)
// Manages .orh-cache/hashes and .orh-cache/deps.graph
// Determines which modules need recompilation.

const std = @import("std");
const XxHash3 = std.hash.XxHash3;
const lexer = @import("lexer.zig");

pub const CACHE_DIR = ".orh-cache";
pub const GENERATED_DIR = ".orh-cache/generated";
pub const HASHES_FILE = ".orh-cache/hashes";
pub const DEPS_FILE = ".orh-cache/deps.graph";
pub const WARNINGS_FILE = ".orh-cache/warnings";

/// A module entry in the cache
pub const ModuleEntry = struct {
    name: []const u8,
    files: [][]const u8,
    content_hash: u64,
};

/// The cache state
pub const Cache = struct {
    hashes: std.StringHashMap(u64),
    deps: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .hashes = std.StringHashMap(u64).init(allocator),
            .deps = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Cache) void {
        // Free duped hash keys
        var hs_it = self.hashes.iterator();
        while (hs_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.hashes.deinit();
        // Free deps keys and value lists
        var it = self.deps.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| self.allocator.free(dep);
            entry.value_ptr.deinit(self.allocator);
        }
        self.deps.deinit();
    }

    /// Load content hashes from .orh-cache/hashes
    pub fn loadHashes(self: *Cache) !void {
        const file = std.fs.cwd().openFile(HASHES_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) return; // fresh build
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Format: "path hash"
            var parts = std.mem.splitScalar(u8, line, ' ');
            const path = parts.next() orelse continue;
            const hash_str = parts.next() orelse continue;
            const hash_val = std.fmt.parseInt(u64, hash_str, 10) catch continue;
            const path_copy = try self.allocator.dupe(u8, path);
            try self.hashes.put(path_copy, hash_val);
        }
    }

    /// Save content hashes to .orh-cache/hashes
    pub fn saveHashes(self: *Cache) !void {
        try ensureGeneratedDir();
        const file = try std.fs.cwd().createFile(HASHES_FILE, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        var it = self.hashes.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.flush();
    }

    /// Load dependency graph from .orh-cache/deps.graph
    pub fn loadDeps(self: *Cache) !void {
        const file = std.fs.cwd().openFile(DEPS_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Format: "module → dep1, dep2, dep3"
            var parts = std.mem.splitSequence(u8, line, " → ");
            const mod_name = parts.next() orelse continue;
            const deps_str = parts.next() orelse continue;

            const mod_copy = try self.allocator.dupe(u8, mod_name);
            var dep_list: std.ArrayListUnmanaged([]const u8) = .{};

            if (deps_str.len > 0) {
                var dep_parts = std.mem.splitSequence(u8, deps_str, ", ");
                while (dep_parts.next()) |dep| {
                    if (dep.len > 0) {
                        try dep_list.append(self.allocator, try self.allocator.dupe(u8, dep));
                    }
                }
            }

            try self.deps.put(mod_copy, dep_list);
        }
    }

    /// Save dependency graph to .orh-cache/deps.graph
    pub fn saveDeps(self: *Cache) !void {
        try ensureGeneratedDir();
        const file = try std.fs.cwd().createFile(DEPS_FILE, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        var it = self.deps.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} →", .{entry.key_ptr.*});
            for (entry.value_ptr.items, 0..) |dep, i| {
                if (i == 0) try writer.print(" {s}", .{dep})
                else try writer.print(", {s}", .{dep});
            }
            try writer.print("\n", .{});
        }
        try writer.flush();
    }

    /// Check if a file has changed since last build (compares semantic hash)
    pub fn hasChanged(self: *Cache, path: []const u8) !bool {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return true;
        defer self.allocator.free(content);
        const current_hash = hashSemanticContent(content);
        const cached_hash = self.hashes.get(path) orelse return true;
        return current_hash != cached_hash;
    }

    /// Update the semantic hash for a file
    pub fn updateHash(self: *Cache, path: []const u8) !void {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        const hash_val = hashSemanticContent(content);
        const result = try self.hashes.getOrPut(path);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, path);
        }
        result.value_ptr.* = hash_val;
    }

    /// Check if a module needs recompilation (any file changed or dependency changed)
    pub fn moduleNeedsRecompile(self: *Cache, module_name: []const u8, files: []const []const u8) !bool {
        // Check if any source file changed
        for (files) |file| {
            if (try self.hasChanged(file)) return true;
        }

        // Check if any dependency changed
        const deps = self.deps.get(module_name) orelse return false;
        for (deps.items) |dep| {
            // Check if dep module's generated zig file exists
            const zig_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.zig", .{ GENERATED_DIR, dep });
            defer self.allocator.free(zig_path);
            std.fs.cwd().access(zig_path, .{}) catch return true;
        }

        return false;
    }
};

/// A cached warning entry
pub const CachedWarning = struct {
    module: []const u8,
    file: []const u8,
    line: usize,
    message: []const u8,
};

/// Load cached warnings from .orh-cache/warnings
pub fn loadWarnings(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(CachedWarning) {
    var list: std.ArrayListUnmanaged(CachedWarning) = .{};
    const file = std.fs.cwd().openFile(WARNINGS_FILE, .{}) catch |err| {
        if (err == error.FileNotFound) return list;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Format: "module\tfile\tline\tmessage"
        var parts = std.mem.splitScalar(u8, line, '\t');
        const mod = parts.next() orelse continue;
        const src_file = parts.next() orelse continue;
        const line_str = parts.next() orelse continue;
        const msg = parts.next() orelse continue;
        const line_num = std.fmt.parseInt(usize, line_str, 10) catch continue;
        try list.append(allocator, .{
            .module = try allocator.dupe(u8, mod),
            .file = try allocator.dupe(u8, src_file),
            .line = line_num,
            .message = try allocator.dupe(u8, msg),
        });
    }
    return list;
}

/// Save warnings to .orh-cache/warnings
pub fn saveWarnings(warnings: []const CachedWarning) !void {
    try ensureGeneratedDir();
    const file = try std.fs.cwd().createFile(WARNINGS_FILE, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    var w = file.writer(&buf);
    const writer = &w.interface;

    for (warnings) |warn| {
        try writer.print("{s}\t{s}\t{d}\t{s}\n", .{ warn.module, warn.file, warn.line, warn.message });
    }
    try writer.flush();
}

/// Compute a semantic hash of Orhon source by hashing the token stream.
/// Whitespace (newlines) and doc comments are excluded so that formatting-only
/// changes do not invalidate the cache. Token kinds and literal text are both
/// included so that real code changes always produce a different hash.
///
/// No allocation — the lexer is driven incrementally and XxHash3 is seeded
/// with the previous result to build a rolling hash.
pub fn hashSemanticContent(source: []const u8) u64 {
    var lex = lexer.Lexer.init(source);
    var seed: u64 = 0;

    while (true) {
        const tok = lex.next();
        // Stop at EOF
        if (tok.kind == .eof) break;
        // Skip tokens that carry no semantic meaning
        if (tok.kind == .newline or tok.kind == .doc_comment) continue;

        // Hash the token kind as a two-byte value, seeded by previous result
        const kind_val: u16 = @intFromEnum(tok.kind);
        const kind_bytes = [2]u8{ @truncate(kind_val >> 8), @truncate(kind_val) };
        seed = XxHash3.hash(seed, &kind_bytes);

        // For tokens whose text carries semantic value, also hash the text
        switch (tok.kind) {
            .identifier,
            .int_literal,
            .float_literal,
            .string_literal,
            => {
                seed = XxHash3.hash(seed, tok.text);
            },
            else => {},
        }
    }

    return seed;
}

pub fn ensureGeneratedDir() !void {
    std.fs.cwd().makePath(GENERATED_DIR) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Write a generated .zig file to the cache
pub fn writeGeneratedZig(module_name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    try ensureGeneratedDir();
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ GENERATED_DIR, module_name });
    defer allocator.free(path);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Read a generated .zig file from the cache
pub fn readGeneratedZig(module_name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ GENERATED_DIR, module_name });
    defer allocator.free(path);
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

test "cache init and deinit" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expect(cache.hashes.count() == 0);
}

test "cache has changed - nonexistent file" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const changed = try cache.hasChanged("nonexistent_file_xyz.orh");
    try std.testing.expect(changed);
}

test "cache unchanged file has same hash" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    // Write a temp file
    const tmp_path = "/tmp/orhon_cache_test_unchanged.orh";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module test\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Update hash, then hasChanged should return false
    try cache.updateHash(tmp_path);
    const changed = try cache.hasChanged(tmp_path);
    try std.testing.expect(!changed);
}

test "cache detects content change" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    // Write a temp file
    const tmp_path = "/tmp/orhon_cache_test_changed.orh";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module test\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    // Record initial hash
    try cache.updateHash(tmp_path);

    // Modify the file
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module test\nfunc main() {}\n");
    }

    // hasChanged should now return true
    const changed = try cache.hasChanged(tmp_path);
    try std.testing.expect(changed);
}

test "semantic hash ignores whitespace" {
    const src1 = "module test\nfunc main() {}\n";
    const src2 = "module test\n\n\nfunc main() {}\n\n";
    const h1 = hashSemanticContent(src1);
    const h2 = hashSemanticContent(src2);
    try std.testing.expectEqual(h1, h2);
}

test "semantic hash ignores comments" {
    const src1 = "module test\nfunc main() {}\n";
    const src2 = "module test\n/// A doc comment\nfunc main() {}\n";
    const h1 = hashSemanticContent(src1);
    const h2 = hashSemanticContent(src2);
    try std.testing.expectEqual(h1, h2);
}

test "semantic hash detects code changes" {
    const src1 = "module test\nfunc main() {}\n";
    const src2 = "module test\nfunc other() {}\n";
    const h1 = hashSemanticContent(src1);
    const h2 = hashSemanticContent(src2);
    try std.testing.expect(h1 != h2);
}

test "cache hasChanged with formatting" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const tmp_path = "/tmp/orhon_cache_test_formatting.orh";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module test\nfunc main() {}\n");
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try cache.updateHash(tmp_path);

    // Rewrite with different whitespace only (semantically identical)
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{});
        defer f.close();
        try f.writeAll("module test\n\n\nfunc main()  {}\n\n");
    }

    // hasChanged should return false — only whitespace differs
    const changed = try cache.hasChanged(tmp_path);
    try std.testing.expect(!changed);
}
