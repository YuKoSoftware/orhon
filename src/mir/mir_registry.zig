// mir_registry.zig — Arbitrary-union arity tracker.
//
// The registry no longer holds canonical name strings or per-type module
// attribution. Comptime-memoized generic types in _unions.zig handle dedup
// at the Zig type-system level. The registry only needs to know how high
// the global union arity goes so codegen_unions emits enough factory
// functions, and which arity each module contributed so incremental builds
// can replay correctly.

const std = @import("std");

pub const UnionRegistry = struct {
    /// Per-module arity contributions. A module that uses (i32 | str | f64)
    /// contributes arity 3. The global max across all modules drives how
    /// many OrhonUnionN factories codegen_unions emits.
    module_arities: std.StringHashMapUnmanaged(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UnionRegistry {
        return .{
            .module_arities = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionRegistry) void {
        var it = self.module_arities.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.module_arities.deinit(self.allocator);
    }

    /// Record that `module` uses an arbitrary union of `arity` members.
    /// Tracks the maximum arity per module (multiple unions in the same
    /// module: only the largest matters). Arity < 2 is silently ignored.
    pub fn registerArity(self: *UnionRegistry, module: []const u8, arity: usize) !void {
        if (arity < 2) return;
        const result = try self.module_arities.getOrPut(self.allocator, module);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, module);
            result.value_ptr.* = arity;
        } else if (arity > result.value_ptr.*) {
            result.value_ptr.* = arity;
        }
    }

    /// Restore a cached per-module arity (used by the incremental cache replay path).
    pub fn restoreArity(self: *UnionRegistry, module: []const u8, arity: usize) !void {
        try self.registerArity(module, arity);
    }

    /// Maximum arity across all modules. Returns 0 if no unions registered.
    pub fn maxArity(self: *const UnionRegistry) usize {
        var max: usize = 0;
        var it = self.module_arities.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > max) max = entry.value_ptr.*;
        }
        return max;
    }

    /// Return true if any module registered an arbitrary union.
    pub fn isEmpty(self: *const UnionRegistry) bool {
        return self.module_arities.count() == 0;
    }

    /// Iterator over (module_name, arity) pairs for cache serialization.
    pub fn iterator(self: *const UnionRegistry) std.StringHashMapUnmanaged(usize).Iterator {
        return self.module_arities.iterator();
    }
};

// ── Tests ───────────────────────────────────────────────────

test "registry - register and max arity" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    try reg.registerArity("main", 2);
    try reg.registerArity("main", 4);
    try reg.registerArity("shapes", 3);

    try std.testing.expectEqual(@as(usize, 4), reg.maxArity());
    try std.testing.expectEqual(false, reg.isEmpty());
}

test "registry - arity 1 ignored" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    try reg.registerArity("main", 1);
    try std.testing.expectEqual(true, reg.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), reg.maxArity());
}

test "registry - per-module max preserved" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    try reg.registerArity("a", 5);
    try reg.registerArity("a", 2);
    try reg.registerArity("b", 3);

    var found_a: usize = 0;
    var found_b: usize = 0;
    var it = reg.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "a")) found_a = entry.value_ptr.*;
        if (std.mem.eql(u8, entry.key_ptr.*, "b")) found_b = entry.value_ptr.*;
    }
    try std.testing.expectEqual(@as(usize, 5), found_a);
    try std.testing.expectEqual(@as(usize, 3), found_b);
}

test "registry - restoreArity matches registerArity" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    try reg.restoreArity("cached", 3);
    try std.testing.expectEqual(@as(usize, 3), reg.maxArity());
}
