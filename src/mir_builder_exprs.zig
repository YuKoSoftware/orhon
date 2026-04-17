// mir_builder_exprs.zig — expressions cluster for MirBuilder (Phase B7)
// Satellite of mir_builder.zig — all functions take *MirBuilder as first parameter.
// Covers: int_literal, float_literal, string_literal, bool_literal, null_literal,
//         error_literal, identifier, binary_expr, range_expr, unary_expr, call_expr,
//         field_expr, index_expr, slice_expr, mut_borrow_expr, const_borrow_expr,
//         interpolated_string, compiler_func, array_literal, tuple_literal, version_literal.

const std = @import("std");
const mir_builder_mod = @import("mir_builder.zig");
const ast_typed = @import("ast_typed.zig");
const mir_typed = @import("mir_typed.zig");
const mir_types = @import("mir/mir_types.zig");
const string_pool = @import("string_pool.zig");
const type_store_mod = @import("type_store.zig");

const MirBuilder = mir_builder_mod.MirBuilder;
const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
const MirNodeIndex = @import("mir_store.zig").MirNodeIndex;
const StringIndex = string_pool.StringIndex;
const RT = mir_types.RT;
const TypeId = type_store_mod.TypeId;

// ── Helpers ──────────────────────────────────────────────────────────────────

fn internRT(b: *MirBuilder, rt: RT) !TypeId {
    if (rt == .unknown or rt == .inferred) return .none;
    return b.store.types.intern(b.allocator, rt);
}

fn internStr(b: *MirBuilder, ast_si: StringIndex) !StringIndex {
    return b.store.strings.intern(b.allocator, b.ast.strings.get(ast_si));
}

// ── Public dispatch ──────────────────────────────────────────────────────────

/// Called by MirBuilder.lowerNode for all expression-kind AstNodes.
pub fn lowerExpr(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    return switch (b.ast.getNode(idx).tag) {
        .int_literal     => lowerIntLiteral(b, idx),
        .float_literal   => lowerFloatLiteral(b, idx),
        .string_literal  => lowerStringLiteral(b, idx),
        .bool_literal    => lowerBoolLiteral(b, idx),
        .null_literal    => lowerNullLiteral(b, idx),
        .error_literal   => lowerErrorLiteral(b, idx),
        .identifier      => lowerIdentifier(b, idx),
        .binary_expr     => lowerBinary(b, idx),
        .range_expr      => lowerRange(b, idx),
        else => mir_typed.Passthrough.pack(b.store, b.allocator, idx, .none, .plain, .{}),
    };
}

// ── Leaf literal lowerers ────────────────────────────────────────────────────

fn lowerIntLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.IntLiteral.unpack(b.ast, idx);
    const text = try internStr(b, ast_rec.text);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Literal.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .text = text, .kind = 0, .bool_val = 0,
    });
}

fn lowerFloatLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.FloatLiteral.unpack(b.ast, idx);
    const text = try internStr(b, ast_rec.text);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Literal.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .text = text, .kind = 1, .bool_val = 0,
    });
}

fn lowerStringLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.StringLiteral.unpack(b.ast, idx);
    const text = try internStr(b, ast_rec.text);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Literal.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .text = text, .kind = 2, .bool_val = 0,
    });
}

fn lowerBoolLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.BoolLiteral.unpack(b.ast, idx);
    const empty_si = try b.store.strings.intern(b.allocator, "");
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Literal.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .text = empty_si, .kind = 3, .bool_val = if (ast_rec.value) @as(u32, 1) else 0,
    });
}

fn lowerNullLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const empty_si = try b.store.strings.intern(b.allocator, "");
    return mir_typed.Literal.pack(b.store, b.allocator, idx, .none, .plain, .{
        .text = empty_si, .kind = 4, .bool_val = 0,
    });
}

fn lowerErrorLiteral(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ErrorLiteral.unpack(b.ast, idx);
    const name = try internStr(b, ast_rec.name);
    return mir_typed.Literal.pack(b.store, b.allocator, idx, .none, .plain, .{
        .text = name, .kind = 5, .bool_val = 0,
    });
}

// ── Identifier ────────────────────────────────────────────────────────────────

fn lowerIdentifier(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.Identifier.unpack(b.ast, idx);
    const name = try internStr(b, ast_rec.name);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Identifier.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .name = name, .resolved_kind = resolveIdentifierKind(b, idx),
    });
}

/// Stub: returns 0 until DeclTable API verified at B8.
fn resolveIdentifierKind(_: *const MirBuilder, _: AstNodeIndex) u32 {
    return 0;
}

// ── Binary / range ────────────────────────────────────────────────────────────

fn lowerBinary(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.BinaryExpr.unpack(b.ast, idx);
    const lhs = try b.lowerNode(ast_rec.lhs);
    const rhs = try b.lowerNode(ast_rec.rhs);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Binary.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .op = ast_rec.op, .lhs = lhs, .rhs = rhs,
    });
}

fn lowerRange(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.RangeExpr.unpack(b.ast, idx);
    const lhs = try b.lowerNode(ast_rec.lhs);
    const rhs = try b.lowerNode(ast_rec.rhs);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Binary.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .op = ast_rec.op, .lhs = lhs, .rhs = rhs,
    });
}
