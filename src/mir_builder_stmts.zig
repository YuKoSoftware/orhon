// mir_builder_stmts.zig — statements cluster for MirBuilder (Phase B6)
// Satellite of mir_builder.zig — all functions take *MirBuilder as first parameter.
// Covers: block, return_stmt, if_stmt, while_stmt, for_stmt, defer_stmt,
//         match_stmt, match_arm, assignment, break_stmt, continue_stmt.

const std = @import("std");
const mir_builder_mod = @import("mir_builder.zig");
const ast_typed = @import("ast_typed.zig");
const mir_typed = @import("mir_typed.zig");
const mir_types = @import("mir/mir_types.zig");
const string_pool = @import("string_pool.zig");
const declarations = @import("declarations.zig");
const parser = @import("parser.zig");

const MirBuilder = mir_builder_mod.MirBuilder;
const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
const MirNodeIndex = @import("mir_store.zig").MirNodeIndex;
const MirExtraIndex = @import("mir_store.zig").MirExtraIndex;
const TypeId = @import("type_store.zig").TypeId;
const RT = @import("types.zig").ResolvedType;
const StringIndex = string_pool.StringIndex;

fn internRT(b: *MirBuilder, rt: RT) !TypeId {
    if (rt == .unknown or rt == .inferred) return .none;
    return b.store.types.intern(b.allocator, rt);
}

// ── Public dispatch ──────────────────────────────────────────────────────────

/// Called by MirBuilder.lowerNode for all statement-kind AstNodes.
pub fn lowerStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    return switch (b.ast.getNode(idx).tag) {
        .block => lowerBlock(b, idx),
        .return_stmt => lowerReturnStmt(b, idx),
        .if_stmt => lowerIfStmt(b, idx),
        .while_stmt => lowerWhileStmt(b, idx),
        .for_stmt => lowerForStmt(b, idx),
        .defer_stmt => lowerDeferStmt(b, idx),
        .match_stmt => lowerMatchStmt(b, idx),
        .match_arm => lowerMatchArm(b, idx),
        .assignment => lowerAssignment(b, idx),
        .break_stmt => lowerBreakStmt(b, idx),
        .continue_stmt => lowerContinueStmt(b, idx),
        else => unreachable,
    };
}

// ── Statement lowerers ────────────────────────────────────────────────────────

fn lowerBlock(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_stmts = ast_typed.Block.getStmts(b.ast, idx);
    var mir_stmts = try std.ArrayListUnmanaged(MirNodeIndex).initCapacity(b.allocator, ast_stmts.len);
    defer mir_stmts.deinit(b.allocator);
    for (ast_stmts) |s| {
        const m = try b.lowerNode(s);
        try mir_stmts.append(b.allocator, m);
    }
    return mir_typed.Block.pack(b.store, b.allocator, idx, .none, .plain, mir_stmts.items);
}

fn lowerReturnStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ReturnStmt.unpack(b.ast, idx);
    const value = if (ast_rec.value != .none) try b.lowerNode(ast_rec.value) else .none;
    if (ast_rec.value != .none) {
        if (b.current_func_name) |fname| {
            if (b.decls) |d| {
                if (d.funcs.get(fname)) |sig| {
                    const ret_type_id = try internRT(b, sig.return_type);
                    b.stampCoercion(value, b.inferCoercion(ast_rec.value, ret_type_id));
                }
            }
        }
    }
    return mir_typed.ReturnStmt.pack(b.store, b.allocator, idx, .none, .plain, .{ .value = value });
}

fn lowerIfStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.IfStmt.unpack(b.ast, idx);
    const narrowing_extra = try extractNarrowing(b, ast_rec.condition, ast_rec.then_block);
    const cond = try b.lowerNode(ast_rec.condition);
    const then_b = try b.lowerNode(ast_rec.then_block);
    const else_b = if (ast_rec.else_block != .none) try b.lowerNode(ast_rec.else_block) else .none;
    return mir_typed.IfStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .condition = cond,
        .then_block = then_b,
        .else_block = else_b,
        .narrowing_extra = narrowing_extra,
    });
}

fn lowerWhileStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.WhileStmt.unpack(b.ast, idx);
    const cond = try b.lowerNode(ast_rec.condition);
    const body = try b.lowerNode(ast_rec.body);
    const continue_expr = if (ast_rec.continue_expr != .none)
        try b.lowerNode(ast_rec.continue_expr)
    else
        MirNodeIndex.none;
    return mir_typed.WhileStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .condition = cond,
        .body = body,
        .continue_expr = continue_expr,
    });
}

fn lowerForStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ForStmt.unpack(b.ast, idx);

    // Lower body.
    const body = try b.lowerNode(ast_rec.body);

    // Lower iterables: expression nodes write extra_data internally via their pack functions,
    // so collect MirNodeIndex values and append them contiguously afterward.
    var iterable_indices: std.ArrayListUnmanaged(u32) = .{};
    defer iterable_indices.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.iterables_start..ast_rec.iterables_end]) |iu32| {
        const it_mir = try b.lowerNode(@enumFromInt(iu32));
        try iterable_indices.append(b.allocator, @intFromEnum(it_mir));
    }
    const iterables_start: u32 = @intCast(b.store.extra_data.items.len);
    try b.store.extra_data.appendSlice(b.allocator, iterable_indices.items);
    const iterables_end: u32 = @intCast(b.store.extra_data.items.len);

    // Copy captures: StringIndex values re-interned from AST pool into MIR pool.
    const captures_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.captures_start..ast_rec.captures_end]) |si_u32| {
        const ast_si: StringIndex = @enumFromInt(si_u32);
        const mir_si = try b.store.strings.intern(b.allocator, b.ast.strings.get(ast_si));
        try b.store.extra_data.append(b.allocator, @intFromEnum(mir_si));
    }
    const captures_end: u32 = @intCast(b.store.extra_data.items.len);

    return mir_typed.ForStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .body = body,
        .iterables_start = iterables_start,
        .iterables_end = iterables_end,
        .captures_start = captures_start,
        .captures_end = captures_end,
        .flags = ast_rec.flags,
    });
}

fn lowerDeferStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.DeferStmt.unpack(b.ast, idx);
    const body = try b.lowerNode(ast_rec.body);
    return mir_typed.DeferStmt.pack(b.store, b.allocator, idx, .none, .plain, .{ .body = body });
}

fn lowerMatchStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.MatchStmt.unpack(b.ast, idx);

    const value = try b.lowerNode(ast_rec.value);

    // Lower arms: MatchArm.pack writes MatchArmExtra to extra_data internally,
    // so collect MirNodeIndex values and append them contiguously afterward.
    var arm_indices: std.ArrayListUnmanaged(u32) = .{};
    defer arm_indices.deinit(b.allocator);
    for (b.ast.extra_data.items[ast_rec.arms_start..ast_rec.arms_end]) |au32| {
        const arm_mir = try b.lowerNode(@enumFromInt(au32));
        try arm_indices.append(b.allocator, @intFromEnum(arm_mir));
    }
    const arms_start: u32 = @intCast(b.store.extra_data.items.len);
    try b.store.extra_data.appendSlice(b.allocator, arm_indices.items);
    const arms_end: u32 = @intCast(b.store.extra_data.items.len);

    return mir_typed.MatchStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .value = value,
        .arms_start = arms_start,
        .arms_end = arms_end,
    });
}

fn lowerMatchArm(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.MatchArm.unpack(b.ast, idx);
    const pattern = try b.lowerNode(ast_rec.pattern);
    const guard = if (ast_rec.guard != .none) try b.lowerNode(ast_rec.guard) else .none;
    const body = try b.lowerNode(ast_rec.body);
    return mir_typed.MatchArm.pack(b.store, b.allocator, idx, .none, .plain, .{
        .pattern = pattern,
        .guard = guard,
        .body = body,
    });
}

fn lowerAssignment(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.Assignment.unpack(b.ast, idx);
    const lhs = try b.lowerNode(ast_rec.lhs);
    const rhs = try b.lowerNode(ast_rec.rhs);
    if (b.type_map.get(ast_rec.lhs)) |lhs_rt| {
        const lhs_type_id = try internRT(b, lhs_rt);
        b.stampCoercion(rhs, b.inferCoercion(ast_rec.rhs, lhs_type_id));
    }
    return mir_typed.Assignment.pack(b.store, b.allocator, idx, .none, .plain, .{
        .op = ast_rec.op,
        .lhs = lhs,
        .rhs = rhs,
    });
}

fn lowerBreakStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    return mir_typed.BreakStmt.pack(b.store, b.allocator, idx, .none, .plain, .{});
}

fn lowerContinueStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    return mir_typed.ContinueStmt.pack(b.store, b.allocator, idx, .none, .plain, .{});
}

// ── Narrowing detection ───────────────────────────────────────────────────────

fn buildNarrowBranchExtra(b: *MirBuilder, source_rt: RT, name_opt: ?[]const u8) !mir_typed.NarrowBranchExtra {
    const name = name_opt orelse return .{
        .type_name = .none,
        .positional_tag = 0xFFFF_FFFF,
        .kind = 0,
    };
    const kind: u32 = if (mir_types.isErrorTypeName(name)) 1
        else if (mir_types.isNullTypeName(name)) 2
        else 0;
    const tag = mir_types.positionalTagOf(source_rt, name);
    const pt: u32 = if (tag) |t| @as(u32, t) else 0xFFFF_FFFF;
    const si = try b.store.strings.intern(b.allocator, name);
    return .{ .type_name = si, .positional_tag = pt, .kind = kind };
}

fn remainingUnionTypeName(members_rt: ?[]const RT, excluded: []const u8) ?[]const u8 {
    const members = members_rt orelse return null;
    var remaining: ?[]const u8 = null;
    for (members) |m| {
        const n = m.name();
        if (std.mem.eql(u8, n, excluded)) continue;
        if (mir_types.isErrorTypeName(n) or mir_types.isNullTypeName(n)) continue;
        if (remaining != null) return null;
        remaining = n;
    }
    return remaining;
}

/// Returns true if every control-flow path in the block ends with an early exit
/// (return, break, or continue) as a direct statement. Shallow check only.
fn blockHasEarlyExit(ast: *const @import("ast_store.zig").AstStore, block_idx: AstNodeIndex) bool {
    const stmts = ast_typed.Block.getStmts(ast, block_idx);
    if (stmts.len == 0) return false;
    const last = stmts[stmts.len - 1];
    const tag = ast.getNode(last).tag;
    return tag == .return_stmt or tag == .break_stmt or tag == .continue_stmt;
}

fn extractNarrowing(b: *MirBuilder, cond_idx: AstNodeIndex, then_idx: AstNodeIndex) anyerror!MirExtraIndex {
    const cond_node = b.ast.getNode(cond_idx);
    if (cond_node.tag != .binary_expr) return .none;

    const bin = ast_typed.BinaryExpr.unpack(b.ast, cond_idx);
    const bin_op: parser.Operator = @enumFromInt(bin.op);
    const is_eq = bin_op == .eq;
    const is_ne = bin_op == .ne;
    if (!is_eq and !is_ne) return .none;

    const lhs_node = b.ast.getNode(bin.lhs);
    if (lhs_node.tag != .compiler_func) return .none;
    const cf = ast_typed.CompilerFunc.unpack(b.ast, bin.lhs);
    const cf_name = b.ast.strings.get(cf.name);
    if (!std.mem.eql(u8, cf_name, "type")) return .none;
    if (cf.args_end <= cf.args_start) return .none;

    const val_ast_idx: AstNodeIndex = @enumFromInt(b.ast.extra_data.items[cf.args_start]);
    const val_node = b.ast.getNode(val_ast_idx);
    if (val_node.tag != .identifier) return .none;
    const val_name = b.ast.strings.get(val_node.data.str);

    const source_rt = blk: {
        if (b.type_map.get(val_ast_idx)) |rt| {
            if (rt == .union_type or rt == .null_type or rt == .err) break :blk rt;
        }
        if (b.var_types.get(val_name)) |type_id| {
            if (type_id != .none) {
                const rt = b.store.types.get(type_id);
                if (rt == .union_type) break :blk rt;
            }
        }
        // Fallback: look up in current function's parameter list via DeclTable.
        if (b.decls) |decls| {
            if (b.current_func_name) |fname| {
                if (decls.funcs.get(fname)) |sig| {
                    for (sig.params) |p| {
                        if (std.mem.eql(u8, p.name, val_name)) break :blk p.type_;
                    }
                }
            }
        }
        return .none;
    };
    const tc = mir_types.classifyType(source_rt);
    if (tc != .arbitrary_union and tc != .error_union and tc != .null_union and tc != .null_error_union)
        return .none;

    const rhs_node = b.ast.getNode(bin.rhs);
    const type_name: []const u8 = switch (rhs_node.tag) {
        .identifier => b.ast.strings.get(rhs_node.data.str),
        .null_literal => "null",
        else => return .none,
    };

    const members_rt = if (source_rt == .union_type) source_rt.union_type else null;
    const remaining = remainingUnionTypeName(members_rt, type_name);
    const has_early_exit = if (then_idx != .none) blockHasEarlyExit(b.ast, then_idx) else false;

    const then_name: ?[]const u8 = if (is_eq) type_name else remaining;
    const else_name: ?[]const u8 = if (is_eq) remaining else type_name;
    const post_name: ?[]const u8 = if (has_early_exit) (if (is_eq) remaining else type_name) else null;

    const var_si = try b.store.strings.intern(b.allocator, val_name);
    const then_branch = try buildNarrowBranchExtra(b, source_rt, then_name);
    const else_branch = try buildNarrowBranchExtra(b, source_rt, else_name);
    const post_branch = try buildNarrowBranchExtra(b, source_rt, post_name);

    return b.store.appendExtra(b.allocator, mir_typed.IfNarrowingExtra{
        .var_name = var_si,
        .type_class = @intFromEnum(tc),
        .has_then = if (then_name != null) 1 else 0,
        .then_type_name = then_branch.type_name,
        .then_positional_tag = then_branch.positional_tag,
        .then_kind = then_branch.kind,
        .has_else = if (else_name != null) 1 else 0,
        .else_type_name = else_branch.type_name,
        .else_positional_tag = else_branch.positional_tag,
        .else_kind = else_branch.kind,
        .has_post = if (post_name != null) 1 else 0,
        .post_type_name = post_branch.type_name,
        .post_positional_tag = post_branch.positional_tag,
        .post_kind = post_branch.kind,
    });
}
