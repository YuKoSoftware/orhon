// scope.zig — Generic scope with parent-chain traversal
// Used by resolver (pass 5), ownership (pass 6), and propagation (pass 8).

const std = @import("std");

/// Generic scope frame: string-keyed hashmap with optional parent link.
/// Provides init/deinit, define, lookup (immutable), and lookupPtr (mutable)
/// with automatic parent-chain traversal.
pub fn ScopeBase(comptime V: type) type {
    return struct {
        const Self = @This();

        vars: std.StringHashMap(V),
        parent: ?*Self,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, parent: ?*Self) Self {
            return .{
                .vars = std.StringHashMap(V).init(allocator),
                .parent = parent,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.vars.deinit();
        }

        /// Immutable lookup — walks parent chain, returns copy of value.
        pub fn lookup(self: *const Self, name: []const u8) ?V {
            if (self.vars.get(name)) |v| return v;
            if (self.parent) |p| return p.lookup(name);
            return null;
        }

        /// Mutable lookup — walks parent chain, returns pointer to value.
        pub fn lookupPtr(self: *Self, name: []const u8) ?*V {
            if (self.vars.getPtr(name)) |v| return v;
            if (self.parent) |p| return p.lookupPtr(name);
            return null;
        }

        /// Define a name in the current scope (does not walk parents).
        pub fn define(self: *Self, name: []const u8, v: V) !void {
            try self.vars.put(name, v);
        }
    };
}

// --- tests ---

const testing = std.testing;

test "ScopeBase — define and lookup" {
    var scope = ScopeBase(i32).init(testing.allocator, null);
    defer scope.deinit();

    try scope.define("x", 42);
    try testing.expectEqual(@as(i32, 42), scope.lookup("x").?);
    try testing.expect(scope.lookup("y") == null);
}

test "ScopeBase — parent chain lookup" {
    var parent = ScopeBase(i32).init(testing.allocator, null);
    defer parent.deinit();
    try parent.define("x", 1);

    var child = ScopeBase(i32).init(testing.allocator, &parent);
    defer child.deinit();
    try child.define("y", 2);

    // child sees own and parent vars
    try testing.expectEqual(@as(i32, 2), child.lookup("y").?);
    try testing.expectEqual(@as(i32, 1), child.lookup("x").?);
    try testing.expect(child.lookup("z") == null);
}

test "ScopeBase — child shadows parent" {
    var parent = ScopeBase(i32).init(testing.allocator, null);
    defer parent.deinit();
    try parent.define("x", 1);

    var child = ScopeBase(i32).init(testing.allocator, &parent);
    defer child.deinit();
    try child.define("x", 99);

    try testing.expectEqual(@as(i32, 99), child.lookup("x").?);
    try testing.expectEqual(@as(i32, 1), parent.lookup("x").?);
}

test "ScopeBase — lookupPtr mutates in parent" {
    var parent = ScopeBase(i32).init(testing.allocator, null);
    defer parent.deinit();
    try parent.define("x", 1);

    var child = ScopeBase(i32).init(testing.allocator, &parent);
    defer child.deinit();

    // mutate parent's value through child's lookupPtr
    if (child.lookupPtr("x")) |ptr| {
        ptr.* = 42;
    }
    try testing.expectEqual(@as(i32, 42), parent.lookup("x").?);
}

test "ScopeBase — lookupPtr returns null for missing" {
    var scope = ScopeBase(i32).init(testing.allocator, null);
    defer scope.deinit();

    try testing.expect(scope.lookupPtr("x") == null);
}
