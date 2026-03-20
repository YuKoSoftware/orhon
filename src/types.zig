// types.zig — Kodr type system shared definitions
// Used by declarations, resolver, ownership, borrow, and propagation passes.

const std = @import("std");
const parser = @import("parser.zig");
const K = @import("constants.zig");

/// Ownership state of a variable — used by ownership analysis pass
pub const OwnershipState = enum {
    owned, // this scope owns the value
    moved, // value has been moved out
    borrowed, // currently borrowed (immutable)
    mut_borrowed, // currently mutably borrowed
};

/// Structured type representation — preserves full type information
/// from AST type nodes so downstream passes don't need string matching.
pub const ResolvedType = union(enum) {
    /// Primitive types: i32, f64, bool, String, void, etc.
    primitive: []const u8,
    /// User-defined types: struct/enum/bitfield names
    named: []const u8,
    /// Error type
    err,
    /// Null type
    null_type,
    /// Slice: []T
    slice: *const ResolvedType,
    /// Fixed-size array: [N]T
    array: Array,
    /// Error union: (Error | T)
    error_union: *const ResolvedType,
    /// Null union: (null | T)
    null_union: *const ResolvedType,
    /// General union: (A | B | C) — not error or null specific
    union_type: []const ResolvedType,
    /// Named tuple: (a: T, b: U)
    tuple: []const TupleField,
    /// Function pointer: func(T) R
    func_ptr: FuncPtr,
    /// Generic type: List(i32), Map(K,V), Set(T)
    generic: Generic,
    /// Pointer: Ptr(T), const &T, var &T
    ptr: Ptr,
    /// Type not yet resolved (e.g. inferred from context)
    inferred,
    /// Type from another module or otherwise unknown
    unknown,

    pub const Array = struct {
        elem: *const ResolvedType,
        size: *parser.Node, // size expression node (e.g. int literal "5")
    };

    pub const TupleField = struct {
        name: []const u8,
        type_: ResolvedType,
    };

    pub const FuncPtr = struct {
        params: []const ResolvedType,
        return_type: *const ResolvedType,
    };

    pub const Generic = struct {
        name: []const u8,
        args: []const ResolvedType,
    };

    pub const Ptr = struct {
        kind: []const u8, // "var &" or "const &"
        elem: *const ResolvedType,
    };

    /// Returns true if this type is a primitive (copy semantics, no ownership transfer)
    pub fn isPrimitive(self: ResolvedType) bool {
        return switch (self) {
            .primitive => true,
            .err, .null_type => true,
            .inferred, .unknown => false,
            else => false,
        };
    }

    /// Returns true if this is an error union: (Error | T)
    pub fn isErrorUnion(self: ResolvedType) bool {
        return self == .error_union;
    }

    /// Returns true if this is a null union: (null | T)
    pub fn isNullUnion(self: ResolvedType) bool {
        return self == .null_union;
    }

    /// Returns true if this is any kind of union
    pub fn isUnion(self: ResolvedType) bool {
        return switch (self) {
            .error_union, .null_union, .union_type => true,
            else => false,
        };
    }

    /// Get the inner type of an error or null union
    pub fn innerType(self: ResolvedType) ?*const ResolvedType {
        return switch (self) {
            .error_union => |t| t,
            .null_union => |t| t,
            else => null,
        };
    }

    /// String representation for backwards compatibility and error messages
    pub fn name(self: ResolvedType) []const u8 {
        return switch (self) {
            .primitive => |n| n,
            .named => |n| n,
            .err => K.Type.ERROR,
            .null_type => K.Type.NULL,
            .slice => "slice",
            .array => "array",
            .error_union => "error_union",
            .null_union => "null_union",
            .union_type => "union",
            .tuple => "tuple",
            .func_ptr => "func",
            .generic => |g| g.name,
            .ptr => |p| p.kind,
            .inferred => "inferred",
            .unknown => "unknown",
        };
    }
};

/// Convert a parser type AST node into a ResolvedType.
/// Uses the arena allocator for any heap-allocated inner types.
pub fn resolveTypeNode(alloc: std.mem.Allocator, node: *parser.Node) anyerror!ResolvedType {
    return switch (node.*) {
        .type_named => |n| classifyNamed(n),
        .type_primitive => |p| .{ .primitive = p },

        .type_slice => |elem| {
            const inner = try alloc.create(ResolvedType);
            inner.* = try resolveTypeNode(alloc, elem);
            return .{ .slice = inner };
        },

        .type_array => |a| {
            const inner = try alloc.create(ResolvedType);
            inner.* = try resolveTypeNode(alloc, a.elem);
            return .{ .array = .{ .elem = inner, .size = a.size } };
        },

        .type_union => |members| {
            return resolveUnion(alloc, members);
        },

        .type_tuple_named => |fields| {
            var resolved = try alloc.alloc(ResolvedType.TupleField, fields.len);
            for (fields, 0..) |f, i| {
                resolved[i] = .{
                    .name = f.name,
                    .type_ = try resolveTypeNode(alloc, f.type_node),
                };
            }
            return .{ .tuple = resolved };
        },

        .type_tuple_anon => |members| {
            // Anonymous tuple — treat as union
            return resolveUnion(alloc, members);
        },

        .type_func => |f| {
            var params = try alloc.alloc(ResolvedType, f.params.len);
            for (f.params, 0..) |p, i| {
                params[i] = try resolveTypeNode(alloc, p);
            }
            const ret = try alloc.create(ResolvedType);
            ret.* = try resolveTypeNode(alloc, f.ret);
            return .{ .func_ptr = .{ .params = params, .return_type = ret } };
        },

        .type_generic => |g| {
            var args = try alloc.alloc(ResolvedType, g.args.len);
            for (g.args, 0..) |a, i| {
                args[i] = try resolveTypeNode(alloc, a);
            }
            return .{ .generic = .{ .name = g.name, .args = args } };
        },

        .type_ptr => |p| {
            const inner = try alloc.create(ResolvedType);
            inner.* = try resolveTypeNode(alloc, p.elem);
            return .{ .ptr = .{ .kind = p.kind, .elem = inner } };
        },

        else => .unknown,
    };
}

/// Classify a named type string into the appropriate ResolvedType variant
fn classifyNamed(n: []const u8) ResolvedType {
    // Check for Error and null first
    if (std.mem.eql(u8, n, K.Type.ERROR)) return .err;
    if (std.mem.eql(u8, n, K.Type.NULL)) return .null_type;
    // Check primitives
    if (isPrimitiveName(n)) return .{ .primitive = n };
    // Everything else is a named type (struct/enum/bitfield/etc.)
    return .{ .named = n };
}

/// Resolve a union type node, detecting (Error | T) and (null | T) as special cases
fn resolveUnion(alloc: std.mem.Allocator, members: []*parser.Node) !ResolvedType {
    // Check for (Error | T) or (null | T) — two-member unions with a special first type
    if (members.len == 2) {
        const first = members[0];
        const second = members[1];
        if (first.* == .type_named) {
            if (std.mem.eql(u8, first.type_named, K.Type.ERROR)) {
                const inner = try alloc.create(ResolvedType);
                inner.* = try resolveTypeNode(alloc, second);
                return .{ .error_union = inner };
            }
            if (std.mem.eql(u8, first.type_named, K.Type.NULL)) {
                const inner = try alloc.create(ResolvedType);
                inner.* = try resolveTypeNode(alloc, second);
                return .{ .null_union = inner };
            }
        }
    }
    // General union: (A | B | C)
    var resolved = try alloc.alloc(ResolvedType, members.len);
    for (members, 0..) |m, i| {
        resolved[i] = try resolveTypeNode(alloc, m);
    }
    return .{ .union_type = resolved };
}

/// Check if a name is a primitive type (copy semantics)
pub fn isPrimitiveName(n: []const u8) bool {
    const primitives = [_][]const u8{
        "i8",    "i16",  "i32",  "i64",  "i128",
        "u8",    "u16",  "u32",  "u64",  "u128",
        "isize", "usize",
        "f16",   "bf16", "f32",  "f64",  "f128",
        "bool",  K.Type.STRING, K.Type.VOID,
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, n, p)) return true;
    }
    return false;
}

test "resolvedtype - primitive detection" {
    const t_i32 = ResolvedType{ .primitive = "i32" };
    try std.testing.expect(t_i32.isPrimitive());

    const t_struct = ResolvedType{ .named = "Player" };
    try std.testing.expect(!t_struct.isPrimitive());
}

test "resolvedtype - union detection" {
    const alloc = std.testing.allocator;

    const inner = try alloc.create(ResolvedType);
    defer alloc.destroy(inner);
    inner.* = .{ .primitive = "i32" };

    const err_union = ResolvedType{ .error_union = inner };
    try std.testing.expect(err_union.isErrorUnion());
    try std.testing.expect(err_union.isUnion());
    try std.testing.expect(!err_union.isNullUnion());

    const null_union = ResolvedType{ .null_union = inner };
    try std.testing.expect(null_union.isNullUnion());
    try std.testing.expect(null_union.isUnion());
    try std.testing.expect(!null_union.isErrorUnion());
}

test "resolvedtype - name for error messages" {
    const t = ResolvedType{ .primitive = "i32" };
    try std.testing.expectEqualStrings("i32", t.name());

    const e = ResolvedType{ .err = {} };
    try std.testing.expectEqualStrings("Error", e.name());
}

test "classifyNamed" {
    const err = classifyNamed("Error");
    try std.testing.expect(err == .err);

    const null_t = classifyNamed("null");
    try std.testing.expect(null_t == .null_type);

    const prim = classifyNamed("i32");
    try std.testing.expect(prim == .primitive);

    const named = classifyNamed("Player");
    try std.testing.expect(named == .named);
}

test "isPrimitiveName" {
    try std.testing.expect(isPrimitiveName("i32"));
    try std.testing.expect(isPrimitiveName("String"));
    try std.testing.expect(!isPrimitiveName("Player"));
    try std.testing.expect(!isPrimitiveName("List"));
}
