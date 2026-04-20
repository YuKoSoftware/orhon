// codegen_decls.zig — MIR-path declaration generators for the Orhon code generator
// Contains: struct, enum, var/const/compt, test, and func declaration codegen (MIR path).
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const types = @import("../types.zig");
const RT = types.ResolvedType;
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

/// MIR-path function codegen — reads from MirStore.
pub fn generateFuncMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    return generateFuncMirFromStore(cg, store, idx);
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
            types.Primitive.fromName(rt.type_named) == .void else false;
        if (!std.mem.eql(u8, func_name, "main")) {
            if (!is_void_ret) {
                if (try cg.reExportIfSidecar(func_name, is_pub)) return;
                return;
            }
            // Void empty body with params = sidecar function; without params = legit empty.
            if (rec.params_end > rec.params_start) {
                if (try cg.reExportIfSidecar(func_name, is_pub)) return;
            }
        }
    }

    // Track current function for MIR return type queries.
    const prev_func_idx = cg.current_func_idx;
    cg.current_func_idx = idx;
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMirFromStore(store, rec.body, &cg.reassigned_vars, cg.allocator);
    const prev_error_narrowed = cg.error_narrowed;
    cg.error_narrowed = .{};
    const prev_null_narrowed = cg.null_narrowed;
    cg.null_narrowed = .{};
    defer {
        cg.current_func_idx = prev_func_idx;
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
        types.Primitive.fromName(ret_type.type_named) == .@"type";
    const is_type_generic = is_compt and returns_type;

    try cg.emitFmt("fn {s}(", .{func_name});

    // Parameters — MirStore path: flat MirNodeIndex list in extra_data.
    var first_any_param: ?[]const u8 = null;
    const params_extra = store.extra_data.items[rec.params_start..rec.params_end];
    var emitted: usize = 0;
    for (params_extra) |pu32| {
        const param_idx: MirNodeIndex = @enumFromInt(pu32);
        const p = mir_typed.ParamDef.unpack(store, param_idx);
        const pname = store.strings.get(p.name);
        const pta = cg.getAstNode(p.type_annotation) orelse continue;
        if (emitted > 0) try cg.emit(", ");
        emitted += 1;
        const is_any = pta.* == .type_named and
            types.Primitive.fromName(pta.type_named) == .any;
        const is_type_param = pta.* == .type_named and
            types.Primitive.fromName(pta.type_named) == .@"type";
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

    try cg.emit(") ");

    // Return type
    const return_is_any = ret_type.* == .type_named and
        types.Primitive.fromName(ret_type.type_named) == .any;
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

fn getRootIdentMirFromStore(store: *const MirStore, idx: MirNodeIndex) ?[]const u8 {
    if (idx == .none) return null;
    const raw: u32 = @intFromEnum(idx);
    if (raw >= store.nodes.len) return null;
    const entry = store.getNode(idx);
    return switch (entry.tag) {
        .identifier => store.strings.get(mir_typed.Identifier.unpack(store, idx).name),
        .field_access => getRootIdentMirFromStore(store, mir_typed.FieldAccess.unpack(store, idx).object),
        .index => getRootIdentMirFromStore(store, mir_typed.Index.unpack(store, idx).object),
        .slice => getRootIdentMirFromStore(store, mir_typed.Slice.unpack(store, idx).object),
        else => null,
    };
}

fn collectAssignedMirFromStore(store: *const MirStore, idx: MirNodeIndex, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void {
    if (idx == .none) return;
    const raw: u32 = @intFromEnum(idx);
    if (raw >= store.nodes.len) return;
    const entry = store.getNode(idx);
    switch (entry.tag) {
        .assignment => {
            const rec = mir_typed.Assignment.unpack(store, idx);
            if (getRootIdentMirFromStore(store, rec.lhs)) |name| try set.put(alloc, name, {});
            try collectAssignedMirFromStore(store, rec.rhs, set, alloc);
        },
        .call => {
            const rec = mir_typed.Call.unpack(store, idx);
            const callee_entry = store.getNode(rec.callee);
            if (callee_entry.tag == .field_access) {
                const fa_rec = mir_typed.FieldAccess.unpack(store, rec.callee);
                if (getRootIdentMirFromStore(store, fa_rec.object)) |name| {
                    try set.put(alloc, name, {});
                }
            }
            for (store.extra_data.items[rec.args_start..rec.args_end]) |u|
                try collectAssignedMirFromStore(store, @enumFromInt(u), set, alloc);
        },
        .block => {
            for (mir_typed.Block.getStmts(store, idx)) |s|
                try collectAssignedMirFromStore(store, s, set, alloc);
        },
        .func => {}, // nested function — own scope
        .if_stmt => {
            const rec = mir_typed.IfStmt.unpack(store, idx);
            try collectAssignedMirFromStore(store, rec.condition, set, alloc);
            if (rec.then_block != .none) try collectAssignedMirFromStore(store, rec.then_block, set, alloc);
            if (rec.else_block != .none) try collectAssignedMirFromStore(store, rec.else_block, set, alloc);
        },
        .while_stmt => {
            const rec = mir_typed.WhileStmt.unpack(store, idx);
            try collectAssignedMirFromStore(store, rec.condition, set, alloc);
            try collectAssignedMirFromStore(store, rec.body, set, alloc);
            if (rec.continue_expr != .none) try collectAssignedMirFromStore(store, rec.continue_expr, set, alloc);
        },
        .slice => {
            const rec = mir_typed.Slice.unpack(store, idx);
            if (getRootIdentMirFromStore(store, rec.object)) |name| try set.put(alloc, name, {});
        },
        .for_stmt => {
            const rec = mir_typed.ForStmt.unpack(store, idx);
            try collectAssignedMirFromStore(store, rec.body, set, alloc);
        },
        .var_decl => {
            const rec = mir_typed.VarDecl.unpack(store, idx);
            if (rec.value != .none) try collectAssignedMirFromStore(store, rec.value, set, alloc);
        },
        .match_stmt => {
            const rec = mir_typed.MatchStmt.unpack(store, idx);
            for (store.extra_data.items[rec.arms_start..rec.arms_end]) |u| {
                const arm_idx: MirNodeIndex = @enumFromInt(u);
                const arm_rec = mir_typed.MatchArm.unpack(store, arm_idx);
                try collectAssignedMirFromStore(store, arm_rec.body, set, alloc);
            }
        },
        .defer_stmt => {
            const rec = mir_typed.DeferStmt.unpack(store, idx);
            try collectAssignedMirFromStore(store, rec.body, set, alloc);
        },
        else => {},
    }
}

// ============================================================
// STRUCTS
// ============================================================

/// MIR-path struct codegen — reads from MirStore.
pub fn generateStructMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    return generateStructMirFromStore(cg, store, idx);
}

/// MirStore path — reads name/flags/type_params from MirStore; members from old MirNode.
fn generateStructMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.StructDef.unpack(store, idx);
    const struct_name = store.strings.get(rec.name);
    const is_pub = (rec.flags & 1) != 0;

    if (try cg.reExportIfZigModule(struct_name, is_pub)) return;

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

    const members = store.extra_data.items[rec.members_start..rec.members_end];
    try emitStructBodyFromStore(cg, store, members);

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

/// Private helper — emit struct body from MirStore extra_data slice.
/// Used by generateStructMirFromStore (new MirStore path).
pub fn emitStructBodyFromStore(cg: *CodeGen, store: *const MirStore, member_extras: []const u32) anyerror!void {
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
                const prev_idx = cg.current_func_idx;
                cg.current_func_idx = child_idx;
                defer cg.current_func_idx = prev_idx;
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

/// MIR-path enum codegen — reads from MirStore.
pub fn generateEnumMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    return generateEnumMirFromStore(cg, store, idx);
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

    const members = store.extra_data.items[rec.members_start..rec.members_end];
    for (members) |mu32| {
        const variant_idx: MirNodeIndex = @enumFromInt(mu32);
        const vrec = mir_typed.EnumVariantDef.unpack(store, variant_idx);
        const vname = store.strings.get(vrec.name);
        try cg.emitIndent();
        if (vrec.value != .none) {
            try cg.emitFmt("{s} = ", .{vname});
            try cg.generateExprMir(vrec.value);
            try cg.emit(",\n");
        } else {
            try cg.emitFmt("{s},\n", .{vname});
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
    const store = cg.mir_store.?;
    return generateHandleMirFromStore(cg, store, idx);
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
    return ta.* == .type_named and types.Primitive.fromName(ta.type_named) == .@"type";
}

/// MIR-path top-level var/const/compt declaration.
pub fn generateTopLevelDeclMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    return generateTopLevelDeclMirFromStore(cg, store, idx);
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
    const store = cg.mir_store.?;
    return generateTestMirFromStore(cg, store, idx);
}

/// MirStore path — reads all data from MirStore typed accessors.
fn generateTestMirFromStore(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.TestDef.unpack(store, idx);
    const description = store.strings.get(rec.description);
    try cg.emitFmt("test {s} ", .{description});
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMirFromStore(store, rec.body, &cg.reassigned_vars, cg.allocator);
    cg.in_test_block = true;
    try cg.generateBlockMir(rec.body);
    cg.in_test_block = false;
    cg.reassigned_vars.deinit(cg.allocator);
    cg.reassigned_vars = prev_reassigned_vars;
    try cg.emit("\n");
}


