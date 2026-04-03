// codegen_exprs.zig — MIR expression generators (core expressions, continuations, ranges, interpolation, loops)
// Contains: generateExprMir, generateCoercedExprMir, continue/range/interpolation/for/destruct generators (MIR path).
// Match generators, compiler-func generators, and arithmetic overflow helpers are in codegen_match.zig.
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
// UNION HELPERS (moved from codegen.zig per D-06)
// ============================================================

/// Infer which union tag a value belongs to based on its literal type.
pub fn inferArbitraryUnionTag(value: *parser.Node, members_rt: ?[]const RT) ?[]const u8 {
    return switch (value.*) {
        .int_literal => findMemberByKind(members_rt, .int) orelse "i32",
        .float_literal => findMemberByKind(members_rt, .float) orelse "f32",
        .string_literal => findMemberByKind(members_rt, .string) orelse "str",
        .bool_literal => findMemberByKind(members_rt, .bool_) orelse "bool",
        else => null,
    };
}

const TypeKind = enum { int, float, string, bool_ };

pub fn matchesKind(n: []const u8, kind: TypeKind) bool {
    return switch (kind) {
        .int => std.mem.eql(u8, n, "i8") or std.mem.eql(u8, n, "i16") or
            std.mem.eql(u8, n, "i32") or std.mem.eql(u8, n, "i64") or
            std.mem.eql(u8, n, "u8") or std.mem.eql(u8, n, "u16") or
            std.mem.eql(u8, n, "u32") or std.mem.eql(u8, n, "u64") or
            std.mem.eql(u8, n, "usize"),
        .float => std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "f64"),
        .string => std.mem.eql(u8, n, "str"),
        .bool_ => std.mem.eql(u8, n, "bool"),
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
                    // Record narrowing for `.value` resolution
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
                        // Record narrowing for `.value` resolution
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
                    const zig_rhs = builtins.primitiveToZig(rhs);
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

            // Division → @divTrunc (skip for vectors — Zig @Vector supports native / and %)
            if (!any_vec and bin_op == .div) {
                try cg.emit("@divTrunc(");
                try cg.generateExprMir(m.lhs());
                try cg.emit(", ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(")");
            } else if (!any_vec and bin_op == .mod) {
                try cg.emit("@mod(");
                try cg.generateExprMir(m.lhs());
                try cg.emit(", ");
                try cg.generateExprMir(m.rhs());
                try cg.emit(")");
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
            const callee_is_field = callee_mir.kind == .field_access;
            const callee_name = callee_mir.name orelse "";
            const call_args = m.callArgs();
            // Handle(value) → just emit the value
            if (callee_is_ident and std.mem.eql(u8, callee_name, builtins.BT.HANDLE) and call_args.len == 1) {
                try cg.generateExprMir(call_args[0]);
                return;
            }
            // Bitfield constructor
            if (callee_is_ident) {
                if (cg.decls) |d| {
                    if (d.bitfields.get(callee_name)) |_| {
                        try cg.emitFmt("{s}{{ .value = ", .{callee_name});
                        if (call_args.len == 0) {
                            try cg.emit("0");
                        } else {
                            for (call_args, 0..) |arg, i| {
                                if (i > 0) try cg.emit(" | ");
                                if (arg.kind == .identifier) {
                                    try cg.emitFmt("{s}.{s}", .{ callee_name, arg.name orelse "" });
                                } else {
                                    try cg.generateExprMir(arg);
                                }
                            }
                        }
                        try cg.emit(" }");
                        return;
                    }
                }
            }
            // Bitfield method: p.has(Read) → p.has(Permissions.Read)
            if (callee_is_field) {
                const obj_mir = callee_mir.children[0]; // field_access.children[0] = object
                if (mirGetBitfieldName(obj_mir, cg.decls)) |bf_name| {
                    try cg.generateExprMir(callee_mir);
                    try cg.emit("(");
                    for (call_args, 0..) |arg, i| {
                        if (i > 0) try cg.emit(", ");
                        if (arg.kind == .identifier) {
                            try cg.emitFmt("{s}.{s}", .{ bf_name, arg.name orelse "" });
                        } else {
                            try cg.generateExprMir(arg);
                        }
                    }
                    try cg.emit(")");
                    return;
                }
            }
            // Collection constructor: List(T).new(), Map(K,V).new(), Set(T).new() → .{}
            // The collection_expr builder is transparent — List(i32) reduces to the
            // element type_primitive (i32) in the AST. So the callee's object has
            // kind == .type_expr (a type in expression position), not .collection.
            // Calling .new() with no args on a type in expression position always
            // means "zero-initialize" — safe because user struct names parse as
            // .identifier (not .type_expr), so there's no false-positive risk.
            if (callee_is_field) {
                const method = callee_mir.name orelse "";
                if (std.mem.eql(u8, method, "new")) {
                    if (callee_mir.children.len > 0) {
                        const obj_mir = callee_mir.children[0];
                        if (obj_mir.kind == .type_expr or obj_mir.kind == .collection) {
                            if (call_args.len == 0) {
                                try cg.emit(".{}");
                                return;
                            } else if (call_args.len == 1) {
                                try cg.emit(".{ .alloc = ");
                                try cg.generateExprMir(call_args[0]);
                                try cg.emit(" }");
                                return;
                            }
                        }
                    }
                }
            }
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
            // handle.value → handle.getValue()
            if (std.mem.eql(u8, field, "value") and obj_tc == .thread_handle) {
                try cg.generateExprMir(obj_mir);
                try cg.emit(".getValue()");
            } else if (std.mem.eql(u8, field, "done") and obj_tc == .thread_handle) {
                try cg.generateExprMir(obj_mir);
                try cg.emit(".done()");
            } else if (std.mem.eql(u8, field, "value") and obj_tc == .safe_ptr) {
                try cg.generateExprMir(obj_mir);
                try cg.emit(".*");
            } else if (std.mem.eql(u8, field, "value") and obj_tc == .raw_ptr) {
                try cg.generateExprMir(obj_mir);
                try cg.emit("[0]");
            } else if (std.mem.eql(u8, field, K.Type.ERROR)) {
                // result.Error → @errorName(captured_err) (native Zig error)
                if (obj_mir.kind == .identifier) {
                    const obj_name = obj_mir.name orelse "";
                    if (cg.error_capture_var.get(obj_name)) |cap| {
                        try cg.emitFmt("@errorName({s})", .{cap});
                    } else {
                        // Use if/else pattern — `catch |_e| expr` returns T, not []const u8
                        try cg.emit("(if (");
                        try cg.generateExprMir(obj_mir);
                        try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
                    }
                } else {
                    try cg.emit("(if (");
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
                }
            } else if (std.mem.eql(u8, field, "value") and
                (obj_tc == .arbitrary_union or obj_tc == .null_union or obj_tc == .error_union))
            {
                if (obj_tc == .arbitrary_union) {
                    try cg.generateExprMir(obj_mir);
                    if (obj_mir.kind == .identifier) {
                        if (obj_mir.narrowed_to) |narrowed| {
                            try cg.emitFmt("._{s}", .{narrowed});
                        } else {
                            const obj_name = obj_mir.name orelse "";
                            const members_rt = if (obj_mir.resolved_type == .union_type) obj_mir.resolved_type.union_type else
                                if (cg.getVarUnionMembers(obj_name)) |m2| m2 else null;
                            if (members_rt) |members| {
                                for (members) |mem| {
                                    const n = mem.name();
                                    if (!std.mem.eql(u8, n, K.Type.ERROR) and !std.mem.eql(u8, n, K.Type.NULL)) {
                                        try cg.emitFmt("._{s}", .{n});
                                        break;
                                    }
                                }
                            }
                        }
                    }
                } else if (obj_tc == .null_union) {
                    // (null | T) → ?T: result.value → result.?
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".?");
                } else if (obj_tc == .error_union) {
                    // (Error | T) → anyerror!T: result.value → result catch unreachable
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(" catch unreachable");
                }
            } else if (obj_tc == .arbitrary_union and codegen.isResultValueField(field, cg.decls)) {
                try cg.generateExprMir(obj_mir);
                try cg.emitFmt("._{s}", .{field});
            } else if (codegen.isResultValueField(field, cg.decls)) {
                if (obj_tc == .null_union) {
                    // (null | T) → ?T: result.value → result.?
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".?");
                } else {
                    // (Error | T) → anyerror!T: result.value → result catch unreachable
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(" catch unreachable");
                }
            } else if (std.mem.eql(u8, field, "value") and obj_mir.kind == .identifier) {
                // Fallback `.value` unwrap using narrowing info
                const obj_name = obj_mir.name orelse "";
                if (cg.error_narrowed.contains(obj_name)) {
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(" catch unreachable");
                } else if (cg.null_narrowed.contains(obj_name)) {
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".?");
                } else {
                    try cg.generateExprMir(obj_mir);
                    try cg.emit(".value");
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
                    try cg.emit(builtins.primitiveToZig(name));
                }
            } else {
                try cg.emit(builtins.primitiveToZig(name));
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
        .collection => try cg.generateCollectionExprMir(m),
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
            // Type nodes are structural — emit via typeToZig, except struct_type which needs field-by-field emission
            if (m.ast.* == .struct_type) {
                try cg.emit("struct {\n");
                cg.indent += 1;
                for (m.ast.struct_type) |f| {
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
        return std.mem.eql(u8, m.resolved_type.generic.name, builtins.BT.VECTOR);
    }
    return false;
}

/// Check if a MirNode is typed as a bitfield, return the bitfield name.
pub fn mirGetBitfieldName(m: *const mir.MirNode, decls_opt: ?*declarations.DeclTable) ?[]const u8 {
    const d = decls_opt orelse return null;
    if (m.resolved_type == .named) {
        if (d.bitfields.contains(m.resolved_type.named)) return m.resolved_type.named;
    }
    return null;
}

// Generate a while continue expression — same as assignment but no trailing semicolon.
/// MIR-path continue expression for while loops.
pub fn generateContinueExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.kind == .assignment) {
        const assign_op = m.op orelse .assign;
        if (assign_op == .div_assign) {
            try cg.generateExprMir(m.lhs());
            try cg.emit(" = @divTrunc(");
            try cg.generateExprMir(m.lhs());
            try cg.emit(", ");
            try cg.generateExprMir(m.rhs());
            try cg.emit(")");
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
/// temp var name as the expression — avoiding a memory leak by pairing with defer free.
/// "hello @{name}, value @{x}!" →
/// MIR-path for loop codegen.
pub fn generateForMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const caps = m.captures orelse &.{};
    const idx_var = m.index_var;
    const iter_m = m.iterable();
    const is_range = iter_m.kind == .binary and (iter_m.op orelse .assign) == .range;
    const needs_cast = is_range or idx_var != null;
    if (m.is_compt) try cg.emit("inline ");
    try cg.emit("for (");
    if (is_range) {
        try cg.writeRangeExprMir(iter_m);
    } else {
        try cg.generateExprMir(iter_m);
    }
    if (idx_var != null) try cg.emit(", 0..");
    try cg.emit(") |");
    if (caps.len > 0) {
        if (is_range) {
            try cg.emitFmt("_orhon_{s}", .{caps[0]});
        } else {
            try cg.emit(caps[0]);
        }
    }
    if (idx_var) |idx| {
        try cg.emitFmt(", _orhon_{s}", .{idx});
    }
    if (needs_cast) {
        try cg.emit("| {\n");
        cg.indent += 1;
        if (is_range and caps.len > 0) {
            try cg.emitIndent();
            try cg.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ caps[0], caps[0] });
        }
        if (idx_var) |idx| {
            try cg.emitIndent();
            try cg.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ idx, idx });
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

