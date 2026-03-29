// mir_registry.zig — Canonical union type deduplication

const std = @import("std");
const mir_types = @import("mir_types.zig");

pub const RT = mir_types.RT;

// ── Union Registry ──────────────────────────────────────────

/// Canonical union type deduplication.
/// Same structural union across functions shares one Zig type name.
pub const UnionRegistry = struct {
    /// Sorted member names → canonical Zig type name
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        members: []const []const u8,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) UnionRegistry {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.members);
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    /// Get or create a canonical name for a union type.
    pub fn canonicalize(self: *UnionRegistry, members: []const []const u8) ![]const u8 {
        const sorted = try self.allocator.alloc([]const u8, members.len);
        @memcpy(sorted, members);
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
                    self.allocator.free(sorted);
                    return entry.name;
                }
            }
        }

        // Build name: "OrhonUnion_i32_String"
        var buf = std.ArrayListUnmanaged(u8){};
        try buf.appendSlice(self.allocator, "OrhonUnion");
        for (sorted) |m| {
            try buf.append(self.allocator, '_');
            try buf.appendSlice(self.allocator, m);
        }
        const name = try self.allocator.dupe(u8, buf.items);
        buf.deinit(self.allocator);

        try self.entries.append(self.allocator, .{
            .members = sorted,
            .name = name,
        });
        return name;
    }
};

// ── Tests ───────────────────────────────────────────────────

test "union registry - canonicalize" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "String" });
    const name2 = try reg.canonicalize(&.{ "String", "i32" });

    // Same structural union → same name
    try std.testing.expectEqualStrings(name1, name2);
    try std.testing.expect(std.mem.indexOf(u8, name1, "OrhonUnion") != null);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "union registry - different unions" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "String" });
    const name2 = try reg.canonicalize(&.{ "i32", "f32" });

    try std.testing.expect(!std.mem.eql(u8, name1, name2));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
}
