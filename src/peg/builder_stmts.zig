// builder_stmts.zig — Statement builders for the PEG AST builder
// Contains: buildBlock, buildReturn, buildIf, buildElifChain,
//           buildWhile, buildFor, buildDefer, buildMatch, buildMatchArm,
//           buildExprOrAssignment

const std = @import("std");
const builder = @import("builder.zig");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;
const TokenKind = lexer.TokenKind;

const BuildContext = builder.BuildContext;

// ============================================================
// STATEMENT BUILDERS
// ============================================================

pub fn buildBlock(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // block <- '{' _ statement* _ '}'
    var stmts = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "statement")) {
                // statement is transparent — build its actual content child
                for (child.children) |*sc| {
                    if (sc.rule) |sr| {
                        // Skip whitespace/newline rules
                        if (std.mem.eql(u8, sr, "_") or std.mem.eql(u8, sr, "TERM")) continue;
                        try stmts.append(ctx.alloc(), try builder.buildNode(ctx, sc));
                    }
                }
            }
            // Skip _ rules at block level
        }
    }
    return ctx.newNode(.{ .block = .{ .statements = try stmts.toOwnedSlice(ctx.alloc()) } });
}

pub fn buildReturn(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    var value: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        value = try builder.buildNode(ctx, e);
    }
    return ctx.newNode(.{ .return_stmt = .{ .value = value } });
}

pub fn buildIf(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // if_stmt <- 'if' '(' expr ')' block elif_chain?
    const condition = if (cap.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoCondition;
    const then_block = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;
    var else_block: ?*Node = null;
    if (cap.findChild("elif_chain")) |chain| {
        else_block = try builder.buildNode(ctx, chain);
    }
    return ctx.newNode(.{ .if_stmt = .{
        .condition = condition,
        .then_block = then_block,
        .else_block = else_block,
    } });
}

// elif_chain <- 'elif' '(' expr ')' block elif_chain?  /  'else' block
// Builds an if_stmt node (for the elif alternative) or a plain block (for the else alternative).
// The result is used as the else_block of the parent if_stmt or elif_chain.
pub fn buildElifChain(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // Check if this is an 'elif' or 'else' branch by looking for an expr child.
    // An 'elif' branch has: expr (condition) + block (then) + optional elif_chain (else)
    // An 'else' branch has: only a block child.
    if (cap.findChild("expr")) |e| {
        // elif branch
        const condition = try builder.buildNode(ctx, e);
        const then_block = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;
        var else_block: ?*Node = null;
        if (cap.findChild("elif_chain")) |chain| {
            else_block = try builder.buildNode(ctx, chain);
        }
        return ctx.newNode(.{ .if_stmt = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        } });
    } else {
        // else branch — just a block
        return if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;
    }
}

pub fn buildWhile(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const condition = if (cap.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoCondition;
    var continue_expr: ?*Node = null;
    if (cap.findChild("assign_expr")) |ae| {
        continue_expr = try builder.buildNode(ctx, ae);
    }
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .while_stmt = .{
        .condition = condition,
        .continue_expr = continue_expr,
        .body = body,
    } });
}

pub fn buildFor(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const iterable = if (cap.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoIterable;
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;

    // Extract captures from for_captures child
    var captures = std.ArrayListUnmanaged([]const u8){};
    if (cap.findChild("for_captures")) |fc| {
        for (fc.start_pos..fc.end_pos) |i| {
            if (i < ctx.tokens.len and ctx.tokens[i].kind == .identifier) {
                try captures.append(ctx.alloc(), ctx.tokens[i].text);
            }
        }
    }
    // If two captures, the second is the index variable
    var index_var: ?[]const u8 = null;
    if (captures.items.len >= 2) {
        index_var = captures.pop();
    }
    return ctx.newNode(.{ .for_stmt = .{
        .iterable = iterable,
        .captures = try captures.toOwnedSlice(ctx.alloc()),
        .index_var = index_var,
        .body = body,
        .is_compt = false,
        .is_tuple_capture = false,
    } });
}

pub fn buildDefer(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .defer_stmt = .{ .body = body } });
}

pub fn buildMatch(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const value = if (cap.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoMatchValue;
    const arms = try builder.buildChildrenByRule(ctx, cap, "match_arm");
    return ctx.newNode(.{ .match_stmt = .{ .value = value, .arms = arms } });
}

pub fn buildMatchArm(ctx: *BuildContext, cap: *const CaptureNode) anyerror!*Node {
    const mp_cap = cap.findChild("match_pattern") orelse return error.NoPattern;
    const body = if (cap.findChild("block")) |b| try builder.buildNode(ctx, b) else return error.NoBlock;

    // Check if match_pattern contains a parenthesized_pattern.
    // parenthesized_pattern is a named rule ref, so it appears as a child of match_pattern
    // when that alternative fires.
    if (mp_cap.findChild("parenthesized_pattern")) |pp| {
        // Determine which alternative matched by scanning tokens:
        // Guarded:  '(' IDENTIFIER 'if' expr ')' — has kw_if between '(' and first expr
        // Plain:    '(' expr ')'
        //
        // If there is a kw_if token in the pp token range (after the first identifier),
        // it is a guarded binding. IDENTIFIER is a terminal token not a sub-rule, so we
        // must scan tokens directly instead of using findChild.
        const has_if_kw = builder.findTokenInRange(ctx, pp.start_pos, pp.end_pos, .kw_if) != null;

        if (has_if_kw) {
            // Guarded pattern: (x if guard_expr)
            // First token after '(' is the bound identifier
            const ident_pos = pp.start_pos + 1; // '(' is at start_pos, IDENTIFIER is next
            if (ident_pos >= ctx.tokens.len) return error.NoPattern;
            const ident_text = ctx.tokens[ident_pos].text;
            const pattern = try ctx.newNode(.{ .identifier = ident_text });
            // The expr child of pp is the guard expression
            const guard = if (pp.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoGuardExpr;
            return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } });
        }

        // Non-guarded parenthesized pattern: (1..10) or (42)
        // Build the inner expr as the pattern
        const pattern = if (pp.findChild("expr")) |e| try builder.buildNode(ctx, e) else return error.NoPattern;
        return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = null, .body = body } });
    }

    // Plain pattern (bare literal, identifier, or 'else')
    const pattern = try builder.buildNode(ctx, mp_cap);
    return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = null, .body = body } });
}

pub fn buildExprOrAssignment(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // expr_or_assignment <- expr assign_op expr TERM / expr TERM
    // Check if there's an assign_op child
    if (cap.findChild("assign_op")) |_| {
        // Assignment: expr assign_op expr
        var exprs = std.ArrayListUnmanaged(*const CaptureNode){};
        for (cap.children) |*child| {
            if (child.rule) |r| {
                if (std.mem.eql(u8, r, "expr")) {
                    try exprs.append(ctx.alloc(), child);
                }
            }
        }
        if (exprs.items.len >= 2) {
            const lhs = try builder.buildNode(ctx, exprs.items[0]);
            const rhs = try builder.buildNode(ctx, exprs.items[1]);
            // Find the operator token
            var op: parser.Operator = .assign;
            for (cap.children) |*child| {
                if (child.rule) |r| {
                    if (std.mem.eql(u8, r, "assign_op")) {
                        op = parser.Operator.parse(builder.tokenText(ctx, child.start_pos));
                        break;
                    }
                }
            }
            return ctx.newNode(.{ .assignment = .{ .op = op, .left = lhs, .right = rhs } });
        }
    }

    // Plain expression
    if (cap.findChild("expr")) |e| return builder.buildNode(ctx, e);
    return error.NoExpr;
}
