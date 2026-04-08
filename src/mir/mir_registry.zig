// mir_registry.zig — Canonical union type deduplication

const std = @import("std");
const mir_types = @import("mir_types.zig");
const types = @import("../types.zig");

pub const RT = mir_types.RT;

// ── Union Registry ──────────────────────────────────────────

/// Tracks which module defines a user type used in a union.
pub const ModuleType = struct {
    type_name: []const u8,
    module_name: []const u8,
};

/// Canonical union type deduplication.
/// Same structural union across functions shares one Zig type name.
/// Pipeline-level: one instance shared across all modules.
pub const UnionRegistry = struct {
    /// Sorted member names → canonical Zig type name
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        members: []const []const u8,
        name: []const u8,
        /// Non-primitive members and their defining modules
        module_types: []const ModuleType,
    };

    pub fn init(allocator: std.mem.Allocator) UnionRegistry {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionRegistry) void {
        for (self.entries.items) |entry| {
            for (entry.members) |m| self.allocator.free(m);
            self.allocator.free(entry.members);
            self.allocator.free(entry.name);
            for (entry.module_types) |mt| {
                self.allocator.free(mt.type_name);
                self.allocator.free(mt.module_name);
            }
            self.allocator.free(entry.module_types);
        }
        self.entries.deinit(self.allocator);
    }

    /// Restore a cached entry into the registry. Deduplicates against existing entries.
    pub fn restoreEntry(
        self: *UnionRegistry,
        name: []const u8,
        members: []const []const u8,
        module_types: []const ModuleType,
    ) !void {
        // Check for existing entry with same members (already sorted in cache)
        for (self.entries.items) |entry| {
            if (entry.members.len == members.len) {
                var match = true;
                for (entry.members, members) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        match = false;
                        break;
                    }
                }
                if (match) return; // already registered
            }
        }

        // Dupe all strings into registry allocator
        const duped_members = try self.allocator.alloc([]const u8, members.len);
        for (members, 0..) |m, i| duped_members[i] = try self.allocator.dupe(u8, m);

        const duped_mt = try self.allocator.alloc(ModuleType, module_types.len);
        for (module_types, 0..) |mt, i| {
            duped_mt[i] = .{
                .type_name = try self.allocator.dupe(u8, mt.type_name),
                .module_name = try self.allocator.dupe(u8, mt.module_name),
            };
        }

        try self.entries.append(self.allocator, .{
            .members = duped_members,
            .name = try self.allocator.dupe(u8, name),
            .module_types = duped_mt,
        });
    }

    /// Get or create a canonical name for a union type.
    /// `module_context` maps type names to their defining module names.
    /// Pass null when module context is unavailable (e.g. tests).
    pub fn canonicalize(
        self: *UnionRegistry,
        members: []const []const u8,
        module_context: ?*const std.StringHashMapUnmanaged([]const u8),
    ) ![]const u8 {
        const sorted = try self.allocator.alloc([]const u8, members.len);
        for (members, 0..) |m, i| sorted[i] = try self.allocator.dupe(u8, m);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        // Look for existing entry
        for (self.entries.items) |entry| {
            if (entry.members.len == sorted.len) {
                var match = true;
                for (entry.members, sorted) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    for (sorted) |s| self.allocator.free(s);
                    self.allocator.free(sorted);
                    return entry.name;
                }
            }
        }

        // Collect module types for non-primitive members
        var mt_list = std.ArrayListUnmanaged(ModuleType){};
        if (module_context) |ctx| {
            for (sorted) |m| {
                if (!types.isPrimitiveName(m)) {
                    if (ctx.get(m)) |mod_name| {
                        try mt_list.append(self.allocator, .{
                            .type_name = try self.allocator.dupe(u8, m),
                            .module_name = try self.allocator.dupe(u8, mod_name),
                        });
                    }
                }
            }
        }

        // Build name: "OrhonUnion_i32_str" (primitives) or "OrhonUnion_i32_modname_MyStruct" (user types)
        var buf = std.ArrayListUnmanaged(u8){};
        try buf.appendSlice(self.allocator, "OrhonUnion");
        for (sorted) |m| {
            try buf.append(self.allocator, '_');
            // Include module name for user types to avoid collisions
            if (module_context) |ctx| {
                if (!types.isPrimitiveName(m)) {
                    if (ctx.get(m)) |mod_name| {
                        try buf.appendSlice(self.allocator, mod_name);
                        try buf.append(self.allocator, '_');
                    }
                }
            }
            try buf.appendSlice(self.allocator, m);
        }
        const name = try self.allocator.dupe(u8, buf.items);
        buf.deinit(self.allocator);

        try self.entries.append(self.allocator, .{
            .members = sorted,
            .name = name,
            .module_types = try mt_list.toOwnedSlice(self.allocator),
        });
        return name;
    }
};

// ── Tests ───────────────────────────────────────────────────

test "union registry - canonicalize" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "str" }, null);
    const name2 = try reg.canonicalize(&.{ "str", "i32" }, null);

    // Same structural union → same name
    try std.testing.expectEqualStrings(name1, name2);
    try std.testing.expect(std.mem.indexOf(u8, name1, "OrhonUnion") != null);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "union registry - different unions" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "str" }, null);
    const name2 = try reg.canonicalize(&.{ "i32", "f32" }, null);

    try std.testing.expect(!std.mem.eql(u8, name1, name2));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
}

test "union registry - user types include module name" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    // Set up module context: MyStruct is defined in module "shapes"
    var ctx = std.StringHashMapUnmanaged([]const u8){};
    defer ctx.deinit(alloc);
    try ctx.put(alloc, "MyStruct", "shapes");

    const name = try reg.canonicalize(&.{ "i32", "MyStruct" }, &ctx);

    // Name should include module name for user type
    try std.testing.expect(std.mem.indexOf(u8, name, "shapes_MyStruct") != null);
    try std.testing.expect(std.mem.indexOf(u8, name, "i32") != null);

    // Entry should have module_types for MyStruct
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items[0].module_types.len);
    try std.testing.expectEqualStrings("MyStruct", reg.entries.items[0].module_types[0].type_name);
    try std.testing.expectEqualStrings("shapes", reg.entries.items[0].module_types[0].module_name);
}

test "union registry - same user type from same module deduplicates" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    var ctx = std.StringHashMapUnmanaged([]const u8){};
    defer ctx.deinit(alloc);
    try ctx.put(alloc, "Point", "geo");

    const name1 = try reg.canonicalize(&.{ "i32", "Point" }, &ctx);
    const name2 = try reg.canonicalize(&.{ "Point", "i32" }, &ctx);

    try std.testing.expectEqualStrings(name1, name2);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "union registry - restoreEntry" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    // Restore an entry
    try reg.restoreEntry("OrhonUnion_i32_str", &.{ "i32", "str" }, &.{});
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try std.testing.expectEqualStrings("OrhonUnion_i32_str", reg.entries.items[0].name);

    // Restore same entry again — deduplicates
    try reg.restoreEntry("OrhonUnion_i32_str", &.{ "i32", "str" }, &.{});
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);

    // canonicalize with same members returns the restored name
    const name = try reg.canonicalize(&.{ "str", "i32" }, null);
    try std.testing.expectEqualStrings("OrhonUnion_i32_str", name);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "union registry - restoreEntry with module types" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    try reg.restoreEntry("OrhonUnion_i32_shapes_Point", &.{ "Point", "i32" }, &.{
        .{ .type_name = "Point", .module_name = "shapes" },
    });
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items[0].module_types.len);
    try std.testing.expectEqualStrings("Point", reg.entries.items[0].module_types[0].type_name);
    try std.testing.expectEqualStrings("shapes", reg.entries.items[0].module_types[0].module_name);
}
