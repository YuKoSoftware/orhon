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
    bf16,
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
            .{ "bf16", .bf16 },
            .{ "f32", .f32 },
            .{ "f64", .f64 },
            .{ "f128", .f128 },
            .{ "bool", .bool },
            .{ "String", .string },
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
            .bf16 => "bf16",
            .f32 => "f32",
            .f64 => "f64",
            .f128 => "f128",
            .bool => "bool",
            .string => "String",
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

    pub fn isFloat(self: Primitive) bool {
        return switch (self) {
            .f16, .bf16, .f32, .f64, .f128 => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Primitive) bool {
        return self.isInteger() or self.isFloat() or
            self == .numeric_literal or self == .float_literal;
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
    /// Core language wrapper type: ErrorUnion(T), NullUnion(T), Handle(T), Ptr(T), etc.
    core_type: CoreType,
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

    pub const CoreType = struct {
        kind: Kind,
        inner: *const ResolvedType,

        pub const Kind = enum {
            error_union, // ErrorUnion(T) → anyerror!T
            null_union, // NullUnion(T) → ?T
            handle, // Handle(T) → _OrhonHandle(T)
            safe_ptr, // Ptr(T) → *T
            raw_ptr, // RawPtr(T) → [*]T
            volatile_ptr, // VolatilePtr(T) → *volatile T
        };
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

    /// Returns true if this is any kind of union
    pub fn isUnion(self: ResolvedType) bool {
        return self == .union_type;
    }

    /// Returns true if this is a specific core type kind
    pub fn isCoreType(self: ResolvedType, kind: CoreType.Kind) bool {
        return switch (self) {
            .core_type => |ct| ct.kind == kind,
            else => false,
        };
    }

    /// Get the inner type of a core type wrapper, or null
    pub fn coreInner(self: ResolvedType) ?*const ResolvedType {
        return switch (self) {
            .core_type => |ct| ct.inner,
            else => null,
        };
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
            .core_type => |ct| switch (ct.kind) {
                .error_union => "ErrorUnion(T)",
                .null_union => "NullUnion(T)",
                .handle => "Handle(T)",
                .safe_ptr => "Ptr(T)",
                .raw_ptr => "RawPtr(T)",
                .volatile_ptr => "VolatilePtr(T)",
            },
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
        .type_primitive => |p| blk: {
            break :blk if (Primitive.fromName(p)) |prim| ResolvedType{ .primitive = prim } else ResolvedType.unknown;
        },

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
            // Core language wrapper types → CoreType
            const core_kind: ?ResolvedType.CoreType.Kind = if (std.mem.eql(u8, g.name, "ErrorUnion"))
                .error_union
            else if (std.mem.eql(u8, g.name, "NullUnion"))
                .null_union
            else if (std.mem.eql(u8, g.name, "Handle"))
                .handle
            else if (std.mem.eql(u8, g.name, "Ptr"))
                .safe_ptr
            else if (std.mem.eql(u8, g.name, "RawPtr"))
                .raw_ptr
            else if (std.mem.eql(u8, g.name, "VolatilePtr"))
                .volatile_ptr
            else
                null;

            if (core_kind) |kind| {
                if (g.args.len > 0) {
                    const inner = try alloc.create(ResolvedType);
                    inner.* = try resolveTypeNode(alloc, g.args[0]);
                    return .{ .core_type = .{ .kind = kind, .inner = inner } };
                }
                return .unknown;
            }

            // User-defined generics: List(T), Map(K,V), etc.
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
    if (Primitive.fromName(n)) |prim| return .{ .primitive = prim };
    // Everything else is a named type (struct/enum/bitfield/etc.)
    return .{ .named = n };
}

/// Resolve a union type node. Flattens nested unions, bans Error and null as
/// members (use ErrorUnion(T) and NullUnion(T) instead), checks for duplicates.
fn resolveUnion(alloc: std.mem.Allocator, members: []*parser.Node) !ResolvedType {
    // Phase 1: Resolve all members, flattening nested unions
    var flat = std.ArrayListUnmanaged(ResolvedType){};
    defer flat.deinit(alloc);

    for (members) |m| {
        const resolved = try resolveTypeNode(alloc, m);
        // Ban Error and null in regular unions
        if (resolved == .err) return error.ErrorInUnion;
        if (resolved == .null_type) return error.NullInUnion;
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
    const alloc = std.testing.allocator;

    const inner = try alloc.create(ResolvedType);
    defer alloc.destroy(inner);
    inner.* = .{ .primitive = .i32 };

    // CoreType variants
    const core_err = ResolvedType{ .core_type = .{ .kind = .error_union, .inner = inner } };
    try std.testing.expect(core_err.isCoreType(.error_union));
    try std.testing.expect(!core_err.isCoreType(.null_union));
    try std.testing.expect(core_err.coreInner() == inner);

    const core_null = ResolvedType{ .core_type = .{ .kind = .null_union, .inner = inner } };
    try std.testing.expect(core_null.isCoreType(.null_union));
    try std.testing.expect(!core_null.isCoreType(.error_union));
    try std.testing.expectEqualStrings("NullUnion(T)", core_null.name());
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

test "isPrimitiveName" {
    try std.testing.expect(isPrimitiveName("i32"));
    try std.testing.expect(isPrimitiveName("String"));
    try std.testing.expect(!isPrimitiveName("Player"));
    try std.testing.expect(!isPrimitiveName("List"));
}

test "CoreType - isCoreType helper" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(ResolvedType);
    defer alloc.destroy(inner);
    inner.* = .{ .primitive = .i32 };

    const err_union = ResolvedType{ .core_type = .{ .kind = .error_union, .inner = inner } };
    try std.testing.expect(err_union.isCoreType(.error_union));
    try std.testing.expect(!err_union.isCoreType(.null_union));

    const plain = ResolvedType{ .primitive = .i32 };
    try std.testing.expect(!plain.isCoreType(.error_union));
}

test "resolveUnion - bans Error in union" {
    const alloc = std.testing.allocator;
    const err_node = try alloc.create(parser.Node);
    defer alloc.destroy(err_node);
    err_node.* = .{ .type_named = "Error" };
    const i32_node = try alloc.create(parser.Node);
    defer alloc.destroy(i32_node);
    i32_node.* = .{ .type_named = "i32" };
    var members = [_]*parser.Node{ err_node, i32_node };
    const result = resolveUnion(alloc, &members);
    try std.testing.expectError(error.ErrorInUnion, result);
}

test "resolveUnion - bans null in union" {
    const alloc = std.testing.allocator;
    const null_node = try alloc.create(parser.Node);
    defer alloc.destroy(null_node);
    null_node.* = .{ .type_named = "null" };
    const i32_node = try alloc.create(parser.Node);
    defer alloc.destroy(i32_node);
    i32_node.* = .{ .type_named = "i32" };
    var members = [_]*parser.Node{ null_node, i32_node };
    const result = resolveUnion(alloc, &members);
    try std.testing.expectError(error.NullInUnion, result);
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
