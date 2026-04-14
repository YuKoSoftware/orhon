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

const CodeGen = codegen.CodeGen;

pub fn mirContainsIdentifier(m: *mir.MirNode, name: []const u8) bool {
    if (m.kind == .identifier and std.mem.eql(u8, m.name orelse "", name)) return true;
    for (m.children) |child| {
        if (mirContainsIdentifier(child, name)) return true;
    }
    return false;
}

/// Check if the match arm body references the match variable.
fn armUsesMatchVar(body: *mir.MirNode, match_var: ?[]const u8) bool {
    const mv = match_var orelse return false;
    return mirContainsIdentifier(body, mv);
}

/// Generate a match arm body with variable name substitution.
/// Inside the body, references to `match_var` compile as `capture` instead.
/// Saves and restores the previous substitution for nested match support.
fn generateArmBodyWithSubst(cg: *CodeGen, body: *mir.MirNode, match_var: ?[]const u8, capture: []const u8) anyerror!void {
    const prev = cg.match_var_subst;
    if (match_var) |mv| {
        cg.match_var_subst = .{ .original = mv, .capture = capture };
    }
    try cg.generateBlockMir(body);
    cg.match_var_subst = prev;
}

/// Returns true if any arm in the match has a guard expression.
pub fn hasGuardedArm(arms: []*mir.MirNode) bool {
    for (arms) |arm_mir| {
        if (arm_mir.guard() != null) return true;
    }
    return false;
}

/// Guarded match — emits as a scoped if/else chain with a temp variable.
/// Used when any arm has a guard expression (Zig switch cannot express guards).
///
/// For guarded binding `(x if x > 0)`, emits:
///   if (_g0: { const x = _m; break :_g0 x > 0; }) { const x = _m; body }
///
/// The labeled block lets the guard expression reference the bound variable while
/// still producing a bool for the outer if. The `else if` chain then correctly
/// short-circuits: only the first matching guard fires its body.
pub fn generateGuardedMatchMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    // Emit wrapper block with temp var: const _m = <match_value>;
    try cg.emitIndent();
    try cg.emit("{\n");
    cg.indent += 1;
    try cg.emitIndent();
    try cg.emit("const _m = ");
    try cg.generateExprMir(m.value());
    try cg.emit(";\n");

    var first = true;
    var else_arm: ?*mir.MirNode = null;
    var guard_counter: usize = 0;

    for (m.matchArms()) |arm_mir| {
        const pat_m = arm_mir.pattern();
        const pat_name = pat_m.name orelse "";

        // Collect else arm — emit last
        if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
            else_arm = arm_mir;
            continue;
        }

        try cg.emitIndent();
        if (!first) {
            try cg.emit(" else ");
        }

        if (arm_mir.guard()) |guard_node| {
            // Guarded binding: (x if guard_expr) => body
            //
            // Desugar to a labeled comptime block so the guard can reference the
            // bound variable, while the outer if-else chain still works correctly.
            //
            // if (_g0: { const x = _m; break :_g0 x > 0; }) {
            //     const x = _m;
            //     body
            // }
            //
            // This is correct for chained else-if: only the first matching guard
            // fires. The labeled block evaluates to bool, so Zig treats it as a
            // normal boolean condition for the if expression.
            try cg.emitFmt("if (_g{d}: {{ const {s} = _m; break :_g{d} ", .{ guard_counter, pat_name, guard_counter });
            try cg.generateExprMir(guard_node);
            try cg.emit("; }) {\n");
            cg.indent += 1;
            try cg.emitIndent();
            // Bind the guard variable so body statements can reference it.
            // If the body doesn't reference the variable, suppress with _ = x to
            // avoid "unused local constant" from Zig. If the body does reference it,
            // suppress the "pointless discard" by omitting _ = x.
            const body_uses_var = mirContainsIdentifier(arm_mir.body(), pat_name);
            if (body_uses_var) {
                try cg.emitFmt("const {s} = _m;\n", .{pat_name});
            } else {
                try cg.emitFmt("const {s} = _m; _ = {s};\n", .{ pat_name, pat_name });
            }
            try cg.generateBodyStatements(arm_mir.body());
            cg.indent -= 1;
            try cg.emitIndent();
            try cg.emit("}");
            guard_counter += 1;
        } else if (pat_m.kind == .binary and (pat_m.op orelse .eq) == .range) {
            // Range pattern: (1..10)
            try cg.emit("if (_m >= ");
            try cg.generateExprMir(pat_m.lhs());
            try cg.emit(" and _m <= ");
            try cg.generateExprMir(pat_m.rhs());
            try cg.emit(") ");
            try cg.generateBlockMir(arm_mir.body());
        } else if (pat_m.literal_kind == .string) {
            // String pattern
            try cg.emit("if (std.mem.eql(u8, _m, ");
            try cg.generateExprMir(pat_m);
            try cg.emit(")) ");
            try cg.generateBlockMir(arm_mir.body());
        } else {
            // Plain value: integer, enum variant, etc.
            try cg.emit("if (_m == ");
            try cg.generateExprMir(pat_m);
            try cg.emit(") ");
            try cg.generateBlockMir(arm_mir.body());
        }

        first = false;
    }

    // Emit else arm last
    if (else_arm) |ea| {
        if (!first) {
            try cg.emit(" else ");
        }
        try cg.generateBlockMir(ea.body());
    }

    try cg.emit("\n");
    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// MIR-path match codegen — dispatches to string, type, or regular switch.
pub fn generateMatchMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    // String match — Zig has no string switch, desugar to if/else chain
    const is_string_match = blk: {
        for (m.matchArms()) |arm_mir| {
            if (arm_mir.pattern().literal_kind == .string) break :blk true;
        }
        break :blk false;
    };

    // Type match — any arm is `Error`, `null`, or value is an arbitrary union
    const is_type_match = blk: {
        if (m.value().type_class == .arbitrary_union) break :blk true;
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            if (pat_m.literal_kind == .null_lit) break :blk true;
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR))
                break :blk true;
        }
        break :blk false;
    };

    const is_null_union = blk: {
        for (m.matchArms()) |arm_mir| {
            if (arm_mir.pattern().literal_kind == .null_lit) break :blk true;
        }
        break :blk false;
    };

    // Check for guarded arms — must use if/else chain (Zig switch cannot express guards)
    const has_guard = hasGuardedArm(m.matchArms());

    if (has_guard) {
        try cg.generateGuardedMatchMir(m);
    } else if (is_string_match) {
        try cg.generateStringMatchMir(m);
    } else if (is_type_match) {
        try cg.generateTypeMatchMir(m, is_null_union);
    } else {
        // Regular switch
        try cg.emit("switch (");
        const val_m = m.value();
        if (val_m.kind == .identifier and val_m.resolved_type == .ptr) {
            try cg.emitFmt("{s}.*", .{val_m.name orelse ""});
        } else {
            try cg.generateExprMir(val_m);
        }
        try cg.emit(") {\n");
        cg.indent += 1;
        var has_wildcard = false;
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            try cg.emitIndent();
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", "else")) {
                has_wildcard = true;
                try cg.emit("else");
            } else if (pat_m.kind == .binary and (pat_m.op orelse .eq) == .range) {
                try cg.generateExprMir(pat_m.lhs());
                try cg.emit("...");
                try cg.generateExprMir(pat_m.rhs());
            } else {
                try cg.generateExprMir(pat_m);
            }
            try cg.emit(" => ");
            try cg.generateBlockMir(arm_mir.body());
            try cg.emit(",\n");
        }
        if (!has_wildcard) {
            var is_enum_switch = false;
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                if (pat_m.kind == .identifier and pat_m.resolved_kind == .enum_variant) {
                    is_enum_switch = true;
                    break;
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
pub fn generateTypeMatchMir(cg: *CodeGen, m: *mir.MirNode, is_null_union: bool) anyerror!void {
    const is_arbitrary = blk: {
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR)) break :blk false;
            if (pat_m.literal_kind == .null_lit) break :blk false;
        }
        break :blk true;
    };

    const is_error_union = blk: {
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR)) break :blk true;
        }
        break :blk false;
    };

    // Check if the match value's actual type is null_error_union (?anyerror!T),
    // which requires the two-step unwrap even when arms don't cover all variants.
    const val_tc = m.value().type_class;
    const is_null_error = val_tc == .null_error_union or (is_error_union and is_null_union);

    // For native ?T and anyerror!T, use if/else instead of switch
    if (is_null_error) {
        // match on ?anyerror!T → three-way nested if:
        //   if (val) |_eu| { if (_eu) |_match_val| { value } else |_match_err| { error } } else { null }
        var value_arm: ?*mir.MirNode = null;
        var error_arm: ?*mir.MirNode = null;
        var null_arm: ?*mir.MirNode = null;
        var else_arm: ?*mir.MirNode = null;
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            const pat_name = pat_m.name orelse "";
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, K.Type.ERROR)) {
                error_arm = arm_mir;
            } else if (pat_m.literal_kind == .null_lit) {
                null_arm = arm_mir;
            } else if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                else_arm = arm_mir;
            } else {
                value_arm = arm_mir;
            }
        }
        const match_var = m.value().name;
        // Determine which arms use the match variable for capture selection
        const val_body = if (value_arm orelse else_arm) |arm| arm.body() else null;
        const err_body = if (error_arm) |arm| arm.body() else if (else_arm) |arm| arm.body() else null;
        const val_uses = if (val_body) |b| armUsesMatchVar(b, match_var) else false;
        const err_uses = if (err_body) |b| armUsesMatchVar(b, match_var) else false;
        // Outer if: unwrap optional
        try cg.emit("if (");
        try cg.generateExprMir(m.value());
        try cg.emit(") |_eu| ");
        // Inner if: unwrap error union
        if (val_uses) try cg.emit("if (_eu) |_match_val| ") else try cg.emit("if (_eu) |_| ");
        if (value_arm orelse else_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        if (err_uses) try cg.emit(" else |_match_err| ") else try cg.emit(" else |_| ");
        if (error_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_err");
        } else if (else_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_err");
        } else {
            try cg.emit("{}");
        }
        // Outer else: null case
        try cg.emit(" else ");
        if (null_arm) |arm| {
            try cg.generateBlockMir(arm.body());
        } else if (else_arm) |arm| {
            try cg.generateBlockMir(arm.body());
        } else {
            try cg.emit("{}");
        }
        return;
    }

    if (is_error_union) {
        // match on anyerror!T → if (val) |_match_val| { ... } else |_match_err| { ... }
        var value_arm: ?*mir.MirNode = null;
        var error_arm: ?*mir.MirNode = null;
        var else_arm: ?*mir.MirNode = null;
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            const pat_name = pat_m.name orelse "";
            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, K.Type.ERROR)) {
                error_arm = arm_mir;
            } else if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                else_arm = arm_mir;
            } else {
                value_arm = arm_mir;
            }
        }
        const match_var = m.value().name;
        const val_body = if (value_arm orelse else_arm) |arm| arm.body() else null;
        const err_body = if (error_arm) |arm| arm.body() else null;
        const val_uses = if (val_body) |b| armUsesMatchVar(b, match_var) else false;
        const err_uses = if (err_body) |b| armUsesMatchVar(b, match_var) else false;
        try cg.emit("if (");
        try cg.generateExprMir(m.value());
        if (val_uses) try cg.emit(") |_match_val| ") else try cg.emit(") |_| ");
        if (value_arm orelse else_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        if (err_uses) try cg.emit(" else |_match_err| ") else try cg.emit(" else |_| ");
        if (error_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_err");
        } else {
            try cg.emit("{}");
        }
        return;
    }

    if (is_null_union) {
        // match on ?T → if (val) |_match_val| { ... } else { ... }
        var value_arm: ?*mir.MirNode = null;
        var null_arm: ?*mir.MirNode = null;
        var else_arm: ?*mir.MirNode = null;
        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            const pat_name = pat_m.name orelse "";
            if (pat_m.literal_kind == .null_lit) {
                null_arm = arm_mir;
            } else if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                else_arm = arm_mir;
            } else {
                value_arm = arm_mir;
            }
        }
        const match_var = m.value().name;
        const val_body = if (value_arm orelse else_arm) |arm| arm.body() else null;
        const val_uses = if (val_body) |b| armUsesMatchVar(b, match_var) else false;
        try cg.emit("if (");
        try cg.generateExprMir(m.value());
        if (val_uses) try cg.emit(") |_match_val| ") else try cg.emit(") |_| ");
        if (value_arm orelse else_arm) |arm| {
            try generateArmBodyWithSubst(cg, arm.body(), match_var, "_match_val");
        } else {
            try cg.emit("{}");
        }
        try cg.emit(" else ");
        if (null_arm) |arm| {
            try cg.generateBlockMir(arm.body());
        } else {
            try cg.emit("{}");
        }
        return;
    }

    // Arbitrary union — keep as switch, with positional tag arms computed
    // against the matched value's canonical sort order.
    const match_var = m.value().name;
    try cg.emit("switch (");
    try cg.generateExprMir(m.value());
    try cg.emit(") {\n");
    cg.indent += 1;

    // Build the canonical sorted member names of the matched value's union.
    const max_arity = 32;
    var sorted_buf: [max_arity][]const u8 = undefined;
    var sorted_len: usize = 0;
    if (m.value().resolved_type == .union_type) {
        for (m.value().resolved_type.union_type) |mem| {
            const n = mem.name();
            if (std.mem.eql(u8, n, "Error") or std.mem.eql(u8, n, "null")) continue;
            if (sorted_len >= max_arity) break;
            sorted_buf[sorted_len] = n;
            sorted_len += 1;
        }
        mir.union_sort.sortMemberNames(sorted_buf[0..sorted_len]);
    }

    for (m.matchArms()) |arm_mir| {
        const pat_m = arm_mir.pattern();
        const pat_name = pat_m.name orelse "";
        try cg.emitIndent();

        if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
            try cg.emit("else");
        } else if (is_arbitrary and pat_m.kind == .identifier) {
            if (mir.union_sort.positionalIndex(sorted_buf[0..sorted_len], pat_name)) |idx| {
                try cg.emitFmt("._{d}", .{idx});
            } else {
                try cg.emitFmt("._{s}", .{pat_name});
            }
        }

        const arm_uses = armUsesMatchVar(arm_mir.body(), match_var);
        if (arm_uses) try cg.emit(" => |_match_val| ") else try cg.emit(" => ");
        try generateArmBodyWithSubst(cg, arm_mir.body(), match_var, "_match_val");
        try cg.emit(",\n");
    }

    cg.indent -= 1;
    try cg.emitIndent();
    try cg.emit("}");
}

/// MIR-path string match — desugars to if/else chain.
pub fn generateStringMatchMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    var first = true;
    var wildcard_arm: ?*mir.MirNode = null;

    for (m.matchArms()) |arm_mir| {
        const pat_m = arm_mir.pattern();

        if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", "else")) {
            wildcard_arm = arm_mir;
            continue;
        }

        if (first) {
            try cg.emit("if (std.mem.eql(u8, ");
            first = false;
        } else {
            try cg.emit(" else if (std.mem.eql(u8, ");
        }

        const val_m = m.value();
        if (val_m.kind == .identifier and val_m.resolved_type == .ptr) {
            try cg.emitFmt("{s}.*", .{val_m.name orelse ""});
        } else {
            try cg.generateExprMir(val_m);
        }
        try cg.emit(", ");
        try cg.generateExprMir(pat_m);
        try cg.emit(")) ");
        try cg.generateBlockMir(arm_mir.body());
    }

    if (wildcard_arm) |wa| {
        if (first) {
            try cg.generateBlockMir(wa.body());
        } else {
            try cg.emit(" else ");
            try cg.generateBlockMir(wa.body());
        }
    } else if (!first) {
        try cg.emit(" else {}");
    }
}

/// MIR-path interpolated string — inline variant used by temp_var statement handler.
/// Emits allocPrint directly to main output (no hoisting). The temp_var path already
/// wraps this in `const _orhon_interp_N = ...;` with a sibling injected_defer node,
/// so no pre_stmts hoisting is needed here.
pub fn generateInterpolatedStringMirInline(cg: *CodeGen, parts: []const parser.InterpolatedPart, expr_children: []*mir.MirNode) anyerror!void {
    try cg.emit("std.fmt.allocPrint(std.heap.smp_allocator, \"");
    var expr_idx: usize = 0;
    // Build format string
    for (parts) |part| {
        switch (part) {
            .literal => |text| {
                for (text) |ch| {
                    switch (ch) {
                        '{' => try cg.emit("{{"),
                        '}' => try cg.emit("}}"),
                        '\\' => try cg.emit("\\"),
                        else => {
                            const buf: [1]u8 = .{ch};
                            try cg.emit(&buf);
                        },
                    }
                }
            },
            .expr => {
                if (expr_idx < expr_children.len and codegen.mirIsString(expr_children[expr_idx])) {
                    try cg.emit("{s}");
                } else {
                    try cg.emit("{}");
                }
                expr_idx += 1;
            },
        }
    }
    try cg.emit("\", .{");
    // Build args tuple
    var first = true;
    for (expr_children) |child| {
        if (!first) try cg.emit(", ");
        try cg.generateExprMir(child);
        first = false;
    }
    // Use error propagation only if the enclosing function has an error return type.
    // Otherwise use unreachable — smp_allocator OOM is extremely rare in practice.
    const ret_tc = cg.funcReturnTypeClass();
    if (ret_tc == .error_union or ret_tc == .null_error_union) {
        try cg.emit("}) catch |err| return err");
    } else {
        try cg.emit("}) catch unreachable");
    }
}

/// MIR-path interpolated string — uses interp_parts for literals, children for exprs.
/// Hoists the allocPrint call to a temp variable in pre_stmts, then emits only the
/// temp var name — paired with defer free to avoid a memory leak.
pub fn generateInterpolatedStringMir(cg: *CodeGen, parts: []const parser.InterpolatedPart, expr_children: []*mir.MirNode) anyerror!void {
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
    var expr_idx: usize = 0;
    for (parts) |part| {
        switch (part) {
            .literal => |text| {
                for (text) |ch| {
                    switch (ch) {
                        '{' => try cg.pre_stmts.appendSlice(cg.allocator, "{{"),
                        '}' => try cg.pre_stmts.appendSlice(cg.allocator, "}}"),
                        '\\' => try cg.pre_stmts.appendSlice(cg.allocator, "\\"),
                        else => try cg.pre_stmts.append(cg.allocator, ch),
                    }
                }
            },
            .expr => {
                if (expr_idx < expr_children.len and codegen.mirIsString(expr_children[expr_idx])) {
                    try cg.pre_stmts.appendSlice(cg.allocator, "{s}");
                } else {
                    try cg.pre_stmts.appendSlice(cg.allocator, "{}");
                }
                expr_idx += 1;
            },
        }
    }
    try cg.pre_stmts.appendSlice(cg.allocator, "\", .{");

    // Redirect output to pre_stmts to emit arg expressions
    const saved_output = cg.output;
    cg.output = cg.pre_stmts;
    var first = true;
    for (expr_children) |child| {
        if (!first) try cg.emit(", ");
        try cg.generateExprMir(child);
        first = false;
    }
    cg.pre_stmts = cg.output;
    cg.output = saved_output;

    // Use error propagation only if the enclosing function has an error return type.
    const ret_tc2 = cg.funcReturnTypeClass();
    if (ret_tc2 == .error_union or ret_tc2 == .null_error_union) {
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
fn emitIntrospectionType(cg: *CodeGen, arg: *mir.MirNode) anyerror!void {
    const is_type_ref = switch (arg.kind) {
        .type_expr => true,
        .identifier => blk: {
            // Identifier is a direct type reference when its name matches the resolved type name.
            // e.g. Vec2 → name="Vec2", resolved_type=.named{"Vec2"} → true
            // e.g. v   → name="v",    resolved_type=.named{"Vec2"} → false
            // Compt type params (T: type) resolve to .primitive(.type) — also a type ref.
            const id_name = arg.name orelse break :blk false;
            break :blk switch (arg.resolved_type) {
                .named => |n| std.mem.eql(u8, id_name, n),
                .primitive => |p| p == .@"type" and cg.inComptFunc(),
                else => false,
            };
        },
        else => blk: {
            // Compiler functions returning type (e.g. @fieldType, @typeOf) are type refs
            break :blk arg.resolved_type == .primitive and arg.resolved_type.primitive == .@"type";
        },
    };
    if (is_type_ref) {
        try cg.generateExprMir(arg);
    } else {
        try cg.emit("@TypeOf(");
        try cg.generateExprMir(arg);
        try cg.emit(")");
    }
}

/// MIR-path compiler function (@typename, @cast, @size, etc.).
pub fn generateCompilerFuncMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const cf_name = m.name orelse return;
    const args = m.children;
    switch (builtins.CompilerFunc.fromName(cf_name) orelse unreachable) {
        .typename => {
            try cg.emit("@typeName(@TypeOf(");
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit("))");
        },
        .typeid => {
            try cg.emit("@intFromPtr(@typeName(@TypeOf(");
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit(")).ptr)");
        },
        .cast => {
            if (args.len >= 2) {
                const target_type = try cg.typeToZig(args[0].ast); // type trees are structural — typeToZig walks AST
                const target_is_float = target_type.len > 0 and target_type[0] == 'f';
                const target_is_enum = args[0].resolved_kind == .enum_type_name;
                // Detect float source from literal kind OR resolved type
                const source_is_float = args[1].literal_kind == .float or
                    (args[1].resolved_type == .primitive and args[1].resolved_type.primitive.isFloat());
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
                try cg.generateExprMir(args[1]);
                try cg.emit("))");
            } else if (args.len == 1) {
                try cg.emit("@intCast(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        },
        .size => {
            try cg.emit("@sizeOf(");
            if (args.len > 0) try emitIntrospectionType(cg, args[0]);
            try cg.emit(")");
        },
        .@"align" => {
            try cg.emit("@alignOf(");
            if (args.len > 0) try emitIntrospectionType(cg, args[0]);
            try cg.emit(")");
        },
        .copy => {
            if (args.len > 0) try cg.generateExprMir(args[0]);
        },
        .move => {
            if (args.len > 0) try cg.generateExprMir(args[0]);
        },
        .assert => {
            if (args.len >= 2) {
                // @assert(cond, "message") — conditional panic with custom message
                try cg.emit("if (!(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")) @panic(");
                try cg.generateExprMir(args[1]);
                try cg.emit(")");
            } else {
                if (cg.in_test_block) {
                    try cg.emit("try std.testing.expect(");
                } else {
                    try cg.emit("std.debug.assert(");
                }
                if (args.len > 0) try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        },
        .swap => {
            if (args.len == 2) {
                try cg.emit("std.mem.swap(@TypeOf(");
                try cg.generateExprMir(args[0]);
                try cg.emit("), &");
                try cg.generateExprMir(args[0]);
                try cg.emit(", &");
                try cg.generateExprMir(args[1]);
                try cg.emit(")");
            }
        },
        .hasField => {
            try cg.emit("@hasField(");
            if (args.len >= 1) {
                try emitIntrospectionType(cg, args[0]);
            }
            if (args.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(args[1]);
            }
            try cg.emit(")");
        },
        .hasDecl => {
            try cg.emit("@hasDecl(");
            if (args.len >= 1) {
                try emitIntrospectionType(cg, args[0]);
            }
            if (args.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(args[1]);
            }
            try cg.emit(")");
        },
        .fieldType => {
            try cg.emit("@FieldType(");
            if (args.len >= 1) {
                try emitIntrospectionType(cg, args[0]);
            }
            if (args.len >= 2) {
                try cg.emit(", ");
                try cg.generateExprMir(args[1]);
            }
            try cg.emit(")");
        },
        .fieldNames => {
            try cg.emit("std.meta.fieldNames(");
            if (args.len >= 1) {
                try emitIntrospectionType(cg, args[0]);
            }
            try cg.emit(")");
        },
        .typeOf => {
            try cg.emit("@TypeOf(");
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit(")");
        },
        .splitAt => {
            // @splitAt is handled in generateDestructMir for destructuring context.
            // Standalone usage is not meaningful — splitAt always produces two values.
            try cg.emit("/* @splitAt must be used with destructuring: const a, b = @splitAt(arr, n) */");
        },
        .wrap => {
            if (args.len > 0) try cg.generateWrappingExprMir(args[0]);
        },
        .sat => {
            if (args.len > 0) try cg.generateSaturatingExprMir(args[0]);
        },
        .overflow => {
            if (args.len > 0) try cg.generateOverflowExprMir(args[0]);
        },
        .compileError => {
            try cg.emit("@compileError(");
            if (args.len > 0) try cg.generateExprMir(args[0]);
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

pub fn generateWrappingExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.kind == .binary) {
        if (mapWrappingOp(m.op orelse .assign)) |op| {
            try cg.generateExprMir(m.lhs());
            try cg.emitFmt(" {s} ", .{op});
            try cg.generateExprMir(m.rhs());
            return;
        }
    }
    try cg.generateExprMir(m);
}

pub fn generateSaturatingExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.kind == .binary) {
        if (mapSaturatingOp(m.op orelse .assign)) |op| {
            try cg.generateExprMir(m.lhs());
            try cg.emitFmt(" {s} ", .{op});
            try cg.generateExprMir(m.rhs());
            return;
        }
    }
    try cg.generateExprMir(m);
}

// ── Overflow: MIR path ──────────────────────────────────────────
// overflow(a + b) → (blk: { const _ov = @addWithOverflow(a, b);
//   if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(a), error.overflow)
//   else break :blk @as(anyerror!@TypeOf(a), _ov[0]); })
// When operands are literals, @TypeOf gives comptime_int which Zig rejects.
// MirLowerer stamps the enclosing var_decl's type annotation onto the binary
// operand via `overflow_type`; codegen reads it from the MIR node.

fn resolveOverflowTypeStr(cg: *CodeGen, m: *mir.MirNode, left_is_literal: bool) anyerror!?[]const u8 {
    if (!left_is_literal) return null;
    const ann = m.overflow_type orelse return null;
    if (codegen.extractValueType(ann)) |vt| return try cg.typeToZig(vt);
    return null;
}

fn emitOverflowTail(cg: *CodeGen, type_str: ?[]const u8) anyerror!void {
    if (type_str) |ts| {
        try cg.emitFmt("); if (_ov[1] != 0) break :blk @as(anyerror!{s}, error.overflow) else break :blk @as(anyerror!{s}, _ov[0]); }})", .{ ts, ts });
    }
}

pub fn generateOverflowExprMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.kind == .binary) {
        if (mapOverflowBuiltin(m.op orelse .assign)) |builtin| {
            const left_is_literal = m.lhs().literal_kind == .int or m.lhs().literal_kind == .float;
            const type_str = try resolveOverflowTypeStr(cg, m, left_is_literal);

            try cg.emit("(blk: { const _ov = ");
            try cg.emitFmt("{s}(", .{builtin});
            if (type_str) |ts| {
                try cg.emitFmt("@as({s}, ", .{ts});
                try cg.generateExprMir(m.lhs());
                try cg.emit(")");
            } else {
                try cg.generateExprMir(m.lhs());
            }
            try cg.emit(", ");
            try cg.generateExprMir(m.rhs());
            if (type_str) |_| {
                try emitOverflowTail(cg, type_str);
            } else {
                try cg.emit("); if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(");
                try cg.generateExprMir(m.lhs());
                try cg.emit("), error.overflow) else break :blk @as(anyerror!@TypeOf(");
                try cg.generateExprMir(m.lhs());
                try cg.emit("), _ov[0]); })");
            }
            return;
        }
    }
    try cg.generateExprMir(m);
}

/// MIR-path fill default arguments.
pub fn fillDefaultArgsMir(cg: *CodeGen, callee_mir: *const mir.MirNode, actual_arg_count: usize) anyerror!void {
    // Resolve function name from callee MirNode
    const func_name: []const u8 = if (callee_mir.kind == .identifier)
        callee_mir.name orelse return
    else if (callee_mir.kind == .field_access)
        callee_mir.name orelse return
    else
        return;

    // Find the function's MirNode from the MIR root to get param defaults
    const func_mir = findFuncMir(cg, func_name) orelse return;
    const mir_params = func_mir.params();
    if (actual_arg_count >= mir_params.len) return;

    var wrote_any = actual_arg_count > 0;
    for (mir_params[actual_arg_count..]) |param_m| {
        if (param_m.defaultChild()) |dv_mir| {
            if (wrote_any) try cg.emit(", ");
            try cg.generateExprMir(dv_mir);
            wrote_any = true;
        }
    }
}

/// Find a function's MirNode by name in the MIR root.
fn findFuncMir(cg: *CodeGen, func_name: []const u8) ?*mir.MirNode {
    if (cg.mir_root) |root| {
        for (root.children) |child| {
            if (child.kind == .func and child.name != null and
                std.mem.eql(u8, child.name.?, func_name)) return child;
        }
    }
    return null;
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

test "mirContainsIdentifier" {
    var leaf = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .identifier, .children = &.{}, .name = "x" };
    try std.testing.expect(mirContainsIdentifier(&leaf, "x"));
    try std.testing.expect(!mirContainsIdentifier(&leaf, "y"));

    // Nested: parent with child containing "y"
    var child = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .identifier, .children = &.{}, .name = "y" };
    var children = [_]*mir.MirNode{&child};
    var parent = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .binary, .children = &children, .name = null };
    try std.testing.expect(mirContainsIdentifier(&parent, "y"));
    try std.testing.expect(!mirContainsIdentifier(&parent, "z"));
}

test "hasGuardedArm" {
    var pat = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var body_node = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    // No guard (2 children)
    var children2 = [_]*mir.MirNode{ &pat, &body_node };
    var arm1 = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_arm, .children = &children2 };
    var arms_no_guard = [_]*mir.MirNode{&arm1};
    try std.testing.expect(!hasGuardedArm(&arms_no_guard));

    // With guard (3 children)
    var guard_n = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .binary, .children = &.{} };
    var children3 = [_]*mir.MirNode{ &pat, &guard_n, &body_node };
    var arm2 = mir.MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_arm, .children = &children3 };
    var arms_with_guard = [_]*mir.MirNode{&arm2};
    try std.testing.expect(hasGuardedArm(&arms_with_guard));
}
