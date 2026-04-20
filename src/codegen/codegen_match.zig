// codegen_match.zig — Match, string match, interpolated string, and compiler-func generators
// Contains: match/type match/string match/guarded match, interpolated string, compiler functions, collection/ptr generators.
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const types = @import("../types.zig");
const RT = types.ResolvedType;
const builtins = @import("../builtins.zig");
const mir_store_mod = @import("../mir_store.zig");
const mir_typed = @import("../mir_typed.zig");

const CodeGen = codegen.CodeGen;
const MirNodeIndex = mir_store_mod.MirNodeIndex;
const MirStore = mir_store_mod.MirStore;

/// MirStore-based implementation — used by new callers that already have MirNodeIndex.
pub fn mirContainsIdentifier(store: *const MirStore, idx: MirNodeIndex, name: []const u8) bool {
    if (idx == .none) return false;
    const entry = store.getNode(idx);
    if (entry.tag == .identifier) {
        const rec = mir_typed.Identifier.unpack(store, idx);
        return std.mem.eql(u8, store.strings.get(rec.name), name);
    }
    switch (entry.tag) {
        .block => {
            for (mir_typed.Block.getStmts(store, idx)) |s|
                if (mirContainsIdentifier(store, s, name)) return true;
        },
        .binary => {
            const rec = mir_typed.Binary.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.lhs, name)) return true;
            if (mirContainsIdentifier(store, rec.rhs, name)) return true;
        },
        .call => {
            const rec = mir_typed.Call.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.callee, name)) return true;
            for (store.extra_data.items[rec.args_start..rec.args_end]) |u|
                if (mirContainsIdentifier(store, @enumFromInt(u), name)) return true;
        },
        .field_access => {
            const rec = mir_typed.FieldAccess.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.object, name)) return true;
        },
        .if_stmt => {
            const rec = mir_typed.IfStmt.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.condition, name)) return true;
            if (rec.then_block != .none) if (mirContainsIdentifier(store, rec.then_block, name)) return true;
            if (rec.else_block != .none) if (mirContainsIdentifier(store, rec.else_block, name)) return true;
        },
        .var_decl => {
            const rec = mir_typed.VarDecl.unpack(store, idx);
            if (rec.value != .none) if (mirContainsIdentifier(store, rec.value, name)) return true;
        },
        .unary => {
            const rec = mir_typed.Unary.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.operand, name)) return true;
        },
        .return_stmt => {
            const rec = mir_typed.ReturnStmt.unpack(store, idx);
            if (rec.value != .none) if (mirContainsIdentifier(store, rec.value, name)) return true;
        },
        .assignment => {
            const rec = mir_typed.Assignment.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.lhs, name)) return true;
            if (mirContainsIdentifier(store, rec.rhs, name)) return true;
        },
        .index => {
            const rec = mir_typed.Index.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.object, name)) return true;
            if (mirContainsIdentifier(store, rec.index, name)) return true;
        },
        .while_stmt => {
            const rec = mir_typed.WhileStmt.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.condition, name)) return true;
            if (mirContainsIdentifier(store, rec.body, name)) return true;
        },
        .for_stmt => {
            const rec = mir_typed.ForStmt.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.body, name)) return true;
        },
        .defer_stmt => {
            const rec = mir_typed.DeferStmt.unpack(store, idx);
            if (mirContainsIdentifier(store, rec.body, name)) return true;
        },
        // Unknown node kinds are assumed not to contain the identifier. New kinds
        // must be added here if they can appear in narrowing contexts.
        else => {},
    }
    return false;
}

/// Generate a match arm body with variable name substitution.
/// Inside the body, references to `match_var` compile as `capture` instead.
/// Saves and restores the previous substitution for nested match support.
fn generateArmBodyWithSubst(cg: *CodeGen, body: MirNodeIndex, match_var: ?[]const u8, capture: []const u8) anyerror!void {
    const prev = cg.match_var_subst;
    if (match_var) |mv| {
        cg.match_var_subst = .{ .original = mv, .capture = capture };
    }
    try cg.generateBlockMir(body);
    cg.match_var_subst = prev;
}

/// Guarded match — emits as a scoped if/else chain with a temp variable.
/// Used when any arm has a guard expression (Zig switch cannot express guards).
pub fn generateGuardedMatchMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const rec = mir_typed.MatchStmt.unpack(store, idx);
    const arms_extra = store.extra_data.items[rec.arms_start..rec.arms_end];

    try cg.emitIndent();
    try cg.emit("{\n");
    cg.indent += 1;
    try cg.emitIndent();
    try cg.emit("const _m = ");
    try cg.generateExprMir(rec.value);
    try cg.emit(";\n");

    var first = true;
    var else_body: MirNodeIndex = .none;
    var guard_counter: usize = 0;

    for (arms_extra) |au32| {
        const arm_idx: MirNodeIndex = @enumFromInt(au32);
        const arm = mir_typed.MatchArm.unpack(store, arm_idx);
        const pat = arm.pattern;
        const pat_entry = store.getNode(pat);

        // Collect else arm — emit last
        if (pat_entry.tag == .identifier) {
            const id = mir_typed.Identifier.unpack(store, pat);
            if (std.mem.eql(u8, store.strings.get(id.name), "else")) {
                else_body = arm.body;
                continue;
            }
        }

        try cg.emitIndent();
        if (!first) try cg.emit(" else ");

        if (arm.guard != .none) {
            // Guarded binding: (x if guard_expr) => body
            const pat_name: []const u8 = if (pat_entry.tag == .identifier)
                store.strings.get(mir_typed.Identifier.unpack(store, pat).name)
            else
                "_";
            try cg.emitFmt("if (_g{d}: {{ const {s} = _m; break :_g{d} ", .{ guard_counter, pat_name, guard_counter });
            try cg.generateExprMir(arm.guard);
            try cg.emit("; }) {\n");
            cg.indent += 1;
            try cg.emitIndent();
            const body_uses_var = mirContainsIdentifier(store, arm.body, pat_name);
            if (body_uses_var) {
                try cg.emitFmt("const {s} = _m;\n", .{pat_name});
            } else {
                try cg.emitFmt("const {s} = _m; _ = {s};\n", .{ pat_name, pat_name });
            }
            try cg.generateBodyStatements(arm.body);
            cg.indent -= 1;
            try cg.emitIndent();
            try cg.emit("}");
            guard_counter += 1;
        } else if (pat_entry.tag == .binary) {
            const bin = mir_typed.Binary.unpack(store, pat);
            const op: parser.Operator = @enumFromInt(bin.op);
            if (op == .range) {
                try cg.emit("if (_m >= ");
                try cg.generateExprMir(bin.lhs);
                try cg.emit(" and _m <= ");
                try cg.generateExprMir(bin.rhs);
                try cg.emit(") ");
                try cg.generateBlockMir(arm.body);
            } else {
                try cg.emit("if (_m == ");
                try cg.generateExprMir(pat);
                try cg.emit(") ");
                try cg.generateBlockMir(arm.body);
            }
        } else if (pat_entry.tag == .literal) {
            const lit = mir_typed.Literal.unpack(store, pat);
            if (lit.kind == @intFromEnum(mir.LiteralKind.string)) {
                try cg.emit("if (std.mem.eql(u8, _m, ");
                try cg.generateExprMir(pat);
                try cg.emit(")) ");
                try cg.generateBlockMir(arm.body);
            } else {
                try cg.emit("if (_m == ");
                try cg.generateExprMir(pat);
                try cg.emit(") ");
                try cg.generateBlockMir(arm.body);
            }
        } else {
            try cg.emit("if (_m == ");
            try cg.generateExprMir(pat);
            try cg.emit(") ");
            try cg.generateBlockMir(arm.body);
        }

        first = false;
    }

    if (else_body != .none) {
        if (!first) try cg.emit(" else ");
        try cg.generateBlockMir(else_body);
    }

    try cg.emit("\n");
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// MIR-path match codegen — dispatches to string, type, or regular switch.
pub fn generateMatchMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const rec = mir_typed.MatchStmt.unpack(store, idx);
    const arms_extra = store.extra_data.items[rec.arms_start..rec.arms_end];
    const val_entry = store.getNode(rec.value);

    // String match — Zig has no string switch, desugar to if/else chain
    const is_string_match = blk: {
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            if (store.getNode(arm.pattern).tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, arm.pattern);
                if (lit.kind == @intFromEnum(mir.LiteralKind.string)) break :blk true;
            }
        }
        break :blk false;
    };

    // Type match — value is an arbitrary union, or any arm matches Error/null
    const is_type_match = blk: {
        if (val_entry.type_class == .arbitrary_union) break :blk true;
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            if (pat_entry.tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, pat);
                if (lit.kind == @intFromEnum(mir.LiteralKind.null_lit)) break :blk true;
            }
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                if (types.Primitive.fromName(store.strings.get(id.name)) == .err) break :blk true;
            }
        }
        break :blk false;
    };

    const is_null_union = blk: {
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            if (store.getNode(arm.pattern).tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, arm.pattern);
                if (lit.kind == @intFromEnum(mir.LiteralKind.null_lit)) break :blk true;
            }
        }
        break :blk false;
    };

    // Check for guarded arms — must use if/else chain (Zig switch cannot express guards)
    const has_guard = blk: {
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            if (arm.guard != .none) break :blk true;
        }
        break :blk false;
    };

    if (has_guard) {
        try cg.generateGuardedMatchMir(idx);
    } else if (is_string_match) {
        try cg.generateStringMatchMir(idx);
    } else if (is_type_match) {
        try cg.generateTypeMatchMir(idx, is_null_union);
    } else {
        // Regular switch
        try cg.emit("switch (");
        if (val_entry.tag == .identifier) {
            const val_rt = if (val_entry.type_id != .none) store.types.get(val_entry.type_id) else .unknown;
            if (val_rt == .ptr) {
                const val_id = mir_typed.Identifier.unpack(store, rec.value);
                try cg.emitFmt("{s}.*", .{store.strings.get(val_id.name)});
            } else {
                try cg.generateExprMir(rec.value);
            }
        } else {
            try cg.generateExprMir(rec.value);
        }
        try cg.emit(") {\n");
        cg.indent += 1;
        var has_wildcard = false;
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            try cg.emitIndent();
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                const id_name = store.strings.get(id.name);
                if (std.mem.eql(u8, id_name, "else")) {
                    has_wildcard = true;
                    try cg.emit("else");
                } else {
                    try cg.generateExprMir(pat);
                }
            } else if (pat_entry.tag == .binary) {
                const bin = mir_typed.Binary.unpack(store, pat);
                const op: parser.Operator = @enumFromInt(bin.op);
                if (op == .range) {
                    try cg.generateExprMir(bin.lhs);
                    try cg.emit("...");
                    try cg.generateExprMir(bin.rhs);
                } else {
                    try cg.generateExprMir(pat);
                }
            } else {
                try cg.generateExprMir(pat);
            }
            try cg.emit(" => ");
            try cg.generateBlockMir(arm.body);
            try cg.emit(",\n");
        }
        if (!has_wildcard) {
            var is_enum_switch = false;
            for (arms_extra) |au32| {
                const arm_idx: MirNodeIndex = @enumFromInt(au32);
                const arm = mir_typed.MatchArm.unpack(store, arm_idx);
                if (store.getNode(arm.pattern).tag == .identifier) {
                    const id = mir_typed.Identifier.unpack(store, arm.pattern);
                    if (id.resolved_kind == 1) { // enum_variant
                        is_enum_switch = true;
                        break;
                    }
                }
            }
            if (!is_enum_switch) {
                try cg.emitIndent();
                try cg.emit("else => {},\n");
            }
        }
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("}");
    }
}

/// MIR-path type match (arbitrary/error/null union switch).
pub fn generateTypeMatchMir(cg: *CodeGen, idx: MirNodeIndex, is_null_union: bool) anyerror!void {
    const store = cg.mir_store orelse return;
    const rec = mir_typed.MatchStmt.unpack(store, idx);
    const arms_extra = store.extra_data.items[rec.arms_start..rec.arms_end];
    const val_entry = store.getNode(rec.value);

    const match_var: ?[]const u8 = if (val_entry.tag == .identifier)
        store.strings.get(mir_typed.Identifier.unpack(store, rec.value).name)
    else
        null;

    const is_arbitrary = blk: {
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                if (types.Primitive.fromName(store.strings.get(id.name)) == .err) break :blk false;
            }
            if (pat_entry.tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, pat);
                if (lit.kind == @intFromEnum(mir.LiteralKind.null_lit)) break :blk false;
            }
        }
        break :blk true;
    };

    const is_error_union = blk: {
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            if (store.getNode(arm.pattern).tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, arm.pattern);
                if (types.Primitive.fromName(store.strings.get(id.name)) == .err) break :blk true;
            }
        }
        break :blk false;
    };

    const val_tc = val_entry.type_class;
    const is_null_error = val_tc == .null_error_union or (is_error_union and is_null_union);

    if (is_null_error) {
        // match on ?anyerror!T → three-way nested if
        var value_body: MirNodeIndex = .none;
        var error_body: MirNodeIndex = .none;
        var null_body: MirNodeIndex = .none;
        var else_body: MirNodeIndex = .none;
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                const n = store.strings.get(id.name);
                if (types.Primitive.fromName(n) == .err) {
                    error_body = arm.body;
                } else if (std.mem.eql(u8, n, "else")) {
                    else_body = arm.body;
                } else {
                    value_body = arm.body;
                }
            } else if (pat_entry.tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, pat);
                if (lit.kind == @intFromEnum(mir.LiteralKind.null_lit)) {
                    null_body = arm.body;
                } else {
                    value_body = arm.body;
                }
            } else {
                value_body = arm.body;
            }
        }
        const active_val_body = if (value_body != .none) value_body else else_body;
        const active_err_body = if (error_body != .none) error_body else else_body;
        const val_uses = if (active_val_body != .none) (if (match_var) |mv| mirContainsIdentifier(store, active_val_body, mv) else false) else false;
        const err_uses = if (active_err_body != .none) (if (match_var) |mv| mirContainsIdentifier(store, active_err_body, mv) else false) else false;
        try cg.emit("if (");
        try cg.generateExprMir(rec.value);
        try cg.emit(") |_eu| ");
        if (val_uses) try cg.emit("if (_eu) |_match_val| ") else try cg.emit("if (_eu) |_| ");
        if (active_val_body != .none) {
            try generateArmBodyWithSubst(cg, active_val_body, match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        if (err_uses) try cg.emit(" else |_match_err| ") else try cg.emit(" else |_| ");
        if (active_err_body != .none) {
            try generateArmBodyWithSubst(cg, active_err_body, match_var, "_match_err");
        } else {
            try cg.emit("{}");
        }
        try cg.emit(" else ");
        const active_null_body = if (null_body != .none) null_body else else_body;
        if (active_null_body != .none) {
            try cg.generateBlockMir(active_null_body);
        } else {
            try cg.emit("{}");
        }
        return;
    }

    if (is_error_union) {
        // match on anyerror!T → if (val) |_match_val| { ... } else |_match_err| { ... }
        var value_body: MirNodeIndex = .none;
        var error_body: MirNodeIndex = .none;
        var else_body: MirNodeIndex = .none;
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                const n = store.strings.get(id.name);
                if (types.Primitive.fromName(n) == .err) {
                    error_body = arm.body;
                } else if (std.mem.eql(u8, n, "else")) {
                    else_body = arm.body;
                } else {
                    value_body = arm.body;
                }
            } else {
                value_body = arm.body;
            }
        }
        const active_val_body = if (value_body != .none) value_body else else_body;
        const val_uses = if (active_val_body != .none) (if (match_var) |mv| mirContainsIdentifier(store, active_val_body, mv) else false) else false;
        const err_uses = if (error_body != .none) (if (match_var) |mv| mirContainsIdentifier(store, error_body, mv) else false) else false;
        try cg.emit("if (");
        try cg.generateExprMir(rec.value);
        if (val_uses) try cg.emit(") |_match_val| ") else try cg.emit(") |_| ");
        if (active_val_body != .none) {
            try generateArmBodyWithSubst(cg, active_val_body, match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        if (err_uses) try cg.emit(" else |_match_err| ") else try cg.emit(" else |_| ");
        if (error_body != .none) {
            try generateArmBodyWithSubst(cg, error_body, match_var, "_match_err");
        } else {
            try cg.emit("{}");
        }
        return;
    }

    if (is_null_union) {
        // match on ?T → if (val) |_match_val| { ... } else { ... }
        var value_body: MirNodeIndex = .none;
        var null_body: MirNodeIndex = .none;
        var else_body: MirNodeIndex = .none;
        for (arms_extra) |au32| {
            const arm_idx: MirNodeIndex = @enumFromInt(au32);
            const arm = mir_typed.MatchArm.unpack(store, arm_idx);
            const pat = arm.pattern;
            const pat_entry = store.getNode(pat);
            if (pat_entry.tag == .literal) {
                const lit = mir_typed.Literal.unpack(store, pat);
                if (lit.kind == @intFromEnum(mir.LiteralKind.null_lit)) {
                    null_body = arm.body;
                    continue;
                }
            }
            if (pat_entry.tag == .identifier) {
                const id = mir_typed.Identifier.unpack(store, pat);
                if (std.mem.eql(u8, store.strings.get(id.name), "else")) {
                    else_body = arm.body;
                    continue;
                }
            }
            value_body = arm.body;
        }
        const active_val_body = if (value_body != .none) value_body else else_body;
        const val_uses = if (active_val_body != .none) (if (match_var) |mv| mirContainsIdentifier(store, active_val_body, mv) else false) else false;
        try cg.emit("if (");
        try cg.generateExprMir(rec.value);
        if (val_uses) try cg.emit(") |_match_val| ") else try cg.emit(") |_| ");
        if (active_val_body != .none) {
            try generateArmBodyWithSubst(cg, active_val_body, match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        try cg.emit(" else ");
        const active_null_body = if (null_body != .none) null_body else else_body;
        if (active_null_body != .none) {
            try cg.generateBlockMir(active_null_body);
        } else {
            try cg.emit("{}");
        }
        return;
    }

    // Arbitrary union — switch with positional tag arms.
    try cg.emit("switch (");
    try cg.generateExprMir(rec.value);
    try cg.emit(") {\n");
    cg.indent += 1;

    const max_arity = 32;
    var sorted_buf: [max_arity][]const u8 = undefined;
    var sorted_len: usize = 0;
    const val_rt = if (val_entry.type_id != .none) store.types.get(val_entry.type_id) else @import("../types.zig").ResolvedType.unknown;
    if (val_rt == .union_type) {
        for (val_rt.union_type) |mem| {
            const n = mem.name();
            if (types.Primitive.fromName(n) == .err or types.Primitive.fromName(n) == .null_type) continue;
            if (sorted_len >= max_arity) break;
            sorted_buf[sorted_len] = n;
            sorted_len += 1;
        }
        mir.union_sort.sortMemberNames(sorted_buf[0..sorted_len]);
    }

    for (arms_extra) |au32| {
        const arm_idx: MirNodeIndex = @enumFromInt(au32);
        const arm = mir_typed.MatchArm.unpack(store, arm_idx);
        const pat = arm.pattern;
        const pat_entry = store.getNode(pat);
        try cg.emitIndent();

        if (pat_entry.tag == .identifier) {
            const id = mir_typed.Identifier.unpack(store, pat);
            const pat_name = store.strings.get(id.name);
            if (std.mem.eql(u8, pat_name, "else")) {
                try cg.emit("else");
            } else if (is_arbitrary) {
                if (mir.union_sort.positionalIndex(sorted_buf[0..sorted_len], pat_name)) |pos_idx| {
                    try cg.emitFmt("._{d}", .{pos_idx});
                } else {
                    try cg.emitFmt("._{s}", .{pat_name});
                }
            } else {
                try cg.generateExprMir(pat);
            }
        } else {
            try cg.generateExprMir(pat);
        }

        const arm_uses = if (match_var) |mv| mirContainsIdentifier(store, arm.body, mv) else false;
        if (arm_uses) try cg.emit(" => |_match_val| ") else try cg.emit(" => ");
        try generateArmBodyWithSubst(cg, arm.body, match_var, "_match_val");
        try cg.emit(",\n");
    }

    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// MIR-path string match — desugars to if/else chain.
pub fn generateStringMatchMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const rec = mir_typed.MatchStmt.unpack(store, idx);
    const arms_extra = store.extra_data.items[rec.arms_start..rec.arms_end];
    const val_entry = store.getNode(rec.value);

    var first = true;
    var wildcard_body: MirNodeIndex = .none;

    for (arms_extra) |au32| {
        const arm_idx: MirNodeIndex = @enumFromInt(au32);
        const arm = mir_typed.MatchArm.unpack(store, arm_idx);
        const pat = arm.pattern;
        const pat_entry = store.getNode(pat);

        if (pat_entry.tag == .identifier) {
            const id = mir_typed.Identifier.unpack(store, pat);
            if (std.mem.eql(u8, store.strings.get(id.name), "else")) {
                wildcard_body = arm.body;
                continue;
            }
        }

        if (first) {
            try cg.emit("if (std.mem.eql(u8, ");
            first = false;
        } else {
            try cg.emit(" else if (std.mem.eql(u8, ");
        }

        if (val_entry.tag == .identifier) {
            const val_rt = if (val_entry.type_id != .none) store.types.get(val_entry.type_id) else .unknown;
            if (val_rt == .ptr) {
                const val_id = mir_typed.Identifier.unpack(store, rec.value);
                try cg.emitFmt("{s}.*", .{store.strings.get(val_id.name)});
            } else {
                try cg.generateExprMir(rec.value);
            }
        } else {
            try cg.generateExprMir(rec.value);
        }
        try cg.emit(", ");
        try cg.generateExprMir(pat);
        try cg.emit(")) ");
        try cg.generateBlockMir(arm.body);
    }

    if (wildcard_body != .none) {
        if (first) {
            try cg.generateBlockMir(wildcard_body);
        } else {
            try cg.emit(" else ");
            try cg.generateBlockMir(wildcard_body);
        }
    } else if (!first) {
        try cg.emit(" else {}");
    }
}

/// MIR-path interpolated string — MirStore variant.
/// Reads (tag, payload) pairs from extra_data[parts_start..parts_end]:
///   tag==0: string literal (payload is StringIndex)
///   tag==1: expression (payload is MirNodeIndex)
/// Hoists the allocPrint call to a temp variable in pre_stmts (same as old variant).
pub fn generateInterpolatedStringMirFromStore(cg: *CodeGen, store: *const MirStore, parts_start: u32, parts_end: u32) anyerror!void {
    const n = cg.interp_count;
    cg.interp_count += 1;

    // Build indent prefix for hoisted lines
    var indent_buf: [256]u8 = undefined;
    var indent_len: usize = 0;
    var i: usize = 0;
    while (i < cg.indent and indent_len + 4 <= indent_buf.len) : (i += 1) {
        @memcpy(indent_buf[indent_len .. indent_len + 4], "    ");
        indent_len += 4;
    }
    const indent_str = indent_buf[0..indent_len];

    var name_buf: [32]u8 = undefined;
    const var_name = std.fmt.bufPrint(&name_buf, "_interp_{d}", .{n}) catch "_interp";
    try cg.pre_stmts.appendSlice(cg.allocator, indent_str);
    try cg.pre_stmts.appendSlice(cg.allocator, "const ");
    try cg.pre_stmts.appendSlice(cg.allocator, var_name);
    try cg.pre_stmts.appendSlice(cg.allocator, " = std.fmt.allocPrint(std.heap.smp_allocator, \"");

    // Build format string into pre_stmts
    // Pairs: extra_data[parts_start..parts_end] = (tag, payload) pairs, step 2
    var j: u32 = parts_start;
    while (j + 1 <= parts_end) : (j += 2) {
        const tag = store.extra_data.items[j];
        const payload = store.extra_data.items[j + 1];
        if (tag == 0) {
            // String literal part — payload is StringIndex
            const si: mir_typed.StringIndex = @enumFromInt(payload);
            const text = store.strings.get(si);
            for (text) |ch| {
                switch (ch) {
                    '{' => try cg.pre_stmts.appendSlice(cg.allocator, "{{"),
                    '}' => try cg.pre_stmts.appendSlice(cg.allocator, "}}"),
                    '\\' => try cg.pre_stmts.appendSlice(cg.allocator, "\\"),
                    else => try cg.pre_stmts.append(cg.allocator, ch),
                }
            }
        } else {
            // Expression part — payload is MirNodeIndex
            const expr_idx: MirNodeIndex = @enumFromInt(payload);
            if (CodeGen.mirIsStringFromStore(store, expr_idx)) {
                try cg.pre_stmts.appendSlice(cg.allocator, "{s}");
            } else {
                try cg.pre_stmts.appendSlice(cg.allocator, "{}");
            }
        }
    }
    try cg.pre_stmts.appendSlice(cg.allocator, "\", .{");

    // Redirect output to pre_stmts to emit arg expressions
    const saved_output = cg.output;
    cg.output = cg.pre_stmts;
    var first = true;
    var k: u32 = parts_start;
    while (k + 1 <= parts_end) : (k += 2) {
        const tag = store.extra_data.items[k];
        const payload = store.extra_data.items[k + 1];
        if (tag == 1) {
            // Expression part
            if (!first) try cg.emit(", ");
            const expr_idx: MirNodeIndex = @enumFromInt(payload);
            try cg.generateExprMir(expr_idx);
            first = false;
        }
    }
    cg.pre_stmts = cg.output;
    cg.output = saved_output;

    // Use error propagation only if the enclosing function has an error return type.
    const ret_tc = cg.funcReturnTypeClass();
    if (ret_tc == .error_union or ret_tc == .null_error_union) {
        try cg.pre_stmts.appendSlice(cg.allocator, "}) catch |err| return err;\n");
    } else {
        try cg.pre_stmts.appendSlice(cg.allocator, "}) catch unreachable;\n");
    }
    // Append: <indent>defer std.heap.smp_allocator.free(_interp_N);
    try cg.pre_stmts.appendSlice(cg.allocator, indent_str);
    try cg.pre_stmts.appendSlice(cg.allocator, "defer std.heap.smp_allocator.free(");
    try cg.pre_stmts.appendSlice(cg.allocator, var_name);
    try cg.pre_stmts.appendSlice(cg.allocator, ");\n");

    // Emit just the temp var name as the expression
    try cg.emit(var_name);
}

/// Emit the first argument to a struct-introspection compiler function.
/// If the arg is a type reference (type_expr, or an identifier whose name IS the
/// resolved type name — i.e. a struct/enum name used directly), emit it as-is.
/// Otherwise wrap in @TypeOf() to handle value arguments (e.g. a variable).
fn emitIntrospectionType(cg: *CodeGen, store: *const MirStore, arg_idx: MirNodeIndex) anyerror!void {
    const entry = store.getNode(arg_idx);
    const is_type_ref: bool = switch (entry.tag) {
        .type_expr => true,
        .identifier => blk: {
            const rec = mir_typed.Identifier.unpack(store, arg_idx);
            const id_name = store.strings.get(rec.name);
            if (entry.type_id == .none) {
                // Unknown-type identifier in a compt func — likely a type parameter.
                break :blk cg.inComptFunc();
            }
            const rt = store.types.get(entry.type_id);
            break :blk switch (rt) {
                .named => |n| std.mem.eql(u8, id_name, n),
                .primitive => |p| p == .@"type" and cg.inComptFunc(),
                else => false,
            };
        },
        else => blk: {
            if (entry.type_id == .none) {
                if (entry.tag == .compiler_fn) {
                    const cf_rec = mir_typed.CompilerFn.unpack(store, arg_idx);
                    const name = store.strings.get(cf_rec.name);
                    if (std.mem.eql(u8, name, "fieldType")) break :blk true;
                }
                break :blk false;
            }
            const rt = store.types.get(entry.type_id);
            break :blk rt == .primitive and rt.primitive == .@"type";
        },
    };
    if (is_type_ref) {
        try cg.generateExprMir(arg_idx);
    } else {
        try cg.emit("@TypeOf(");
        try cg.generateExprMir(arg_idx);
        try cg.emit(")");
    }
}

/// MIR-path compiler function (@typename, @cast, @size, etc.).
pub fn generateCompilerFuncMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const rec = mir_typed.CompilerFn.unpack(store, idx);
    const cf_name = store.strings.get(rec.name);
    const args_extra = store.extra_data.items[rec.args_start..rec.args_end];

    switch (builtins.CompilerFunc.fromName(cf_name) orelse unreachable) {
        .typename => {
            try cg.emit("@typeName(@TypeOf(");
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
            try cg.emit("))");
        },
        .typeid => {
            try cg.emit("@intFromPtr(@typeName(@TypeOf(");
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
            try cg.emit(")).ptr)");
        },
        .cast => {
            if (args_extra.len >= 2) {
                const arg0: MirNodeIndex = @enumFromInt(args_extra[0]);
                const arg1: MirNodeIndex = @enumFromInt(args_extra[1]);
                const arg0_entry = store.getNode(arg0);
                const arg1_entry = store.getNode(arg1);
                // typeToZig walks AST — get *parser.Node via span back-pointer
                const span0 = arg0_entry.span;
                const ast_node0 = cg.getAstNode(span0) orelse return;
                const target_type = try cg.typeToZig(ast_node0);
                const target_is_float = target_type.len > 0 and target_type[0] == 'f';
                const target_is_enum = arg0_entry.tag == .identifier and
                    mir_typed.Identifier.unpack(store, arg0).resolved_kind == 2; // enum_type_name
                const source_is_float = blk: {
                    if (arg1_entry.tag == .literal) {
                        const lit = mir_typed.Literal.unpack(store, arg1);
                        if (lit.kind == @intFromEnum(mir.LiteralKind.float)) break :blk true;
                    }
                    if (arg1_entry.type_id != .none) {
                        const rt = store.types.get(arg1_entry.type_id);
                        if (rt == .primitive and rt.primitive.isFloat()) break :blk true;
                    }
                    break :blk false;
                };
                try cg.emitFmt("@as({s}, ", .{target_type});
                if (target_is_enum) {
                    try cg.emit("@enumFromInt(");
                } else if (target_is_float and source_is_float) {
                    try cg.emit("@floatCast(");
                } else if (target_is_float) {
                    try cg.emit("@floatFromInt(");
                } else if (source_is_float) {
                    try cg.emit("@intFromFloat(");
                } else {
                    try cg.emit("@intCast(");
                }
                try cg.generateExprMir(arg1);
                try cg.emit("))");
            } else if (args_extra.len == 1) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(@enumFromInt(args_extra[0]));
                try cg.emit(")");
            }
        },
        .size => {
            try cg.emit("@sizeOf(");
            if (args_extra.len > 0) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            try cg.emit(")");
        },
        .@"align" => {
            try cg.emit("@alignOf(");
            if (args_extra.len > 0) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            try cg.emit(")");
        },
        .copy => {
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
        },
        .move => {
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
        },
        .assert => {
            if (args_extra.len >= 2) {
                try cg.emit("if (!(");
                try cg.generateExprMir(@enumFromInt(args_extra[0]));
                try cg.emit(")) @panic(");
                try cg.generateExprMir(@enumFromInt(args_extra[1]));
                try cg.emit(")");
            } else {
                if (cg.in_test_block) {
                    try cg.emit("try std.testing.expect(");
                } else {
                    try cg.emit("std.debug.assert(");
                }
                if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
                try cg.emit(")");
            }
        },
        .swap => {
            if (args_extra.len == 2) {
                const arg0: MirNodeIndex = @enumFromInt(args_extra[0]);
                const arg1: MirNodeIndex = @enumFromInt(args_extra[1]);
                try cg.emit("std.mem.swap(@TypeOf(");
                try cg.generateExprMir(arg0);
                try cg.emit("), &");
                try cg.generateExprMir(arg0);
                try cg.emit(", &");
                try cg.generateExprMir(arg1);
                try cg.emit(")");
            }
        },
        .hasField => {
            try cg.emit("@hasField(");
            if (args_extra.len >= 1) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            if (args_extra.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(@enumFromInt(args_extra[1]));
            }
            try cg.emit(")");
        },
        .hasDecl => {
            try cg.emit("@hasDecl(");
            if (args_extra.len >= 1) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            if (args_extra.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(@enumFromInt(args_extra[1]));
            }
            try cg.emit(")");
        },
        .fieldType => {
            try cg.emit("@FieldType(");
            if (args_extra.len >= 1) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            if (args_extra.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(@enumFromInt(args_extra[1]));
            }
            try cg.emit(")");
        },
        .fieldNames => {
            try cg.emit("std.meta.fieldNames(");
            if (args_extra.len >= 1) try emitIntrospectionType(cg, store, @enumFromInt(args_extra[0]));
            try cg.emit(")");
        },
        .typeOf => {
            try cg.emit("@TypeOf(");
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
            try cg.emit(")");
        },
        .splitAt => {
            try cg.emit("/* @splitAt must be used with destructuring: const a, b = @splitAt(arr, n) */");
        },
        .wrap => {
            if (args_extra.len > 0) try cg.generateWrappingExprMir(@enumFromInt(args_extra[0]));
        },
        .sat => {
            if (args_extra.len > 0) try cg.generateSaturatingExprMir(@enumFromInt(args_extra[0]));
        },
        .overflow => {
            if (args_extra.len > 0) try cg.generateOverflowExprMir(@enumFromInt(args_extra[0]));
        },
        .compileError => {
            try cg.emit("@compileError(");
            if (args_extra.len > 0) try cg.generateExprMir(@enumFromInt(args_extra[0]));
            try cg.emit(")");
        },
        // @type is an internal desugaring artifact from `x is T` — always handled as
        // part of binary `is` expression in codegen_exprs, never reaches here standalone
        .@"type" => @panic("@type should not reach generateCompilerFuncMir"),
    }
}

// ── Operator maps for arithmetic builtins ───────────────────────

fn mapWrappingOp(op: parser.Operator) ?[]const u8 {
    return switch (op) {
        .add => "+%",
        .sub => "-%",
        .mul => "*%",
        else => null,
    };
}

fn mapSaturatingOp(op: parser.Operator) ?[]const u8 {
    return switch (op) {
        .add => "+|",
        .sub => "-|",
        .mul => "*|",
        else => null,
    };
}

fn mapOverflowBuiltin(op: parser.Operator) ?[]const u8 {
    return switch (op) {
        .add => "@addWithOverflow",
        .sub => "@subWithOverflow",
        .mul => "@mulWithOverflow",
        else => null,
    };
}

// ── Wrapping / saturating / overflow: MIR paths ────────────────────

pub fn generateWrappingExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const entry = store.getNode(idx);
    if (entry.tag == .binary) {
        const bin = mir_typed.Binary.unpack(store, idx);
        const op: parser.Operator = @enumFromInt(bin.op);
        if (mapWrappingOp(op)) |wop| {
            try cg.generateExprMir(bin.lhs);
            try cg.emitFmt(" {s} ", .{wop});
            try cg.generateExprMir(bin.rhs);
            return;
        }
    }
    try cg.generateExprMir(idx);
}

pub fn generateSaturatingExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const entry = store.getNode(idx);
    if (entry.tag == .binary) {
        const bin = mir_typed.Binary.unpack(store, idx);
        const op: parser.Operator = @enumFromInt(bin.op);
        if (mapSaturatingOp(op)) |sop| {
            try cg.generateExprMir(bin.lhs);
            try cg.emitFmt(" {s} ", .{sop});
            try cg.generateExprMir(bin.rhs);
            return;
        }
    }
    try cg.generateExprMir(idx);
}

// ── Overflow: MIR path ──────────────────────────────────────────
// overflow(a + b) → (blk: { const _ov = @addWithOverflow(a, b);
//   if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(a), error.overflow)
//   else break :blk @as(anyerror!@TypeOf(a), _ov[0]); })

pub fn generateOverflowExprMir(cg: *CodeGen, idx: MirNodeIndex) anyerror!void {
    const store = cg.mir_store orelse return;
    const entry = store.getNode(idx);
    if (entry.tag == .binary) {
        const bin = mir_typed.Binary.unpack(store, idx);
        const op: parser.Operator = @enumFromInt(bin.op);
        if (mapOverflowBuiltin(op)) |builtin| {
            try cg.emit("(blk: { const _ov = ");
            try cg.emitFmt("{s}(", .{builtin});
            try cg.generateExprMir(bin.lhs);
            try cg.emit(", ");
            try cg.generateExprMir(bin.rhs);
            try cg.emit("); if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(");
            try cg.generateExprMir(bin.lhs);
            try cg.emit("), error.overflow) else break :blk @as(anyerror!@TypeOf(");
            try cg.generateExprMir(bin.lhs);
            try cg.emit("), _ov[0]); })");
            return;
        }
    }
    try cg.generateExprMir(idx);
}

/// MIR-path fill default arguments.
/// Old MirNode tree no longer runs — getOldMirNode always returns null.
pub fn fillDefaultArgsMir(cg: *CodeGen, callee_idx: MirNodeIndex, actual_arg_count: usize) anyerror!void {
    _ = cg;
    _ = callee_idx;
    _ = actual_arg_count;
}

// ============================================================
// FREE FUNCTIONS (file-scope, not methods)
// ============================================================

pub fn opToZig(op: parser.Operator) []const u8 {
    return op.toZig();
}

/// Check if a field name is a type name used for union value access (result.i32, result.User)
pub fn isResultValueField(name: []const u8, decls: ?*declarations.DeclTable) bool {
    // .value — universal unwrap syntax for error/null unions
    if (std.mem.eql(u8, name, "value")) return true;
    // Primitive type names — always valid as union payload access
    if (types.isPrimitiveName(name)) return true;
    // Known user-defined types from the declaration table
    if (decls) |d| {
        if (d.structs.contains(name)) return true;
        if (d.enums.contains(name)) return true;
    }
    // Builtin types that can appear in unions
    if (builtins.isBuiltinType(name)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────

test "isResultValueField" {
    try std.testing.expect(isResultValueField("value", null));
    try std.testing.expect(isResultValueField("i32", null));
    try std.testing.expect(isResultValueField("str", null));
    try std.testing.expect(isResultValueField("f64", null));
    try std.testing.expect(!isResultValueField("x", null));
    try std.testing.expect(!isResultValueField("myVar", null));
}

test "isResultValueField with decls" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    try decl_table.structs.put("Player", .{ .name = "Player", .fields = &.{}, .is_pub = true });
    try std.testing.expect(isResultValueField("Player", &decl_table));
    try std.testing.expect(!isResultValueField("Unknown", &decl_table));
}

test "mapWrappingOp" {
    try std.testing.expectEqualStrings("+%", mapWrappingOp(.add).?);
    try std.testing.expectEqualStrings("-%", mapWrappingOp(.sub).?);
    try std.testing.expectEqualStrings("*%", mapWrappingOp(.mul).?);
    try std.testing.expect(mapWrappingOp(.div) == null);
    try std.testing.expect(mapWrappingOp(.mod) == null);
}

test "mapSaturatingOp" {
    try std.testing.expectEqualStrings("+|", mapSaturatingOp(.add).?);
    try std.testing.expectEqualStrings("-|", mapSaturatingOp(.sub).?);
    try std.testing.expectEqualStrings("*|", mapSaturatingOp(.mul).?);
    try std.testing.expect(mapSaturatingOp(.div) == null);
}

test "mapOverflowBuiltin" {
    try std.testing.expectEqualStrings("@addWithOverflow", mapOverflowBuiltin(.add).?);
    try std.testing.expectEqualStrings("@subWithOverflow", mapOverflowBuiltin(.sub).?);
    try std.testing.expectEqualStrings("@mulWithOverflow", mapOverflowBuiltin(.mul).?);
    try std.testing.expect(mapOverflowBuiltin(.div) == null);
}

