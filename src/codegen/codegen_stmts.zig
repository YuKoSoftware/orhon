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

/// Read IfNarrowing directly from a MirNodeIndex.
/// String slices borrow from cg.mir_store.strings — valid during generate().
fn readNarrowingFromStoreIdx(cg: *const CodeGen, idx: MirNodeIndex) ?mir.IfNarrowing {
    const store = cg.mir_store orelse return null;
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
fn emitNarrowedBlockFromStore(cg: *CodeGen, block_idx: MirNodeIndex, var_name: []const u8, narrow: mir.NarrowBranch, type_class: mir.TypeClass) anyerror!void {
    const store = cg.mir_store.?;
    const stmts = mir_typed.Block.getStmts(store, block_idx);
    try cg.emit("{\n");
    cg.indent += 1;
    // Emit the arm-top binding
    try cg.emitIndent();
    try emitUnwrapBinding(cg, var_name, narrow, type_class);
    try cg.emit("\n");
    // Generate body with substitution active
    const prev = cg.match_var_subst;
    cg.match_var_subst = .{ .original = var_name, .capture = "_is_val" };
    const saved_pre = cg.pre_stmts;
    cg.pre_stmts = .{};
    for (stmts) |child_idx| {
        try cg.flushPreStmts();
        const stmt_start = cg.output.items.len;
        try cg.emitIndent();
        try generateStatementMir(cg, child_idx);
        try cg.emit("\n");
        if (cg.pre_stmts.items.len > 0) {
            const stmt_bytes = try cg.allocator.dupe(u8, cg.output.items[stmt_start..]);
            defer cg.allocator.free(stmt_bytes);
            cg.output.shrinkRetainingCapacity(stmt_start);
            try cg.flushPreStmts();
            try cg.output.appendSlice(cg.allocator, stmt_bytes);
        }
    }
    cg.pre_stmts.deinit(cg.allocator);
    cg.pre_stmts = saved_pre;
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

/// MIR-path block generation — reads stmt list from MirStore Block.
pub fn generateBlockMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const stmts = mir_typed.Block.getStmts(store, idx);
    try cg.emit("{\n");
    cg.indent += 1;
    // Isolate pre_stmts: any pre_stmts from the outer scope (e.g. from an if-condition)
    // must not be flushed inside this nested block — they belong before the entire
    // statement that opened this block. Save and restore around body emission.
    const saved_pre = cg.pre_stmts;
    cg.pre_stmts = .{};
    try emitStatementsWithNarrowing(cg, stmts);
    cg.pre_stmts.deinit(cg.allocator);
    cg.pre_stmts = saved_pre;
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// Emit the body statements of a block node, already inside an outer `{`.
/// Caller must manage indentation and surrounding braces.
pub fn generateBodyStatements(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const stmts = mir_typed.Block.getStmts(store, idx);
    try emitStatementsWithNarrowing(cg, stmts);
}

/// Emit a slice of MirNodeIndex statements, handling post-if narrowing at each step.
/// When narrowing fires, emits a binding and recursively processes remaining siblings.
fn emitStatementsWithNarrowing(cg: *CodeGen, stmts: []const MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    for (stmts, 0..) |child_idx, i| {
        try cg.flushPreStmts();
        const stmt_start = cg.output.items.len;
        try cg.emitIndent();
        try generateStatementMir(cg, child_idx);
        try cg.emit("\n");
        // If generateStatementMir populated pre_stmts (e.g. interpolation temp vars),
        // hoist them before the statement we just emitted.
        if (cg.pre_stmts.items.len > 0) {
            const stmt_bytes = try cg.allocator.dupe(u8, cg.output.items[stmt_start..]);
            defer cg.allocator.free(stmt_bytes);
            cg.output.shrinkRetainingCapacity(stmt_start);
            try cg.flushPreStmts();
            try cg.output.appendSlice(cg.allocator, stmt_bytes);
        }
        // Post-if narrowing: if this if_stmt has early exit and post_branch,
        // emit a binding for the narrowed variable and substitute in remaining siblings.
        if (store.getNode(child_idx).tag == .if_stmt) {
            const narrowing_opt: ?mir.IfNarrowing = readNarrowingFromStoreIdx(cg, child_idx);
            if (narrowing_opt) |narrowing| {
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
                    const remaining = stmts[i + 1 ..];
                    var any_uses = false;
                    for (remaining) |sib_idx| {
                        if (match_impl.mirContainsIdentifier(store, sib_idx, var_name)) {
                            any_uses = true;
                            break;
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

/// MIR-path statement generator — dispatches on MirStore tag.
pub fn generateStatementMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
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
            const narrowing_opt = readNarrowingFromStoreIdx(cg, idx);
            if (narrowing_opt) |narrowing| {
                const tc = narrowing.type_class;
                const vn = narrowing.var_name;
                // Then-block with narrowing
                if (rec.then_block != .none) {
                    if (narrowing.then_branch) |tb| {
                        if (match_impl.mirContainsIdentifier(store, rec.then_block, vn)) {
                            try emitNarrowedBlockFromStore(cg, rec.then_block, vn, tb, tc);
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
                            try emitNarrowedBlockFromStore(cg, rec.else_block, vn, eb, tc);
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
            const lhs_type_class = lhs_entry.type_class;
            if (assign_op == .div_assign) {
                const lhs_rt = if (lhs_entry.type_id != .none) store.types.get(lhs_entry.type_id) else .unknown;
                const is_float_assign = if (lhs_rt == .primitive) lhs_rt.primitive.isFloat() else false;
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
                else
                    null;
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
            if (rec.continue_expr != .none) {
                try cg.emit(" : (");
                try cg.generateContinueExprMir(rec.continue_expr);
                try cg.emit(")");
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
        // Injected nodes from MirBuilder (interpolation hoisting)
        .temp_var => {
            const tv_rec = mir_typed.TempVar.unpack(store, idx);
            const name = store.strings.get(tv_rec.name);
            try cg.emitFmt("const {s} = undefined;", .{name});
        },
        .injected_defer => {
            const id_rec = mir_typed.InjectedDefer.unpack(store, idx);
            try cg.emit("defer ");
            try generateStatementMir(cg, id_rec.body);
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
}

/// MIR-path statement var/const declaration — uses VarDecl typed record from MirStore.
pub fn generateStmtDeclMir(cg: *CodeGen, idx: MirNodeIndex, decl_keyword: []const u8) anyerror!void {
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
}
