// lexer.zig — Kodr tokenizer
// Follows std.zig.Tokenizer state machine pattern.
// Produces a flat list of tokens from source text.

const std = @import("std");

/// All token kinds in Kodr
pub const TokenKind = enum {
    // Literals
    int_literal,
    float_literal,
    string_literal,

    // Identifiers and keywords
    identifier,

    // Keywords
    kw_func,
    kw_var,
    kw_const,
    kw_if,
    kw_else,
    kw_for,
    kw_while,
    kw_return,
    kw_import,
    kw_pub,
    kw_match,
    kw_struct,
    kw_enum,
    kw_defer,
    kw_thread,
    kw_null,
    kw_void,
    kw_compt,
    kw_any,
    kw_module,
    kw_test,
    kw_and,
    kw_or,
    kw_not,
    kw_main,
    kw_as,
    kw_type,
    kw_label,
    kw_break,
    kw_continue,
    kw_true,
    kw_false,
    kw_extern,
    kw_is,

    // Punctuation
    lparen,     // (
    rparen,     // )
    lbrace,     // {
    rbrace,     // }
    lbracket,   // [
    rbracket,   // ]
    comma,      // ,
    colon,      // :
    scope,      // ::
    semicolon,  // ;
    dot,        // .
    dotdot,     // ..
    arrow,      // =>
    pipe,       // |
    ampersand,  // &
    at,         // @

    // Operators
    plus,       // +
    plus_plus,  // ++
    minus,      // -
    star,       // *
    slash,      // /
    percent,    // %
    bang,       // !
    caret,      // ^
    lshift,     // <<
    rshift,     // >>
    eq,         // ==
    neq,        // !=
    lt,         // <
    gt,         // >
    lte,        // <=
    gte,        // >=
    assign,     // =
    plus_assign, // +=
    minus_assign,// -=
    star_assign, // *=
    slash_assign,// /=

    // Special
    newline,
    eof,
    invalid,
};

/// A single token with its kind, source text, and location
pub const Token = struct {
    kind: TokenKind,
    text: []const u8, // slice into original source
    line: usize,
    col: usize,
};

/// Keyword lookup table
const KEYWORDS = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "func",     .kw_func },
    .{ "var",      .kw_var },
    .{ "const",    .kw_const },
    .{ "if",       .kw_if },
    .{ "else",     .kw_else },
    .{ "for",      .kw_for },
    .{ "while",    .kw_while },
    .{ "return",   .kw_return },
    .{ "import",   .kw_import },
    .{ "pub",      .kw_pub },
    .{ "match",    .kw_match },
    .{ "struct",   .kw_struct },
    .{ "enum",     .kw_enum },
    .{ "defer",    .kw_defer },
    .{ "thread",   .kw_thread },
    .{ "null",     .kw_null },
    .{ "void",     .kw_void },
    .{ "compt",    .kw_compt },
    .{ "any",      .kw_any },
    .{ "module",   .kw_module },
    .{ "test",     .kw_test },
    .{ "and",      .kw_and },
    .{ "or",       .kw_or },
    .{ "not",      .kw_not },
    .{ "main",     .kw_main },
    .{ "as",       .kw_as },
    .{ "type",     .kw_type },
    .{ "label",    .kw_label },
    .{ "break",    .kw_break },
    .{ "continue", .kw_continue },
    .{ "true",     .kw_true },
    .{ "false",    .kw_false },
    .{ "extern",   .kw_extern },
    .{ "is",       .kw_is },
});

/// The lexer state machine
pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    fn peek(self: *Lexer) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn peekAt(self: *Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.source.len) return null;
        return self.source[idx];
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return ch;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\r' => _ = self.advance(),
                '/' => {
                    if (self.peekAt(1) == '/') {
                        // Line comment — consume until newline
                        while (self.peek()) |c| {
                            if (c == '\n') break;
                            _ = self.advance();
                        }
                    } else if (self.peekAt(1) == '*') {
                        // Block comment — consume until */
                        _ = self.advance(); // consume /
                        _ = self.advance(); // consume *
                        while (self.peek()) |c| {
                            if (c == '*' and self.peekAt(1) == '/') {
                                _ = self.advance(); // consume *
                                _ = self.advance(); // consume /
                                break;
                            }
                            if (c == '\n') {
                                self.line += 1;
                                self.col = 0;
                            }
                            _ = self.advance();
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn lexString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        _ = self.advance(); // consume opening "

        while (self.peek()) |ch| {
            if (ch == '\\') {
                _ = self.advance(); // consume backslash
                _ = self.advance(); // consume escape char
            } else if (ch == '"') {
                _ = self.advance(); // consume closing "
                break;
            } else if (ch == '\n') {
                // Unterminated string
                break;
            } else {
                _ = self.advance();
            }
        }

        return .{
            .kind = .string_literal,
            .text = self.source[start..self.pos],
            .line = start_line,
            .col = start_col,
        };
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        var kind: TokenKind = .int_literal;

        // Check for prefix
        if (self.peek() == '0') {
            const next_ch = self.peekAt(1);
            if (next_ch == 'x' or next_ch == 'X') {
                _ = self.advance(); _ = self.advance();
                while (self.peek()) |ch| {
                    if (std.ascii.isHex(ch) or ch == '_') _ = self.advance()
                    else break;
                }
                return .{ .kind = .int_literal, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
            } else if (next_ch == 'b' or next_ch == 'B') {
                _ = self.advance(); _ = self.advance();
                while (self.peek()) |ch| {
                    if (ch == '0' or ch == '1' or ch == '_') _ = self.advance()
                    else break;
                }
                return .{ .kind = .int_literal, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
            } else if (next_ch == 'o' or next_ch == 'O') {
                _ = self.advance(); _ = self.advance();
                while (self.peek()) |ch| {
                    if ((ch >= '0' and ch <= '7') or ch == '_') _ = self.advance()
                    else break;
                }
                return .{ .kind = .int_literal, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
            }
        }

        // Decimal integer or float
        while (self.peek()) |ch| {
            if (std.ascii.isDigit(ch) or ch == '_') _ = self.advance()
            else break;
        }

        // Check for float
        if (self.peek() == '.' and self.peekAt(1) != '.') {
            if (self.peekAt(1)) |next_ch| {
                if (std.ascii.isDigit(next_ch)) {
                    kind = .float_literal;
                    _ = self.advance(); // consume .
                    while (self.peek()) |ch| {
                        if (std.ascii.isDigit(ch) or ch == '_') _ = self.advance()
                        else break;
                    }
                }
            }
        }

        return .{ .kind = kind, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
    }

    fn lexIdentOrKeyword(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const start_col = self.col;

        while (self.peek()) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') _ = self.advance()
            else break;
        }

        const text = self.source[start..self.pos];
        const kind = KEYWORDS.get(text) orelse .identifier;

        return .{ .kind = kind, .text = text, .line = start_line, .col = start_col };
    }

    /// Get the next token
    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        const start_line = self.line;
        const start_col = self.col;

        const ch = self.peek() orelse {
            return .{ .kind = .eof, .text = "", .line = start_line, .col = start_col };
        };

        // Newline — significant in Kodr (statement terminator)
        if (ch == '\n') {
            const start = self.pos;
            _ = self.advance();
            return .{ .kind = .newline, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
        }

        // String literal
        if (ch == '"') return self.lexString();

        // Number literal
        if (std.ascii.isDigit(ch)) return self.lexNumber();

        // Identifier or keyword
        if (std.ascii.isAlphabetic(ch) or ch == '_') return self.lexIdentOrKeyword();

        // Single/double character operators and punctuation
        const start = self.pos;
        _ = self.advance();

        const kind: TokenKind = switch (ch) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ',' => .comma,
            ':' => blk: {
                if (self.peek() == ':') { _ = self.advance(); break :blk .scope; }
                break :blk .colon;
            },
            ';' => .semicolon,
            '@' => .at,
            '^' => .caret,
            '%' => .percent,
            '*' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .star_assign; }
                break :blk .star;
            },
            '+' => blk: {
                if (self.peek() == '+') { _ = self.advance(); break :blk .plus_plus; }
                if (self.peek() == '=') { _ = self.advance(); break :blk .plus_assign; }
                break :blk .plus;
            },
            '-' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .minus_assign; }
                break :blk .minus;
            },
            '/' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .slash_assign; }
                break :blk .slash;
            },
            '!' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .neq; }
                break :blk .bang;
            },
            '=' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .eq; }
                if (self.peek() == '>') { _ = self.advance(); break :blk .arrow; }
                break :blk .assign;
            },
            '<' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .lte; }
                if (self.peek() == '<') { _ = self.advance(); break :blk .lshift; }
                break :blk .lt;
            },
            '>' => blk: {
                if (self.peek() == '=') { _ = self.advance(); break :blk .gte; }
                if (self.peek() == '>') { _ = self.advance(); break :blk .rshift; }
                break :blk .gt;
            },
            '.' => blk: {
                if (self.peek() == '.') { _ = self.advance(); break :blk .dotdot; }
                break :blk .dot;
            },
            '|' => .pipe,
            '&' => .ampersand,
            else => .invalid,
        };

        return .{ .kind = kind, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
    }

    /// Tokenize all source into a flat list
    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(Token) {
        var tokens: std.ArrayListUnmanaged(Token) = .{};
        while (true) {
            const tok = self.next();
            try tokens.append(allocator, tok);
            if (tok.kind == .eof) break;
        }
        return tokens;
    }
};

test "lexer - keywords" {
    var lex = Lexer.init("func var const if else");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    // Filter out newlines and eof
    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.kw_var, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.kw_const, kinds.items[2]);
    try std.testing.expectEqual(TokenKind.kw_if, kinds.items[3]);
    try std.testing.expectEqual(TokenKind.kw_else, kinds.items[4]);
}

test "lexer - integer literals" {
    var lex = Lexer.init("42 0xFF 0b1010 0o777 1_000_000");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[2]);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[3]);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[4]);
}

test "lexer - float literals" {
    var lex = Lexer.init("3.14 1_000.5");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.float_literal, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.float_literal, kinds.items[1]);
}

test "lexer - string literal with escape" {
    var lex = Lexer.init("\"hello\\nworld\"");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    try std.testing.expectEqual(TokenKind.string_literal, tokens.items[0].kind);
}

test "lexer - operators" {
    var lex = Lexer.init("== != <= >= << >> => ..");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(TokenKind.eq, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.neq, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.lte, kinds.items[2]);
    try std.testing.expectEqual(TokenKind.gte, kinds.items[3]);
    try std.testing.expectEqual(TokenKind.lshift, kinds.items[4]);
    try std.testing.expectEqual(TokenKind.rshift, kinds.items[5]);
    try std.testing.expectEqual(TokenKind.arrow, kinds.items[6]);
    try std.testing.expectEqual(TokenKind.dotdot, kinds.items[7]);
}

test "lexer - concatenation operator" {
    var lex = Lexer.init("a ++ b + c");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    // a ++ b + c → identifier, plus_plus, identifier, plus, identifier
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.plus_plus, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[2]);
    try std.testing.expectEqual(TokenKind.plus, kinds.items[3]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[4]);
}

test "lexer - comment skipping" {
    var lex = Lexer.init("func // this is a comment\nvar");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.kw_var, kinds.items[1]);
}

test "lexer - block comment skipping" {
    var lex = Lexer.init("func /* this is a block comment */ var");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.kw_var, kinds.items[1]);
}

test "lexer - multiline block comment" {
    var lex = Lexer.init("func\n/* comment\nspanning\nlines */\nvar");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.kw_var, kinds.items[1]);
}

test "lexer - line tracking" {
    var lex = Lexer.init("func\nvar\nconst");
    const tok1 = lex.next();
    _ = lex.next(); // newline
    const tok2 = lex.next();
    _ = lex.next(); // newline
    const tok3 = lex.next();

    try std.testing.expectEqual(@as(usize, 1), tok1.line);
    try std.testing.expectEqual(@as(usize, 2), tok2.line);
    try std.testing.expectEqual(@as(usize, 3), tok3.line);
}

test "lexer - scope operator ::" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("std::console");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), kinds.items.len);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.scope,      kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[2]);
}

test "lexer - extern keyword" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("extern func");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_extern, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.kw_func,   kinds.items[1]);
}

test "lexer - colon not consumed as scope" {
    // single : should remain .colon, not .scope
    const alloc = std.testing.allocator;
    var lex = Lexer.init("x: i32");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
        }
    }
    try std.testing.expectEqual(TokenKind.colon, kinds.items[1]);
}
