// types.zig — Orhon type system shared definitions
// Used by declarations, resolver, ownership, borrow, and propagation passes.

const std = @import("std");
const parser = @import("parser.zig");
const K = @import("constants.zig");
const ast_store_mod = @import("ast_store.zig");
pub const AstNodeIndex = ast_store_mod.AstNodeIndex;

/// A type parameter bound at a specific func_decl or struct_decl.
/// `binder` is the AstNodeIndex of the declaring node — unique per declaration site.
pub const TypeParam = struct {
    name: []const u8,
    binder: AstNodeIndex,
};

/// Primitive type enum — replaces string-based primitive type identification.
/// Exhaustive switching, zero-cost comparison, no typo risk.
/// Includes special compiler-known types (err, null_type, any, this, vector)
/// so every comparison site uses fromName() instead of std.mem.eql.
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
    /// Built-in error sentinel type ("Error" in source)
    err,
    /// Built-in null sentinel type ("null" in source)
    null_type,
    /// anytype parameter marker ("any" in source)
    any,
    /// Self-reference inside a type declaration ("@this" in source)
    this,
    /// Deprecated alias for @this ("Self" in source)
    self_deprecated,
    /// SIMD vector type ("Vector" in source, generic)
    vector,

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
            .{ "Error", .err },
            .{ "null", .null_type },
            .{ "any", .any },
            .{ "@this", .this },
            .{ "Self", .self_deprecated },
            .{ "Vector", .vector },
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
            .err => "Error",
            .null_type => "null",
            .any => "any",
            .this => "@this",
            .self_deprecated => "Self",
            .vector => "Vector",
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
            .err => "anyerror",
            .null_type => "null",
            .any => "anytype",
            .this, .self_deprecated => "@This()",
            .vector => "@Vector",
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
    /// Type parameter introduced at a generic function or struct binder.
    /// `name` is the source name (e.g. "T"), `binder` is the AstNodeIndex of the
    /// declaring func_decl or struct_decl. Universally compatible until constraint
    /// checks land (S6+). HKT remains out of scope.
    type_param: TypeParam,

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
            .named, .slice, .array, .union_type, .tuple, .func_ptr, .generic, .ptr, .type_param => false,
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
            .type_param => |tp| tp.name,
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

        // Binary | expression in type-alias position: (null | T) or (Error | T) parsed as binary OR.
        .binary_expr => |b| {
            if (b.op != .bit_or) return .unknown;
            var members = std.ArrayListUnmanaged(*parser.Node){};
            defer members.deinit(alloc);
            try collectBinaryOrLeaves(alloc, b, &members);
            return resolveUnion(alloc, members.items);
        },

        // Generic type constructor in expression position: List(T), Map(K,V).
        .call_expr => |c| {
            if (c.callee.* != .identifier) return .unknown;
            var args = try alloc.alloc(ResolvedType, c.args.len);
            for (c.args, 0..) |a, i| {
                args[i] = try resolveTypeNode(alloc, a);
            }
            return .{ .generic = .{ .name = c.callee.identifier, .args = args } };
        },
        // Bare identifier in type position: cast(i64, x) type arg, or unknown type name.
        .identifier => |n| classifyNamed(n),
        // Integer literal in type position (e.g. Vector(4, f32) size arg) — preserve
        // the text so zigOfRTInner can extract it for @Vector(N, T) emission.
        .int_literal => |n| .{ .named = n },

        // Non-type AST nodes (77+ variants) — only type_* nodes resolve to types
        else => .unknown,
    };
}

/// Classify a named type string into the appropriate ResolvedType variant
fn classifyNamed(n: []const u8) ResolvedType {
    if (Primitive.fromName(n)) |prim| return switch (prim) {
        .err => .err,
        .null_type => .null_type,
        // Special compiler-known types exist in Primitive only for comparison;
        // they remain .named in the type system so anytype/self-ref semantics hold.
        .any, .this, .self_deprecated, .vector => .{ .named = n },
        else => .{ .primitive = prim },
    };
    return .{ .named = n };
}

/// Flatten a left-recursive binary `|` expression tree into a flat list of leaf nodes.
fn collectBinaryOrLeaves(alloc: std.mem.Allocator, b: parser.BinaryOp, out: *std.ArrayListUnmanaged(*parser.Node)) anyerror!void {
    if (b.left.* == .binary_expr and b.left.binary_expr.op == .bit_or) {
        try collectBinaryOrLeaves(alloc, b.left.binary_expr, out);
    } else {
        try out.append(alloc, b.left);
    }
    if (b.right.* == .binary_expr and b.right.binary_expr.op == .bit_or) {
        try collectBinaryOrLeaves(alloc, b.right.binary_expr, out);
    } else {
        try out.append(alloc, b.right);
    }
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

/// Check if a name is a primitive type (copy semantics, user-facing numeric/bool/str/void).
/// Excludes pseudo-types and special compiler-known names that are in Primitive for
/// comparison purposes only (any, err, null_type, this, self_deprecated, vector).
pub fn isPrimitiveName(n: []const u8) bool {
    if (Primitive.fromName(n)) |p| {
        return switch (p) {
            .i8, .i16, .i32, .i64, .i128,
            .u8, .u16, .u32, .u64, .u128,
            .isize, .usize,
            .f16, .f32, .f64, .f128,
            .bool, .string, .void,
            => true,
            else => false,
        };
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
    // Special compiler-known types are in Primitive for comparison only — not user primitives
    try std.testing.expect(!isPrimitiveName("Error"));
    try std.testing.expect(!isPrimitiveName("null"));
    try std.testing.expect(!isPrimitiveName("any"));
    try std.testing.expect(!isPrimitiveName("@this"));
    try std.testing.expect(!isPrimitiveName("Self"));
    try std.testing.expect(!isPrimitiveName("Vector"));
}

test "classifyNamed - special types stay .named" {
    // "any", "@this", "Self", "Vector" must remain .named so the resolver's
    // anytype/self-reference semantics continue to work correctly.
    try std.testing.expect(classifyNamed("any") == .named);
    try std.testing.expect(classifyNamed("@this") == .named);
    try std.testing.expect(classifyNamed("Self") == .named);
    try std.testing.expect(classifyNamed("Vector") == .named);
    // "Error" and "null" map to their dedicated ResolvedType variants
    try std.testing.expect(classifyNamed("Error") == .err);
    try std.testing.expect(classifyNamed("null") == .null_type);
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

test "type_param variant - isPrimitive returns false" {
    const binder: AstNodeIndex = @enumFromInt(1);
    const tp = ResolvedType{ .type_param = .{ .name = "T", .binder = binder } };
    try std.testing.expect(!tp.isPrimitive());
}

test "type_param variant - name returns the param name" {
    const binder: AstNodeIndex = @enumFromInt(1);
    const tp = ResolvedType{ .type_param = .{ .name = "T", .binder = binder } };
    try std.testing.expectEqualStrings("T", tp.name());
}

test "type_param variant - distinct binders are distinguishable" {
    const b1: AstNodeIndex = @enumFromInt(1);
    const b2: AstNodeIndex = @enumFromInt(2);
    const t1 = ResolvedType{ .type_param = .{ .name = "T", .binder = b1 } };
    const t2 = ResolvedType{ .type_param = .{ .name = "T", .binder = b2 } };
    try std.testing.expect(t1.type_param.binder != t2.type_param.binder);
}

test "resolveTypeNode - binary_expr union (null | i32)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var left = parser.Node{ .type_named = "null" };
    var right = parser.Node{ .type_named = "i32" };
    var b_expr = parser.Node{ .binary_expr = .{ .left = &left, .right = &right, .op = .bit_or } };
    const rt = try resolveTypeNode(a, &b_expr);
    try std.testing.expect(rt == .union_type);
    try std.testing.expectEqual(@as(usize, 2), rt.union_type.len);
    var found_null = false;
    var found_i32 = false;
    for (rt.union_type) |m| {
        if (m == .null_type) found_null = true;
        if (m == .primitive and m.primitive == .i32) found_i32 = true;
    }
    try std.testing.expect(found_null);
    try std.testing.expect(found_i32);
}

test "resolveTypeNode - identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var node = parser.Node{ .identifier = "i32" };
    const rt = try resolveTypeNode(arena.allocator(), &node);
    try std.testing.expect(rt == .primitive);
    try std.testing.expectEqual(Primitive.i32, rt.primitive);
}

test "resolveTypeNode - call_expr as generic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var callee = parser.Node{ .identifier = "List" };
    var arg = parser.Node{ .type_named = "i32" };
    var args = [_]*parser.Node{&arg};
    var node = parser.Node{ .call_expr = .{ .callee = &callee, .args = &args, .arg_names = &.{} } };
    const rt = try resolveTypeNode(a, &node);
    try std.testing.expect(rt == .generic);
    try std.testing.expectEqualStrings("List", rt.generic.name);
    try std.testing.expectEqual(@as(usize, 1), rt.generic.args.len);
}
