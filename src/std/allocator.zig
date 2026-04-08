// allocator.zig — implementation for std::allocator module
// Wraps Zig allocators in uniform structs for Orhon.

const std = @import("std");

/// Default allocator for std types — SMP (fastest general-purpose).
pub const default = std.heap.smp_allocator;

// ── SMP — general-purpose production allocator (lock-free, pooled) ──

/// General-purpose production allocator using lock-free pooled allocation.
pub const SMP = struct {
    /// Create a new SMP allocator instance.
    pub fn create() SMP {
        return .{};
    }

    /// Release the SMP allocator (no-op, stateless).
    pub fn deinit(_: *SMP) void {}

    /// Return the underlying Zig SMP allocator interface.
    pub fn allocator(_: *const SMP) std.mem.Allocator {
        return std.heap.smp_allocator;
    }
};

// ── Debug — leak-detecting allocator for development ──

/// Leak-detecting allocator for development and testing.
pub const Debug = struct {
    da: std.heap.DebugAllocator(.{}),

    /// Create a new Debug allocator instance.
    pub fn create() Debug {
        return .{ .da = std.heap.DebugAllocator(.{}){} };
    }

    /// Release the Debug allocator and report any detected leaks.
    pub fn deinit(self: *Debug) void {
        _ = self.da.deinit();
    }

    /// Return the underlying Zig debug allocator interface.
    pub fn allocator(self: *Debug) std.mem.Allocator {
        return self.da.allocator();
    }
};

// ── Arena — batch allocator, freeAll releases everything ──

/// Batch allocator that frees all allocations at once.
pub const Arena = struct {
    arena: std.heap.ArenaAllocator,

    /// Create a new Arena allocator backed by the SMP allocator.
    pub fn create() Arena {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
    }

    /// Release all allocations while retaining capacity for reuse.
    pub fn freeAll(self: *Arena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Release the Arena allocator and all backing memory.
    pub fn deinit(self: *Arena) void {
        self.arena.deinit();
    }

    /// Return the underlying Zig arena allocator interface.
    pub fn allocator(self: *Arena) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// ── Page — OS page allocator (stateless, for large/aligned buffers) ──

/// OS page allocator for large or page-aligned buffers (stateless).
pub const Page = struct {
    /// Create a new Page allocator instance.
    pub fn create() Page {
        return .{};
    }

    /// Release the Page allocator (no-op, stateless).
    pub fn deinit(_: *Page) void {}

    /// Return the underlying Zig page allocator interface.
    pub fn allocator(_: *const Page) std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

// ── Fixed — allocates from a caller-provided buffer, no OS calls ──

/// Fixed-buffer allocator that allocates from a caller-provided slice with no OS calls.
pub const Fixed = struct {
    fba: std.heap.FixedBufferAllocator,

    /// Create a new Fixed allocator backed by the given buffer.
    pub fn create(buf: []u8) Fixed {
        return .{ .fba = std.heap.FixedBufferAllocator.init(buf) };
    }

    /// Reset the allocator to the beginning of the buffer, allowing reuse.
    pub fn reset(self: *Fixed) void {
        self.fba.reset();
    }

    /// Release the Fixed allocator (no-op, buffer is caller-owned).
    pub fn deinit(_: *Fixed) void {}

    /// Return the underlying Zig fixed-buffer allocator interface.
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
