// grammar.zig — PEG grammar data structures + .peg file parser
//
// Parses the text format of orhon.peg into a Grammar data structure
// that the matching engine can evaluate against token streams.

const std = @import("std");
const token_map = @import("token_map.zig");
const lexer = @import("../lexer.zig");
const TokenKind = lexer.TokenKind;

// ============================================================
// DATA STRUCTURES
// ============================================================

/// PEG expression tree — the fundamental building block of grammar rules.
/// Recursive tagged union, arena-allocated.
pub const Expr = union(enum) {
    /// Match a token by kind: 'func' -> .kw_func, IDENTIFIER -> .identifier
    token: TokenKind,

    /// Match a token by kind (.identifier) AND text value.
    /// Used for contextual identifiers like 'Error', 'Ptr', 'dep', 'linkC'.
    token_text: struct { kind: TokenKind, text: []const u8 },

    /// Reference to another grammar rule by name
    rule_ref: []const u8,

    /// Ordered sequence: all elements must match in order
    sequence: []const Expr,

    /// Ordered choice: first matching alternative wins (PEG `/`)
    choice: []const Expr,

    /// Zero or more repetitions (PEG `*`)
    repeat: *const Expr,

    /// One or more repetitions (PEG `+`)
    repeat1: *const Expr,

    /// Optional match (PEG `?`)
    optional: *const Expr,

    /// Negative lookahead — succeed if inner fails, consume nothing (PEG `!`)
    not: *const Expr,

    /// Positive lookahead — succeed if inner matches, consume nothing (PEG `&`)
    ahead: *const Expr,
};

/// A named grammar rule
pub const Rule = struct {
    name: []const u8,
    body: Expr,
};

/// The complete parsed grammar
pub const Grammar = struct {
    rules: std.StringHashMapUnmanaged(Expr),
    rule_names: []const []const u8, // preserve definition order
    arena: std.heap.ArenaAllocator,

    pub fn getRule(self: *const Grammar, name: []const u8) ?Expr {
        return self.rules.get(name);
    }

    pub fn deinit(self: *Grammar) void {
        const backing = self.arena.child_allocator;
        var arena_copy = self.arena;
        _ = backing;
        arena_copy.deinit();
    }
};

// ============================================================
// PEG FILE PARSER
// ============================================================

/// Parse a .peg grammar file text into a Grammar data structure.
/// Uses the provided allocator for all allocations (arena recommended).
pub fn parseGrammar(source: []const u8, backing_allocator: std.mem.Allocator) !Grammar {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    const allocator = arena.allocator();
    var parser = GrammarParser{
        .source = source,
        .pos = 0,
        .allocator = allocator,
        .rules = .{},
        .rule_names = .{},
    };
    try parser.parse();

    // Override character-level rules with token-level equivalents.
    // The .peg file defines these with character classes for documentation,
    // but the engine operates on tokens from the lexer.

    // _ = zero or more newline tokens (skip whitespace between constructs)
    const nl_token = try allocator.create(Expr);
    nl_token.* = Expr{ .token = .newline };
    try parser.rules.put(allocator, "_", Expr{ .repeat = nl_token });

    // TERM = statement terminator: newline, or lookahead '}', or EOF
    // Matches the parser's expectNewlineOrEof + rbrace behavior.
    const rbrace_ahead = try allocator.create(Expr);
    rbrace_ahead.* = Expr{ .token = .rbrace };
    const eof_ahead = try allocator.create(Expr);
    eof_ahead.* = Expr{ .token = .eof };
    const term_alts = try allocator.alloc(Expr, 3);
    term_alts[0] = Expr{ .token = .newline };
    term_alts[1] = Expr{ .ahead = rbrace_ahead };
    term_alts[2] = Expr{ .ahead = eof_ahead };
    try parser.rules.put(allocator, "TERM", Expr{ .choice = term_alts });

    // EOF = match eof token
    try parser.rules.put(allocator, "EOF", Expr{ .token = .eof });

    return Grammar{
        .rules = parser.rules,
        .rule_names = try parser.rule_names.toOwnedSlice(allocator),
        .arena = arena,
    };
}

const GrammarParser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    rules: std.StringHashMapUnmanaged(Expr),
    rule_names: std.ArrayListUnmanaged([]const u8),

    fn parse(self: *GrammarParser) !void {
        while (self.pos < self.source.len) {
            self.skipBlankAndComments();
            if (self.pos >= self.source.len) break;

            // A rule starts with an unindented identifier at column 0
            if (!self.isAtLineStart()) {
                self.skipLine();
                continue;
            }

            const c = self.source[self.pos];
            if (!isIdentStart(c)) {
                self.skipLine();
                continue;
            }

            // Read rule name
            const name = self.readIdent();

            // Skip to <- on next line or same line
            self.skipWhitespaceOnly();
            if (!self.matchStr("<-")) {
                // Maybe <- is on the next line (indented)
                self.skipLine();
                self.skipWhitespaceOnly();
                if (!self.matchStr("<-")) continue;
            }

            // Parse the rule body
            const body = try self.parseChoiceExpr();

            // Store rule
            try self.rules.put(self.allocator, name, body);
            try self.rule_names.append(self.allocator, name);
        }
    }

    // ── Expression Parsing ──────────────────────────────────

    /// Parse a choice expression: alt1 / alt2 / alt3
    fn parseChoiceExpr(self: *GrammarParser) anyerror!Expr {
        var alts = std.ArrayListUnmanaged(Expr){};
        try alts.append(self.allocator, try self.parseSequenceExpr());

        while (true) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) break;

            // Choice continuation: '/' at start of content (possibly after indentation)
            if (self.source[self.pos] == '/') {
                // Make sure it's not '/=' or '//'
                if (self.pos + 1 < self.source.len and
                    (self.source[self.pos + 1] == '=' or self.source[self.pos + 1] == '/'))
                    break;
                self.pos += 1;
                self.skipWhitespaceOnly();
                try alts.append(self.allocator, try self.parseSequenceExpr());
            } else break;
        }

        if (alts.items.len == 1) return alts.items[0];
        return Expr{ .choice = try alts.toOwnedSlice(self.allocator) };
    }

    /// Parse a sequence expression: elem1 elem2 elem3
    fn parseSequenceExpr(self: *GrammarParser) anyerror!Expr {
        var elems = std.ArrayListUnmanaged(Expr){};

        while (true) {
            self.skipWhitespaceOnly();
            if (self.pos >= self.source.len) break;

            const c = self.source[self.pos];
            // Stop at: newline (unless continuation), '/', end of group ')', comment '#'
            if (c == '\n' or c == '/' or c == ')' or c == '#') break;
            // Also stop at EOF marker in grammar
            if (c == '<' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '-') break;

            const elem = try self.parsePostfixExpr() orelse break;
            try elems.append(self.allocator, elem);
        }

        if (elems.items.len == 0) return Expr{ .sequence = &.{} };
        if (elems.items.len == 1) return elems.items[0];
        return Expr{ .sequence = try elems.toOwnedSlice(self.allocator) };
    }

    /// Parse postfix: atom ('*' | '+' | '?')
    fn parsePostfixExpr(self: *GrammarParser) anyerror!?Expr {
        var inner = try self.parsePrefixExpr() orelse return null;

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '*') {
                self.pos += 1;
                const p = try self.allocator.create(Expr);
                p.* = inner;
                inner = Expr{ .repeat = p };
            } else if (c == '+') {
                self.pos += 1;
                const p = try self.allocator.create(Expr);
                p.* = inner;
                inner = Expr{ .repeat1 = p };
            } else if (c == '?') {
                self.pos += 1;
                const p = try self.allocator.create(Expr);
                p.* = inner;
                inner = Expr{ .optional = p };
            } else break;
        }

        return inner;
    }

    /// Parse prefix: '!' atom | '&' atom | atom
    fn parsePrefixExpr(self: *GrammarParser) anyerror!?Expr {
        if (self.pos >= self.source.len) return null;

        const c = self.source[self.pos];
        if (c == '!') {
            self.pos += 1;
            self.skipWhitespaceOnly();
            const inner = try self.parseAtom() orelse return null;
            const p = try self.allocator.create(Expr);
            p.* = inner;
            return Expr{ .not = p };
        }
        if (c == '&') {
            self.pos += 1;
            self.skipWhitespaceOnly();
            const inner = try self.parseAtom() orelse return null;
            const p = try self.allocator.create(Expr);
            p.* = inner;
            return Expr{ .ahead = p };
        }

        return try self.parseAtom();
    }

    /// Parse atom: 'literal' | TERMINAL | rule_ref | ( group )
    fn parseAtom(self: *GrammarParser) anyerror!?Expr {
        if (self.pos >= self.source.len) return null;

        const c = self.source[self.pos];

        // Quoted literal: 'func', '(', '+='
        if (c == '\'') {
            const text = self.readQuotedString();
            // Look up in literal map
            if (token_map.LITERAL_MAP.get(text)) |kind| {
                return Expr{ .token = kind };
            }
            // Not a known token literal — treat as contextual identifier match
            // (e.g., 'Error', 'Ptr', 'dep', 'cimport')
            return Expr{ .token_text = .{ .kind = .identifier, .text = text } };
        }

        // Parenthesized group
        if (c == '(') {
            self.pos += 1;
            self.skipWhitespaceAndNewlines();
            const inner = try self.parseChoiceExpr();
            self.skipWhitespaceAndNewlines();
            if (self.pos < self.source.len and self.source[self.pos] == ')') {
                self.pos += 1;
            }
            return inner;
        }

        // Identifier — could be TERMINAL, rule_ref, or contextual keyword
        if (isIdentStart(c)) {
            const ident = self.readIdent();

            // UPPER_CASE terminal: IDENTIFIER, INT_LITERAL, NL, EOF
            if (token_map.TERMINAL_MAP.get(ident)) |kind| {
                return Expr{ .token = kind };
            }

            // Character-class terminals defined in the grammar file's TERMINAL section
            // (IDENT_dep, IDENT_cimport, etc.) — skip, not real rules
            if (std.mem.startsWith(u8, ident, "IDENT_")) {
                return null;
            }

            // lowercase name = rule reference
            return Expr{ .rule_ref = ident };
        }

        // '[' character class — these are lexer-level definitions, skip
        if (c == '[') {
            self.skipToEndOfCharClass();
            return null;
        }

        return null;
    }

    // ── Low-level Helpers ───────────────────────────────────

    fn readIdent(self: *GrammarParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.source[start..self.pos];
    }

    fn readQuotedString(self: *GrammarParser) []const u8 {
        if (self.source[self.pos] != '\'') return "";
        self.pos += 1; // skip opening quote
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '\'') {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        if (self.pos < self.source.len) self.pos += 1; // skip closing quote
        return text;
    }

    fn matchStr(self: *GrammarParser, s: []const u8) bool {
        if (self.pos + s.len > self.source.len) return false;
        if (std.mem.eql(u8, self.source[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    fn skipWhitespaceOnly(self: *GrammarParser) void {
        while (self.pos < self.source.len and
            (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
        {
            self.pos += 1;
        }
        // Skip inline comments
        if (self.pos + 1 < self.source.len and
            self.source[self.pos] == '#')
        {
            self.skipLine();
        }
    }

    fn skipWhitespaceAndNewlines(self: *GrammarParser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                self.skipLine();
            } else break;
        }
    }

    fn skipBlankAndComments(self: *GrammarParser) void {
        self.skipWhitespaceAndNewlines();
    }

    fn skipLine(self: *GrammarParser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // skip newline
    }

    fn skipToEndOfCharClass(self: *GrammarParser) void {
        // Skip past the closing ']' and any following content on the line
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn isAtLineStart(self: *GrammarParser) bool {
        if (self.pos == 0) return true;
        // Check that the character before is a newline
        return self.source[self.pos - 1] == '\n';
    }
};

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// ============================================================
// TESTS
// ============================================================

test "grammar - parse simple rule" {
    const alloc = std.testing.allocator;
    const src = "foo\n    <- 'bar' baz\n";
    var grammar = try parseGrammar(src, alloc);
    defer grammar.deinit();

    try std.testing.expectEqual(@as(usize, 1), grammar.rule_names.len);
    try std.testing.expectEqualStrings("foo", grammar.rule_names[0]);

    const rule = grammar.getRule("foo") orelse return error.TestFailed;
    try std.testing.expect(rule == .sequence);
}

test "grammar - parse choice rule" {
    const alloc = std.testing.allocator;
    const src = "top\n    <- 'func'\n     / 'struct'\n";
    var grammar = try parseGrammar(src, alloc);
    defer grammar.deinit();

    const rule = grammar.getRule("top") orelse return error.TestFailed;
    try std.testing.expect(rule == .choice);
    try std.testing.expectEqual(@as(usize, 2), rule.choice.len);
}

test "grammar - parse repetition and optional" {
    const alloc = std.testing.allocator;
    const src = "list\n    <- item (',' item)* ','?\n";
    var grammar = try parseGrammar(src, alloc);
    defer grammar.deinit();

    const rule = grammar.getRule("list") orelse return error.TestFailed;
    try std.testing.expect(rule == .sequence);
}

test "grammar - parse negation" {
    const alloc = std.testing.allocator;
    const src = "ret\n    <- 'return' (!NL expr)? NL\n";
    var grammar = try parseGrammar(src, alloc);
    defer grammar.deinit();

    const rule = grammar.getRule("ret") orelse return error.TestFailed;
    try std.testing.expect(rule == .sequence);
}

test "grammar - parse full orhon grammar" {
    const alloc = std.testing.allocator;
    const peg_source = @embedFile("orhon.peg");
    var grammar = try parseGrammar(peg_source, alloc);
    defer grammar.deinit();

    // Verify key rules exist
    try std.testing.expect(grammar.getRule("program") != null);
    try std.testing.expect(grammar.getRule("module_decl") != null);
    try std.testing.expect(grammar.getRule("func_decl") != null);
    try std.testing.expect(grammar.getRule("struct_decl") != null);
    try std.testing.expect(grammar.getRule("enum_decl") != null);
    try std.testing.expect(grammar.getRule("expr") != null);
    try std.testing.expect(grammar.getRule("type") != null);
    try std.testing.expect(grammar.getRule("block") != null);
    try std.testing.expect(grammar.getRule("if_stmt") != null);
    try std.testing.expect(grammar.getRule("match_stmt") != null);
    try std.testing.expect(grammar.getRule("for_stmt") != null);
    try std.testing.expect(grammar.getRule("while_stmt") != null);
    try std.testing.expect(grammar.getRule("postfix_expr") != null);
    try std.testing.expect(grammar.getRule("primary_expr") != null);

    // Should have a substantial number of rules
    try std.testing.expect(grammar.rule_names.len >= 50);
}

test "grammar - token resolution in parsed rules" {
    const alloc = std.testing.allocator;
    const src = "stmt\n    <- 'return' expr NL\n";
    var grammar = try parseGrammar(src, alloc);
    defer grammar.deinit();

    const rule = grammar.getRule("stmt") orelse return error.TestFailed;
    try std.testing.expect(rule == .sequence);
    const seq = rule.sequence;
    try std.testing.expectEqual(@as(usize, 3), seq.len);

    // 'return' -> token(.kw_return)
    try std.testing.expect(seq[0] == .token);
    try std.testing.expectEqual(TokenKind.kw_return, seq[0].token);

    // expr -> rule_ref
    try std.testing.expect(seq[1] == .rule_ref);
    try std.testing.expectEqualStrings("expr", seq[1].rule_ref);

    // NL -> token(.newline)
    try std.testing.expect(seq[2] == .token);
    try std.testing.expectEqual(TokenKind.newline, seq[2].token);
}
