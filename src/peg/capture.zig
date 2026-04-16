// capture.zig — PEG capture tree and AST-building engine
//
// Extends the basic matching engine to produce CaptureNodes — a lightweight
// parse tree that records which rules matched at which positions. The builder
// module then transforms capture trees into parser.Node AST nodes.
//
// Separated from engine.zig to keep the validation-only path fast and simple.

const std = @import("std");
const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const Expr = grammar_mod.Expr;
const lexer = @import("../lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

// ============================================================
// CAPTURE NODE — lightweight parse tree
// ============================================================

pub const CaptureNode = struct {
    /// Which grammar rule produced this node (null for anonymous expressions)
    rule: ?[]const u8,
    /// Token range
    start_pos: usize,
    end_pos: usize,
    /// Sub-captures from rule_ref matches within sequences
    children: []CaptureNode,
    /// Which alternative matched in a choice (0-indexed)
    choice_index: usize,

    /// Find the first child matching a rule name
    pub fn findChild(self: *const CaptureNode, name: []const u8) ?*const CaptureNode {
        for (self.children) |*child| {
            if (child.rule) |r| {
                if (std.mem.eql(u8, r, name)) return child;
            }
        }
        return null;
    }

    /// Get token text at a specific position within this capture's range
    pub fn tokenText(self: *const CaptureNode, tokens: []const Token, offset: usize) []const u8 {
        const idx = self.start_pos + offset;
        if (idx < tokens.len) return tokens[idx].text;
        return "";
    }

};

// ============================================================
// CAPTURE ENGINE
// ============================================================

pub const CaptureEngine = struct {
    grammar: *const Grammar,
    tokens: []const Token,
    arena: std.heap.ArenaAllocator,

    pub fn init(grammar: *const Grammar, tokens: []const Token, backing_allocator: std.mem.Allocator) CaptureEngine {
        return .{
            .grammar = grammar,
            .tokens = tokens,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    /// Arena allocator — must be called on the live struct, not a stack copy.
    fn alloc(self: *CaptureEngine) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *CaptureEngine) void {
        self.arena.deinit();
    }

    /// Match a named rule and produce a capture tree.
    pub fn captureRule(self: *CaptureEngine, rule_name: []const u8, pos: usize) ?CaptureNode {
        const expr = self.grammar.getRule(rule_name) orelse return null;

        var children = std.ArrayListUnmanaged(CaptureNode){};
        const end_pos = self.evalCapture(expr, pos, &children) orelse return null;

        return CaptureNode{
            .rule = rule_name,
            .start_pos = pos,
            .end_pos = end_pos,
            .children = children.toOwnedSlice(self.alloc()) catch &.{},
            .choice_index = 0,
        };
    }

    /// Match the full program and return the capture tree.
    pub fn captureProgram(self: *CaptureEngine) ?CaptureNode {
        const result = self.captureRule("program", 0) orelse return null;
        // Verify full consumption
        if (result.end_pos >= self.tokens.len) return result;
        if (self.tokens[result.end_pos].kind == .eof) return result;
        return null;
    }

    /// Evaluate an expression, collecting capture nodes from rule_ref matches.
    fn evalCapture(self: *CaptureEngine, expr: Expr, pos: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        return switch (expr) {
            .token => |kind| self.matchToken(kind, pos),
            .token_text => |tt| self.matchTokenText(tt.kind, tt.text, pos),
            .rule_ref => |name| self.evalRuleRef(name, pos, children),
            .sequence => |exprs| self.evalSequence(exprs, pos, children),
            .choice => |alts| self.evalChoice(alts, pos, children),
            .repeat => |inner| self.evalRepeat(inner, pos, 0, children),
            .repeat1 => |inner| self.evalRepeat(inner, pos, 1, children),
            .optional => |inner| self.evalOptional(inner, pos, children),
            .not => |inner| self.evalNot(inner, pos),
            .ahead => |inner| self.evalAhead(inner, pos),
            .any_token => self.matchAnyToken(pos),
        };
    }

    /// Match any single non-EOF token (PEG `.`)
    fn matchAnyToken(self: *CaptureEngine, pos: usize) ?usize {
        if (pos >= self.tokens.len) return null;
        if (self.tokens[pos].kind == .eof) return null;
        return pos + 1;
    }

    fn matchToken(self: *CaptureEngine, expected: TokenKind, pos: usize) ?usize {
        if (pos >= self.tokens.len) return null;
        if (self.tokens[pos].kind == expected) return pos + 1;
        return null;
    }

    fn matchTokenText(self: *CaptureEngine, expected_kind: TokenKind, expected_text: []const u8, pos: usize) ?usize {
        if (pos >= self.tokens.len) return null;
        const tok = self.tokens[pos];
        if (tok.kind == expected_kind and std.mem.eql(u8, tok.text, expected_text)) return pos + 1;
        return null;
    }

    fn evalRuleRef(self: *CaptureEngine, name: []const u8, pos: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        const cap = self.captureRule(name, pos) orelse return null;
        children.append(self.alloc(), cap) catch return null;
        return cap.end_pos;
    }

    fn evalSequence(self: *CaptureEngine, exprs: []const Expr, pos: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        const saved_len = children.items.len;
        var current = pos;
        for (exprs) |expr| {
            const end = self.evalCapture(expr, current, children) orelse {
                // Backtrack children
                children.shrinkRetainingCapacity(saved_len);
                return null;
            };
            current = end;
        }
        return current;
    }

    fn evalChoice(self: *CaptureEngine, alts: []const Expr, pos: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        for (alts) |alt| {
            const saved_len = children.items.len;
            if (self.evalCapture(alt, pos, children)) |end| {
                return end;
            }
            children.shrinkRetainingCapacity(saved_len);
        }
        return null;
    }

    fn evalRepeat(self: *CaptureEngine, inner: *const Expr, pos: usize, min_count: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        var current = pos;
        var count: usize = 0;

        while (true) {
            const end = self.evalCapture(inner.*, current, children) orelse break;
            if (end == current) break;
            current = end;
            count += 1;
        }

        if (count < min_count) return null;
        return current;
    }

    fn evalOptional(self: *CaptureEngine, inner: *const Expr, pos: usize, children: *std.ArrayListUnmanaged(CaptureNode)) ?usize {
        if (self.evalCapture(inner.*, pos, children)) |end| {
            return end;
        }
        return pos;
    }

    fn evalNot(self: *CaptureEngine, inner: *const Expr, pos: usize) ?usize {
        // Negative lookahead — discard any captures
        var dummy = std.ArrayListUnmanaged(CaptureNode){};
        if (self.evalCapture(inner.*, pos, &dummy)) |_| return null;
        return pos;
    }

    fn evalAhead(self: *CaptureEngine, inner: *const Expr, pos: usize) ?usize {
        // Positive lookahead — discard any captures
        var dummy = std.ArrayListUnmanaged(CaptureNode){};
        if (self.evalCapture(inner.*, pos, &dummy)) |_| return pos;
        return null;
    }
};

// ============================================================
// TESTS
// ============================================================

test "capture - simple rule produces capture tree" {
    const alloc = std.testing.allocator;

    const src = "mod\n    <- 'module' IDENTIFIER NL\n";
    var g = try grammar_mod.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .kw_module, .text = "module", .line = 1, .col = 1 },
        .{ .kind = .identifier, .text = "main", .line = 1, .col = 8 },
        .{ .kind = .newline, .text = "\n", .line = 1, .col = 12 },
        .{ .kind = .eof, .text = "", .line = 2, .col = 1 },
    };

    var engine = CaptureEngine.init(&g, &tokens, std.heap.page_allocator);
    defer engine.deinit();
    const result = engine.captureRule("mod", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start_pos);
    try std.testing.expectEqual(@as(usize, 3), result.?.end_pos);
    try std.testing.expectEqualStrings("mod", result.?.rule.?);
}

test "capture - rule with sub-rules produces children" {
    const alloc = std.testing.allocator;

    const src =
        \\prog
        \\    <- mod_decl func_decl
        \\mod_decl
        \\    <- 'module' IDENTIFIER NL
        \\func_decl
        \\    <- 'func' IDENTIFIER NL
        \\
    ;
    var g = try grammar_mod.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .kw_module, .text = "module", .line = 1, .col = 1 },
        .{ .kind = .identifier, .text = "main", .line = 1, .col = 8 },
        .{ .kind = .newline, .text = "\n", .line = 1, .col = 12 },
        .{ .kind = .kw_func, .text = "func", .line = 2, .col = 1 },
        .{ .kind = .identifier, .text = "foo", .line = 2, .col = 6 },
        .{ .kind = .newline, .text = "\n", .line = 2, .col = 9 },
        .{ .kind = .eof, .text = "", .line = 3, .col = 1 },
    };

    var engine = CaptureEngine.init(&g, &tokens, std.heap.page_allocator);
    defer engine.deinit();
    const result = engine.captureRule("prog", 0);
    try std.testing.expect(result != null);

    // prog should have two children: mod_decl and func_decl
    try std.testing.expectEqual(@as(usize, 2), result.?.children.len);
    try std.testing.expectEqualStrings("mod_decl", result.?.children[0].rule.?);
    try std.testing.expectEqualStrings("func_decl", result.?.children[1].rule.?);

    // mod_decl spans tokens 0-3
    try std.testing.expectEqual(@as(usize, 0), result.?.children[0].start_pos);
    try std.testing.expectEqual(@as(usize, 3), result.?.children[0].end_pos);

    // func_decl spans tokens 3-6
    try std.testing.expectEqual(@as(usize, 3), result.?.children[1].start_pos);
    try std.testing.expectEqual(@as(usize, 6), result.?.children[1].end_pos);
}

test "capture - findChild by rule name" {
    const alloc = std.testing.allocator;

    const src =
        \\prog
        \\    <- mod_decl func_decl
        \\mod_decl
        \\    <- 'module' IDENTIFIER NL
        \\func_decl
        \\    <- 'func' IDENTIFIER NL
        \\
    ;
    var g = try grammar_mod.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .kw_module, .text = "module", .line = 1, .col = 1 },
        .{ .kind = .identifier, .text = "main", .line = 1, .col = 8 },
        .{ .kind = .newline, .text = "\n", .line = 1, .col = 12 },
        .{ .kind = .kw_func, .text = "func", .line = 2, .col = 1 },
        .{ .kind = .identifier, .text = "foo", .line = 2, .col = 6 },
        .{ .kind = .newline, .text = "\n", .line = 2, .col = 9 },
        .{ .kind = .eof, .text = "", .line = 3, .col = 1 },
    };

    var engine = CaptureEngine.init(&g, &tokens, std.heap.page_allocator);
    defer engine.deinit();
    const result = engine.captureRule("prog", 0) orelse return error.TestFailed;

    const mod = result.findChild("mod_decl");
    try std.testing.expect(mod != null);
    try std.testing.expectEqualStrings("mod_decl", mod.?.rule.?);

    const func = result.findChild("func_decl");
    try std.testing.expect(func != null);
    try std.testing.expectEqualStrings("func_decl", func.?.rule.?);

    // Non-existent child
    try std.testing.expect(result.findChild("nonexistent") == null);
}

test "capture - full orhon program" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const result = engine.captureProgram();
    try std.testing.expect(result != null);

    // program should have children: module_decl and top_level (containing func_decl)
    const prog = result.?;
    try std.testing.expect(prog.findChild("module_decl") != null);
}
