// codegen_decls.zig — MIR-path declaration generators for the Orhon code generator
// Contains: struct, enum, var/const/compt, test, and func declaration codegen (MIR path).
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const RT = @import("../types.zig").ResolvedType;
const mir_store_mod = @import("../mir_store.zig");
const mir_typed = @import("../mir_typed.zig");
const ast_store_mod = @import("../ast_store.zig");

const CodeGen = codegen.CodeGen;
const MirNodeIndex = mir_store_mod.MirNodeIndex;
const MirStore = mir_store_mod.MirStore;
const AstNodeIndex = ast_store_mod.AstNodeIndex;

// ============================================================
// FUNCTIONS
// ============================================================

/// Emit a re-export for a zig-backed module declaration from the named zig module.
/// Zig source files are registered as named Zig modules with a `_zig` suffix in the build graph.
pub fn generateZigReExport(cg: *CodeGen, name: []const u8, is_pub: bool) anyerror!void {
    const vis = if (is_pub) "pub " else "";
    try cg.emitLineFmt("{s}const {s} = @import(\"{s}_zig\").{s};", .{ vis, name, cg.module_name, name });
}

/// MIR-path function codegen — reads from MirStore when available, falls back to old MirNode.
pub fn generateFuncMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        // Only use MirStore path for valid real MirStore indices.
        // Synth indices (0x80000001+) are assigned by populateOldMirMap for old MirNodes
        // that have no MirStore entry — fall back to old path for these.
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateFuncMirFromStore(cg, store, idx);
        }
    }
    return generateFuncMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateFuncMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const func_name = m.name orelse return;

    // zig-backed module — re-export from zig source module
    if (try cg.reExportIfZigModule(func_name, m.is_pub)) return;

    // Body-less declaration — re-export from sidecar if mixed module, else skip.
    // Never skip main or void functions (they can legitimately have empty bodies).
    if (m.children.len == 0) {
        if (try cg.reExportIfSidecar(func_name, m.is_pub)) return;
        return;
    }
    const body_m = m.body();
    const is_void_ret = if (m.return_type) |rt| rt.* == .type_named and
        std.mem.eql(u8, rt.type_named, K.Type.VOID) else false;
    if (body_m.kind == .block and body_m.children.len == 0 and
        !std.mem.eql(u8, func_name, "main"))
    {
        if (!is_void_ret) {
            // Non-void body-less func — re-export from sidecar if mixed module, else skip.
            if (try cg.reExportIfSidecar(func_name, m.is_pub)) return;
            return;
        }
        // Void empty body with params = sidecar function; without params = legit empty (e.g., showCursor).
        if (m.params().len > 0) {
            if (try cg.reExportIfSidecar(func_name, m.is_pub)) return;
        }
    }

    // Track current function for MIR return type queries
    const prev_func_mir = cg.current_func_mir;
    cg.current_func_mir = m;
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMir(m.body(), &cg.reassigned_vars, cg.allocator);
    const prev_error_narrowed = cg.error_narrowed;
    cg.error_narrowed = .{};
    const prev_null_narrowed = cg.null_narrowed;
    cg.null_narrowed = .{};
    defer {
        cg.current_func_mir = prev_func_mir;
        cg.reassigned_vars.deinit(cg.allocator);
        cg.reassigned_vars = prev_reassigned_vars;
        cg.error_narrowed.deinit(cg.allocator);
        cg.error_narrowed = prev_error_narrowed;
        cg.null_narrowed.deinit(cg.allocator);
        cg.null_narrowed = prev_null_narrowed;
    }

    const ret_type = m.return_type orelse return;

    // pub modifier
    if (m.is_pub or std.mem.eql(u8, func_name, "main")) try cg.emit("pub ");

    const returns_type = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
    const is_type_generic = m.is_compt and returns_type;

    try cg.emitFmt("fn {s}(", .{func_name});

    // Parameters
    var first_any_param: ?[]const u8 = null;
    for (m.params(), 0..) |param_m, i| {
        if (i > 0) try cg.emit(", ");
        const pname = param_m.name orelse continue;
        const pta = param_m.type_annotation orelse continue;
        const is_any = pta.* == .type_named and
            std.mem.eql(u8, pta.type_named, K.Type.ANY);
        const is_type_param = pta.* == .type_named and
            std.mem.eql(u8, pta.type_named, K.Type.TYPE);
        if (is_any and first_any_param == null) first_any_param = pname;
        if (is_type_param) {
            try cg.emitFmt("comptime {s}: type", .{pname});
        } else if (is_type_generic and is_any) {
            try cg.emitFmt("comptime {s}: anytype", .{pname});
        } else if (m.is_compt and is_any) {
            try cg.emitFmt("comptime {s}: anytype", .{pname});
        } else if (is_any) {
            try cg.emitFmt("{s}: anytype", .{pname});
        } else if (m.is_compt and !is_type_generic) {
            const zig_type = try cg.typeToZig(pta);
            try cg.emitFmt("comptime {s}: {s}", .{ pname, zig_type });
        } else {
            const zig_type = try cg.typeToZig(pta);
            try cg.emitFmt("{s}: {s}", .{ pname, zig_type });
        }
    }

    try cg.emit(") ");

    // Return type
    const return_is_any = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.ANY);
    if (return_is_any) {
        if (first_any_param) |pname| {
            try cg.emitFmt("@TypeOf({s})", .{pname});
        } else {
            try cg.emit("anyopaque");
        }
    } else {
        try cg.emit(try cg.typeToZig(ret_type));
    }
    try cg.emit(" ");

    // Body
    try cg.generateBlockMir(cg.mirIdx(body_m));
    try cg.emit("\n");
}

/// MirStore path — reads all data from MirStore typed accessors.
fn generateFuncMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.Func.unpack(store, idx);
    const func_name = store.strings.get(rec.name);

    const is_pub = (rec.flags & 1) != 0;
    const is_compt = (rec.flags & 2) != 0;

    // zig-backed module — re-export from zig source module
    if (try cg.reExportIfZigModule(func_name, is_pub)) return;

    // Body-less declaration — re-export from sidecar if mixed module, else skip.
    // Never skip main or void functions (they can legitimately have empty bodies).
    const body_stmts = mir_typed.Block.getStmts(store, rec.body);
    if (body_stmts.len == 0) {
        const ret_node = cg.getAstNode(rec.return_type);
        const is_void_ret = if (ret_node) |rt| rt.* == .type_named and
            std.mem.eql(u8, rt.type_named, K.Type.VOID) else false;
        if (!std.mem.eql(u8, func_name, "main")) {
            if (!is_void_ret) {
                if (try cg.reExportIfSidecar(func_name, is_pub)) return;
                return;
            }
            // Void empty body with params = sidecar function; without params = legit empty.
            // Bridge via getOldMirNode for correct param count — params_start/params_end
            // in MirStore extra_data interleave ParamDefExtra words with MirNodeIndex values.
            // TODO Task 5: use a clean MirStore param count.
            if (cg.getOldMirNode(idx)) |func_m_for_check| {
                if (func_m_for_check.params().len > 0) {
                    if (try cg.reExportIfSidecar(func_name, is_pub)) return;
                }
            }
        }
    }

    // Track current function for MIR return type queries.
    // NOTE: The outer caller (generateTopLevelMir) already sets current_func_mir
    // before calling us. The inner save/restore is kept for the struct-method case,
    // where emitStructBodyFromStore sets current_func_mir via getOldMirNode.
    // TODO Task 5: replace with current_func_idx.
    const prev_func_mir = cg.current_func_mir;
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    // collectAssignedMir still needs old *MirNode — TODO Task 5: replace with MirStore walk.
    if (cg.getOldMirNode(rec.body)) |body_m| {
        try collectAssignedMir(body_m, &cg.reassigned_vars, cg.allocator);
    }
    const prev_error_narrowed = cg.error_narrowed;
    cg.error_narrowed = .{};
    const prev_null_narrowed = cg.null_narrowed;
    cg.null_narrowed = .{};
    defer {
        cg.current_func_mir = prev_func_mir;
        cg.reassigned_vars.deinit(cg.allocator);
        cg.reassigned_vars = prev_reassigned_vars;
        cg.error_narrowed.deinit(cg.allocator);
        cg.error_narrowed = prev_error_narrowed;
        cg.null_narrowed.deinit(cg.allocator);
        cg.null_narrowed = prev_null_narrowed;
    }

    const ret_type = cg.getAstNode(rec.return_type) orelse return;

    // pub modifier
    if (is_pub or std.mem.eql(u8, func_name, "main")) try cg.emit("pub ");

    const returns_type = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
    const is_type_generic = is_compt and returns_type;

    try cg.emitFmt("fn {s}(", .{func_name});

    // Parameters — use old MirNode params() for correct traversal.
    // The params_start..params_end range in MirStore extra_data interleaves
    // ParamDefExtra words with param MirNodeIndex values; stride is not uniform
    // when params have default values. Bridge via getOldMirNode for safety.
    // TODO Task 5: replace with a clean MirStore param iteration.
    var first_any_param: ?[]const u8 = null;
    const func_m_opt = cg.getOldMirNode(idx);
    if (func_m_opt) |func_m| {
        for (func_m.params(), 0..) |param_m, i| {
            if (i > 0) try cg.emit(", ");
            const pname = param_m.name orelse continue;
            const pta = param_m.type_annotation orelse continue;
            const is_any = pta.* == .type_named and
                std.mem.eql(u8, pta.type_named, K.Type.ANY);
            const is_type_param = pta.* == .type_named and
                std.mem.eql(u8, pta.type_named, K.Type.TYPE);
            if (is_any and first_any_param == null) first_any_param = pname;
            if (is_type_param) {
                try cg.emitFmt("comptime {s}: type", .{pname});
            } else if (is_type_generic and is_any) {
                try cg.emitFmt("comptime {s}: anytype", .{pname});
            } else if (is_compt and is_any) {
                try cg.emitFmt("comptime {s}: anytype", .{pname});
            } else if (is_any) {
                try cg.emitFmt("{s}: anytype", .{pname});
            } else if (is_compt and !is_type_generic) {
                const zig_type = try cg.typeToZig(pta);
                try cg.emitFmt("comptime {s}: {s}", .{ pname, zig_type });
            } else {
                const zig_type = try cg.typeToZig(pta);
                try cg.emitFmt("{s}: {s}", .{ pname, zig_type });
            }
        }
    }

    try cg.emit(") ");

    // Return type
    const return_is_any = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.ANY);
    if (return_is_any) {
        if (first_any_param) |pname| {
            try cg.emitFmt("@TypeOf({s})", .{pname});
        } else {
            try cg.emit("anyopaque");
        }
    } else {
        try cg.emit(try cg.typeToZig(ret_type));
    }
    try cg.emit(" ");

    // Body
    try cg.generateBlockMir(rec.body);
    try cg.emit("\n");
}

/// MIR-path collectAssigned — traverses MirNode tree.
pub fn collectAssignedMir(m: *mir.MirNode, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void {
    switch (m.kind) {
        .assignment => {
            if (getRootIdentMir(m.lhs())) |name| try set.put(alloc, name, {});
            try collectAssignedMir(m.rhs(), set, alloc);
        },
        .call => {
            const callee_m = m.getCallee();
            if (callee_m.kind == .field_access) {
                if (callee_m.children.len > 0) {
                    if (getRootIdentMir(callee_m.children[0])) |name| {
                        try set.put(alloc, name, {});
                    }
                }
            }
            for (m.callArgs()) |arg| try collectAssignedMir(arg, set, alloc);
        },
        .block => {
            for (m.children) |child| try collectAssignedMir(child, set, alloc);
        },
        .func => {}, // nested function — own scope
        .if_stmt => {
            try collectAssignedMir(m.condition(), set, alloc);
            if (m.children.len > 1) try collectAssignedMir(m.thenBlock(), set, alloc);
            if (m.elseBlock()) |e| try collectAssignedMir(e, set, alloc);
        },
        .while_stmt => {
            try collectAssignedMir(m.condition(), set, alloc);
            try collectAssignedMir(m.children[1], set, alloc);
            if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
        },
        .for_stmt => try collectAssignedMir(m.body(), set, alloc),
        .slice => {
            if (m.children.len > 0 and m.children[0].kind == .identifier) {
                if (m.children[0].name) |name| try set.put(alloc, name, {});
            }
            if (m.children.len > 1) try collectAssignedMir(m.children[1], set, alloc);
            if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
        },
        .var_decl => {
            if (m.children.len > 0) try collectAssignedMir(m.value(), set, alloc);
        },
        .match_stmt => {
            for (m.matchArms()) |arm_mir| {
                try collectAssignedMir(arm_mir.body(), set, alloc);
            }
        },
        .defer_stmt => try collectAssignedMir(m.body(), set, alloc),
        else => {
            for (m.children) |child| try collectAssignedMir(child, set, alloc);
        },
    }
}

pub fn getRootIdentMir(m: *const mir.MirNode) ?[]const u8 {
    return switch (m.kind) {
        .identifier => m.name,
        .field_access => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
        .index => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
        else => null,
    };
}

// ============================================================
// STRUCTS
// ============================================================

/// MIR-path struct codegen — reads from MirStore when available, falls back to old MirNode.
pub fn generateStructMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateStructMirFromStore(cg, store, idx);
        }
    }
    return generateStructMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateStructMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const struct_name = m.name orelse return;
    if (try cg.reExportIfZigModule(struct_name, m.is_pub)) return;

    // Mixed module with sidecar — structs with only body-less methods come from the .zig
    // sidecar and should be re-exported rather than generated as empty Zig structs.
    if (cg.has_zig_sidecar and isSidecarStructOld(m)) {
        if (try cg.reExportIfSidecar(struct_name, m.is_pub)) return;
    }

    const tp = m.type_params;
    const is_generic = tp != null and tp.?.len > 0;

    const prev_in_struct = cg.in_struct;
    cg.in_struct = true;
    defer cg.in_struct = prev_in_struct;

    if (is_generic) {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("fn {s}(", .{struct_name});
        for (tp.?, 0..) |param, i| {
            if (i > 0) try cg.emit(", ");
            if (param.* == .param) {
                try cg.emitFmt("comptime {s}: type", .{param.param.name});
            }
        }
        try cg.emit(") type {\n");
        cg.indent += 1;
        try cg.emitIndent();
        try cg.emit("return struct {\n");
        cg.indent += 1;
        cg.generic_struct_name = struct_name;
    } else {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = struct {{\n", .{struct_name});
        cg.indent += 1;
    }

    try emitStructBody(cg, m.children);

    if (is_generic) {
        cg.generic_struct_name = null;
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("};\n");
        cg.indent -= 1;
        try cg.emit("}\n");
    } else {
        cg.indent -= 1;
        try cg.emit("};\n");
    }
}

/// MirStore path — reads name/flags/type_params from MirStore; members from old MirNode.
fn generateStructMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.StructDef.unpack(store, idx);
    const struct_name = store.strings.get(rec.name);
    const is_pub = (rec.flags & 1) != 0;

    if (try cg.reExportIfZigModule(struct_name, is_pub)) return;

    // Mixed module with sidecar — use old MirNode children for sidecar check.
    // members_start..members_end in extra_data interleaves member extra-data with
    // MirNodeIndex values and is not a flat index list.
    // TODO Task 5: use a clean MirStore member iteration.
    const m_opt = cg.getOldMirNode(idx);
    if (cg.has_zig_sidecar) {
        if (m_opt) |m| {
            if (isSidecarStructOld(m)) {
                if (try cg.reExportIfSidecar(struct_name, is_pub)) return;
            }
        }
    }

    // type_params: safe to read from MirStore — they are AstNodeIndex values
    // copied raw from AST extra_data (no nested lowering).
    const tp_extras = store.extra_data.items[rec.type_params_start..rec.type_params_end];
    const is_generic = tp_extras.len > 0;

    const prev_in_struct = cg.in_struct;
    cg.in_struct = true;
    defer cg.in_struct = prev_in_struct;

    if (is_generic) {
        if (is_pub) try cg.emit("pub ");
        try cg.emitFmt("fn {s}(", .{struct_name});
        for (tp_extras, 0..) |tp_u32, i| {
            if (i > 0) try cg.emit(", ");
            // type_params entries are AstNodeIndex values (copied raw from AST extra_data)
            const tp_ast_idx: AstNodeIndex = @enumFromInt(tp_u32);
            const tp_node = cg.getAstNode(tp_ast_idx) orelse continue;
            if (tp_node.* == .param) {
                try cg.emitFmt("comptime {s}: type", .{tp_node.param.name});
            }
        }
        try cg.emit(") type {\n");
        cg.indent += 1;
        try cg.emitIndent();
        try cg.emit("return struct {\n");
        cg.indent += 1;
        cg.generic_struct_name = struct_name;
    } else {
        if (is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = struct {{\n", .{struct_name});
        cg.indent += 1;
    }

    // Use old MirNode children for member emission — members_start..members_end
    // is not a flat MirNodeIndex list due to extra_data interleaving.
    // TODO Task 5: use emitStructBodyFromStore when extra_data layout is clean.
    if (m_opt) |m| {
        try emitStructBody(cg, m.children);
    }

    if (is_generic) {
        cg.generic_struct_name = null;
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("};\n");
        cg.indent -= 1;
        try cg.emit("}\n");
    } else {
        cg.indent -= 1;
        try cg.emit("};\n");
    }
}

/// Emit the body of a struct (fields, methods, constants) from MIR children.
/// Used by both named structs and anonymous struct expressions.
/// NOTE: Signature unchanged — called from codegen_exprs.zig (Task 4).
pub fn emitStructBody(cg: *CodeGen, children: []*mir.MirNode) anyerror!void {
    for (children) |child| {
        switch (child.kind) {
            .field_def => {
                const fname = child.name orelse continue;
                try cg.emitIndent();
                try cg.emitFmt("{s}: {s}", .{ fname, try cg.typeToZig(child.type_annotation orelse continue) });
                if (child.defaultChild()) |dv_mir| {
                    try cg.emit(" = ");
                    try cg.generateExprMir(cg.mirIdx(dv_mir));
                }
                try cg.emit(",\n");
            },
            .func => {
                const prev = cg.current_func_mir;
                cg.current_func_mir = child;
                defer cg.current_func_mir = prev;
                try cg.generateFuncMir(cg.mirIdx(child));
            },
            .var_decl => {
                const decl_kw: []const u8 = if (child.is_const) "const" else "var";
                const cname = child.name orelse continue;
                try cg.emitIndent();
                try cg.emitFmt("{s} {s}", .{ decl_kw, cname });
                if (child.type_annotation) |t| try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
                try cg.emit(" = ");
                try cg.generateExprMir(cg.mirIdx(child.value()));
                try cg.emit(";\n");
            },
            else => {},
        }
    }
}

/// Private helper — emit struct body from MirStore extra_data slice.
/// Used by generateStructMirFromStore (new MirStore path).
fn emitStructBodyFromStore(cg: *CodeGen, store: *const MirStore, member_extras: []const u32) anyerror!void {
    for (member_extras) |mu32| {
        const child_idx: MirNodeIndex = @enumFromInt(mu32);
        const child_tag = store.getNode(child_idx).tag;
        switch (child_tag) {
            .field_def => {
                const f_rec = mir_typed.FieldDef.unpack(store, child_idx);
                const fname = store.strings.get(f_rec.name);
                const ftype = cg.getAstNode(f_rec.type_annotation) orelse continue;
                try cg.emitIndent();
                try cg.emitFmt("{s}: {s}", .{ fname, try cg.typeToZig(ftype) });
                if (f_rec.default != .none) {
                    try cg.emit(" = ");
                    try cg.generateExprMir(f_rec.default);
                }
                try cg.emit(",\n");
            },
            .func => {
                const prev = cg.current_func_mir;
                // current_func_mir still expects old *mir.MirNode; bridge via getOldMirNode.
                // If getOldMirNode returns null (no old-tree entry), current_func_mir retains
                // the outer struct's value — stale but non-crashing for this migration phase.
                // TODO Task 5: replace with current_func_idx field.
                if (cg.getOldMirNode(child_idx)) |old_m| cg.current_func_mir = old_m;
                defer cg.current_func_mir = prev;
                try cg.generateFuncMir(child_idx);
            },
            .var_decl => {
                const v_rec = mir_typed.VarDecl.unpack(store, child_idx);
                const is_const = (v_rec.flags & 2) != 0;
                const decl_kw: []const u8 = if (is_const) "const" else "var";
                const cname = store.strings.get(v_rec.name);
                try cg.emitIndent();
                try cg.emitFmt("{s} {s}", .{ decl_kw, cname });
                if (v_rec.type_annotation != .none) {
                    if (cg.getAstNode(v_rec.type_annotation)) |t| {
                        try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
                    }
                }
                try cg.emit(" = ");
                try cg.generateExprMir(v_rec.value);
                try cg.emit(";\n");
            },
            else => {},
        }
    }
}

// ============================================================
// ENUMS
// ============================================================

/// MIR-path enum codegen — reads from MirStore when available, falls back to old MirNode.
pub fn generateEnumMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateEnumMirFromStore(cg, store, idx);
        }
    }
    return generateEnumMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateEnumMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const enum_name = m.name orelse return;
    if (m.is_pub) try cg.emit("pub ");

    const backing = try cg.typeToZig(m.backing_type orelse return);

    try cg.emitFmt("const {s} = enum({s}) {{\n", .{ enum_name, backing });
    cg.indent += 1;

    for (m.children) |child| {
        switch (child.kind) {
            .enum_variant_def => {
                const vname = child.name orelse continue;
                try cg.emitIndent();
                if (child.literal) |lit| {
                    try cg.emitFmt("{s} = {s},\n", .{ vname, lit });
                } else {
                    try cg.emitFmt("{s},\n", .{vname});
                }
            },
            else => {},
        }
    }

    cg.indent -= 1;
    try cg.emit("};\n");
}

/// MirStore path — reads name/flags/backing_type from MirStore; members from old MirNode.
fn generateEnumMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.EnumDef.unpack(store, idx);
    const enum_name = store.strings.get(rec.name);
    const is_pub = (rec.flags & 1) != 0;
    if (is_pub) try cg.emit("pub ");

    const backing_node = cg.getAstNode(rec.backing_type) orelse return;
    const backing = try cg.typeToZig(backing_node);

    try cg.emitFmt("const {s} = enum({s}) {{\n", .{ enum_name, backing });
    cg.indent += 1;

    // Use old MirNode children for variant emission — members_start..members_end
    // in MirStore extra_data interleaves variant extra-data with MirNodeIndex values
    // when variants have explicit discriminant values (Literal.pack appends to extra_data).
    // TODO Task 5: use a clean MirStore member iteration.
    if (cg.getOldMirNode(idx)) |m| {
        for (m.children) |child| {
            switch (child.kind) {
                .enum_variant_def => {
                    const vname = child.name orelse continue;
                    try cg.emitIndent();
                    if (child.literal) |lit| {
                        try cg.emitFmt("{s} = {s},\n", .{ vname, lit });
                    } else {
                        try cg.emitFmt("{s},\n", .{vname});
                    }
                },
                else => {},
            }
        }
    }

    cg.indent -= 1;
    try cg.emit("};\n");
}

// ============================================================
// HANDLES
// ============================================================

/// MIR-path handle codegen — emits `const Name = *anyopaque;`
pub fn generateHandleMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateHandleMirFromStore(cg, store, idx);
        }
    }
    return generateHandleMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateHandleMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const handle_name = m.name orelse return;
    if (try cg.reExportIfZigModule(handle_name, m.is_pub)) return;

    if (m.is_pub) try cg.emit("pub ");
    try cg.emitFmt("const {s} = *anyopaque;\n", .{handle_name});
}

/// MirStore path — reads all data from MirStore typed accessors.
fn generateHandleMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.HandleDef.unpack(store, idx);
    const handle_name = store.strings.get(rec.name);
    const is_pub = (rec.flags & 1) != 0;
    if (try cg.reExportIfZigModule(handle_name, is_pub)) return;

    if (is_pub) try cg.emit("pub ");
    try cg.emitFmt("const {s} = *anyopaque;\n", .{handle_name});
}

// ============================================================
// VARIABLE DECLARATIONS
// ============================================================

/// Returns true if the type annotation is the `type` keyword — indicating a type alias declaration.
pub fn isTypeAlias(type_annotation: ?*parser.Node) bool {
    const ta = type_annotation orelse return false;
    return ta.* == .type_named and std.mem.eql(u8, ta.type_named, K.Type.TYPE);
}

/// MIR-path top-level var/const/compt declaration.
pub fn generateTopLevelDeclMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateTopLevelDeclMirFromStore(cg, store, idx);
        }
    }
    return generateTopLevelDeclMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateTopLevelDeclMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const name = m.name orelse return;
    if (try cg.reExportIfZigModule(name, m.is_pub)) return;

    // Type alias: const Name: type = T → const Name = ZigType;
    if (m.is_const and isTypeAlias(m.type_annotation)) {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = ", .{name});
        try cg.emit(try cg.typeToZig(m.value().ast)); // type trees are structural — typeToZig walks AST
        try cg.emit(";\n");
        return;
    }

    const decl_keyword: []const u8 = if (m.is_const) "const" else "var";
    if (m.is_pub) try cg.emit("pub ");
    try cg.emitFmt("{s} {s}", .{ decl_keyword, name });
    if (m.type_annotation) |t| {
        try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
    }
    try cg.emit(" = ");
    if (m.type_class == .arbitrary_union) {
        try cg.generateCoercedExprMir(cg.mirIdx(m.value()));
    } else if (m.value().kind == .type_expr) {
        // Type in expression position = default constructor (.{})
        try cg.emit(".{}");
    } else {
        // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
        try cg.generateExprMir(cg.mirIdx(m.value()));
    }
    try cg.emit(";\n");
}

/// MirStore path — reads all data from MirStore typed accessors.
fn generateTopLevelDeclMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.VarDecl.unpack(store, idx);
    const name = store.strings.get(rec.name);
    const is_pub = (rec.flags & 1) != 0;
    const is_const = (rec.flags & 2) != 0;
    if (try cg.reExportIfZigModule(name, is_pub)) return;

    const type_annotation = if (rec.type_annotation != .none)
        cg.getAstNode(rec.type_annotation)
    else
        null;

    // Type alias: const Name: type = T → const Name = ZigType;
    if (is_const and isTypeAlias(type_annotation)) {
        if (is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = ", .{name});
        // type_expr span points to the AST node for the RHS type expression
        const value_span = store.getNode(rec.value).span;
        const value_ast = cg.getAstNode(value_span) orelse return;
        try cg.emit(try cg.typeToZig(value_ast));
        try cg.emit(";\n");
        return;
    }

    const decl_keyword: []const u8 = if (is_const) "const" else "var";
    if (is_pub) try cg.emit("pub ");
    try cg.emitFmt("{s} {s}", .{ decl_keyword, name });
    if (type_annotation) |t| {
        try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
    }
    try cg.emit(" = ");

    const entry = store.getNode(idx);
    if (entry.type_class == .arbitrary_union) {
        try cg.generateCoercedExprMir(rec.value);
    } else if (store.getNode(rec.value).tag == .type_expr) {
        // Type in expression position = default constructor (.{})
        try cg.emit(".{}");
    } else {
        // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
        try cg.generateExprMir(rec.value);
    }
    try cg.emit(";\n");
}

// ============================================================
// TESTS
// ============================================================

pub fn generateTestMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store) |store| {
        const raw: u32 = @intFromEnum(idx);
        if (raw > 0 and raw < store.nodes.len) {
            return generateTestMirFromStore(cg, store, idx);
        }
    }
    return generateTestMirOld(cg, idx);
}

/// Old MirNode path — kept as fallback for tests/pipelines without MirStore.
fn generateTestMirOld(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    const description = m.name orelse return;
    try cg.emitFmt("test {s} ", .{description});
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMir(m.body(), &cg.reassigned_vars, cg.allocator);
    cg.in_test_block = true;
    try cg.generateBlockMir(cg.mirIdx(m.body()));
    cg.in_test_block = false;
    cg.reassigned_vars.deinit(cg.allocator);
    cg.reassigned_vars = prev_reassigned_vars;
    try cg.emit("\n");
}

/// MirStore path — reads all data from MirStore typed accessors.
fn generateTestMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.TestDef.unpack(store, idx);
    const description = store.strings.get(rec.description);
    try cg.emitFmt("test {s} ", .{description});
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    // collectAssignedMir still needs old *MirNode — TODO Task 5: replace with MirStore walk.
    if (cg.getOldMirNode(rec.body)) |body_m| {
        try collectAssignedMir(body_m, &cg.reassigned_vars, cg.allocator);
    }
    cg.in_test_block = true;
    try cg.generateBlockMir(rec.body);
    cg.in_test_block = false;
    cg.reassigned_vars.deinit(cg.allocator);
    cg.reassigned_vars = prev_reassigned_vars;
    try cg.emit("\n");
}

// ============================================================
// HELPERS
// ============================================================

/// Check if a struct MIR node is from a .zig sidecar — all its methods are body-less.
/// Old MirNode version — used by the old codegen path.
fn isSidecarStructOld(m: *mir.MirNode) bool {
    if (m.children.len == 0) return true;
    for (m.children) |child| {
        if (child.kind == .func) {
            const body_m = child.body();
            if (body_m.kind == .block and body_m.children.len > 0) return false;
        }
    }
    return true;
}

