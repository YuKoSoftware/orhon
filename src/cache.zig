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
pub const ZIG_MODULES_DIR = ".orh-cache/zig_modules";

/// Schema version for every cache file. Bumped when the on-disk layout of any
/// cache record changes in a way that old files can't be parsed. A mismatched
/// version is treated as an empty cache (forces a clean rebuild) rather than
/// a hard error — upgrading orhon should never fail because of stale caches.
const CACHE_SCHEMA_VERSION: u32 = 1;

// ── ZON cache schemas ──────────────────────────────────────
// All five cache files share the same shape: a version field plus an entries
// array. ZON handles escaping automatically so module names containing spaces,
// tabs, or other separator characters no longer corrupt the cache.

const HashEntryZon = struct { path: []const u8, hash: u64 };
const HashesCacheZon = struct { version: u32, entries: []const HashEntryZon };

const DepsEntryZon = struct { module: []const u8, deps: []const []const u8 };
const DepsCacheZon = struct { version: u32, entries: []const DepsEntryZon };

const InterfaceEntryZon = struct { module: []const u8, hash: u64 };
const InterfacesCacheZon = struct { version: u32, entries: []const InterfaceEntryZon };

const WarningEntryZon = struct {
    module: []const u8,
    file: []const u8,
    line: usize,
    message: []const u8,
};
const WarningsCacheZon = struct { version: u32, entries: []const WarningEntryZon };

const UnionEntryZon = struct { module: []const u8, arity: usize };
const UnionsCacheZon = struct { version: u32, entries: []const UnionEntryZon };

/// Read a ZON cache file into the schema type. Returns null for missing files,
/// parse errors, or version mismatches — all three mean "no usable cache."
/// Caller owns the returned value and must free via `std.zon.parse.free`.
fn readZonCache(
    comptime T: type,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?T {
    const content = std.fs.cwd().readFileAllocOptions(
        allocator,
        path,
        1024 * 1024,
        null,
        .@"1",
        0,
    ) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(content);
    const parsed = std.zon.parse.fromSlice(T, allocator, content, null, .{}) catch return null;
    if (@hasField(T, "version") and parsed.version != CACHE_SCHEMA_VERSION) {
        std.zon.parse.free(allocator, parsed);
        return null;
    }
    return parsed;
}

/// Serialize a value to a ZON cache file at `path`.
fn writeZonCache(path: []const u8, value: anytype) !void {
    try ensureGeneratedDir();
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buf: [8192]u8 = undefined;
    var w = file.writer(&buf);
    try std.zon.stringify.serialize(value, .{}, &w.interface);
    try w.interface.flush();
}

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

    /// Load content hashes from .orh-cache/hashes (ZON format).
    pub fn loadHashes(self: *Cache) !void {
        const parsed = (try readZonCache(HashesCacheZon, self.allocator, HASHES_FILE)) orelse return;
        defer std.zon.parse.free(self.allocator, parsed);
        for (parsed.entries) |e| {
            const path_copy = try self.allocator.dupe(u8, e.path);
            try self.hashes.put(path_copy, e.hash);
        }
    }

    /// Save content hashes to .orh-cache/hashes (ZON format).
    pub fn saveHashes(self: *Cache) !void {
        var entries = try std.ArrayListUnmanaged(HashEntryZon).initCapacity(self.allocator, self.hashes.count());
        defer entries.deinit(self.allocator);
        var it = self.hashes.iterator();
        while (it.next()) |entry| {
            entries.appendAssumeCapacity(.{ .path = entry.key_ptr.*, .hash = entry.value_ptr.* });
        }
        try writeZonCache(HASHES_FILE, HashesCacheZon{
            .version = CACHE_SCHEMA_VERSION,
            .entries = entries.items,
        });
    }

    /// Load dependency graph from .orh-cache/deps.graph (ZON format).
    pub fn loadDeps(self: *Cache) !void {
        const parsed = (try readZonCache(DepsCacheZon, self.allocator, DEPS_FILE)) orelse return;
        defer std.zon.parse.free(self.allocator, parsed);
        for (parsed.entries) |e| {
            const mod_copy = try self.allocator.dupe(u8, e.module);
            var dep_list: std.ArrayListUnmanaged([]const u8) = .{};
            try dep_list.ensureTotalCapacity(self.allocator, e.deps.len);
            for (e.deps) |dep| {
                dep_list.appendAssumeCapacity(try self.allocator.dupe(u8, dep));
            }
            try self.deps.put(mod_copy, dep_list);
        }
    }

    /// Save dependency graph to .orh-cache/deps.graph (ZON format).
    pub fn saveDeps(self: *Cache) !void {
        var entries = try std.ArrayListUnmanaged(DepsEntryZon).initCapacity(self.allocator, self.deps.count());
        defer entries.deinit(self.allocator);
        var it = self.deps.iterator();
        while (it.next()) |entry| {
            entries.appendAssumeCapacity(.{
                .module = entry.key_ptr.*,
                .deps = entry.value_ptr.items,
            });
        }
        try writeZonCache(DEPS_FILE, DepsCacheZon{
            .version = CACHE_SCHEMA_VERSION,
            .entries = entries.items,
        });
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
    /// Load interface hashes from .orh-cache/interfaces (ZON format).
    pub fn loadInterfaceHashes(self: *Cache) !void {
        const parsed = (try readZonCache(InterfacesCacheZon, self.allocator, INTERFACES_FILE)) orelse return;
        defer std.zon.parse.free(self.allocator, parsed);
        for (parsed.entries) |e| {
            const name_copy = try self.allocator.dupe(u8, e.module);
            try self.interface_hashes.put(name_copy, e.hash);
        }
    }

    /// Save interface hashes to .orh-cache/interfaces (ZON format).
    pub fn saveInterfaceHashes(self: *Cache) !void {
        var entries = try std.ArrayListUnmanaged(InterfaceEntryZon).initCapacity(self.allocator, self.interface_hashes.count());
        defer entries.deinit(self.allocator);
        var it = self.interface_hashes.iterator();
        while (it.next()) |entry| {
            entries.appendAssumeCapacity(.{ .module = entry.key_ptr.*, .hash = entry.value_ptr.* });
        }
        try writeZonCache(INTERFACES_FILE, InterfacesCacheZon{
            .version = CACHE_SCHEMA_VERSION,
            .entries = entries.items,
        });
    }

};

/// A cached warning entry
pub const CachedWarning = struct {
    module: []const u8,
    file: []const u8,
    line: usize,
    message: []const u8,
};

/// Load cached warnings from .orh-cache/warnings (ZON format).
pub fn loadWarnings(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(CachedWarning) {
    var list: std.ArrayListUnmanaged(CachedWarning) = .{};
    const parsed = (try readZonCache(WarningsCacheZon, allocator, WARNINGS_FILE)) orelse return list;
    defer std.zon.parse.free(allocator, parsed);
    try list.ensureTotalCapacity(allocator, parsed.entries.len);
    for (parsed.entries) |e| {
        list.appendAssumeCapacity(.{
            .module = try allocator.dupe(u8, e.module),
            .file = try allocator.dupe(u8, e.file),
            .line = e.line,
            .message = try allocator.dupe(u8, e.message),
        });
    }
    return list;
}

/// Save warnings to .orh-cache/warnings (ZON format).
pub fn saveWarnings(warnings: []const CachedWarning, allocator: std.mem.Allocator) !void {
    var entries_buf = try std.ArrayListUnmanaged(WarningEntryZon).initCapacity(allocator, warnings.len);
    defer entries_buf.deinit(allocator);
    for (warnings) |warn| {
        entries_buf.appendAssumeCapacity(.{
            .module = warn.module,
            .file = warn.file,
            .line = warn.line,
            .message = warn.message,
        });
    }
    try writeZonCache(WARNINGS_FILE, WarningsCacheZon{
        .version = CACHE_SCHEMA_VERSION,
        .entries = entries_buf.items,
    });
}

// ── Union Cache ────────────────────────────────────────────

pub const UNIONS_FILE = ".orh-cache/unions";

/// A cached per-module arity contribution.
/// The redesigned registry only needs to know how high the global arity goes
/// and which modules contributed it; comptime-memoized generic types in
/// _unions.zig handle structural dedup at the Zig type-system level.
pub const CachedUnionEntry = struct {
    module: []const u8,
    arity: usize,
};

/// Load cached union arities from .orh-cache/unions (ZON format).
/// Returns an empty list for missing files or version mismatches.
pub fn loadUnions(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(CachedUnionEntry) {
    var list: std.ArrayListUnmanaged(CachedUnionEntry) = .{};
    const parsed = (try readZonCache(UnionsCacheZon, allocator, UNIONS_FILE)) orelse return list;
    defer std.zon.parse.free(allocator, parsed);
    try list.ensureTotalCapacity(allocator, parsed.entries.len);
    for (parsed.entries) |e| {
        list.appendAssumeCapacity(.{
            .module = try allocator.dupe(u8, e.module),
            .arity = e.arity,
        });
    }
    return list;
}

/// Save union arities to .orh-cache/unions (ZON format).
pub fn saveUnions(unions: []const CachedUnionEntry, allocator: std.mem.Allocator) !void {
    var entries_buf = try std.ArrayListUnmanaged(UnionEntryZon).initCapacity(allocator, unions.len);
    defer entries_buf.deinit(allocator);
    for (unions) |entry| {
        entries_buf.appendAssumeCapacity(.{ .module = entry.module, .arity = entry.arity });
    }
    try writeZonCache(UNIONS_FILE, UnionsCacheZon{
        .version = CACHE_SCHEMA_VERSION,
        .entries = entries_buf.items,
    });
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
/// alphabetically before hashing. Dynamic allocation removes the previous
/// 256-symbol-per-category cap.
pub fn hashInterface(alloc: std.mem.Allocator, decls: *const declarations.DeclTable) !u64 {
    var seed: u64 = 0;

    // Collect names per category from the unified symbols map.
    var func_names: std.ArrayList([]const u8) = .{};
    defer func_names.deinit(alloc);
    var struct_names: std.ArrayList([]const u8) = .{};
    defer struct_names.deinit(alloc);
    var enum_names: std.ArrayList([]const u8) = .{};
    defer enum_names.deinit(alloc);
    var var_names: std.ArrayList([]const u8) = .{};
    defer var_names.deinit(alloc);
    var type_names: std.ArrayList([]const u8) = .{};
    defer type_names.deinit(alloc);

    var it = decls.symbols.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .func => |sig| if (sig.is_pub) try func_names.append(alloc, name),
            .@"struct" => |sig| if (sig.is_pub) try struct_names.append(alloc, name),
            .@"enum" => |sig| if (sig.is_pub) try enum_names.append(alloc, name),
            .@"var" => |sig| if (sig.is_pub) try var_names.append(alloc, name),
            .type_alias => try type_names.append(alloc, name),
            .handle, .blueprint => {},
        }
    }

    sortNames(func_names.items);
    sortNames(struct_names.items);
    sortNames(enum_names.items);
    sortNames(var_names.items);
    sortNames(type_names.items);

    // Category 0x01: public functions
    seed = XxHash3.hash(seed, &[_]u8{0x01});
    for (func_names.items) |name| {
        const sig = decls.symbols.get(name).?.func;
        seed = XxHash3.hash(seed, name);
        for (sig.params) |param| seed = hashResolvedType(seed, param.type_);
        seed = hashResolvedType(seed, sig.return_type);
        seed = XxHash3.hash(seed, &[_]u8{@intFromEnum(sig.context)});
    }

    // Category 0x02: public structs
    seed = XxHash3.hash(seed, &[_]u8{0x02});
    for (struct_names.items) |name| {
        const sig = decls.symbols.get(name).?.@"struct";
        seed = XxHash3.hash(seed, name);
        var field_names: std.ArrayList([]const u8) = .{};
        defer field_names.deinit(alloc);
        for (sig.fields) |field| try field_names.append(alloc, field.name);
        sortNames(field_names.items);
        for (field_names.items) |fname| {
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

    // Category 0x03: public enums
    seed = XxHash3.hash(seed, &[_]u8{0x03});
    for (enum_names.items) |name| {
        const sig = decls.symbols.get(name).?.@"enum";
        seed = XxHash3.hash(seed, name);
        seed = hashResolvedType(seed, sig.backing_type);
        var vnames: std.ArrayList([]const u8) = .{};
        defer vnames.deinit(alloc);
        for (sig.variants) |v| try vnames.append(alloc, v);
        sortNames(vnames.items);
        for (vnames.items) |vname| seed = XxHash3.hash(seed, vname);
    }

    // Category 0x05: public variables/constants
    seed = XxHash3.hash(seed, &[_]u8{0x05});
    for (var_names.items) |name| {
        const sig = decls.symbols.get(name).?.@"var";
        seed = XxHash3.hash(seed, name);
        if (sig.type_) |t| seed = hashResolvedType(seed, t);
        seed = XxHash3.hash(seed, &[_]u8{@intFromBool(sig.is_const)});
    }

    // Category 0x06: type aliases (all public — no is_pub field)
    seed = XxHash3.hash(seed, &[_]u8{0x06});
    for (type_names.items) |name| {
        seed = XxHash3.hash(seed, name);
    }

    return seed;
}

/// Sort a slice of string slices alphabetically in-place.
fn sortNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
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
            // Hash the size expression content (e.g. int literal text) for cross-build stability
            const size_text = if (arr.size.* == .int_literal) arr.size.int_literal else "?";
            s = XxHash3.hash(s, size_text);
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
            const kind_val: u8 = @intCast(@intFromEnum(p.kind));
            s = XxHash3.hash(s, &[_]u8{kind_val});
            s = hashResolvedType(s, p.elem.*);
        },
        .type_param => |tp| {
            s = XxHash3.hash(s, tp.name);
            const binder_val: u32 = @intFromEnum(tp.binder);
            s = XxHash3.hash(s, std.mem.asBytes(&binder_val));
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
        .context = .normal,
        .is_pub = is_pub,
        .is_instance = false,
    };
    try table.symbols.put(func_name, .{ .func = sig });
    return table;
}

/// Free a test DeclTable that was built with makeTestTable.
fn freeTestTable(_: std.mem.Allocator, table: *declarations.DeclTable) void {
    table.deinit();
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

    const h1 = try hashInterface(alloc, &t1);
    const h2 = try hashInterface(alloc, &t2);
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
            .context = .normal,
            .is_pub = false, // private — must not affect the hash
            .is_instance = false,
        };
        try pub_and_priv.symbols.put("helper", .{ .func = priv_sig });
    }

    const h1 = try hashInterface(alloc, &pub_table);
    const h2 = try hashInterface(alloc, &pub_and_priv);
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
            .context = .normal,
            .is_pub = true, // public — must change the hash
            .is_instance = false,
        };
        try t2.symbols.put("farewell", .{ .func = new_pub });
    }

    const h1 = try hashInterface(alloc, &t1);
    const h2 = try hashInterface(alloc, &t2);
    try std.testing.expect(h1 != h2);
}

test "interface hashes load save roundtrip" {
    const alloc = std.testing.allocator;

    try ensureGeneratedDir();
    defer std.fs.cwd().deleteFile(INTERFACES_FILE) catch {};

    var cache1 = Cache.init(alloc);
    defer cache1.deinit();

    const k1 = try alloc.dupe(u8, "collections");
    try cache1.interface_hashes.put(k1, 12345678901234);
    const k2 = try alloc.dupe(u8, "str");
    try cache1.interface_hashes.put(k2, 98765432109876);

    try cache1.saveInterfaceHashes();

    var cache2 = Cache.init(alloc);
    defer cache2.deinit();
    try cache2.loadInterfaceHashes();

    try std.testing.expectEqual(@as(?u64, 12345678901234), cache2.interface_hashes.get("collections"));
    try std.testing.expectEqual(@as(?u64, 98765432109876), cache2.interface_hashes.get("str"));
}

test "interface hash changes on field type change" {
    const alloc = std.testing.allocator;

    // Build DeclTable with struct Point { x: f32 }
    var decl1 = declarations.DeclTable.init(alloc);
    defer decl1.deinit();
    const fields1 = try alloc.alloc(declarations.FieldSig, 1);
    fields1[0] = .{ .name = "x", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    try decl1.symbols.put("Point", .{ .@"struct" = .{ .name = "Point", .fields = fields1, .is_pub = true } });
    const hash1 = try hashInterface(alloc, &decl1);

    // Build DeclTable with struct Point { x: f64 } — different field type
    var decl2 = declarations.DeclTable.init(alloc);
    defer decl2.deinit();
    const fields2 = try alloc.alloc(declarations.FieldSig, 1);
    fields2[0] = .{ .name = "x", .type_ = .{ .primitive = .f64 }, .has_default = false, .is_pub = true };
    try decl2.symbols.put("Point", .{ .@"struct" = .{ .name = "Point", .fields = fields2, .is_pub = true } });
    const hash2 = try hashInterface(alloc, &decl2);

    try std.testing.expect(hash1 != hash2);
}

test "interface hash with slice type" {
    const alloc = std.testing.allocator;

    var decl1 = declarations.DeclTable.init(alloc);
    defer decl1.deinit();
    const inner = try decl1.type_arena.allocator().create(types.ResolvedType);
    inner.* = .{ .primitive = .u8 };
    const fields1 = try alloc.alloc(declarations.FieldSig, 1);
    fields1[0] = .{ .name = "data", .type_ = .{ .slice = inner }, .has_default = false, .is_pub = true };
    try decl1.symbols.put("Buffer", .{ .@"struct" = .{ .name = "Buffer", .fields = fields1, .is_pub = true } });
    const hash1 = try hashInterface(alloc, &decl1);

    // Same struct, same field → same hash
    var decl2 = declarations.DeclTable.init(alloc);
    defer decl2.deinit();
    const inner2 = try decl2.type_arena.allocator().create(types.ResolvedType);
    inner2.* = .{ .primitive = .u8 };
    const fields2 = try alloc.alloc(declarations.FieldSig, 1);
    fields2[0] = .{ .name = "data", .type_ = .{ .slice = inner2 }, .has_default = false, .is_pub = true };
    try decl2.symbols.put("Buffer", .{ .@"struct" = .{ .name = "Buffer", .fields = fields2, .is_pub = true } });
    const hash2 = try hashInterface(alloc, &decl2);

    try std.testing.expectEqual(hash1, hash2);
}

test "interface hash with named type" {
    const alloc = std.testing.allocator;

    var decl1 = declarations.DeclTable.init(alloc);
    defer decl1.deinit();
    const fields1 = try alloc.alloc(declarations.FieldSig, 1);
    fields1[0] = .{ .name = "inner", .type_ = .{ .named = "Widget" }, .has_default = false, .is_pub = true };
    try decl1.symbols.put("Container", .{ .@"struct" = .{ .name = "Container", .fields = fields1, .is_pub = true } });
    const hash1 = try hashInterface(alloc, &decl1);

    // Different named type → different hash
    var decl2 = declarations.DeclTable.init(alloc);
    defer decl2.deinit();
    const fields2 = try alloc.alloc(declarations.FieldSig, 1);
    fields2[0] = .{ .name = "inner", .type_ = .{ .named = "Gadget" }, .has_default = false, .is_pub = true };
    try decl2.symbols.put("Container", .{ .@"struct" = .{ .name = "Container", .fields = fields2, .is_pub = true } });
    const hash2 = try hashInterface(alloc, &decl2);

    try std.testing.expect(hash1 != hash2);
}

test "union cache round-trip" {
    const alloc = std.testing.allocator;

    const entries = [_]CachedUnionEntry{
        .{ .module = "main", .arity = 2 },
        .{ .module = "shapes", .arity = 4 },
    };

    try saveUnions(&entries, alloc);
    defer std.fs.cwd().deleteFile(UNIONS_FILE) catch {};

    var loaded = try loadUnions(alloc);
    defer {
        for (loaded.items) |u| alloc.free(u.module);
        loaded.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("main", loaded.items[0].module);
    try std.testing.expectEqual(@as(usize, 2), loaded.items[0].arity);
    try std.testing.expectEqualStrings("shapes", loaded.items[1].module);
    try std.testing.expectEqual(@as(usize, 4), loaded.items[1].arity);
}

test "union cache rejects old schema" {
    const alloc = std.testing.allocator;
    try ensureGeneratedDir();
    {
        const file = try std.fs.cwd().createFile(UNIONS_FILE, .{});
        defer file.close();
        // Legacy tab-delimited v1/v2 format — invalid ZON, should yield empty cache.
        try file.writeAll("main\tOrhonUnion_i32_str\ti32,str\t\n");
    }
    defer std.fs.cwd().deleteFile(UNIONS_FILE) catch {};

    var loaded = try loadUnions(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "union cache load missing file" {
    const alloc = std.testing.allocator;
    // Ensure file doesn't exist
    std.fs.cwd().deleteFile(UNIONS_FILE) catch {};
    var loaded = try loadUnions(alloc);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
}

test "interface hash changes beyond 256 symbols" {
    // Regression test for the old 256-symbol cap: verifies that adding the
    // 301st public function changes the hash (was silently ignored before the fix).
    const alloc = std.testing.allocator;

    const parser_mod = @import("parser.zig");

    // Build a DeclTable with 300 public functions named "func0".."func299".
    // Names are duped into the type_arena (freed with table.deinit).
    // params slices are allocated with alloc so deinit's allocator.free works.
    var table_300 = declarations.DeclTable.init(alloc);
    defer table_300.deinit();

    for (0..300) |i| {
        const name = try std.fmt.allocPrint(alloc, "func{d}", .{i});
        const owned = try table_300.type_arena.allocator().dupe(u8, name);
        alloc.free(name);
        const params = try alloc.alloc(declarations.ParamSig, 0);
        const ret_node = try table_300.type_arena.allocator().create(parser_mod.Node);
        ret_node.* = .{ .type_named = "void" };
        const sig = declarations.FuncSig{
            .name = owned,
            .params = params,
            .param_nodes = &.{},
            .return_type = .{ .primitive = .void },
            .context = .normal,
            .is_pub = true,
            .is_instance = false,
        };
        try table_300.symbols.put(owned, .{ .func = sig });
    }

    const hash_300 = try hashInterface(alloc, &table_300);

    // Build an identical table with one additional function "func300".
    var table_301 = declarations.DeclTable.init(alloc);
    defer table_301.deinit();

    for (0..301) |i| {
        const name = try std.fmt.allocPrint(alloc, "func{d}", .{i});
        const owned = try table_301.type_arena.allocator().dupe(u8, name);
        alloc.free(name);
        const params = try alloc.alloc(declarations.ParamSig, 0);
        const ret_node = try table_301.type_arena.allocator().create(parser_mod.Node);
        ret_node.* = .{ .type_named = "void" };
        const sig = declarations.FuncSig{
            .name = owned,
            .params = params,
            .param_nodes = &.{},
            .return_type = .{ .primitive = .void },
            .context = .normal,
            .is_pub = true,
            .is_instance = false,
        };
        try table_301.symbols.put(owned, .{ .func = sig });
    }

    const hash_301 = try hashInterface(alloc, &table_301);

    try std.testing.expect(hash_300 != hash_301);
}

