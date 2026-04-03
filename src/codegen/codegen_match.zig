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
const module = @import("../module.zig");
const RT = @import("../types.zig").ResolvedType;
const builtins = @import("../builtins.zig");

const CodeGen = codegen.CodeGen;

pub fn mirContainsIdentifier(m: *mir.MirNode, name: []const u8) bool {
    if (m.kind == .identifier and std.mem.eql(u8, m.name orelse "", name)) return true;
    for (m.children) |child| {
        if (mirContainsIdentifier(child, name)) return true;
    }
    return false;
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
        if (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", "self")) {
            try cg.emit("self.*");
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
                if (pat_m.kind == .identifier) {
                    if (cg.isEnumVariant(pat_m.name orelse "")) {
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

    // For native ?T and anyerror!T, use if/else instead of switch
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
        try cg.emit("if (");
        try cg.generateExprMir(m.value());
        try cg.emit(") |_match_val| ");
        if (value_arm orelse else_arm) |arm| {
            try cg.generateBlockMir(arm.body());
        } else {
            try cg.emit("{}");
        }
        try cg.emit(" else |_match_err| ");
        if (error_arm) |arm| {
            try cg.generateBlockMir(arm.body());
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
        try cg.emit("if (");
        try cg.generateExprMir(m.value());
        try cg.emit(") |_match_val| ");
        if (value_arm orelse else_arm) |arm| {
            try cg.generateBlockMir(arm.body());
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

    // Arbitrary union — keep as switch
    try cg.emit("switch (");
    try cg.generateExprMir(m.value());
    try cg.emit(") {\n");
    cg.indent += 1;

    for (m.matchArms()) |arm_mir| {
        const pat_m = arm_mir.pattern();
        const pat_name = pat_m.name orelse "";
        try cg.emitIndent();

        if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
            try cg.emit("else");
        } else if (is_arbitrary and pat_m.kind == .identifier) {
            try cg.emitFmt("._{s}", .{pat_name});
        }

        try cg.emit(" => ");
        try cg.generateBlockMir(arm_mir.body());
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
        if (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", "self")) {
            try cg.emit("self.*");
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
    // Otherwise use unreachable — page_allocator OOM is extremely rare in practice.
    if (cg.funcReturnTypeClass() == .error_union) {
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
    if (cg.funcReturnTypeClass() == .error_union) {
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
            const id_name = arg.name orelse break :blk false;
            break :blk switch (arg.resolved_type) {
                .named => |n| std.mem.eql(u8, id_name, n),
                else => false,
            };
        },
        else => false,
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
    switch (builtins.CompilerFunc.fromName(cf_name) orelse {
        try cg.emitFmt("/* unknown @{s} */", .{cf_name});
        return;
    }) {
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
                const target_is_enum = cg.isEnumTypeName(args[0].ast); // type trees are structural — isEnumTypeName reads AST
                const source_is_float_literal = args[1].literal_kind == .float;
                try cg.emitFmt("@as({s}, ", .{target_type});
                if (target_is_enum) {
                    try cg.emit("@enumFromInt(");
                } else if (target_is_float and source_is_float_literal) {
                    try cg.emit("@floatCast(");
                } else if (target_is_float) {
                    try cg.emit("@floatFromInt(");
                } else if (source_is_float_literal) {
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
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit(")");
        },
        .@"align" => {
            try cg.emit("@alignOf(");
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit(")");
        },
        .copy => {
            if (args.len > 0) try cg.generateExprMir(args[0]);
        },
        .move => {
            if (args.len > 0) try cg.generateExprMir(args[0]);
        },
        .assert => {
            if (cg.in_test_block) {
                try cg.emit("try std.testing.expect(");
            } else {
                try cg.emit("std.debug.assert(");
            }
            if (args.len > 0) try cg.generateExprMir(args[0]);
            try cg.emit(")");
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
// Use the concrete type from the enclosing decl's type_ctx if available.

fn resolveOverflowTypeStr(cg: *CodeGen, left_is_literal: bool) anyerror!?[]const u8 {
    if (left_is_literal) {
        if (cg.type_ctx) |ctx| {
            if (codegen.extractValueType(ctx)) |vt| return try cg.typeToZig(vt);
        }
    }
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
            const type_str = try resolveOverflowTypeStr(cg, left_is_literal);

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
    // Primitive type names — always valid as union payload access
    const primitives = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "isize", "usize",
        "f16", "bf16", "f32", "f64", "f128",
        "bool", "str", "void",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    // Known user-defined types from the declaration table
    if (decls) |d| {
        if (d.structs.contains(name)) return true;
        if (d.enums.contains(name)) return true;
    }
    // Builtin types that can appear in unions
    if (builtins.isBuiltinType(name)) return true;
    return false;
}
