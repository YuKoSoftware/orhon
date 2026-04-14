// codegen_stmts.zig — Block and statement generators for the Orhon code generator
// Contains: generateBlockMir, generateBodyStatements, generateStatementMir, generateStmtDeclMir.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const match_impl = @import("codegen_match.zig");

const CodeGen = codegen.CodeGen;

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
        try cg.generateStatementMir(child);
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
/// Handles injected temp_var/injected_defer nodes from MirLowerer.
pub fn generateBlockMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    try cg.emit("{\n");
    cg.indent += 1;
    try cg.generateBodyStatements(m);
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// Emit the body statements of a block node, already inside an outer `{`.
/// Caller must manage indentation and surrounding braces.
/// Detects post-if narrowing (early exit pattern) and emits arm-top bindings
/// for subsequent sibling statements. Handles cascading narrowing (e.g.,
/// `if(x is null) { return } if(x is Error) { return } return x`).
pub fn generateBodyStatements(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    try emitStatementsWithNarrowing(cg, m.children);
}

/// Emit a slice of statements, handling post-if narrowing at each step.
/// When narrowing fires, emits a binding and recursively processes remaining siblings.
fn emitStatementsWithNarrowing(cg: *CodeGen, stmts: []*mir.MirNode) anyerror!void {
    for (stmts, 0..) |child, idx| {
        try cg.flushPreStmts();
        try cg.emitIndent();
        try cg.generateStatementMir(child);
        try cg.emit("\n");
        // Post-if narrowing: if this if_stmt has early exit and post_branch,
        // emit a binding for the narrowed variable and substitute in remaining siblings.
        if (child.kind == .if_stmt) {
            if (child.narrowing) |narrowing| {
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
                    for (remaining) |sib| {
                        if (match_impl.mirContainsIdentifier(sib, var_name)) {
                            any_uses = true;
                            break;
                        }
                    }
                    if (any_uses) {
                        const bind_name = try std.fmt.allocPrint(cg.allocator, "_is_{d}", .{cg.narrowing_count});
                        try cg.type_strings.append(cg.allocator, bind_name); // track for cleanup
                        cg.narrowing_count += 1;
                        // Determine effective type_class for the unwrap expression.
                        // For null_error_union: removing null first → .? (gives anyerror!T).
                        // Removing error first → no clean single-layer unwrap exists in Zig,
                        // so do full unwrap (.? catch unreachable) to get T directly.
                        // If already substituted (one layer removed), use simple single-layer.
                        const already_subst = !std.mem.eql(u8, source_name, var_name);
                        const eff_tc = blk: {
                            if (narrowing.type_class == .null_error_union and !already_subst) {
                                if (narrowing.then_branch) |tb| {
                                    if (tb.kind == .null_sentinel) break :blk mir.TypeClass.null_union;
                                    // Error-first on null_error_union → full unwrap
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
                        // If we did a full unwrap (null_error_union), the remaining type
                        // is plain T — prevent further narrowing on this variable.
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

/// MIR-path statement dispatch — switches on MirKind, reads type info from MirNode.
/// All handlers use MirNode tree directly — no AST fallthrough.
pub fn generateStatementMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    switch (m.kind) {
        .var_decl => {
            const var_name = m.name orelse return;
            // Type alias in function body: const Name: type = T
            // No _ = &name; suffix — type aliases are types, not values.
            if (m.is_const and codegen.isTypeAlias(m.type_annotation)) {
                try cg.emitFmt("const {s} = ", .{var_name});
                try cg.emit(try cg.typeToZig(m.value().ast)); // type trees are structural — typeToZig walks AST
                try cg.emit(";");
                return;
            }
            if (m.is_const) {
                try cg.generateStmtDeclMir(m, "const");
            } else {
                const is_mutated = cg.reassigned_vars.contains(var_name);
                const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    try cg.reporter.warnFmt(cg.nodeLocMir(m),
                        "'{s}' is declared as var but never reassigned — use const", .{var_name});
                }
                try cg.generateStmtDeclMir(m, decl_keyword);
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
                            try cg.generateExprMir(val_m);
                        },
                        .arbitrary_union_wrap => |_| {
                            try cg.generateArbitraryUnionWrappedExprMir(val_m, cg.funcReturnMembers());
                        },
                        .array_to_slice, .value_to_const_ref => {
                            try cg.emit("&");
                            try cg.generateExprMir(val_m);
                        },
                        .optional_unwrap => {
                            // Native ?T: unwrap → .?
                            try cg.generateExprMir(val_m);
                            try cg.emit(".?");
                        },
                    }
                } else {
                    // Native ?T and anyerror!T — Zig coerces values automatically
                    try cg.generateExprMir(val_m);
                }
            }
            try cg.emit(";");
        },
        .if_stmt => {
            try cg.emit("if (");
            try cg.generateExprMir(m.condition());
            try cg.emit(") ");
            // Narrowing: emit arm-top bindings when the body uses the narrowed variable
            if (m.narrowing) |narrowing| {
                const tc = narrowing.type_class;
                const vn = narrowing.var_name;
                // Then-block with narrowing
                if (m.children.len > 1) {
                    const then_m = m.thenBlock();
                    if (narrowing.then_branch) |tb| {
                        if (match_impl.mirContainsIdentifier(then_m, vn)) {
                            try emitNarrowedBlock(cg, then_m, vn, tb, tc);
                        } else {
                            try cg.generateBlockMir(then_m);
                        }
                    } else {
                        try cg.generateBlockMir(then_m);
                    }
                }
                // Else-block with narrowing
                if (m.elseBlock()) |else_m| {
                    try cg.emit(" else ");
                    if (else_m.kind == .if_stmt) {
                        try cg.generateStatementMir(else_m);
                    } else if (narrowing.else_branch) |eb| {
                        if (match_impl.mirContainsIdentifier(else_m, vn)) {
                            try emitNarrowedBlock(cg, else_m, vn, eb, tc);
                        } else {
                            try cg.generateBlockMir(else_m);
                        }
                    } else {
                        try cg.generateBlockMir(else_m);
                    }
                }
            } else {
                if (m.children.len > 1) try cg.generateBlockMir(m.thenBlock());
                if (m.elseBlock()) |else_m| {
                    try cg.emit(" else ");
                    if (else_m.kind == .if_stmt) {
                        try cg.generateStatementMir(else_m);
                    } else {
                        try cg.generateBlockMir(else_m);
                    }
                }
            }
        },
        .assignment => {
            const assign_op = m.op orelse .assign;
            if (assign_op == .div_assign) {
                const is_float_assign = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
                try cg.generateExprMir(m.lhs());
                if (is_float_assign) {
                    try cg.emit(" = (");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(" / ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(");");
                } else {
                    try cg.emit(" = @divTrunc(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(", ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(");");
                }
            } else if (assign_op == .assign and
                (m.lhs().type_class == .null_union or m.lhs().type_class == .null_error_union))
            {
                try cg.generateExprMir(m.lhs());
                try cg.emit(" = ");
                try cg.generateCoercedExprMir(m.rhs());
                try cg.emit(";");
            } else if (assign_op == .assign and
                m.lhs().type_class == .arbitrary_union)
            {
                const members_rt = if (m.lhs().resolved_type == .union_type)
                    m.lhs().resolved_type.union_type
                else if (m.lhs().kind == .identifier) cg.getVarUnionMembers(m.lhs().name orelse "") else null;
                try cg.generateExprMir(m.lhs());
                try cg.emit(" = ");
                try cg.generateArbitraryUnionWrappedExprMir(m.rhs(), members_rt);
                try cg.emit(";");
            } else {
                try cg.generateExprMir(m.lhs());
                try cg.emitFmt(" {s} ", .{assign_op.toZig()});
                try cg.generateExprMir(m.rhs());
                try cg.emit(";");
            }
        },
        .destruct => try cg.generateDestructMir(m),
        .while_stmt => {
            try cg.emit("while (");
            try cg.generateExprMir(m.condition());
            try cg.emit(")");
            if (m.children.len > 2) {
                const cont_m = m.children[2];
                try cg.emit(" : (");
                try cg.generateContinueExprMir(cont_m);
                try cg.emit(")");
            }
            try cg.emit(" ");
            // Body is children[1]
            try cg.generateBlockMir(m.children[1]);
        },
        .for_stmt => try cg.generateForMir(m),
        .defer_stmt => {
            try cg.emit("defer ");
            try cg.generateBlockMir(m.body());
        },
        .match_stmt => try cg.generateMatchMir(m),
        .break_stmt => try cg.emit("break;"),
        .continue_stmt => try cg.emit("continue;"),
        .block => try cg.generateBlockMir(m),
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
            try cg.generateFuncMir(m);
        },
        // Expression-kind MirNodes used as statements — discard return value.
        // Covers: call, field_expr, index, compiler_func, literal, identifier, etc.
        else => {
            if (m.kind == .call) try cg.emit("_ = ");
            try cg.generateExprMir(m);
            try cg.emit(";");
        },
    }
}

/// MIR-path statement var/const declaration — uses m.type_class directly.
pub fn generateStmtDeclMir(cg: *CodeGen, m: *mir.MirNode, decl_keyword: []const u8) anyerror!void {
    const var_name = m.name orelse return;
    const val_m = m.value(); // children[0] = value expression
    try cg.emitFmt("{s} {s}", .{ decl_keyword, var_name });
    if (m.type_annotation) |t| {
        // array_to_slice emits &source which gives *const [N]T — only coerces to []const T.
        // For mutable slices, users should use arr[0..len] which produces []T directly.
        if (val_m.coercion != null and std.meta.activeTag(val_m.coercion.?) == .array_to_slice and t.* == .type_slice) {
            const inner = try cg.typeToZig(t.type_slice);
            try cg.emitFmt(": []const {s}", .{inner});
        } else {
            try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
        }
    }
    try cg.emit(" = ");
    if (m.type_class == .arbitrary_union) {
        try cg.generateCoercedExprMir(val_m);
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
            try cg.generateExprMir(val_m);
        } else switch (c) {
            .array_to_slice, .value_to_const_ref => {
                try cg.emit("&");
                try cg.generateExprMir(val_m);
            },
            .optional_unwrap => {
                try cg.generateExprMir(val_m);
                try cg.emit(".?");
            },
            else => {
                // null_wrap, error_wrap, arbitrary_union_wrap — Zig handles natively
                try cg.generateExprMir(val_m);
            },
        }
    } else {
        // No coercion — emit value directly
        try cg.generateExprMir(val_m);
    }
    try cg.emitFmt("; _ = &{s};", .{var_name});
}

