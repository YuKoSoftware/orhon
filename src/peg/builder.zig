// builder.zig — Transforms PEG capture trees into parser.Node AST nodes
//
// Each grammar rule that produces an AST node has a builder function.
// Rules not in the dispatch table are "transparent" — the builder
// recurses into their single child.

const std = @import("std");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const errors = @import("../errors.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const LocMap = parser.LocMap;

const decls_impl = @import("builder_decls.zig");
const stmts_impl = @import("builder_stmts.zig");
const exprs_impl = @import("builder_exprs.zig");
const types_impl = @import("builder_types.zig");

// ============================================================
// BUILD CONTEXT
// ============================================================

/// Syntax error collected during AST building (from error recovery).
pub const SyntaxError = struct {
    message: []const u8,
    line: usize,
    col: usize,
};

pub const BuildContext = struct {
    tokens: []const Token,
    arena: std.heap.ArenaAllocator,
    locs: LocMap,
    current_pos: usize = 0, // token position for source location tracking
    owns_arena: bool = true,
    /// Syntax errors from error recovery (skipped tokens)
    syntax_errors: std.ArrayListUnmanaged(SyntaxError) = .{},

    pub fn init(tokens: []const Token, backing_allocator: std.mem.Allocator) BuildContext {
        return .{
            .tokens = tokens,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .locs = LocMap.init(backing_allocator),
        };
    }

    /// Initialize with an external arena (caller owns it — do NOT call deinit).
    pub fn initWithArena(tokens: []const Token, arena: std.heap.ArenaAllocator, backing_allocator: std.mem.Allocator) BuildContext {
        return .{
            .tokens = tokens,
            .arena = arena,
            .locs = LocMap.init(backing_allocator),
            .owns_arena = false,
        };
    }

    pub fn deinit(self: *BuildContext) void {
        self.syntax_errors.deinit(self.arena.child_allocator);
        self.locs.deinit();
        if (self.owns_arena) self.arena.deinit();
    }

    /// Record a syntax error from error recovery (token skip).
    pub fn reportError(self: *BuildContext, message: []const u8, pos: usize) void {
        const tok = if (pos < self.tokens.len) self.tokens[pos] else null;
        const line = if (tok) |t| t.line else 0;
        const col = if (tok) |t| t.col else 0;
        self.syntax_errors.append(self.arena.child_allocator, .{
            .message = message,
            .line = line,
            .col = col,
        }) catch return;
    }

    pub fn alloc(self: *BuildContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn newNode(self: *BuildContext, node: Node) !*Node {
        const n = try self.alloc().create(Node);
        n.* = node;
        // Record source location from current_pos
        if (self.current_pos < self.tokens.len) {
            const tok = self.tokens[self.current_pos];
            try self.locs.put(n, .{ .file = "", .line = tok.line, .col = tok.col });
        }
        return n;
    }

    pub fn newNodeAt(self: *BuildContext, node: Node, pos: usize) !*Node {
        const n = try self.alloc().create(Node);
        n.* = node;
        if (pos < self.tokens.len) {
            const tok = self.tokens[pos];
            try self.locs.put(n, .{ .file = "", .line = tok.line, .col = tok.col });
        }
        return n;
    }
};

// ============================================================
// PUBLIC API
// ============================================================

pub const BuildResult = struct {
    node: *Node,
    ctx: BuildContext,
};

/// Build an AST from a capture tree.
pub fn buildAST(cap: *const CaptureNode, tokens: []const Token, allocator: std.mem.Allocator) !BuildResult {
    var ctx = BuildContext.init(tokens, allocator);
    const node = try buildNode(&ctx, cap);
    return .{ .node = node, .ctx = ctx };
}

/// Build an AST using an external arena (for integration with module.zig).
pub fn buildASTWithArena(cap: *const CaptureNode, tokens: []const Token, arena: std.heap.ArenaAllocator, allocator: std.mem.Allocator) !BuildResult {
    var ctx = BuildContext.initWithArena(tokens, arena, allocator);
    const node = try buildNode(&ctx, cap);
    return .{ .node = node, .ctx = ctx };
}

// ============================================================
// NODE DISPATCH
// ============================================================

const BuilderFn = *const fn (*BuildContext, *const CaptureNode) anyerror!*Node;

/// Comptime dispatch table mapping PEG rule names to builder functions.
const rule_dispatch = std.StaticStringMap(BuilderFn).initComptime(.{
    // Declarations
    .{ "program", decls_impl.buildProgram },
    .{ "module_decl", decls_impl.buildModuleDecl },
    .{ "const_decl", decls_impl.buildConstDecl },
    .{ "var_decl", decls_impl.buildVarDecl },
    .{ "func_decl", decls_impl.buildFuncDecl },
    .{ "param", decls_impl.buildParam },
    .{ "struct_decl", decls_impl.buildStructDecl },
    .{ "blueprint_decl", decls_impl.buildBlueprintDecl },
    .{ "enum_decl", decls_impl.buildEnumDecl },
    .{ "field_decl", decls_impl.buildFieldDecl },
    .{ "enum_variant", decls_impl.buildEnumVariant },
    .{ "destruct_decl", decls_impl.buildDestructDecl },
    .{ "test_decl", decls_impl.buildTestDecl },
    .{ "import_decl", decls_impl.buildImport },
    .{ "metadata", decls_impl.buildMetadata },
    .{ "pub_decl", decls_impl.buildPubDecl },
    .{ "compt_decl", decls_impl.buildComptDecl },
    // Statements
    .{ "block", stmts_impl.buildBlock },
    .{ "return_stmt", stmts_impl.buildReturn },
    .{ "if_stmt", stmts_impl.buildIf },
    .{ "elif_chain", stmts_impl.buildElifChain },
    .{ "while_stmt", stmts_impl.buildWhile },
    .{ "for_stmt", stmts_impl.buildFor },
    .{ "defer_stmt", stmts_impl.buildDefer },
    .{ "match_stmt", stmts_impl.buildMatch },
    .{ "match_arm", stmts_impl.buildMatchArm },
    .{ "break_stmt", buildBreakStmt },
    .{ "continue_stmt", buildContinueStmt },
    .{ "throw_stmt", stmts_impl.buildThrowStmt },
    .{ "expr_or_assignment", stmts_impl.buildExprOrAssignment },
    .{ "assign_expr", stmts_impl.buildExprOrAssignment },
    // Expressions
    .{ "int_literal", exprs_impl.buildIntLiteral },
    .{ "float_literal", exprs_impl.buildFloatLiteral },
    .{ "string_literal", exprs_impl.buildStringLiteral },
    .{ "bool_literal", exprs_impl.buildBoolLiteral },
    .{ "null_literal", buildNullLiteral },
    .{ "void_literal", buildVoidLiteral },
    .{ "identifier_expr", exprs_impl.buildIdentifier },
    .{ "compiler_func", exprs_impl.buildCompilerFunc },
    .{ "error_literal", exprs_impl.buildErrorLiteral },
    .{ "array_literal", exprs_impl.buildArrayLiteral },
    .{ "grouped_expr", exprs_impl.buildGroupedExpr },
    .{ "tuple_literal", exprs_impl.buildTupleLiteral },
    .{ "anon_tuple_literal", exprs_impl.buildAnonTupleLiteral },
    .{ "struct_expr", exprs_impl.buildStructExpr },
    // Binary expression tower
    .{ "or_expr", exprs_impl.buildBinaryExpr },
    .{ "and_expr", exprs_impl.buildBinaryExpr },
    .{ "bitor_expr", exprs_impl.buildBinaryExpr },
    .{ "bitxor_expr", exprs_impl.buildBinaryExpr },
    .{ "bitand_expr", exprs_impl.buildBinaryExpr },
    .{ "shift_expr", exprs_impl.buildBinaryExpr },
    .{ "add_expr", exprs_impl.buildBinaryExpr },
    .{ "mul_expr", exprs_impl.buildBinaryExpr },
    .{ "compare_expr", exprs_impl.buildCompareExpr },
    .{ "range_expr", exprs_impl.buildRangeExpr },
    .{ "not_expr", exprs_impl.buildNotExpr },
    .{ "unary_expr", exprs_impl.buildUnaryExpr },
    .{ "postfix_expr", exprs_impl.buildPostfixExpr },
    // Types
    .{ "named_type", types_impl.buildNamedType },
    .{ "keyword_type", types_impl.buildKeywordType },
    .{ "generic_type", types_impl.buildGenericType },
    .{ "scoped_type", types_impl.buildScopedType },
    .{ "scoped_generic_type", types_impl.buildScopedGenericType },
    .{ "borrow_type", types_impl.buildBorrowType },
    .{ "ref_type", types_impl.buildRefType },
    .{ "paren_type", types_impl.buildParenType },
    .{ "slice_type", types_impl.buildSliceType },
    .{ "array_type", types_impl.buildArrayType },
    .{ "func_type", types_impl.buildFuncType },
});

fn buildBreakStmt(ctx: *BuildContext, _: *const CaptureNode) anyerror!*Node {
    return ctx.newNode(.{ .break_stmt = {} });
}

fn buildContinueStmt(ctx: *BuildContext, _: *const CaptureNode) anyerror!*Node {
    return ctx.newNode(.{ .continue_stmt = {} });
}

fn buildNullLiteral(ctx: *BuildContext, _: *const CaptureNode) anyerror!*Node {
    return ctx.newNode(.{ .null_literal = {} });
}

fn buildVoidLiteral(ctx: *BuildContext, _: *const CaptureNode) anyerror!*Node {
    return ctx.newNode(.{ .type_named = "void" });
}

/// Build an AST node from a capture node. Dispatches to rule-specific
/// builders via comptime lookup table, or passes through transparent rules.
pub fn buildNode(ctx: *BuildContext, cap: *const CaptureNode) anyerror!*Node {
    const rule = cap.rule orelse return error.NoRule;

    // Track position for source location recording
    ctx.current_pos = cap.start_pos;

    // Dispatch to builder via comptime lookup table
    if (rule_dispatch.get(rule)) |builder_fn| return builder_fn(ctx, cap);

    // Transparent rules — recurse into first child
    if (cap.children.len > 0) return buildNode(ctx, &cap.children[0]);

    // Terminal rule with no children — extract token
    return buildTokenNode(ctx, cap);
}

// ============================================================
// TOKEN HELPERS
// ============================================================

/// Get token text at a position
pub fn tokenText(ctx: *BuildContext, pos: usize) []const u8 {
    if (pos < ctx.tokens.len) return ctx.tokens[pos].text;
    return "";
}

/// Find first token of a kind within a capture range
pub fn findTokenInRange(ctx: *BuildContext, start: usize, end: usize, kind: TokenKind) ?usize {
    var i = start;
    while (i < end and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == kind) return i;
    }
    return null;
}

/// Build a node from a terminal capture (identifier, literal, etc.)
pub fn buildTokenNode(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.start_pos >= ctx.tokens.len) return error.InvalidCapture;
    const tok = ctx.tokens[cap.start_pos];
    return switch (tok.kind) {
        .identifier => ctx.newNode(.{ .identifier = tok.text }),
        .int_literal => ctx.newNode(.{ .int_literal = tok.text }),
        .float_literal => ctx.newNode(.{ .float_literal = tok.text }),
        .string_literal => ctx.newNode(.{ .string_literal = tok.text }),
        .kw_true => ctx.newNode(.{ .bool_literal = true }),
        .kw_false => ctx.newNode(.{ .bool_literal = false }),
        .kw_null => ctx.newNode(.{ .null_literal = {} }),
        else => ctx.newNode(.{ .identifier = tok.text }),
    };
}

/// Build all children with a specific rule name into a node slice
pub fn buildChildrenByRule(ctx: *BuildContext, cap: *const CaptureNode, rule_name: []const u8) ![]*Node {
    var nodes = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, rule_name)) {
                try nodes.append(ctx.alloc(), try buildNode(ctx, child));
            }
        }
    }
    return nodes.toOwnedSlice(ctx.alloc());
}

/// Recursively collect expr nodes from a capture tree
pub fn collectExprsRecursive(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "expr")) {
                try out.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM")) {
                // skip
            } else {
                try collectExprsRecursive(ctx, child, out);
            }
        }
    }
}

/// Collect call arguments with optional names
pub fn collectCallArgs(ctx: *BuildContext, cap: *const CaptureNode, args: *std.ArrayListUnmanaged(*Node), names: *std.ArrayListUnmanaged([]const u8), has_names: *bool) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "named_or_positional_arg")) {
                // Check if it's named: IDENTIFIER ':' expr
                if (child.findChild("expr")) |e| {
                    // Check for name by looking at the token before ':'
                    const first_tok = ctx.tokens[child.start_pos];
                    if (first_tok.kind == .identifier and
                        child.start_pos + 1 < child.end_pos and
                        ctx.tokens[child.start_pos + 1].kind == .colon)
                    {
                        try names.append(ctx.alloc(), first_tok.text);
                        has_names.* = true;
                    } else {
                        try names.append(ctx.alloc(), "");
                    }
                    try args.append(ctx.alloc(), try buildNode(ctx, e));
                }
            } else if (std.mem.eql(u8, r, "expr")) {
                try args.append(ctx.alloc(), try buildNode(ctx, child));
                try names.append(ctx.alloc(), "");
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM")) {
                // skip
            } else {
                try collectCallArgs(ctx, child, args, names, has_names);
            }
        }
    }
}

/// Recursively collect param nodes from a capture tree.
/// Stops at nested func_decl / compt_decl boundaries to avoid
/// picking up params from functions nested inside (e.g. methods in struct_expr).
pub fn collectParamsRecursive(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "param")) {
                try out.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "func_decl") or
                std.mem.eql(u8, r, "compt_decl"))
            {
                // Do not recurse into nested function declarations — their params
                // belong to them, not to the enclosing function being built.
            } else {
                try collectParamsRecursive(ctx, child, out);
            }
        }
    }
}

/// Build all children into nodes (any rule)
pub fn buildAllChildren(ctx: *BuildContext, cap: *const CaptureNode) ![]*Node {
    var nodes = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        try nodes.append(ctx.alloc(), try buildNode(ctx, child));
    }
    return nodes.toOwnedSlice(ctx.alloc());
}

// ============================================================
// SHARED STRUCT/ENUM HELPERS (used by decls and builder satellites)
// ============================================================

/// Walk a capture tree to collect struct type params and member nodes.
/// Called by builder_decls.buildStructDecl.
pub fn collectStructParts(ctx: *BuildContext, cap: *const CaptureNode, type_params: *std.ArrayListUnmanaged(*Node), members: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    var pending_doc: ?[]const u8 = null;
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "doc_block")) {
                pending_doc = extractDoc(ctx, child);
            } else if (std.mem.eql(u8, r, "field_decl") or
                std.mem.eql(u8, r, "func_decl") or
                std.mem.eql(u8, r, "compt_decl") or
                std.mem.eql(u8, r, "const_decl") or
                std.mem.eql(u8, r, "var_decl"))
            {
                // Terminal declaration nodes — build and add as members
                const node = try buildNode(ctx, child);
                if (hasPubBefore(ctx, cap, child.start_pos)) setPub(node, true);
                if (pending_doc) |doc| {
                    setDoc(node, doc);
                    pending_doc = null;
                }
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "pub_decl")) {
                const node = try buildNode(ctx, child);
                if (pending_doc) |doc| {
                    setDoc(node, doc);
                    pending_doc = null;
                }
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "generic_params") or std.mem.eql(u8, r, "param_list")) {
                // Only collect params from generic_params context (not from functions)
                try collectParamsRecursive(ctx, child, type_params);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "type")) {
                // skip
            } else {
                // Recurse into wrapper rules (struct_body, struct_member, etc.)
                // but NOT into declarations (which have their own params)
                try collectStructParts(ctx, child, type_params, members);
            }
        }
    }
}

/// Check if there's a 'pub' token in the capture range before the given position.
/// Used by collectStructParts and collectEnumMembers in satellites.
pub fn hasPubBefore(ctx: *BuildContext, cap: *const CaptureNode, before_pos: usize) bool {
    var i = cap.start_pos;
    while (i < before_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .kw_pub) return true;
    }
    return false;
}

/// Set the is_pub flag on a node (works for all declaration node types).
/// Used by builder satellites.
pub fn setPub(node: *Node, value: bool) void {
    switch (node.*) {
        .func_decl => |*d| d.is_pub = value,
        .struct_decl => |*d| d.is_pub = value,
        .blueprint_decl => |*d| d.is_pub = value,
        .enum_decl => |*d| d.is_pub = value,
        .var_decl => |*d| d.is_pub = value,
        .field_decl => |*d| d.is_pub = value,
        else => {},
    }
}

/// Extract doc comment text from a doc_block capture node.
/// Joins all DOC_COMMENT token texts with newlines.
pub fn extractDoc(ctx: *BuildContext, doc_cap: *const CaptureNode) ?[]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};
    var i = doc_cap.start_pos;
    while (i < doc_cap.end_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .doc_comment) {
            parts.append(ctx.alloc(), ctx.tokens[i].text) catch return null;
        }
    }
    if (parts.items.len == 0) return null;
    return std.mem.join(ctx.alloc(), "\n", parts.items) catch null;
}

/// Set the doc field on a declaration node.
pub fn setDoc(node: *Node, doc: ?[]const u8) void {
    switch (node.*) {
        .func_decl => |*d| d.doc = doc,
        .struct_decl => |*d| d.doc = doc,
        .blueprint_decl => |*d| d.doc = doc,
        .enum_decl => |*d| d.doc = doc,
        .var_decl => |*d| d.doc = doc,
        .field_decl => |*d| d.doc = doc,
        .enum_variant => |*d| d.doc = doc,
        .module_decl => |*d| d.doc = doc,
        else => {},
    }
}

// NOTE: All declaration, statement, expression, and type builder functions have
// been extracted to their respective satellite files:
//   builder_decls.zig  — program, module, import, metadata, func, param, const, var,
//                        struct, enum, field, enum_variant, destruct, test, pub_decl, compt_decl
//   builder_stmts.zig  — block, return, throw, if, elif, while, for, defer, match, match_arm,
//                        expr_or_assignment
//   builder_exprs.zig  — int/float/string/bool literals, identifier, error, compiler_func,
//                        array, grouped, tuple, struct_expr, binary, compare, range, not,
//                        unary, postfix
//   builder_types.zig  — named, keyword, scoped, scoped_generic, generic, borrow, ref,
//                        paren, slice, array, func types

// ============================================================
// TESTS
// ============================================================

test "builder - build minimal program AST" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init("module myapp\n");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    try std.testing.expect(result.node.* == .program);
    try std.testing.expectEqualStrings("myapp", result.node.program.module.module_decl.name);
}

test "builder - build program with function" {
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

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    const prog = result.node.program;
    try std.testing.expectEqualStrings("myapp", prog.module.module_decl.name);
    try std.testing.expectEqual(@as(usize, 1), prog.top_level.len);

    const func = prog.top_level[0];
    try std.testing.expect(func.* == .func_decl);
    try std.testing.expectEqualStrings("add", func.func_decl.name);
    try std.testing.expectEqual(@as(usize, 2), func.func_decl.params.len);
}

test "builder - build program with const" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\const MAX: i32 = 100
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    const prog = result.node.program;
    try std.testing.expectEqual(@as(usize, 1), prog.top_level.len);

    const decl = prog.top_level[0];
    try std.testing.expect(decl.* == .var_decl);
    try std.testing.expectEqualStrings("MAX", decl.var_decl.name);
    try std.testing.expect(decl.var_decl.type_annotation != null);
    try std.testing.expect(decl.var_decl.mutability == .constant);
}

test "builder - build pub struct" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init(
        \\module example
        \\
        \\pub struct Point {
        \\    pub x: f64
        \\    pub y: f64
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    const prog = result.node.program;
    try std.testing.expectEqual(@as(usize, 1), prog.top_level.len);

    const s = prog.top_level[0];
    try std.testing.expect(s.* == .struct_decl);
    try std.testing.expectEqualStrings("Point", s.struct_decl.name);
    try std.testing.expect(s.struct_decl.is_pub);
}
