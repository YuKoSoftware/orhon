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

/// Resolve a FuncSig for a call expression's callee (simplified port from MirAnnotator).
/// Only handles direct identifier and field_expr callee forms.
fn resolveCallSig(b: *const MirBuilder, call_idx: AstNodeIndex) ?@import("declarations.zig").FuncSig {
    const ast_rec = ast_typed.CallExpr.unpack(b.ast, call_idx);
    const callee_tag = b.ast.getNode(ast_rec.callee).tag;
    if (callee_tag == .identifier) {
        const rec = ast_typed.Identifier.unpack(b.ast, ast_rec.callee);
        const name = b.ast.strings.get(rec.name);
        return if (b.decls) |d| d.funcs.get(name) else null;
    }
    if (callee_tag == .field_expr) {
        const rec = ast_typed.FieldExpr.unpack(b.ast, ast_rec.callee);
        const field = b.ast.strings.get(rec.field);
        return if (b.decls) |d| d.funcs.get(field) else null;
    }
    return null;
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
        .index_expr           => lowerIndex(b, idx),
        .slice_expr           => lowerSlice(b, idx),
        .interpolated_string  => lowerInterpolation(b, idx),
        .compiler_func   => lowerCompilerFn(b, idx),
        .array_literal   => lowerArrayLit(b, idx),
        .tuple_literal   => lowerTupleLit(b, idx),
        .version_literal => lowerVersionLit(b, idx),
        else => unreachable,
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
    const name_str = b.ast.strings.get(ast_rec.name);
    // type_map first; var_types fallback for locals; decls fallback for named types.
    const rt = b.type_map.get(idx) orelse blk: {
        if (b.var_types.get(name_str)) |tid| {
            if (tid != .none) break :blk b.store.types.get(tid);
        }
        if (b.decls) |d| {
            if (d.structs.contains(name_str) or d.enums.contains(name_str) or d.handles.contains(name_str)) {
                break :blk RT{ .named = name_str };
            }
        }
        break :blk RT.unknown;
    };
    return mir_typed.Identifier.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .name = name, .resolved_kind = resolveIdentifierKind(b, idx),
    });
}

/// Returns 0=plain, 1=enum_variant, 2=enum_type_name for an identifier.
fn resolveIdentifierKind(b: *const MirBuilder, idx: AstNodeIndex) u32 {
    const ast_rec = ast_typed.Identifier.unpack(b.ast, idx);
    const name = b.ast.strings.get(ast_rec.name);
    const decls = b.decls orelse return 0;
    if (decls.enums.contains(name)) return 2;
    var it = decls.enums.valueIterator();
    while (it.next()) |sig| {
        for (sig.variants) |v| {
            if (std.mem.eql(u8, v, name)) return 1;
        }
    }
    return 0;
}

// ── Binary / range ────────────────────────────────────────────────────────────

fn lowerBinary(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.BinaryExpr.unpack(b.ast, idx);
    const lhs = try b.lowerNode(ast_rec.lhs);
    const rhs = try b.lowerNode(ast_rec.rhs);
    const rt = b.type_map.get(idx) orelse .unknown;
    // Stamp union_tag for `x is T` expressions (desugared as @type(x) == T).
    // Needed to emit `val == ._N` for arbitrary-union type checks in codegen.
    const union_tag = blk: {
        const op: @import("parser.zig").Operator = @enumFromInt(ast_rec.op);
        if (op != .eq and op != .ne) break :blk @as(u32, 0);
        const lhs_node = b.ast.getNode(ast_rec.lhs);
        if (lhs_node.tag != .compiler_func) break :blk @as(u32, 0);
        const cf_rec = ast_typed.CompilerFunc.unpack(b.ast, ast_rec.lhs);
        const cf_name = b.ast.strings.get(cf_rec.name);
        if (!std.mem.eql(u8, cf_name, "type")) break :blk @as(u32, 0);
        if (cf_rec.args_end <= cf_rec.args_start) break :blk @as(u32, 0);
        const arg_idx: AstNodeIndex = @enumFromInt(b.ast.extra_data.items[cf_rec.args_start]);
        const arg_rt = resolveSourceUnionRT(b, arg_idx) orelse break :blk @as(u32, 0);
        // Only stamp for arbitrary unions (not Error/null sentinels)
        const has_error = arg_rt.unionContainsError();
        const has_null = arg_rt.unionContainsNull();
        if (has_error or has_null) break :blk @as(u32, 0);
        // Get rhs type name from identifier
        const rhs_node = b.ast.getNode(ast_rec.rhs);
        if (rhs_node.tag != .identifier) break :blk @as(u32, 0);
        const rhs_name = b.ast.strings.get(rhs_node.data.str);
        const tag = mir_types.positionalTagOf(arg_rt, rhs_name) orelse break :blk @as(u32, 0);
        break :blk @as(u32, tag) + 1; // 0 = none, n+1 = tag n
    };
    return mir_typed.Binary.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .op = ast_rec.op, .lhs = lhs, .rhs = rhs, .union_tag = union_tag,
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
    var arg_ast_indices = try std.ArrayListUnmanaged(AstNodeIndex).initCapacity(b.allocator, arg_count);
    defer arg_ast_indices.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.args_start..ast_rec.args_end]) |au32| {
        const arg_ast: AstNodeIndex = @enumFromInt(au32);
        try arg_ast_indices.append(b.allocator, arg_ast);
        try arg_nodes.append(b.allocator, try b.lowerNode(arg_ast));
    }

    // Stamp coercion on each arg against the function signature's param types.
    const sig_opt = resolveCallSig(b, idx);
    if (sig_opt) |sig| {
        for (arg_nodes.items, 0..) |arg_mir, i| {
            if (i < sig.params.len) {
                const param_type_id = try internRT(b, sig.params[i].type_);
                b.stampCoercion(arg_mir, b.inferCoercion(arg_ast_indices.items[i], param_type_id));
            }
        }
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

// ── Interpolated string ───────────────────────────────────────────────────────

fn lowerInterpolation(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.InterpolatedString.unpack(b.ast, idx);

    // Collect output pairs into a temp buffer to avoid interleaving with
    // extra_data written by child expr lowering (same pattern as lowerCall).
    var parts_buf = std.ArrayListUnmanaged(u32){};
    defer parts_buf.deinit(b.allocator);

    var i = ast_rec.parts_start;
    while (i < ast_rec.parts_end) : (i += 2) {
        const tag     = b.ast.extra_data.items[i];
        const payload = b.ast.extra_data.items[i + 1];
        if (tag == 0) {
            const mir_si = try internStr(b, @enumFromInt(payload));
            try parts_buf.append(b.allocator, 0);
            try parts_buf.append(b.allocator, @intFromEnum(mir_si));
        } else {
            const mir_node = try b.lowerNode(@enumFromInt(payload));
            try parts_buf.append(b.allocator, 1);
            try parts_buf.append(b.allocator, @intFromEnum(mir_node));
        }
    }

    const parts_start: u32 = @intCast(b.store.extra_data.items.len);
    for (parts_buf.items) |v| try b.store.extra_data.append(b.allocator, v);
    const parts_end: u32 = @intCast(b.store.extra_data.items.len);

    const rt = b.type_map.get(idx) orelse .unknown;
    return mir_typed.Interpolation.pack(b.store, b.allocator, idx, try internRT(b, rt), mir_types.classifyType(rt), .{
        .parts_start = parts_start, .parts_end = parts_end,
    });
}

fn lowerCompilerFn(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.CompilerFunc.unpack(b.ast, idx);
    const name = try internStr(b, ast_rec.name);
    // Temp buffer to avoid interleaving with extra_data from child lowering.
    var arg_nodes = std.ArrayListUnmanaged(MirNodeIndex){};
    defer arg_nodes.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.args_start..ast_rec.args_end]) |au32| {
        try arg_nodes.append(b.allocator, try b.lowerNode(@enumFromInt(au32)));
    }
    const args_start: u32 = @intCast(b.store.extra_data.items.len);
    for (arg_nodes.items) |m| try b.store.extra_data.append(b.allocator, @intFromEnum(m));
    const args_end: u32 = @intCast(b.store.extra_data.items.len);
    return mir_typed.CompilerFn.pack(b.store, b.allocator, idx, .none, .plain, .{
        .name = name, .args_start = args_start, .args_end = args_end,
    });
}

fn lowerArrayLit(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_items = ast_typed.ArrayLiteral.getItems(b.ast, idx);
    var mir_items = try std.ArrayListUnmanaged(MirNodeIndex).initCapacity(b.allocator, ast_items.len);
    defer mir_items.deinit(b.allocator);
    for (ast_items) |item| try mir_items.append(b.allocator, try b.lowerNode(item));
    return mir_typed.ArrayLit.pack(b.store, b.allocator, idx, .none, .plain, mir_items.items);
}

fn lowerTupleLit(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.TupleLiteral.unpack(b.ast, idx);
    const elem_count = ast_rec.elements_end - ast_rec.elements_start;
    // Temp buffer to avoid interleaving with extra_data from child lowering.
    var elem_nodes = std.ArrayListUnmanaged(MirNodeIndex){};
    defer elem_nodes.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.elements_start..ast_rec.elements_end]) |eu32| {
        try elem_nodes.append(b.allocator, try b.lowerNode(@enumFromInt(eu32)));
    }
    const elements_start: u32 = @intCast(b.store.extra_data.items.len);
    for (elem_nodes.items) |m| try b.store.extra_data.append(b.allocator, @intFromEnum(m));
    const elements_end: u32 = @intCast(b.store.extra_data.items.len);
    // Re-intern optional field names (names_start=0 means no names).
    const names_start: u32 = @intCast(b.store.extra_data.items.len);
    if (ast_rec.names_start != 0 and elem_count > 0) {
        for (b.ast.extra_data.items[ast_rec.names_start .. ast_rec.names_start + elem_count]) |si_u32| {
            const mir_si = try internStr(b, @enumFromInt(si_u32));
            try b.store.extra_data.append(b.allocator, @intFromEnum(mir_si));
        }
    }
    return mir_typed.TupleLit.pack(b.store, b.allocator, idx, .none, .plain, .{
        .elements_start = elements_start,
        .elements_end = elements_end,
        .names_start = if (ast_rec.names_start != 0 and elem_count > 0) names_start else 0,
    });
}

fn lowerVersionLit(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.VersionLiteral.unpack(b.ast, idx);
    return mir_typed.VersionLit.pack(b.store, b.allocator, idx, .none, .plain, .{
        .major = try internStr(b, ast_rec.major),
        .minor = try internStr(b, ast_rec.minor),
        .patch = try internStr(b, ast_rec.patch),
    });
}
