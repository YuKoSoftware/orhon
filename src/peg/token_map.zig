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
    .{ "bitfield", .kw_bitfield },
    .{ "defer", .kw_defer },
    .{ "thread", .kw_thread },
    .{ "null", .kw_null },
    .{ "void", .kw_void },
    .{ "compt", .kw_compt },
    .{ "any", .kw_any },
    .{ "module", .kw_module },
    .{ "test", .kw_test },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "not", .kw_not },
    .{ "main", .kw_main },
    .{ "as", .kw_as },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "bridge", .kw_bridge },
    .{ "blueprint", .kw_blueprint },
    .{ "is", .kw_is },
    .{ "throw", .kw_throw },
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

/// Resolve a PEG grammar atom to a token kind.
/// Returns null for lowercase rule references (those are rule names, not tokens).
pub fn resolve(name: []const u8) ?TokenKind {
    // Single-quoted literal (quotes already stripped by grammar parser)
    if (LITERAL_MAP.get(name)) |kind| return kind;
    // UPPER_CASE terminal
    if (TERMINAL_MAP.get(name)) |kind| return kind;
    return null;
}

/// Check if a name is a known contextual identifier (like 'dep', 'cimport', 'Error',
/// 'Ptr', 'List', etc.). These are parsed as IDENTIFIER tokens but matched by text.
/// The PEG engine matches these by checking both token kind (.identifier) and text.
pub fn isContextualIdentifier(name: []const u8) bool {
    return LITERAL_MAP.get(name) == null and
        TERMINAL_MAP.get(name) == null and
        name.len > 0 and std.ascii.isUpper(name[0]) == false;
}

// ============================================================
// TESTS
// ============================================================

test "token_map - keywords resolve correctly" {
    try std.testing.expectEqual(TokenKind.kw_func, resolve("func").?);
    try std.testing.expectEqual(TokenKind.kw_struct, resolve("struct").?);
    try std.testing.expectEqual(TokenKind.kw_return, resolve("return").?);
    try std.testing.expectEqual(TokenKind.kw_elif, resolve("elif").?);
    try std.testing.expectEqual(TokenKind.kw_type, resolve("type").?);
}

test "token_map - punctuation resolves correctly" {
    try std.testing.expectEqual(TokenKind.lparen, resolve("(").?);
    try std.testing.expectEqual(TokenKind.dotdot, resolve("..").?);
    try std.testing.expectEqual(TokenKind.arrow, resolve("=>").?);
    try std.testing.expectEqual(TokenKind.scope, resolve("::").?);
}

test "token_map - operators resolve correctly" {
    try std.testing.expectEqual(TokenKind.plus_plus, resolve("++").?);
    try std.testing.expectEqual(TokenKind.lshift, resolve("<<").?);
    try std.testing.expectEqual(TokenKind.plus_assign, resolve("+=").?);
    try std.testing.expectEqual(TokenKind.neq, resolve("!=").?);
}

test "token_map - terminals resolve correctly" {
    try std.testing.expectEqual(TokenKind.identifier, resolve("IDENTIFIER").?);
    try std.testing.expectEqual(TokenKind.int_literal, resolve("INT_LITERAL").?);
    try std.testing.expectEqual(TokenKind.newline, resolve("NL").?);
    try std.testing.expectEqual(TokenKind.eof, resolve("EOF").?);
}

test "token_map - unknown names return null" {
    try std.testing.expect(resolve("expr") == null);
    try std.testing.expect(resolve("func_decl") == null);
    try std.testing.expect(resolve("block") == null);
}
