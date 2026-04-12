// builder_exprs.zig — Expression builders for the PEG AST builder
// Contains: buildIntLiteral, buildFloatLiteral, buildStringLiteral,
//           buildBoolLiteral, buildIdentifier, buildErrorLiteral,
//           buildCompilerFunc, buildArrayLiteral, buildGroupedExpr,
//           buildVersionLiteral, buildStructExpr, buildBinaryExpr,
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
                // Unclosed @{ — report error and emit remainder as literal
                ctx.reportError("unclosed '@{' in string — missing '}'", cap.start_pos);
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

pub fn buildVersionLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // version_literal <- '(' _ INT_LITERAL _ ',' _ INT_LITERAL _ ',' _ INT_LITERAL _ ')'
    var parts: [3][]const u8 = .{ "0", "0", "0" };
    var idx: usize = 0;
    var i = cap.start_pos;
    while (i < cap.end_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .int_literal and idx < 3) {
            parts[idx] = ctx.tokens[i].text;
            idx += 1;
        }
    }
    return ctx.newNode(.{ .version_literal = parts });
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
                    try operands.append(ctx.alloc(), child);
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
                    try idents.append(ctx.alloc(), ctx.tokens[j].text);
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
                try operands.append(ctx.alloc(), child);
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
    // postfix_expr <- primary_expr (method_call / field_access / slice_access / index_access / struct_init_access / call_access)*
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
            } else if (std.mem.eql(u8, r, "struct_init_access")) {
                var args_list = std.ArrayListUnmanaged(*Node){};
                var names_list = std.ArrayListUnmanaged([]const u8){};
                var has_names = false;
                try builder.collectCallArgs(ctx, child, &args_list, &names_list, &has_names);
                expr = try ctx.newNode(.{ .call_expr = .{
                    .callee = expr,
                    .args = try args_list.toOwnedSlice(ctx.alloc()),
                    .arg_names = if (has_names) try names_list.toOwnedSlice(ctx.alloc()) else &.{},
                } });
            } else if (std.mem.eql(u8, r, "call_access")) {
                // call_access handles positional args only (no named args)
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

// ============================================================
// TUPLE LITERAL BUILDER
// ============================================================

pub fn buildTupleLiteral(ctx: *BuildContext, cap: *const CaptureNode) anyerror!*Node {
    // tuple_literal <- '@' 'tuple' '(' _ (tuple_element (_ ',' _ tuple_element)* (_ ',')?)? _ ')'
    // tuple_element <- IDENTIFIER _ ':' _ expr   (choice_index 0 = named)
    //               /  expr                       (choice_index 1 = positional)
    var elements = std.ArrayListUnmanaged(*Node){};
    var names = std.ArrayListUnmanaged([]const u8){};
    var has_named: bool = false;
    var has_positional: bool = false;

    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (!std.mem.eql(u8, r, "tuple_element")) continue;
            // Detect named vs positional by checking whether the first token is an
            // identifier followed by a colon (named), or just an expression (positional).
            // choice_index 0 = named alternative, choice_index 1+ = positional.
            const is_named = child.choice_index == 0 and
                child.start_pos + 1 < child.end_pos and
                ctx.tokens[child.start_pos].kind == .identifier and
                ctx.tokens[child.start_pos + 1].kind == .colon;

            if (is_named) {
                has_named = true;
                const name_text = ctx.tokens[child.start_pos].text;
                try names.append(ctx.alloc(), name_text);
                // The expr child is inside the tuple_element capture
                if (child.findChild("expr")) |e| {
                    try elements.append(ctx.alloc(), try builder.buildNode(ctx, e));
                } else {
                    // Fallback: collect recursively
                    var expr_list = std.ArrayListUnmanaged(*Node){};
                    try builder.collectExprsRecursive(ctx, child, &expr_list);
                    if (expr_list.items.len > 0) {
                        try elements.append(ctx.alloc(), expr_list.items[0]);
                    }
                }
            } else {
                has_positional = true;
                try names.append(ctx.alloc(), "");
                if (child.findChild("expr")) |e| {
                    try elements.append(ctx.alloc(), try builder.buildNode(ctx, e));
                } else if (child.children.len > 0) {
                    try elements.append(ctx.alloc(), try builder.buildNode(ctx, &child.children[0]));
                } else {
                    // Terminal positional element
                    try elements.append(ctx.alloc(), try builder.buildTokenNode(ctx, child));
                }
            }
        }
    }

    if (has_named and has_positional) {
        ctx.reportError("cannot mix positional and named elements in @tuple", cap.start_pos);
        return error.BuildError;
    }

    return ctx.newNode(.{ .tuple_literal = .{
        .elements = try elements.toOwnedSlice(ctx.alloc()),
        .names = if (has_named) try names.toOwnedSlice(ctx.alloc()) else null,
    } });
}

// ============================================================
// TESTS
// ============================================================

test "buildTupleLiteral - positional form produces nodes with names=null" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = @import("../lexer.zig").Lexer.init(
        \\module mymod
        \\func f() void {
        \\    const t = @tuple(1, 2, 3)
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = @import("capture.zig").CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try builder.buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    const func = result.node.program.top_level[0];
    try std.testing.expect(func.* == .func_decl);
    const stmts = func.func_decl.body.block.statements;
    try std.testing.expect(stmts.len > 0);
    const decl = stmts[0];
    try std.testing.expect(decl.* == .var_decl);
    const tup_node = decl.var_decl.value;
    try std.testing.expect(tup_node.* == .tuple_literal);
    try std.testing.expectEqual(@as(usize, 3), tup_node.tuple_literal.elements.len);
    try std.testing.expect(tup_node.tuple_literal.names == null);
}

test "buildTupleLiteral - named form produces nodes with names slice" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = @import("../lexer.zig").Lexer.init(
        \\module mymod
        \\func f() void {
        \\    const t = @tuple(a: 1, b: 2)
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = @import("capture.zig").CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try builder.buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    const func = result.node.program.top_level[0];
    try std.testing.expect(func.* == .func_decl);
    const stmts = func.func_decl.body.block.statements;
    try std.testing.expect(stmts.len > 0);
    const decl = stmts[0];
    try std.testing.expect(decl.* == .var_decl);
    const tup_node = decl.var_decl.value;
    try std.testing.expect(tup_node.* == .tuple_literal);
    try std.testing.expectEqual(@as(usize, 2), tup_node.tuple_literal.elements.len);
    try std.testing.expect(tup_node.tuple_literal.names != null);
    try std.testing.expectEqualStrings("a", tup_node.tuple_literal.names.?[0]);
    try std.testing.expectEqualStrings("b", tup_node.tuple_literal.names.?[1]);
}

test "buildTupleLiteral - mixed form returns error" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = @import("../lexer.zig").Lexer.init(
        \\module mymod
        \\func f() void {
        \\    const t = @tuple(1, a: 2)
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = @import("capture.zig").CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    // buildAST must return an error for mixed positional+named
    const result = builder.buildAST(&cap, tokens.items, std.heap.page_allocator);
    try std.testing.expectError(error.BuildError, result);
}
