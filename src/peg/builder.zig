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

    fn alloc(self: *BuildContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn newNode(self: *BuildContext, node: Node) !*Node {
        const n = try self.alloc().create(Node);
        n.* = node;
        // Record source location from current_pos
        if (self.current_pos < self.tokens.len) {
            const tok = self.tokens[self.current_pos];
            try self.locs.put(n, .{ .file = "", .line = tok.line, .col = tok.col });
        }
        return n;
    }

    fn newNodeAt(self: *BuildContext, node: Node, pos: usize) !*Node {
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
fn buildNode(ctx: *BuildContext, cap: *const CaptureNode) anyerror!*Node {
    const rule = cap.rule orelse return error.NoRule;

    // Track position for source location recording
    ctx.current_pos = cap.start_pos;

    // Dispatch to rule-specific builders
    if (std.mem.eql(u8, rule, "program")) return buildProgram(ctx, cap);
    if (std.mem.eql(u8, rule, "module_decl")) return buildModuleDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "const_decl")) return buildConstDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "var_decl")) return buildVarDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "func_decl")) return buildFuncDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "block")) return buildBlock(ctx, cap);
    if (std.mem.eql(u8, rule, "return_stmt")) return buildReturn(ctx, cap);
    if (std.mem.eql(u8, rule, "if_stmt")) return buildIf(ctx, cap);
    if (std.mem.eql(u8, rule, "while_stmt")) return buildWhile(ctx, cap);
    if (std.mem.eql(u8, rule, "for_stmt")) return buildFor(ctx, cap);
    if (std.mem.eql(u8, rule, "defer_stmt")) return buildDefer(ctx, cap);
    if (std.mem.eql(u8, rule, "match_stmt")) return buildMatch(ctx, cap);
    if (std.mem.eql(u8, rule, "match_arm")) return buildMatchArm(ctx, cap);
    if (std.mem.eql(u8, rule, "break_stmt")) return ctx.newNode(.{ .break_stmt = {} });
    if (std.mem.eql(u8, rule, "continue_stmt")) return ctx.newNode(.{ .continue_stmt = {} });
    if (std.mem.eql(u8, rule, "param")) return buildParam(ctx, cap);
    if (std.mem.eql(u8, rule, "struct_decl")) return buildStructDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "enum_decl")) return buildEnumDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "field_decl")) return buildFieldDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "enum_variant")) return buildEnumVariant(ctx, cap);
    if (std.mem.eql(u8, rule, "bitfield_decl")) return buildBitfieldDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "destruct_decl")) return buildDestructDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "test_decl")) return buildTestDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "import_decl")) return buildImport(ctx, cap);
    if (std.mem.eql(u8, rule, "metadata")) return buildMetadata(ctx, cap);
    if (std.mem.eql(u8, rule, "expr_or_assignment")) return buildExprOrAssignment(ctx, cap);
    if (std.mem.eql(u8, rule, "assign_expr")) return buildExprOrAssignment(ctx, cap);

    // Expression builders
    if (std.mem.eql(u8, rule, "int_literal")) return buildIntLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "float_literal")) return buildFloatLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "string_literal")) return buildStringLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "bool_literal")) return buildBoolLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "null_literal")) return ctx.newNode(.{ .null_literal = {} });
    if (std.mem.eql(u8, rule, "identifier_expr")) return buildIdentifier(ctx, cap);
    if (std.mem.eql(u8, rule, "compiler_func")) return buildCompilerFunc(ctx, cap);
    if (std.mem.eql(u8, rule, "error_literal")) return buildErrorLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "array_literal")) return buildArrayLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "grouped_expr")) return buildGroupedExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "tuple_literal")) return buildTupleLiteral(ctx, cap);
    if (std.mem.eql(u8, rule, "struct_expr")) return buildStructExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "ptr_cast_expr")) return buildPtrCastExpr(ctx, cap);

    // Binary expression tower — all use the same builder
    if (std.mem.eql(u8, rule, "or_expr")) return buildBinaryExpr(ctx, cap, "or");
    if (std.mem.eql(u8, rule, "and_expr")) return buildBinaryExpr(ctx, cap, "and");
    if (std.mem.eql(u8, rule, "bitor_expr")) return buildBinaryExpr(ctx, cap, "|");
    if (std.mem.eql(u8, rule, "bitxor_expr")) return buildBinaryExpr(ctx, cap, "^");
    if (std.mem.eql(u8, rule, "bitand_expr")) return buildBinaryExpr(ctx, cap, "&");
    if (std.mem.eql(u8, rule, "shift_expr")) return buildBinaryExpr(ctx, cap, "<<");
    if (std.mem.eql(u8, rule, "add_expr")) return buildBinaryExpr(ctx, cap, "+");
    if (std.mem.eql(u8, rule, "mul_expr")) return buildBinaryExpr(ctx, cap, "*");
    if (std.mem.eql(u8, rule, "compare_expr")) return buildCompareExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "range_expr")) return buildRangeExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "not_expr")) return buildNotExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "unary_expr")) return buildUnaryExpr(ctx, cap);
    if (std.mem.eql(u8, rule, "postfix_expr")) return buildPostfixExpr(ctx, cap);

    // Type builders
    if (std.mem.eql(u8, rule, "named_type")) return buildNamedType(ctx, cap);
    if (std.mem.eql(u8, rule, "keyword_type")) return buildKeywordType(ctx, cap);
    if (std.mem.eql(u8, rule, "generic_type")) return buildGenericType(ctx, cap);
    if (std.mem.eql(u8, rule, "borrow_type")) return buildBorrowType(ctx, cap);
    if (std.mem.eql(u8, rule, "ref_type")) return buildRefType(ctx, cap);
    if (std.mem.eql(u8, rule, "paren_type")) return buildParenType(ctx, cap);
    if (std.mem.eql(u8, rule, "slice_type")) return buildSliceType(ctx, cap);
    if (std.mem.eql(u8, rule, "array_type")) return buildArrayType(ctx, cap);
    if (std.mem.eql(u8, rule, "func_type")) return buildFuncType(ctx, cap);

    // Bridge declarations
    if (std.mem.eql(u8, rule, "bridge_decl")) return buildBridgeDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_func")) return buildBridgeFunc(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_const")) return buildBridgeConst(ctx, cap);
    if (std.mem.eql(u8, rule, "bridge_struct")) return buildBridgeStruct(ctx, cap);
    if (std.mem.eql(u8, rule, "thread_decl")) return buildThreadDecl(ctx, cap);

    // Context-setting rules (set flags on child node)
    if (std.mem.eql(u8, rule, "pub_decl")) return buildPubDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "compt_decl")) return buildComptDecl(ctx, cap);

    // Transparent rules — recurse into first child
    if (cap.children.len > 0) return buildNode(ctx, &cap.children[0]);

    // Terminal rule with no children — extract token
    return buildTokenNode(ctx, cap);
}

// ============================================================
// TOKEN HELPERS
// ============================================================

/// Get token text at a position
fn tokenText(ctx: *BuildContext, pos: usize) []const u8 {
    if (pos < ctx.tokens.len) return ctx.tokens[pos].text;
    return "";
}

/// Find first token of a kind within a capture range
fn findTokenInRange(ctx: *BuildContext, start: usize, end: usize, kind: TokenKind) ?usize {
    var i = start;
    while (i < end and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == kind) return i;
    }
    return null;
}

/// Build a node from a terminal capture (identifier, literal, etc.)
fn buildTokenNode(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
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
fn buildChildrenByRule(ctx: *BuildContext, cap: *const CaptureNode, rule_name: []const u8) ![]*Node {
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
fn collectExprsRecursive(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
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
fn collectCallArgs(ctx: *BuildContext, cap: *const CaptureNode, args: *std.ArrayListUnmanaged(*Node), names: *std.ArrayListUnmanaged([]const u8), has_names: *bool) anyerror!void {
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
fn collectParamsRecursive(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
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
fn buildAllChildren(ctx: *BuildContext, cap: *const CaptureNode) ![]*Node {
    var nodes = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        try nodes.append(ctx.alloc(), try buildNode(ctx, child));
    }
    return nodes.toOwnedSlice(ctx.alloc());
}

// ============================================================
// PROGRAM STRUCTURE BUILDERS
// ============================================================

fn buildProgram(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // program <- _ module_decl (_ (doc_block / metadata / import_decl / top_level))* _ EOF
    const mod = if (cap.findChild("module_decl")) |m| try buildNode(ctx, m) else return error.NoModule;

    var metadata_list = std.ArrayListUnmanaged(*Node){};
    var imports_list = std.ArrayListUnmanaged(*Node){};
    var top_level_list = std.ArrayListUnmanaged(*Node){};

    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "metadata")) {
                try metadata_list.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "import_decl")) {
                try imports_list.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "top_level")) {
                // top_level is transparent — build its child
                for (child.children) |*tl_child| {
                    if (tl_child.rule) |_| {
                        try top_level_list.append(ctx.alloc(), try buildNode(ctx, tl_child));
                    }
                }
            } else if (std.mem.eql(u8, r, "top_level_decl")) {
                try top_level_list.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "error_skip")) {
                // Error recovery: report the skipped tokens as a syntax error
                const start = child.start_pos;
                const tok = if (start < ctx.tokens.len) ctx.tokens[start] else null;
                if (tok) |t| {
                    const msg = try std.fmt.allocPrint(ctx.alloc(), "unexpected '{s}'", .{t.text});
                    ctx.reportError(msg, start);
                }
                // Don't add to AST — skipped tokens are discarded
            }
        }
    }

    return ctx.newNode(.{ .program = .{
        .module = mod,
        .metadata = try metadata_list.toOwnedSlice(ctx.alloc()),
        .imports = try imports_list.toOwnedSlice(ctx.alloc()),
        .top_level = try top_level_list.toOwnedSlice(ctx.alloc()),
    } });
}

fn buildModuleDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // module_decl <- doc_block? 'module' (IDENTIFIER / 'main') NL
    // Find the name token — it's the identifier or 'main' keyword after 'module'
    const name_pos = findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .identifier) orelse
        findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .kw_main) orelse
        return error.NoModuleName;
    return ctx.newNode(.{ .module_decl = .{ .name = tokenText(ctx, name_pos) } });
}

fn buildImport(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // import_decl <- 'import' import_path ('as' IDENTIFIER)? NL
    //             / 'include' import_path NL
    const is_include = ctx.tokens[cap.start_pos].kind == .kw_include;
    var path: []const u8 = "";
    var scope: ?[]const u8 = null;
    var alias: ?[]const u8 = null;
    var is_c_header = false;

    // Walk tokens to extract path components
    var i = cap.start_pos + 1;
    while (i < cap.end_pos) : (i += 1) {
        const tok = ctx.tokens[i];
        if (tok.kind == .string_literal) {
            path = tok.text;
            is_c_header = true;
        } else if (tok.kind == .identifier or tok.kind == .kw_main) {
            if (i + 1 < cap.end_pos and ctx.tokens[i + 1].kind == .scope) {
                scope = tok.text;
                i += 2; // skip ::
                if (i < cap.end_pos) path = ctx.tokens[i].text;
            } else {
                path = tok.text;
            }
        } else if (tok.kind == .kw_as) {
            i += 1;
            if (i < cap.end_pos) alias = ctx.tokens[i].text;
        }
    }

    return ctx.newNode(.{ .import_decl = .{
        .path = path,
        .scope = scope,
        .alias = alias,
        .is_c_header = is_c_header,
        .is_include = is_include,
    } });
}

fn buildMetadata(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // metadata <- '#' metadata_body NL
    // metadata_body <- 'dep' expr expr? / 'linkC' expr / IDENTIFIER '=' expr
    const field_pos = cap.start_pos + 1; // after #
    const field = tokenText(ctx, field_pos);

    // Build value from first expr child
    if (cap.children.len > 0) {
        const value = try buildNode(ctx, &cap.children[0]);
        var extra: ?*Node = null;
        if (cap.children.len > 1) {
            extra = try buildNode(ctx, &cap.children[1]);
        }
        return ctx.newNode(.{ .metadata = .{ .field = field, .value = value, .extra = extra } });
    }

    // Fallback — create a dummy value
    const dummy = try ctx.newNode(.{ .identifier = field });
    return ctx.newNode(.{ .metadata = .{ .field = field, .value = dummy } });
}

// ============================================================
// DECLARATION BUILDERS
// ============================================================

fn buildFuncDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // func_decl <- 'func' func_name '(' _ param_list _ ')' type (block / TERM)
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        const name_pos = fn_cap.start_pos;
        name = tokenText(ctx, name_pos);
    }

    // Params may be nested inside param_list
    var params_list = std.ArrayListUnmanaged(*Node){};
    try collectParamsRecursive(ctx, cap, &params_list);
    const params = try params_list.toOwnedSlice(ctx.alloc());

    const ret_type = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = params,
        .return_type = ret_type,
        .body = body,
        .is_compt = false,
        .is_pub = false,
        .is_bridge = false,
        .is_thread = false,
    } });
}

fn buildParam(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // param <- param_name ':' type ('=' expr)?
    var name: []const u8 = "";
    if (cap.findChild("param_name")) |pn| {
        name = tokenText(ctx, pn.start_pos);
    }

    const type_ann = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    var default: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        default = try buildNode(ctx, e);
    }

    return ctx.newNode(.{ .param = .{
        .name = name,
        .type_annotation = type_ann,
        .default_value = default,
    } });
}

fn buildConstDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // const_decl <- 'const' IDENTIFIER destruct_tail TERM
    //            / 'const' IDENTIFIER (':' type)? '=' expr TERM

    // Check for destructuring: const a, b = expr
    if (cap.findChild("destruct_tail")) |dt| {
        return buildDestructFromTail(ctx, cap, dt, true);
    }

    const name_pos = cap.start_pos + 1; // after 'const'
    const name = tokenText(ctx, name_pos);

    var type_ann: ?*Node = null;
    if (cap.findChild("type")) |t| {
        type_ann = try buildNode(ctx, t);
    }

    const value = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else try ctx.newNode(.{ .int_literal = "0" });

    return ctx.newNode(.{ .const_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .value = value,
        .is_pub = false,
    } });
}

fn buildVarDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // Check for destructuring: var a, b = expr
    if (cap.findChild("destruct_tail")) |dt| {
        return buildDestructFromTail(ctx, cap, dt, false);
    }

    const name_pos = cap.start_pos + 1;
    const name = tokenText(ctx, name_pos);

    var type_ann: ?*Node = null;
    if (cap.findChild("type")) |t| {
        type_ann = try buildNode(ctx, t);
    }

    const value = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else try ctx.newNode(.{ .int_literal = "0" });

    return ctx.newNode(.{ .var_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .value = value,
        .is_pub = false,
    } });
}

fn buildStructDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // struct_decl <- 'struct' IDENTIFIER generic_params? '{' _ struct_body _ '}'
    const name_pos = cap.start_pos + 1;
    const name = tokenText(ctx, name_pos);

    var type_params_list = std.ArrayListUnmanaged(*Node){};
    var members = std.ArrayListUnmanaged(*Node){};

    // Walk children recursively to find params (from generic_params) and members
    try collectStructParts(ctx, cap, &type_params_list, &members);

    return ctx.newNode(.{ .struct_decl = .{
        .name = name,
        .type_params = try type_params_list.toOwnedSlice(ctx.alloc()),
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

fn collectStructParts(ctx: *BuildContext, cap: *const CaptureNode, type_params: *std.ArrayListUnmanaged(*Node), members: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            // Terminal declaration nodes — build and add as members
            if (std.mem.eql(u8, r, "field_decl") or
                std.mem.eql(u8, r, "func_decl") or
                std.mem.eql(u8, r, "compt_decl") or
                std.mem.eql(u8, r, "const_decl") or
                std.mem.eql(u8, r, "var_decl") or
                std.mem.eql(u8, r, "bridge_decl") or
                std.mem.eql(u8, r, "bridge_func") or
                std.mem.eql(u8, r, "bridge_const"))
            {
                const node = try buildNode(ctx, child);
                if (hasPubBefore(ctx, cap, child.start_pos)) setPub(node, true);
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "pub_decl")) {
                try members.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "generic_params") or std.mem.eql(u8, r, "param_list")) {
                // Only collect params from generic_params context (not from functions)
                try collectParamsRecursive(ctx, child, type_params);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "doc_block") or std.mem.eql(u8, r, "type")) {
                // skip
            } else {
                // Recurse into wrapper rules (struct_body, struct_member, bridge_struct_body, etc.)
                // but NOT into declarations (which have their own params)
                try collectStructParts(ctx, child, type_params, members);
            }
        }
    }
}

/// Check if there's a 'pub' token in the capture range before the given position
fn hasPubBefore(ctx: *BuildContext, cap: *const CaptureNode, before_pos: usize) bool {
    var i = cap.start_pos;
    while (i < before_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .kw_pub) return true;
    }
    return false;
}

fn buildEnumDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // enum_decl <- 'enum' '(' type ')' IDENTIFIER '{' _ enum_body _ '}'
    const backing = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "u8" });

    // Name is the identifier after ')'
    var name: []const u8 = "";
    for (cap.start_pos..cap.end_pos) |i| {
        if (i > 0 and i < ctx.tokens.len and ctx.tokens[i].kind == .identifier and ctx.tokens[i - 1].kind == .rparen) {
            name = ctx.tokens[i].text;
            break;
        }
    }

    var members = std.ArrayListUnmanaged(*Node){};
    try collectEnumMembers(ctx, cap, &members);

    return ctx.newNode(.{ .enum_decl = .{
        .name = name,
        .backing_type = backing,
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

fn collectEnumMembers(ctx: *BuildContext, cap: *const CaptureNode, members: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "enum_variant") or std.mem.eql(u8, r, "func_decl") or std.mem.eql(u8, r, "pub_decl")) {
                const node = try buildNode(ctx, child);
                if (hasPubBefore(ctx, cap, child.start_pos)) setPub(node, true);
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "doc_block") or std.mem.eql(u8, r, "type")) {
                // skip
            } else {
                try collectEnumMembers(ctx, child, members);
            }
        }
    }
}

fn buildFieldDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // field_decl <- IDENTIFIER ':' type ('=' expr)? TERM
    const name = tokenText(ctx, cap.start_pos);
    const type_ann = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    var default: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        default = try buildNode(ctx, e);
    }
    return ctx.newNode(.{ .field_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .default_value = default,
        .is_pub = false,
    } });
}

fn buildEnumVariant(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = tokenText(ctx, cap.start_pos);
    const fields = try buildChildrenByRule(ctx, cap, "param");
    return ctx.newNode(.{ .enum_variant = .{ .name = name, .fields = fields } });
}

fn buildDestructDecl(_: *BuildContext, _: *const CaptureNode) !*Node {
    return error.DestructNotReached; // handled by buildDestructFromTail
}

fn buildDestructFromTail(ctx: *BuildContext, cap: *const CaptureNode, dt: *const CaptureNode, is_const: bool) !*Node {
    // destruct_tail <- (',' IDENTIFIER)+ '=' expr
    // First name is after 'const'/'var' keyword
    const first_name = tokenText(ctx, cap.start_pos + 1);
    var names = std.ArrayListUnmanaged([]const u8){};
    try names.append(ctx.alloc(), first_name);
    // Collect additional names from comma-separated identifiers in destruct_tail (before '=')
    for (dt.start_pos..dt.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .assign) break;
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .identifier) {
            try names.append(ctx.alloc(), ctx.tokens[i].text);
        }
    }
    // Value is the expr child
    var value: *Node = try ctx.newNode(.{ .int_literal = "0" });
    if (dt.findChild("expr")) |e| {
        value = try buildNode(ctx, e);
    } else {
        // expr might be a sibling of destruct_tail in the const_decl capture
        if (cap.findChild("expr")) |e| {
            value = try buildNode(ctx, e);
        }
    }
    return ctx.newNode(.{ .destruct_decl = .{
        .names = try names.toOwnedSlice(ctx.alloc()),
        .is_const = is_const,
        .value = value,
    } });
}

fn buildBitfieldDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bitfield_decl <- 'bitfield' '(' type ')' IDENTIFIER '{' _ bitfield_body _ '}'
    const backing = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "u32" });

    // Name is the identifier after ')'
    var name: []const u8 = "";
    for (cap.start_pos..cap.end_pos) |i| {
        if (i > 0 and i < ctx.tokens.len and ctx.tokens[i].kind == .identifier and ctx.tokens[i - 1].kind == .rparen) {
            name = ctx.tokens[i].text;
            break;
        }
    }

    // Collect flag names (just identifiers inside the body)
    var members = std.ArrayListUnmanaged([]const u8){};
    // Find the lbrace, then collect identifiers until rbrace
    var in_body = false;
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len) {
            if (ctx.tokens[i].kind == .lbrace) { in_body = true; continue; }
            if (ctx.tokens[i].kind == .rbrace) break;
            if (in_body and ctx.tokens[i].kind == .identifier) {
                try members.append(ctx.alloc(), ctx.tokens[i].text);
            }
        }
    }

    return ctx.newNode(.{ .bitfield_decl = .{
        .name = name,
        .backing_type = backing,
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
}

fn buildTestDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // test_decl <- 'test' STRING_LITERAL block
    var desc: []const u8 = "";
    if (findTokenInRange(ctx, cap.start_pos, cap.end_pos, .string_literal)) |pos| {
        desc = tokenText(ctx, pos);
    }
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });
    return ctx.newNode(.{ .test_decl = .{ .description = desc, .body = body } });
}

// ============================================================
// CONTEXT FLAG BUILDERS
// ============================================================

fn buildPubDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // pub_decl <- 'pub' (func_decl / struct_decl / ...)
    // Build the child, then set is_pub = true
    for (cap.children) |*child| {
        if (child.rule) |_| {
            const node = try buildNode(ctx, child);
            setPub(node, true);
            return node;
        }
    }
    return error.NoPubChild;
}

fn buildComptDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compt_decl <- 'compt' func_decl
    if (cap.findChild("func_decl")) |child| {
        const node = try buildNode(ctx, child);
        if (node.* == .func_decl) node.func_decl.is_compt = true;
        return node;
    }
    return error.NoComptChild;
}

fn buildBridgeDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_decl <- 'bridge' (bridge_func / bridge_const / bridge_struct)
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "bridge_func") or
                std.mem.eql(u8, r, "bridge_const") or
                std.mem.eql(u8, r, "bridge_struct"))
            {
                return buildNode(ctx, child);
            }
        }
    }
    return error.NoBridgeChild;
}

fn buildBridgeFunc(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_func <- 'func' func_name '(' _ param_list _ ')' type TERM
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        name = tokenText(ctx, fn_cap.start_pos);
    }
    var params_list = std.ArrayListUnmanaged(*Node){};
    try collectParamsRecursive(ctx, cap, &params_list);
    const ret_type = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = ret_type,
        .body = try ctx.newNode(.{ .block = .{ .statements = &.{} } }),
        .is_compt = false,
        .is_pub = false,
        .is_bridge = true,
        .is_thread = false,
    } });
}

fn buildBridgeConst(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_const <- 'const' IDENTIFIER ':' type TERM
    const name = tokenText(ctx, cap.start_pos + 1);
    const type_ann = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "any" });
    return ctx.newNode(.{ .const_decl = .{
        .name = name,
        .type_annotation = type_ann,
        .value = try ctx.newNode(.{ .int_literal = "0" }),
        .is_pub = false,
        .is_bridge = true,
    } });
}

fn buildBridgeStruct(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // bridge_struct <- 'struct' IDENTIFIER generic_params? ('{' _ bridge_struct_body _ '}' / TERM)
    const name = tokenText(ctx, cap.start_pos + 1);
    var type_params_list = std.ArrayListUnmanaged(*Node){};
    var members = std.ArrayListUnmanaged(*Node){};
    try collectStructParts(ctx, cap, &type_params_list, &members);
    return ctx.newNode(.{ .struct_decl = .{
        .name = name,
        .type_params = try type_params_list.toOwnedSlice(ctx.alloc()),
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
        .is_bridge = true,
    } });
}

fn buildThreadDecl(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // thread_decl <- 'thread' func_name '(' _ param_list _ ')' type block
    var name: []const u8 = "";
    if (cap.findChild("func_name")) |fn_cap| {
        name = tokenText(ctx, fn_cap.start_pos);
    }
    var params_list = std.ArrayListUnmanaged(*Node){};
    try collectParamsRecursive(ctx, cap, &params_list);
    const ret_type = if (cap.findChild("type")) |t| try buildNode(ctx, t) else try ctx.newNode(.{ .type_named = "void" });
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else try ctx.newNode(.{ .block = .{ .statements = &.{} } });

    return ctx.newNode(.{ .func_decl = .{
        .name = name,
        .params = try params_list.toOwnedSlice(ctx.alloc()),
        .return_type = ret_type,
        .body = body,
        .is_compt = false,
        .is_pub = false,
        .is_bridge = false,
        .is_thread = true,
    } });
}

fn setPub(node: *Node, value: bool) void {
    switch (node.*) {
        .func_decl => |*d| d.is_pub = value,
        .struct_decl => |*d| d.is_pub = value,
        .enum_decl => |*d| d.is_pub = value,
        .bitfield_decl => |*d| d.is_pub = value,
        .const_decl => |*d| d.is_pub = value,
        .var_decl => |*d| d.is_pub = value,
        .field_decl => |*d| d.is_pub = value,
        else => {},
    }
}

// ============================================================
// STATEMENT BUILDERS
// ============================================================

fn buildBlock(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // block <- '{' _ statement* _ '}'
    var stmts = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "statement")) {
                // statement is transparent — build its actual content child
                for (child.children) |*sc| {
                    if (sc.rule) |sr| {
                        // Skip whitespace/newline rules
                        if (std.mem.eql(u8, sr, "_") or std.mem.eql(u8, sr, "TERM")) continue;
                        try stmts.append(ctx.alloc(), try buildNode(ctx, sc));
                    }
                }
            }
            // Skip _ rules at block level
        }
    }
    return ctx.newNode(.{ .block = .{ .statements = try stmts.toOwnedSlice(ctx.alloc()) } });
}

fn buildReturn(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    var value: ?*Node = null;
    if (cap.findChild("expr")) |e| {
        value = try buildNode(ctx, e);
    }
    return ctx.newNode(.{ .return_stmt = .{ .value = value } });
}

fn buildIf(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // if_stmt <- 'if' '(' expr ')' block elif_chain?
    const condition = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else return error.NoCondition;
    const then_block = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    var else_block: ?*Node = null;
    if (cap.findChild("elif_chain")) |chain| {
        else_block = try buildNode(ctx, chain);
    }
    return ctx.newNode(.{ .if_stmt = .{
        .condition = condition,
        .then_block = then_block,
        .else_block = else_block,
    } });
}

fn buildWhile(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const condition = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else return error.NoCondition;
    var continue_expr: ?*Node = null;
    if (cap.findChild("assign_expr")) |ae| {
        continue_expr = try buildNode(ctx, ae);
    }
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .while_stmt = .{
        .condition = condition,
        .continue_expr = continue_expr,
        .body = body,
    } });
}

fn buildFor(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const iterable = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else return error.NoIterable;
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;

    // Extract captures from for_captures child
    var captures = std.ArrayListUnmanaged([]const u8){};
    if (cap.findChild("for_captures")) |fc| {
        for (fc.start_pos..fc.end_pos) |i| {
            if (i < ctx.tokens.len and ctx.tokens[i].kind == .identifier) {
                try captures.append(ctx.alloc(), ctx.tokens[i].text);
            }
        }
    }
    // If two captures, the second is the index variable
    var index_var: ?[]const u8 = null;
    if (captures.items.len >= 2) {
        index_var = captures.pop();
    }
    return ctx.newNode(.{ .for_stmt = .{
        .iterable = iterable,
        .captures = try captures.toOwnedSlice(ctx.alloc()),
        .index_var = index_var,
        .body = body,
        .is_compt = false,
        .is_tuple_capture = false,
    } });
}

fn buildDefer(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .defer_stmt = .{ .body = body } });
}

fn buildMatch(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const value = if (cap.findChild("expr")) |e| try buildNode(ctx, e) else return error.NoMatchValue;
    const arms = try buildChildrenByRule(ctx, cap, "match_arm");
    return ctx.newNode(.{ .match_stmt = .{ .value = value, .arms = arms } });
}

fn buildMatchArm(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const pattern = if (cap.findChild("match_pattern")) |mp| try buildNode(ctx, mp) else return error.NoPattern;
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .body = body } });
}

fn buildExprOrAssignment(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // expr_or_assignment <- expr assign_op expr TERM / expr TERM
    // Check if there's an assign_op child
    if (cap.findChild("assign_op")) |_| {
        // Assignment: expr assign_op expr
        var exprs = std.ArrayListUnmanaged(*const CaptureNode){};
        for (cap.children) |*child| {
            if (child.rule) |r| {
                if (std.mem.eql(u8, r, "expr")) {
                    try exprs.append(ctx.alloc(), child);
                }
            }
        }
        if (exprs.items.len >= 2) {
            const lhs = try buildNode(ctx, exprs.items[0]);
            const rhs = try buildNode(ctx, exprs.items[1]);
            // Find the operator token
            var op: []const u8 = "=";
            for (cap.children) |*child| {
                if (child.rule) |r| {
                    if (std.mem.eql(u8, r, "assign_op")) {
                        op = tokenText(ctx, child.start_pos);
                        break;
                    }
                }
            }
            return ctx.newNode(.{ .assignment = .{ .op = op, .left = lhs, .right = rhs } });
        }
    }

    // Plain expression
    if (cap.findChild("expr")) |e| return buildNode(ctx, e);
    return error.NoExpr;
}

// ============================================================
// EXPRESSION BUILDERS
// ============================================================

fn buildIntLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .int_literal = tokenText(ctx, cap.start_pos) });
}

fn buildFloatLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .float_literal = tokenText(ctx, cap.start_pos) });
}

fn buildStringLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .string_literal = tokenText(ctx, cap.start_pos) });
}

fn buildBoolLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const tok = ctx.tokens[cap.start_pos];
    return ctx.newNode(.{ .bool_literal = tok.kind == .kw_true });
}

fn buildIdentifier(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .identifier = tokenText(ctx, cap.start_pos) });
}

fn buildErrorLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // error_literal <- 'Error' '(' STRING_LITERAL ')'
    if (findTokenInRange(ctx, cap.start_pos, cap.end_pos, .string_literal)) |pos| {
        return ctx.newNode(.{ .error_literal = tokenText(ctx, pos) });
    }
    return ctx.newNode(.{ .error_literal = "" });
}

fn buildCompilerFunc(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compiler_func <- compiler_func_name '(' _ arg_list _ ')'
    var name: []const u8 = "";
    if (cap.findChild("compiler_func_name")) |cn| {
        name = tokenText(ctx, cn.start_pos);
    }
    var args_list = std.ArrayListUnmanaged(*Node){};
    try collectExprsRecursive(ctx, cap, &args_list);
    return ctx.newNode(.{ .compiler_func = .{ .name = name, .args = try args_list.toOwnedSlice(ctx.alloc()) } });
}

fn buildArrayLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const items = try buildChildrenByRule(ctx, cap, "expr");
    return ctx.newNode(.{ .array_literal = items });
}

fn buildGroupedExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // grouped_expr <- '(' _ expr _ ')'
    if (cap.findChild("expr")) |e| return buildNode(ctx, e);
    return error.NoExpr;
}

fn buildTupleLiteral(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // tuple_literal <- '(' _ IDENTIFIER ':' expr (_ ',' _ IDENTIFIER ':' expr)* _ ')'
    var names = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged(*Node){};
    var i = cap.start_pos + 1; // skip (
    while (i < cap.end_pos) : (i += 1) {
        const tok = ctx.tokens[i];
        if (tok.kind == .identifier and i + 1 < cap.end_pos and ctx.tokens[i + 1].kind == .colon) {
            try names.append(ctx.alloc(), tok.text);
            // Find and build the corresponding expr
            for (cap.children) |*child| {
                if (child.rule) |r| {
                    if (std.mem.eql(u8, r, "expr") and child.start_pos > i) {
                        try values.append(ctx.alloc(), try buildNode(ctx, child));
                        break;
                    }
                }
            }
        }
    }
    return ctx.newNode(.{ .tuple_literal = .{
        .is_named = true,
        .fields = try values.toOwnedSlice(ctx.alloc()),
        .field_names = try names.toOwnedSlice(ctx.alloc()),
    } });
}

fn buildStructExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // struct_expr <- 'struct' '{' _ (('pub')? field_decl _)* _ '}'
    var fields = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "field_decl")) {
                const node = try buildNode(ctx, child);
                if (hasPubBefore(ctx, cap, child.start_pos)) setPub(node, true);
                try fields.append(ctx.alloc(), node);
            }
        }
    }
    return ctx.newNode(.{ .struct_type = try fields.toOwnedSlice(ctx.alloc()) });
}

/// Binary expression builder — handles the left-associative precedence tower.
/// Grammar: left_operand (OP right_operand)*
fn buildBinaryExpr(ctx: *BuildContext, cap: *const CaptureNode, _: []const u8) !*Node {
    // The children are the operand sub-rules (e.g., and_expr children for or_expr)
    if (cap.children.len == 0) return error.NoBinaryChildren;
    if (cap.children.len == 1) return buildNode(ctx, &cap.children[0]);

    // Multiple children — build left-associative chain
    // The operator is the token between children
    var left = try buildNode(ctx, &cap.children[0]);
    var i: usize = 1;
    while (i < cap.children.len) : (i += 1) {
        // Find operator token between prev child end and this child start
        const prev_end = cap.children[i - 1].end_pos;
        const next_start = cap.children[i].start_pos;
        var op: []const u8 = "+";
        var j = prev_end;
        while (j < next_start) : (j += 1) {
            const tok = ctx.tokens[j];
            if (tok.kind != .newline) {
                op = tok.text;
                break;
            }
        }
        const right = try buildNode(ctx, &cap.children[i]);
        left = try ctx.newNode(.{ .binary_expr = .{ .op = op, .left = left, .right = right } });
    }
    return left;
}

fn buildCompareExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // compare_expr <- bitor_expr compare_op bitor_expr / bitor_expr 'is' 'not'? (IDENTIFIER / 'null') / bitor_expr

    // Check for 'is' type check
    if (findTokenInRange(ctx, cap.start_pos, cap.end_pos, .kw_is)) |is_pos| {
        // Find the operand (everything before 'is')
        var operands = std.ArrayListUnmanaged(*const CaptureNode){};
        for (cap.children) |*child| {
            if (child.rule) |r| {
                if (!std.mem.eql(u8, r, "compare_op") and
                    !std.mem.eql(u8, r, "_") and
                    !std.mem.eql(u8, r, "TERM"))
                {
                    operands.append(ctx.alloc(), child) catch {};
                }
            }
        }
        if (operands.items.len > 0) {
            const expr_node = try buildNode(ctx, operands.items[0]);
            // Build: type(expr) == TypeName / type(expr) != TypeName
            const args = try ctx.alloc().alloc(*Node, 1);
            args[0] = expr_node;
            const type_call = try ctx.newNode(.{ .compiler_func = .{ .name = "type", .args = args } });

            // Check for 'not' after 'is'
            const negated = is_pos + 1 < cap.end_pos and ctx.tokens[is_pos + 1].kind == .kw_not;
            const cmp_op: []const u8 = if (negated) "!=" else "==";

            // Find the type name (last identifier or null keyword)
            var rhs: *Node = try ctx.newNode(.{ .identifier = "unknown" });
            var j = if (negated) is_pos + 2 else is_pos + 1;
            while (j < cap.end_pos) : (j += 1) {
                if (ctx.tokens[j].kind == .identifier) {
                    rhs = try ctx.newNode(.{ .identifier = ctx.tokens[j].text });
                    break;
                } else if (ctx.tokens[j].kind == .kw_null) {
                    rhs = try ctx.newNode(.{ .null_literal = {} });
                    break;
                }
            }
            return ctx.newNode(.{ .binary_expr = .{ .op = cmp_op, .left = type_call, .right = rhs } });
        }
    }

    // Regular comparison: bitor_expr compare_op bitor_expr
    var operands = std.ArrayListUnmanaged(*const CaptureNode){};
    var op: []const u8 = "==";
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "compare_op")) {
                op = tokenText(ctx, child.start_pos);
            } else if (!std.mem.eql(u8, r, "_") and !std.mem.eql(u8, r, "TERM")) {
                operands.append(ctx.alloc(), child) catch {};
            }
        }
    }
    if (operands.items.len <= 1) {
        if (operands.items.len == 1) return buildNode(ctx, operands.items[0]);
        if (cap.children.len > 0) return buildNode(ctx, &cap.children[0]);
        return error.NoCompareChildren;
    }
    const left = try buildNode(ctx, operands.items[0]);
    const right = try buildNode(ctx, operands.items[1]);
    return ctx.newNode(.{ .binary_expr = .{ .op = op, .left = left, .right = right } });
}

fn buildRangeExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.children.len <= 1) {
        if (cap.children.len == 1) return buildNode(ctx, &cap.children[0]);
        return error.NoRangeChildren;
    }
    const left = try buildNode(ctx, &cap.children[0]);
    const right = try buildNode(ctx, &cap.children[1]);
    return ctx.newNode(.{ .range_expr = .{ .op = "..", .left = left, .right = right } });
}

fn buildNotExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // not_expr <- 'not' not_expr / compare_expr
    if (ctx.tokens[cap.start_pos].kind == .kw_not) {
        const operand = if (cap.children.len > 0) try buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .unary_expr = .{ .op = "not", .operand = operand } });
    }
    if (cap.children.len > 0) return buildNode(ctx, &cap.children[0]);
    return error.NoNotChildren;
}

fn buildUnaryExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // unary_expr <- '!' unary_expr / '&' unary_expr / postfix_expr
    const first_tok = ctx.tokens[cap.start_pos];
    if (first_tok.kind == .bang) {
        const operand = if (cap.children.len > 0) try buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .unary_expr = .{ .op = "!", .operand = operand } });
    }
    if (first_tok.kind == .ampersand) {
        const operand = if (cap.children.len > 0) try buildNode(ctx, &cap.children[0]) else return error.NoOperand;
        return ctx.newNode(.{ .borrow_expr = operand });
    }
    if (cap.children.len > 0) return buildNode(ctx, &cap.children[0]);
    return error.NoUnaryChildren;
}

fn buildPostfixExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // postfix_expr <- primary_expr (method_call / field_access / slice_access / index_access / call_access)*
    if (cap.children.len == 0) return error.NoPostfixChildren;

    var expr = try buildNode(ctx, &cap.children[0]);

    var i: usize = 1;
    while (i < cap.children.len) : (i += 1) {
        const child = &cap.children[i];
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "method_call")) {
                // method_call <- '.' IDENTIFIER '(' _ arg_list _ ')'
                const field_name = tokenText(ctx, child.start_pos + 1); // after '.'
                var args_list = std.ArrayListUnmanaged(*Node){};
                try collectExprsRecursive(ctx, child, &args_list);
                const field_access = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
                expr = try ctx.newNode(.{ .call_expr = .{ .callee = field_access, .args = try args_list.toOwnedSlice(ctx.alloc()), .arg_names = &.{} } });
            } else if (std.mem.eql(u8, r, "field_access")) {
                const field_name = tokenText(ctx, child.start_pos + 1);
                expr = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
            } else if (std.mem.eql(u8, r, "call_access")) {
                var args_list = std.ArrayListUnmanaged(*Node){};
                var names_list = std.ArrayListUnmanaged([]const u8){};
                var has_names = false;
                try collectCallArgs(ctx, child, &args_list, &names_list, &has_names);
                expr = try ctx.newNode(.{ .call_expr = .{
                    .callee = expr,
                    .args = try args_list.toOwnedSlice(ctx.alloc()),
                    .arg_names = if (has_names) try names_list.toOwnedSlice(ctx.alloc()) else &.{},
                } });
            } else if (std.mem.eql(u8, r, "index_access")) {
                if (child.findChild("or_expr")) |ie| {
                    const index = try buildNode(ctx, ie);
                    expr = try ctx.newNode(.{ .index_expr = .{ .object = expr, .index = index } });
                }
            } else if (std.mem.eql(u8, r, "slice_access")) {
                if (child.children.len >= 2) {
                    const low = try buildNode(ctx, &child.children[0]);
                    const high = try buildNode(ctx, &child.children[1]);
                    expr = try ctx.newNode(.{ .slice_expr = .{ .object = expr, .low = low, .high = high } });
                }
            }
        }
    }

    return expr;
}

/// Build ptr_cast_expr: Ptr(T).cast(addr) / RawPtr(T).cast(addr) / VolatilePtr(T).cast(addr)
/// Grammar: ('Ptr' / 'RawPtr' / 'VolatilePtr') '(' type ')' '.' 'cast' '(' expr ')'
/// Produces a ptr_expr node — same as the classic Ptr(T, addr) syntax.
fn buildPtrCastExpr(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const kind = tokenText(ctx, cap.start_pos);
    var type_arg: ?*Node = null;
    var addr_arg: ?*Node = null;
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type") and type_arg == null) {
                type_arg = try buildNode(ctx, child);
            } else if (std.mem.eql(u8, r, "expr") and addr_arg == null) {
                addr_arg = try buildNode(ctx, child);
            }
        }
    }
    const t = type_arg orelse return error.MissingTypeArg;
    var addr = addr_arg orelse return error.MissingAddrArg;
    // PEG may parse &x as ref_type (type_ptr) in some contexts — convert to borrow_expr
    if (addr.* == .type_ptr) {
        addr = try ctx.newNode(.{ .borrow_expr = addr.type_ptr.elem });
    }
    return ctx.newNode(.{ .ptr_expr = .{
        .kind = kind,
        .type_arg = t,
        .addr_arg = addr,
    } });
}

// ============================================================
// TYPE BUILDERS
// ============================================================

fn buildNamedType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .type_named = tokenText(ctx, cap.start_pos) });
}

fn buildKeywordType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .type_named = tokenText(ctx, cap.start_pos) });
}

fn buildGenericType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = tokenText(ctx, cap.start_pos);
    // Collect type/expr args from generic_arg_list -> type_or_expr -> type/expr
    var args_list = std.ArrayListUnmanaged(*Node){};
    try collectGenericArgs(ctx, cap, &args_list);
    // Pointer constructors: RawPtr(T, &x), SafePtr(T, &x), VolatilePtr(T, &x), Ptr(T, &x)
    const is_ptr = std.mem.eql(u8, name, "RawPtr") or std.mem.eql(u8, name, "SafePtr") or
        std.mem.eql(u8, name, "VolatilePtr") or std.mem.eql(u8, name, "Ptr");
    if (is_ptr and args_list.items.len == 2) {
        // PEG parses &x as ref_type (type_ptr) in type_or_expr context — convert to borrow_expr
        var addr = args_list.items[1];
        if (addr.* == .type_ptr) {
            addr = try ctx.newNode(.{ .borrow_expr = addr.type_ptr.elem });
        }
        return ctx.newNode(.{ .ptr_expr = .{
            .kind = name,
            .type_arg = args_list.items[0],
            .addr_arg = addr,
        } });
    }
    return ctx.newNode(.{ .type_generic = .{ .name = name, .args = try args_list.toOwnedSlice(ctx.alloc()) } });
}

fn collectGenericArgs(ctx: *BuildContext, cap: *const CaptureNode, out: *std.ArrayListUnmanaged(*Node)) anyerror!void {
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type") or std.mem.eql(u8, r, "expr")) {
                try out.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM")) {
                // skip
            } else {
                // Recurse into generic_arg_list, type_or_expr wrappers
                try collectGenericArgs(ctx, child, out);
            }
        }
    }
}

fn buildBorrowType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // borrow_type <- 'const' '&' type
    if (cap.findChild("type")) |t| {
        const inner = try buildNode(ctx, t);
        return ctx.newNode(.{ .type_ptr = .{ .kind = "const &", .elem = inner } });
    }
    return error.NoBorrowInner;
}

fn buildRefType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // ref_type <- '&' type
    if (cap.findChild("type")) |t| {
        const inner = try buildNode(ctx, t);
        return ctx.newNode(.{ .type_ptr = .{ .kind = "var &", .elem = inner } });
    }
    return error.NoRefInner;
}

fn buildParenType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // paren_type <- '(' ')' / '(' IDENTIFIER ':' type ... ')' / '(' type ('|' type)+ ')' / '(' type ')'
    // Check for void: ()
    if (cap.end_pos - cap.start_pos <= 2) return ctx.newNode(.{ .type_named = "void" });

    // Collect type children
    var type_children = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type")) {
                try type_children.append(ctx.alloc(), try buildNode(ctx, child));
            }
        }
    }

    // Check for named tuple: IDENTIFIER ':' type pattern (not union with '|')
    var named_fields = std.ArrayListUnmanaged(parser.NamedTypeField){};
    var type_idx: usize = 0;
    var i = cap.start_pos;
    while (i + 1 < cap.end_pos and i + 1 < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .identifier and ctx.tokens[i + 1].kind == .colon) {
            if (type_idx < type_children.items.len) {
                try named_fields.append(ctx.alloc(), .{
                    .name = ctx.tokens[i].text,
                    .type_node = type_children.items[type_idx],
                    .default = null,
                });
                type_idx += 1;
            }
        }
    }
    if (named_fields.items.len > 0 and named_fields.items.len == type_children.items.len) {
        return ctx.newNode(.{ .type_tuple_named = try named_fields.toOwnedSlice(ctx.alloc()) });
    }

    // Union: multiple type children with | separators
    if (type_children.items.len > 1) {
        return ctx.newNode(.{ .type_union = try type_children.toOwnedSlice(ctx.alloc()) });
    }
    if (type_children.items.len == 1) return type_children.items[0];

    return ctx.newNode(.{ .type_named = "void" });
}

fn buildSliceType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.findChild("type")) |t| {
        const elem = try buildNode(ctx, t);
        return ctx.newNode(.{ .type_slice = elem });
    }
    return error.NoSliceElem;
}

fn buildArrayType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    if (cap.findChild("expr")) |size_cap| {
        if (cap.findChild("type")) |type_cap| {
            const size = try buildNode(ctx, size_cap);
            const elem = try buildNode(ctx, type_cap);
            return ctx.newNode(.{ .type_array = .{ .size = size, .elem = elem } });
        }
    }
    return error.NoArrayComponents;
}

fn buildFuncType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // func_type <- 'func' '(' _ type_list _ ')' type
    var params = std.ArrayListUnmanaged(*Node){};
    // Collect param types from type_list child, plus return type (direct type child)
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type_list")) {
                // Param types are nested inside type_list
                for (child.children) |*tc| {
                    if (tc.rule) |tr| {
                        if (std.mem.eql(u8, tr, "type")) {
                            try params.append(ctx.alloc(), try buildNode(ctx, tc));
                        }
                    }
                }
            } else if (std.mem.eql(u8, r, "type")) {
                try params.append(ctx.alloc(), try buildNode(ctx, child));
            }
        }
    }
    // Last type is the return type
    if (params.items.len > 0) {
        const ret = params.items[params.items.len - 1];
        params.items.len -= 1;
        return ctx.newNode(.{ .type_func = .{
            .params = try params.toOwnedSlice(ctx.alloc()),
            .ret = ret,
        } });
    }
    return error.NoFuncTypeReturn;
}

// ============================================================
// TESTS
// ============================================================

test "builder - build minimal program AST" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init("module main\n");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    var result = try buildAST(&cap, tokens.items, std.heap.page_allocator);
    defer result.ctx.deinit();

    try std.testing.expect(result.node.* == .program);
    try std.testing.expectEqualStrings("main", result.node.program.module.module_decl.name);
}

test "builder - build program with function" {
    const alloc = std.testing.allocator;
    const peg = @import("../peg.zig");

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init(
        \\module main
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
    try std.testing.expectEqualStrings("main", prog.module.module_decl.name);
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
        \\module main
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
