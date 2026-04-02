// allocator.zig — implementation for std::allocator module
// Wraps Zig allocators in uniform structs for Orhon.

const std = @import("std");

// ── SMP — general-purpose allocator (wraps GeneralPurposeAllocator) ──

pub const SMP = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    pub fn create() SMP {
        return .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };
    }

    pub fn deinit(self: *SMP) void {
        _ = self.gpa.deinit();
    }

    pub fn allocator(self: *SMP) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

// ── Arena — batch allocator, freeAll releases everything ──

pub const Arena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn create() Arena {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }

    pub fn freeAll(self: *Arena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *Arena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ── Page — OS page allocator (stateless, wrapped for uniform interface) ──

pub const Page = struct {
    pub fn create() Page {
        return .{};
    }

    pub fn allocator(_: *const Page) std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

// ── Tests ──

test "SMP create and deinit" {
    var smp = SMP.create();
    const alloc = smp.allocator();
    const ptr = try alloc.create(i32);
    ptr.* = 42;
    try std.testing.expectEqual(42, ptr.*);
    alloc.destroy(ptr);
    _ = smp.deinit();
}

test "Arena create, allocate, freeAll, deinit" {
    var arena = Arena.create();
    const alloc = arena.allocator();
    const ptr = try alloc.create(i32);
    ptr.* = 99;
    try std.testing.expectEqual(99, ptr.*);
    arena.freeAll();
    arena.deinit();
}

test "Page create and allocate" {
    var page = Page.create();
    const alloc = page.allocator();
    const ptr = try alloc.create(i32);
    ptr.* = 77;
    try std.testing.expectEqual(77, ptr.*);
    alloc.destroy(ptr);
}
