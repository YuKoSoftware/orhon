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
    raw_ptr,
    safe_ptr,
    thread_handle,
};

/// Classify a resolved type into a codegen category.
pub fn classifyType(t: RT) TypeClass {
    return switch (t) {
        .error_union => .error_union,
        .null_union => .null_union,
        .union_type => .arbitrary_union,
        .primitive => |p| if (p == .string) .string else .plain,
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "RawPtr") or std.mem.eql(u8, g.name, "VolatilePtr"))
                return .raw_ptr;
            if (std.mem.eql(u8, g.name, "Ptr"))
                return .safe_ptr;
            if (std.mem.eql(u8, g.name, "Handle"))
                return .thread_handle;
            return .plain;
        },
        .ptr => .safe_ptr,
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
    value_to_const_ref, // T → &T for const & parameters
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
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };
    try std.testing.expectEqual(TypeClass.error_union, classifyType(RT{ .error_union = inner }));
    try std.testing.expectEqual(TypeClass.null_union, classifyType(RT{ .null_union = inner }));
}

test "classifyType - pointers and named" {
    try std.testing.expectEqual(TypeClass.raw_ptr, classifyType(RT{ .generic = .{
        .name = "RawPtr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.safe_ptr, classifyType(RT{ .generic = .{
        .name = "Ptr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .named = "MyStruct" }));
}
