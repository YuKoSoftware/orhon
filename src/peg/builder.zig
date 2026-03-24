// builder.zig — Transforms PEG capture trees into parser.Node AST nodes
//
// Each grammar rule that produces an AST node has a builder function.
// Rules not in the dispatch table are "transparent" — the builder
// recurses into their single child.

const std = @import("std");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const capture_mod = @import("capture.zig");
const CaptureNode = capture_mod.CaptureNode;
const Node = parser.Node;
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

// ============================================================
// BUILD CONTEXT
// ============================================================

pub const BuildContext = struct {
    tokens: []const Token,
    arena: std.heap.ArenaAllocator,

    pub fn init(tokens: []const Token, backing_allocator: std.mem.Allocator) BuildContext {
        return .{
            .tokens = tokens,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *BuildContext) void {
        self.arena.deinit();
    }

    fn alloc(self: *BuildContext) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn newNode(self: *BuildContext, node: Node) !*Node {
        const n = try self.alloc().create(Node);
        n.* = node;
        return n;
    }
};

// ============================================================
// PUBLIC API
// ============================================================

/// Build an AST from a capture tree.
pub fn buildAST(cap: *const CaptureNode, tokens: []const Token, allocator: std.mem.Allocator) !struct { node: *Node, ctx: BuildContext } {
    var ctx = BuildContext.init(tokens, allocator);
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
    if (std.mem.eql(u8, rule, "test_decl")) return buildTestDecl(ctx, cap);
    if (std.mem.eql(u8, rule, "import_decl")) return buildImport(ctx, cap);
    if (std.mem.eql(u8, rule, "metadata")) return buildMetadata(ctx, cap);
    if (std.mem.eql(u8, rule, "expr_or_assignment")) return buildExprOrAssignment(ctx, cap);

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
    // Same structure as const_decl
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
            if (std.mem.eql(u8, r, "field_decl") or
                std.mem.eql(u8, r, "func_decl") or
                std.mem.eql(u8, r, "compt_decl") or
                std.mem.eql(u8, r, "const_decl") or
                std.mem.eql(u8, r, "var_decl"))
            {
                const node = try buildNode(ctx, child);
                // Check if parent (struct_member) has a pub token before this child
                if (hasPubBefore(ctx, cap, child.start_pos)) setPub(node, true);
                try members.append(ctx.alloc(), node);
            } else if (std.mem.eql(u8, r, "pub_decl")) {
                try members.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "param")) {
                try type_params.append(ctx.alloc(), try buildNode(ctx, child));
            } else if (std.mem.eql(u8, r, "_") or std.mem.eql(u8, r, "TERM") or std.mem.eql(u8, r, "doc_block")) {
                // skip
            } else {
                // Recurse into wrapper rules (struct_body, struct_member, generic_params, etc.)
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
        if (i > 0 and ctx.tokens[i].kind == .identifier and ctx.tokens[i - 1].kind == .rparen) {
            name = ctx.tokens[i].text;
            break;
        }
    }

    var members = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "enum_member")) {
                for (child.children) |*mc| {
                    try members.append(ctx.alloc(), try buildNode(ctx, mc));
                }
            } else if (std.mem.eql(u8, r, "enum_variant") or std.mem.eql(u8, r, "func_decl")) {
                try members.append(ctx.alloc(), try buildNode(ctx, child));
            }
        }
    }

    return ctx.newNode(.{ .enum_decl = .{
        .name = name,
        .backing_type = backing,
        .members = try members.toOwnedSlice(ctx.alloc()),
        .is_pub = false,
    } });
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
    return ctx.newNode(.{ .for_stmt = .{
        .iterable = iterable,
        .captures = try captures.toOwnedSlice(ctx.alloc()),
        .index_var = null,
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
    const args = try buildChildrenByRule(ctx, cap, "expr");
    return ctx.newNode(.{ .compiler_func = .{ .name = name, .args = args } });
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
    // compare_expr <- bitor_expr compare_op bitor_expr / bitor_expr 'is' ... / bitor_expr
    // Filter out compare_op to get just the operands
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
                const args = try buildChildrenByRule(ctx, child, "expr");
                const field_access = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
                expr = try ctx.newNode(.{ .call_expr = .{ .callee = field_access, .args = args, .arg_names = &.{} } });
            } else if (std.mem.eql(u8, r, "field_access")) {
                const field_name = tokenText(ctx, child.start_pos + 1);
                expr = try ctx.newNode(.{ .field_expr = .{ .object = expr, .field = field_name } });
            } else if (std.mem.eql(u8, r, "call_access")) {
                const args = try buildChildrenByRule(ctx, child, "expr");
                expr = try ctx.newNode(.{ .call_expr = .{ .callee = expr, .args = args, .arg_names = &.{} } });
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
    const args = try buildAllChildren(ctx, cap);
    return ctx.newNode(.{ .type_generic = .{ .name = name, .args = args } });
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

    // Check for union: multiple type children with | separators
    var type_children = std.ArrayListUnmanaged(*Node){};
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type")) {
                try type_children.append(ctx.alloc(), try buildNode(ctx, child));
            }
        }
    }
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
    // The type children are the param types + return type (last one)
    for (cap.children) |*child| {
        if (child.rule) |r| {
            if (std.mem.eql(u8, r, "type")) {
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
