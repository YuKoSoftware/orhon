// ptr.zig — Pointer wrapper types for Orhon std::ptr
//
// Ptr(T)         — safe single-value pointer, from borrows only
// RawPtr(T)      — unsafe indexable pointer, borrows or integer addresses
// VolatilePtr(T) — unsafe volatile pointer, hardware registers

const std = @import("std");

/// Safe single-value pointer. Wraps a Zig pointer obtained from a borrow.
/// Cannot be constructed from a raw integer address.
pub fn Ptr(comptime T: type) type {
    return struct {
        raw: *T,

        const Self = @This();

        /// Create a safe pointer from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = ref };
        }

        /// Read the pointed-to value.
        pub fn read(self: Self) T {
            return self.raw.*;
        }

        /// Write a value through the pointer.
        pub fn write(self: Self, val: T) void {
            self.raw.* = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}

/// Unsafe indexable pointer. Supports offset-based access and construction
/// from raw integer addresses. For FFI, C interop, and array-style access.
pub fn RawPtr(comptime T: type) type {
    return struct {
        raw: [*]T,

        const Self = @This();

        /// Create from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = @as([*]T, @ptrCast(ref)) };
        }

        /// Create from a raw integer address.
        pub fn fromAddress(addr: usize) Self {
            return .{ .raw = @as([*]T, @ptrFromInt(addr)) };
        }

        /// Read the value at offset n.
        pub fn at(self: Self, n: usize) T {
            return self.raw[n];
        }

        /// Write a value at offset n.
        pub fn set(self: Self, n: usize, val: T) void {
            self.raw[n] = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}

/// Unsafe volatile pointer. Every read and write is volatile — the compiler
/// never caches or reorders accesses. For memory-mapped hardware registers.
pub fn VolatilePtr(comptime T: type) type {
    return struct {
        raw: *volatile T,

        const Self = @This();

        /// Create from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = @as(*volatile T, @ptrCast(ref)) };
        }

        /// Create from a raw integer address.
        pub fn fromAddress(addr: usize) Self {
            return .{ .raw = @as(*volatile T, @ptrFromInt(addr)) };
        }

        /// Volatile read.
        pub fn read(self: Self) T {
            return self.raw.*;
        }

        /// Volatile write.
        pub fn write(self: Self, val: T) void {
            self.raw.* = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}
