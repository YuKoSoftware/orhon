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
    string_interp_start, // opening " of an interp string (signals start to the PEG grammar)
    string_part,         // literal segment of an interp string; text = raw chars, slice into source
    string_interp_end,   // closing " of an interp string; text = slice of the closing quote

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
    kw_handle,
    kw_defer,
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
    .{ "handle",    .kw_handle },
    .{ "defer",    .kw_defer },
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
    .{ "type",     .kw_type },
});

fn isBinaryDigit(ch: u8) bool {
    return ch == '0' or ch == '1';
}

fn isOctalDigit(ch: u8) bool {
    return ch >= '0' and ch <= '7';
}

const LexerMode = union(enum) {
    normal:        void,
    string_body:   void,
    string_interp: struct { depth: u32 },
};

/// The lexer state machine
pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    mode: LexerMode = .normal,

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
    /// Lex a single token from the current position (whitespace already skipped).
    fn lexToken(self: *Lexer) Token {
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

    /// Get the next token
    pub fn next(self: *Lexer) Token {
        switch (self.mode) {
            .string_body => return self.lexStringBody(),
            .string_interp => |interp| return self.nextInInterp(interp.depth),
            .normal => {
                self.skipWhitespaceAndComments();
                // Intercept interpolated strings before they reach lexToken()
                if (self.peek() == '"' and self.containsInterpolation()) {
                    const start_line = self.line;
                    const start_col  = self.col;
                    _ = self.advance(); // consume opening "
                    self.mode = .string_body;
                    // Emit string_interp_start so the PEG grammar can cheaply identify
                    // the start of an interpolated string without lookahead.
                    return .{
                        .kind = .string_interp_start,
                        .text = "\"",
                        .line = start_line,
                        .col  = start_col,
                    };
                }
                return self.lexToken();
            },
        }
    }

    /// In .string_interp mode: lex one expression token, track brace depth.
    /// Discards newlines (not significant inside @{}).
    /// When the matching } is found (depth reaches 1 — the closing @{): switches to .string_body and returns
    /// the next string_part or string_interp_end immediately.
    fn nextInInterp(self: *Lexer, depth: u32) Token {
        while (true) {
            self.skipWhitespaceAndComments();

            // EOF before closing } — error recovery
            if (self.peek() == null) {
                self.mode = .normal;
                return .{
                    .kind = .string_interp_end,
                    .text = self.source[self.pos..self.pos],
                    .line = self.line,
                    .col  = self.col,
                };
            }

            // Discard newlines inside @{...}
            if (self.peek() == '\n') {
                _ = self.advance();
                continue;
            }

            // A literal " inside @{...} means the string ended without closing } — error recovery.
            if (self.peek() == '"') {
                self.mode = .normal;
                return .{
                    .kind = .string_interp_end,
                    .text = self.source[self.pos..self.pos],
                    .line = self.line,
                    .col  = self.col,
                };
            }

            const tok = self.lexToken();

            switch (tok.kind) {
                .lbrace => {
                    self.mode = .{ .string_interp = .{ .depth = depth + 1 } };
                    return tok;
                },
                .rbrace => {
                    if (depth > 1) {
                        self.mode = .{ .string_interp = .{ .depth = depth - 1 } };
                        return tok;
                    }
                    // Depth hits 0 — @{...} is closed. Resume string body.
                    self.mode = .string_body;
                    return self.lexStringBody();
                },
                .eof => {
                    self.mode = .normal;
                    return .{
                        .kind = .string_interp_end,
                        .text = self.source[self.pos..self.pos],
                        .line = self.line,
                        .col  = self.col,
                    };
                },
                else => {
                    // Expression token — mode stays .string_interp{depth} (unchanged in self.mode)
                    return tok;
                },
            }
        }
    }

    /// Scan literal characters in .string_body mode. Emits:
    ///   - string_part  for any accumulated literal text (raw source slice, no quotes)
    ///   - string_interp_end  when the closing " is reached (or on unterminated string)
    /// When @{ is found: emits string_part (if non-empty), advances past @{, switches to
    /// .string_interp{depth:1}, and falls through to nextInInterp for the first expr token.
    fn lexStringBody(self: *Lexer) Token {
        const start_line = self.line;
        const start_col  = self.col;
        const part_start = self.pos;

        while (self.peek()) |ch| {
            switch (ch) {
                '@' => {
                    if (self.peekAt(1) == '{') {
                        const part_end = self.pos;
                        _ = self.advance(); // @
                        _ = self.advance(); // {
                        self.mode = .{ .string_interp = .{ .depth = 1 } };
                        if (part_end > part_start) {
                            return .{
                                .kind = .string_part,
                                .text = self.source[part_start..part_end],
                                .line = start_line,
                                .col  = start_col,
                            };
                        }
                        // No preceding text — lex the first expression token immediately
                        return self.nextInInterp(1);
                    }
                    _ = self.advance();
                },
                '"' => {
                    const part_end = self.pos;
                    if (part_end > part_start) {
                        // Trailing literal text exists. Emit string_part WITHOUT consuming ".
                        // Next call: peek()=='"', part_start==part_end, falls to else branch.
                        return .{
                            .kind = .string_part,
                            .text = self.source[part_start..part_end],
                            .line = start_line,
                            .col  = start_col,
                        };
                    }
                    // No trailing text — emit string_interp_end and close.
                    _ = self.advance(); // consume "
                    self.mode = .normal;
                    return .{
                        .kind = .string_interp_end,
                        .text = self.source[self.pos - 1..self.pos],
                        .line = start_line,
                        .col  = start_col,
                    };
                },
                '\n' => {
                    // Unterminated interpolated string — error recovery.
                    self.mode = .normal;
                    return .{
                        .kind = .string_interp_end,
                        .text = self.source[self.pos..self.pos],
                        .line = start_line,
                        .col  = start_col,
                    };
                },
                '\\' => {
                    _ = self.advance(); // backslash
                    if (self.peek() != null) _ = self.advance(); // escaped char
                },
                else => _ = self.advance(),
            }
        }
        // EOF inside string body
        self.mode = .normal;
        return .{
            .kind = .string_interp_end,
            .text = self.source[self.pos..self.pos],
            .line = start_line,
            .col  = start_col,
        };
    }

    /// Pure peek: returns true if the string starting at pos (the opening ") contains @{.
    /// Does not advance pos.
    fn containsInterpolation(self: *Lexer) bool {
        var i = self.pos + 1; // skip the opening "
        while (i < self.source.len) : (i += 1) {
            switch (self.source[i]) {
                '"'  => return false,
                '\n' => return false,
                '\\' => i += 1, // skip escaped character
                '@'  => if (i + 1 < self.source.len and self.source[i + 1] == '{') return true,
                else => {},
            }
        }
        return false;
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

test "lexer - invalid prefix literals produce .invalid" {
    const cases = [_][]const u8{ "0x", "0b", "0o", "0xZZ", "0b22", "0o99" };
    for (cases) |input| {
        var lex = Lexer.init(input);
        const tok = lex.next();
        try std.testing.expectEqual(TokenKind.invalid, tok.kind);
    }
}

test "lexer - unterminated string at newline" {
    var lex = Lexer.init("\"hello\nworld");
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.string_literal, tok.kind);
    try std.testing.expectEqualStrings("\"hello", tok.text);
}

test "lexer - unterminated string at EOF" {
    var lex = Lexer.init("\"hello");
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.string_literal, tok.kind);
    try std.testing.expectEqualStrings("\"hello", tok.text);
}

test "lexer - EOF inside escape sequence" {
    var lex = Lexer.init("\"\\");
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.string_literal, tok.kind);
    const tok2 = lex.next();
    try std.testing.expectEqual(TokenKind.eof, tok2.kind);
}

test "lexer - mut alone is identifier not keyword" {
    var lex = Lexer.init("mut x");
    const tok = lex.next();
    try std.testing.expectEqual(TokenKind.identifier, tok.kind);
    try std.testing.expectEqualStrings("mut", tok.text);
}

test "lexer - column tracking" {
    var lex = Lexer.init("  func var");
    const tok1 = lex.next(); // func at col 3
    const tok2 = lex.next(); // var at col 8
    try std.testing.expectEqual(@as(usize, 3), tok1.col);
    try std.testing.expectEqual(@as(usize, 8), tok2.col);
}

test "lexer - number before dotdot stays int" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("1..5");
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
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.dotdot, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[2]);
}

test "lexer - number before dot non-digit stays int" {
    const alloc = std.testing.allocator;
    var lex = Lexer.init("42.x");
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
    try std.testing.expectEqual(TokenKind.int_literal, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.dot, kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier, kinds.items[2]);
}

test "lexer - @ produces at_sign" {
    var lex = Lexer.init("@cast");
    const tok1 = lex.next();
    const tok2 = lex.next();
    try std.testing.expectEqual(TokenKind.at_sign, tok1.kind);
    try std.testing.expectEqual(TokenKind.identifier, tok2.kind);
}

test "lexer - # produces hash" {
    var lex = Lexer.init("#build");
    const tok1 = lex.next();
    const tok2 = lex.next();
    try std.testing.expectEqual(TokenKind.hash, tok1.kind);
    try std.testing.expectEqual(TokenKind.identifier, tok2.kind);
}

test "lexer - %= is two tokens" {
    var lex = Lexer.init("%=");
    const tok1 = lex.next();
    const tok2 = lex.next();
    try std.testing.expectEqual(TokenKind.percent, tok1.kind);
    try std.testing.expectEqual(TokenKind.assign, tok2.kind);
}

/// Helper: collect non-newline, non-eof token kinds into a list.
fn collectKinds(tokens: []const Token, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(TokenKind) {
    var kinds = std.ArrayListUnmanaged(TokenKind){};
    for (tokens) |t| {
        if (t.kind != .newline and t.kind != .eof) {
            try kinds.append(allocator, t.kind);
        }
    }
    return kinds;
}

test "interp - fast path unchanged" {
    // A plain string with no @{ must still produce a single string_literal token.
    var lex = Lexer.init("\"hello\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_literal, kinds.items[0]);
}

test "interp - single interpolation" {
    var lex = Lexer.init("\"hello @{x} world\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, string_part("hello "), identifier("x"), string_part(" world"), string_interp_end
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.string_part,         kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[2]);
    try std.testing.expectEqual(TokenKind.string_part,         kinds.items[3]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[4]);
}

test "interp - no leading text" {
    var lex = Lexer.init("\"@{x}\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, identifier("x"), string_interp_end
    try std.testing.expectEqual(@as(usize, 3), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[1]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[2]);
}

test "interp - no trailing text" {
    var lex = Lexer.init("\"hello @{x}\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, string_part("hello "), identifier("x"), string_interp_end
    try std.testing.expectEqual(@as(usize, 4), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.string_part,         kinds.items[1]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[2]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[3]);
}

test "interp - multiple interpolations" {
    var lex = Lexer.init("\"@{x} @{y}\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, identifier("x"), string_part(" "), identifier("y"), string_interp_end
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[1]);
    try std.testing.expectEqual(TokenKind.string_part,         kinds.items[2]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[3]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[4]);
}

test "interp - expression with operators" {
    var lex = Lexer.init("\"@{a + 1}\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, identifier("a"), plus, int_literal("1"), string_interp_end
    try std.testing.expectEqual(@as(usize, 5), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[1]);
    try std.testing.expectEqual(TokenKind.plus,                kinds.items[2]);
    try std.testing.expectEqual(TokenKind.int_literal,         kinds.items[3]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[4]);
}

test "interp - nested braces in expression" {
    // @{foo({})} — the inner {} must not close the @{ early
    var lex = Lexer.init("\"@{foo({})}\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // string_interp_start, identifier, lparen, lbrace, rbrace, rparen, string_interp_end
    try std.testing.expectEqual(@as(usize, 7), kinds.items.len);
    try std.testing.expectEqual(TokenKind.string_interp_start, kinds.items[0]);
    try std.testing.expectEqual(TokenKind.identifier,          kinds.items[1]);
    try std.testing.expectEqual(TokenKind.lparen,              kinds.items[2]);
    try std.testing.expectEqual(TokenKind.lbrace,              kinds.items[3]);
    try std.testing.expectEqual(TokenKind.rbrace,              kinds.items[4]);
    try std.testing.expectEqual(TokenKind.rparen,              kinds.items[5]);
    try std.testing.expectEqual(TokenKind.string_interp_end,   kinds.items[6]);
}

test "interp - unclosed @{ error recovery" {
    // An unclosed @{ must produce string_interp_end (no hang/panic).
    // After error recovery, the unconsumed " is lexed as a string_literal in .normal mode.
    var lex = Lexer.init("\"@{x\"");
    var tokens = try lex.tokenize(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);
    var kinds = try collectKinds(tokens.items, std.testing.allocator);
    defer kinds.deinit(std.testing.allocator);
    // Must contain string_interp_end; exact prefix may vary
    try std.testing.expect(kinds.items.len >= 1);
    // Check that string_interp_end appears in the stream (error recovery was triggered)
    var found_interp_end = false;
    for (kinds.items) |kind| {
        if (kind == .string_interp_end) {
            found_interp_end = true;
            break;
        }
    }
    try std.testing.expect(found_interp_end);
}
