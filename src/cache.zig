// cache.zig — Kodr incremental compilation cache
// Manages .kodr-cache/timestamps and .kodr-cache/deps.graph
// Determines which modules need recompilation.

const std = @import("std");

pub const CACHE_DIR = ".kodr-cache";
pub const GENERATED_DIR = ".kodr-cache/generated";
pub const TIMESTAMPS_FILE = ".kodr-cache/timestamps";
pub const DEPS_FILE = ".kodr-cache/deps.graph";

/// A module entry in the cache
pub const ModuleEntry = struct {
    name: []const u8,
    files: [][]const u8,
    last_modified: i128,
};

/// The cache state
pub const Cache = struct {
    timestamps: std.StringHashMap(i128),
    deps: std.StringHashMap(std.ArrayListUnmanaged([]const u8)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .timestamps = std.StringHashMap(i128).init(allocator),
            .deps = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Cache) void {
        // Free duped timestamp keys
        var ts_it = self.timestamps.iterator();
        while (ts_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.timestamps.deinit();
        // Free deps keys and value lists
        var it = self.deps.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| self.allocator.free(dep);
            entry.value_ptr.deinit(self.allocator);
        }
        self.deps.deinit();
    }

    /// Load timestamps from .kodr-cache/timestamps
    pub fn loadTimestamps(self: *Cache) !void {
        const file = std.fs.cwd().openFile(TIMESTAMPS_FILE, .{}) catch |err| {
            if (err == error.FileNotFound) return; // fresh build
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // Format: "path timestamp"
            var parts = std.mem.splitScalar(u8, line, ' ');
            const path = parts.next() orelse continue;
            const ts_str = parts.next() orelse continue;
            const ts = std.fmt.parseInt(i128, ts_str, 10) catch continue;
            const path_copy = try self.allocator.dupe(u8, path);
            try self.timestamps.put(path_copy, ts);
        }
    }

    /// Save timestamps to .kodr-cache/timestamps
    pub fn saveTimestamps(self: *Cache) !void {
        try ensureGeneratedDir();
        const file = try std.fs.cwd().createFile(TIMESTAMPS_FILE, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var w = file.writer(&buf);
        const writer = &w.interface;

        var it = self.timestamps.iterator();
        while (it.next()) |entry| {
            try writer.print("{s} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.flush();
    }

    /// Load dependency graph from .kodr-cache/deps.graph
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

    /// Save dependency graph to .kodr-cache/deps.graph
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

    /// Check if a file has changed since last build
    pub fn hasChanged(self: *Cache, path: []const u8) !bool {
        const stat = std.fs.cwd().statFile(path) catch return true; // file gone = changed
        const current_ts = stat.mtime;
        const cached_ts = self.timestamps.get(path) orelse return true; // not in cache = changed
        return current_ts != cached_ts;
    }

    /// Update the timestamp for a file
    pub fn updateTimestamp(self: *Cache, path: []const u8) !void {
        const stat = try std.fs.cwd().statFile(path);
        const result = try self.timestamps.getOrPut(path);
        if (result.found_existing) {
            result.value_ptr.* = stat.mtime;
        } else {
            result.key_ptr.* = try self.allocator.dupe(u8, path);
            result.value_ptr.* = stat.mtime;
        }
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
    try std.testing.expect(cache.timestamps.count() == 0);
}

test "cache has changed - nonexistent file" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    const changed = try cache.hasChanged("nonexistent_file_xyz.kodr");
    try std.testing.expect(changed);
}
