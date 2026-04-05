// codegen_exprs.zig — MIR expression generators (core expressions, continuations, ranges, interpolation, loops)
// Contains: generateExprMir, generateCoercedExprMir, continue/range/interpolation/for/destruct generators (MIR path).
// Match generators, compiler-func generators, and arithmetic overflow helpers are in codegen_match.zig.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const declarations = @import("../declarations.zig");
const K = @import("../constants.zig");
const module = @import("../module.zig");
const types = @import("../types.zig");
const RT = types.ResolvedType;

const CodeGen = codegen.CodeGen;

// ============================================================
// UNION HELPERS (moved from codegen.zig per D-06)
// ============================================================

const TypeKind = enum { int, float, string, bool_ };

pub fn matchesKind(n: []const u8, kind: TypeKind) bool {
    const prim = types.Primitive.fromName(n) orelse return false;
    return switch (kind) {
        .int => prim.isInteger(),
        .float => prim.isFloat(),
        .string => prim == .string,
        .bool_ => prim == .bool,
    };
}

/// Search union members (MIR resolved types) for a type matching the given kind.
pub fn findMemberByKind(members_rt: ?[]const RT, kind: TypeKind) ?[]const u8 {
    const members = members_rt orelse return null;
    for (members) |m| {
        const n = m.name();
        if (matchesKind(n, kind)) return n;
    }
    return null;
}

/// MIR-path: wrap a MirNode expression in an arbitrary union tag.
pub fn generateArbitraryUnionWrappedExprMir(cg: *CodeGen, m: *mir.MirNode, members_rt: ?[]const RT) anyerror!void {
    if (m.coercion) |_| {
        try cg.generateCoercedExprMir(m);
        return;
    }
    const tag = inferArbitraryUnionTagMir(m, members_rt);
    if (tag) |t| {
        try cg.emitFmt(".{{ ._{s} = ", .{t});
        try cg.generateExprMir(m);
        try cg.emit(" }");
    } else {
        try cg.generateExprMir(m);
    }
}

/// Infer union tag from MirNode literal_kind.
pub fn inferArbitraryUnionTagMir(m: *const mir.MirNode, members_rt: ?[]const RT) ?[]const u8 {
    const lk = m.literal_kind orelse return null;
    return switch (lk) {
        .int => findMemberByKind(members_rt, .int) orelse "i32",
        .float => findMemberByKind(members_rt, .float) orelse "f32",
        .string => findMemberByKind(members_rt, .string) orelse "str",
        .bool_lit => findMemberByKind(members_rt, .bool_) orelse "bool",
        else => null,
    };
}

// ============================================================
// MIR EXPRESSION GENERATORS
// ============================================================

/// MIR-path expression dispatch — switches on MirKind, reads type info from MirNode.
/// All expression kinds handled via MirNode children — no AST-path fallthrough.
pub fn generateExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    switch (m.kind) {
        .binary => {
            const bin_op = m.op orelse .eq;
            const is_eq = bin_op == .eq;
            const is_ne = bin_op == .ne;
            // `x is T` desugared form: @type(x) == T
            const lhs_mir = m.lhs();
            if ((is_eq or is_ne) and
                lhs_mir.kind == .compiler_fn and
                std.mem.eql(u8, lhs_mir.name orelse "", K.Type.TYPE) and
                lhs_mir.children.len > 0)
            {
                // val_mir is the MirNode for the variable being type-checked
                const val_mir = lhs_mir.children[0];
                const cmp = if (is_eq) "==" else "!=";
                const rhs_mir = m.rhs();
                if (rhs_mir.literal_kind == .null_lit) {
                    // Record narrowing for type-name unwrap fallback
                    if (val_mir.kind == .identifier)
                        try cg.null_narrowed.put(cg.allocator, val_mir.name orelse "", {});
                    // (null | T) → ?T: x is null → x == null
                    try cg.emit("(");
                    try cg.generateExprMir(val_mir);
                    try cg.emitFmt(" {s} null)", .{cmp});
                    return;
                }
                if (rhs_mir.kind == .identifier) {
                    const rhs = rhs_mir.name orelse "";
                    if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                        // Record narrowing for type-name unwrap fallback
                        if (val_mir.kind == .identifier)
                            try cg.error_narrowed.put(cg.allocator, val_mir.name orelse "", {});
                        // (Error | T) → anyerror!T: x is Error → if/else pattern
                        const t_val = if (is_eq) "false" else "true";
                        const f_val = if (is_eq) "true" else "false";
                        try cg.emit("(if (");
                        try cg.generateExprMir(val_mir);
                        try cg.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
                        return;
                    }
                    if (lhs_mir.type_class == .arbitrary_union or
                        val_mir.type_class == .arbitrary_union)
                    {
                        try cg.emit("(");
                        try cg.generateExprMir(val_mir);
                        try cg.emitFmt(" {s} ._{s})", .{ cmp, rhs });
                        return;
                    }
                    const zig_rhs = types.Primitive.nameToZig(rhs);
                    try cg.emit("(@TypeOf(");
                    try cg.generateExprMir(val_mir);
                    try cg.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                    return;
                }
                // Qualified type check: `val is module.Type` per D-07
                if (rhs_mir.kind == .field_access) {
                    // If left side is a tagged union, emit union tag comparison
                    if (lhs_mir.type_class == .arbitrary_union or
                        val_mir.type_class == .arbitrary_union)
                    {
                        const type_name = rhs_mir.name orelse "";
                        try cg.emit("(");
                        try cg.generateExprMir(val_mir);
                        try cg.emitFmt(" {s} ._{s})", .{ cmp, type_name });
                        return;
                    }
                    // Non-union: comptime type check via @TypeOf
                    try cg.emit("(@TypeOf(");
                    try cg.generateExprMir(val_mir);
                    try cg.emitFmt(") {s} ", .{cmp});
                    try cg.emitTypeMirPath(rhs_mir);
                    try cg.emit(")");
                    return;
                }
            }
            // Vector operand detection for arithmetic
            const lhs_is_vec = mirIsVector(m.lhs());
            const rhs_is_vec = mirIsVector(m.rhs());
            const any_vec = lhs_is_vec or rhs_is_vec;

            // Division and modulo — use native / % for floats, @divTrunc/@mod for integers
            // Skip for vectors — Zig @Vector supports native / and %
            const is_float_op = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
            if (!any_vec and bin_op == .div) {
                if (is_float_op) {
                    try cg.emit("(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(" / ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(")");
                } else {
                    try cg.emit("@divTrunc(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(", ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(")");
                }
            } else if (!any_vec and bin_op == .mod) {
                if (is_float_op) {
                    try cg.emit("(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(" % ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(")");
                } else {
                    try cg.emit("@mod(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit(", ");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit(")");
                }
            } else if (any_vec and lhs_is_vec != rhs_is_vec) {
                // Vector-scalar broadcast: wrap scalar side with @splat
                const op = codegen.opToZig(bin_op);
                try cg.emit("(");
                if (lhs_is_vec) {
                    try cg.generateExprMir(m.lhs());
                    try cg.emitFmt(" {s} ", .{op});
                    try cg.emit("@as(@TypeOf(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit("), @splat(");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit("))");
                } else {
                    try cg.emit("@as(@TypeOf(");
                    try cg.generateExprMir(m.rhs());
                    try cg.emit("), @splat(");
                    try cg.generateExprMir(m.lhs());
                    try cg.emit("))");
                    try cg.emitFmt(" {s} ", .{op});
                    try cg.generateExprMir(m.rhs());
                }
                try cg.emit(")");
            } else {
                const op = codegen.opToZig(bin_op);
                try cg.emit("(");
                try cg.generateExprMir(m.lhs());
                try cg.emitFmt(" {s} ", .{op});
                try cg.generateExprMir(m.rhs());
                try cg.emit(")");
            }
        },
        .call => {
            const callee_mir = m.getCallee();
            const callee_is_ident = callee_mir.kind == .identifier;
            const callee_name = callee_mir.name orelse "";
            const call_args = m.callArgs();
            // Clean call generation
            const call_arg_names = m.arg_names;
            if (call_arg_names != null and call_arg_names.?.len > 0) {
                const an = call_arg_names.?;
                try cg.generateExprMir(callee_mir);
                try cg.emit("{ ");
                for (call_args, 0..) |arg, i| {
                    if (i > 0) try cg.emit(", ");
                    if (i < an.len and an[i].len > 0) {
                        try cg.emitFmt(".{s} = ", .{an[i]});
                    }
                    try cg.generateExprMir(arg);
                }
                try cg.emit(" }");
            } else {
                // Inside a generic struct, Name(T) self-instantiation → just @This()
                const is_self_generic_mir = if (cg.generic_struct_name) |gsn|
                    callee_is_ident and std.mem.eql(u8, callee_name, gsn)
                else
                    false;

                if (is_self_generic_mir) {
                    try cg.emit("@This()");
                } else if (call_args.len == 0 and callee_is_ident) {
                    // Zero-arg call on a struct type → TypeName{} (not TypeName())
                    const is_struct_type = if (cg.decls) |d| d.structs.contains(callee_name) else false;
                    if (is_struct_type) {
                        try cg.emitFmt("{s}{{}}", .{callee_name});
                    } else {
                        try cg.generateExprMir(callee_mir);
                        try cg.emit("(");
                        try cg.fillDefaultArgsMir(callee_mir, 0);
                        try cg.emit(")");
                    }
                } else if (call_args.len == 0 and callee_mir.kind == .call) {
                    // Zero-arg call on a generic type expression: Counter2(i32)() → Counter2(i32){}
                    // The callee is itself a call (a compt func returning type), so construct with {}
                    try cg.generateExprMir(callee_mir);
                    try cg.emit("{}");
                } else {
                    try cg.generateExprMir(callee_mir);
                    try cg.emit("(");
                    for (call_args, 0..) |arg, i| {
                        if (i > 0) try cg.emit(", ");
                        // Const auto-borrow: if param is promoted to *const T and
                        // the arg has no coercion annotation (var caller), emit &arg.
                        // Const callers are handled by value_to_const_ref in generateCoercedExprMir.
                        if (arg.coercion == null and cg.isPromotedParam(callee_name, i)) {
                            try cg.emit("&");
                            try cg.generateExprMir(arg);
                        } else {
                            try cg.generateCoercedExprMir(arg);
                        }
                    }
                    try cg.fillDefaultArgsMir(callee_mir, call_args.len);
                    try cg.emit(")");
                }
            }
        },
        .field_access => {
            const field = m.name orelse "";
            const obj_mir = m.children[0];
            const obj_tc = obj_mir.type_class;
            if (std.mem.eql(u8, field, K.Type.ERROR)) {
                // result.Error → @errorName(err) (native Zig error)
                try cg.emit("(if (");
                try cg.generateExprMir(obj_mir);
                try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
            } else if (codegen.isResultValueField(field, cg.decls)) {
                // Resolve effective type class — fall back to var_types, then
                // narrowing maps when MIR node annotation is .plain
                // (compiler-generated exprs like @overflow, cross-module calls).
                const eff_tc = if (obj_tc != .plain) obj_tc else blk: {
                    const obj_name = if (obj_mir.kind == .identifier) (obj_mir.name orelse "") else "";
                    if (obj_name.len > 0) {
                        if (cg.var_types) |vt| {
                            if (vt.get(obj_name)) |info| {
                                if (info.type_class != .plain) break :blk info.type_class;
                            }
                        }
                        // Narrowing fallback — is Error / is null / throw tracked the variable
                        if (cg.error_narrowed.contains(obj_name)) break :blk mir.TypeClass.error_union;
                        if (cg.null_narrowed.contains(obj_name)) break :blk mir.TypeClass.null_union;
                    }
                    break :blk obj_tc;
                };
                if (eff_tc == .null_error_union) {
                    try cg.emit("(");
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".? catch unreachable)");
                } else if (eff_tc == .error_union) {
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(" catch unreachable");
                } else if (eff_tc == .null_union) {
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".?");
                } else if (eff_tc == .arbitrary_union) {
                    try cg.generateExprMir(obj_mir);
                    try cg.emitFmt("._{s}", .{field});
                } else {
                    try cg.generateExprMir(obj_mir);
                    try cg.emitFmt(".{s}", .{field});
                }
            } else {
                try cg.generateExprMir(obj_mir);
                try cg.emitFmt(".{s}", .{field});
            }
        },
        .literal => {
            const lk = m.literal_kind orelse return;
            switch (lk) {
                .int, .float, .string => try cg.emit(m.literal orelse return),
                .bool_lit => try cg.emit(if (m.bool_val) "true" else "false"),
                .null_lit => try cg.emit("null"),
                .error_lit => {
                    // Error("message") → error.sanitized_name (native Zig error)
                    const msg = m.literal orelse return;
                    const name = try cg.sanitizeErrorName(msg);
                    try cg.emitFmt("error.{s}", .{name});
                },
            }
        },
        .identifier => {
            const name = m.name orelse return;
            if (cg.isEnumVariant(name)) {
                try cg.emitFmt(".{s}", .{name});
            } else if (cg.generic_struct_name) |gsn| {
                if (std.mem.eql(u8, name, gsn)) {
                    try cg.emit("@This()");
                } else {
                    try cg.emit(types.Primitive.nameToZig(name));
                }
            } else {
                try cg.emit(types.Primitive.nameToZig(name));
            }
        },
        .unary => {
            const op = codegen.opToZig(m.op orelse return);
            try cg.emitFmt("{s}(", .{op});
            try cg.generateExprMir(m.children[0]);
            try cg.emit(")");
        },
        .index => {
            try cg.generateExprMir(m.children[0]);
            try cg.emit("[");
            const index_is_literal = m.children[1].literal_kind == .int;
            if (!index_is_literal) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(m.children[1]);
                try cg.emit(")");
            } else {
                try cg.generateExprMir(m.children[1]);
            }
            try cg.emit("]");
        },
        .slice => {
            try cg.generateExprMir(m.children[0]);
            try cg.emit("[");
            if (m.children[1].literal_kind != .int) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(m.children[1]);
                try cg.emit(")");
            } else {
                try cg.generateExprMir(m.children[1]);
            }
            try cg.emit("..");
            if (m.children[2].literal_kind != .int) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(m.children[2]);
                try cg.emit(")");
            } else {
                try cg.generateExprMir(m.children[2]);
            }
            try cg.emit("]");
        },
        .borrow => {
            try cg.emit("&");
            try cg.generateExprMir(m.children[0]);
        },
        .interpolation => {
            // If the MIR lowerer hoisted this to a temp var, emit just the var name
            if (m.injected_name) |var_name| {
                try cg.emit(var_name);
            } else if (m.interp_parts) |parts| {
                try cg.generateInterpolatedStringMir(parts, m.children);
            }
        },
        .compiler_fn => try cg.generateCompilerFuncMir(m),
        .array_lit => {
            try cg.emit(".{");
            for (m.children, 0..) |child, i| {
                if (i > 0) try cg.emit(", ");
                try cg.generateExprMir(child);
            }
            try cg.emit("}");
        },
        .tuple_lit => {
            try cg.emit(".{");
            if (m.is_named_tuple) {
                const fnames = m.field_names orelse &.{};
                for (m.children, 0..) |child, i| {
                    if (i > 0) try cg.emit(", ");
                    if (i < fnames.len) try cg.emitFmt(".{s} = ", .{fnames[i]});
                    try cg.generateExprMir(child);
                }
            } else {
                for (m.children, 0..) |child, i| {
                    if (i > 0) try cg.emit(", ");
                    try cg.generateExprMir(child);
                }
            }
            try cg.emit("}");
        },
        .type_expr => {
            if (m.ast.* == .struct_type) {
                // Anonymous struct — emit full body (fields, methods, constants) via MIR children
                try cg.emit("struct {\n");
                cg.indent += 1;
                // Set struct context so Self → @This() inside methods
                const prev_gsn = cg.generic_struct_name;
                const prev_in_struct = cg.in_struct;
                cg.generic_struct_name = "_anon";
                cg.in_struct = true;
                defer cg.generic_struct_name = prev_gsn;
                defer cg.in_struct = prev_in_struct;
                try cg.emitStructBody(m.children);
                cg.indent -= 1;
                try cg.emitIndent();
                try cg.emit("}");
            } else {
                try cg.emit(try cg.typeToZig(m.ast));
            }
        },
        .passthrough => {}, // architectural nodes (metadata, module_decl) — no codegen
        else => {},
    }
}

/// MIR-path coerced expression — reads coercion from MirNode directly.
pub fn generateCoercedExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const coercion = m.coercion orelse return cg.generateExprMir(m);
    switch (coercion) {
        .array_to_slice => {
            try cg.emit("&");
            try cg.generateExprMir(m);
        },
        // Native ?T and anyerror!T — Zig handles coercion automatically
        .null_wrap, .error_wrap => {
            try cg.generateExprMir(m);
        },
        .arbitrary_union_wrap => {
            if (m.coerce_tag) |tag| {
                try cg.emitFmt(".{{ ._{s} = ", .{tag});
                try cg.generateExprMir(m);
                try cg.emit(" }");
            } else {
                try cg.generateExprMir(m);
            }
        },
        .optional_unwrap => {
            // Native ?T: unwrap → .?
            try cg.generateExprMir(m);
            try cg.emit(".?");
        },
        .value_to_const_ref => {
            // T → *const T: take address for const & parameter passing
            // Skip extra & if the expression is already an explicit borrow (const &x)
            if (m.kind == .borrow) {
                try cg.generateExprMir(m);
            } else {
                try cg.emit("&");
                try cg.generateExprMir(m);
            }
        },
    }
}

/// Check if a MirNode represents a string expression (via type_class or literal_kind).
pub fn mirIsString(m: *const mir.MirNode) bool {
    return m.type_class == .string or m.literal_kind == .string or m.kind == .interpolation;
}

/// Check if a MirNode represents a SIMD Vector type.
pub fn mirIsVector(m: *const mir.MirNode) bool {
    if (m.resolved_type == .generic) {
        return std.mem.eql(u8, m.resolved_type.generic.name, K.Type.VECTOR);
    }
    return false;
}

// Generate a while continue expression — same as assignment but no trailing semicolon.
/// MIR-path continue expression for while loops.
pub fn generateContinueExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.kind == .assignment) {
        const assign_op = m.op orelse .assign;
        if (assign_op == .div_assign) {
            const is_float_cont = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
            try cg.generateExprMir(m.lhs());
            if (is_float_cont) {
                try cg.emit(" = (");
                try cg.generateExprMir(m.lhs());
                try cg.emit(" / ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(")");
            } else {
                try cg.emit(" = @divTrunc(");
                try cg.generateExprMir(m.lhs());
                try cg.emit(", ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(")");
            }
        } else {
            try cg.generateExprMir(m.lhs());
            try cg.emitFmt(" {s} ", .{assign_op.toZig()});
            try cg.generateExprMir(m.rhs());
        }
    } else {
        try cg.generateExprMir(m);
    }
}

/// MIR-path range expression for for-loops.
pub fn writeRangeExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const left_is_literal = m.lhs().literal_kind == .int;
    if (left_is_literal) {
        try cg.generateExprMir(m.lhs());
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(m.lhs());
        try cg.emit(")");
    }
    try cg.emit("..");
    // Open-ended range (0..) — rhs is void sentinel (type_named = "void"), emit nothing after ..
    if (m.rhs().ast.* == .type_named) return;
    const right_is_literal = m.rhs().literal_kind == .int;
    if (right_is_literal) {
        try cg.generateExprMir(m.rhs());
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(m.rhs());
        try cg.emit(")");
    }
}

/// Generate string interpolation using std.fmt.allocPrint.
/// Hoists the allocPrint call to a temp variable in pre_stmts, then emits only the
/// MIR-path for loop codegen — Zig-style multi-object for.
/// Each iterable in the header maps positionally to a capture.
/// Range iterables (0.., a..b) get @intCast wrapping on their captures.
pub fn generateForMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const caps = m.captures orelse &.{};
    const iters = m.iterables();

    // Determine which iterables are ranges (need @intCast on their capture)
    var needs_cast = false;
    for (iters) |iter_m| {
        if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
            needs_cast = true;
            break;
        }
    }

    // Tuple capture — struct field destructuring on first iterable
    if (m.is_tuple_capture and caps.len > 0) {
        if (m.is_compt) try cg.emit("inline ");
        try cg.emit("for (");
        // First iterable: the struct slice
        try cg.generateExprMir(iters[0]);
        // Additional iterables (e.g., 0..)
        for (iters[1..]) |iter_m| {
            try cg.emit(", ");
            if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
                try cg.writeRangeExprMir(iter_m);
            } else {
                try cg.generateExprMir(iter_m);
            }
        }
        try cg.emit(") |_orhon_entry");
        // Extra captures beyond struct fields (e.g., index from 0..)
        const field_names = resolveStructFieldNames(iters[0].resolved_type, cg.decls);
        const n_fields = if (field_names) |f| f.len else caps.len;
        for (caps[n_fields..]) |cap| {
            // Range captures need intCast wrapper
            try cg.emitFmt(", _orhon_{s}", .{cap});
        }
        try cg.emit("| {\n");
        cg.indent += 1;
        // Bind struct fields to capture names
        for (caps[0..n_fields], 0..) |cap, i| {
            try cg.emitIndent();
            if (field_names) |fields| {
                if (i < fields.len) {
                    try cg.emitFmt("const {s} = _orhon_entry.{s};\n", .{ cap, fields[i].name });
                    continue;
                }
            }
            try cg.emitFmt("const {s} = _orhon_entry.@\"{d}\";\n", .{ cap, i });
        }
        // intCast extra captures (range iterables)
        for (caps[n_fields..], iters[1..]) |cap, iter_m| {
            if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
                try cg.emitIndent();
                try cg.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ cap, cap });
            }
        }
        for (m.body().children) |child| {
            try cg.emitIndent();
            try cg.generateStatementMir(child);
            try cg.emit("\n");
        }
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("}");
        return;
    }

    // Non-tuple: each iterable maps 1:1 to a capture
    if (m.is_compt) try cg.emit("inline ");
    try cg.emit("for (");
    for (iters, 0..) |iter_m, i| {
        if (i > 0) try cg.emit(", ");
        if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
            try cg.writeRangeExprMir(iter_m);
        } else {
            try cg.generateExprMir(iter_m);
        }
    }
    try cg.emit(") |");
    for (caps, 0..) |cap, i| {
        if (i > 0) try cg.emit(", ");
        const iter_m = if (i < iters.len) iters[i] else null;
        const is_range = if (iter_m) |im| (im.kind == .binary and (im.op orelse .assign) == .range) else false;
        if (is_range) {
            try cg.emitFmt("_orhon_{s}", .{cap});
        } else {
            try cg.emit(cap);
        }
    }
    if (needs_cast) {
        try cg.emit("| {\n");
        cg.indent += 1;
        for (caps, 0..) |cap, i| {
            const iter_m = if (i < iters.len) iters[i] else null;
            const is_range = if (iter_m) |im| (im.kind == .binary and (im.op orelse .assign) == .range) else false;
            if (is_range) {
                try cg.emitIndent();
                try cg.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ cap, cap });
            }
        }
        for (m.body().children) |child| {
            try cg.emitIndent();
            try cg.generateStatementMir(child);
            try cg.emit("\n");
        }
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("}");
    } else {
        try cg.emit("| ");
        try cg.generateBlockMir(m.body());
    }
}

/// Resolve struct field signatures from a slice/array element type via declarations.
fn resolveStructFieldNames(iter_type: RT, decls: ?*declarations.DeclTable) ?[]const declarations.FieldSig {
    const elem_type = switch (iter_type) {
        .slice => |s| s.*,
        .array => |a| a.elem.*,
        else => return null,
    };
    const type_name = switch (elem_type) {
        .named => |n| n,
        else => return null,
    };
    const d = decls orelse return null;
    const sig = d.structs.get(type_name) orelse return null;
    return sig.fields;
}

/// MIR-path destructuring codegen.
pub fn generateDestructMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const d_names = m.names orelse &.{};
    const decl_keyword: []const u8 = if (m.is_const) "const" else "var";
    const val_m = m.value();
    // @splitAt destructuring: const left, right = @splitAt(arr, n)
    if (d_names.len == 2 and val_m.kind == .compiler_fn) {
        const fn_name = val_m.name orelse "";
        if (std.mem.eql(u8, fn_name, "splitAt") and val_m.children.len == 2) {
            const destruct_idx = cg.destruct_counter;
            cg.destruct_counter += 1;
            try cg.emitFmt("var _orhon_s{d}: usize = @intCast(", .{destruct_idx});
            try cg.generateExprMir(val_m.children[1]);
            try cg.emit(");\n");
            try cg.emitIndent();
            try cg.emitFmt("_ = &_orhon_s{d};\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[0] });
            try cg.generateExprMir(val_m.children[0]);
            try cg.emitFmt("[0.._orhon_s{d}];\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[1] });
            try cg.generateExprMir(val_m.children[0]);
            try cg.emitFmt("[_orhon_s{d}..];", .{destruct_idx});
            return;
        }
    }
    // Normal tuple destructuring
    const idx = cg.destruct_counter;
    cg.destruct_counter += 1;
    try cg.emitFmt("const _orhon_d{d} = ", .{idx});
    try cg.generateExprMir(val_m);
    try cg.emit(";");
    for (d_names) |name| {
        try cg.emit("\n");
        try cg.emitIndent();
        try cg.emitFmt("{s} {s} = _orhon_d{d}.{s};", .{ decl_keyword, name, idx, name });
    }
}

// ── Tests ──────────────────────────────────────────────────

test "matchesKind" {
    try std.testing.expect(matchesKind("i32", .int));
    try std.testing.expect(matchesKind("u64", .int));
    try std.testing.expect(matchesKind("f64", .float));
    try std.testing.expect(matchesKind("f32", .float));
    try std.testing.expect(matchesKind("str", .string));
    try std.testing.expect(matchesKind("bool", .bool_));
    // Negative cases
    try std.testing.expect(!matchesKind("i32", .float));
    try std.testing.expect(!matchesKind("str", .int));
    try std.testing.expect(!matchesKind("bool", .string));
    try std.testing.expect(!matchesKind("UnknownType", .int));
}

test "findMemberByKind" {
    const members = &[_]RT{ RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    try std.testing.expectEqualStrings("i32", findMemberByKind(members, .int).?);
    try std.testing.expectEqualStrings("str", findMemberByKind(members, .string).?);
    try std.testing.expect(findMemberByKind(members, .float) == null);
    try std.testing.expect(findMemberByKind(null, .int) == null);
}

