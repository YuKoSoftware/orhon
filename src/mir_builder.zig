// mir_builder.zig — fused MIR builder hub (Phase B: passthrough skeleton)
// Replaces MirAnnotator + MirLowerer once populated (B5-B8).
// Satellite files (mir_builder_decls.zig, etc.) added per cluster in B5-B8.
// Contract: AstStore must outlive MirBuilder (span back-pointers are AstNodeIndex).

const std = @import("std");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const mir_types = @import("mir/mir_types.zig");
const mir_registry = @import("mir/mir_registry.zig");
const ast_store_mod = @import("ast_store.zig");
const mir_store_mod = @import("mir_store.zig");
const mir_typed = @import("mir_typed.zig");
const type_store_mod = @import("type_store.zig");
const decls_impl = @import("mir_builder_decls.zig");
const stmts_impl = @import("mir_builder_stmts.zig");
const exprs_impl = @import("mir_builder_exprs.zig");

const AstNodeIndex = ast_store_mod.AstNodeIndex;
const AstStore = ast_store_mod.AstStore;
const MirStore = mir_store_mod.MirStore;
const MirNodeIndex = mir_store_mod.MirNodeIndex;
const MirKind = mir_store_mod.MirKind;
const RT = mir_types.RT;
const TypeClass = mir_types.TypeClass;
const Coercion = mir_types.Coercion;
const TypeId = type_store_mod.TypeId;
const UnionRegistry = mir_registry.UnionRegistry;

// Internal phase-separation result (BR4).
const ClassifyResult = struct {
    type_class: TypeClass,
    rt: RT,
};

pub const MirBuilder = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,
    decls: *declarations.DeclTable,
    /// AstNodeIndex-keyed type map produced by the resolver.
    /// Populated starting at B5; empty at B4 (passthrough-only).
    type_map: *const std.AutoHashMapUnmanaged(AstNodeIndex, RT),
    ast: *const AstStore,
    store: *MirStore,
    union_registry: *UnionRegistry,
    /// Variable name → TypeId fallback — used when a narrowed MirNode type
    /// hides the source union (BR2). Populated in B5+.
    /// Keys are slices borrowed from b.ast.strings — valid only while AstStore is alive.
    var_types: std.StringHashMapUnmanaged(TypeId),
    /// Current function name — for return-type resolution in B5+.
    current_func_name: ?[]const u8,
    /// Module currently being built — for union-registry attribution in B5+.
    current_module_name: []const u8,
    /// Per-interpolation counter threaded through lowering (BR3).
    interp_counter: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *errors.Reporter,
        decls: *declarations.DeclTable,
        type_map: *const std.AutoHashMapUnmanaged(AstNodeIndex, RT),
        ast: *const AstStore,
        store: *MirStore,
        union_registry: *UnionRegistry,
    ) MirBuilder {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .decls = decls,
            .type_map = type_map,
            .ast = ast,
            .store = store,
            .union_registry = union_registry,
            .var_types = .{},
            .current_func_name = null,
            .current_module_name = "",
            .interp_counter = 0,
        };
    }

    pub fn deinit(self: *MirBuilder) void {
        self.var_types.deinit(self.allocator);
    }

    pub fn build(self: *MirBuilder, root: AstNodeIndex) !MirNodeIndex {
        return self.lowerNode(root);
    }

    // ── Internal phase separation (BR4) ──────────────────────────────────
    // Ordering within lowerNode: classify → infer coercion → emit.
    // Kept as separate private functions even as stubs so the invariant
    // survives incremental population in B5-B8.

    fn classifyNode(self: *MirBuilder, idx: AstNodeIndex) ClassifyResult {
        _ = self;
        _ = idx;
        return .{ .type_class = .plain, .rt = .unknown };
    }

    fn inferCoercion(self: *MirBuilder, idx: AstNodeIndex, ty: TypeId) ?Coercion {
        _ = self;
        _ = idx;
        _ = ty;
        return null;
    }

    pub fn lowerNode(self: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
        const kind = self.ast.getNode(idx).tag;
        const cls = self.classifyNode(idx);
        _ = self.inferCoercion(idx, .none);
        return switch (kind) {
            .func_decl,
            .struct_decl,
            .enum_decl,
            .handle_decl,
            .var_decl,
            .test_decl,
            .destruct_decl,
            .import_decl,
            => decls_impl.lowerDecl(self, idx),
            .block,
            .return_stmt,
            .if_stmt,
            .while_stmt,
            .for_stmt,
            .defer_stmt,
            .match_stmt,
            .match_arm,
            .assignment,
            .break_stmt,
            .continue_stmt,
            => stmts_impl.lowerStmt(self, idx),
            .int_literal, .float_literal, .string_literal,
            .bool_literal, .null_literal, .error_literal,
            .identifier, .binary_expr, .range_expr,
            .unary_expr, .call_expr, .field_expr,
            .index_expr, .slice_expr,
            .mut_borrow_expr, .const_borrow_expr,
            .interpolated_string, .compiler_func,
            .array_literal, .tuple_literal, .version_literal,
            => exprs_impl.lowerExpr(self, idx),
            else => mir_typed.Passthrough.pack(
                self.store,
                self.allocator,
                idx,
                .none,
                cls.type_class,
                .{},
            ),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const ast_typed = @import("ast_typed.zig");

fn testBuilder(allocator: std.mem.Allocator, ast_store: *AstStore, mir_store: *MirStore, type_map: *std.AutoHashMapUnmanaged(AstNodeIndex, RT), union_registry: *UnionRegistry) MirBuilder {
    return MirBuilder.init(allocator, undefined, undefined, type_map, ast_store, mir_store, union_registry);
}

test "MirBuilder: passthrough for non-declaration node" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    // Pack a node that falls through to passthrough (null_literal now emits MirKind.literal).
    const tu_idx = try ast_typed.TypeUnion.pack(&ast_store, allocator, .none, &.{});

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.build(tu_idx);
    try std.testing.expect(mir_idx != .none);
    try std.testing.expectEqual(MirKind.passthrough, mir_store.getNode(mir_idx).tag);
    try std.testing.expectEqual(tu_idx, mir_store.getNode(mir_idx).span);
}

test "MirBuilder: two build calls produce distinct indices" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const a_ast = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const b_ast = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const a = try builder.build(a_ast);
    const b = try builder.build(b_ast);
    try std.testing.expect(a != b);
}

// ── B5: Declaration cluster tests ───────────────────────────────────────────

test "MirBuilder B5: var_decl emits MirKind.var_decl" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const name_si = try ast_store.strings.intern(allocator, "x");
    const val_idx = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const var_idx = try ast_typed.VarDecl.pack(&ast_store, allocator, .none, .{
        .name = name_si, .value = val_idx, .type_annotation = .none, .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(var_idx);
    try std.testing.expectEqual(MirKind.var_decl, mir_store.getNode(mir_idx).tag);
    try std.testing.expectEqual(var_idx, mir_store.getNode(mir_idx).span);
}

test "MirBuilder B5: import_decl emits MirKind.import" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const path_si = try ast_store.strings.intern(allocator, "std");
    const scope_si = try ast_store.strings.intern(allocator, "");
    const alias_si = try ast_store.strings.intern(allocator, "std");
    const imp_idx = try ast_typed.ImportDecl.pack(&ast_store, allocator, .none, .{
        .path = path_si, .scope = scope_si, .alias = alias_si, .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(imp_idx);
    try std.testing.expectEqual(MirKind.import, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B5: handle_decl emits MirKind.handle_def" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const name_si = try ast_store.strings.intern(allocator, "File");
    const hdl_idx = try ast_typed.HandleDecl.pack(&ast_store, allocator, .none, .{
        .name = name_si, .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(hdl_idx);
    try std.testing.expectEqual(MirKind.handle_def, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B5: func_decl emits MirKind.func with lowered body" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const name_si = try ast_store.strings.intern(allocator, "foo");
    const body_idx = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const func_idx = try ast_typed.FuncDecl.pack(&ast_store, allocator, .none, .{
        .name = name_si,
        .return_type = .none,
        .body = body_idx,
        .params_start = 0,
        .params_end = 0,
        .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(func_idx);
    const entry = mir_store.getNode(mir_idx);
    try std.testing.expectEqual(MirKind.func, entry.tag);
    // body is separately stored as a passthrough since Block is not a decl kind
    const rec = mir_typed.Func.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.body != .none);
}

test "MirBuilder B5: struct_decl emits MirKind.struct_def" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const name_si = try ast_store.strings.intern(allocator, "Point");
    const struct_idx = try ast_typed.StructDecl.pack(&ast_store, allocator, .none, .{
        .name = name_si,
        .members_start = 0, .members_end = 0,
        .type_params_start = 0, .type_params_end = 0,
        .blueprints_start = 0, .blueprints_end = 0,
        .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(struct_idx);
    try std.testing.expectEqual(MirKind.struct_def, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B5: enum_decl emits MirKind.enum_def" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const name_si = try ast_store.strings.intern(allocator, "Color");
    const enum_idx = try ast_typed.EnumDecl.pack(&ast_store, allocator, .none, .{
        .name = name_si,
        .backing_type = .none,
        .members_start = 0, .members_end = 0,
        .flags = 0,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(enum_idx);
    try std.testing.expectEqual(MirKind.enum_def, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B5: test_decl emits MirKind.test_def" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const desc_si = try ast_store.strings.intern(allocator, "my test");
    const body_idx = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const test_idx = try ast_typed.TestDecl.pack(&ast_store, allocator, .none, .{
        .description = desc_si, .body = body_idx,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(test_idx);
    try std.testing.expectEqual(MirKind.test_def, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B5: destruct_decl emits MirKind.destruct" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const val_idx = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const dest_idx = try ast_typed.DestructDecl.pack(&ast_store, allocator, .none, .{
        .value = val_idx, .names_start = 0, .names_end = 0, .is_const = 1,
    });

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(dest_idx);
    try std.testing.expectEqual(MirKind.destruct, mir_store.getNode(mir_idx).tag);
}

// ── B6: Statements cluster tests ────────────────────────────────────────────

test "MirBuilder B6: break_stmt emits MirKind.break_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const brk = try ast_typed.BreakStmt.pack(&ast_store, allocator, .none, .{});
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(brk);
    try std.testing.expectEqual(MirKind.break_stmt, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B6: continue_stmt emits MirKind.continue_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const cont = try ast_typed.ContinueStmt.pack(&ast_store, allocator, .none, .{});
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(cont);
    try std.testing.expectEqual(MirKind.continue_stmt, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B6: return_stmt emits MirKind.return_stmt with lowered value" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const val = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const ret = try ast_typed.ReturnStmt.pack(&ast_store, allocator, .none, .{ .value = val });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(ret);
    try std.testing.expectEqual(MirKind.return_stmt, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B6: defer_stmt emits MirKind.defer_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const body = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const dfr = try ast_typed.DeferStmt.pack(&ast_store, allocator, .none, .{ .body = body });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(dfr);
    try std.testing.expectEqual(MirKind.defer_stmt, mir_store.getNode(mir_idx).tag);
}

test "MirBuilder B6: block emits MirKind.block and lowers child stmts" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const s1 = try ast_typed.BreakStmt.pack(&ast_store, allocator, .none, .{});
    const s2 = try ast_typed.ContinueStmt.pack(&ast_store, allocator, .none, .{});
    const blk = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{ s1, s2 });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(blk);
    try std.testing.expectEqual(MirKind.block, mir_store.getNode(mir_idx).tag);
    const stmts = mir_typed.Block.getStmts(&mir_store, mir_idx);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expectEqual(MirKind.break_stmt, mir_store.getNode(stmts[0]).tag);
    try std.testing.expectEqual(MirKind.continue_stmt, mir_store.getNode(stmts[1]).tag);
}

test "MirBuilder B6: if_stmt emits MirKind.if_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const cond = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const then_b = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const if_idx = try ast_typed.IfStmt.pack(&ast_store, allocator, .none, .{
        .condition = cond, .then_block = then_b, .else_block = .none,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(if_idx);
    try std.testing.expectEqual(MirKind.if_stmt, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.IfStmt.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.condition != .none);
    try std.testing.expect(rec.then_block != .none);
}

test "MirBuilder B6: while_stmt emits MirKind.while_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const cond = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const body = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const whl = try ast_typed.WhileStmt.pack(&ast_store, allocator, .none, .{
        .condition = cond, .body = body, .continue_expr = .none,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(whl);
    try std.testing.expectEqual(MirKind.while_stmt, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.WhileStmt.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.condition != .none);
    try std.testing.expect(rec.body != .none);
}

test "MirBuilder B6: for_stmt emits MirKind.for_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const body = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const for_idx = try ast_typed.ForStmt.pack(&ast_store, allocator, .none, .{
        .body = body,
        .iterables_start = 0, .iterables_end = 0,
        .captures_start = 0, .captures_end = 0,
        .flags = 0,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(for_idx);
    try std.testing.expectEqual(MirKind.for_stmt, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.ForStmt.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.body != .none);
}

test "MirBuilder B6: match_stmt emits MirKind.match_stmt" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const val = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const match_idx = try ast_typed.MatchStmt.pack(&ast_store, allocator, .none, .{
        .value = val, .arms_start = 0, .arms_end = 0,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(match_idx);
    try std.testing.expectEqual(MirKind.match_stmt, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.MatchStmt.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.value != .none);
}

test "MirBuilder B6: match_arm emits MirKind.match_arm" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const pat = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const body = try ast_typed.Block.pack(&ast_store, allocator, .none, &.{});
    const arm = try ast_typed.MatchArm.pack(&ast_store, allocator, .none, .{
        .pattern = pat, .guard = .none, .body = body,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(arm);
    try std.testing.expectEqual(MirKind.match_arm, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.MatchArm.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.pattern != .none);
    try std.testing.expect(rec.body != .none);
}

test "MirBuilder B6: assignment emits MirKind.assignment" {
    const allocator = std.testing.allocator;
    var mir_store = MirStore.init();
    defer mir_store.deinit(allocator);
    var ast_store = AstStore.init();
    defer ast_store.deinit(allocator);
    var type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{};
    defer type_map.deinit(allocator);
    var union_registry = UnionRegistry.init(allocator);
    defer union_registry.deinit();

    const lhs_si = try ast_store.strings.intern(allocator, "x");
    const lhs = try ast_typed.Identifier.pack(&ast_store, allocator, .none, .{ .name = lhs_si });
    const rhs = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});
    const asgn = try ast_typed.Assignment.pack(&ast_store, allocator, .none, .{
        .op = 0, .lhs = lhs, .rhs = rhs,
    });
    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.lowerNode(asgn);
    try std.testing.expectEqual(MirKind.assignment, mir_store.getNode(mir_idx).tag);
    const rec = mir_typed.Assignment.unpack(&mir_store, mir_idx);
    try std.testing.expect(rec.lhs != .none);
    try std.testing.expect(rec.rhs != .none);
}

// ── B7: Expressions cluster tests ───────────────────────────────────────────

test "MirBuilder B7: int_literal emits MirKind.literal kind=0" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const si = try as_.strings.intern(allocator, "42");
    const idx = try ast_typed.IntLiteral.pack(&as_, allocator, .none, .{ .text = si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 0), mir_typed.Literal.unpack(&ms, m).kind);
}

test "MirBuilder B7: float_literal emits MirKind.literal kind=1" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const si = try as_.strings.intern(allocator, "3.14");
    const idx = try ast_typed.FloatLiteral.pack(&as_, allocator, .none, .{ .text = si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 1), mir_typed.Literal.unpack(&ms, m).kind);
}

test "MirBuilder B7: string_literal emits MirKind.literal kind=2" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const si = try as_.strings.intern(allocator, "hello");
    const idx = try ast_typed.StringLiteral.pack(&as_, allocator, .none, .{ .text = si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 2), mir_typed.Literal.unpack(&ms, m).kind);
}

test "MirBuilder B7: bool_literal emits MirKind.literal kind=3 with bool_val" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const idx = try ast_typed.BoolLiteral.pack(&as_, allocator, .none, .{ .value = true });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    const rec = mir_typed.Literal.unpack(&ms, m);
    try std.testing.expectEqual(@as(u32, 3), rec.kind);
    try std.testing.expectEqual(@as(u32, 1), rec.bool_val);
}

test "MirBuilder B7: null_literal emits MirKind.literal kind=4" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const idx = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 4), mir_typed.Literal.unpack(&ms, m).kind);
}

test "MirBuilder B7: error_literal emits MirKind.literal kind=5" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const si = try as_.strings.intern(allocator, "NotFound");
    const idx = try ast_typed.ErrorLiteral.pack(&as_, allocator, .none, .{ .name = si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 5), mir_typed.Literal.unpack(&ms, m).kind);
}

test "MirBuilder B7: identifier emits MirKind.identifier" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const si = try as_.strings.intern(allocator, "myVar");
    const idx = try ast_typed.Identifier.pack(&as_, allocator, .none, .{ .name = si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.identifier, ms.getNode(m).tag);
    const rec = mir_typed.Identifier.unpack(&ms, m);
    // resolved_kind = 0 (stub until DeclTable API confirmed at B8).
    try std.testing.expectEqual(@as(u32, 0), rec.resolved_kind);
}

test "MirBuilder B7: binary_expr emits MirKind.binary with lhs and rhs" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const lhs = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const rhs = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.BinaryExpr.pack(&as_, allocator, .none, .{ .op = 0, .lhs = lhs, .rhs = rhs });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.binary, ms.getNode(m).tag);
    const rec = mir_typed.Binary.unpack(&ms, m);
    try std.testing.expect(rec.lhs != .none);
    try std.testing.expect(rec.rhs != .none);
}

test "MirBuilder B7: range_expr emits MirKind.binary" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const lhs = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const rhs = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.RangeExpr.pack(&as_, allocator, .none, .{ .op = 0, .lhs = lhs, .rhs = rhs });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.binary, ms.getNode(m).tag);
}

test "MirBuilder B7: unary_expr emits MirKind.unary" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const operand = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.UnaryExpr.pack(&as_, allocator, .none, .{ .op = 0, .operand = operand });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.unary, ms.getNode(m).tag);
    try std.testing.expect(mir_typed.Unary.unpack(&ms, m).operand != .none);
}

test "MirBuilder B7: mut_borrow_expr emits MirKind.borrow kind=1" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const child = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.MutBorrowExpr.pack(&as_, allocator, .none, .{ .child = child });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.borrow, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 1), mir_typed.Borrow.unpack(&ms, m).kind);
}

test "MirBuilder B7: const_borrow_expr emits MirKind.borrow kind=0" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const child = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.ConstBorrowExpr.pack(&as_, allocator, .none, .{ .child = child });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.borrow, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(u32, 0), mir_typed.Borrow.unpack(&ms, m).kind);
}
