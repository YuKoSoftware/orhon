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
const bridge_impl = @import("builder_bridge.zig");
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
        }) catch {};
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

/// Build an AST node from a capture node. Dispatches to rule-specific
/// builders or passes through transparent rules.
pub fn buildNode(ctx: *BuildContext, cap: *const CaptureNode) anyerror!*Node {
    const rule = cap.rule orelse return error.NoRule;

    // Track position for source location recording
    ctx.current_pos = cap.start_pos;

    // Declaration builders
    if (std.mem.eql(u8, rule, "program")) return decls_impl.buildProgram(ctx, cap);
    if (std.mem.eql(u8, rule, "module_decl")) return decls_impl.buildModuleDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "const_decl")) return decls_impl.buildConstDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "var_decl")) return decls_impl.buildVarDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "func_decl")) return decls_impl.buildFuncDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "param")) return decls_impl.buildParam(ctx, cap);
    if (std.mem.eql(u8, rule, "struct_decl")) return decls_impl.buildStructDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "blueprint_decl")) return decls_impl.buildBlueprintDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "enum_decl")) return decls_impl.buildEnumDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "field_decl")) return decls_impl.buildFieldDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "enum_variant")) return decls_impl.buildEnumVariant(ctx, cap);
    if (std.mem.eql(u8, rule, "bitfield_decl")) return decls_impl.buildBitfieldDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "destruct_decl")) return decls_impl.buildDestructDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "test_decl")) return decls_impl.buildTestDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "import_decl")) return decls_impl.buildImport(ctx, cap);
    if (std.mem.eql(u8, rule, "metadata")) return decls_impl.buildMetadata(ctx, cap);

    // Statement builders
    if (std.mem.eql(u8, rule, "block")) return stmts_impl.buildBlock(ctx, cap);
    if (std.mem.eql(u8, rule, "return_stmt")) return stmts_impl.buildReturn(ctx, cap);
    if (std.mem.eql(u8, rule, "if_stmt")) return stmts_impl.buildIf(ctx, cap);
    if (std.mem.eql(u8, rule, "elif_chain")) return stmts_impl.buildElifChain(ctx, cap);
    if (std.mem.eql(u8, rule, "while_stmt")) return stmts_impl.buildWhile(ctx, cap);
    if (std.mem.eql(u8, rule, "for_stmt")) return stmts_impl.buildFor(ctx, cap);
    if (std.mem.eql(u8, rule, "defer_stmt")) return stmts_impl.buildDefer(ctx, cap);
    if (std.mem.eql(u8, rule, "match_stmt")) return stmts_impl.buildMatch(ctx, cap);
    if (std.mem.eql(u8, rule, "match_arm")) return stmts_impl.buildMatchArm(ctx, cap);
    if (std.mem.eql(u8, rule, "break_stmt")) return ctx.newNode(.{ .break_stmt = {} });
    if (std.mem.eql(u8, rule, "continue_stmt")) return ctx.newNode(.{ .continue_stmt = {} });
    if (std.mem.eql(u8, rule, "throw_stmt")) return stmts_impl.buildThrowStmt(ctx, cap);
    if (std.mem.eql(u8, rule, "expr_or_assignment")) return stmts_impl.buildExprOrAssignment(ctx, cap);
    if (std.mem.eql(u8, rule, "assign_expr")) return stmts_impl.buildExprOrAssignment(ctx, cap);

    // Expression builders
    if (std.mem.eql(u8, rule, "int_literal")) return exprs_impl.buildIntLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "float_literal")) return exprs_impl.buildFloatLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "string_literal")) return exprs_impl.buildStringLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "bool_literal")) return exprs_impl.buildBoolLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "null_literal")) return ctx.newNode(.{ .null_literal = {} });
    if (std.mem.eql(u8, rule, "identifier_expr")) return exprs_impl.buildIdentifier(ctx, cap);
    if (std.mem.eql(u8, rule, "compiler_func")) return exprs_impl.buildCompilerFunc(ctx, cap);
    if (std.mem.eql(u8, rule, "error_literal")) return exprs_impl.buildErrorLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "array_literal")) return exprs_impl.buildArrayLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "grouped_expr")) return exprs_impl.buildGroupedExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "tuple_literal")) return exprs_impl.buildTupleLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "struct_expr")) return exprs_impl.buildStructExpr(ctx, cap);

    // Binary expression tower — all use the same builder
    if (std.mem.eql(u8, rule, "or_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "or");
    if (std.mem.eql(u8, rule, "and_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "and");
    if (std.mem.eql(u8, rule, "bitor_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "|");
    if (std.mem.eql(u8, rule, "bitxor_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "^");
    if (std.mem.eql(u8, rule, "bitand_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "&");
    if (std.mem.eql(u8, rule, "shift_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "<<");
    if (std.mem.eql(u8, rule, "add_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "+");
    if (std.mem.eql(u8, rule, "mul_expr")) return exprs_impl.buildBinaryExpr(ctx, cap, "*");
    if (std.mem.eql(u8, rule, "compare_expr")) return exprs_impl.buildCompareExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "range_expr")) return exprs_impl.buildRangeExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "not_expr")) return exprs_impl.buildNotExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "unary_expr")) return exprs_impl.buildUnaryExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "postfix_expr")) return exprs_impl.buildPostfixExpr(ctx, cap);

    // Type builders
    if (std.mem.eql(u8, rule, "named_type")) return types_impl.buildNamedType(ctx, cap);
    if (std.mem.eql(u8, rule, "keyword_type")) return types_impl.buildKeywordType(ctx, cap);
    if (std.mem.eql(u8, rule, "generic_type")) return types_impl.buildGenericType(ctx, cap);
    if (std.mem.eql(u8, rule, "scoped_type")) return types_impl.buildScopedType(ctx, cap);
    if (std.mem.eql(u8, rule, "scoped_generic_type")) return types_impl.buildScopedGenericType(ctx, cap);
    if (std.mem.eql(u8, rule, "borrow_type")) return types_impl.buildBorrowType(ctx, cap);
    if (std.mem.eql(u8, rule, "ref_type")) return types_impl.buildRefType(ctx, cap);
    if (std.mem.eql(u8, rule, "paren_type")) return types_impl.buildParenType(ctx, cap);
    if (std.mem.eql(u8, rule, "slice_type")) return types_impl.buildSliceType(ctx, cap);
    if (std.mem.eql(u8, rule, "array_type")) return types_impl.buildArrayType(ctx, cap);
    if (std.mem.eql(u8, rule, "func_type")) return types_impl.buildFuncType(ctx, cap);

    // Bridge declarations
    if (std.mem.eql(u8, rule, "bridge_decl")) return bridge_impl.buildBridgeDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_func")) return bridge_impl.buildBridgeFunc(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_const")) return bridge_impl.buildBridgeConst(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_struct")) return bridge_impl.buildBridgeStruct(ctx, cap);
    if (std.mem.eql(u8, rule, "thread_decl")) return bridge_impl.buildThreadDecl(ctx, cap);

    // Context-setting rules (set flags on child node)
    if (std.mem.eql(u8, rule, "pub_decl")) return bridge_impl.buildPubDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "compt_decl")) return bridge_impl.buildComptDecl(ctx, cap);

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

/// Recursively collect param nodes from a capture tree
pub fn collectParamsRecursive(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "param")) {
                try out.append(ctx.alloc(), try buildNode(ctx, child));
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
// SHARED STRUCT/ENUM HELPERS (used by decls and bridge satellites)
// ============================================================

/// Walk a capture tree to collect struct/bridge struct type params and member nodes.
/// Called by builder_decls.buildStructDecl and builder_bridge.buildBridgeStruct.
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
                std.mem.eql(u8, r, "var_decl") or
                std.mem.eql(u8, r, "bridge_decl") or
                std.mem.eql(u8, r, "bridge_func") or
                std.mem.eql(u8, r, "bridge_const"))
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
                // Recurse into wrapper rules (struct_body, struct_member, bridge_struct_body, etc.)
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
/// Used by bridge and decls satellites.
pub fn setPub(node: *Node, value: bool) void {
    switch (node.*) {
        .func_decl => |*d| d.is_pub = value,
        .struct_decl => |*d| d.is_pub = value,
        .blueprint_decl => |*d| d.is_pub = value,
        .enum_decl => |*d| d.is_pub = value,
        .bitfield_decl => |*d| d.is_pub = value,
        .const_decl => |*d| d.is_pub = value,
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
        .bitfield_decl => |*d| d.doc = doc,
        .const_decl => |*d| d.doc = doc,
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
//                        struct, enum, field, enum_variant, destruct, bitfield, test
//   builder_bridge.zig — pub_decl, compt_decl, bridge_decl/func/const/struct, thread_decl
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
    try std.testing.expect(decl.* == .const_decl);
    try std.testing.expectEqualStrings("MAX", decl.const_decl.name);
    try std.testing.expect(decl.const_decl.type_annotation != null);
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
