// lsp_semantic.zig -- LSP semantic tokens handler

const std = @import("std");
const lsp_types = @import("lsp_types.zig");
const lsp_json = @import("lsp_json.zig");
const lsp_utils = @import("lsp_utils.zig");
const lexer = @import("../lexer.zig");

const SemanticTokenType = lsp_types.SemanticTokenType;
const SemanticModifier = lsp_types.SemanticModifier;
const SemanticToken = lsp_types.SemanticToken;
const TokenClassification = lsp_types.TokenClassification;

const jsonStr = lsp_json.jsonStr;
const jsonObj = lsp_json.jsonObj;
const writeJsonValue = lsp_json.writeJsonValue;
const appendInt = lsp_json.appendInt;
const buildEmptyResponse = lsp_json.buildEmptyResponse;
const extractTextDocumentUri = lsp_json.extractTextDocumentUri;

const lspLog = lsp_utils.lspLog;
const uriToPath = lsp_utils.uriToPath;

pub fn handleSemanticTokens(allocator: std.mem.Allocator, root: std.json.Value, id: std.json.Value) ![]u8 {
    const params = jsonObj(root, "params") orelse return buildEmptyResponse(allocator, id);
    const uri = extractTextDocumentUri(params) orelse return buildEmptyResponse(allocator, id);

    const path = uriToPath(uri) orelse return buildEmptyResponse(allocator, id);
    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch
        return buildEmptyResponse(allocator, id);
    defer allocator.free(source);
    lspLog("semanticTokens: {s}", .{path});

    // Lex the source to get tokens
    var lex = lexer.Lexer.init(source);
    var tokens: std.ArrayListUnmanaged(SemanticToken) = .{};
    defer tokens.deinit(allocator);

    while (true) {
        const tok = lex.next();
        if (tok.kind == .eof) break;
        if (tok.kind == .newline) continue;

        const sem = classifyToken(tok.kind);
        if (sem.token_type) |tt| {
            try tokens.append(allocator, .{
                .line = if (tok.line > 0) tok.line - 1 else 0, // lexer is 1-based
                .col = if (tok.col > 0) tok.col - 1 else 0,
                .length = tok.text.len,
                .token_type = @intFromEnum(tt),
                .modifiers = sem.modifiers,
            });
        }
    }

    // Encode as delta-encoded data array per LSP spec
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(&buf, allocator, id);
    try buf.appendSlice(allocator, ",\"result\":{\"data\":[");

    var prev_line: usize = 0;
    var prev_col: usize = 0;
    for (tokens.items, 0..) |tok, tok_idx| {
        if (tok_idx > 0) try buf.append(allocator, ',');
        const delta_line = tok.line -| prev_line;
        const delta_col = if (tok.line == prev_line) tok.col -| prev_col else tok.col;
        try appendInt(&buf, allocator, delta_line);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, delta_col);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.length);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.token_type);
        try buf.append(allocator, ',');
        try appendInt(&buf, allocator, tok.modifiers);
        prev_line = tok.line;
        prev_col = tok.col;
    }

    try buf.appendSlice(allocator, "]}}");
    return allocator.dupe(u8, buf.items);
}

pub fn classifyToken(kind: lexer.TokenKind) TokenClassification {
    return switch (kind) {
        // Keywords
        .kw_func, .kw_var, .kw_const, .kw_struct, .kw_enum,
        .kw_module, .kw_import, .kw_use, .kw_pub, .kw_compt, .kw_test,
        .kw_if, .kw_elif, .kw_else, .kw_for, .kw_while, .kw_return, .kw_match,
        .kw_break, .kw_continue, .kw_defer, .kw_any,
        .kw_and, .kw_or, .kw_not, .kw_as, .kw_is,
        .kw_true, .kw_false, .kw_null,
        .kw_void, .kw_type,
        => .{ .token_type = .keyword, .modifiers = 0 },

        // @ prefix for compiler functions — classify as operator prefix
        .at_sign => .{ .token_type = .operator, .modifiers = 0 },

        // Literals
        .string_literal => .{ .token_type = .string, .modifiers = 0 },
        .int_literal, .float_literal => .{ .token_type = .number, .modifiers = 0 },

        // Operators
        .plus, .plus_plus, .minus, .star, .slash, .percent,
        .eq, .neq, .lt, .gt, .lte, .gte,
        .caret, .lshift, .rshift, .bang, .ampersand,
        .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign,
        .arrow, .dotdot, .pipe,
        => .{ .token_type = .operator, .modifiers = 0 },

        .hash => .{ .token_type = .keyword, .modifiers = 0 },

        // Identifiers classified by context later, but base case
        .identifier => .{ .token_type = null, .modifiers = 0 },

        // Skip punctuation and structural tokens
        else => .{ .token_type = null, .modifiers = 0 },
    };
}

// ============================================================
// TESTS
// ============================================================

test "classifyToken keywords" {
    const kw = classifyToken(.kw_func);
    try std.testing.expectEqual(SemanticTokenType.keyword, kw.token_type.?);
    const num = classifyToken(.int_literal);
    try std.testing.expectEqual(SemanticTokenType.number, num.token_type.?);
    const str = classifyToken(.string_literal);
    try std.testing.expectEqual(SemanticTokenType.string, str.token_type.?);
    const ident = classifyToken(.identifier);
    try std.testing.expect(ident.token_type == null);
}
