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

    // Pack a leaf node that falls through to passthrough.
    const null_idx = try ast_typed.NullLiteral.pack(&ast_store, allocator, .none, .{});

    var builder = testBuilder(allocator, &ast_store, &mir_store, &type_map, &union_registry);
    defer builder.deinit();

    const mir_idx = try builder.build(null_idx);
    try std.testing.expect(mir_idx != .none);
    try std.testing.expectEqual(MirKind.passthrough, mir_store.getNode(mir_idx).tag);
    try std.testing.expectEqual(null_idx, mir_store.getNode(mir_idx).span);
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
