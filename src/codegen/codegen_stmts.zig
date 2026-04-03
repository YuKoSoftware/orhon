// codegen_stmts.zig — Block and statement generators for the Orhon code generator
// Contains: generateBlockMir, generateBodyStatements, generateStatementMir, generateStmtDeclMir.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const builtins = @import("../builtins.zig");

const CodeGen = codegen.CodeGen;

// ============================================================
// BLOCKS AND STATEMENTS
// ============================================================

/// MIR-path block generation — walks MirNode children instead of AST statements.
/// Handles injected temp_var/injected_defer nodes from MirLowerer.
pub fn generateBlockMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    try cg.emit("{\n");
    cg.indent += 1;

    for (m.children) |child| {
        try cg.flushPreStmts();
        try cg.emitIndent();
        try cg.generateStatementMir(child);
        try cg.emit("\n");
    }

    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// Emit the body statements of a block node, already inside an outer `{`.
/// Caller must manage indentation and surrounding braces.
pub fn generateBodyStatements(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    for (m.children) |child| {
        try cg.flushPreStmts();
        try cg.emitIndent();
        try cg.generateStatementMir(child);
        try cg.emit("\n");
    }
}

/// MIR-path statement dispatch — switches on MirKind, reads type info from MirNode.
/// All handlers use MirNode tree directly — no AST fallthrough.
pub fn generateStatementMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    switch (m.kind) {
        .var_decl => {
            const var_name = m.name orelse return;
            // Type alias in function body: const Name: type = T
            // Must precede is_compt check. No _ = &name; suffix — type aliases are types, not values.
            if (m.is_const and codegen.isTypeAlias(m.type_annotation)) {
                try cg.emitFmt("const {s} = ", .{var_name});
                try cg.emit(try cg.typeToZig(m.value().ast)); // type trees are structural — typeToZig walks AST
                try cg.emit(";");
                return;
            }
            if (m.is_compt) {
                try cg.emitFmt("const {s}: {s} = ", .{
                    var_name,
                    try cg.typeToZig(m.type_annotation orelse return),
                });
                try cg.generateExprMir(m.value());
                try cg.emit(";");
            } else if (m.is_const) {
                try cg.generateStmtDeclMir(m, "const");
            } else {
                const is_handle = if (m.type_annotation) |ta|
                    ta.* == .type_generic and std.mem.eql(u8, ta.type_generic.name, builtins.BT.HANDLE)
                else
                    false;
                const is_mutated = is_handle or cg.reassigned_vars.contains(var_name);
                const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    const msg = try std.fmt.allocPrint(cg.allocator,
                        "'{s}' is declared as var but never reassigned — use const", .{var_name});
                    defer cg.allocator.free(msg);
                    try cg.reporter.warn(.{ .message = msg, .loc = cg.nodeLocMir(m) });
                }
                try cg.generateStmtDeclMir(m, decl_keyword);
            }
        },
        .return_stmt => {
            try cg.emit("return");
            if (m.children.len > 0) {
                const val_m = m.value();
                try cg.emit(" ");
                // Use MIR coercion from child MirNode directly
                if (val_m.coercion) |c| {
                    switch (c) {
                        // Native ?T and anyerror!T — Zig handles coercion natively
                        .null_wrap, .error_wrap => {
                            try cg.generateExprMir(val_m);
                        },
                        .arbitrary_union_wrap => {
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
            // Narrowing is pre-stamped on MirNode descendants — no map needed
            if (m.children.len > 1) try cg.generateBlockMir(m.thenBlock());
            if (m.elseBlock()) |else_m| {
                try cg.emit(" else ");
                if (else_m.kind == .if_stmt) {
                    // elif — emit as else if without extra braces
                    try cg.generateStatementMir(else_m);
                } else {
                    try cg.generateBlockMir(else_m);
                }
            }
        },
        .assignment => {
            const assign_op = m.op orelse .assign;
            if (assign_op == .div_assign) {
                try cg.generateExprMir(m.lhs());
                try cg.emit(" = @divTrunc(");
                try cg.generateExprMir(m.lhs());
                try cg.emit(", ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(");");
            } else if (assign_op == .assign and
                m.lhs().type_class == .null_union)
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
        .throw_stmt => {
            const var_name = m.name orelse return;
            try cg.emitFmt("if ({s}) |_| {{}} else |_err| return _err;", .{var_name});
        },
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
        // Bare expression as statement — discard return value
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
    if (m.type_annotation) |t| try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
    try cg.emit(" = ");
    if (m.type_class == .arbitrary_union) {
        try cg.generateCoercedExprMir(val_m);
    } else if (val_m.kind == .type_expr) {
        // Type in expression position = default constructor (.{})
        try cg.emit(".{}");
    } else {
        // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
        const prev_ctx = cg.type_ctx;
        cg.type_ctx = m.type_annotation;
        if (codegen.getPtrCoercionTarget(m.type_annotation)) |ptr| {
            try cg.generatePtrCoercionMir(ptr.name, ptr.inner_type, val_m);
        } else {
            try cg.generateExprMir(val_m);
        }
        cg.type_ctx = prev_ctx;
    }
    try cg.emitFmt("; _ = &{s};", .{var_name});
}

