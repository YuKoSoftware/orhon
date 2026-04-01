// mir_types.zig — MIR type definitions and classification

const std = @import("std");
const parser = @import("../parser.zig");
const types = @import("../types.zig");
const builtins = @import("../builtins.zig");

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
        .union_type => .arbitrary_union,
        .primitive => |p| if (p == .string) .string else .plain,
        .generic => |g| {
            if (std.mem.eql(u8, g.name, builtins.BT.RAW_PTR) or std.mem.eql(u8, g.name, builtins.BT.VOLATILE_PTR))
                return .raw_ptr;
            if (std.mem.eql(u8, g.name, builtins.BT.PTR))
                return .safe_ptr;
            if (std.mem.eql(u8, g.name, builtins.BT.HANDLE))
                return .thread_handle;
            return .plain;
        },
        .core_type => |ct| switch (ct.kind) {
            .raw_ptr, .volatile_ptr => .raw_ptr,
            .safe_ptr => .safe_ptr,
            .handle => .thread_handle,
            .error_union => .error_union,
            .null_union => .null_union,
        },
        // .ptr is a const &T reference — field access auto-derefs in Zig, not a Ptr(T) wrapper
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
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };
    try std.testing.expectEqual(TypeClass.error_union, classifyType(RT{ .core_type = .{ .kind = .error_union, .inner = inner } }));
    try std.testing.expectEqual(TypeClass.null_union, classifyType(RT{ .core_type = .{ .kind = .null_union, .inner = inner } }));
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
