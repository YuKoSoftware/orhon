// codegen_exprs.zig — MIR expression generators (core expressions, continuations, ranges, interpolation, loops)
// Contains: generateExprMir (dispatch hub), generateBinaryMir, generateCallMir, generateFieldAccessMir,
//           generateIdentifierMir, generateCoercedExprMir,
//           continue/range/interpolation/for/destruct generators (MIR path).
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
const mir_store_mod = @import("../mir_store.zig");
const mir_typed = @import("../mir_typed.zig");
const match_impl = @import("codegen_match.zig");
const decls_impl = @import("codegen_decls.zig");

const CodeGen = codegen.CodeGen;
const MirNodeIndex = mir_store_mod.MirNodeIndex;
const MirStore = mir_store_mod.MirStore;
const StringIndex = mir_typed.StringIndex;

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
pub fn generateArbitraryUnionWrappedExprMir(cg: *CodeGen, idx: MirNodeIndex, members_rt: ?[]const RT) anyerror!void {
    _ = members_rt;
    const entry = cg.mir_store.?.getNode(idx);
    if (entry.coercion_kind != 0) {
        try cg.generateCoercedExprMir(idx);
        return;
    }
    try cg.generateExprMir(idx);
}

// ============================================================
// MIR EXPRESSION GENERATORS
// ============================================================

/// MIR-path expression dispatch — unconditional MirStore path.
pub fn generateExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
        const entry = store.getNode(idx);
        switch (entry.tag) {
            .binary => try generateBinaryMir(cg, store, idx),
            .call => try generateCallMir(cg, store, idx),
            .field_access => try generateFieldAccessMir(cg, store, idx),
            .literal => {
                const rec = mir_typed.Literal.unpack(store, idx);
                const lk: mir.LiteralKind = @enumFromInt(rec.kind);
                switch (lk) {
                    .int, .float, .string => {
                        if (rec.text != .none) {
                            try cg.emit(store.strings.get(rec.text));
                        }
                    },
                    .bool_lit => try cg.emit(if (rec.bool_val != 0) "true" else "false"),
                    .null_lit => try cg.emit("null"),
                    .error_lit => {
                        if (rec.text != .none) {
                            const msg = store.strings.get(rec.text);
                            const name = try cg.sanitizeErrorName(msg);
                            try cg.emitFmt("error.{s}", .{name});
                        }
                    },
                }
            },
            .identifier => try generateIdentifierMir(cg, store, idx),
            .unary => {
                const rec = mir_typed.Unary.unpack(store, idx);
                const op: parser.Operator = @enumFromInt(rec.op);
                const op_str = codegen.opToZig(op);
                try cg.emitFmt("{s}(", .{op_str});
                try cg.generateExprMir(rec.operand);
                try cg.emit(")");
            },
            .index => {
                const rec = mir_typed.Index.unpack(store, idx);
                try cg.generateExprMir(rec.object);
                try cg.emit("[");
                // Check if index is an int literal for intCast decision
                const index_entry = store.getNode(rec.index);
                const index_is_literal = index_entry.tag == .literal and
                    @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.index).kind)) == .int;
                if (!index_is_literal) {
                    try cg.emit("@intCast(");
                    try cg.generateExprMir(rec.index);
                    try cg.emit(")");
                } else {
                    try cg.generateExprMir(rec.index);
                }
                try cg.emit("]");
            },
            .slice => {
                const rec = mir_typed.Slice.unpack(store, idx);
                try cg.generateExprMir(rec.object);
                try cg.emit("[");
                const low_entry = store.getNode(rec.low);
                const low_is_literal = low_entry.tag == .literal and
                    @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.low).kind)) == .int;
                if (!low_is_literal) {
                    try cg.emit("@intCast(");
                    try cg.generateExprMir(rec.low);
                    try cg.emit(")");
                } else {
                    try cg.generateExprMir(rec.low);
                }
                try cg.emit("..");
                const high_entry = store.getNode(rec.high);
                const high_is_literal = high_entry.tag == .literal and
                    @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.high).kind)) == .int;
                if (!high_is_literal) {
                    try cg.emit("@intCast(");
                    try cg.generateExprMir(rec.high);
                    try cg.emit(")");
                } else {
                    try cg.generateExprMir(rec.high);
                }
                try cg.emit("]");
            },
            .borrow => {
                const rec = mir_typed.Borrow.unpack(store, idx);
                try cg.emit("&");
                try cg.generateExprMir(rec.operand);
            },
            .interpolation => {
                const rec = mir_typed.Interpolation.unpack(store, idx);
                try match_impl.generateInterpolatedStringMirFromStore(cg, store, rec.parts_start, rec.parts_end);
            },
            .compiler_fn => try cg.generateCompilerFuncMir(idx),
            .array_lit => {
                const items = mir_typed.ArrayLit.getItems(store, idx);
                try cg.emit(".{");
                for (items, 0..) |item_idx, i| {
                    if (i > 0) try cg.emit(", ");
                    try cg.generateExprMir(item_idx);
                }
                try cg.emit("}");
            },
            .tuple_lit => {
                const rec = mir_typed.TupleLit.unpack(store, idx);
                const elem_count = rec.elements_end - rec.elements_start;
                try cg.emit(".{ ");
                var i: u32 = 0;
                while (i < elem_count) : (i += 1) {
                    if (i > 0) try cg.emit(", ");
                    const elem_idx: MirNodeIndex = @enumFromInt(store.extra_data.items[rec.elements_start + i]);
                    // Named fields: names_start points to StringIndex array in extra_data
                    if (rec.names_start != 0) {
                        const name_si: StringIndex = @enumFromInt(store.extra_data.items[rec.names_start + i]);
                        if (name_si != .none) {
                            const name = store.strings.get(name_si);
                            if (name.len > 0) {
                                try cg.emitFmt(".{s} = ", .{name});
                            }
                        }
                    }
                    try cg.generateExprMir(elem_idx);
                }
                try cg.emit(" }");
            },
            .version_lit => {}, // version metadata — not emitted in code
            .type_expr => {}, // type_expr: no codegen (old path removed)
            .inline_struct => {
                const rec = mir_typed.InlineStruct.unpack(store, idx);
                const members = store.extra_data.items[rec.members_start..rec.members_end];
                const prev_in_struct = cg.in_struct;
                cg.in_struct = true;
                defer cg.in_struct = prev_in_struct;
                try cg.emit("struct {\n");
                cg.indent += 1;
                try decls_impl.emitStructBodyFromStore(cg, store, members);
                cg.indent -= 1;
                try cg.emitIndent();
                try cg.emit("}");
            },
            .passthrough => {}, // architectural nodes (metadata, module_decl) — no codegen
            else => {
                // Unknown tag in MirStore: no codegen for this node
            },
        }
}

// ============================================================
// PER-KIND EXPRESSION HELPERS — NEW MIRSTORE PATH
// ============================================================

fn generateBinaryMir(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.Binary.unpack(store, idx);
    const bin_op: parser.Operator = @enumFromInt(rec.op);
    const is_eq = bin_op == .eq;
    const is_ne = bin_op == .ne;

    // `x is T` desugared form: @type(x) == T
    // Check if lhs is compiler_fn named "type"
    const lhs_entry = store.getNode(rec.lhs);
    if ((is_eq or is_ne) and
        lhs_entry.tag == .compiler_fn)
    {
        const lhs_fn_rec = mir_typed.CompilerFn.unpack(store, rec.lhs);
        const fn_name = store.strings.get(lhs_fn_rec.name);
        const lhs_args_count = lhs_fn_rec.args_end - lhs_fn_rec.args_start;
        if (std.mem.eql(u8, fn_name, K.Type.TYPE) and lhs_args_count > 0) {
            const val_idx: MirNodeIndex = @enumFromInt(store.extra_data.items[lhs_fn_rec.args_start]);
            const cmp = if (is_eq) "==" else "!=";
            const rhs_entry = store.getNode(rec.rhs);

            // rhs is null literal
            if (rhs_entry.tag == .literal and
                @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.rhs).kind)) == .null_lit)
            {
                const val_entry = store.getNode(val_idx);
                if (val_entry.tag == .identifier) {
                    const val_ident = mir_typed.Identifier.unpack(store, val_idx);
                    const val_name = store.strings.get(val_ident.name);
                    try cg.null_narrowed.put(cg.allocator, val_name, {});
                    if (cg.match_var_subst) |subst| {
                        if (subst.eff_tc != null and subst.eff_tc.? == .plain and
                            std.mem.eql(u8, val_name, subst.original))
                        {
                            try cg.emit(if (is_eq) "false" else "true");
                            return;
                        }
                    }
                }
                try cg.emit("(");
                try cg.generateExprMir(val_idx);
                try cg.emitFmt(" {s} null)", .{cmp});
                return;
            }

            // rhs is identifier
            if (rhs_entry.tag == .identifier) {
                const rhs_id_rec = mir_typed.Identifier.unpack(store, rec.rhs);
                const rhs = store.strings.get(rhs_id_rec.name);
                if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                    const val_entry = store.getNode(val_idx);
                    if (val_entry.tag == .identifier) {
                        const val_ident = mir_typed.Identifier.unpack(store, val_idx);
                        const val_name = store.strings.get(val_ident.name);
                        try cg.error_narrowed.put(cg.allocator, val_name, {});
                    }
                    // Get val's effective type_class from MirStore entry
                    const val_tc = blk: {
                        if (cg.match_var_subst) |subst| {
                            if (subst.eff_tc) |etc| {
                                const val_entry2 = store.getNode(val_idx);
                                if (val_entry2.tag == .identifier) {
                                    const vi = mir_typed.Identifier.unpack(store, val_idx);
                                    if (std.mem.eql(u8, store.strings.get(vi.name), subst.original))
                                        break :blk etc;
                                }
                            }
                        }
                        const val_entry2 = store.getNode(val_idx);
                        if (val_entry2.type_class != .plain) break :blk val_entry2.type_class;
                        break :blk val_entry2.type_class;
                    };
                    if (val_tc == .plain) {
                        try cg.emit(if (is_eq) "false" else "true");
                    } else if (val_tc == .null_error_union) {
                        const inner_t = if (is_eq) "false" else "true";
                        const inner_f = if (is_eq) "true" else "false";
                        const outer_else = if (is_eq) "false" else "true";
                        try cg.emit("(if (");
                        try cg.generateExprMir(val_idx);
                        try cg.emitFmt(") |_oe| (if (_oe) |_| {s} else |_| {s}) else {s})", .{ inner_t, inner_f, outer_else });
                    } else {
                        const t_val = if (is_eq) "false" else "true";
                        const f_val = if (is_eq) "true" else "false";
                        try cg.emit("(if (");
                        try cg.generateExprMir(val_idx);
                        try cg.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
                    }
                    return;
                }
                if (rec.union_tag != 0) {
                    const tag = rec.union_tag - 1;
                    try cg.emit("(std.meta.activeTag(");
                    try cg.generateExprMir(val_idx);
                    try cg.emitFmt(") {s} ._{d})", .{ cmp, tag });
                    return;
                }
                const zig_rhs = types.Primitive.nameToZig(rhs);
                try cg.emit("(@TypeOf(");
                try cg.generateExprMir(val_idx);
                try cg.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                return;
            }

            // rhs is field_access
            if (rhs_entry.tag == .field_access) {
                if (rec.union_tag != 0) {
                    const tag = rec.union_tag - 1;
                    try cg.emit("(std.meta.activeTag(");
                    try cg.generateExprMir(val_idx);
                    try cg.emitFmt(") {s} ._{d})", .{ cmp, tag });
                    return;
                }
                try cg.emit("(@TypeOf(");
                try cg.generateExprMir(val_idx);
                try cg.emitFmt(") {s} ", .{cmp});
                try cg.generateExprMir(rec.rhs);
                try cg.emit(")");
                return;
            }
        }
    }

    // Vector/float detection: always false (old MirNode bridge removed). Task 5 must
    // replace with TypeClass/type_id from MirStore.
    const lhs_is_vec = false;
    const rhs_is_vec = false;
    const any_vec = false;
    const is_float_op = false;

    if (!any_vec and bin_op == .div) {
        if (is_float_op) {
            try cg.emit("(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit(" / ");
            try cg.generateExprMir(rec.rhs);
            try cg.emit(")");
        } else {
            try cg.emit("@divTrunc(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit(", ");
            try cg.generateExprMir(rec.rhs);
            try cg.emit(")");
        }
    } else if (!any_vec and bin_op == .mod) {
        if (is_float_op) {
            try cg.emit("(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit(" % ");
            try cg.generateExprMir(rec.rhs);
            try cg.emit(")");
        } else {
            try cg.emit("@mod(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit(", ");
            try cg.generateExprMir(rec.rhs);
            try cg.emit(")");
        }
    } else if (any_vec and lhs_is_vec != rhs_is_vec) {
        const op = codegen.opToZig(bin_op);
        try cg.emit("(");
        if (lhs_is_vec) {
            try cg.generateExprMir(rec.lhs);
            try cg.emitFmt(" {s} ", .{op});
            try cg.emit("@as(@TypeOf(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit("), @splat(");
            try cg.generateExprMir(rec.rhs);
            try cg.emit("))");
        } else {
            try cg.emit("@as(@TypeOf(");
            try cg.generateExprMir(rec.rhs);
            try cg.emit("), @splat(");
            try cg.generateExprMir(rec.lhs);
            try cg.emit("))");
            try cg.emitFmt(" {s} ", .{op});
            try cg.generateExprMir(rec.rhs);
        }
        try cg.emit(")");
    } else {
        const op = codegen.opToZig(bin_op);
        try cg.emit("(");
        try cg.generateExprMir(rec.lhs);
        try cg.emitFmt(" {s} ", .{op});
        try cg.generateExprMir(rec.rhs);
        try cg.emit(")");
    }
}

fn generateCallMir(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.Call.unpack(store, idx);
    const callee_idx = rec.callee;
    const callee_entry = store.getNode(callee_idx);
    const callee_is_ident = callee_entry.tag == .identifier;
    const callee_name = if (callee_is_ident) blk: {
        const id_rec = mir_typed.Identifier.unpack(store, callee_idx);
        break :blk store.strings.get(id_rec.name);
    } else "";

    const arg_count = rec.args_end - rec.args_start;
    // arg_names: stored at arg_names_start in extra_data, each is a StringIndex (u32)
    // arg_names_start == 0 means no named args
    const has_named_args = rec.arg_names_start != 0 and arg_count > 0;

    if (has_named_args) {
        try cg.generateExprMir(callee_idx);
        try cg.emit("{ ");
        var i: u32 = 0;
        while (i < arg_count) : (i += 1) {
            if (i > 0) try cg.emit(", ");
            const arg_idx: MirNodeIndex = @enumFromInt(store.extra_data.items[rec.args_start + i]);
            const name_si: StringIndex = @enumFromInt(store.extra_data.items[rec.arg_names_start + i]);
            if (name_si != .none) {
                const name = store.strings.get(name_si);
                if (name.len > 0) {
                    try cg.emitFmt(".{s} = ", .{name});
                }
            }
            try cg.generateExprMir(arg_idx);
        }
        try cg.emit(" }");
    } else {
        const is_self_generic_mir = if (cg.generic_struct_name) |gsn|
            callee_is_ident and std.mem.eql(u8, callee_name, gsn)
        else
            false;
        if (is_self_generic_mir) {
            try cg.emit("@This()");
        } else if (arg_count == 0 and callee_is_ident) {
            const is_struct_type = if (cg.decls) |d| d.structs.contains(callee_name) else false;
            if (is_struct_type) {
                try cg.emitFmt("{s}{{}}", .{callee_name});
            } else {
                try cg.generateExprMir(callee_idx);
                try cg.emit("(");
                try cg.fillDefaultArgsMir(callee_idx, 0);
                try cg.emit(")");
            }
        } else if (arg_count == 0 and callee_entry.tag == .call) {
            try cg.generateExprMir(callee_idx);
            try cg.emit("{}");
        } else {
            try cg.generateExprMir(callee_idx);
            try cg.emit("(");
            var i: u32 = 0;
            while (i < arg_count) : (i += 1) {
                if (i > 0) try cg.emit(", ");
                const arg_idx: MirNodeIndex = @enumFromInt(store.extra_data.items[rec.args_start + i]);
                try cg.generateCoercedExprMir(arg_idx);
            }
            try cg.fillDefaultArgsMir(callee_idx, arg_count);
            try cg.emit(")");
        }
    }
}

fn generateFieldAccessMir(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.FieldAccess.unpack(store, idx);
    const field = store.strings.get(rec.field);
    const obj_idx = rec.object;
    const obj_entry = store.getNode(obj_idx);
    const obj_tc = obj_entry.type_class;

    // Self-module reference: module.func where module is the current module.
    if (obj_entry.tag == .identifier) {
        const obj_id_rec = mir_typed.Identifier.unpack(store, obj_idx);
        const obj_name = store.strings.get(obj_id_rec.name);
        if (obj_name.len > 0 and std.mem.eql(u8, obj_name, cg.module_name)) {
            try cg.emit(field);
            return;
        }
    }

    if (cg.match_var_subst) |subst| {
        if (obj_entry.tag == .identifier) {
            const obj_id_rec = mir_typed.Identifier.unpack(store, obj_idx);
            const obj_name = store.strings.get(obj_id_rec.name);
            if (std.mem.eql(u8, obj_name, subst.original)) {
                if (codegen.isResultValueField(field, cg.decls) or std.mem.eql(u8, field, K.Type.ERROR)) {
                    try cg.emit(subst.capture);
                    return;
                }
            }
        }
    }

    if (std.mem.eql(u8, field, K.Type.ERROR)) {
        // Use obj type_class directly from MirStore entry
        const err_tc = obj_tc;
        if (err_tc == .null_error_union) {
            try cg.emit("(if (");
            try cg.generateExprMir(obj_idx);
            try cg.emit(") |_oe| (if (_oe) |_| unreachable else |_e| @errorName(_e)) else unreachable)");
        } else {
            try cg.emit("(if (");
            try cg.generateExprMir(obj_idx);
            try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
        }
    } else if (codegen.isResultValueField(field, cg.decls)) {
        const eff_tc = if (obj_tc != .plain) obj_tc else blk: {
            if (obj_entry.tag == .identifier) {
                const obj_id_rec = mir_typed.Identifier.unpack(store, obj_idx);
                const obj_name = store.strings.get(obj_id_rec.name);
                if (obj_name.len > 0) {
                    if (cg.error_narrowed.contains(obj_name) or cg.null_narrowed.contains(obj_name)) {
                        if (cg.error_narrowed.contains(obj_name)) break :blk mir.TypeClass.error_union;
                        break :blk mir.TypeClass.null_union;
                    }
                }
            }
            break :blk obj_tc;
        };
        if (codegen.valueUnwrapForm(eff_tc)) |form| {
            try cg.emit(form.prefix);
            try cg.generateExprMir(obj_idx);
            try cg.emit(form.suffix);
        } else if (eff_tc == .arbitrary_union) {
            // union_tag is directly available in FieldAccess.Record
            if (rec.union_tag != 0) {
                const tag = rec.union_tag - 1;
                try cg.generateExprMir(obj_idx);
                try cg.emitFmt("._{d}", .{tag});
            } else {
                // Fallback: emit `._<raw_field>`
                try cg.generateExprMir(obj_idx);
                try cg.emitFmt("._{s}", .{field});
            }
        } else {
            try cg.generateExprMir(obj_idx);
            try cg.emitFmt(".{s}", .{field});
        }
    } else {
        try cg.generateExprMir(obj_idx);
        try cg.emitFmt(".{s}", .{field});
    }
}

fn generateIdentifierMir(cg: *CodeGen, store: *const MirStore, idx: MirNodeIndex) anyerror!void {
    const rec = mir_typed.Identifier.unpack(store, idx);
    const name = store.strings.get(rec.name);
    if (cg.match_var_subst) |subst| {
        if (std.mem.eql(u8, name, subst.original)) {
            try cg.emit(subst.capture);
            return;
        }
    }
    // resolved_kind == 1 means enum_variant.
    const is_enum_variant = rec.resolved_kind == 1;
    if (is_enum_variant) {
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
}

/// MIR-path coerced expression — uses MirStore coercion_kind directly.
pub fn generateCoercedExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const entry = store.getNode(idx);
    if (mir_store_mod.coercionFromKind(entry.coercion_kind)) |coercion| {
        switch (coercion) {
            .array_to_slice => {
                try cg.emit("&");
                try cg.generateExprMir(idx);
            },
            .null_wrap, .error_wrap => {
                try cg.generateExprMir(idx);
            },
            .arbitrary_union_wrap => |tag| {
                try cg.emitFmt(".{{ ._{d} = ", .{tag});
                try cg.generateExprMir(idx);
                try cg.emit(" }");
            },
            .optional_unwrap => {
                try cg.generateExprMir(idx);
                try cg.emit(".?");
            },
            .value_to_const_ref => {
                if (entry.tag == .borrow) {
                    try cg.generateExprMir(idx);
                } else {
                    try cg.emit("&");
                    try cg.generateExprMir(idx);
                }
            },
        }
        return;
    }
    try cg.generateExprMir(idx);
}

/// Check if a MirStore entry represents a string expression.
pub fn mirIsStringFromStore(store: *const MirStore, idx: MirNodeIndex) bool {
    const entry = store.getNode(idx);
    if (entry.type_class == .string) return true;
    if (entry.tag == .interpolation) return true;
    if (entry.tag == .literal) {
        const rec = mir_typed.Literal.unpack(store, idx);
        const lk: mir.LiteralKind = @enumFromInt(rec.kind);
        if (lk == .string) return true;
    }
    return false;
}


/// MIR-path continue expression for while loops.
pub fn generateContinueExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const entry = store.getNode(idx);
    if (entry.tag == .assignment) {
        const rec = mir_typed.Assignment.unpack(store, idx);
        const assign_op: parser.Operator = @enumFromInt(rec.op);
        if (assign_op == .div_assign) {
            const lhs_entry = store.getNode(rec.lhs);
            const lhs_rt = if (lhs_entry.type_id != .none) store.types.get(lhs_entry.type_id) else .unknown;
            const is_float_cont = lhs_rt == .primitive and lhs_rt.primitive.isFloat();
            try cg.generateExprMir(rec.lhs);
            if (is_float_cont) {
                try cg.emit(" = (");
                try cg.generateExprMir(rec.lhs);
                try cg.emit(" / ");
                try cg.generateExprMir(rec.rhs);
                try cg.emit(")");
            } else {
                try cg.emit(" = @divTrunc(");
                try cg.generateExprMir(rec.lhs);
                try cg.emit(", ");
                try cg.generateExprMir(rec.rhs);
                try cg.emit(")");
            }
        } else {
            try cg.generateExprMir(rec.lhs);
            try cg.emitFmt(" {s} ", .{assign_op.toZig()});
            try cg.generateExprMir(rec.rhs);
        }
    } else {
        try cg.generateExprMir(idx);
    }
}

/// MIR-path range expression for for-loops.
pub fn writeRangeExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const rec = mir_typed.Binary.unpack(store, idx);
    const lhs_entry = store.getNode(rec.lhs);
    const left_is_literal = lhs_entry.tag == .literal and
        @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.lhs).kind)) == .int;
    if (left_is_literal) {
        try cg.generateExprMir(rec.lhs);
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(rec.lhs);
        try cg.emit(")");
    }
    try cg.emit("..");
    // Open-ended range (0..) — rhs is type_expr sentinel, emit nothing after ..
    const rhs_entry = store.getNode(rec.rhs);
    if (rhs_entry.tag == .type_expr) return;
    const right_is_literal = rhs_entry.tag == .literal and
        @as(mir.LiteralKind, @enumFromInt(mir_typed.Literal.unpack(store, rec.rhs).kind)) == .int;
    if (right_is_literal) {
        try cg.generateExprMir(rec.rhs);
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(rec.rhs);
        try cg.emit(")");
    }
}

/// Emit one for-loop iterable expression from MirStore.
fn emitForIterMir(cg: *CodeGen, store: *const MirStore, iter_idx: MirNodeIndex) anyerror!void {
    const iter_entry = store.getNode(iter_idx);
    if (iter_entry.tag == .binary) {
        const bin_rec = mir_typed.Binary.unpack(store, iter_idx);
        const bin_op: parser.Operator = @enumFromInt(bin_rec.op);
        if (bin_op == .range) {
            try cg.writeRangeExprMir(iter_idx);
        } else {
            try cg.generateExprMir(iter_idx);
        }
    } else {
        try cg.generateExprMir(iter_idx);
    }
}

/// MIR-path for loop codegen — Zig-style multi-object for.
pub fn generateForMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const rec = mir_typed.ForStmt.unpack(store, idx);
    const iters_raw = store.extra_data.items[rec.iterables_start..rec.iterables_end];
    const caps_raw = store.extra_data.items[rec.captures_start..rec.captures_end];

    const is_tuple_capture = (rec.flags & 1) != 0;
    const inline_prefix: []const u8 = if (cg.inComptFunc()) "inline " else "";

    if (is_tuple_capture and caps_raw.len > 0) {
        try cg.emit(inline_prefix);
        try cg.emit("for (");
        // First iterable: the struct slice
        const first_iter: MirNodeIndex = @enumFromInt(iters_raw[0]);
        try emitForIterMir(cg, store, first_iter);
        // Additional iterables
        for (iters_raw[1..]) |iter_u32| {
            try cg.emit(", ");
            try emitForIterMir(cg, store, @enumFromInt(iter_u32));
        }
        try cg.emit(") |_orhon_entry");
        const first_iter_entry = store.getNode(first_iter);
        const iter_rt = if (first_iter_entry.type_id != .none) store.types.get(first_iter_entry.type_id) else .unknown;
        const field_names = resolveStructFieldNames(iter_rt, cg.decls);
        // Extra iterables beyond the first (e.g., `0..` index ranges) each claim one capture.
        const n_extra_iters = if (iters_raw.len > 1) iters_raw.len - 1 else 0;
        const n_fields: usize = if (field_names) |f| f.len
            else if (caps_raw.len > n_extra_iters) caps_raw.len - n_extra_iters
            else 0;
        for (caps_raw[n_fields..]) |cap_u32| {
            const cap_si: StringIndex = @enumFromInt(cap_u32);
            try cg.emitFmt(", {s}", .{store.strings.get(cap_si)});
        }
        try cg.emit("| {\n");
        cg.indent += 1;
        for (caps_raw[0..n_fields], 0..) |cap_u32, i| {
            const cap_si: StringIndex = @enumFromInt(cap_u32);
            const cap = store.strings.get(cap_si);
            try cg.emitIndent();
            if (field_names) |fields| {
                if (i < fields.len) {
                    try cg.emitFmt("const {s} = _orhon_entry.{s};\n", .{ cap, fields[i].name });
                    continue;
                }
            }
            try cg.emitFmt("const {s} = _orhon_entry.@\"{d}\";\n", .{ cap, i });
        }
        for (mir_typed.Block.getStmts(store, rec.body)) |child_idx| {
            try cg.emitIndent();
            try cg.generateStatementMir(child_idx);
            try cg.emit("\n");
        }
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("}");
        return;
    }

    // Non-tuple: each iterable maps 1:1 to a capture
    try cg.emit(inline_prefix);
    try cg.emit("for (");
    for (iters_raw, 0..) |iter_u32, i| {
        if (i > 0) try cg.emit(", ");
        try emitForIterMir(cg, store, @enumFromInt(iter_u32));
    }
    try cg.emit(") |");
    for (caps_raw, 0..) |cap_u32, i| {
        if (i > 0) try cg.emit(", ");
        const cap_si: StringIndex = @enumFromInt(cap_u32);
        try cg.emit(store.strings.get(cap_si));
    }
    try cg.emit("| ");
    try cg.generateBlockMir(rec.body);
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
pub fn generateDestructMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store.?;
    const rec = mir_typed.Destruct.unpack(store, idx);
    const is_const = (rec.flags & 1) != 0;
    const decl_keyword: []const u8 = if (is_const) "const" else "var";

    const names_raw = store.extra_data.items[rec.names_start..rec.names_end];
    const val_idx = rec.value;
    const val_entry = store.getNode(val_idx);

    // @splitAt destructuring: const left, right = @splitAt(arr, n)
    if (names_raw.len == 2 and val_entry.tag == .compiler_fn) {
        const fn_rec = mir_typed.CompilerFn.unpack(store, val_idx);
        const fn_name = store.strings.get(fn_rec.name);
        const fn_arg_count = fn_rec.args_end - fn_rec.args_start;
        if (std.mem.eql(u8, fn_name, "splitAt") and fn_arg_count == 2) {
            const arg0: MirNodeIndex = @enumFromInt(store.extra_data.items[fn_rec.args_start]);
            const arg1: MirNodeIndex = @enumFromInt(store.extra_data.items[fn_rec.args_start + 1]);
            const name0 = store.strings.get(@enumFromInt(names_raw[0]));
            const name1 = store.strings.get(@enumFromInt(names_raw[1]));
            const destruct_idx = cg.destruct_counter;
            cg.destruct_counter += 1;
            try cg.emitFmt("var _orhon_s{d}: usize = @intCast(", .{destruct_idx});
            try cg.generateExprMir(arg1);
            try cg.emit(");\n");
            try cg.emitIndent();
            try cg.emitFmt("_ = &_orhon_s{d};\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, name0 });
            try cg.generateExprMir(arg0);
            try cg.emitFmt("[0.._orhon_s{d}];\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, name1 });
            try cg.generateExprMir(arg0);
            try cg.emitFmt("[_orhon_s{d}..];", .{destruct_idx});
            return;
        }
    }

    // Normal tuple destructuring
    const di = cg.destruct_counter;
    cg.destruct_counter += 1;
    try cg.emitFmt("const _orhon_d{d} = ", .{di});
    try cg.generateExprMir(val_idx);
    try cg.emit(";");
    for (names_raw) |name_u32| {
        const name = store.strings.get(@enumFromInt(name_u32));
        try cg.emit("\n");
        try cg.emitIndent();
        try cg.emitFmt("{s} {s} = _orhon_d{d}.{s};", .{ decl_keyword, name, di, name });
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
