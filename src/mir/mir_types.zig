// mir_types.zig — MIR type definitions and classification

const std = @import("std");
const parser = @import("../parser.zig");
const types = @import("../types.zig");

pub const RT = types.ResolvedType;

// ── Type Classification ─────────────────────────────────────

/// How codegen should treat a variable or expression.
/// Replaces the 7 ad-hoc hashmaps in CodeGen.
pub const TypeClass = enum {
    plain,
    error_union,
    null_union,
    arbitrary_union,
    string,
};

/// Classify a resolved type into a codegen category.
pub fn classifyType(t: RT) TypeClass {
    return switch (t) {
        .union_type => {
            // Scan union members for Error/null to classify as error_union or null_union
            if (t.unionContainsError()) return .error_union;
            if (t.unionContainsNull()) return .null_union;
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
pub const Coercion = enum {
    array_to_slice,
    null_wrap,
    error_wrap,
    arbitrary_union_wrap,
    optional_unwrap,
    value_to_const_ref, // T → const& T for const& parameters
};

// ── Node Info ───────────────────────────────────────────────

/// Per-AST-node annotation produced by the MIR annotator.
pub const NodeInfo = struct {
    resolved_type: RT,
    type_class: TypeClass,
    coercion: ?Coercion = null,
    coerce_tag: ?[]const u8 = null,
    narrowed_to: ?[]const u8 = null,
};

/// Annotation table: AST node pointer → NodeInfo.
pub const NodeMap = std.AutoHashMapUnmanaged(*parser.Node, NodeInfo);

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
