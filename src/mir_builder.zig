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
const ast_typed = @import("ast_typed.zig");
const mir_store_mod = @import("mir_store.zig");
const mir_typed = @import("mir_typed.zig");
const type_store_mod = @import("type_store.zig");
const decls_impl   = @import("mir_builder_decls.zig");
const stmts_impl   = @import("mir_builder_stmts.zig");
const exprs_impl   = @import("mir_builder_exprs.zig");
const members_impl = @import("mir_builder_members.zig");
const types_impl   = @import("mir_builder_types.zig");

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
    decls: ?*declarations.DeclTable,
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
        decls: ?*declarations.DeclTable,
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
        // Program root: lower all top-level declarations and return them packed as a
        // Block so codegen can iterate via mir_typed.Block.getStmts(store, mir_root_idx).
        const kind = self.ast.getNode(root).tag;
        if (kind == .program) {
            const rec = ast_typed.Program.unpack(self.ast, root);
            var top_level = std.ArrayListUnmanaged(MirNodeIndex){};
            defer top_level.deinit(self.allocator);
            for (self.ast.extra_data.items[rec.top_level_start..rec.top_level_end]) |idx_u32| {
                const m = try self.lowerNode(@enumFromInt(idx_u32));
                try top_level.append(self.allocator, m);
            }
            return mir_typed.Block.pack(self.store, self.allocator, root, .none, .plain, top_level.items);
        }
        return self.lowerNode(root);
    }

    /// Create a synthetic temp_var node for interpolation hoisting (BR3).
    pub fn createTempVar(self: *MirBuilder, name: []const u8) !MirNodeIndex {
        return types_impl.createTempVar(self, name);
    }

    /// Create a synthetic injected_defer node for interpolation cleanup (BR3).
    pub fn createInjectedDefer(self: *MirBuilder, body: MirNodeIndex) !MirNodeIndex {
        return types_impl.createInjectedDefer(self, body);
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

    pub fn inferCoercion(self: *MirBuilder, idx: AstNodeIndex, dst_type_id: TypeId) ?Coercion {
        if (dst_type_id == .none) return null;
        const src_rt = self.type_map.get(idx) orelse return null;
        const dst_rt = self.store.types.get(dst_type_id);
        return detectCoercion(src_rt, dst_rt);
    }

    pub fn stampCoercion(self: *MirBuilder, idx: MirNodeIndex, c: ?Coercion) void {
        if (c) |coercion| {
            const raw = @intFromEnum(idx);
            self.store.nodes.items(.coercion_kind)[raw] =
                mir_store_mod.coercionToKind(coercion);
        }
    }

    pub fn lowerNode(self: *MirBuilder, idx: AstNodeIndex) anyerror!MirNodeIndex {
        const kind = self.ast.getNode(idx).tag;
        const cls = self.classifyNode(idx);
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
            .field_decl, .param, .enum_variant,
            => members_impl.lowerMember(self, idx),
            .type_slice, .type_array, .type_ptr, .type_union,
            .type_tuple_named, .type_func, .type_generic,
            .type_named, .struct_type,
            => types_impl.lowerTypeExpr(self, idx),
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
// Coercion helpers — free functions so satellites can call them
// ---------------------------------------------------------------------------

/// Determine if a value of type `src` needs coercion to fit `dst`.
/// Mirrors MirAnnotator.detectCoercion using the same logic.
pub fn detectCoercion(src: RT, dst: RT) ?Coercion {
    if (src == .unknown or src == .inferred or dst == .unknown or dst == .inferred)
        return null;
    if (src == .array and dst == .slice)
        return .array_to_slice;
    if (dst.unionContainsNull() and !src.unionContainsNull() and src != .null_type)
        return .null_wrap;
    if (dst.unionContainsError() and !src.unionContainsError() and src != .err)
        return .error_wrap;
    if (dst == .union_type and src != .union_type) {
        if (src == .null_type) {
            for (dst.union_type) |member| {
                if (member == .null_type) return null;
            }
        }
        if (src == .err and dst.unionContainsError()) return null;
        if (src == .primitive and src.primitive == .numeric_literal) {
            for (dst.union_type) |member| {
                if (member == .primitive and member.primitive.isInteger()) {
                    const tag = mir_types.positionalTagOf(dst, member.name()) orelse return null;
                    return .{ .arbitrary_union_wrap = tag };
                }
            }
        }
        if (src == .primitive and src.primitive == .float_literal) {
            for (dst.union_type) |member| {
                if (member == .primitive and member.primitive.isFloat()) {
                    const tag = mir_types.positionalTagOf(dst, member.name()) orelse return null;
                    return .{ .arbitrary_union_wrap = tag };
                }
            }
        }
        const tag = mir_types.positionalTagOf(dst, src.name()) orelse return null;
        return .{ .arbitrary_union_wrap = tag };
    }
    if (src.unionContainsNull() and !dst.unionContainsNull())
        return .optional_unwrap;
    if (dst == .ptr and dst.ptr.kind == .const_ref) {
        if (typesMatchForCoercion(src, dst.ptr.elem.*))
            return .value_to_const_ref;
    }
    return null;
}

fn typesMatchForCoercion(a: RT, b: RT) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .primitive => |p| p == b.primitive,
        .named => |n| std.mem.eql(u8, n, b.named),
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testBuilder(allocator: std.mem.Allocator, ast_store: *AstStore, mir_store: *MirStore, type_map: *std.AutoHashMapUnmanaged(AstNodeIndex, RT), union_registry: *UnionRegistry) MirBuilder {
    return MirBuilder.init(allocator, undefined, null, type_map, ast_store, mir_store, union_registry);
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

    // Pack a node that falls through to passthrough. module_decl has no routing arm.
    const name_si = try ast_store.strings.intern(allocator, "main");
    const tu_idx = try ast_typed.ModuleDecl.pack(&ast_store, allocator, .none, .{ .name = name_si, .doc = .none });

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
    try std.testing.expectEqual(mir_typed.MirExtraIndex.none, rec.narrowing_extra);
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
    try std.testing.expectEqual(MirNodeIndex.none, rec.continue_expr);
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

test "MirBuilder B7: call_expr lowers callee and args" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();

    // Build: callee(arg1, arg2) with no named args.
    const callee = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const arg1   = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const arg2   = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    // Store arg AstNodeIndex values in ast extra_data.
    const args_start: u32 = @intCast(as_.extra_data.items.len);
    try as_.extra_data.append(allocator, @intFromEnum(arg1));
    try as_.extra_data.append(allocator, @intFromEnum(arg2));
    const args_end: u32 = @intCast(as_.extra_data.items.len);
    const idx = try ast_typed.CallExpr.pack(&as_, allocator, .none, .{
        .callee = callee, .args_start = args_start, .args_end = args_end, .arg_names_start = 0,
    });

    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.call, ms.getNode(m).tag);
    const rec = mir_typed.Call.unpack(&ms, m);
    try std.testing.expect(rec.callee != .none);
    try std.testing.expect(rec.args_end - rec.args_start == 2);
}

test "MirBuilder B7: field_expr emits MirKind.field_access, stamps union_tag via var_types" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();

    // Build: x.str where x has union type [str | i32].
    // Intern the identifier "x" and field "str".
    const x_si = try as_.strings.intern(allocator, "x");
    const obj_idx = try ast_typed.Identifier.pack(&as_, allocator, .none, .{ .name = x_si });
    const field_si = try as_.strings.intern(allocator, "str");
    const idx = try ast_typed.FieldExpr.pack(&as_, allocator, .none, .{ .field = field_si, .object = obj_idx });

    var b = testBuilder(allocator, &as_, &ms, &tm, &ur);
    defer b.deinit();

    // Build a union RT [str | i32] and intern it into the MIR type store.
    // positionalTagOf filters Error/null and sorts canonically: i32 @ 0, str @ 1.
    const union_members = &[_]RT{
        RT{ .primitive = .string },
        RT{ .primitive = .i32 },
    };
    const union_rt = RT{ .union_type = union_members };
    const tid = try ms.types.intern(allocator, union_rt);

    // Register the union TypeId in var_types under the key "x".
    // Key must be a slice valid for the duration of the test (here a string literal suffices).
    try b.var_types.put(allocator, "x", tid);

    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.field_access, ms.getNode(m).tag);
    const rec = mir_typed.FieldAccess.unpack(&ms, m);
    // Sorted canonical order: i32 @ 0, str @ 1.
    // union_tag = positional_tag + 1 = 1 + 1 = 2.
    try std.testing.expect(rec.union_tag > 0);
}

test "MirBuilder B7: index_expr emits MirKind.index" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const obj = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx_node = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.IndexExpr.pack(&as_, allocator, .none, .{ .object = obj, .index = idx_node });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.index, ms.getNode(m).tag);
    const rec = mir_typed.Index.unpack(&ms, m);
    try std.testing.expect(rec.object != .none);
    try std.testing.expect(rec.index != .none);
}

test "MirBuilder B7: slice_expr emits MirKind.slice" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const obj = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const lo  = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const hi  = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.SliceExpr.pack(&as_, allocator, .none, .{ .object = obj, .low = lo, .high = hi });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.slice, ms.getNode(m).tag);
    const rec = mir_typed.Slice.unpack(&ms, m);
    try std.testing.expect(rec.object != .none);
    try std.testing.expect(rec.low != .none);
    try std.testing.expect(rec.high != .none);
}

test "MirBuilder B7: interpolated_string lowers expr parts to MirNodeIndex" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();

    // Build an interpolation with 2 parts: literal "hello " + expression (null).
    const lit_si = try as_.strings.intern(allocator, "hello ");
    const expr_node = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const parts_start: u32 = @intCast(as_.extra_data.items.len);
    try as_.extra_data.append(allocator, 0);                          // tag=0 (literal)
    try as_.extra_data.append(allocator, @intFromEnum(lit_si));
    try as_.extra_data.append(allocator, 1);                          // tag=1 (expr)
    try as_.extra_data.append(allocator, @intFromEnum(expr_node));
    const parts_end: u32 = @intCast(as_.extra_data.items.len);
    const idx = try ast_typed.InterpolatedString.pack(&as_, allocator, .none, .{
        .parts_start = parts_start, .parts_end = parts_end,
    });

    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.interpolation, ms.getNode(m).tag);
    const rec = mir_typed.Interpolation.unpack(&ms, m);
    // 2 parts × 2 words each = 4 words in extra_data.
    try std.testing.expectEqual(@as(u32, 4), rec.parts_end - rec.parts_start);
    // Second part (words 2-3) should be tag=1.
    const tag1 = ms.extra_data.items[rec.parts_start + 2];
    try std.testing.expectEqual(@as(u32, 1), tag1);
}

test "MirBuilder B7: compiler_func emits MirKind.compiler_fn" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "@cast");
    const arg = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const args_start: u32 = @intCast(as_.extra_data.items.len);
    try as_.extra_data.append(allocator, @intFromEnum(arg));
    const args_end: u32 = @intCast(as_.extra_data.items.len);
    const idx = try ast_typed.CompilerFunc.pack(&as_, allocator, .none, .{
        .name = name_si, .args_start = args_start, .args_end = args_end,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.compiler_fn, ms.getNode(m).tag);
    const rec = mir_typed.CompilerFn.unpack(&ms, m);
    try std.testing.expect(rec.args_end - rec.args_start == 1);
}

test "MirBuilder B7: array_literal lowers items" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const a = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const b2 = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.ArrayLiteral.pack(&as_, allocator, .none, &.{ a, b2 });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.array_lit, ms.getNode(m).tag);
    try std.testing.expectEqual(@as(usize, 2), mir_typed.ArrayLit.getItems(&ms, m).len);
}

test "MirBuilder B7: tuple_literal emits MirKind.tuple_lit" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const elem = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const elems_start: u32 = @intCast(as_.extra_data.items.len);
    try as_.extra_data.append(allocator, @intFromEnum(elem));
    const elems_end: u32 = @intCast(as_.extra_data.items.len);
    const idx = try ast_typed.TupleLiteral.pack(&as_, allocator, .none, .{
        .elements_start = elems_start, .elements_end = elems_end, .names_start = 0,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.tuple_lit, ms.getNode(m).tag);
    const rec = mir_typed.TupleLit.unpack(&ms, m);
    try std.testing.expect(rec.elements_end - rec.elements_start == 1);
}

test "MirBuilder B7: version_literal emits MirKind.version_lit" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const maj = try as_.strings.intern(allocator, "1");
    const min = try as_.strings.intern(allocator, "2");
    const pat = try as_.strings.intern(allocator, "3");
    const idx = try ast_typed.VersionLiteral.pack(&as_, allocator, .none, .{
        .major = maj, .minor = min, .patch = pat,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.version_lit, ms.getNode(m).tag);
}

// ── B8: Members + types + injected cluster tests ──────────────────────────────

test "MirBuilder B8: field_decl emits MirKind.field_def with name and type_annotation" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "x");
    const type_ann = try ast_typed.TypeNamed.pack(&as_, allocator, .none, .{ .name = name_si });
    const idx = try ast_typed.FieldDecl.pack(&as_, allocator, .none, .{
        .name = name_si, .type_annotation = type_ann, .default_value = .none, .flags = 0,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.field_def, ms.getNode(m).tag);
    const rec = mir_typed.FieldDef.unpack(&ms, m);
    try std.testing.expectEqual(type_ann, rec.type_annotation);
    try std.testing.expectEqual(MirNodeIndex.none, rec.default);
    try std.testing.expectEqualStrings("x", ms.strings.get(rec.name));
}

test "MirBuilder B8: field_decl with default value lowers default" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "count");
    const type_ann = try ast_typed.TypeNamed.pack(&as_, allocator, .none, .{ .name = name_si });
    const default_val = try ast_typed.NullLiteral.pack(&as_, allocator, .none, .{});
    const idx = try ast_typed.FieldDecl.pack(&as_, allocator, .none, .{
        .name = name_si, .type_annotation = type_ann, .default_value = default_val, .flags = 1,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.field_def, ms.getNode(m).tag);
    const rec = mir_typed.FieldDef.unpack(&ms, m);
    try std.testing.expect(rec.default != .none);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(rec.default).tag);
    try std.testing.expectEqual(@as(u32, 1), rec.flags);
}

test "MirBuilder B8: param emits MirKind.param_def" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "n");
    const type_ann = try ast_typed.TypeNamed.pack(&as_, allocator, .none, .{ .name = name_si });
    const idx = try ast_typed.Param.pack(&as_, allocator, .none, .{
        .name = name_si, .type_annotation = type_ann, .default_value = .none,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.param_def, ms.getNode(m).tag);
    const rec = mir_typed.ParamDef.unpack(&ms, m);
    try std.testing.expectEqual(type_ann, rec.type_annotation);
    try std.testing.expectEqual(MirNodeIndex.none, rec.default);
    try std.testing.expectEqualStrings("n", ms.strings.get(rec.name));
}

test "MirBuilder B8: enum_variant emits MirKind.enum_variant_def no discriminant" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "Red");
    const idx = try ast_typed.EnumVariant.pack(&as_, allocator, .none, .{
        .name = name_si, .value = .none,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.enum_variant_def, ms.getNode(m).tag);
    const rec = mir_typed.EnumVariantDef.unpack(&ms, m);
    try std.testing.expectEqual(MirNodeIndex.none, rec.value);
    try std.testing.expectEqualStrings("Red", ms.strings.get(rec.name));
}

test "MirBuilder B8: enum_variant with discriminant lowers value" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "Green");
    const disc_si = try as_.strings.intern(allocator, "1");
    const disc = try ast_typed.IntLiteral.pack(&as_, allocator, .none, .{ .text = disc_si });
    const idx = try ast_typed.EnumVariant.pack(&as_, allocator, .none, .{
        .name = name_si, .value = disc,
    });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.enum_variant_def, ms.getNode(m).tag);
    const rec = mir_typed.EnumVariantDef.unpack(&ms, m);
    try std.testing.expect(rec.value != .none);
    try std.testing.expectEqual(MirKind.literal, ms.getNode(rec.value).tag);
}

test "MirBuilder B8: type_named emits MirKind.type_expr" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const name_si = try as_.strings.intern(allocator, "i32");
    const idx = try ast_typed.TypeNamed.pack(&as_, allocator, .none, .{ .name = name_si });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.type_expr, ms.getNode(m).tag);
    try std.testing.expectEqual(idx, ms.getNode(m).span);
}

test "MirBuilder B8: type_slice emits MirKind.type_expr" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    const elem_si = try as_.strings.intern(allocator, "u8");
    const elem = try ast_typed.TypeNamed.pack(&as_, allocator, .none, .{ .name = elem_si });
    const idx = try ast_typed.TypeSlice.pack(&as_, allocator, .none, .{ .elem = elem });
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.lowerNode(idx);
    try std.testing.expectEqual(MirKind.type_expr, ms.getNode(m).tag);
    try std.testing.expectEqual(idx, ms.getNode(m).span);
}

test "MirBuilder B8: createTempVar produces MirKind.temp_var" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const m = try b.createTempVar("_orhon_interp_0");
    try std.testing.expectEqual(MirKind.temp_var, ms.getNode(m).tag);
    const rec = mir_typed.TempVar.unpack(&ms, m);
    try std.testing.expectEqualStrings("_orhon_interp_0", ms.strings.get(rec.name));
}

test "MirBuilder B8: createInjectedDefer produces MirKind.injected_defer" {
    const allocator = std.testing.allocator;
    var ms = MirStore.init(); defer ms.deinit(allocator);
    var as_ = AstStore.init(); defer as_.deinit(allocator);
    var tm: std.AutoHashMapUnmanaged(AstNodeIndex, RT) = .{}; defer tm.deinit(allocator);
    var ur = UnionRegistry.init(allocator); defer ur.deinit();
    var b = testBuilder(allocator, &as_, &ms, &tm, &ur); defer b.deinit();
    const body = try ast_typed.BreakStmt.pack(&as_, allocator, .none, .{});
    const body_mir = try b.lowerNode(body);
    const m = try b.createInjectedDefer(body_mir);
    try std.testing.expectEqual(MirKind.injected_defer, ms.getNode(m).tag);
    const rec = mir_typed.InjectedDefer.unpack(&ms, m);
    try std.testing.expectEqual(body_mir, rec.body);
}
