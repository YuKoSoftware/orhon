// mir_builder_stmts.zig — statements cluster for MirBuilder (Phase B6)
// Satellite of mir_builder.zig — all functions take *MirBuilder as first parameter.
// Covers: block, return_stmt, if_stmt, while_stmt, for_stmt, defer_stmt,
//         match_stmt, match_arm, assignment, break_stmt, continue_stmt.

const std = @import("std");
const mir_builder_mod = @import("mir_builder.zig");
const ast_typed = @import("ast_typed.zig");
const mir_typed = @import("mir_typed.zig");
const string_pool = @import("string_pool.zig");

const MirBuilder = mir_builder_mod.MirBuilder;
const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
const MirNodeIndex = @import("mir_store.zig").MirNodeIndex;
const StringIndex = string_pool.StringIndex;

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
    return mir_typed.ReturnStmt.pack(b.store, b.allocator, idx, .none, .plain, .{ .value = value });
}

fn lowerIfStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.IfStmt.unpack(b.ast, idx);
    const cond = try b.lowerNode(ast_rec.condition);
    const then_b = try b.lowerNode(ast_rec.then_block);
    const else_b = if (ast_rec.else_block != .none) try b.lowerNode(ast_rec.else_block) else .none;
    return mir_typed.IfStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .condition = cond,
        .then_block = then_b,
        .else_block = else_b,
    });
}

fn lowerWhileStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.WhileStmt.unpack(b.ast, idx);
    const cond = try b.lowerNode(ast_rec.condition);
    const body = try b.lowerNode(ast_rec.body);
    return mir_typed.WhileStmt.pack(b.store, b.allocator, idx, .none, .plain, .{
        .condition = cond,
        .body = body,
    });
}

fn lowerForStmt(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ForStmt.unpack(b.ast, idx);

    // Lower body.
    const body = try b.lowerNode(ast_rec.body);

    // Lower iterables: AstNodeIndex → MirNodeIndex.
    const iterables_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.iterables_start..ast_rec.iterables_end]) |iu32| {
        const it_mir = try b.lowerNode(@enumFromInt(iu32));
        try b.store.extra_data.append(b.allocator, @intFromEnum(it_mir));
    }
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

    // Lower arms: AstNodeIndex → MirNodeIndex.
    const arms_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.arms_start..ast_rec.arms_end]) |au32| {
        const arm_mir = try b.lowerNode(@enumFromInt(au32));
        try b.store.extra_data.append(b.allocator, @intFromEnum(arm_mir));
    }
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
