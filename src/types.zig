// types.zig — Orhon type system shared definitions
// Used by declarations, resolver, ownership, borrow, and propagation passes.

const std = @import("std");
const parser = @import("parser.zig");
const K = @import("constants.zig");

/// Primitive type enum — replaces string-based primitive type identification.
/// Exhaustive switching, zero-cost comparison, no typo risk.
pub const Primitive = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
    isize,
    usize,
    f16,
    f32,
    f64,
    f128,
    bool,
    string,
    void,
    @"type",
    /// Unresolved integer literal — requires explicit type annotation
    numeric_literal,
    /// Unresolved float literal — requires explicit type annotation
    float_literal,

    /// Convert from AST/source name string. Returns null for non-primitive names.
    pub fn fromName(n: []const u8) ?Primitive {
        const map = std.StaticStringMap(Primitive).initComptime(.{
            .{ "i8", .i8 },
            .{ "i16", .i16 },
            .{ "i32", .i32 },
            .{ "i64", .i64 },
            .{ "i128", .i128 },
            .{ "u8", .u8 },
            .{ "u16", .u16 },
            .{ "u32", .u32 },
            .{ "u64", .u64 },
            .{ "u128", .u128 },
            .{ "isize", .isize },
            .{ "usize", .usize },
            .{ "f16", .f16 },
            .{ "f32", .f32 },
            .{ "f64", .f64 },
            .{ "f128", .f128 },
            .{ "bool", .bool },
            .{ "str", .string },
            .{ "void", .void },
            .{ "type", .@"type" },
            .{ "numeric_literal", .numeric_literal },
            .{ "float_literal", .float_literal },
        });
        return map.get(n);
    }

    /// Convert to the Orhon source name string.
    pub fn toName(self: Primitive) []const u8 {
        return switch (self) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .i128 => "i128",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .u128 => "u128",
            .isize => "isize",
            .usize => "usize",
            .f16 => "f16",
            .f32 => "f32",
            .f64 => "f64",
            .f128 => "f128",
            .bool => "bool",
            .string => "str",
            .void => "void",
            .@"type" => "type",
            .numeric_literal => "numeric_literal",
            .float_literal => "float_literal",
        };
    }

    /// Convert to the Zig equivalent type name.
    pub fn toZig(self: Primitive) []const u8 {
        return switch (self) {
            .string => "[]const u8",
            .void => "void",
            .bool => "bool",
            .@"type" => "type",
            .numeric_literal => "comptime_int",
            .float_literal => "comptime_float",
            // All others map 1:1 to Zig
            else => self.toName(),
        };
    }

    pub fn isInteger(self: Primitive) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            => true,
            else => false,
        };
    }

    pub fn isUnsigned(self: Primitive) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .u128, .usize => true,
            else => false,
        };
    }

    pub fn isFloat(self: Primitive) bool {
        return switch (self) {
            .f16, .f32, .f64, .f128 => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Primitive) bool {
        return self.isInteger() or self.isFloat() or
            self == .numeric_literal or self == .float_literal;
    }

    /// Map an Orhon type name string to its Zig equivalent.
    /// Returns the original string unchanged if it's not a primitive name.
    pub fn nameToZig(name: []const u8) []const u8 {
        if (fromName(name)) |p| return p.toZig();
        return name;
    }
};

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
    primitive: Primitive,
    /// User-defined types: struct/enum names
    named: []const u8,
    /// Error type
    err,
    /// Null type
    null_type,
    /// Slice: []T
    slice: *const ResolvedType,
    /// Fixed-size array: [N]T
    array: Array,
    /// General union: (A | B | C) — not error or null specific
    union_type: []const ResolvedType,
    /// Named tuple: (a: T, b: U)
    tuple: []const TupleField,
    /// Function pointer: func(T) R
    func_ptr: FuncPtr,
    /// Generic type: List(i32), Map(K,V), Set(T)
    generic: Generic,
    /// Borrow reference: const &T, mut &T
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
        kind: parser.PtrKind,
        elem: *const ResolvedType,
    };

    /// Returns true if this type is a primitive (copy semantics, no ownership transfer)
    pub fn isPrimitive(self: ResolvedType) bool {
        return switch (self) {
            .primitive => true,
            .err, .null_type => true,
            .inferred, .unknown => false,
            .named, .slice, .array, .union_type, .tuple, .func_ptr, .generic, .ptr => false,
        };
    }

    /// Returns true if this is any kind of union
    pub fn isUnion(self: ResolvedType) bool {
        return self == .union_type;
    }

    /// Returns true if this union contains Error as a member: (Error | T)
    pub fn unionContainsError(self: ResolvedType) bool {
        if (self != .union_type) return false;
        for (self.union_type) |m| {
            if (m == .err) return true;
        }
        return false;
    }

    /// Returns true if this union contains null as a member: (null | T)
    pub fn unionContainsNull(self: ResolvedType) bool {
        if (self != .union_type) return false;
        for (self.union_type) |m| {
            if (m == .null_type) return true;
        }
        return false;
    }

    /// Get the non-Error/non-null inner type of a union like (Error | T) or (null | T).
    /// Returns null if there are multiple non-special members.
    pub fn unionInnerType(self: ResolvedType) ?ResolvedType {
        if (self != .union_type) return null;
        var inner: ?ResolvedType = null;
        for (self.union_type) |m| {
            if (m == .err or m == .null_type) continue;
            if (inner != null) return null; // multiple non-special members
            inner = m;
        }
        return inner;
    }

    /// String representation for backwards compatibility and error messages
    pub fn name(self: ResolvedType) []const u8 {
        return switch (self) {
            .primitive => |p| p.toName(),
            .named => |n| n,
            .err => "Error",
            .null_type => "null",
            .slice => "[]T",
            .array => "[N]T",
            .union_type => "(A | B)",
            .tuple => "(a: T, b: U)",
            .func_ptr => "func(T) U",
            .generic => |g| g.name,
            .ptr => |p| if (p.kind == .mut_ref) "mut&" else "const&",
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
            // Generic type: List(T), Map(K,V), Vector(N, T), etc.
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

        // Non-type AST nodes (77+ variants) — only type_* nodes resolve to types
        else => .unknown,
    };
}

/// Classify a named type string into the appropriate ResolvedType variant
fn classifyNamed(n: []const u8) ResolvedType {
    // Check for Error and null first
    if (std.mem.eql(u8, n, K.Type.ERROR)) return .err;
    if (std.mem.eql(u8, n, K.Type.NULL)) return .null_type;
    // Check primitives
    if (Primitive.fromName(n)) |prim| return .{ .primitive = prim };
    // Everything else is a named type (struct/enum/etc.)
    return .{ .named = n };
}

/// Resolve a union type node. Flattens nested unions, checks for duplicates.
/// Error and null are valid union members: (Error | T) → anyerror!T, (null | T) → ?T.
fn resolveUnion(alloc: std.mem.Allocator, members: []*parser.Node) !ResolvedType {
    // Phase 1: Resolve all members, flattening nested unions
    var flat = std.ArrayListUnmanaged(ResolvedType){};
    defer flat.deinit(alloc);

    for (members) |m| {
        const resolved = try resolveTypeNode(alloc, m);
        if (resolved == .union_type) {
            for (resolved.union_type) |inner| {
                try flat.append(alloc, inner);
            }
        } else {
            try flat.append(alloc, resolved);
        }
    }

    // Phase 2: Check for duplicate type names
    for (flat.items, 0..) |a, i| {
        const a_name = a.name();
        for (flat.items[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a_name, b.name())) {
                return error.DuplicateUnionMember;
            }
        }
    }

    // Phase 3: Build union
    const result = try alloc.alloc(ResolvedType, flat.items.len);
    @memcpy(result, flat.items);
    return .{ .union_type = result };
}

/// Find the name of the first duplicate member in a union type node.
/// Used for error reporting when resolveUnion returns DuplicateUnionMember.
pub fn findDuplicateUnionMember(alloc: std.mem.Allocator, members: []*parser.Node) ?[]const u8 {
    var resolved = std.ArrayListUnmanaged(ResolvedType){};
    defer resolved.deinit(alloc);

    for (members) |m| {
        const r = resolveTypeNode(alloc, m) catch continue;
        if (r == .union_type) {
            for (r.union_type) |inner| {
                resolved.append(alloc, inner) catch continue;
            }
        } else {
            resolved.append(alloc, r) catch continue;
        }
    }

    for (resolved.items, 0..) |a, i| {
        const a_name = a.name();
        for (resolved.items[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a_name, b.name())) return a_name;
        }
    }
    return null;
}

/// Check if a name is a primitive type (copy semantics)
pub fn isPrimitiveName(n: []const u8) bool {
    if (Primitive.fromName(n)) |p| {
        // numeric_literal and float_literal are pseudo-types, not user-facing primitives
        return p != .numeric_literal and p != .float_literal and p != .@"type";
    }
    return false;
}

test "resolvedtype - primitive detection" {
    const t_i32 = ResolvedType{ .primitive = .i32 };
    try std.testing.expect(t_i32.isPrimitive());

    const t_struct = ResolvedType{ .named = "Player" };
    try std.testing.expect(!t_struct.isPrimitive());
}

test "resolvedtype - union detection" {
    // (Error | i32) union
    const err_union = ResolvedType{ .union_type = &.{ ResolvedType.err, ResolvedType{ .primitive = .i32 } } };
    try std.testing.expect(err_union.unionContainsError());
    try std.testing.expect(!err_union.unionContainsNull());
    try std.testing.expect(err_union.unionInnerType().?.primitive == .i32);

    // (null | i32) union
    const null_union = ResolvedType{ .union_type = &.{ ResolvedType.null_type, ResolvedType{ .primitive = .i32 } } };
    try std.testing.expect(null_union.unionContainsNull());
    try std.testing.expect(!null_union.unionContainsError());
    try std.testing.expect(null_union.unionInnerType().?.primitive == .i32);

    // Plain union (i32 | str)
    const plain_union = ResolvedType{ .union_type = &.{ ResolvedType{ .primitive = .i32 }, ResolvedType{ .primitive = .string } } };
    try std.testing.expect(!plain_union.unionContainsError());
    try std.testing.expect(!plain_union.unionContainsNull());
}

test "resolvedtype - name for error messages" {
    const t = ResolvedType{ .primitive = .i32 };
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

test "Primitive.nameToZig" {
    try std.testing.expectEqualStrings("[]const u8", Primitive.nameToZig("str"));
    try std.testing.expectEqualStrings("i32", Primitive.nameToZig("i32"));
    try std.testing.expectEqualStrings("Player", Primitive.nameToZig("Player"));
}

test "isPrimitiveName" {
    try std.testing.expect(isPrimitiveName("i32"));
    try std.testing.expect(isPrimitiveName("str"));
    try std.testing.expect(!isPrimitiveName("Player"));
    try std.testing.expect(!isPrimitiveName("List"));
}

test "resolveUnion - allows Error in union" {
    const alloc = std.testing.allocator;
    const err_node = try alloc.create(parser.Node);
    defer alloc.destroy(err_node);
    err_node.* = .{ .type_named = "Error" };
    const i32_node = try alloc.create(parser.Node);
    defer alloc.destroy(i32_node);
    i32_node.* = .{ .type_named = "i32" };
    var members = [_]*parser.Node{ err_node, i32_node };
    const result = try resolveUnion(alloc, &members);
    try std.testing.expect(result == .union_type);
    try std.testing.expect(result.unionContainsError());
    alloc.free(result.union_type);
}

test "resolveUnion - allows null in union" {
    const alloc = std.testing.allocator;
    const null_node = try alloc.create(parser.Node);
    defer alloc.destroy(null_node);
    null_node.* = .{ .type_named = "null" };
    const i32_node = try alloc.create(parser.Node);
    defer alloc.destroy(i32_node);
    i32_node.* = .{ .type_named = "i32" };
    var members = [_]*parser.Node{ null_node, i32_node };
    const result = try resolveUnion(alloc, &members);
    try std.testing.expect(result == .union_type);
    try std.testing.expect(result.unionContainsNull());
    alloc.free(result.union_type);
}

test "resolveUnion - errors on duplicate type" {
    const alloc = std.testing.allocator;
    const n1 = try alloc.create(parser.Node);
    defer alloc.destroy(n1);
    n1.* = .{ .type_named = "i32" };
    const n2 = try alloc.create(parser.Node);
    defer alloc.destroy(n2);
    n2.* = .{ .type_named = "i32" };
    var members = [_]*parser.Node{ n1, n2 };
    const result = resolveUnion(alloc, &members);
    try std.testing.expectError(error.DuplicateUnionMember, result);
}
