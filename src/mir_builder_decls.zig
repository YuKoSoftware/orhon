// mir_builder_decls.zig — declarations cluster for MirBuilder (Phase B5)
// Satellite of mir_builder.zig — all functions take *MirBuilder as first parameter.
// Covers: func, struct_def, enum_def, handle_def, var_decl, test_def, destruct, import.

const std = @import("std");
const mir_builder_mod = @import("mir_builder.zig");
const ast_typed = @import("ast_typed.zig");
const mir_typed = @import("mir_typed.zig");
const mir_types = @import("mir/mir_types.zig");
const string_pool = @import("string_pool.zig");

const MirBuilder = mir_builder_mod.MirBuilder;
const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
const MirNodeIndex = @import("mir_store.zig").MirNodeIndex;
const TypeId = @import("type_store.zig").TypeId;
const RT = @import("types.zig").ResolvedType;
const StringIndex = string_pool.StringIndex;

// ── Public dispatch ──────────────────────────────────────────────────────────

/// Called by MirBuilder.lowerNode for all declaration-kind AstNodes.
pub fn lowerDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    return switch (b.ast.getNode(idx).tag) {
        .func_decl => lowerFuncDecl(b, idx),
        .struct_decl => lowerStructDecl(b, idx),
        .enum_decl => lowerEnumDecl(b, idx),
        .handle_decl => lowerHandleDecl(b, idx),
        .var_decl => lowerVarDecl(b, idx),
        .test_decl => lowerTestDecl(b, idx),
        .destruct_decl => lowerDestructDecl(b, idx),
        .import_decl => lowerImportDecl(b, idx),
        else => unreachable,
    };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Intern a ResolvedType; returns TypeId.none for unknown/inferred.
fn internRT(b: *MirBuilder, rt: RT) !TypeId {
    if (rt == .unknown or rt == .inferred) return .none;
    return b.store.types.intern(b.allocator, rt);
}

/// Intern a string from the AST pool into the MIR strings pool.
fn internStr(b: *MirBuilder, ast_si: StringIndex) !StringIndex {
    return b.store.strings.intern(b.allocator, b.ast.strings.get(ast_si));
}

/// Register non-null/non-error union members with the union registry.
fn registerUnionArities(b: *MirBuilder, members: []const RT) !void {
    var arity: usize = 0;
    for (members) |m| {
        if (m != .err and m != .null_type) arity += 1;
    }
    if (arity < 2) return;
    try b.union_registry.registerArity(b.current_module_name, arity);
}

// ── Declaration lowerers ──────────────────────────────────────────────────────

fn lowerFuncDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.FuncDecl.unpack(b.ast, idx);
    const name_str = b.ast.strings.get(ast_rec.name);

    const prev_func = b.current_func_name;
    b.current_func_name = name_str;
    defer b.current_func_name = prev_func;

    // Lower params → MirNodeIndex values in MIR extra_data.
    const params_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.params_start..ast_rec.params_end]) |pu32| {
        const param_mir = try b.lowerNode(@enumFromInt(pu32));
        try b.store.extra_data.append(b.allocator, @intFromEnum(param_mir));
    }
    const params_end: u32 = @intCast(b.store.extra_data.items.len);

    const body = try b.lowerNode(ast_rec.body);
    const name = try internStr(b, ast_rec.name);
    const rt = b.type_map.get(idx) orelse .unknown;
    const tid = try internRT(b, rt);

    return mir_typed.Func.pack(b.store, b.allocator, idx, tid, mir_types.classifyType(rt), .{
        .name = name,
        .return_type = ast_rec.return_type,
        .body = body,
        .params_start = params_start,
        .params_end = params_end,
        .flags = ast_rec.flags,
    });
}

fn lowerStructDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.StructDecl.unpack(b.ast, idx);

    // Lower members → MirNodeIndex values.
    const members_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.members_start..ast_rec.members_end]) |mu32| {
        const m_mir = try b.lowerNode(@enumFromInt(mu32));
        try b.store.extra_data.append(b.allocator, @intFromEnum(m_mir));
    }
    const members_end: u32 = @intCast(b.store.extra_data.items.len);

    // type_params: copy AstNodeIndex values from AST extra_data.
    const tp_start: u32 = @intCast(b.store.extra_data.items.len);
    try b.store.extra_data.appendSlice(
        b.allocator,
        b.ast.extra_data.items[ast_rec.type_params_start..ast_rec.type_params_end],
    );
    const tp_end: u32 = @intCast(b.store.extra_data.items.len);

    // blueprints: re-intern name strings from AST pool into MIR pool.
    const bp_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.blueprints_start..ast_rec.blueprints_end]) |si_u32| {
        const ast_si: StringIndex = @enumFromInt(si_u32);
        const mir_si = try b.store.strings.intern(b.allocator, b.ast.strings.get(ast_si));
        try b.store.extra_data.append(b.allocator, @intFromEnum(mir_si));
    }
    const bp_end: u32 = @intCast(b.store.extra_data.items.len);

    const name = try internStr(b, ast_rec.name);
    const name_str = b.ast.strings.get(ast_rec.name);
    const rt = b.type_map.get(idx) orelse RT{ .named = name_str };
    const tid = try internRT(b, rt);

    return mir_typed.StructDef.pack(b.store, b.allocator, idx, tid, .plain, .{
        .name = name,
        .members_start = members_start,
        .members_end = members_end,
        .type_params_start = tp_start,
        .type_params_end = tp_end,
        .blueprints_start = bp_start,
        .blueprints_end = bp_end,
        .flags = ast_rec.flags,
    });
}

fn lowerEnumDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.EnumDecl.unpack(b.ast, idx);

    // Lower members → MirNodeIndex values.
    const members_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.members_start..ast_rec.members_end]) |mu32| {
        const m_mir = try b.lowerNode(@enumFromInt(mu32));
        try b.store.extra_data.append(b.allocator, @intFromEnum(m_mir));
    }
    const members_end: u32 = @intCast(b.store.extra_data.items.len);

    const name = try internStr(b, ast_rec.name);
    const name_str = b.ast.strings.get(ast_rec.name);
    const rt = b.type_map.get(idx) orelse RT{ .named = name_str };
    const tid = try internRT(b, rt);

    return mir_typed.EnumDef.pack(b.store, b.allocator, idx, tid, .plain, .{
        .name = name,
        .backing_type = ast_rec.backing_type,
        .members_start = members_start,
        .members_end = members_end,
        .flags = ast_rec.flags,
    });
}

fn lowerHandleDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.HandleDecl.unpack(b.ast, idx);
    const name = try internStr(b, ast_rec.name);
    const name_str = b.ast.strings.get(ast_rec.name);
    const rt = b.type_map.get(idx) orelse RT{ .named = name_str };
    const tid = try internRT(b, rt);

    return mir_typed.HandleDef.pack(b.store, b.allocator, idx, tid, .plain, .{
        .name = name,
        .flags = ast_rec.flags,
    });
}

fn lowerVarDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.VarDecl.unpack(b.ast, idx);
    const rt = b.type_map.get(idx) orelse .unknown;
    const tc = mir_types.classifyType(rt);
    const tid = try internRT(b, rt);

    // Lower value expression.
    const value = try b.lowerNode(ast_rec.value);

    // Track variable type for later union-tag resolution (BR2).
    // Key is borrowed from b.ast.strings; lifetime tied to AstStore.
    const name_str = b.ast.strings.get(ast_rec.name);
    try b.var_types.put(b.allocator, name_str, tid);

    // Register union arities (for _unions.zig codegen sizing).
    if (rt == .union_type) try registerUnionArities(b, rt.union_type);

    const name = try internStr(b, ast_rec.name);

    return mir_typed.VarDecl.pack(b.store, b.allocator, idx, tid, tc, .{
        .name = name,
        .value = value,
        .type_annotation = ast_rec.type_annotation,
        .flags = ast_rec.flags,
    });
}

fn lowerTestDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.TestDecl.unpack(b.ast, idx);
    const body = try b.lowerNode(ast_rec.body);
    const desc = try internStr(b, ast_rec.description);

    return mir_typed.TestDef.pack(b.store, b.allocator, idx, .none, .plain, .{
        .description = desc,
        .body = body,
    });
}

fn lowerDestructDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.DestructDecl.unpack(b.ast, idx);
    const value = try b.lowerNode(ast_rec.value);

    // Re-intern name strings from AST pool into MIR pool and append to MIR extra_data.
    const names_start: u32 = @intCast(b.store.extra_data.items.len);
    for (b.ast.extra_data.items[ast_rec.names_start..ast_rec.names_end]) |si_u32| {
        const ast_si: StringIndex = @enumFromInt(si_u32);
        const mir_si = try b.store.strings.intern(b.allocator, b.ast.strings.get(ast_si));
        try b.store.extra_data.append(b.allocator, @intFromEnum(mir_si));
    }
    const names_end: u32 = @intCast(b.store.extra_data.items.len);

    return mir_typed.Destruct.pack(b.store, b.allocator, idx, .none, .plain, .{
        .value = value,
        .names_start = names_start,
        .names_end = names_end,
        .flags = ast_rec.is_const,
    });
}

fn lowerImportDecl(b: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
    const ast_rec = ast_typed.ImportDecl.unpack(b.ast, idx);
    const path = try internStr(b, ast_rec.path);
    const scope = try internStr(b, ast_rec.scope);
    const alias = try internStr(b, ast_rec.alias);

    return mir_typed.Import.pack(b.store, b.allocator, idx, .none, .plain, .{
        .path = path,
        .scope = scope,
        .alias = alias,
        .flags = ast_rec.flags,
    });
}
