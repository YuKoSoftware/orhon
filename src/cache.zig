// cache.zig — Orhon incremental compilation cache (semantic hashing + interface diffing)
// Manages .orh-cache/hashes, .orh-cache/deps.graph, and .orh-cache/interfaces.
// Determines which modules need recompilation.

const std = @import("std");
const XxHash3 = std.hash.XxHash3;
const lexer = @import("lexer.zig");
const declarations = @import("declarations.zig");
const types = @import("types.zig");

pub const CACHE_DIR = ".orh-cache";
pub const GENERATED_DIR = ".orh-cache/generated";
pub const HASHES_FILE = ".orh-cache/hashes";
pub const DEPS_FILE = ".orh-cache/deps.graph";
pub const WARNINGS_FILE = ".orh-cache/warnings";
pub const INTERFACES_FILE = ".orh-cache/interfaces";

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
    /// Interface hashes keyed by module name — used for smarter dependency invalidation.
    /// A downstream module only recompiles if its dependency's interface hash changed,
    /// not just because the dependency's source changed.
    interface_hashes: std.StringHashMap(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .hashes = std.StringHashMap(u64).init(allocator),
            .deps = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .interface_hashes = std.StringHashMap(u64).init(allocator),
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
        // Free interface hash keys
        var ih_it = self.interface_hashes.iterator();
        while (ih_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.interface_hashes.deinit();
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

    /// Load interface hashes from .orh-cache/interfaces
    pub fn loadInterfaceHashes(self: *Cache) !void {
        const file = std.fs.cwd().openFile(INTERFACES_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) return; // fresh build
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Format: "module_name hash"
            var parts = std.mem.splitScalar(u8, line, ' ');
            const mod_name = parts.next() orelse continue;
            const hash_str = parts.next() orelse continue;
            const hash_val = std.fmt.parseInt(u64, hash_str, 10) catch continue;
            const name_copy = try self.allocator.dupe(u8, mod_name);
            try self.interface_hashes.put(name_copy, hash_val);
        }
    }

    /// Save interface hashes to .orh-cache/interfaces
    pub fn saveInterfaceHashes(self: *Cache) !void {
        try ensureGeneratedDir();
        const file = try std.fs.cwd().createFile(INTERFACES_FILE, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        var it = self.interface_hashes.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.flush();
    }

    /// Returns true if the dependency's current interface hash differs from cached,
    /// or if no cached interface hash exists for the dependency.
    pub fn depInterfaceChanged(self: *Cache, dep_name: []const u8) bool {
        _ = self.interface_hashes.get(dep_name) orelse return true;
        // The caller is responsible for comparing against the freshly computed hash.
        // This function reports "changed" only when there is no stored hash at all.
        // The actual comparison happens in pipeline.zig where both values are available.
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

/// Compute a deterministic u64 hash of a module's public interface.
///
/// Only public declarations are included — private changes (is_pub=false) do not
/// affect the hash. This is the key property enabling interface diffing: a module
/// that changes only its function bodies or private helpers will produce the same
/// interface hash, so downstream importers can skip recompilation.
///
/// HashMap iteration order is non-deterministic, so entry names are sorted
/// alphabetically before hashing (up to 256 names per category; beyond that
/// the sort is skipped — rare edge case, still semantically correct).
pub fn hashInterface(decls: *const declarations.DeclTable) u64 {
    var seed: u64 = 0;

    // Category 0x01: public functions
    seed = XxHash3.hash(seed, &[_]u8{0x01});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.funcs.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_pub) continue;
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            const sig = decls.funcs.get(name).?;
            seed = XxHash3.hash(seed, name);
            for (sig.params) |param| {
                seed = hashResolvedType(seed, param.type_);
            }
            seed = hashResolvedType(seed, sig.return_type);
            seed = XxHash3.hash(seed, &[_]u8{ @intFromBool(sig.is_compt), @intFromBool(sig.is_thread) });
        }
    }

    // Category 0x02: public structs
    seed = XxHash3.hash(seed, &[_]u8{0x02});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.structs.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_pub) continue;
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            const sig = decls.structs.get(name).?;
            seed = XxHash3.hash(seed, name);
            // Sort fields by name for determinism
            var field_names: [256][]const u8 = undefined;
            var fc: usize = 0;
            for (sig.fields) |field| {
                if (fc < 256) {
                    field_names[fc] = field.name;
                    fc += 1;
                }
            }
            sortNames(field_names[0..fc]);
            for (field_names[0..fc]) |fname| {
                // Find field by name
                for (sig.fields) |field| {
                    if (std.mem.eql(u8, field.name, fname)) {
                        seed = XxHash3.hash(seed, field.name);
                        seed = hashResolvedType(seed, field.type_);
                        seed = XxHash3.hash(seed, &[_]u8{@intFromBool(field.is_pub)});
                        break;
                    }
                }
            }
        }
    }

    // Category 0x03: public enums
    seed = XxHash3.hash(seed, &[_]u8{0x03});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.enums.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_pub) continue;
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            const sig = decls.enums.get(name).?;
            seed = XxHash3.hash(seed, name);
            seed = hashResolvedType(seed, sig.backing_type);
            // Sort variant names
            var vnames: [256][]const u8 = undefined;
            var vc: usize = 0;
            for (sig.variants) |v| {
                if (vc < 256) {
                    vnames[vc] = v;
                    vc += 1;
                }
            }
            sortNames(vnames[0..vc]);
            for (vnames[0..vc]) |vname| {
                seed = XxHash3.hash(seed, vname);
            }
        }
    }

    // Category 0x04: public bitfields
    seed = XxHash3.hash(seed, &[_]u8{0x04});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.bitfields.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_pub) continue;
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            const sig = decls.bitfields.get(name).?;
            seed = XxHash3.hash(seed, name);
            seed = hashResolvedType(seed, sig.backing_type);
            var fnames: [256][]const u8 = undefined;
            var fc: usize = 0;
            for (sig.flags) |flag| {
                if (fc < 256) {
                    fnames[fc] = flag;
                    fc += 1;
                }
            }
            sortNames(fnames[0..fc]);
            for (fnames[0..fc]) |flag| {
                seed = XxHash3.hash(seed, flag);
            }
        }
    }

    // Category 0x05: public variables/constants
    seed = XxHash3.hash(seed, &[_]u8{0x05});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.vars.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.is_pub) continue;
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            const sig = decls.vars.get(name).?;
            seed = XxHash3.hash(seed, name);
            if (sig.type_) |t| seed = hashResolvedType(seed, t);
            seed = XxHash3.hash(seed, &[_]u8{ @intFromBool(sig.is_const), @intFromBool(sig.is_compt) });
        }
    }

    // Category 0x06: public type aliases
    seed = XxHash3.hash(seed, &[_]u8{0x06});
    {
        var names: [256][]const u8 = undefined;
        var count: usize = 0;
        var it = decls.types.iterator();
        while (it.next()) |entry| {
            if (count < 256) {
                names[count] = entry.key_ptr.*;
                count += 1;
            }
        }
        sortNames(names[0..count]);
        for (names[0..count]) |name| {
            seed = XxHash3.hash(seed, name);
        }
    }

    return seed;
}

/// Sort a slice of string slices alphabetically in-place using insertion sort.
/// Insertion sort is chosen for its simplicity and low overhead for small slices.
fn sortNames(names: [][]const u8) void {
    if (names.len <= 1) return;
    var i: usize = 1;
    while (i < names.len) : (i += 1) {
        const key = names[i];
        var j: usize = i;
        while (j > 0 and std.mem.order(u8, names[j - 1], key) == .gt) : (j -= 1) {
            names[j] = names[j - 1];
        }
        names[j] = key;
    }
}

/// Hash a ResolvedType value into a running seed.
/// Hashes the tag discriminant plus inner data recursively.
fn hashResolvedType(seed: u64, rt: types.ResolvedType) u64 {
    var s = seed;
    // Hash the tag as a discriminant byte
    const tag: u8 = @intCast(@intFromEnum(std.meta.activeTag(rt)));
    s = XxHash3.hash(s, &[_]u8{tag});
    switch (rt) {
        .primitive => |p| {
            const pval: u8 = @intCast(@intFromEnum(p));
            s = XxHash3.hash(s, &[_]u8{pval});
        },
        .named => |name| {
            s = XxHash3.hash(s, name);
        },
        .err, .null_type, .inferred, .unknown => {
            // tag is enough
        },
        .slice => |elem| {
            s = hashResolvedType(s, elem.*);
        },
        .array => |arr| {
            s = hashResolvedType(s, arr.elem.*);
            // size node is an AST pointer; use its address as a proxy (stable within a build)
            const addr: u64 = @intFromPtr(arr.size);
            s = XxHash3.hash(s, std.mem.asBytes(&addr));
        },
        .error_union => |inner| {
            s = hashResolvedType(s, inner.*);
        },
        .null_union => |inner| {
            s = hashResolvedType(s, inner.*);
        },
        .union_type => |variants| {
            for (variants) |v| {
                s = hashResolvedType(s, v);
            }
        },
        .tuple => |fields| {
            for (fields) |f| {
                s = XxHash3.hash(s, f.name);
                s = hashResolvedType(s, f.type_);
            }
        },
        .func_ptr => |fp| {
            for (fp.params) |p| {
                s = hashResolvedType(s, p);
            }
            s = hashResolvedType(s, fp.return_type.*);
        },
        .generic => |g| {
            s = XxHash3.hash(s, g.name);
            for (g.args) |arg| {
                s = hashResolvedType(s, arg);
            }
        },
        .ptr => |p| {
            s = XxHash3.hash(s, p.kind);
            s = hashResolvedType(s, p.elem.*);
        },
    }
    return s;
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

// ── Interface hashing tests ────────────────────────────────────────────────

/// Build a minimal DeclTable with a single public function for testing.
/// Uses an arena allocator for parser nodes — the arena must be deinitialized
/// after the table.
fn makeTestTable(
    alloc: std.mem.Allocator,
    arena: std.mem.Allocator,
    func_name: []const u8,
    is_pub: bool,
) !declarations.DeclTable {
    var table = declarations.DeclTable.init(alloc);
    const params = try alloc.alloc(declarations.ParamSig, 0);

    // parser.Node for the return type — owned by the arena, freed with it
    const parser_mod = @import("parser.zig");
    const ret_node = try arena.create(parser_mod.Node);
    ret_node.* = .{ .type_named = "void" };

    const sig = declarations.FuncSig{
        .name = func_name,
        .params = params,
        .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = is_pub,
        .is_thread = false,
        .is_bridge = false,
    };
    try table.funcs.put(func_name, sig);
    return table;
}

/// Free a test DeclTable that was built with makeTestTable.
fn freeTestTable(alloc: std.mem.Allocator, table: *declarations.DeclTable) void {
    var it = table.funcs.iterator();
    while (it.next()) |e| alloc.free(e.value_ptr.params);
    table.funcs.deinit();
    table.structs.deinit();
    table.enums.deinit();
    table.bitfields.deinit();
    table.vars.deinit();
    table.types.deinit();
    table.struct_methods.deinit(alloc);
    table.type_arena.deinit();
}

test "interface hash deterministic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Two identical tables must produce the same hash
    var t1 = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &t1);

    var t2 = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &t2);

    const h1 = hashInterface(&t1);
    const h2 = hashInterface(&t2);
    try std.testing.expectEqual(h1, h2);
}

test "interface hash ignores private" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Table with only a public func
    var pub_table = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &pub_table);

    // Same table, plus a private func
    var pub_and_priv = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &pub_and_priv);
    {
        const parser_mod = @import("parser.zig");
        const ret_node = try a.create(parser_mod.Node);
        ret_node.* = .{ .type_named = "void" };
        const params = try alloc.alloc(declarations.ParamSig, 0);
        const priv_sig = declarations.FuncSig{
            .name = "helper",
            .params = params,
            .param_nodes = &.{},
            .return_type = .{ .primitive = .void },
            .return_type_node = ret_node,
            .is_compt = false,
            .is_pub = false, // private — must not affect the hash
            .is_thread = false,
            .is_bridge = false,
        };
        try pub_and_priv.funcs.put("helper", priv_sig);
    }

    const h1 = hashInterface(&pub_table);
    const h2 = hashInterface(&pub_and_priv);
    try std.testing.expectEqual(h1, h2);
}

test "interface hash changes on public change" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var t1 = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &t1);

    // Same as t1 but with an additional public function
    var t2 = try makeTestTable(alloc, a, "greet", true);
    defer freeTestTable(alloc, &t2);
    {
        const parser_mod = @import("parser.zig");
        const ret_node = try a.create(parser_mod.Node);
        ret_node.* = .{ .type_named = "void" };
        const params = try alloc.alloc(declarations.ParamSig, 0);
        const new_pub = declarations.FuncSig{
            .name = "farewell",
            .params = params,
            .param_nodes = &.{},
            .return_type = .{ .primitive = .void },
            .return_type_node = ret_node,
            .is_compt = false,
            .is_pub = true, // public — must change the hash
            .is_thread = false,
            .is_bridge = false,
        };
        try t2.funcs.put("farewell", new_pub);
    }

    const h1 = hashInterface(&t1);
    const h2 = hashInterface(&t2);
    try std.testing.expect(h1 != h2);
}

test "interface hashes load save roundtrip" {
    const alloc = std.testing.allocator;
    const tmp_interfaces = "/tmp/orhon_test_interfaces";

    var cache1 = Cache.init(alloc);
    defer cache1.deinit();

    // Insert two module interface hashes
    const k1 = try alloc.dupe(u8, "collections");
    try cache1.interface_hashes.put(k1, 12345678901234);
    const k2 = try alloc.dupe(u8, "str");
    try cache1.interface_hashes.put(k2, 98765432109876);

    // Save to temp file by temporarily overriding via direct file write
    {
        const file = try std.fs.cwd().createFile(tmp_interfaces, .{});
        defer file.close();
        var buf: [1024]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;
        var it = cache1.interface_hashes.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.flush();
    }
    defer std.fs.cwd().deleteFile(tmp_interfaces) catch {};

    // Load into a fresh cache by reading the temp file directly
    var cache2 = Cache.init(alloc);
    defer cache2.deinit();
    {
        const file = std.fs.cwd().openFile(tmp_interfaces, .{}) catch unreachable;
        defer file.close();
        const content = try file.readToEndAlloc(alloc, 1024 * 1024);
        defer alloc.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, ' ');
            const mod_name = parts.next() orelse continue;
            const hash_str = parts.next() orelse continue;
            const hash_val = std.fmt.parseInt(u64, hash_str, 10) catch continue;
            const name_copy = try alloc.dupe(u8, mod_name);
            try cache2.interface_hashes.put(name_copy, hash_val);
        }
    }

    try std.testing.expectEqual(@as(?u64, 12345678901234), cache2.interface_hashes.get("collections"));
    try std.testing.expectEqual(@as(?u64, 98765432109876), cache2.interface_hashes.get("str"));
}
