// codegen_stmts.zig — Block and statement generators for the Orhon code generator
// Contains: generateBlockMir, generateBodyStatements, generateStatementMir, generateStmtDeclMir.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const match_impl = @import("codegen_match.zig");
const mir_typed = @import("../mir_typed.zig");
const mir_store_mod = @import("../mir_store.zig");

const CodeGen = codegen.CodeGen;
const MirNodeIndex = mir_store_mod.MirNodeIndex;

/// Returns true if idx is a real MirStore entry (not a synthetic fallback index).
/// Synthetic indices start at 0x80000001 to avoid collision with real store indices.
fn isRealMirIdx(cg: *const CodeGen, idx: MirNodeIndex) bool {
    const store = cg.mir_store orelse return false;
    if (idx == .none) return false;
    const raw: u32 = @intFromEnum(idx);
    return raw < store.nodes.len;
}

/// Read IfNarrowing from MirStore when available, converting IfNarrowingExtra to mir.IfNarrowing.
/// String slices borrow from cg.mir_store.strings — valid during generate().
fn readNarrowingFromStore(cg: *const CodeGen, if_ast: *parser.Node) ?mir.IfNarrowing {
    const store = cg.mir_store orelse return null;
    const idx = cg.getMirIdxForParserNode(if_ast);
    if (idx == .none) return null;
    const raw: u32 = @intFromEnum(idx);
    if (raw >= store.nodes.len) return null;
    const entry = store.getNode(idx);
    if (entry.tag != .if_stmt) return null;
    const rec = mir_typed.IfStmt.unpack(store, idx);
    if (rec.narrowing_extra == .none) return null;
    const nr = store.extraData(mir_typed.IfNarrowingExtra, rec.narrowing_extra);
    const tc: mir.TypeClass = @enumFromInt(nr.type_class);
    return .{
        .var_name = store.strings.get(nr.var_name),
        .type_class = tc,
        .then_branch = if (nr.has_then != 0) .{
            .type_name = store.strings.get(nr.then_type_name),
            .positional_tag = if (nr.then_positional_tag == 0xFFFF_FFFF) null else @intCast(nr.then_positional_tag),
            .kind = @enumFromInt(nr.then_kind),
        } else null,
        .else_branch = if (nr.has_else != 0) .{
            .type_name = store.strings.get(nr.else_type_name),
            .positional_tag = if (nr.else_positional_tag == 0xFFFF_FFFF) null else @intCast(nr.else_positional_tag),
            .kind = @enumFromInt(nr.else_kind),
        } else null,
        .post_branch = if (nr.has_post != 0) .{
            .type_name = store.strings.get(nr.post_type_name),
            .positional_tag = if (nr.post_positional_tag == 0xFFFF_FFFF) null else @intCast(nr.post_positional_tag),
            .kind = @enumFromInt(nr.post_kind),
        } else null,
    };
}

// ============================================================
// BLOCKS AND STATEMENTS
// ============================================================

/// Emit a block with an arm-top narrowing binding.
/// Generates: `{ const _is_val = <unwrap>; <body> }` with match_var_subst active.
fn emitNarrowedBlock(cg: *CodeGen, block: *mir.MirNode, var_name: []const u8, narrow: mir.NarrowBranch, type_class: mir.TypeClass) anyerror!void {
    try cg.emit("{\n");
    cg.indent += 1;
    // Emit the arm-top binding
    try cg.emitIndent();
    try emitUnwrapBinding(cg, var_name, narrow, type_class);
    try cg.emit("\n");
    // Generate body with substitution active
    const prev = cg.match_var_subst;
    cg.match_var_subst = .{ .original = var_name, .capture = "_is_val" };
    for (block.children) |child| {
        try cg.flushPreStmts();
        try cg.emitIndent();
        try generateStatementMir(cg, cg.mirIdx(child));
        try cg.emit("\n");
    }
    cg.match_var_subst = prev;
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// Emit `const _is_val = <unwrap_expr>;` using the variable name as both binding and source.
fn emitUnwrapBinding(cg: *CodeGen, var_name: []const u8, narrow: mir.NarrowBranch, type_class: mir.TypeClass) anyerror!void {
    return emitUnwrapBindingNamed(cg, "_is_val", var_name, narrow, type_class);
}

/// Emit `const <bind_name> = <unwrap_expr>;` based on the union type_class and narrowed type.
fn emitUnwrapBindingNamed(cg: *CodeGen, bind_name: []const u8, source_name: []const u8, narrow: mir.NarrowBranch, type_class: mir.TypeClass) anyerror!void {
    const is_error = narrow.kind == .error_sentinel;
    const is_null = narrow.kind == .null_sentinel;

    if (is_null) {
        // Null narrowing — no useful value to bind
        try cg.emit("// null arm — no binding");
        return;
    }

    if (is_error) {
        // Error narrowing — extract the error name string
        switch (type_class) {
            .error_union => {
                try cg.emitFmt("const {s} = if ({s}) |_| unreachable else |e| @errorName(e);", .{ bind_name, source_name });
            },
            .null_error_union => {
                try cg.emitFmt("const {s} = if ({s}) |_oe| (if (_oe) |_| unreachable else |e| @errorName(e)) else unreachable;", .{ bind_name, source_name });
            },
            else => {
                try cg.emit("// unsupported error narrowing");
            },
        }
        return;
    }

    // Value narrowing — extract the unwrapped value
    if (codegen.valueUnwrapForm(type_class)) |form| {
        try cg.emitFmt("const {s} = {s}{s}{s};", .{ bind_name, form.prefix, source_name, form.suffix });
        return;
    }
    switch (type_class) {
        .arbitrary_union => {
            if (narrow.positional_tag) |tag| {
                try cg.emitFmt("const {s} = {s}._{d};", .{ bind_name, source_name, tag });
            } else {
                // Defensive fallback — lowerer should always stamp positional_tag
                // for arbitrary_union narrowing. Preserve the old behavior exactly:
                // emit `._<raw_type_name>` matching what the prior
                // arbitrary-union tag fallback produced.
                try cg.emitFmt("const {s} = {s}._{s};", .{ bind_name, source_name, narrow.type_name });
            }
        },
        else => {
            try cg.emit("// unsupported narrowing");
        },
    }
}

/// MIR-path block generation — walks MirNode children instead of AST statements.
/// NOTE: Uses old MirNode children to preserve injected temp_var/injected_defer nodes
/// (interpolation hoisting). MirStore Block.getStmts will be used in B10 when
/// the old MIR tree is removed and MirBuilder handles interpolation injection.
pub fn generateBlockMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    try cg.emit("{\n");
    cg.indent += 1;
    try emitStatementsWithNarrowing(cg, m.children);
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// Emit the body statements of a block node, already inside an outer `{`.
/// Caller must manage indentation and surrounding braces.
/// NOTE: Uses old MirNode children for the same reason as generateBlockMir.
pub fn generateBodyStatements(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const m = cg.getOldMirNode(idx) orelse return;
    try emitStatementsWithNarrowing(cg, m.children);
}

/// Emit a slice of statements, handling post-if narrowing at each step.
/// When narrowing fires, emits a binding and recursively processes remaining siblings.
fn emitStatementsWithNarrowing(cg: *CodeGen, stmts: []*mir.MirNode) anyerror!void {
    for (stmts, 0..) |child, idx| {
        try cg.flushPreStmts();
        try cg.emitIndent();
        // Injected nodes (temp_var, injected_defer) share AST pointers with their
        // interpolation expression counterpart, so mirIdx() would return the MirStore
        // index of the interpolation expr rather than the injected node.  Bypass the
        // MirStore dispatch and call the old-path implementation directly.
        if (child.kind == .temp_var or child.kind == .injected_defer) {
            try generateStatementMirImpl(cg, child);
        } else {
            try generateStatementMir(cg, cg.mirIdx(child));
        }
        try cg.emit("\n");
        // Post-if narrowing: if this if_stmt has early exit and post_branch,
        // emit a binding for the narrowed variable and substitute in remaining siblings.
        if (child.kind == .if_stmt) {
            if (readNarrowingFromStore(cg, child.ast) orelse child.narrowing) |narrowing| {
                if (narrowing.post_branch) |pb| {
                    const var_name = narrowing.var_name;
                    // Skip if variable is already fully unwrapped (.plain) from a prior narrowing
                    if (cg.match_var_subst) |subst| {
                        if (subst.eff_tc != null and subst.eff_tc.? == .plain and
                            std.mem.eql(u8, var_name, subst.original)) continue;
                    }
                    // Use the effective name (after any active substitution) for the unwrap source
                    const source_name = if (cg.match_var_subst) |subst|
                        (if (std.mem.eql(u8, var_name, subst.original)) subst.capture else var_name)
                    else
                        var_name;
                    // Check if any subsequent sibling references the variable
                    const remaining = stmts[idx + 1 ..];
                    var any_uses = false;
                    if (cg.mir_store) |_store| {
                        for (remaining) |sib| {
                            if (match_impl.mirContainsIdentifier(_store, cg.mirIdx(sib), var_name)) {
                                any_uses = true;
                                break;
                            }
                        }
                    } else {
                        // Old path: no MirStore, fall back to old MirNode recursive scan
                        for (remaining) |sib| {
                            if (match_impl.mirContainsIdentifierOld(sib, var_name)) {
                                any_uses = true;
                                break;
                            }
                        }
                    }
                    if (any_uses) {
                        const bind_name = try std.fmt.allocPrint(cg.allocator, "_is_{d}", .{cg.narrowing_count});
                        try cg.type_strings.append(cg.allocator, bind_name); // track for cleanup
                        cg.narrowing_count += 1;
                        // Determine effective type_class for the unwrap expression.
                        const already_subst = !std.mem.eql(u8, source_name, var_name);
                        const eff_tc = blk: {
                            if (narrowing.type_class == .null_error_union and !already_subst) {
                                if (narrowing.then_branch) |tb| {
                                    if (tb.kind == .null_sentinel) break :blk mir.TypeClass.null_union;
                                    if (tb.kind == .error_sentinel) break :blk mir.TypeClass.null_error_union;
                                }
                            }
                            if (narrowing.then_branch) |tb| {
                                if (tb.kind == .null_sentinel) break :blk mir.TypeClass.null_union;
                                if (tb.kind == .error_sentinel) break :blk mir.TypeClass.error_union;
                            }
                            break :blk narrowing.type_class;
                        };
                        try cg.emitIndent();
                        try emitUnwrapBindingNamed(cg, bind_name, source_name, pb, eff_tc);
                        try cg.emit("\n");
                        const prev = cg.match_var_subst;
                        const subst_tc: ?mir.TypeClass = if (eff_tc == .null_error_union) .plain else eff_tc;
                        cg.match_var_subst = .{ .original = var_name, .capture = bind_name, .eff_tc = subst_tc };
                        // Recursively process remaining siblings — handles cascading narrowing
                        try emitStatementsWithNarrowing(cg, remaining);
                        cg.match_var_subst = prev;
                        return; // remaining siblings already emitted
                    }
                }
            }
        }
    }
}

/// MIR-path statement generator — dispatches on MirStore tag when idx is a real store
/// entry, falls back to old *MirNode path otherwise.
/// Collapses the former generateStatementMir + generateStatementMirImpl into one function.
pub fn generateStatementMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (isRealMirIdx(cg, idx)) {
        const store = cg.mir_store.?;
        const entry = store.getNode(idx);
        switch (entry.tag) {
            .var_decl => {
                const rec = mir_typed.VarDecl.unpack(store, idx);
                const var_name = store.strings.get(rec.name);
                const flags = rec.flags;
                const is_const = (flags & 2) != 0;
                // Type alias in function body: const Name: type = T
                if (is_const) {
                    const type_ann_node = if (rec.type_annotation != .none) cg.getAstNode(rec.type_annotation) else null;
                    if (codegen.isTypeAlias(type_ann_node)) {
                        const val_ast = if (rec.value != .none) cg.getAstNode(store.getNode(rec.value).span) else null;
                        try cg.emitFmt("const {s} = ", .{var_name});
                        if (val_ast) |va| {
                            try cg.emit(try cg.typeToZig(va));
                        }
                        try cg.emit(";");
                        return;
                    }
                    try cg.generateStmtDeclMir(idx, "const");
                } else {
                    const is_mutated = cg.reassigned_vars.contains(var_name);
                    const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                    if (!is_mutated) {
                        // Source location from old MirNode for the warning
                        if (cg.getOldMirNode(idx)) |m| {
                            try cg.reporter.warnFmt(cg.nodeLocMir(m),
                                "'{s}' is declared as var but never reassigned — use const", .{var_name});
                        }
                    }
                    try cg.generateStmtDeclMir(idx, decl_keyword);
                }
            },
            .return_stmt => {
                const rec = mir_typed.ReturnStmt.unpack(store, idx);
                try cg.emit("return");
                if (rec.value != .none) {
                    const val_idx = rec.value;
                    const val_entry = store.getNode(val_idx);
                    try cg.emit(" ");
                    // Inside a match arm, the variable is already unwrapped by the capture —
                    // skip coercions like .optional_unwrap that would double-unwrap.
                    const is_substituted = if (cg.match_var_subst) |subst| blk: {
                        if (val_entry.tag == .identifier) {
                            const id_rec = mir_typed.Identifier.unpack(store, val_idx);
                            const id_name = store.strings.get(id_rec.name);
                            break :blk std.mem.eql(u8, id_name, subst.original);
                        }
                        break :blk false;
                    } else false;
                    // Use MIR coercion from MirStore coercion_kind
                    const coercion = mir_store_mod.coercionFromKind(val_entry.coercion_kind);
                    if (!is_substituted and coercion != null) {
                        switch (coercion.?) {
                            // Native ?T and anyerror!T — Zig handles coercion natively
                            .null_wrap, .error_wrap => {
                                try cg.generateExprMir(val_idx);
                            },
                            .arbitrary_union_wrap => |_| {
                                try cg.generateArbitraryUnionWrappedExprMir(val_idx, cg.funcReturnMembers());
                            },
                            .array_to_slice, .value_to_const_ref => {
                                try cg.emit("&");
                                try cg.generateExprMir(val_idx);
                            },
                            .optional_unwrap => {
                                // Native ?T: unwrap → .?
                                try cg.generateExprMir(val_idx);
                                try cg.emit(".?");
                            },
                        }
                    } else {
                        // Native ?T and anyerror!T — Zig coerces values automatically
                        try cg.generateExprMir(val_idx);
                    }
                }
                try cg.emit(";");
            },
            .if_stmt => {
                const rec = mir_typed.IfStmt.unpack(store, idx);
                try cg.emit("if (");
                try cg.generateExprMir(rec.condition);
                try cg.emit(") ");
                // Narrowing: prefer MirStore IfNarrowingExtra.
                // Use old MirNode as bridge to readNarrowingFromStore (parser node needed).
                const narrowing_opt: ?mir.IfNarrowing = if (cg.getOldMirNode(idx)) |m|
                    readNarrowingFromStore(cg, m.ast) orelse m.narrowing
                else
                    null;
                if (narrowing_opt) |narrowing| {
                    const tc = narrowing.type_class;
                    const vn = narrowing.var_name;
                    // Then-block with narrowing
                    if (rec.then_block != .none) {
                        if (narrowing.then_branch) |tb| {
                            if (match_impl.mirContainsIdentifier(store, rec.then_block, vn)) {
                                if (cg.getOldMirNode(rec.then_block)) |then_m| {
                                    try emitNarrowedBlock(cg, then_m, vn, tb, tc);
                                } else {
                                    try cg.generateBlockMir(rec.then_block);
                                }
                            } else {
                                try cg.generateBlockMir(rec.then_block);
                            }
                        } else {
                            try cg.generateBlockMir(rec.then_block);
                        }
                    }
                    // Else-block with narrowing
                    if (rec.else_block != .none) {
                        try cg.emit(" else ");
                        if (store.getNode(rec.else_block).tag == .if_stmt) {
                            try generateStatementMir(cg, rec.else_block);
                        } else if (narrowing.else_branch) |eb| {
                            if (match_impl.mirContainsIdentifier(store, rec.else_block, vn)) {
                                if (cg.getOldMirNode(rec.else_block)) |else_m| {
                                    try emitNarrowedBlock(cg, else_m, vn, eb, tc);
                                } else {
                                    try cg.generateBlockMir(rec.else_block);
                                }
                            } else {
                                try cg.generateBlockMir(rec.else_block);
                            }
                        } else {
                            try cg.generateBlockMir(rec.else_block);
                        }
                    }
                } else {
                    if (rec.then_block != .none) try cg.generateBlockMir(rec.then_block);
                    if (rec.else_block != .none) {
                        try cg.emit(" else ");
                        if (store.getNode(rec.else_block).tag == .if_stmt) {
                            try generateStatementMir(cg, rec.else_block);
                        } else {
                            try cg.generateBlockMir(rec.else_block);
                        }
                    }
                }
            },
            .assignment => {
                const rec = mir_typed.Assignment.unpack(store, idx);
                const assign_op: parser.Operator = @enumFromInt(rec.op);
                const lhs_idx = rec.lhs;
                const rhs_idx = rec.rhs;
                const lhs_entry = store.getNode(lhs_idx);
                // Use MirStore type_class supplemented by old MirNode fallback.
                // MirStore identifier type_class may be .plain when the type_map
                // doesn't have the resolved union type (e.g. cross-module vars).
                const lhs_type_class_store = lhs_entry.type_class;
                const lhs_type_class = blk: {
                    if (lhs_type_class_store != .plain) break :blk lhs_type_class_store;
                    // Supplement from old MirNode when MirStore says .plain
                    if (cg.getOldMirNode(lhs_idx)) |lhs_m| break :blk lhs_m.type_class;
                    break :blk lhs_type_class_store;
                };
                if (assign_op == .div_assign) {
                    const lhs_rt = if (lhs_entry.type_id != .none) store.types.get(lhs_entry.type_id) else .unknown;
                    // Supplement is_float from old MirNode when type_id unavailable
                    const is_float_assign = if (lhs_rt == .primitive)
                        lhs_rt.primitive.isFloat()
                    else if (cg.getOldMirNode(lhs_idx)) |lhs_m|
                        lhs_m.resolved_type == .primitive and lhs_m.resolved_type.primitive.isFloat()
                    else
                        false;
                    try cg.generateExprMir(lhs_idx);
                    if (is_float_assign) {
                        try cg.emit(" = (");
                        try cg.generateExprMir(lhs_idx);
                        try cg.emit(" / ");
                        try cg.generateExprMir(rhs_idx);
                        try cg.emit(");");
                    } else {
                        try cg.emit(" = @divTrunc(");
                        try cg.generateExprMir(lhs_idx);
                        try cg.emit(", ");
                        try cg.generateExprMir(rhs_idx);
                        try cg.emit(");");
                    }
                } else if (assign_op == .assign and
                    (lhs_type_class == .null_union or lhs_type_class == .null_error_union))
                {
                    try cg.generateExprMir(lhs_idx);
                    try cg.emit(" = ");
                    try cg.generateCoercedExprMir(rhs_idx);
                    try cg.emit(";");
                } else if (assign_op == .assign and lhs_type_class == .arbitrary_union) {
                    const lhs_rt = if (lhs_entry.type_id != .none) store.types.get(lhs_entry.type_id) else .unknown;
                    const members_rt = if (lhs_rt == .union_type)
                        lhs_rt.union_type
                    else if (lhs_entry.tag == .identifier) blk: {
                        const id_rec = mir_typed.Identifier.unpack(store, lhs_idx);
                        const from_var = cg.getVarUnionMembers(store.strings.get(id_rec.name));
                        if (from_var) |fv| break :blk fv;
                        // Supplement from old MirNode resolved_type
                        if (cg.getOldMirNode(lhs_idx)) |lhs_m| {
                            if (lhs_m.resolved_type == .union_type) break :blk lhs_m.resolved_type.union_type;
                        }
                        break :blk null;
                    } else null;
                    try cg.generateExprMir(lhs_idx);
                    try cg.emit(" = ");
                    try cg.generateArbitraryUnionWrappedExprMir(rhs_idx, members_rt);
                    try cg.emit(";");
                } else {
                    try cg.generateExprMir(lhs_idx);
                    try cg.emitFmt(" {s} ", .{assign_op.toZig()});
                    try cg.generateExprMir(rhs_idx);
                    try cg.emit(";");
                }
            },
            .destruct => try cg.generateDestructMir(idx),
            .while_stmt => {
                const rec = mir_typed.WhileStmt.unpack(store, idx);
                try cg.emit("while (");
                try cg.generateExprMir(rec.condition);
                try cg.emit(")");
                // Continue expression is not yet in MirStore (missing from B9 WhileStmt).
                // Fall back to old MirNode to check for children[2].
                if (cg.getOldMirNode(idx)) |m| {
                    if (m.children.len > 2) {
                        const cont_m = m.children[2];
                        try cg.emit(" : (");
                        try cg.generateContinueExprMir(cg.mirIdx(cont_m));
                        try cg.emit(")");
                    }
                }
                try cg.emit(" ");
                try cg.generateBlockMir(rec.body);
            },
            .for_stmt => try cg.generateForMir(idx),
            .defer_stmt => {
                const rec = mir_typed.DeferStmt.unpack(store, idx);
                try cg.emit("defer ");
                try cg.generateBlockMir(rec.body);
            },
            .match_stmt => try cg.generateMatchMir(idx),
            .break_stmt => try cg.emit("break;"),
            .continue_stmt => try cg.emit("continue;"),
            .block => try cg.generateBlockMir(idx),
            // Injected nodes from MirLowerer (interpolation hoisting)
            .temp_var => {
                const tv_rec = mir_typed.TempVar.unpack(store, idx);
                const name = store.strings.get(tv_rec.name);
                try cg.emitFmt("const {s} = ", .{name});
                // interp_parts and children are on the old MirNode — fall back to retrieve them.
                if (cg.getOldMirNode(idx)) |m| {
                    if (m.interp_parts) |parts| {
                        // Use inline variant — temp_var already provides the const + sibling defer
                        try cg.generateInterpolatedStringMirInline(parts, m.children);
                    }
                }
                try cg.emit(";");
            },
            .injected_defer => {
                // Retrieve the name from the old MirNode's injected_name field.
                if (cg.getOldMirNode(idx)) |m| {
                    if (m.injected_name) |name| {
                        try cg.emitFmt("defer std.heap.smp_allocator.free({s});", .{name});
                    }
                }
            },
            // Local function declaration — delegate to top-level func codegen
            .func => {
                try cg.generateFuncMir(idx);
            },
            // Expression-kind MirNodes used as statements — discard return value.
            else => {
                if (entry.tag == .call) try cg.emit("_ = ");
                try cg.generateExprMir(idx);
                try cg.emit(";");
            },
        }
    } else {
        // Fallback: old MirNode tree (no MirStore or synthetic index)
        const m = cg.getOldMirNode(idx) orelse return;
        try generateStatementMirImpl(cg, m);
    }
}

/// Private implementation — takes *mir.MirNode directly for the old-path fallback.
/// Called from generateStatementMir when idx is a synthetic or unavailable index.
fn generateStatementMirImpl(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    switch (m.kind) {
        .var_decl => {
            const var_name = m.name orelse return;
            // Type alias in function body: const Name: type = T
            if (m.is_const and codegen.isTypeAlias(m.type_annotation)) {
                try cg.emitFmt("const {s} = ", .{var_name});
                try cg.emit(try cg.typeToZig(m.value().ast)); // type trees are structural — typeToZig walks AST
                try cg.emit(";");
                return;
            }
            if (m.is_const) {
                try cg.generateStmtDeclMir(cg.mirIdx(m), "const");
            } else {
                const is_mutated = cg.reassigned_vars.contains(var_name);
                const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    try cg.reporter.warnFmt(cg.nodeLocMir(m),
                        "'{s}' is declared as var but never reassigned — use const", .{var_name});
                }
                try cg.generateStmtDeclMir(cg.mirIdx(m), decl_keyword);
            }
        },
        .return_stmt => {
            try cg.emit("return");
            if (m.children.len > 0) {
                const val_m = m.value();
                try cg.emit(" ");
                // Inside a match arm, the variable is already unwrapped by the capture —
                // skip coercions like .optional_unwrap that would double-unwrap.
                const is_substituted = if (cg.match_var_subst) |subst|
                    (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", subst.original))
                else
                    false;
                // Use MIR coercion from child MirNode directly
                if (!is_substituted and val_m.coercion != null) {
                    switch (val_m.coercion.?) {
                        // Native ?T and anyerror!T — Zig handles coercion natively
                        .null_wrap, .error_wrap => {
                            try cg.generateExprMir(cg.mirIdx(val_m));
                        },
                        .arbitrary_union_wrap => |_| {
                            try cg.generateArbitraryUnionWrappedExprMir(cg.mirIdx(val_m), cg.funcReturnMembers());
                        },
                        .array_to_slice, .value_to_const_ref => {
                            try cg.emit("&");
                            try cg.generateExprMir(cg.mirIdx(val_m));
                        },
                        .optional_unwrap => {
                            // Native ?T: unwrap → .?
                            try cg.generateExprMir(cg.mirIdx(val_m));
                            try cg.emit(".?");
                        },
                    }
                } else {
                    // Native ?T and anyerror!T — Zig coerces values automatically
                    try cg.generateExprMir(cg.mirIdx(val_m));
                }
            }
            try cg.emit(";");
        },
        .if_stmt => {
            try cg.emit("if (");
            try cg.generateExprMir(cg.mirIdx(m.condition()));
            try cg.emit(") ");
            // Narrowing: prefer MirStore IfNarrowingExtra, fall back to old MirNode.narrowing.
            if (readNarrowingFromStore(cg, m.ast) orelse m.narrowing) |narrowing| {
                const tc = narrowing.type_class;
                const vn = narrowing.var_name;
                const old_store = cg.mir_store;
                // Then-block with narrowing
                if (m.children.len > 1) {
                    const then_m = m.thenBlock();
                    if (narrowing.then_branch) |tb| {
                        const then_uses = if (old_store) |s| match_impl.mirContainsIdentifier(s, cg.mirIdx(then_m), vn) else match_impl.mirContainsIdentifierOld(then_m, vn);
                        if (then_uses) {
                            try emitNarrowedBlock(cg, then_m, vn, tb, tc);
                        } else {
                            try cg.generateBlockMir(cg.mirIdx(then_m));
                        }
                    } else {
                        try cg.generateBlockMir(cg.mirIdx(then_m));
                    }
                }
                // Else-block with narrowing
                if (m.elseBlock()) |else_m| {
                    try cg.emit(" else ");
                    if (else_m.kind == .if_stmt) {
                        try generateStatementMirImpl(cg, else_m);
                    } else if (narrowing.else_branch) |eb| {
                        const else_uses = if (old_store) |s| match_impl.mirContainsIdentifier(s, cg.mirIdx(else_m), vn) else match_impl.mirContainsIdentifierOld(else_m, vn);
                        if (else_uses) {
                            try emitNarrowedBlock(cg, else_m, vn, eb, tc);
                        } else {
                            try cg.generateBlockMir(cg.mirIdx(else_m));
                        }
                    } else {
                        try cg.generateBlockMir(cg.mirIdx(else_m));
                    }
                }
            } else {
                if (m.children.len > 1) try cg.generateBlockMir(cg.mirIdx(m.thenBlock()));
                if (m.elseBlock()) |else_m| {
                    try cg.emit(" else ");
                    if (else_m.kind == .if_stmt) {
                        try generateStatementMirImpl(cg, else_m);
                    } else {
                        try cg.generateBlockMir(cg.mirIdx(else_m));
                    }
                }
            }
        },
        .assignment => {
            const assign_op = m.op orelse .assign;
            if (assign_op == .div_assign) {
                const is_float_assign = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                if (is_float_assign) {
                    try cg.emit(" = (");
                    try cg.generateExprMir(cg.mirIdx(m.lhs()));
                    try cg.emit(" / ");
                    try cg.generateExprMir(cg.mirIdx(m.rhs()));
                    try cg.emit(");");
                } else {
                    try cg.emit(" = @divTrunc(");
                    try cg.generateExprMir(cg.mirIdx(m.lhs()));
                    try cg.emit(", ");
                    try cg.generateExprMir(cg.mirIdx(m.rhs()));
                    try cg.emit(");");
                }
            } else if (assign_op == .assign and
                (m.lhs().type_class == .null_union or m.lhs().type_class == .null_error_union))
            {
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                try cg.emit(" = ");
                try cg.generateCoercedExprMir(cg.mirIdx(m.rhs()));
                try cg.emit(";");
            } else if (assign_op == .assign and
                m.lhs().type_class == .arbitrary_union)
            {
                const members_rt = if (m.lhs().resolved_type == .union_type)
                    m.lhs().resolved_type.union_type
                else if (m.lhs().kind == .identifier) cg.getVarUnionMembers(m.lhs().name orelse "") else null;
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                try cg.emit(" = ");
                try cg.generateArbitraryUnionWrappedExprMir(cg.mirIdx(m.rhs()), members_rt);
                try cg.emit(";");
            } else {
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                try cg.emitFmt(" {s} ", .{assign_op.toZig()});
                try cg.generateExprMir(cg.mirIdx(m.rhs()));
                try cg.emit(";");
            }
        },
        .destruct => try cg.generateDestructMir(cg.mirIdx(m)),
        .while_stmt => {
            try cg.emit("while (");
            try cg.generateExprMir(cg.mirIdx(m.condition()));
            try cg.emit(")");
            if (m.children.len > 2) {
                const cont_m = m.children[2];
                try cg.emit(" : (");
                try cg.generateContinueExprMir(cg.mirIdx(cont_m));
                try cg.emit(")");
            }
            try cg.emit(" ");
            // Body is children[1]
            try cg.generateBlockMir(cg.mirIdx(m.children[1]));
        },
        .for_stmt => try cg.generateForMir(cg.mirIdx(m)),
        .defer_stmt => {
            try cg.emit("defer ");
            try cg.generateBlockMir(cg.mirIdx(m.body()));
        },
        .match_stmt => try cg.generateMatchMir(cg.mirIdx(m)),
        .break_stmt => try cg.emit("break;"),
        .continue_stmt => try cg.emit("continue;"),
        .block => try cg.generateBlockMir(cg.mirIdx(m)),
        // Injected nodes from MirLowerer (interpolation hoisting)
        .temp_var => {
            if (m.injected_name) |name| {
                try cg.emitFmt("const {s} = ", .{name});
                if (m.interp_parts) |parts| {
                    // Use inline variant — temp_var already provides the const + sibling defer
                    try cg.generateInterpolatedStringMirInline(parts, m.children);
                }
                try cg.emit(";");
            }
        },
        .injected_defer => {
            if (m.injected_name) |name| {
                try cg.emitFmt("defer std.heap.smp_allocator.free({s});", .{name});
            }
        },
        // Local function declaration — delegate to top-level func codegen
        .func => {
            try cg.generateFuncMir(cg.mirIdx(m));
        },
        // Expression-kind MirNodes used as statements — discard return value.
        else => {
            if (m.kind == .call) try cg.emit("_ = ");
            try cg.generateExprMir(cg.mirIdx(m));
            try cg.emit(";");
        },
    }
}

/// MIR-path statement var/const declaration — uses VarDecl typed record from MirStore
/// when idx is a real store entry, falls back to old MirNode otherwise.
pub fn generateStmtDeclMir(cg: *CodeGen, idx: MirNodeIndex, decl_keyword: []const u8) anyerror!void {
    if (isRealMirIdx(cg, idx)) {
        const store = cg.mir_store.?;
        const rec = mir_typed.VarDecl.unpack(store, idx);
        const var_name = store.strings.get(rec.name);
        const val_idx = rec.value;
        const val_entry = store.getNode(val_idx);
        try cg.emitFmt("{s} {s}", .{ decl_keyword, var_name });
        if (rec.type_annotation != .none) {
            if (cg.getAstNode(rec.type_annotation)) |ta| {
                // array_to_slice emits &source which gives *const [N]T — only coerces to []const T.
                const val_coercion = mir_store_mod.coercionFromKind(val_entry.coercion_kind);
                if (val_coercion != null and std.meta.activeTag(val_coercion.?) == .array_to_slice and ta.* == .type_slice) {
                    const inner = try cg.typeToZig(ta.type_slice);
                    try cg.emitFmt(": []const {s}", .{inner});
                } else {
                    try cg.emitFmt(": {s}", .{try cg.typeToZig(ta)});
                }
            }
        }
        try cg.emit(" = ");
        const node_type_class = store.getNode(idx).type_class;
        const val_coercion = mir_store_mod.coercionFromKind(val_entry.coercion_kind);
        if (node_type_class == .arbitrary_union) {
            try cg.generateCoercedExprMir(val_idx);
        } else if (val_entry.tag == .type_expr) {
            // Type in expression position = default constructor (.{})
            try cg.emit(".{}");
        } else if (val_coercion) |c| {
            // Inside a match arm, the variable is already unwrapped — skip coercions
            const is_substituted = if (cg.match_var_subst) |subst| blk: {
                if (val_entry.tag == .identifier) {
                    const id_rec = mir_typed.Identifier.unpack(store, val_idx);
                    const id_name = store.strings.get(id_rec.name);
                    break :blk std.mem.eql(u8, id_name, subst.original);
                }
                break :blk false;
            } else false;
            if (is_substituted) {
                try cg.generateExprMir(val_idx);
            } else switch (c) {
                .array_to_slice, .value_to_const_ref => {
                    try cg.emit("&");
                    try cg.generateExprMir(val_idx);
                },
                .optional_unwrap => {
                    try cg.generateExprMir(val_idx);
                    try cg.emit(".?");
                },
                else => {
                    // null_wrap, error_wrap, arbitrary_union_wrap — Zig handles natively
                    try cg.generateExprMir(val_idx);
                },
            }
        } else {
            // No coercion — emit value directly
            try cg.generateExprMir(val_idx);
        }
        try cg.emitFmt("; _ = &{s};", .{var_name});
    } else {
        // Fallback: old MirNode tree
        const m = cg.getOldMirNode(idx) orelse return;
        const var_name = m.name orelse return;
        const val_m = m.value(); // children[0] = value expression
        try cg.emitFmt("{s} {s}", .{ decl_keyword, var_name });
        if (m.type_annotation) |t| {
            // array_to_slice emits &source which gives *const [N]T — only coerces to []const T.
            if (val_m.coercion != null and std.meta.activeTag(val_m.coercion.?) == .array_to_slice and t.* == .type_slice) {
                const inner = try cg.typeToZig(t.type_slice);
                try cg.emitFmt(": []const {s}", .{inner});
            } else {
                try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
            }
        }
        try cg.emit(" = ");
        if (m.type_class == .arbitrary_union) {
            try cg.generateCoercedExprMir(cg.mirIdx(val_m));
        } else if (val_m.kind == .type_expr) {
            // Type in expression position = default constructor (.{})
            try cg.emit(".{}");
        } else if (val_m.coercion) |c| {
            // Inside a match arm, the variable is already unwrapped — skip coercions
            const is_substituted = if (cg.match_var_subst) |subst|
                (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", subst.original))
            else
                false;
            if (is_substituted) {
                try cg.generateExprMir(cg.mirIdx(val_m));
            } else switch (c) {
                .array_to_slice, .value_to_const_ref => {
                    try cg.emit("&");
                    try cg.generateExprMir(cg.mirIdx(val_m));
                },
                .optional_unwrap => {
                    try cg.generateExprMir(cg.mirIdx(val_m));
                    try cg.emit(".?");
                },
                else => {
                    // null_wrap, error_wrap, arbitrary_union_wrap — Zig handles natively
                    try cg.generateExprMir(cg.mirIdx(val_m));
                },
            }
        } else {
            // No coercion — emit value directly
            try cg.generateExprMir(cg.mirIdx(val_m));
        }
        try cg.emitFmt("; _ = &{s};", .{var_name});
    }
}
