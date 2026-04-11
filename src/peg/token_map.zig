// token_map.zig — Maps PEG grammar literals to lexer TokenKind values
//
// The PEG grammar uses string literals ('func', '(', '+=') and
// terminal names (IDENTIFIER, INT_LITERAL, NL) to reference tokens.
// This module resolves both to TokenKind values at grammar-parse time.

const std = @import("std");
const lexer = @import("../lexer.zig");
const TokenKind = lexer.TokenKind;

/// Map single-quoted literals from the PEG grammar to token kinds.
/// Covers all keywords, punctuation, and operators.
pub const LITERAL_MAP = std.StaticStringMap(TokenKind).initComptime(.{
    // Keywords
    .{ "func", .kw_func },
    .{ "var", .kw_var },
    .{ "const", .kw_const },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "elif", .kw_elif },
    .{ "for", .kw_for },
    .{ "while", .kw_while },
    .{ "return", .kw_return },
    .{ "import", .kw_import },
    .{ "use", .kw_use },
    .{ "pub", .kw_pub },
    .{ "match", .kw_match },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "handle", .kw_handle },
    .{ "defer", .kw_defer },
    .{ "null", .kw_null },
    .{ "void", .kw_void },
    .{ "compt", .kw_compt },
    .{ "any", .kw_any },
    .{ "module", .kw_module },
    .{ "test", .kw_test },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "as", .kw_as },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "blueprint", .kw_blueprint },
    .{ "is", .kw_is },
    .{ "type", .kw_type },
    .{ "@", .at_sign },

    // Compound borrow tokens
    .{ "const&", .const_borrow },
    .{ "mut&", .mut_borrow },

    // Punctuation
    .{ "(", .lparen },
    .{ ")", .rparen },
    .{ "{", .lbrace },
    .{ "}", .rbrace },
    .{ "[", .lbracket },
    .{ "]", .rbracket },
    .{ ",", .comma },
    .{ ":", .colon },
    .{ "::", .scope },
    .{ ";", .semicolon },
    .{ ".", .dot },
    .{ "..", .dotdot },
    .{ "=>", .arrow },
    .{ "|", .pipe },
    .{ "&", .ampersand },
    .{ "#", .hash },

    // Operators
    .{ "+", .plus },
    .{ "++", .plus_plus },
    .{ "-", .minus },
    .{ "*", .star },
    .{ "/", .slash },
    .{ "%", .percent },
    .{ "!", .bang },
    .{ "^", .caret },
    .{ "<<", .lshift },
    .{ ">>", .rshift },
    .{ "==", .eq },
    .{ "!=", .neq },
    .{ "<", .lt },
    .{ ">", .gt },
    .{ "<=", .lte },
    .{ ">=", .gte },
    .{ "=", .assign },
    .{ "+=", .plus_assign },
    .{ "-=", .minus_assign },
    .{ "*=", .star_assign },
    .{ "/=", .slash_assign },
});

/// Map UPPER_CASE terminal names from the PEG grammar to token kinds.
pub const TERMINAL_MAP = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "IDENTIFIER", .identifier },
    .{ "INT_LITERAL", .int_literal },
    .{ "FLOAT_LITERAL", .float_literal },
    .{ "STRING_LITERAL", .string_literal },
    .{ "DOC_COMMENT", .doc_comment },
    .{ "NL", .newline },
    .{ "EOF", .eof },
});

// ============================================================
// TESTS
// ============================================================

test "token_map - keywords resolve correctly" {
    try std.testing.expectEqual(TokenKind.kw_func, LITERAL_MAP.get("func").?);
    try std.testing.expectEqual(TokenKind.kw_struct, LITERAL_MAP.get("struct").?);
    try std.testing.expectEqual(TokenKind.kw_return, LITERAL_MAP.get("return").?);
    try std.testing.expectEqual(TokenKind.kw_elif, LITERAL_MAP.get("elif").?);
    try std.testing.expectEqual(TokenKind.kw_type, LITERAL_MAP.get("type").?);
}

test "token_map - punctuation resolves correctly" {
    try std.testing.expectEqual(TokenKind.lparen, LITERAL_MAP.get("(").?);
    try std.testing.expectEqual(TokenKind.dotdot, LITERAL_MAP.get("..").?);
    try std.testing.expectEqual(TokenKind.arrow, LITERAL_MAP.get("=>").?);
    try std.testing.expectEqual(TokenKind.scope, LITERAL_MAP.get("::").?);
}

test "token_map - operators resolve correctly" {
    try std.testing.expectEqual(TokenKind.plus_plus, LITERAL_MAP.get("++").?);
    try std.testing.expectEqual(TokenKind.lshift, LITERAL_MAP.get("<<").?);
    try std.testing.expectEqual(TokenKind.plus_assign, LITERAL_MAP.get("+=").?);
    try std.testing.expectEqual(TokenKind.neq, LITERAL_MAP.get("!=").?);
}

test "token_map - terminals resolve correctly" {
    try std.testing.expectEqual(TokenKind.identifier, TERMINAL_MAP.get("IDENTIFIER").?);
    try std.testing.expectEqual(TokenKind.int_literal, TERMINAL_MAP.get("INT_LITERAL").?);
    try std.testing.expectEqual(TokenKind.newline, TERMINAL_MAP.get("NL").?);
    try std.testing.expectEqual(TokenKind.eof, TERMINAL_MAP.get("EOF").?);
}

test "token_map - unknown names return null" {
    try std.testing.expect(LITERAL_MAP.get("expr") == null);
    try std.testing.expect(TERMINAL_MAP.get("func_decl") == null);
    try std.testing.expect(LITERAL_MAP.get("block") == null);
}
