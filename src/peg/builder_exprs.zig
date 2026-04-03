// builder_exprs.zig — Expression builders for the PEG AST builder
// Contains: buildIntLiteral, buildFloatLiteral, buildStringLiteral,
//           buildBoolLiteral, buildIdentifier, buildErrorLiteral,
//           buildCompilerFunc, buildArrayLiteral, buildGroupedExpr,
//           buildTupleLiteral, buildStructExpr, buildBinaryExpr,
//           buildCompareExpr, buildRangeExpr, buildNotExpr, buildUnaryExpr,
//           buildPostfixExpr

const std = @import("std");
const builder = @import("builder.zig");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

const BuildContext = builder.BuildContext;

// ============================================================
// EXPRESSION BUILDERS
// ============================================================

pub fn buildIntLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .int_literal = builder.tokenText(ctx, cap.start_pos) });
}

pub fn buildFloatLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .float_literal = builder.tokenText(ctx, cap.start_pos) });
}

pub fn buildStringLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const raw = builder.tokenText(ctx, cap.start_pos);
    // Guard against malformed tokens (need at least opening and closing quote)
    if (raw.len < 2) return ctx.newNode(.{ .string_literal = raw });
    const inner = raw[1 .. raw.len - 1];

    // Fast path: no interpolation — plain string literal (unchanged behavior)
    if (std.mem.indexOf(u8, inner, "@{") == null) {
        return ctx.newNode(.{ .string_literal = raw });
    }

    // Slow path: build InterpolatedPart list by scanning for @{...} markers
    var parts = std.ArrayListUnmanaged(parser.InterpolatedPart){};
    var pos: usize = 0;
    while (pos < inner.len) {
        if (std.mem.indexOf(u8, inner[pos..], "@{")) |rel| {
            const abs = pos + rel;
            // Emit literal text before @{
            if (rel > 0) {
                const lit = try ctx.alloc().dupe(u8, inner[pos..abs]);
                try parts.append(ctx.alloc(), .{ .literal = lit });
            }
            // Find the closing }
            const expr_start = abs + 2;
            if (std.mem.indexOfScalarPos(u8, inner, expr_start, '}')) |close| {
                const expr_text = try ctx.alloc().dupe(u8, inner[expr_start..close]);
                const expr_node = try ctx.newNodeAt(.{ .identifier = expr_text }, cap.start_pos);
                try parts.append(ctx.alloc(), .{ .expr = expr_node });
                pos = close + 1;
            } else {
                // Unclosed @{ — emit remainder as literal (silent degradation)
                const lit = try ctx.alloc().dupe(u8, inner[abs..]);
                try parts.append(ctx.alloc(), .{ .literal = lit });
                break;
            }
        } else {
            // No more @{ — emit remainder as literal
            const lit = try ctx.alloc().dupe(u8, inner[pos..]);
            try parts.append(ctx.alloc(), .{ .literal = lit });
            break;
        }
    }

    return ctx.newNodeAt(.{
        .interpolated_string = .{ .parts = try parts.toOwnedSlice(ctx.alloc()) },
    }, cap.start_pos);
}

pub fn buildBoolLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const tok = ctx.tokens[cap.start_pos];
    return ctx.newNode(.{ .bool_literal = tok.kind == .kw_true });
}

pub fn buildIdentifier(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .identifier = builder.tokenText(ctx, cap.start_pos) });
}

pub fn buildErrorLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // error_literal <- 'Error' '(' STRING_LITERAL ')'
    if (builder.findTokenInRange(ctx, cap.start_pos, cap.end_pos, .string_literal)) |pos| {
        return ctx.newNode(.{ .error_literal = builder.tokenText(ctx, pos) });
    }
    return ctx.newNode(.{ .error_literal = "" });
}

pub fn buildCompilerFunc(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compiler_func <- compiler_func_name '(' _ arg_list _ ')'
    // compiler_func_name <- '@' 'cast' / '@' 'copy' / ... (2 tokens: at_sign + identifier)
    // The name is stored without '@' prefix so downstream passes are unchanged.
    var name: []const u8 = "";
    if (cap.findChild("compiler_func_name")) |cn| {
        // cn.start_pos = '@' token, cn.start_pos + 1 = identifier token (e.g. "cast")
        name = builder.tokenText(ctx, cn.start_pos + 1);
    }
    var args_list = std.ArrayListUnmanaged(*Node){};
    try builder.collectExprsRecursive(ctx, cap, &args_list);
    return ctx.newNode(.{ .compiler_func = .{ .name = name, .args = try args_list.toOwnedSlice(ctx.alloc()) } });
}

pub fn buildArrayLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const items = try builder.buildChildrenByRule(ctx, cap, "expr");
    return ctx.newNode(.{ .array_literal = items });
}

pub fn buildGroupedExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // grouped_expr <- '(' _ expr _ ')'
    if (cap.findChild("expr")) |e| return builder.buildNode(ctx, e);
    return error.NoExpr;
}

pub fn buildTupleLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // tuple_literal <- '(' _ IDENTIFIER ':' expr (_ ',' _ IDENTIFIER ':' expr)* _ ')'
    var names = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged(*Node){};
    var i = cap.start_pos + 1; // skip (
    while (i < cap.end_pos) : (i += 1) {
        const tok = ctx.tokens[i];
        if (tok.kind == .identifier and i + 1 < cap.end_pos and ctx.tokens[i + 1].kind == .colon) {
            try names.append(ctx.alloc(), tok.text);
            // Find and build the corresponding expr
            for (cap.children) |*child| {
                if (child.rule) |r| {
                    if (std.mem.eql(u8, r, "expr") and child.start_pos > i) {
                        try values.append(ctx.alloc(), try builder.buildNode(ctx, child));
                        break;
                    }
                }
            }
        }
    }
    return ctx.newNode(.{ .tuple_literal = .{
        .is_named = true,
        .fields = try values.toOwnedSlice(ctx.alloc()),
        .field_names = try names.toOwnedSlice(ctx.alloc()),
    } });
}

pub fn buildAnonTupleLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // anon_tuple_literal <- '(' _ expr (',' _ expr)+ _ ')'
    var values = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "expr")) {
                try values.append(ctx.alloc(), try builder.buildNode(ctx, child));
            }
        }
    }
    return ctx.newNode(.{ .tuple_literal = .{
        .is_named = false,
        .fields = try values.toOwnedSlice(ctx.alloc()),
        .field_names = &.{},
    } });
}

pub fn buildStructExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // struct_expr <- 'struct' '{' _ (struct_member _)* _ '}'
    var members = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "struct_member")) {
                // struct_member wraps: doc_block? 'pub'? (func_decl / var_decl / const_decl / compt_decl / field_decl)
                // Recurse into the struct_member to find and build the actual declaration
                for (child.children) |*inner| {
                    if (inner.rule != null) {
                        const node = try builder.buildNode(ctx, inner);
                        if (builder.hasPubBefore(ctx, child, inner.start_pos)) builder.setPub(node, true);
                        try members.append(ctx.alloc(), node);
                        break; // one declaration per struct_member
                    }
                }
            }
        }
    }
    return ctx.newNode(.{ .struct_type = try members.toOwnedSlice(ctx.alloc()) });
}

/// Binary expression builder — handles the left-associative precedence tower.
/// Grammar: left_operand (OP right_operand)*
pub fn buildBinaryExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // The children are the operand sub-rules (e.g., and_expr children for or_expr)
    if (cap.children.len == 0) return error.NoBinaryChildren;
    if (cap.children.len == 1) return builder.buildNode(ctx, &cap.children[0]);

    // Multiple children — build left-associative chain
    // The operator is the token between children
    var left = try builder.buildNode(ctx, &cap.children[0]);
    var i: usize = 1;
    while (i < cap.children.len) : (i += 1) {
        // Find operator token between prev child end and this child start
        const prev_end = cap.children[i - 1].end_pos;
        const next_start = cap.children[i].start_pos;
        var op: parser.Operator = .add;
        var j = prev_end;
        while (j < next_start) : (j += 1) {
            const tok = ctx.tokens[j];
            if (tok.kind != .newline) {
                op = parser.Operator.parse(tok.text);
                break;
            }
        }
        const right = try builder.buildNode(ctx, &cap.children[i]);
        left = try ctx.newNode(.{ .binary_expr = .{ .op = op, .left = left, .right = right } });
    }
    return left;
}

pub fn buildCompareExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compare_expr <- bitor_expr compare_op bitor_expr / bitor_expr 'is' 'not'? (IDENTIFIER / 'null') / bitor_expr

    // Check for 'is' type check
    if (builder.findTokenInRange(ctx, cap.start_pos, cap.end_pos, .kw_is)) |is_pos| {
        // Find the operand (everything before 'is')
        var operands = std.ArrayListUnmanaged(*const CaptureNode){};
        for (cap.children) |*child| {
            if (child.rule) |r| {
                if (!std.mem.eql(u8, r, "compare_op") and
                    !std.mem.eql(u8, r, "_") and
                    !std.mem.eql(u8, r, "TERM"))
                {
                    operands.append(ctx.alloc(), child) catch {};
                }
            }
        }
        if (operands.items.len > 0) {
            const expr_node = try builder.buildNode(ctx, operands.items[0]);
            // Build: type(expr) == TypeName / type(expr) != TypeName
            const args = try ctx.alloc().alloc(*Node, 1);
            args[0] = expr_node;
            const type_call = try ctx.newNode(.{ .compiler_func = .{ .name = "type", .args = args } });

            // Check for 'not' after 'is'
            const negated = is_pos + 1 < cap.end_pos and ctx.tokens[is_pos + 1].kind == .kw_not;
            const cmp_op: parser.Operator = if (negated) .ne else .eq;

            // Find the type name (last identifier, dotted path, or null keyword)
            var rhs: *Node = try ctx.newNode(.{ .identifier = "unknown" });
            var j = if (negated) is_pos + 2 else is_pos + 1;
            // Scan for dotted identifier path: IDENTIFIER ('.' IDENTIFIER)* per D-01
            var idents = std.ArrayListUnmanaged([]const u8){};
            defer idents.deinit(ctx.alloc());
            while (j < cap.end_pos) : (j += 1) {
                if (ctx.tokens[j].kind == .identifier) {
                    idents.append(ctx.alloc(), ctx.tokens[j].text) catch {};
                    // Peek ahead: dot followed by identifier → continue collecting
                    if (j + 2 < cap.end_pos and
                        ctx.tokens[j + 1].kind == .dot and
                        ctx.tokens[j + 2].kind == .identifier)
                    {
                        j += 1; // skip dot; loop increment lands on next identifier
                    } else {
                        break;
                    }
                } else if (ctx.tokens[j].kind == .kw_null) {
                    rhs = try ctx.newNode(.{ .null_literal = {} });
                    break;
                }
            }
            // Build AST node from collected identifiers
            if (idents.items.len == 1) {
                // Single identifier — per D-04, no regression
                rhs = try ctx.newNode(.{ .identifier = idents.items[0] });
            } else if (idents.items.len > 1) {
                // Dotted path — per D-05, build left-to-right field_expr chain
                var chain: *Node = try ctx.newNode(.{ .identifier = idents.items[0] });
                for (idents.items[1..]) |name| {
                    chain = try ctx.newNode(.{ .field_expr = .{ .object = chain, .field = name } });
                }
                rhs = chain;
            }
            return ctx.newNode(.{ .binary_expr = .{ .op = cmp_op, .left = type_call, .right = rhs } });
        }
    }

    // Regular comparison: bitor_expr compare_op bitor_expr
    var operands = std.ArrayListUnmanaged(*const CaptureNode){};
    var op: parser.Operator = .eq;
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "compare_op")) {
                op = parser.Operator.parse(builder.tokenText(ctx, child.start_pos));
            } else if (!std.mem.eql(u8, r, "_") and !std.mem.eql(u8, r, "TERM")) {
                operands.append(ctx.alloc(), child) catch {};
            }
        }
    }
    if (operands.items.len <= 1) {
        if (operands.items.len == 1) return builder.buildNode(ctx, operands.items[0]);
        if (cap.children.len > 0) return builder.buildNode(ctx, &cap.children[0]);
        return error.NoCompareChildren;
    }
    const left = try builder.buildNode(ctx, operands.items[0]);
    const right = try builder.buildNode(ctx, operands.items[1]);
    return ctx.newNode(.{ .binary_expr = .{ .op = op, .left = left, .right = right } });
}

pub fn buildRangeExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.children.len <= 1) {
        if (cap.children.len == 1) return builder.buildNode(ctx, &cap.children[0]);
        return error.NoRangeChildren;
    }
    const left = try builder.buildNode(ctx, &cap.children[0]);
    const right = try builder.buildNode(ctx, &cap.children[1]);
    return ctx.newNode(.{ .range_expr = .{ .op = .range, .left = left, .right = right } });
}

pub fn buildNotExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // not_expr <- 'not' not_expr / compare_expr
    if (ctx.tokens[cap.start_pos].kind == .kw_not) {
        const operand = if (cap.children.len > 0) try builder.buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .unary_expr = .{ .op = .not, .operand = operand } });
    }
    if (cap.children.len > 0) return builder.buildNode(ctx, &cap.children[0]);
    return error.NoNotChildren;
}

pub fn buildUnaryExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // unary_expr <- '!' unary_expr / '-' unary_expr / 'const&' unary_expr / 'mut&' unary_expr / postfix_expr
    const first_tok = ctx.tokens[cap.start_pos];
    if (first_tok.kind == .bang) {
        const operand = if (cap.children.len > 0) try builder.buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .unary_expr = .{ .op = .bang, .operand = operand } });
    }
    if (first_tok.kind == .minus) {
        const operand = if (cap.children.len > 0) try builder.buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .unary_expr = .{ .op = .negate, .operand = operand } });
    }
    if (first_tok.kind == .const_borrow) {
        // const& — explicit const borrow expression
        const operand = if (cap.children.len > 0) try builder.buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .const_borrow_expr = operand });
    }
    if (first_tok.kind == .mut_borrow) {
        // mut& — explicit mutable borrow expression
        const operand = if (cap.children.len > 0) try builder.buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .mut_borrow_expr = operand });
    }
    if (cap.children.len > 0) return builder.buildNode(ctx, &cap.children[0]);
    return error.NoUnaryChildren;
}

pub fn buildPostfixExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // postfix_expr <- primary_expr (method_call / field_access / slice_access / index_access / call_access)*
    if (cap.children.len == 0) return error.NoPostfixChildren;

    var expr = try builder.buildNode(ctx, &cap.children[0]);

    var i: usize = 1;
    while (i < cap.children.len) : (i += 1) {
        const child = &cap.children[i];
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "method_call")) {
                // method_call <- '.' IDENTIFIER '(' _ arg_list _ ')'
                const field_name = builder.tokenText(ctx, child.start_pos + 1); // after '.'
                var args_list = std.ArrayListUnmanaged(*Node){};
                try builder.collectExprsRecursive(ctx, child, &args_list);
                const field_access = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
                expr = try ctx.newNode(.{ .call_expr = .{ .callee = field_access, .args = try args_list.toOwnedSlice(ctx.alloc()), .arg_names = &.{} } });
            } else if (std.mem.eql(u8, r, "field_access")) {
                const field_name = builder.tokenText(ctx, child.start_pos + 1);
                expr = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
            } else if (std.mem.eql(u8, r, "call_access")) {
                var args_list = std.ArrayListUnmanaged(*Node){};
                var names_list = std.ArrayListUnmanaged([]const u8){};
                var has_names = false;
                try builder.collectCallArgs(ctx, child, &args_list, &names_list, &has_names);
                expr = try ctx.newNode(.{ .call_expr = .{
                    .callee = expr,
                    .args = try args_list.toOwnedSlice(ctx.alloc()),
                    .arg_names = if (has_names) try names_list.toOwnedSlice(ctx.alloc()) else &.{},
                } });
            } else if (std.mem.eql(u8, r, "index_access")) {
                if (child.findChild("or_expr")) |ie| {
                    const index = try builder.buildNode(ctx, ie);
                    expr = try ctx.newNode(.{ .index_expr = .{ .object = expr, .index = index } });
                }
            } else if (std.mem.eql(u8, r, "slice_access")) {
                if (child.children.len >= 2) {
                    const low = try builder.buildNode(ctx, &child.children[0]);
                    const high = try builder.buildNode(ctx, &child.children[1]);
                    expr = try ctx.newNode(.{ .slice_expr = .{ .object = expr, .low = low, .high = high } });
                }
            }
        }
    }

    return expr;
}
