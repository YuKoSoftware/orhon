// allocator.zig — implementation for std::allocator module
// Wraps Zig allocators in uniform structs for Orhon.

const std = @import("std");

// ── SMP — general-purpose production allocator (lock-free, pooled) ──

pub const SMP = struct {
    pub fn create() SMP {
        return .{};
    }

    pub fn deinit(_: *SMP) void {}

    pub fn allocator(_: *const SMP) std.mem.Allocator {
        return std.heap.smp_allocator;
    }
};

// ── Debug — leak-detecting allocator for development ──

pub const Debug = struct {
    da: std.heap.DebugAllocator(.{}),

    pub fn create() Debug {
        return .{ .da = std.heap.DebugAllocator(.{}){} };
    }

    pub fn deinit(self: *Debug) void {
        _ = self.da.deinit();
    }

    pub fn allocator(self: *Debug) std.mem.Allocator {
        return self.da.allocator();
    }
};

// ── Arena — batch allocator, freeAll releases everything ──

pub const Arena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn create() Arena {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
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

// ── Page — OS page allocator (stateless, for large/aligned buffers) ──

pub const Page = struct {
    pub fn create() Page {
        return .{};
    }

    pub fn deinit(_: *Page) void {}

    pub fn allocator(_: *const Page) std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

// ── Fixed — allocates from a caller-provided buffer, no OS calls ──

pub const Fixed = struct {
    fba: std.heap.FixedBufferAllocator,

    pub fn create(buf: []u8) Fixed {
        return .{ .fba = std.heap.FixedBufferAllocator.init(buf) };
    }

    pub fn reset(self: *Fixed) void {
        self.fba.reset();
    }

    pub fn deinit(_: *Fixed) void {}

    pub fn allocator(self: *Fixed) std.mem.Allocator {
        return self.fba.allocator();
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
    smp.deinit();
}

test "Debug create and deinit" {
    var dbg = Debug.create();
    const alloc = dbg.allocator();
    const ptr = try alloc.create(i32);
    ptr.* = 42;
    try std.testing.expectEqual(42, ptr.*);
    alloc.destroy(ptr);
    dbg.deinit();
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
    page.deinit();
}

test "Fixed create and allocate" {
    var buf: [1024]u8 = undefined;
    var fixed = Fixed.create(&buf);
    const alloc = fixed.allocator();
    const ptr = try alloc.create(i32);
    ptr.* = 55;
    try std.testing.expectEqual(55, ptr.*);
    fixed.reset();
    fixed.deinit();
}
