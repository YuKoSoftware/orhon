// mem.zig — sidecar for std::mem module
// Allocator wrapper types with init/deinit/allocator + convenience methods.

const std = @import("std");

pub const DebugAlloc = struct {
    _impl: std.heap.DebugAllocator(.{}),

    pub fn init() DebugAlloc {
        return .{ ._impl = .{} };
    }
    pub fn deinit(self: *DebugAlloc) void {
        _ = self._impl.deinit();
    }
    pub fn allocator(self: *DebugAlloc) std.mem.Allocator {
        return self._impl.allocator();
    }
    pub fn alloc(self: *DebugAlloc, comptime T: type, n: usize) []T {
        return self.allocator().alloc(T, n) catch @panic("out of memory");
    }
    pub fn allocOne(self: *DebugAlloc, comptime T: type, val: T) *T {
        const ptr = self.allocator().create(T) catch @panic("out of memory");
        ptr.* = val;
        return ptr;
    }
    pub fn free(self: *DebugAlloc, ptr: anytype) void {
        const T = @TypeOf(ptr);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .one) {
                    self.allocator().destroy(ptr);
                } else {
                    self.allocator().free(ptr);
                }
            },
            else => self.allocator().free(ptr),
        }
    }
};

pub const ArenaAlloc = struct {
    _impl: std.heap.ArenaAllocator,

    pub fn init() ArenaAlloc {
        return .{ ._impl = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
    pub fn deinit(self: *ArenaAlloc) void {
        self._impl.deinit();
    }
    pub fn allocator(self: *ArenaAlloc) std.mem.Allocator {
        return self._impl.allocator();
    }
    pub fn alloc(self: *ArenaAlloc, comptime T: type, n: usize) []T {
        return self.allocator().alloc(T, n) catch @panic("out of memory");
    }
    pub fn allocOne(self: *ArenaAlloc, comptime T: type, val: T) *T {
        const ptr = self.allocator().create(T) catch @panic("out of memory");
        ptr.* = val;
        return ptr;
    }
    pub fn free(self: *ArenaAlloc, ptr: anytype) void {
        const T = @TypeOf(ptr);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .one) {
                    self.allocator().destroy(ptr);
                } else {
                    self.allocator().free(ptr);
                }
            },
            else => self.allocator().free(ptr),
        }
    }
    pub fn freeAll(self: *ArenaAlloc) void {
        _ = self._impl.reset(.free_all);
    }
};

pub const StackAlloc = struct {
    _impl: std.heap.FixedBufferAllocator,

    pub fn init(buf: []u8) StackAlloc {
        return .{ ._impl = std.heap.FixedBufferAllocator.init(buf) };
    }
    pub fn allocator(self: *StackAlloc) std.mem.Allocator {
        return self._impl.allocator();
    }
    pub fn alloc(self: *StackAlloc, comptime T: type, n: usize) []T {
        return self.allocator().alloc(T, n) catch @panic("out of memory");
    }
    pub fn allocOne(self: *StackAlloc, comptime T: type, val: T) *T {
        const ptr = self.allocator().create(T) catch @panic("out of memory");
        ptr.* = val;
        return ptr;
    }
    pub fn free(self: *StackAlloc, ptr: anytype) void {
        const T = @TypeOf(ptr);
        switch (@typeInfo(T)) {
            .pointer => |p| {
                if (p.size == .one) {
                    self.allocator().destroy(ptr);
                } else {
                    self.allocator().free(ptr);
                }
            },
            else => self.allocator().free(ptr),
        }
    }
};
