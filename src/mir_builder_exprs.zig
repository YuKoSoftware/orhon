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
        .unary_expr        => lowerUnary(b, idx),
        .mut_borrow_expr   => lowerMutBorrow(b, idx),
        .const_borrow_expr => lowerConstBorrow(b, idx),
        .call_expr       => lowerCall(b, idx),
        .field_expr      => lowerFieldAccess(b, idx),
        .index_expr      => lowerIndex(b, idx),
        .slice_expr      => lowerSlice(b, idx),
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

// ── Unary / borrow ────────────────────────────────────────────────────────────

fn lowerUnary(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.UnaryExpr.unpack(b.ast, idx);
    const operand = try b.lowerNode(ast_rec.operand);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Unary.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .op = ast_rec.op, .operand = operand,
    });
}

fn lowerMutBorrow(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.MutBorrowExpr.unpack(b.ast, idx);
    const operand = try b.lowerNode(ast_rec.child);
    return mir_typed.Borrow.pack(b.store, b.allocator, idx, .none, .plain, .{
        .kind = 1, .operand = operand,
    });
}

fn lowerConstBorrow(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ConstBorrowExpr.unpack(b.ast, idx);
    const operand = try b.lowerNode(ast_rec.child);
    return mir_typed.Borrow.pack(b.store, b.allocator, idx, .none, .plain, .{
        .kind = 0, .operand = operand,
    });
}

// ── Call ─────────────────────────────────────────────────────────────────────

// ── Field access ──────────────────────────────────────────────────────────────

/// Resolve the "source union RT" for an AST expression node.
/// Primary path: check type_map — if the expression's RT is .union_type, return it.
/// Fallback (BR2): if the identifier's type was narrowed, recover the original union
/// from var_types. This handles the case where type narrowing replaced the union type
/// on the identifier node with a specific member type.
fn resolveSourceUnionRT(b: *const MirBuilder, ast_idx: AstNodeIndex) ?RT {
    if (b.type_map.get(ast_idx)) |rt| {
        if (rt == .union_type) return rt;
    }
    if (b.ast.getNode(ast_idx).tag != .identifier) return null;
    const rec = ast_typed.Identifier.unpack(b.ast, ast_idx);
    const name = b.ast.strings.get(rec.name);
    const tid = b.var_types.get(name) orelse return null;
    if (tid == .none) return null;
    const fallback_rt = b.store.types.get(tid);
    if (fallback_rt == .union_type) return fallback_rt;
    return null;
}

fn lowerFieldAccess(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.FieldExpr.unpack(b.ast, idx);
    const object = try b.lowerNode(ast_rec.object);
    const field = try internStr(b, ast_rec.field);
    const field_str = b.ast.strings.get(ast_rec.field);

    // Encoding: 0 = no tag, positional_tag + 1 = has tag (BR2).
    const union_tag: u32 = blk: {
        if (resolveSourceUnionRT(b, ast_rec.object)) |rt| {
            if (mir_types.positionalTagOf(rt, field_str)) |tag| break :blk @as(u32, tag) + 1;
        }
        break :blk 0;
    };

    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.FieldAccess.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .field = field, .object = object, .union_tag = union_tag,
    });
}

fn lowerCall(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.CallExpr.unpack(b.ast, idx);
    const callee = try b.lowerNode(ast_rec.callee);

    // Collect lowered args into a temp buffer before appending to store.extra_data.
    // Child lowering (via appendExtra) also writes to store.extra_data, so we must
    // lower all args first, then append their MirNodeIndex values contiguously.
    const arg_count = ast_rec.args_end - ast_rec.args_start;
    var arg_nodes = try std.ArrayListUnmanaged(MirNodeIndex).initCapacity(b.allocator, arg_count);
    defer arg_nodes.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.args_start..ast_rec.args_end]) |au32| {
        try arg_nodes.append(b.allocator, try b.lowerNode(@enumFromInt(au32)));
    }
    const args_start: u32 = @intCast(b.store.extra_data.items.len);
    for (arg_nodes.items) |m| try b.store.extra_data.append(b.allocator, @intFromEnum(m));
    const args_end: u32 = @intCast(b.store.extra_data.items.len);

    // Re-intern named-arg StringIndex values (0 = no named args).
    const arg_names_start: u32 = @intCast(b.store.extra_data.items.len);
    if (ast_rec.arg_names_start != 0 and arg_count > 0) {
        for (b.ast.extra_data.items[ast_rec.arg_names_start .. ast_rec.arg_names_start + arg_count]) |si_u32| {
            const mir_si = try internStr(b, @enumFromInt(si_u32));
            try b.store.extra_data.append(b.allocator, @intFromEnum(mir_si));
        }
    }

    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Call.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .callee = callee,
        .args_start = args_start,
        .args_end = args_end,
        .arg_names_start = if (ast_rec.arg_names_start != 0 and arg_count > 0) arg_names_start else 0,
    });
}

// ── Index / slice ─────────────────────────────────────────────────────────────

fn lowerIndex(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.IndexExpr.unpack(b.ast, idx);
    const object = try b.lowerNode(ast_rec.object);
    const index  = try b.lowerNode(ast_rec.index);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Index.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .object = object, .index = index,
    });
}

fn lowerSlice(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.SliceExpr.unpack(b.ast, idx);
    const object = try b.lowerNode(ast_rec.object);
    const low    = try b.lowerNode(ast_rec.low);
    const high   = try b.lowerNode(ast_rec.high);
    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Slice.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .object = object, .low = low, .high = high,
    });
}
