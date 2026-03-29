// engine.zig — PEG packrat matching engine
//
// Token-level PEG interpreter with memoization. Takes a Grammar and
// a token stream, returns whether the input matches a given rule.
// Packrat memoization guarantees O(n * G) worst-case performance
// where n = token count and G = number of grammar rules.

const std = @import("std");
const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const Expr = grammar_mod.Expr;
const lexer = @import("../lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

// ============================================================
// KIND DISPLAY NAME
// ============================================================

/// Return a human-readable display name for a token kind.
/// Strips the "kw_" prefix from keywords, and provides readable names for
/// special token kinds.
pub fn kindDisplayName(kind: TokenKind) []const u8 {
    const raw = @tagName(kind);
    if (std.mem.startsWith(u8, raw, "kw_")) return raw[3..];
    return switch (kind) {
        .eof => "end of file",
        .newline => "newline",
        .identifier => "identifier",
        .int_literal => "integer literal",
        .float_literal => "float literal",
        .string_literal => "string literal",
        else => raw,
    };
}

// ============================================================
// MATCH RESULT
// ============================================================

/// Result of a successful match — just the end position for now.
/// Phase 2 will add AST node construction.
pub const MatchResult = struct {
    end_pos: usize,
};

// ============================================================
// MEMO TABLE
// ============================================================

const MemoKey = struct {
    rule: []const u8,
    pos: usize,
};

const MemoEntry = union(enum) {
    success: MatchResult,
    failure: void,
};

const MemoContext = struct {
    pub fn hash(_: MemoContext, key: MemoKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.rule);
        h.update(std.mem.asBytes(&key.pos));
        return h.final();
    }

    pub fn eql(_: MemoContext, a: MemoKey, b: MemoKey) bool {
        return a.pos == b.pos and std.mem.eql(u8, a.rule, b.rule);
    }
};

const MemoTable = std.HashMapUnmanaged(MemoKey, MemoEntry, MemoContext, 80);

// ============================================================
// ENGINE
// ============================================================

/// Error info from the furthest failure point during parsing.
pub const ParseError = struct {
    pos: usize, // token index where failure occurred
    line: usize,
    col: usize,
    found: []const u8, // token text at failure point
    found_kind: TokenKind,
    expected_rule: []const u8, // rule that was being attempted
    expected_set: std.EnumSet(TokenKind), // all expected token kinds at furthest failure (deduplicated)
    label: ?[]const u8, // human-readable label from grammar annotation, if present
};

pub const Engine = struct {
    grammar: *const Grammar,
    tokens: []const Token,
    memo: MemoTable,
    allocator: std.mem.Allocator,
    // Error tracking — furthest failure position
    furthest_pos: usize = 0,
    furthest_rule: []const u8 = "",
    furthest_label: ?[]const u8 = null,
    // Expected tokens at furthest position — EnumSet provides O(1) insert and automatic deduplication
    furthest_expected: std.EnumSet(TokenKind) = std.EnumSet(TokenKind).initEmpty(),

    pub fn init(grammar: *const Grammar, tokens: []const Token, allocator: std.mem.Allocator) Engine {
        return .{
            .grammar = grammar,
            .tokens = tokens,
            .memo = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.memo.deinit(self.allocator);
    }

    /// Get error info after a failed parse.
    /// Returns ParseError with the EnumSet of expected tokens at the furthest failure position.
    pub fn getError(self: *Engine) ParseError {
        const pos = @min(self.furthest_pos, if (self.tokens.len > 0) self.tokens.len - 1 else 0);
        const tok = if (pos < self.tokens.len) self.tokens[pos] else Token{
            .kind = .eof, .text = "", .line = 0, .col = 0,
        };
        return .{
            .pos = pos,
            .line = tok.line,
            .col = tok.col,
            .found = tok.text,
            .found_kind = tok.kind,
            .expected_rule = self.furthest_rule,
            .expected_set = self.furthest_expected,
            .label = self.furthest_label,
        };
    }

    /// Try to match a named rule at the current position.
    /// Returns the match result (end position) or null if no match.
    pub fn matchRule(self: *Engine, rule_name: []const u8, pos: usize) ?MatchResult {
        // Check memo table
        const key = MemoKey{ .rule = rule_name, .pos = pos };
        if (self.memo.get(key)) |entry| {
            return switch (entry) {
                .success => |r| r,
                .failure => null,
            };
        }

        // Look up rule
        const expr = self.grammar.getRule(rule_name) orelse {
            // Unknown rule — treat as failure
            return null;
        };

        // Evaluate
        const result = self.eval(expr, pos);

        // Track rule name and label for error reporting
        if (result == null and pos >= self.furthest_pos) {
            self.furthest_rule = rule_name;
            self.furthest_label = self.grammar.getLabel(rule_name);
        }

        // Memoize
        self.memo.put(self.allocator, key, if (result) |r|
            MemoEntry{ .success = r }
        else
            MemoEntry{ .failure = {} }) catch {};

        return result;
    }

    /// Evaluate a grammar expression against tokens starting at pos.
    fn eval(self: *Engine, expr: Expr, pos: usize) ?MatchResult {
        return switch (expr) {
            .token => |kind| self.matchToken(kind, pos),
            .token_text => |tt| self.matchTokenText(tt.kind, tt.text, pos),
            .rule_ref => |name| self.matchRule(name, pos),
            .sequence => |exprs| self.evalSequence(exprs, pos),
            .choice => |alts| self.evalChoice(alts, pos),
            .repeat => |inner| self.evalRepeat(inner, pos, 0),
            .repeat1 => |inner| self.evalRepeat(inner, pos, 1),
            .optional => |inner| self.evalOptional(inner, pos),
            .not => |inner| self.evalNot(inner, pos),
            .ahead => |inner| self.evalAhead(inner, pos),
        };
    }

    /// Match a single token by kind
    fn matchToken(self: *Engine, expected: TokenKind, pos: usize) ?MatchResult {
        if (pos >= self.tokens.len) {
            self.trackFailure(pos, expected);
            return null;
        }
        if (self.tokens[pos].kind == expected) {
            return MatchResult{ .end_pos = pos + 1 };
        }
        self.trackFailure(pos, expected);
        return null;
    }

    /// Match a token by kind AND text (for contextual identifiers)
    fn matchTokenText(self: *Engine, expected_kind: TokenKind, expected_text: []const u8, pos: usize) ?MatchResult {
        if (pos >= self.tokens.len) return null;
        const tok = self.tokens[pos];
        if (tok.kind == expected_kind and std.mem.eql(u8, tok.text, expected_text)) {
            return MatchResult{ .end_pos = pos + 1 };
        }
        return null;
    }

    fn trackFailure(self: *Engine, pos: usize, expected: TokenKind) void {
        if (pos > self.furthest_pos) {
            // New furthest position — reset set
            self.furthest_pos = pos;
            self.furthest_expected = std.EnumSet(TokenKind).initEmpty();
            self.furthest_expected.insert(expected);
        } else if (pos == self.furthest_pos) {
            // Same position — accumulate (EnumSet handles deduplication automatically)
            self.furthest_expected.insert(expected);
        }
        // pos < furthest_pos: ignore
    }

    /// Evaluate a sequence: all elements must match in order
    fn evalSequence(self: *Engine, exprs: []const Expr, pos: usize) ?MatchResult {
        var current = pos;
        for (exprs) |expr| {
            const result = self.eval(expr, current) orelse return null;
            current = result.end_pos;
        }
        return MatchResult{ .end_pos = current };
    }

    /// Evaluate ordered choice: first matching alternative wins
    fn evalChoice(self: *Engine, alts: []const Expr, pos: usize) ?MatchResult {
        for (alts) |alt| {
            if (self.eval(alt, pos)) |result| {
                return result;
            }
        }
        return null;
    }

    /// Evaluate repetition: match inner at least min_count times
    fn evalRepeat(self: *Engine, inner: *const Expr, pos: usize, min_count: usize) ?MatchResult {
        var current = pos;
        var count: usize = 0;

        while (true) {
            const result = self.eval(inner.*, current) orelse break;
            // Guard against zero-length matches causing infinite loops
            if (result.end_pos == current) break;
            current = result.end_pos;
            count += 1;
        }

        if (count < min_count) return null;
        return MatchResult{ .end_pos = current };
    }

    /// Evaluate optional: try to match, succeed either way
    fn evalOptional(self: *Engine, inner: *const Expr, pos: usize) ?MatchResult {
        if (self.eval(inner.*, pos)) |result| {
            return result;
        }
        return MatchResult{ .end_pos = pos };
    }

    /// Negative lookahead: succeed if inner fails, consume nothing
    fn evalNot(self: *Engine, inner: *const Expr, pos: usize) ?MatchResult {
        if (self.eval(inner.*, pos)) |_| {
            return null; // inner matched — negation fails
        }
        return MatchResult{ .end_pos = pos }; // inner failed — negation succeeds
    }

    /// Positive lookahead: succeed if inner matches, consume nothing
    fn evalAhead(self: *Engine, inner: *const Expr, pos: usize) ?MatchResult {
        if (self.eval(inner.*, pos)) |_| {
            return MatchResult{ .end_pos = pos }; // matched — but don't consume
        }
        return null;
    }

    /// Convenience: try to match the start rule ("program") against the full token stream.
    /// Returns true if the entire input is consumed.
    pub fn matchAll(self: *Engine, rule_name: []const u8) bool {
        const result = self.matchRule(rule_name, 0) orelse return false;
        // Check that we consumed all tokens (or reached EOF)
        if (result.end_pos >= self.tokens.len) return true;
        // Allow stopping at EOF token
        if (self.tokens[result.end_pos].kind == .eof) return true;
        return false;
    }
};

// ============================================================
// TESTS
// ============================================================

test "engine - match single token" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "kw\n    <- 'func'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .kw_func, .text = "func", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 5 },
    };

    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();

    const result = engine.matchRule("kw", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.end_pos);
}

test "engine - match sequence" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "mod\n    <- 'module' IDENTIFIER NL\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .kw_module, .text = "module", .line = 1, .col = 1 },
        .{ .kind = .identifier, .text = "example", .line = 1, .col = 8 },
        .{ .kind = .newline, .text = "\n", .line = 1, .col = 15 },
        .{ .kind = .eof, .text = "", .line = 2, .col = 1 },
    };

    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();

    try std.testing.expect(engine.matchAll("mod"));
}

test "engine - match choice" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "name\n    <- IDENTIFIER / 'main'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    // Test with identifier
    const tokens1 = [_]Token{
        .{ .kind = .identifier, .text = "foo", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 4 },
    };
    var e1 = Engine.init(&g, &tokens1, alloc);
    defer e1.deinit();
    try std.testing.expect(e1.matchAll("name"));

    // Test with 'main' keyword
    const tokens2 = [_]Token{
        .{ .kind = .kw_main, .text = "main", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 5 },
    };
    var e2 = Engine.init(&g, &tokens2, alloc);
    defer e2.deinit();
    try std.testing.expect(e2.matchAll("name"));
}

test "engine - match repetition" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "items\n    <- IDENTIFIER (',' IDENTIFIER)*\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .identifier, .text = "a", .line = 1, .col = 1 },
        .{ .kind = .comma, .text = ",", .line = 1, .col = 2 },
        .{ .kind = .identifier, .text = "b", .line = 1, .col = 3 },
        .{ .kind = .comma, .text = ",", .line = 1, .col = 4 },
        .{ .kind = .identifier, .text = "c", .line = 1, .col = 5 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 6 },
    };

    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();
    try std.testing.expect(engine.matchAll("items"));
}

test "engine - negative lookahead" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "not_nl\n    <- !NL IDENTIFIER\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    // Should match: identifier without newline before it
    const tokens1 = [_]Token{
        .{ .kind = .identifier, .text = "x", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 2 },
    };
    var e1 = Engine.init(&g, &tokens1, alloc);
    defer e1.deinit();
    try std.testing.expect(e1.matchAll("not_nl"));

    // Should fail: newline at position
    const tokens2 = [_]Token{
        .{ .kind = .newline, .text = "\n", .line = 1, .col = 1 },
        .{ .kind = .identifier, .text = "x", .line = 2, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 2, .col = 2 },
    };
    var e2 = Engine.init(&g, &tokens2, alloc);
    defer e2.deinit();
    try std.testing.expect(!e2.matchAll("not_nl"));
}

test "engine - choice failure accumulates expected set" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "item\n    <- 'func' / 'struct' / 'enum'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .identifier, .text = "foo", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 4 },
    };
    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();
    _ = engine.matchRule("item", 0);
    const err = engine.getError();
    try std.testing.expectEqual(@as(usize, 3), err.expected_set.count());
    try std.testing.expect(err.expected_set.contains(.kw_func));
    try std.testing.expect(err.expected_set.contains(.kw_struct));
    try std.testing.expect(err.expected_set.contains(.kw_enum));
}

test "engine - expected set deduplication" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "item\n    <- 'func' / 'func'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .identifier, .text = "foo", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 4 },
    };
    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();
    _ = engine.matchRule("item", 0);
    const err = engine.getError();
    try std.testing.expectEqual(@as(usize, 1), err.expected_set.count());
}

test "engine - single token failure keeps len 1" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "item\n    <- 'func'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    const tokens = [_]Token{
        .{ .kind = .identifier, .text = "foo", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 4 },
    };
    var engine = Engine.init(&g, &tokens, alloc);
    defer engine.deinit();
    _ = engine.matchRule("item", 0);
    const err = engine.getError();
    try std.testing.expectEqual(@as(usize, 1), err.expected_set.count());
    try std.testing.expect(err.expected_set.contains(.kw_func));
}

test "engine - kindDisplayName" {
    try std.testing.expectEqualStrings("func", kindDisplayName(.kw_func));
    try std.testing.expectEqualStrings("end of file", kindDisplayName(.eof));
    try std.testing.expectEqualStrings("integer literal", kindDisplayName(.int_literal));
    try std.testing.expectEqualStrings("identifier", kindDisplayName(.identifier));
}

test "engine - optional match" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "maybe\n    <- 'pub'? 'func'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    // With pub
    const tokens1 = [_]Token{
        .{ .kind = .kw_pub, .text = "pub", .line = 1, .col = 1 },
        .{ .kind = .kw_func, .text = "func", .line = 1, .col = 5 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 9 },
    };
    var e1 = Engine.init(&g, &tokens1, alloc);
    defer e1.deinit();
    try std.testing.expect(e1.matchAll("maybe"));

    // Without pub
    const tokens2 = [_]Token{
        .{ .kind = .kw_func, .text = "func", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 5 },
    };
    var e2 = Engine.init(&g, &tokens2, alloc);
    defer e2.deinit();
    try std.testing.expect(e2.matchAll("maybe"));
}
