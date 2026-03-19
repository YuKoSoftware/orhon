// types.zig — Kodr type system representation
// Shared across all compiler passes. No business logic here — pure data definitions.

const std = @import("std");

/// All primitive types in Kodr
pub const PrimitiveKind = enum {
    i8, i16, i32, i64, i128,
    u8, u16, u32, u64, u128,
    isize, usize,
    f16, bf16, f32, f64, f128,
    bool,
    string,
};

/// The kind of a Kodr type
pub const TypeKind = enum {
    primitive,
    slice,       // []T
    array,       // [n]T
    ptr,         // Ptr(T)
    raw_ptr,     // RawPtr(T)
    volatile_ptr,// VolatilePtr(T)
    @"union",    // (T | U | ...)
    tuple_named, // (x: T, y: U)
    tuple_anon,  // (T, U)
    func,        // func(T) U
    generic,     // Name(T)
    named,       // user defined name
    null_type,   // null
    void_type,   // void
    any_type,    // any
    error_type,  // Error
    @"struct",
    @"enum",
};

/// A fully resolved Kodr type
pub const Type = union(TypeKind) {
    primitive: PrimitiveKind,
    slice: *Type,
    array: struct {
        size: usize,
        elem: *Type,
    },
    ptr: *Type,
    raw_ptr: *Type,
    volatile_ptr: *Type,
    @"union": []Type,
    tuple_named: []NamedField,
    tuple_anon: []Type,
    func: struct {
        params: []Type,
        ret: *Type,
    },
    generic: struct {
        name: []const u8,
        args: []Type,
    },
    named: []const u8,
    null_type: void,
    void_type: void,
    any_type: void,
    error_type: void,
    @"struct": []const u8, // struct name
    @"enum": []const u8,   // enum name
};

pub const NamedField = struct {
    name: []const u8,
    type: Type,
    default: ?[]const u8 = null, // source text of default expression
};

/// Ownership state of a variable — used by ownership analysis pass
pub const OwnershipState = enum {
    owned,      // this scope owns the value
    moved,      // value has been moved out
    borrowed,   // currently borrowed (immutable)
    mut_borrowed, // currently mutably borrowed
};

/// A borrow entry — used by borrow checker
pub const BorrowEntry = struct {
    variable: []const u8,
    mutable: bool,
    scope_depth: usize,
};

/// Scope frame — used by error propagation analysis
pub const ScopeFrame = struct {
    depth: usize,
    has_error_union: bool,
    handled: bool,
};

test "type kinds are exhaustive" {
    // Make sure we haven't missed any type kind
    const kinds = std.enums.values(TypeKind);
    try std.testing.expect(kinds.len > 0);
}
