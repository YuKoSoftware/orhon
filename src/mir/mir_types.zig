// mir_types.zig — MIR type definitions and classification

const std = @import("std");
const types = @import("../types.zig");
const union_sort = @import("union_sort.zig");

pub const RT = types.ResolvedType;

// ── Type Classification ─────────────────────────────────────

/// How codegen should treat a variable or expression.
/// Replaces the 7 ad-hoc hashmaps in CodeGen.
pub const TypeClass = enum {
    plain,
    error_union,
    null_union,
    null_error_union,
    arbitrary_union,
    string,
};

/// Classify a resolved type into a codegen category.
pub fn classifyType(t: RT) TypeClass {
    return switch (t) {
        .union_type => {
            // Scan union members for Error/null to classify
            const has_error = t.unionContainsError();
            const has_null = t.unionContainsNull();
            if (has_error and has_null) return .null_error_union;
            if (has_error) return .error_union;
            if (has_null) return .null_union;
            return .arbitrary_union;
        },
        .primitive => |p| if (p == .string) .string else .plain,
        // .ptr is a const &T or mut &T reference — field access auto-derefs in Zig
        .ptr => .plain,
        else => .plain,
    };
}

// ── Coercion ────────────────────────────────────────────────

/// An explicit coercion that codegen should emit.
pub const Coercion = union(enum) {
    array_to_slice,
    null_wrap,
    error_wrap,
    /// Positional tag (0..31) into the destination union's canonical sort order.
    arbitrary_union_wrap: u8,
    optional_unwrap,
    /// T → const& T for const& parameters.
    value_to_const_ref,
};

// ── Shared union-tag helpers ────────────────────────────────

/// Whether `name` is the built-in Error sentinel type name.
pub fn isErrorTypeName(name: []const u8) bool {
    return types.Primitive.fromName(name) == .err;
}

/// Whether `name` is the built-in null sentinel type name.
pub fn isNullTypeName(name: []const u8) bool {
    return types.Primitive.fromName(name) == .null_type;
}

/// Resolve a union member name to its canonical positional tag (0..31).
/// Walks the union's members with Error/null filtered out, sorts them in
/// canonical order via `union_sort.sortMemberNames`, and returns the index
/// of `member_name`. Returns null if `union_rt` is not a union, if
/// `member_name` is not a member, or if arity exceeds 32.
///
/// This is the single canonical implementation — callers in the annotator
/// and lowerer use this instead of re-walking member lists themselves.
pub fn positionalTagOf(union_rt: RT, member_name: []const u8) ?u8 {
    if (union_rt != .union_type) return null;
    const max_arity = 32;
    var buf: [max_arity][]const u8 = undefined;
    var n: usize = 0;
    for (union_rt.union_type) |mem| {
        const name = mem.name();
        if (isErrorTypeName(name) or isNullTypeName(name)) continue;
        if (n >= max_arity) return null;
        buf[n] = name;
        n += 1;
    }
    union_sort.sortMemberNames(buf[0..n]);
    const idx = union_sort.positionalIndex(buf[0..n], member_name) orelse return null;
    if (idx > 255) return null;
    return @intCast(idx);
}

// ── MIR node kind enumeration ───────────────────────────────

/// MIR node kinds — grouped from 52 AST kinds.
pub const MirKind = enum {
    // Declarations
    func,
    struct_def,
    enum_def,
    handle_def,
    var_decl,
    test_def,
    destruct,
    import,
    // Statements
    block,
    return_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    defer_stmt,
    match_stmt,
    match_arm,
    assignment,
    break_stmt,
    continue_stmt,
    // Expressions
    literal, // int, float, string, bool, null, error
    identifier,
    binary, // binary_expr, range_expr
    unary,
    call,
    field_access,
    index,
    slice,
    borrow,
    interpolation,
    compiler_fn,
    array_lit,
    tuple_lit,
    version_lit,
    // Types — passthrough (codegen reads ast.* via typeToZig)
    type_expr,
    // Inline struct type expression (compt func return struct { ... })
    inline_struct,
    // Injected nodes (no AST counterpart)
    temp_var,
    injected_defer,
    // Struct/enum members and function params
    field_def,
    param_def,
    enum_variant_def,
    // Passthrough for unhandled/structural nodes
    passthrough,
};

/// Disambiguates the 6 literal types collapsed into MirKind.literal.
pub const LiteralKind = enum {
    int,
    float,
    string,
    bool_lit,
    null_lit,
    error_lit,
};

// ── Type narrowing data ──────────────────────────────────────

/// Distinguishes sentinel narrowing (Error, null) from regular type narrowing.
pub const NarrowKind = enum {
    plain, // regular type name
    error_sentinel, // "Error"
    null_sentinel, // "null"
};

/// One branch of a type narrowing (then, else, or post-if).
pub const NarrowBranch = struct {
    type_name: []const u8,
    positional_tag: ?u8 = null,
    kind: NarrowKind = .plain,
};

/// Pre-computed type narrowing for if_stmt with `is` checks.
pub const IfNarrowing = struct {
    var_name: []const u8,
    then_branch: ?NarrowBranch = null,
    else_branch: ?NarrowBranch = null,
    post_branch: ?NarrowBranch = null,
    type_class: TypeClass = .plain,
};

// ── Tests ───────────────────────────────────────────────────

test "classifyType - primitives" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = .i32 }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = .bool }));
    try std.testing.expectEqual(TypeClass.string, classifyType(RT{ .primitive = .string }));
}

test "classifyType - unions" {
    // (Error | i32) → error_union
    const err_members = &[_]RT{ RT.err, RT{ .primitive = .i32 } };
    try std.testing.expectEqual(TypeClass.error_union, classifyType(RT{ .union_type = err_members }));
    // (null | i32) → null_union
    const null_members = &[_]RT{ RT.null_type, RT{ .primitive = .i32 } };
    try std.testing.expectEqual(TypeClass.null_union, classifyType(RT{ .union_type = null_members }));
    // (null | Error | i32) → null_error_union
    const null_err_members = &[_]RT{ RT.null_type, RT.err, RT{ .primitive = .i32 } };
    try std.testing.expectEqual(TypeClass.null_error_union, classifyType(RT{ .union_type = null_err_members }));
    // (i32 | str) → arbitrary_union
    const arb_members = &[_]RT{ RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    try std.testing.expectEqual(TypeClass.arbitrary_union, classifyType(RT{ .union_type = arb_members }));
}

test "classifyType - named types" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .named = "MyStruct" }));
}

test "classifyType - ptr" {
    const alloc = std.testing.allocator;
    const elem = try alloc.create(RT);
    defer alloc.destroy(elem);
    elem.* = RT{ .named = "Point" };
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .ptr = .{ .kind = .const_ref, .elem = elem } }));
}

test "classifyType - unknown and inferred" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT.unknown));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT.inferred));
}

test "positionalTagOf - basic lookup" {
    // Sorted canonically: f64, i32, str → f64 at 0, i32 at 1, str at 2
    const members = &[_]RT{
        RT{ .primitive = .string },
        RT{ .primitive = .i32 },
        RT{ .primitive = .f64 },
    };
    const u = RT{ .union_type = members };
    try std.testing.expectEqual(@as(?u8, 0), positionalTagOf(u, "f64"));
    try std.testing.expectEqual(@as(?u8, 1), positionalTagOf(u, "i32"));
    try std.testing.expectEqual(@as(?u8, 2), positionalTagOf(u, "str"));
}

test "positionalTagOf - filters Error and null sentinels" {
    // (Error | null | i32 | str) → sorted (i32, str) → i32 at 0, str at 1
    const members = &[_]RT{ RT.err, RT.null_type, RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    const u = RT{ .union_type = members };
    try std.testing.expectEqual(@as(?u8, 0), positionalTagOf(u, "i32"));
    try std.testing.expectEqual(@as(?u8, 1), positionalTagOf(u, "str"));
}

test "positionalTagOf - non-union returns null" {
    try std.testing.expectEqual(@as(?u8, null), positionalTagOf(RT{ .primitive = .i32 }, "i32"));
}

test "positionalTagOf - missing member returns null" {
    const members = &[_]RT{ RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    const u = RT{ .union_type = members };
    try std.testing.expectEqual(@as(?u8, null), positionalTagOf(u, "f64"));
}

test "isErrorTypeName / isNullTypeName" {
    try std.testing.expect(isErrorTypeName("Error"));
    try std.testing.expect(!isErrorTypeName("null"));
    try std.testing.expect(!isErrorTypeName("i32"));
    try std.testing.expect(isNullTypeName("null"));
    try std.testing.expect(!isNullTypeName("Error"));
}
