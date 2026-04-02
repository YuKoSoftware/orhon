// lexer.zig — Orhon tokenizer
// Follows std.zig.Tokenizer state machine pattern.
// Produces a flat list of tokens from source text.

const std = @import("std");

/// All token kinds in Orhon
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
    kw_elif,
    kw_for,
    kw_while,
    kw_return,
    kw_import,
    kw_use,
    kw_pub,
    kw_match,
    kw_struct,
    kw_blueprint,
    kw_enum,
    kw_bitfield,
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
    kw_as,
    kw_break,
    kw_continue,
    kw_true,
    kw_false,
    kw_is,
    kw_throw,
    kw_type,

    // Compound borrow tokens
    const_borrow,  // const&
    mut_borrow,    // mut&

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
    hash,       // #
    at_sign,    // @  (compiler function prefix)
    doc_comment, // /// documentation comment
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
    .{ "elif",     .kw_elif },
    .{ "for",      .kw_for },
    .{ "while",    .kw_while },
    .{ "return",   .kw_return },
    .{ "import",   .kw_import },
    .{ "use",      .kw_use },
    .{ "pub",      .kw_pub },
    .{ "match",    .kw_match },
    .{ "struct",    .kw_struct },
    .{ "blueprint", .kw_blueprint },
    .{ "enum",      .kw_enum },
    .{ "bitfield", .kw_bitfield },
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
    .{ "as",       .kw_as },
    .{ "break",    .kw_break },
    .{ "continue", .kw_continue },
    .{ "true",     .kw_true },
    .{ "false",    .kw_false },
    .{ "is",       .kw_is },
    .{ "throw",    .kw_throw },
    .{ "type",     .kw_type },
});

fn isBinaryDigit(ch: u8) bool {
    return ch == '0' or ch == '1';
}

fn isOctalDigit(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

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
                    if (self.peekAt(1) == '/' and self.peekAt(2) == '/' and self.peekAt(3) != '/') {
                        // Doc comment (///) — don't consume, let next() produce a token
                        break;
                    } else if (self.peekAt(1) == '/') {
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
                if (self.peek() == null) break; // EOF after backslash
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

        // Check for prefix (0x, 0b, 0o)
        if (self.peek() == '0') {
            const next_ch = self.peekAt(1);
            const digit_validator: ?*const fn (u8) bool = if (next_ch == 'x' or next_ch == 'X')
                &std.ascii.isHex
            else if (next_ch == 'b' or next_ch == 'B')
                &isBinaryDigit
            else if (next_ch == 'o' or next_ch == 'O')
                &isOctalDigit
            else
                null;

            if (digit_validator) |isValid| {
                _ = self.advance();
                _ = self.advance();
                const digit_start = self.pos;
                while (self.peek()) |ch| {
                    if (isValid(ch) or ch == '_') _ = self.advance() else break;
                }
                if (self.pos == digit_start)
                    return .{ .kind = .invalid, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
                if (self.peek()) |ch| {
                    if (std.ascii.isAlphanumeric(ch))
                        return .{ .kind = .invalid, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
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

        // Check for compound borrow tokens: const& and mut&
        // The & must immediately follow (no whitespace) to form the compound token.
        if (std.mem.eql(u8, text, "const") and self.peek() == '&') {
            _ = self.advance(); // consume &
            return .{ .kind = .const_borrow, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
        }
        if (std.mem.eql(u8, text, "mut") and self.peek() == '&') {
            _ = self.advance(); // consume &
            return .{ .kind = .mut_borrow, .text = self.source[start..self.pos], .line = start_line, .col = start_col };
        }

        // "mut" alone is not a keyword — return as identifier
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

        // Newline — significant in Orhon (statement terminator)
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

        // Doc comment (///) — extract content after the prefix
        if (ch == '/' and self.peekAt(1) == '/' and self.peekAt(2) == '/' and self.peekAt(3) != '/') {
            _ = self.advance(); // /
            _ = self.advance(); // /
            _ = self.advance(); // /
            // Skip one optional space after ///
            if (self.peek() == ' ') _ = self.advance();
            const text_start = self.pos;
            while (self.peek()) |c| {
                if (c == '\n') break;
                _ = self.advance();
            }
            return .{
                .kind = .doc_comment,
                .text = self.source[text_start..self.pos],
                .line = start_line,
                .col = start_col,
            };
        }

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
            '#' => .hash,
            '@' => .at_sign,
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

test "lexer - block comment line tracking" {
    // After a multiline block comment, tokens should have correct line numbers
    var lex = Lexer.init("func\n/* line2\nline3\nline4 */\nvar");
    const tok1 = lex.next(); // func on line 1
    _ = lex.next(); // newline after func
    // block comment is consumed by skipWhitespaceAndComments
    _ = lex.next(); // newline after block comment
    const tok2 = lex.next(); // var on line 5

    try std.testing.expectEqual(@as(usize, 1), tok1.line);
    try std.testing.expectEqual(@as(usize, 5), tok2.line);
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

test "fuzz lexer" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) !void {
            var lex = Lexer.init(input);
            var count: usize = 0;
            const limit = input.len +| 100; // saturating add
            while (count < limit) : (count += 1) {
                const tok = lex.next();
                if (tok.kind == .eof) return;
            }
            return error.TestUnexpectedResult;
        }
    }.run, .{});
}

test "lexer - stress random inputs" {
    // Generate pseudo-random inputs to stress test the lexer
    const alloc = std.testing.allocator;
    const seeds = [_][]const u8{
        // Edge cases: unterminated constructs
        "\"unterminated string",
        "/* unterminated block comment",
        "/* nested /* comment */",
        "///",
        // Invalid literals
        "0x", "0b", "0o", "0xZZ", "0b22", "0o99",
        "123_", "_123", "1__2",
        // Deep nesting
        "(((((((((((((((((((((((((((((((",
        "))))))))))))))))))))))))))))))))",
        "[[[[[[[[[[[",
        // All operators adjacent
        "+-*/%++==!=<><=>=&|^!>><<..",
        // Keywords mashed together
        "funcvarconstreturnifelsewhileformatchstructenumimportpub",
        // Mixed unicode and ASCII
        "\x00\x01\x02\xff\xfe\xfd",
        "\t\t\t\n\n\n\r\r\r   ",
        // Long repetitions
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "\"\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\"",
        // Real-ish code fragments
        "func f(x: i32, y: i32) i32 { return x + y }",
        "module test\nimport std::console\n\nfunc main() void {\n  console::println(\"hi\")\n}",
        "const x: (Error | i32) = Error(\"fail\")",
        "var list = List(i32)()\nlist.add(42)\nfor item in list { }",
        "struct Point { x: f64 y: f64 }\nconst p = Point { x: 1.0, y: 2.0 }",
        // Empty and minimal
        "",
        " ",
        "\n",
        "x",
        // Boundary characters
        ":::::::::::::::",
        "................",
        ",,,,,,,,,,,,,,,,",
    };

    for (seeds) |input| {
        var lex = Lexer.init(input);
        var tokens = try lex.tokenize(alloc);
        defer tokens.deinit(alloc);

        // Must always produce at least EOF
        try std.testing.expect(tokens.items.len > 0);
        try std.testing.expectEqual(TokenKind.eof, tokens.items[tokens.items.len - 1].kind);
    }
}

test "lexer - doc comment produces token" {
    var lex = Lexer.init("/// This is a doc comment\nfunc");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    var texts = std.ArrayListUnmanaged([]const u8){};
    defer texts.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
            try texts.append(alloc, t.text);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), kinds.items.len);
    try std.testing.expectEqual(TokenKind.doc_comment, kinds.items[0]);
    try std.testing.expectEqualStrings("This is a doc comment", texts.items[0]);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[1]);
}

test "lexer - multiple doc comment lines" {
    var lex = Lexer.init("/// Line one\n/// Line two\nfunc");
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
    try std.testing.expectEqual(@as(usize, 3), kinds.items.len);
    try std.testing.expectEqual(TokenKind.doc_comment, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.doc_comment, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[2]);
}

test "lexer - four slashes is regular comment not doc" {
    var lex = Lexer.init("//// not a doc comment\nfunc");
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
    // //// is a regular comment, so only func remains
    try std.testing.expectEqual(@as(usize, 1), kinds.items.len);
    try std.testing.expectEqual(TokenKind.kw_func, kinds.items[0]);
}

test "lexer - doc comment without space after slashes" {
    var lex = Lexer.init("///no space\nfunc");
    const alloc = std.testing.allocator;
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var kinds = std.ArrayListUnmanaged(TokenKind){};
    defer kinds.deinit(alloc);
    var texts = std.ArrayListUnmanaged([]const u8){};
    defer texts.deinit(alloc);
    for (tokens.items) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(alloc, t.kind);
            try texts.append(alloc, t.text);
        }
    }
    try std.testing.expectEqual(TokenKind.doc_comment, kinds.items[0]);
    try std.testing.expectEqualStrings("no space", texts.items[0]);
}

test "lexer - const& compound borrow token" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("const&x");
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
    try std.testing.expectEqual(TokenKind.const_borrow, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[1]);
}

test "lexer - mut& compound borrow token" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("mut&x");
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
    try std.testing.expectEqual(TokenKind.mut_borrow, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[1]);
}

test "lexer - const with space & is not compound" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("const &x");
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
    try std.testing.expectEqual(TokenKind.kw_const, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.ampersand, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[2]);
}

test "lexer - bare & is bitwise AND" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("a & b");
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
    try std.testing.expectEqual(TokenKind.ampersand, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[2]);
}
