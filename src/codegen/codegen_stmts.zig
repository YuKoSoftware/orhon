// codegen_stmts.zig — Block, statement, and AST expression generators for the Orhon code generator
// Contains: generateBlockMir, generateBodyStatements, generateStatementMir, generateStmtDeclMir, generateExpr.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const module = @import("../module.zig");
const RT = @import("../types.zig").ResolvedType;
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
            const assign_op = m.op orelse "=";
            if (std.mem.eql(u8, assign_op, K.Op.DIV_ASSIGN)) {
                try cg.generateExprMir(m.lhs());
                try cg.emit(" = @divTrunc(");
                try cg.generateExprMir(m.lhs());
                try cg.emit(", ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(");");
            } else if (std.mem.eql(u8, assign_op, "=") and
                m.lhs().type_class == .null_union)
            {
                try cg.generateExprMir(m.lhs());
                try cg.emit(" = ");
                try cg.generateCoercedExprMir(m.rhs());
                try cg.emit(";");
            } else if (std.mem.eql(u8, assign_op, "=") and
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
                try cg.emitFmt(" {s} ", .{assign_op});
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
            try cg.error_narrowed.put(cg.allocator, var_name, {});
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
        const did_coerce = blk: {
            const t = m.type_annotation orelse break :blk false;
            if (t.* != .type_generic) break :blk false;
            if (t.type_generic.args.len == 0) break :blk false;
            const n = t.type_generic.name;
            if (!builtins.isPtrType(n)) break :blk false;
            try cg.generatePtrCoercionMir(n, t.type_generic.args[0], val_m);
            break :blk true;
        };
        if (!did_coerce) try cg.generateExprMir(val_m);
        cg.type_ctx = prev_ctx;
    }
    try cg.emitFmt("; _ = &{s};", .{var_name});
}

// ============================================================
// EXPRESSIONS (AST path)
// ============================================================

pub fn generateExpr(cg: *CodeGen, node: *parser.Node) anyerror!void {
    switch (node.*) {
        .int_literal => |text| {
            // Remove underscore separators for Zig (Zig uses _ too, so keep them)
            try cg.emit(text);
        },
        .float_literal => |text| try cg.emit(text),
        .string_literal => |text| try cg.emit(text),
        .interpolated_string => |interp| try cg.generateInterpolatedString(interp),
        .bool_literal => |b| try cg.emit(if (b) "true" else "false"),
        .null_literal => try cg.emit("null"),
        .error_literal => |msg| {
            // Error("message") → error.sanitized_name (native Zig error)
            const name = try cg.sanitizeErrorName(msg);
            try cg.emitFmt("error.{s}", .{name});
        },
        .identifier => |name| {
            if (cg.isEnumVariant(name)) {
                try cg.emitFmt(".{s}", .{name});
            } else if (cg.generic_struct_name) |gsn| {
                if (std.mem.eql(u8, name, gsn)) {
                    try cg.emit("@This()");
                } else {
                    const mapped = builtins.primitiveToZig(name);
                    try cg.emit(mapped);
                }
            } else {
                // Map type names used as values (e.g. generic type args)
                const mapped = builtins.primitiveToZig(name);
                try cg.emit(mapped);
            }
        },
        .type_named => {
            // Type used as expression value (e.g. generic type arg in Ptr(i32, &x))
            try cg.emit(try cg.typeToZig(node));
        },
        .mut_borrow_expr => |inner| {
            try cg.emit("&");
            try cg.generateExpr(inner);
        },
        .const_borrow_expr => |inner| {
            // const& expr — explicit const borrow; Zig uses &x for both mutable/const borrows,
            // constness is determined by the pointer type annotation, not the expression syntax.
            try cg.emit("&");
            try cg.generateExpr(inner);
        },
        .array_literal => |items| {
            try cg.emit(".{");
            for (items, 0..) |item, i| {
                if (i > 0) try cg.emit(", ");
                try cg.generateExpr(item);
            }
            try cg.emit("}");
        },
        .tuple_literal => |t| {
            try cg.emit(".{");
            if (t.is_named) {
                for (t.fields, 0..) |field, i| {
                    if (i > 0) try cg.emit(", ");
                    try cg.emitFmt(".{s} = ", .{t.field_names[i]});
                    try cg.generateExpr(field);
                }
            } else {
                for (t.fields, 0..) |field, i| {
                    if (i > 0) try cg.emit(", ");
                    try cg.generateExpr(field);
                }
            }
            try cg.emit("}");
        },
        .binary_expr => |b| {
            // `x is Error`   → if(x) false else true  (anyerror!T check)
            // `x is null`    → x == null    (?T check)
            // `x is T`       → @TypeOf(x) == T  (comptime type check for `any` params)
            // `x is not ...` → same but with !=
            const is_eq = std.mem.eql(u8, b.op, K.Op.EQ);
            const is_ne = std.mem.eql(u8, b.op, K.Op.NE);
            if ((is_eq or is_ne) and
                b.left.* == .compiler_func and
                std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE) and
                b.left.compiler_func.args.len > 0)
            {
                const val_node = b.left.compiler_func.args[0];
                const cmp = if (is_eq) "==" else "!=";
                // null is a keyword, parsed as .null_literal not .identifier
                if (b.right.* == .null_literal) {
                    // Record narrowing for `.value` resolution
                    if (val_node.* == .identifier)
                        try cg.null_narrowed.put(cg.allocator, val_node.identifier, {});
                    // (null | T) → ?T: x is null → x == null
                    try cg.emit("(");
                    try cg.generateExpr(val_node);
                    try cg.emitFmt(" {s} null)", .{cmp});
                    return;
                }
                if (b.right.* == .identifier) {
                    const rhs = b.right.identifier;
                    if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                        // Record narrowing for `.value` resolution
                        if (val_node.* == .identifier)
                            try cg.error_narrowed.put(cg.allocator, val_node.identifier, {});
                        // (Error | T) → anyerror!T: x is Error →
                        //   if (x) |_| false else |_| true  (for ==)
                        //   if (x) |_| true else |_| false  (for !=)
                        const t_val = if (is_eq) "false" else "true";
                        const f_val = if (is_eq) "true" else "false";
                        try cg.emit("(if (");
                        try cg.generateExpr(val_node);
                        try cg.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
                        return;
                    }
                    // Arbitrary union type check: `val is i32` → `val == ._i32`
                    if (cg.getTypeClass(val_node) == .arbitrary_union) {
                        try cg.emit("(");
                        try cg.generateExpr(val_node);
                        try cg.emitFmt(" {s} ._{s})", .{ cmp, rhs });
                        return;
                    }
                    // General type check: `val is i32` → `@TypeOf(val) == i32`
                    // Map Orhon type names to Zig (e.g. String → []const u8)
                    const zig_rhs = builtins.primitiveToZig(rhs);
                    try cg.emit("(@TypeOf(");
                    try cg.generateExpr(val_node);
                    try cg.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                    return;
                }
                // Qualified type check: `val is module.Type` per D-07
                if (b.right.* == .field_expr) {
                    // If left side is a tagged union, emit union tag comparison
                    if (cg.getTypeClass(val_node) == .arbitrary_union) {
                        const fe = b.right.field_expr;
                        try cg.emit("(");
                        try cg.generateExpr(val_node);
                        try cg.emitFmt(" {s} ._{s})", .{ cmp, fe.field });
                        return;
                    }
                    // Non-union: comptime type check via @TypeOf
                    try cg.emit("(@TypeOf(");
                    try cg.generateExpr(val_node);
                    try cg.emitFmt(") {s} ", .{cmp});
                    try cg.emitTypePath(b.right);
                    try cg.emit(")");
                    return;
                }
            }
            // Division on signed ints → @divTrunc in Zig
            if (std.mem.eql(u8, b.op, K.Op.DIV)) {
                try cg.emit("@divTrunc(");
                try cg.generateExpr(b.left);
                try cg.emit(", ");
                try cg.generateExpr(b.right);
                try cg.emit(")");
            } else if (std.mem.eql(u8, b.op, K.Op.MOD)) {
                try cg.emit("@mod(");
                try cg.generateExpr(b.left);
                try cg.emit(", ");
                try cg.generateExpr(b.right);
                try cg.emit(")");
            } else if ((is_eq or is_ne) and (cg.isStringExpr(b.left) or cg.isStringExpr(b.right))) {
                // String ([]const u8) comparison → std.mem.eql
                if (is_ne) try cg.emit("!");
                try cg.emit("std.mem.eql(u8, ");
                try cg.generateExpr(b.left);
                try cg.emit(", ");
                try cg.generateExpr(b.right);
                try cg.emit(")");
            } else {
                const op = codegen.opToZig(b.op);
                try cg.emit("(");
                try cg.generateExpr(b.left);
                try cg.emitFmt(" {s} ", .{op});
                try cg.generateExpr(b.right);
                try cg.emit(")");
            }
        },
        .unary_expr => |u| {
            const op = codegen.opToZig(u.op);
            try cg.emitFmt("{s}(", .{op});
            try cg.generateExpr(u.operand);
            try cg.emit(")");
        },
        .call_expr => |c| {
            // Version() is metadata-only — reject in expressions
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, builtins.BT.VERSION)) {
                try cg.reporter.report(.{
                    .message = "Version() can only be used in #version metadata",
                    .loc = cg.nodeLoc(node),
                });
                return;
            }
            // Handle(value) → just emit the value (wrapping done by spawn wrapper)
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, builtins.BT.HANDLE) and c.args.len == 1) {
                try cg.generateExpr(c.args[0]);
                return;
            }
            // Bitfield constructor: Permissions(Read, Write) → Permissions{ .value = Permissions.Read | Permissions.Write }
            if (c.callee.* == .identifier) {
                if (cg.decls) |d| {
                    if (d.bitfields.get(c.callee.identifier)) |_| {
                        const bf_name = c.callee.identifier;
                        try cg.emitFmt("{s}{{ .value = ", .{bf_name});
                        if (c.args.len == 0) {
                            try cg.emit("0");
                        } else {
                            for (c.args, 0..) |arg, i| {
                                if (i > 0) try cg.emit(" | ");
                                if (arg.* == .identifier) {
                                    try cg.emitFmt("{s}.{s}", .{ bf_name, arg.identifier });
                                } else {
                                    try cg.generateExpr(arg);
                                }
                            }
                        }
                        try cg.emit(" }");
                        return;
                    }
                }
            }
            // Bitfield method: p.has(Read) → p.has(Permissions.Read) — qualify flag args
            if (c.callee.* == .field_expr) {
                const obj = c.callee.field_expr.object;
                if (cg.getBitfieldName(obj)) |bf_name| {
                    try cg.generateExpr(c.callee);
                    try cg.emit("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try cg.emit(", ");
                        if (arg.* == .identifier) {
                            try cg.emitFmt("{s}.{s}", .{ bf_name, arg.identifier });
                        } else {
                            try cg.generateExpr(arg);
                        }
                    }
                    try cg.emit(")");
                    return;
                }
            }
            // Collection constructor: List(T).new(), Map(K,V).new(), Set(T).new() → .{}
            // The collection_expr builder is transparent — List(i32) reduces to the
            // element type_primitive (i32) in the AST. The object is either a
            // collection_expr (if the builder is updated) or a type_primitive/type_named
            // (due to transparency). User struct .new() uses identifier (not type node).
            if (c.callee.* == .field_expr) {
                const method = c.callee.field_expr.field;
                const obj = c.callee.field_expr.object;
                if (std.mem.eql(u8, method, "new")) {
                    const is_type_node = obj.* == .collection_expr or
                        obj.* == .type_primitive or obj.* == .type_named or
                        obj.* == .type_generic;
                    if (is_type_node) {
                        if (c.args.len == 0) {
                            try cg.emit(".{}");
                            return;
                        } else if (c.args.len == 1) {
                            try cg.emit(".{ .alloc = ");
                            try cg.generateExpr(c.args[0]);
                            try cg.emit(" }");
                            return;
                        }
                    }
                }
            }
            // overflow/wrap/sat builtins
            if (c.callee.* == .identifier and c.args.len == 1) {
                const callee_name = c.callee.identifier;
                if (std.mem.eql(u8, callee_name, "wrap")) {
                    try cg.generateWrappingExpr(c.args[0]);
                    return;
                } else if (std.mem.eql(u8, callee_name, "sat")) {
                    try cg.generateSaturatingExpr(c.args[0]);
                    return;
                } else if (std.mem.eql(u8, callee_name, "overflow")) {
                    try cg.generateOverflowExpr(c.args[0]);
                    return;
                }
            }
            // ── String method rewriting ──
            // s.method(args) → str.method(s, args) when s is a String
            // x.toString()   → str.toString(x) for any type
            // arr.join(sep)  → str.join(arr, sep) for array/slice join
            if (c.callee.* == .field_expr) {
                const method = c.callee.field_expr.field;
                const obj = c.callee.field_expr.object;
                const is_handle = cg.getTypeClass(obj) == .thread_handle;
                if (!is_handle and (cg.isStringExpr(obj) or
                    std.mem.eql(u8, method, "toString") or
                    std.mem.eql(u8, method, "join")))
                {
                    if (cg.str_is_included) {
                        try cg.emitFmt("{s}(", .{method});
                    } else {
                        const prefix = cg.str_import_alias orelse "str";
                        try cg.emitFmt("{s}.{s}(", .{ prefix, method });
                    }
                    try cg.generateExpr(obj);
                    for (c.args) |arg| {
                        try cg.emit(", ");
                        try cg.generateExpr(arg);
                    }
                    try cg.emit(")");
                    return;
                }
            }
            // ── Clean call generation — pure 1:1 translation ──
            if (c.arg_names.len > 0) {
                // Named arguments → struct instantiation: Type{ .field = value, ... }
                try cg.generateExpr(c.callee);
                try cg.emit("{ ");
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try cg.emit(", ");
                    if (i < c.arg_names.len and c.arg_names[i].len > 0) {
                        try cg.emitFmt(".{s} = ", .{c.arg_names[i]});
                    }
                    try cg.generateExpr(arg);
                }
                try cg.emit(" }");
            } else {
                // Inside a generic struct, Name(T) self-instantiation → just @This()
                // (skip the type args since @This() is already the instantiated type)
                const is_self_generic = if (cg.generic_struct_name) |gsn|
                    c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, gsn)
                else
                    false;

                if (is_self_generic) {
                    try cg.emit("@This()");
                } else if (c.args.len == 0 and c.callee.* == .identifier) {
                    // Zero-arg call on a struct type → TypeName{} (not TypeName())
                    const callee_n = c.callee.identifier;
                    const is_struct_type = if (cg.decls) |d| d.structs.contains(callee_n) else false;
                    if (is_struct_type) {
                        try cg.emitFmt("{s}{{}}", .{callee_n});
                    } else {
                        try cg.generateExpr(c.callee);
                        try cg.emit("(");
                        try cg.fillDefaultArgs(c);
                        try cg.emit(")");
                    }
                } else {
                    // Positional arguments → regular function call
                    try cg.generateExpr(c.callee);
                    try cg.emit("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try cg.emit(", ");
                        try cg.generateExpr(arg);
                    }
                    // Fill in default args if caller passed fewer than the function expects
                    try cg.fillDefaultArgs(c);
                    try cg.emit(")");
                }
            }
        },
        .field_expr => |f| {
            // handle.value → handle.getValue() (thread Handle(T) — blocks + moves result)
            if (std.mem.eql(u8, f.field, "value") and
                cg.getTypeClass(f.object) == .thread_handle)
            {
                try cg.generateExpr(f.object);
                try cg.emit(".getValue()");
            // handle.done → handle.done() (thread Handle(T) — non-blocking check)
            } else if (std.mem.eql(u8, f.field, "done") and
                cg.getTypeClass(f.object) == .thread_handle)
            {
                try cg.generateExpr(f.object);
                try cg.emit(".done()");
            // ptr.value → ptr.* (safe Ptr(T) dereference)
            } else if (std.mem.eql(u8, f.field, "value") and
                cg.getTypeClass(f.object) == .safe_ptr)
            {
                try cg.generateExpr(f.object);
                try cg.emit(".*");
            // raw.value → raw[0] (RawPtr/VolatilePtr dereference)
            } else if (std.mem.eql(u8, f.field, "value") and
                cg.getTypeClass(f.object) == .raw_ptr)
            {
                try cg.generateExpr(f.object);
                try cg.emit("[0]");
            } else if (std.mem.eql(u8, f.field, K.Type.ERROR)) {
                // result.Error → @errorName(captured_err) (native Zig error name)
                if (f.object.* == .identifier) {
                    if (cg.error_capture_var.get(f.object.identifier)) |cap| {
                        try cg.emitFmt("@errorName({s})", .{cap});
                    } else {
                        // Fallback: use if/else pattern to capture the error value
                        // `catch |_e| expr` returns T (not []const u8), so we use the if/else form
                        try cg.emit("(if (");
                        try cg.generateExpr(f.object);
                        try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
                    }
                } else {
                    try cg.emit("(if (");
                    try cg.generateExpr(f.object);
                    try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
                }
            } else if (std.mem.eql(u8, f.field, "value") and
                (cg.getTypeClass(f.object) == .arbitrary_union or cg.getTypeClass(f.object) == .null_union or cg.getTypeClass(f.object) == .error_union))
            {
                // .value unwrap — emit native Zig unwrap based on union kind
                const obj_tc = cg.getTypeClass(f.object);
                if (obj_tc == .arbitrary_union) {
                    try cg.generateExpr(f.object);
                    // Use MIR union members to find the value type
                    if (f.object.* == .identifier) {
                        if (cg.getUnionMembers(f.object) orelse cg.getVarUnionMembers(f.object.identifier)) |members| {
                            for (members) |mem| {
                                const n = mem.name();
                                if (!std.mem.eql(u8, n, K.Type.ERROR) and !std.mem.eql(u8, n, K.Type.NULL)) {
                                    try cg.emitFmt("._{s}", .{n});
                                    break;
                                }
                            }
                        }
                    }
                } else if (obj_tc == .null_union) {
                    // (null | T) → ?T: result.value → result.?
                    try cg.generateExpr(f.object);
                    try cg.emit(".?");
                } else if (obj_tc == .error_union) {
                    // (Error | T) → anyerror!T: result.value → result catch unreachable
                    try cg.generateExpr(f.object);
                    try cg.emit(" catch unreachable");
                }
            } else if (cg.getTypeClass(f.object) == .arbitrary_union and
                codegen.isResultValueField(f.field, cg.decls))
            {
                // Arbitrary union field access: result.i32 → result._i32
                try cg.generateExpr(f.object);
                try cg.emitFmt("._{s}", .{f.field});
            } else if (codegen.isResultValueField(f.field, cg.decls)) {
                // Check if the object is a null union variable
                if (cg.getTypeClass(f.object) == .null_union) {
                    // (null | T) → ?T: result.User → result.?
                    try cg.generateExpr(f.object);
                    try cg.emit(".?");
                } else {
                    // (Error | T) → anyerror!T: result.value → result catch unreachable
                    try cg.generateExpr(f.object);
                    try cg.emit(" catch unreachable");
                }
            } else if (std.mem.eql(u8, f.field, "value") and f.object.* == .identifier) {
                // Fallback `.value` unwrap using narrowing info from `is Error` / `is null` checks.
                if (cg.error_narrowed.contains(f.object.identifier)) {
                    try cg.generateExpr(f.object);
                    try cg.emit(" catch unreachable");
                } else if (cg.null_narrowed.contains(f.object.identifier)) {
                    try cg.generateExpr(f.object);
                    try cg.emit(".?");
                } else {
                    try cg.generateExpr(f.object);
                    try cg.emit(".value");
                }
            } else {
                try cg.generateExpr(f.object);
                try cg.emitFmt(".{s}", .{f.field});
            }
        },
        .index_expr => |i| {
            try cg.generateExpr(i.object);
            try cg.emit("[");
            // Zig requires usize for indices — cast non-literal indices
            const index_is_literal = i.index.* == .int_literal;
            if (!index_is_literal) {
                try cg.emit("@intCast(");
                try cg.generateExpr(i.index);
                try cg.emit(")");
            } else {
                try cg.generateExpr(i.index);
            }
            try cg.emit("]");
        },
        .slice_expr => |s| {
            try cg.generateExpr(s.object);
            try cg.emit("[");
            const low_is_literal = s.low.* == .int_literal;
            if (!low_is_literal) {
                try cg.emit("@intCast(");
                try cg.generateExpr(s.low);
                try cg.emit(")");
            } else {
                try cg.generateExpr(s.low);
            }
            try cg.emit("..");
            const high_is_literal = s.high.* == .int_literal;
            if (!high_is_literal) {
                try cg.emit("@intCast(");
                try cg.generateExpr(s.high);
                try cg.emit(")");
            } else {
                try cg.generateExpr(s.high);
            }
            try cg.emit("]");
        },
        .compiler_func => |cf| {
            try cg.generateCompilerFunc(cf);
        },
        .range_expr => |r| {
            try cg.generateExpr(r.left);
            try cg.emit("..");
            try cg.generateExpr(r.right);
        },
        .collection_expr => |c| {
            try cg.generateCollectionExpr(c);
        },
        .struct_type => |fields| {
            try cg.emit("struct {\n");
            cg.indent += 1;
            for (fields) |f| {
                if (f.* == .field_decl) {
                    try cg.emitIndent();
                    try cg.emitFmt("{s}: {s},\n", .{
                        f.field_decl.name,
                        try cg.typeToZig(f.field_decl.type_annotation),
                    });
                }
            }
            cg.indent -= 1;
            try cg.emitIndent();
            try cg.emit("}");
        },
        else => {
            const msg = try std.fmt.allocPrint(cg.allocator, "internal codegen error: unhandled expression kind '{s}'", .{@tagName(node.*)});
            defer cg.allocator.free(msg);
            try cg.reporter.report(.{ .message = msg });
            return error.CompileError;
        },
    }
}
