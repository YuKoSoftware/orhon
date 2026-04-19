// codegen_exprs.zig — MIR expression generators (core expressions, continuations, ranges, interpolation, loops)
// Contains: generateExprMir (dispatch hub), generateBinaryMir, generateCallMir, generateFieldAccessMir,
//           generateIdentifierMir, generateTypeExprMir, generateCoercedExprMir,
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
    // New MirStore path: check coercion_kind directly on the entry.
    const has_coercion = blk: {
        if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
            const entry = cg.mir_store.?.getNode(idx);
            if (entry.coercion_kind != 0) break :blk true;
        } else if (cg.getOldMirNode(idx)) |m| {
            if (cg.getMirEntryForParserNode(m.ast)) |entry| {
                if (entry.coercion_kind != 0) break :blk true;
            }
            if (m.coercion != null) break :blk true;
        }
        break :blk false;
    };
    if (has_coercion) {
        try cg.generateCoercedExprMir(idx);
        return;
    }
    // For tag inference, fall back to old MirNode (needs literal_kind).
    if (cg.getOldMirNode(idx)) |m| {
        const tag = inferArbitraryUnionTagMir(m, members_rt);
        if (tag) |t| {
            try cg.emitFmt(".{{ ._{s} = ", .{t});
            try cg.generateExprMir(idx);
            try cg.emit(" }");
        } else {
            try cg.generateExprMir(idx);
        }
    } else {
        try cg.generateExprMir(idx);
    }
}

/// Infer the positional union tag for a literal MirNode being wrapped into an
/// arbitrary union. Computes the destination union's canonical sort order
/// (Error/null filtered) and returns the matching member's positional index
/// as a borrowed slice into the annotator's static tag pool.
pub fn inferArbitraryUnionTagMir(m: *const mir.MirNode, members_rt: ?[]const RT) ?[]const u8 {
    const lk = m.literal_kind orelse return null;
    const members = members_rt orelse return null;

    const target_name = switch (lk) {
        .int => findMemberByKind(members_rt, .int) orelse return null,
        .float => findMemberByKind(members_rt, .float) orelse return null,
        .string => findMemberByKind(members_rt, .string) orelse return null,
        .bool_lit => findMemberByKind(members_rt, .bool_) orelse return null,
        else => return null,
    };
    _ = members;

    // Stack-allocated filtered+sorted member list matches the annotator's
    // static tag pool bound of 32 members.
    const max_arity = 32;
    var buf: [max_arity][]const u8 = undefined;
    var n: usize = 0;
    for ((members_rt orelse return null)) |mem| {
        const name = mem.name();
        if (std.mem.eql(u8, name, "Error") or std.mem.eql(u8, name, "null")) continue;
        if (n >= max_arity) return null;
        buf[n] = name;
        n += 1;
    }
    mir.union_sort.sortMemberNames(buf[0..n]);
    const idx = mir.union_sort.positionalIndex(buf[0..n], target_name) orelse return null;
    const pool = [_][]const u8{
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
        "10", "11", "12", "13", "14", "15", "16", "17", "18", "19",
        "20", "21", "22", "23", "24", "25", "26", "27", "28", "29",
        "30", "31",
    };
    if (idx >= pool.len) return null;
    return pool[idx];
}

// ============================================================
// MIR EXPRESSION GENERATORS
// ============================================================

/// Returns true if idx is a real MirStore entry (not .none, not synthetic).
/// Synthetic indices start at 0x80000001 and are NOT valid MirStore slots.
inline fn isMirStoreIdx(store: *const MirStore, idx: MirNodeIndex) bool {
    if (idx == .none) return false;
    const raw: u32 = @intFromEnum(idx);
    return raw < store.nodes.len;
}

/// MIR-path expression dispatch — uses MirStore entry.tag when available,
/// falls back to old MirNode tree otherwise.
pub fn generateExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
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
                // Interpolation: fall back to old MirNode for interp_parts and children.
                const m = cg.getOldMirNode(idx) orelse return;
                if (m.injected_name) |var_name| {
                    try cg.emit(var_name);
                } else if (m.interp_parts) |parts| {
                    try cg.generateInterpolatedStringMir(parts, m.children);
                }
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
            .type_expr => {
                // type_expr: keep on old path (needs emitStructBody with []*MirNode)
                const m = cg.getOldMirNode(idx) orelse return;
                try generateTypeExprMir(cg, m);
            },
            .passthrough => {}, // architectural nodes (metadata, module_decl) — no codegen
            else => {
                // Unknown tag in MirStore: no codegen for this node
            },
        }
        return;
    }
    // Old MirNode fallback path
    const m = cg.getOldMirNode(idx) orelse return;
    switch (m.kind) {
        .binary => try generateBinaryMirOld(cg, m),
        .call => try generateCallMirOld(cg, m),
        .field_access => try generateFieldAccessMirOld(cg, m),
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
        .identifier => try generateIdentifierMirOld(cg, m),
        .unary => {
            const op = codegen.opToZig(m.op orelse return);
            try cg.emitFmt("{s}(", .{op});
            try cg.generateExprMir(cg.mirIdx(m.children[0]));
            try cg.emit(")");
        },
        .index => {
            try cg.generateExprMir(cg.mirIdx(m.children[0]));
            try cg.emit("[");
            const index_is_literal = m.children[1].literal_kind == .int;
            if (!index_is_literal) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(cg.mirIdx(m.children[1]));
                try cg.emit(")");
            } else {
                try cg.generateExprMir(cg.mirIdx(m.children[1]));
            }
            try cg.emit("]");
        },
        .slice => {
            try cg.generateExprMir(cg.mirIdx(m.children[0]));
            try cg.emit("[");
            if (m.children[1].literal_kind != .int) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(cg.mirIdx(m.children[1]));
                try cg.emit(")");
            } else {
                try cg.generateExprMir(cg.mirIdx(m.children[1]));
            }
            try cg.emit("..");
            if (m.children[2].literal_kind != .int) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(cg.mirIdx(m.children[2]));
                try cg.emit(")");
            } else {
                try cg.generateExprMir(cg.mirIdx(m.children[2]));
            }
            try cg.emit("]");
        },
        .borrow => {
            try cg.emit("&");
            try cg.generateExprMir(cg.mirIdx(m.children[0]));
        },
        .interpolation => {
            // If the MIR lowerer hoisted this to a temp var, emit just the var name
            if (m.injected_name) |var_name| {
                try cg.emit(var_name);
            } else if (m.interp_parts) |parts| {
                try cg.generateInterpolatedStringMir(parts, m.children);
            }
        },
        .compiler_fn => try cg.generateCompilerFuncMir(idx),
        .array_lit => {
            try cg.emit(".{");
            for (m.children, 0..) |child, i| {
                if (i > 0) try cg.emit(", ");
                try cg.generateExprMir(cg.mirIdx(child));
            }
            try cg.emit("}");
        },
        .tuple_lit => {
            try cg.emit(".{ ");
            for (m.children, 0..) |child, i| {
                if (i > 0) try cg.emit(", ");
                if (m.arg_names) |names| {
                    try cg.emitFmt(".{s} = ", .{names[i]});
                }
                try cg.generateExprMir(cg.mirIdx(child));
            }
            try cg.emit(" }");
        },
        .version_lit => {}, // version metadata — not emitted in code
        .type_expr => try generateTypeExprMir(cg, m),
        .passthrough => {}, // architectural nodes (metadata, module_decl) — no codegen
        else => {},
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
                        // Also try var_types for identifier nodes
                        if (val_entry2.tag == .identifier) {
                            const vi = mir_typed.Identifier.unpack(store, val_idx);
                            const vn = store.strings.get(vi.name);
                            if (vn.len > 0) {
                                if (cg.var_types) |vt| {
                                    if (vt.get(vn)) |info| {
                                        const info_tc = info.typeClass();
                                        if (info_tc != .plain) break :blk info_tc;
                                    }
                                }
                            }
                        }
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
                // union_tag: use bridge for now (not in Binary.Record)
                if (cg.getOldMirNode(idx)) |old_m| {
                    if (old_m.union_tag) |tag| {
                        try cg.emit("(");
                        try cg.generateExprMir(val_idx);
                        try cg.emitFmt(" {s} ._{d})", .{ cmp, tag });
                        return;
                    }
                }
                const zig_rhs = types.Primitive.nameToZig(rhs);
                try cg.emit("(@TypeOf(");
                try cg.generateExprMir(val_idx);
                try cg.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                return;
            }

            // rhs is field_access
            if (rhs_entry.tag == .field_access) {
                // union_tag: use bridge for now (not in Binary.Record)
                if (cg.getOldMirNode(idx)) |old_m| {
                    if (old_m.union_tag) |tag| {
                        try cg.emit("(");
                        try cg.generateExprMir(val_idx);
                        try cg.emitFmt(" {s} ._{d})", .{ cmp, tag });
                        return;
                    }
                }
                try cg.emit("(@TypeOf(");
                try cg.generateExprMir(val_idx);
                try cg.emitFmt(") {s} ", .{cmp});
                // Emit RHS type — need old MirNode for emitTypeMirPath
                if (cg.getOldMirNode(rec.rhs)) |rhs_m| {
                    try cg.emitTypeMirPath(rhs_m);
                }
                try cg.emit(")");
                return;
            }
        }
    }

    // Vector operand detection for arithmetic — use bridge for resolved_type
    const lhs_is_vec = if (cg.getOldMirNode(rec.lhs)) |lm| mirIsVector(lm) else false;
    const rhs_is_vec = if (cg.getOldMirNode(rec.rhs)) |rm| mirIsVector(rm) else false;
    const any_vec = lhs_is_vec or rhs_is_vec;

    // Float op detection: use type_class or bridge resolved_type
    const is_float_op = blk: {
        if (cg.getOldMirNode(rec.lhs)) |lm| {
            break :blk lm.resolved_type == .primitive and lm.resolved_type.primitive.isFloat();
        }
        break :blk false;
    };

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
        const err_tc = if (obj_tc != .plain) obj_tc else blk: {
            if (obj_entry.tag == .identifier) {
                const obj_id_rec = mir_typed.Identifier.unpack(store, obj_idx);
                const on = store.strings.get(obj_id_rec.name);
                if (on.len > 0) {
                    if (cg.var_types) |vt| {
                        if (vt.get(on)) |info| {
                            const info_tc = info.typeClass();
                            if (info_tc != .plain) break :blk info_tc;
                        }
                    }
                }
            }
            break :blk obj_tc;
        };
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
                    if (cg.var_types) |vt| {
                        if (vt.get(obj_name)) |info| {
                            const info_tc = info.typeClass();
                            if (info_tc != .plain) break :blk info_tc;
                        }
                    }
                    if (cg.error_narrowed.contains(obj_name) or cg.null_narrowed.contains(obj_name)) {
                        if (cg.var_types) |vt| {
                            if (vt.get(obj_name)) |info| {
                                if (info.typeClass() == .null_error_union) break :blk mir.TypeClass.null_error_union;
                            }
                        }
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
    // MirBuilder stub always returns 0 — fall back to old MirNode resolved_kind via bridge.
    const is_enum_variant = rec.resolved_kind == 1 or blk: {
        if (cg.getOldMirNode(idx)) |m| break :blk m.resolved_kind == .enum_variant;
        break :blk false;
    };
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

// ============================================================
// PER-KIND EXPRESSION HELPERS — OLD MIRNODE PATH
// ============================================================

fn generateBinaryMirOld(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
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
        const val_mir = lhs_mir.children[0];
        const cmp = if (is_eq) "==" else "!=";
        const rhs_mir = m.rhs();
        if (rhs_mir.literal_kind == .null_lit) {
            if (val_mir.kind == .identifier)
                try cg.null_narrowed.put(cg.allocator, val_mir.name orelse "", {});
            if (cg.match_var_subst) |subst| {
                if (subst.eff_tc != null and subst.eff_tc.? == .plain and
                    val_mir.kind == .identifier and std.mem.eql(u8, val_mir.name orelse "", subst.original))
                {
                    try cg.emit(if (is_eq) "false" else "true");
                    return;
                }
            }
            try cg.emit("(");
            try cg.generateExprMir(cg.mirIdx(val_mir));
            try cg.emitFmt(" {s} null)", .{cmp});
            return;
        }
        if (rhs_mir.kind == .identifier) {
            const rhs = rhs_mir.name orelse "";
            if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                if (val_mir.kind == .identifier)
                    try cg.error_narrowed.put(cg.allocator, val_mir.name orelse "", {});
                const val_tc = blk: {
                    if (cg.match_var_subst) |subst| {
                        if (subst.eff_tc) |etc| {
                            if (val_mir.kind == .identifier and std.mem.eql(u8, val_mir.name orelse "", subst.original))
                                break :blk etc;
                        }
                    }
                    if (val_mir.type_class != .plain) break :blk val_mir.type_class;
                    const vn = if (val_mir.kind == .identifier) (val_mir.name orelse "") else "";
                    if (vn.len > 0) {
                        if (cg.var_types) |vt| {
                            if (vt.get(vn)) |info| {
                                const info_tc = info.typeClass();
                                if (info_tc != .plain) break :blk info_tc;
                            }
                        }
                    }
                    break :blk val_mir.type_class;
                };
                if (val_tc == .plain) {
                    try cg.emit(if (is_eq) "false" else "true");
                } else if (val_tc == .null_error_union) {
                    const inner_t = if (is_eq) "false" else "true";
                    const inner_f = if (is_eq) "true" else "false";
                    const outer_else = if (is_eq) "false" else "true";
                    try cg.emit("(if (");
                    try cg.generateExprMir(cg.mirIdx(val_mir));
                    try cg.emitFmt(") |_oe| (if (_oe) |_| {s} else |_| {s}) else {s})", .{ inner_t, inner_f, outer_else });
                } else {
                    const t_val = if (is_eq) "false" else "true";
                    const f_val = if (is_eq) "true" else "false";
                    try cg.emit("(if (");
                    try cg.generateExprMir(cg.mirIdx(val_mir));
                    try cg.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
                }
                return;
            }
            if (m.union_tag) |tag| {
                try cg.emit("(");
                try cg.generateExprMir(cg.mirIdx(val_mir));
                try cg.emitFmt(" {s} ._{d})", .{ cmp, tag });
                return;
            }
            const zig_rhs = types.Primitive.nameToZig(rhs);
            try cg.emit("(@TypeOf(");
            try cg.generateExprMir(cg.mirIdx(val_mir));
            try cg.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
            return;
        }
        if (rhs_mir.kind == .field_access) {
            if (m.union_tag) |tag| {
                try cg.emit("(");
                try cg.generateExprMir(cg.mirIdx(val_mir));
                try cg.emitFmt(" {s} ._{d})", .{ cmp, tag });
                return;
            }
            try cg.emit("(@TypeOf(");
            try cg.generateExprMir(cg.mirIdx(val_mir));
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
    const is_float_op = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
    if (!any_vec and bin_op == .div) {
        if (is_float_op) {
            try cg.emit("(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit(" / ");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit(")");
        } else {
            try cg.emit("@divTrunc(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit(", ");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit(")");
        }
    } else if (!any_vec and bin_op == .mod) {
        if (is_float_op) {
            try cg.emit("(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit(" % ");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit(")");
        } else {
            try cg.emit("@mod(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit(", ");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit(")");
        }
    } else if (any_vec and lhs_is_vec != rhs_is_vec) {
        const op = codegen.opToZig(bin_op);
        try cg.emit("(");
        if (lhs_is_vec) {
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emitFmt(" {s} ", .{op});
            try cg.emit("@as(@TypeOf(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit("), @splat(");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit("))");
        } else {
            try cg.emit("@as(@TypeOf(");
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
            try cg.emit("), @splat(");
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emit("))");
            try cg.emitFmt(" {s} ", .{op});
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
        }
        try cg.emit(")");
    } else {
        const op = codegen.opToZig(bin_op);
        try cg.emit("(");
        try cg.generateExprMir(cg.mirIdx(m.lhs()));
        try cg.emitFmt(" {s} ", .{op});
        try cg.generateExprMir(cg.mirIdx(m.rhs()));
        try cg.emit(")");
    }
}

fn generateCallMirOld(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const callee_mir = m.getCallee();
    const callee_is_ident = callee_mir.kind == .identifier;
    const callee_name = callee_mir.name orelse "";
    const call_args = m.callArgs();
    const call_arg_names = m.arg_names;
    if (call_arg_names != null and call_arg_names.?.len > 0) {
        const an = call_arg_names.?;
        try cg.generateExprMir(cg.mirIdx(callee_mir));
        try cg.emit("{ ");
        for (call_args, 0..) |arg, i| {
            if (i > 0) try cg.emit(", ");
            if (i < an.len and an[i].len > 0) {
                try cg.emitFmt(".{s} = ", .{an[i]});
            }
            try cg.generateExprMir(cg.mirIdx(arg));
        }
        try cg.emit(" }");
    } else {
        const is_self_generic_mir = if (cg.generic_struct_name) |gsn|
            callee_is_ident and std.mem.eql(u8, callee_name, gsn)
        else
            false;
        if (is_self_generic_mir) {
            try cg.emit("@This()");
        } else if (call_args.len == 0 and callee_is_ident) {
            const is_struct_type = if (cg.decls) |d| d.structs.contains(callee_name) else false;
            if (is_struct_type) {
                try cg.emitFmt("{s}{{}}", .{callee_name});
            } else {
                try cg.generateExprMir(cg.mirIdx(callee_mir));
                try cg.emit("(");
                try cg.fillDefaultArgsMir(cg.mirIdx(callee_mir), 0);
                try cg.emit(")");
            }
        } else if (call_args.len == 0 and callee_mir.kind == .call) {
            try cg.generateExprMir(cg.mirIdx(callee_mir));
            try cg.emit("{}");
        } else {
            try cg.generateExprMir(cg.mirIdx(callee_mir));
            try cg.emit("(");
            for (call_args, 0..) |arg, i| {
                if (i > 0) try cg.emit(", ");
                try cg.generateCoercedExprMir(cg.mirIdx(arg));
            }
            try cg.fillDefaultArgsMir(cg.mirIdx(callee_mir), call_args.len);
            try cg.emit(")");
        }
    }
}

fn generateFieldAccessMirOld(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const field = m.name orelse "";
    const obj_mir = m.children[0];
    const obj_tc = obj_mir.type_class;

    // Self-module reference: module.func where module is the current module.
    if (obj_mir.kind == .identifier) {
        const obj_name = obj_mir.name orelse "";
        if (obj_name.len > 0 and std.mem.eql(u8, obj_name, cg.module_name)) {
            try cg.emit(field);
            return;
        }
    }

    if (cg.match_var_subst) |subst| {
        if (obj_mir.kind == .identifier and std.mem.eql(u8, obj_mir.name orelse "", subst.original)) {
            if (codegen.isResultValueField(field, cg.decls) or std.mem.eql(u8, field, K.Type.ERROR)) {
                try cg.emit(subst.capture);
                return;
            }
        }
    }
    if (std.mem.eql(u8, field, K.Type.ERROR)) {
        const err_tc = if (obj_tc != .plain) obj_tc else blk: {
            const on = if (obj_mir.kind == .identifier) (obj_mir.name orelse "") else "";
            if (on.len > 0) {
                if (cg.var_types) |vt| {
                    if (vt.get(on)) |info| {
                        const info_tc = info.typeClass();
                        if (info_tc != .plain) break :blk info_tc;
                    }
                }
            }
            break :blk obj_tc;
        };
        if (err_tc == .null_error_union) {
            try cg.emit("(if (");
            try cg.generateExprMir(cg.mirIdx(obj_mir));
            try cg.emit(") |_oe| (if (_oe) |_| unreachable else |_e| @errorName(_e)) else unreachable)");
        } else {
            try cg.emit("(if (");
            try cg.generateExprMir(cg.mirIdx(obj_mir));
            try cg.emit(") |_| unreachable else |_e| @errorName(_e))");
        }
    } else if (codegen.isResultValueField(field, cg.decls)) {
        const eff_tc = if (obj_tc != .plain) obj_tc else blk: {
            const obj_name = if (obj_mir.kind == .identifier) (obj_mir.name orelse "") else "";
            if (obj_name.len > 0) {
                if (cg.var_types) |vt| {
                    if (vt.get(obj_name)) |info| {
                        const info_tc = info.typeClass();
                        if (info_tc != .plain) break :blk info_tc;
                    }
                }
                if (cg.error_narrowed.contains(obj_name) or cg.null_narrowed.contains(obj_name)) {
                    if (cg.var_types) |vt| {
                        if (vt.get(obj_name)) |info| {
                            if (info.typeClass() == .null_error_union) break :blk mir.TypeClass.null_error_union;
                        }
                    }
                    if (cg.error_narrowed.contains(obj_name)) break :blk mir.TypeClass.error_union;
                    break :blk mir.TypeClass.null_union;
                }
            }
            break :blk obj_tc;
        };
        if (codegen.valueUnwrapForm(eff_tc)) |form| {
            try cg.emit(form.prefix);
            try cg.generateExprMir(cg.mirIdx(obj_mir));
            try cg.emit(form.suffix);
        } else if (eff_tc == .arbitrary_union) {
            if (m.union_tag) |tag| {
                try cg.generateExprMir(cg.mirIdx(obj_mir));
                try cg.emitFmt("._{d}", .{tag});
            } else {
                // Fallback: lowerer couldn't resolve the union RT. Preserve the
                // old codegen behavior by emitting `._<raw_field>` — matches what
                // the prior arbitrary-union tag fallback path produced when its
                // lookup failed.
                try cg.generateExprMir(cg.mirIdx(obj_mir));
                try cg.emitFmt("._{s}", .{field});
            }
        } else {
            try cg.generateExprMir(cg.mirIdx(obj_mir));
            try cg.emitFmt(".{s}", .{field});
        }
    } else {
        try cg.generateExprMir(cg.mirIdx(obj_mir));
        try cg.emitFmt(".{s}", .{field});
    }
}

fn generateIdentifierMirOld(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const name = m.name orelse return;
    if (cg.match_var_subst) |subst| {
        if (std.mem.eql(u8, name, subst.original)) {
            try cg.emit(subst.capture);
            return;
        }
    }
    if (m.resolved_kind == .enum_variant) {
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

fn generateTypeExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.ast.* == .struct_type) {
        try cg.emit("struct {\n");
        cg.indent += 1;
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
}

/// MIR-path coerced expression — uses MirStore coercion_kind directly when available,
/// falls back to old MirNode.coercion path.
pub fn generateCoercedExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    // New MirStore path: read coercion_kind directly from the entry.
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
        const store = cg.mir_store.?;
        const entry = store.getNode(idx);
        if (mir_store_mod.coercionFromKind(entry.coercion_kind)) |coercion| {
            switch (coercion) {
                .array_to_slice => {
                    try cg.emit("&");
                    try cg.generateExprMir(idx);
                },
                // Native ?T and anyerror!T — Zig handles coercion automatically
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
                    // Skip extra & if the expression is already an explicit borrow (const &x)
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
        // No coercion in MirStore — emit bare expression
        try cg.generateExprMir(idx);
        return;
    }
    // Old MirNode fallback
    const m = cg.getOldMirNode(idx) orelse return;
    // Prefer MirStore coercion data (set by MirBuilder.inferCoercion in CP2).
    const coercion: mir.Coercion = blk: {
        if (cg.getMirEntryForParserNode(m.ast)) |entry| {
            if (mir_store_mod.coercionFromKind(entry.coercion_kind)) |c| break :blk c;
        }
        break :blk m.coercion orelse return cg.generateExprMir(idx);
    };
    switch (coercion) {
        .array_to_slice => {
            try cg.emit("&");
            try cg.generateExprMir(idx);
        },
        // Native ?T and anyerror!T — Zig handles coercion automatically
        .null_wrap, .error_wrap => {
            try cg.generateExprMir(idx);
        },
        .arbitrary_union_wrap => |tag| {
            try cg.emitFmt(".{{ ._{d} = ", .{tag});
            try cg.generateExprMir(idx);
            try cg.emit(" }");
        },
        .optional_unwrap => {
            // Native ?T: unwrap → .?
            try cg.generateExprMir(idx);
            try cg.emit(".?");
        },
        .value_to_const_ref => {
            // T → *const T: take address for const & parameter passing
            // Skip extra & if the expression is already an explicit borrow (const &x)
            if (m.kind == .borrow) {
                try cg.generateExprMir(idx);
            } else {
                try cg.emit("&");
                try cg.generateExprMir(idx);
            }
        },
    }
}

/// Check if a MirNode represents a string expression (via type_class or literal_kind).
/// Old MirNode version — kept for callers that still use the old path.
pub fn mirIsString(m: *const mir.MirNode) bool {
    return m.type_class == .string or m.literal_kind == .string or m.kind == .interpolation;
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

/// Check if a MirNode represents a SIMD Vector type.
/// Stays on old MirNode path — MirStore TypeClass has no vector variant.
pub fn mirIsVector(m: *const mir.MirNode) bool {
    if (m.resolved_type == .generic) {
        return std.mem.eql(u8, m.resolved_type.generic.name, K.Type.VECTOR);
    }
    return false;
}

/// MIR-path continue expression for while loops.
pub fn generateContinueExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    // New MirStore path
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
        const store = cg.mir_store.?;
        const entry = store.getNode(idx);
        if (entry.tag == .assignment) {
            const rec = mir_typed.Assignment.unpack(store, idx);
            const assign_op: parser.Operator = @enumFromInt(rec.op);
            if (assign_op == .div_assign) {
                // Float detection: use bridge for resolved_type on lhs
                const is_float_cont = if (cg.getOldMirNode(rec.lhs)) |lm|
                    lm.resolved_type == .primitive and lm.resolved_type.primitive.isFloat()
                else
                    false;
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
        return;
    }
    // Old MirNode fallback
    const m = cg.getOldMirNode(idx) orelse return;
    if (m.kind == .assignment) {
        const assign_op = m.op orelse .assign;
        if (assign_op == .div_assign) {
            const is_float_cont = m.lhs().resolved_type == .primitive and m.lhs().resolved_type.primitive.isFloat();
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            if (is_float_cont) {
                try cg.emit(" = (");
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                try cg.emit(" / ");
                try cg.generateExprMir(cg.mirIdx(m.rhs()));
                try cg.emit(")");
            } else {
                try cg.emit(" = @divTrunc(");
                try cg.generateExprMir(cg.mirIdx(m.lhs()));
                try cg.emit(", ");
                try cg.generateExprMir(cg.mirIdx(m.rhs()));
                try cg.emit(")");
            }
        } else {
            try cg.generateExprMir(cg.mirIdx(m.lhs()));
            try cg.emitFmt(" {s} ", .{assign_op.toZig()});
            try cg.generateExprMir(cg.mirIdx(m.rhs()));
        }
    } else {
        try cg.generateExprMir(idx);
    }
}

/// MIR-path range expression for for-loops.
pub fn writeRangeExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    // New MirStore path
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
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
        return;
    }
    // Old MirNode fallback
    const m = cg.getOldMirNode(idx) orelse return;
    const left_is_literal = m.lhs().literal_kind == .int;
    if (left_is_literal) {
        try cg.generateExprMir(cg.mirIdx(m.lhs()));
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(cg.mirIdx(m.lhs()));
        try cg.emit(")");
    }
    try cg.emit("..");
    // Open-ended range (0..) — rhs is void sentinel (type_named = "void"), emit nothing after ..
    if (m.rhs().ast.* == .type_named) return;
    const right_is_literal = m.rhs().literal_kind == .int;
    if (right_is_literal) {
        try cg.generateExprMir(cg.mirIdx(m.rhs()));
    } else {
        try cg.emit("@intCast(");
        try cg.generateExprMir(cg.mirIdx(m.rhs()));
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
    // New MirStore path: only activate if ALL iterables are valid MirStore entries.
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
        const store = cg.mir_store.?;
        const rec = mir_typed.ForStmt.unpack(store, idx);
        const iters_raw = store.extra_data.items[rec.iterables_start..rec.iterables_end];
        const caps_raw = store.extra_data.items[rec.captures_start..rec.captures_end];

        // Check all iterables are valid MirStore entries before using new path.
        const all_valid = blk: {
            for (iters_raw) |iter_u32| {
                if (!isMirStoreIdx(store, @enumFromInt(iter_u32))) break :blk false;
            }
            break :blk true;
        };

        if (all_valid) {
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
                // Extra captures beyond struct fields — use bridge for resolved_type
                const field_names = if (cg.getOldMirNode(first_iter)) |fm|
                    resolveStructFieldNames(fm.resolved_type, cg.decls)
                else
                    null;
                const n_fields: usize = if (field_names) |f| f.len else caps_raw.len;
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
            return;
        }
        // Fall through to old path if iterables are not all in MirStore.
    }
    // Old MirNode fallback
    const m = cg.getOldMirNode(idx) orelse return;
    const caps = m.captures orelse &.{};
    const iters = m.iterables();

    const inline_prefix: []const u8 = if (cg.inComptFunc()) "inline " else "";

    // Tuple capture — struct field destructuring on first iterable
    if (m.is_tuple_capture and caps.len > 0) {
        try cg.emit(inline_prefix);
        try cg.emit("for (");
        // First iterable: the struct slice
        try cg.generateExprMir(cg.mirIdx(iters[0]));
        // Additional iterables (e.g., 0..)
        for (iters[1..]) |iter_m| {
            try cg.emit(", ");
            if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
                try cg.writeRangeExprMir(cg.mirIdx(iter_m));
            } else {
                try cg.generateExprMir(cg.mirIdx(iter_m));
            }
        }
        try cg.emit(") |_orhon_entry");
        // Extra captures beyond struct fields (e.g., index from 0..)
        const field_names = resolveStructFieldNames(iters[0].resolved_type, cg.decls);
        const n_fields = if (field_names) |f| f.len else caps.len;
        for (caps[n_fields..]) |cap| {
            try cg.emitFmt(", {s}", .{cap});
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
        for (m.body().children) |child| {
            try cg.emitIndent();
            try cg.generateStatementMir(cg.mirIdx(child));
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
    for (iters, 0..) |iter_m, i| {
        if (i > 0) try cg.emit(", ");
        if (iter_m.kind == .binary and (iter_m.op orelse .assign) == .range) {
            try cg.writeRangeExprMir(cg.mirIdx(iter_m));
        } else {
            try cg.generateExprMir(cg.mirIdx(iter_m));
        }
    }
    try cg.emit(") |");
    for (caps, 0..) |cap, i| {
        if (i > 0) try cg.emit(", ");
        try cg.emit(cap);
    }
    try cg.emit("| ");
    try cg.generateBlockMir(cg.mirIdx(m.body()));
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
    // New MirStore path
    if (cg.mir_store != null and isMirStoreIdx(cg.mir_store.?, idx)) {
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
        return;
    }
    // Old MirNode fallback
    const m = cg.getOldMirNode(idx) orelse return;
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
            try cg.generateExprMir(cg.mirIdx(val_m.children[1]));
            try cg.emit(");\n");
            try cg.emitIndent();
            try cg.emitFmt("_ = &_orhon_s{d};\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[0] });
            try cg.generateExprMir(cg.mirIdx(val_m.children[0]));
            try cg.emitFmt("[0.._orhon_s{d}];\n", .{destruct_idx});
            try cg.emitIndent();
            try cg.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[1] });
            try cg.generateExprMir(cg.mirIdx(val_m.children[0]));
            try cg.emitFmt("[_orhon_s{d}..];", .{destruct_idx});
            return;
        }
    }
    // Normal tuple destructuring
    const di = cg.destruct_counter;
    cg.destruct_counter += 1;
    try cg.emitFmt("const _orhon_d{d} = ", .{di});
    try cg.generateExprMir(cg.mirIdx(val_m));
    try cg.emit(";");
    for (d_names) |name| {
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
