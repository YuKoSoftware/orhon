// parser.zig — Kodr recursive descent parser + AST type definitions
// AST uses arena allocation — entire tree freed in one call when done.
// Each PEG rule maps directly to a parse_X() function.

const std = @import("std");
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const errors = @import("errors.zig");

// ============================================================
// AST NODE DEFINITIONS
// ============================================================

pub const NodeKind = enum {
    program,
    module_decl,
    import_decl,
    metadata,
    func_decl,
    struct_decl,
    enum_decl,
    bitfield_decl,
    const_decl,
    var_decl,
    compt_decl,
    destruct_decl,
    test_decl,
    field_decl,
    enum_variant,
    param,
    block,
    return_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    defer_stmt,
    match_stmt,
    match_arm,
    break_stmt,
    continue_stmt,
    assignment,
    thread_block,
    async_block,
    // Expressions
    binary_expr,
    unary_expr,
    call_expr,
    index_expr,
    slice_expr,
    field_expr,
    borrow_expr,
    compiler_func,
    ptr_expr,
    coll_expr,
    identifier,
    int_literal,
    float_literal,
    string_literal,
    bool_literal,
    null_literal,
    array_literal,
    tuple_literal,
    error_literal,
    range_expr,
    // Types
    type_primitive,
    type_slice,
    type_array,
    type_ptr,
    type_union,
    type_tuple_named,
    type_tuple_anon,
    type_func,
    type_generic,
    type_named,
    struct_type,
};

/// A node in the AST
/// Uses tagged union for type safety
pub const Node = union(NodeKind) {
    program: Program,
    module_decl: ModuleDecl,
    import_decl: ImportDecl,
    metadata: Metadata,
    func_decl: FuncDecl,
    struct_decl: StructDecl,
    enum_decl: EnumDecl,
    bitfield_decl: BitfieldDecl,
    const_decl: VarDecl,
    var_decl: VarDecl,
    compt_decl: VarDecl,
    destruct_decl: DestructDecl,
    test_decl: TestDecl,
    field_decl: FieldDecl,
    enum_variant: EnumVariant,
    param: Param,
    block: Block,
    return_stmt: ReturnStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    defer_stmt: DeferStmt,
    match_stmt: MatchStmt,
    match_arm: MatchArm,
    break_stmt,
    continue_stmt,
    assignment: BinaryOp,
    thread_block: ConcurrencyBlock,
    async_block: ConcurrencyBlock,
    binary_expr: BinaryOp,
    unary_expr: UnaryOp,
    call_expr: CallExpr,
    index_expr: IndexExpr,
    slice_expr: SliceExpr,
    field_expr: FieldExpr,
    borrow_expr: *Node,
    compiler_func: CompilerFunc,
    ptr_expr: PtrExpr,
    coll_expr: CollExpr,
    identifier: []const u8,
    int_literal: []const u8,
    float_literal: []const u8,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal: void,
    array_literal: []*Node,
    tuple_literal: TupleLiteral,
    error_literal: []const u8,
    range_expr: BinaryOp,
    type_primitive: []const u8,
    type_slice: *Node,
    type_array: TypeArray,
    type_ptr: TypePtr,
    type_union: []*Node,
    type_tuple_named: []NamedTypeField,
    type_tuple_anon: []*Node,
    type_func: TypeFunc,
    type_generic: TypeGeneric,
    type_named: []const u8,
    struct_type: []*Node,  // anonymous struct type expression — fields only, no name/methods
};

pub const Program = struct {
    module: *Node,
    metadata: []*Node,
    imports: []*Node,
    top_level: []*Node,
};

pub const ModuleDecl = struct {
    name: []const u8,
};

pub const ImportDecl = struct {
    path: []const u8,       // module name
    scope: ?[]const u8,     // "std", "global", or null for project-local
    alias: ?[]const u8,     // rename with `as`
    is_c_header: bool,
};

pub const Metadata = struct {
    field: []const u8,
    value: *Node,
    extra: ?*Node = null, // version node for #dep, null otherwise
};

pub const FuncDecl = struct {
    name: []const u8,
    params: []*Node,
    return_type: *Node,
    body: *Node,
    is_compt: bool,
    is_pub: bool,
    is_extern: bool,  // no body — implementation in paired .zig file
};

pub const StructDecl = struct {
    name: []const u8,
    members: []*Node,
    is_pub: bool,
    is_extern: bool = false,
};

pub const EnumDecl = struct {
    name: []const u8,
    backing_type: *Node,
    members: []*Node,
    is_pub: bool,
};

pub const BitfieldDecl = struct {
    name: []const u8,
    backing_type: *Node,
    members: [][]const u8,  // flag names only — no data fields
    is_pub: bool,
};

pub const VarDecl = struct {
    name: []const u8,
    type_annotation: ?*Node,
    value: *Node,
    is_pub: bool,
    is_extern: bool = false,
};

pub const TestDecl = struct {
    description: []const u8,
    body: *Node,
};

pub const FieldDecl = struct {
    name: []const u8,
    type_annotation: *Node,
    default_value: ?*Node,
    is_pub: bool,
};

pub const EnumVariant = struct {
    name: []const u8,
    fields: []*Node, // params for data-carrying variants
};

pub const Param = struct {
    name: []const u8,
    type_annotation: *Node,
    default_value: ?*Node = null,
};

pub const Block = struct {
    statements: []*Node,
};

pub const ReturnStmt = struct {
    value: ?*Node,
};

pub const IfStmt = struct {
    condition: *Node,
    then_block: *Node,
    else_block: ?*Node,
};

pub const WhileStmt = struct {
    condition: *Node,
    continue_expr: ?*Node,
    body: *Node,
};

pub const ForStmt = struct {
    iterable: *Node,
    captures: [][]const u8,
    index_var: ?[]const u8,
    body: *Node,
    is_compt: bool,
    is_tuple_capture: bool,
};

pub const DeferStmt = struct {
    body: *Node,
};

pub const DestructDecl = struct {
    names: [][]const u8, // variable names — must match field names of the named tuple
    is_const: bool,
    value: *Node,
};

pub const MatchStmt = struct {
    value: *Node,
    arms: []*Node,
};

pub const MatchArm = struct {
    pattern: *Node,
    body: *Node,
};

pub const BinaryOp = struct {
    op: []const u8,
    left: *Node,
    right: *Node,
};

pub const UnaryOp = struct {
    op: []const u8,
    operand: *Node,
};

pub const CallExpr = struct {
    callee: *Node,
    args: []*Node,
    arg_names: [][]const u8, // non-empty for named args: Player(name: "hero")
};

pub const IndexExpr = struct {
    object: *Node,
    index: *Node,
};

pub const SliceExpr = struct {
    object: *Node,
    low: *Node,
    high: *Node,
};

pub const FieldExpr = struct {
    object: *Node,
    field: []const u8,
};

pub const CompilerFunc = struct {
    name: []const u8,
    args: []*Node,
};

pub const PtrExpr = struct {
    kind: []const u8, // "Ptr", "RawPtr", "VolatilePtr"
    type_arg: *Node,
    addr_arg: *Node,
};

pub const CollExpr = struct {
    kind: []const u8, // "List", "Map", "Set", "Ring", "ORing"
    type_args: []*Node, // [T] for List/Set/Ring/ORing, [K, V] for Map
    size_arg: ?*Node = null, // capacity for Ring/ORing
    alloc_arg: ?*Node, // null = use default owned allocator
};

pub const ConcurrencyBlock = struct {
    result_type: *Node,
    name: []const u8,
    body: *Node,
};

pub const TupleLiteral = struct {
    is_named: bool,
    fields: []*Node,
    field_names: [][]const u8, // empty if anonymous
};

pub const TypeArray = struct {
    size: *Node,
    elem: *Node,
};

pub const TypePtr = struct {
    kind: []const u8,
    elem: *Node,
};

pub const NamedTypeField = struct {
    name: []const u8,
    type_node: *Node,
    default: ?*Node,
};

pub const TypeFunc = struct {
    params: []*Node,
    ret: *Node,
};

pub const TypeGeneric = struct {
    name: []const u8,
    args: []*Node,
};

// ============================================================
// PARSER
// ============================================================

/// Map from AST node pointers to their source locations
pub const LocMap = std.AutoHashMap(*Node, errors.SourceLoc);

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    arena: std.heap.ArenaAllocator,
    reporter: *errors.Reporter,
    locs: LocMap,

    pub fn init(tokens: []const Token, allocator: std.mem.Allocator, reporter: *errors.Reporter) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .reporter = reporter,
            .locs = LocMap.init(allocator),
        };
    }

    /// Initialize using an existing ArenaAllocator. The caller owns the arena
    /// and is responsible for calling arena.deinit() — do NOT call p.deinit()
    /// when using this constructor, as that would free the caller's arena.
    pub fn initWithArena(tokens: []const Token, arena: std.heap.ArenaAllocator, allocator: std.mem.Allocator, reporter: *errors.Reporter) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
            .reporter = reporter,
            .locs = LocMap.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.locs.deinit();
        self.arena.deinit();
    }

    fn alloc(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn peek(self: *Parser) Token {
        return self.peekAt(0);
    }

    fn peekAt(self: *Parser, offset: usize) Token {
        var i = self.pos;
        var count: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            // Skip newlines for lookahead (except when significant)
            if (self.tokens[i].kind == .newline) continue;
            if (count == offset) return self.tokens[i];
            count += 1;
        }
        return self.tokens[self.tokens.len - 1]; // eof
    }

    fn advance(self: *Parser) Token {
        self.skipNewlines();
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return tok;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.tokens.len and self.tokens[self.pos].kind == .newline) {
            self.pos += 1;
        }
    }

    fn expectNewlineOrEof(self: *Parser) !void {
        if (self.pos >= self.tokens.len) return;
        const tok = self.tokens[self.pos];
        if (tok.kind == .newline or tok.kind == .eof) {
            if (tok.kind == .newline) self.pos += 1;
            return;
        }
        try self.reporter.report(.{
            .message = "expected newline after statement",
            .loc = .{ .file = "", .line = tok.line, .col = tok.col },
        });
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        self.skipNewlines();
        const tok = self.peek();
        if (tok.kind != kind) {
            const msg = try std.fmt.allocPrint(self.alloc(),
                "expected '{s}', found '{s}'",
                .{ tokenFriendlyName(kind), tok.text });
            defer self.alloc().free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = tok.line, .col = tok.col },
            });
            return error.ParseError;
        }
        return self.advance();
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    // eat() — consume token if it matches, return true. No-op if it doesn't.
    // Named after the Zig compiler's eatToken() pattern.
    fn eat(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn newNode(self: *Parser, node: Node) !*Node {
        const n = try self.alloc().create(Node);
        n.* = node;
        // Record source location from current token position
        // File path is set later by the pass that uses the loc
        const p = if (self.pos > 0) self.pos - 1 else 0;
        if (p < self.tokens.len) {
            const tok = self.tokens[p];
            try self.locs.put(n, .{ .file = "", .line = tok.line, .col = tok.col });
        }
        return n;
    }

    // ============================================================
    // PROGRAM STRUCTURE
    // ============================================================

    pub fn parseProgram(self: *Parser) anyerror!*Node {
        self.skipNewlines();

        // module declaration is mandatory
        const module = try self.parseModuleDecl();

        // metadata (#build = ..., etc.)
        var metadata_list: std.ArrayListUnmanaged(*Node) = .{};
        var imports_list: std.ArrayListUnmanaged(*Node) = .{};
        var top_level_list: std.ArrayListUnmanaged(*Node) = .{};

        self.skipNewlines();

        // Collect metadata, imports, and top-level declarations
        while (!self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.eof)) break;

            const tok = self.peek();

            if (tok.kind == .hash) {
                const meta = try self.parseMetadata();
                try metadata_list.append(self.alloc(), meta);
                continue;
            }

            if (tok.kind == .kw_import) {
                const imp = try self.parseImport();
                try imports_list.append(self.alloc(), imp);
                continue;
            }

            // Top level declaration
            const tl = try self.parseTopLevel() orelse break;
            try top_level_list.append(self.alloc(), tl);
        }

        return self.newNode(.{ .program = .{
            .module = module,
            .metadata = try metadata_list.toOwnedSlice(self.alloc()),
            .imports = try imports_list.toOwnedSlice(self.alloc()),
            .top_level = try top_level_list.toOwnedSlice(self.alloc()),
        }});
    }


    fn parseModuleDecl(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_module);
        // Module name can be an identifier or the keyword 'main'
        const name_tok = blk: {
            const tok = self.peek();
            if (tok.kind == .identifier or tok.kind == .kw_main) {
                break :blk self.advance();
            }
            const msg = try std.fmt.allocPrint(self.alloc(),
                "expected module name, found '{s}'", .{tok.text});
            defer self.alloc().free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = tok.line, .col = tok.col },
            });
            return error.ParseError;
        };
        try self.expectNewlineOrEof();
        return self.newNode(.{ .module_decl = .{ .name = name_tok.text } });
    }

    fn parseMetadata(self: *Parser) anyerror!*Node {
        _ = try self.expect(.hash);
        const field_tok = try self.expect(.identifier);

        if (std.mem.eql(u8, field_tok.text, "dep")) {
            // #dep "path" Version?
            const path = try self.parseExpr(); // string literal path
            var version_node: ?*Node = null;
            if (!self.check(.newline) and !self.check(.eof)) {
                version_node = try self.parseExpr();
            }
            try self.expectNewlineOrEof();
            return self.newNode(.{ .metadata = .{ .field = "dep", .value = path, .extra = version_node } });
        }

        _ = try self.expect(.assign);
        const value = try self.parseExpr();
        try self.expectNewlineOrEof();
        return self.newNode(.{ .metadata = .{ .field = field_tok.text, .value = value } });
    }

    fn parseImport(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_import);
        self.skipNewlines();

        const path_tok = self.peek();
        var path: []const u8 = undefined;
        var scope: ?[]const u8 = null;
        var is_c_header = false;

        if (path_tok.kind == .string_literal) {
            // C header: import "header.h"
            _ = self.advance();
            path = path_tok.text;
            is_c_header = true;
        } else {
            // Module name — could be bare `name` or scoped `std::name` / `global::name`
            const first = try self.expect(.identifier);

            if (self.check(.scope)) {
                // Scoped import: std::alpha or global::utils
                _ = self.advance(); // consume ::
                const name_tok = try self.expect(.identifier);
                // Validate scope — only std and global are valid
                if (!std.mem.eql(u8, first.text, "std") and
                    !std.mem.eql(u8, first.text, "global"))
                {
                    const msg = try std.fmt.allocPrint(self.alloc(),
                        "unknown scope '{s}' — only 'std' and 'global' are valid", .{first.text});
                    defer self.alloc().free(msg);
                    try self.reporter.report(.{
                        .message = msg,
                        .loc = .{ .file = "", .line = first.line, .col = first.col },
                    });
                    return error.ParseError;
                }
                scope = first.text;
                path = name_tok.text;
            } else {
                // Bare import: project-local module
                path = first.text;
            }
        }

        var alias: ?[]const u8 = null;
        if (self.check(.kw_as)) {
            _ = self.advance();
            const alias_tok = try self.expect(.identifier);
            alias = alias_tok.text;
        }

        try self.expectNewlineOrEof();
        return self.newNode(.{ .import_decl = .{
            .path = path,
            .scope = scope,
            .alias = alias,
            .is_c_header = is_c_header,
        }});
    }

    fn parseTopLevel(self: *Parser) !?*Node {
        self.skipNewlines();
        const tok = self.peek();

        return switch (tok.kind) {
            .kw_func => try self.parseFuncDecl(false, false),
            .kw_compt => try self.parseComptDecl(),
            .kw_struct => try self.parseStructDecl(false),
            .kw_enum => try self.parseEnumDecl(false),
            .kw_bitfield => try self.parseBitfieldDecl(false),
            .kw_const => try self.parseConstDecl(false),
            .kw_var => {
                try self.reporter.report(.{
                    .message = "module-level 'var' is not allowed — use 'const' or move into a function",
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
            .kw_pub => try self.parsePubDecl(),
            .kw_extern => try self.parseExternDecl(),
            .kw_test => try self.parseTestDecl(),
            .eof => null,
            else => {
                const msg = try std.fmt.allocPrint(self.alloc(),
                    "unexpected token '{s}' at top level", .{tok.text});
                defer self.alloc().free(msg);
                try self.reporter.report(.{
                    .message = msg,
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
        };
    }

    fn parsePubDecl(self: *Parser) anyerror!*Node {
        _ = self.advance(); // consume 'pub'
        const tok = self.peek();
        return switch (tok.kind) {
            .kw_func      => try self.parseFuncDecl(true, false),
            .kw_extern    => {
                const ext_tok = self.peek();
                try self.reporter.report(.{
                    .message = "'pub extern' is redundant — extern declarations are always public, use 'extern'",
                    .loc = .{ .file = "", .line = ext_tok.line, .col = ext_tok.col },
                });
                return error.ParseError;
            },
            .kw_struct    => try self.parseStructDecl(true),
            .kw_enum      => try self.parseEnumDecl(true),
            .kw_bitfield  => try self.parseBitfieldDecl(true),
            .kw_const     => try self.parseConstDecl(true),
            .kw_var       => {
                try self.reporter.report(.{
                    .message = "module-level 'var' is not allowed — use 'const' or move into a function",
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
            .kw_compt  => blk: {
                var node = try self.parseComptDecl();
                if (node.* == .func_decl) node.func_decl.is_pub = true;
                break :blk node;
            },
            else => {
                try self.reporter.report(.{
                    .message = "expected declaration after 'pub'",
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
        };
    }

    fn parseExternDecl(self: *Parser) anyerror!*Node {
        const ext_tok = self.advance(); // consume 'extern'
        const tok = self.peek();
        return switch (tok.kind) {
            .kw_func => self.parseFuncDecl(true, true),
            .kw_const => self.parseExternConstOrVar(true),
            .kw_var => {
                try self.reporter.report(.{
                    .message = "'extern var' is not allowed — use 'extern const' or wrap in 'extern func'",
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
            .kw_struct => self.parseExternStructDecl(),
            else => {
                try self.reporter.report(.{
                    .message = "expected 'func', 'const', or 'struct' after 'extern'",
                    .loc = .{ .file = "", .line = ext_tok.line, .col = ext_tok.col },
                });
                return error.ParseError;
            },
        };
    }

    /// Parse `extern const NAME: TYPE` or `extern var NAME: TYPE` — no value, just a declaration.
    fn parseExternConstOrVar(self: *Parser, is_const: bool) anyerror!*Node {
        _ = self.advance(); // consume 'const' or 'var'
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.colon);
        const type_ann = try self.parseType();
        try self.expectNewlineOrEof();
        // Create a dummy value node — extern decls have no value
        const dummy = try self.newNode(.{ .int_literal = "0" });
        if (is_const) {
            return self.newNode(.{ .const_decl = .{
                .name = name_tok.text,
                .type_annotation = type_ann,
                .value = dummy,
                .is_pub = true,
                .is_extern = true,
            }});
        } else {
            return self.newNode(.{ .var_decl = .{
                .name = name_tok.text,
                .type_annotation = type_ann,
                .value = dummy,
                .is_pub = true,
                .is_extern = true,
            }});
        }
    }

    /// Parse `extern struct NAME` — opaque type from sidecar .zig file.
    fn parseExternStructDecl(self: *Parser) anyerror!*Node {
        _ = self.advance(); // consume 'struct'
        const name_tok = try self.expect(.identifier);
        try self.expectNewlineOrEof();
        return self.newNode(.{ .struct_decl = .{
            .name = name_tok.text,
            .members = &.{},
            .is_pub = true,
            .is_extern = true,
        }});
    }

    // ============================================================
    // FUNCTION DECLARATIONS
    // ============================================================

    fn parseFuncDecl(self: *Parser, is_pub: bool, is_extern: bool) anyerror!*Node {
        _ = try self.expect(.kw_func);
        // Function name can be a regular identifier or the keyword 'main'
        const name_tok = blk: {
            const tok = self.peek();
            if (tok.kind == .identifier or tok.kind == .kw_main) {
                break :blk self.advance();
            }
            const msg = try std.fmt.allocPrint(self.alloc(),
                "expected function name, found '{s}'", .{tok.text});
            defer self.alloc().free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = tok.line, .col = tok.col },
            });
            return error.ParseError;
        };
        _ = try self.expect(.lparen);

        var params: std.ArrayListUnmanaged(*Node) = .{};
        self.skipNewlines();
        if (!self.check(.rparen)) {
            try params.append(self.alloc(), try self.parseParam());
            while (self.check(.comma)) {
                _ = self.advance();
                self.skipNewlines();
                if (self.check(.rparen)) break;
                try params.append(self.alloc(), try self.parseParam());
            }
        }
        _ = try self.expect(.rparen);

        // Validate: default params must come last (no non-default after a default)
        {
            var seen_default = false;
            for (params.items) |p| {
                if (p.* != .param) continue;
                if (p.param.default_value != null) {
                    seen_default = true;
                } else if (seen_default) {
                    try self.reporter.report(.{
                        .message = "parameters with defaults must come after all required parameters",
                        .loc = .{ .file = "", .line = name_tok.line, .col = name_tok.col },
                    });
                    return error.ParseError;
                }
            }
        }

        const ret_type = try self.parseType();

        // extern func has no body — implementation is in paired .zig file
        const body = if (is_extern) blk: {
            try self.expectNewlineOrEof();
            const empty_block = try self.newNode(.{ .block = .{ .statements = &.{} } });
            break :blk empty_block;
        } else try self.parseBlock();

        return self.newNode(.{ .func_decl = .{
            .name = name_tok.text,
            .params = try params.toOwnedSlice(self.alloc()),
            .return_type = ret_type,
            .body = body,
            .is_compt = false,
            .is_pub = is_pub,
            .is_extern = is_extern,
        }});
    }

    fn parseComptDecl(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_compt);
        const tok = self.peek();
        if (tok.kind == .kw_func) {
            var node = try self.parseFuncDecl(false, false);
            node.func_decl.is_compt = true;
            return node;
        }
        if (tok.kind == .kw_for) {
            try self.reporter.report(.{
                .message = "'compt for' is not supported — put the loop inside a 'compt func' instead",
                .loc = .{ .file = "", .line = tok.line, .col = tok.col },
            });
            return error.ParseError;
        }
        // compt var/const — not supported
        try self.reporter.report(.{
            .message = "'compt' is only valid before 'func' — use 'const' for compile-time values",
            .loc = .{ .file = "", .line = tok.line, .col = tok.col },
        });
        return error.ParseError;
    }

    fn parseParam(self: *Parser) anyerror!*Node {
        // Handle self parameter: self: const &Type or self: var &Type or self: Type
        const name_tok = self.peek();

        if (name_tok.kind == .identifier or name_tok.kind == .kw_var or name_tok.kind == .kw_const) {
            _ = self.advance();
            _ = try self.expect(.colon);
            const type_ann = try self.parseType();

            // Optional default value: param: Type = expr
            var default: ?*Node = null;
            if (self.check(.assign)) {
                _ = self.advance();
                default = try self.parseExpr();
            }

            return self.newNode(.{ .param = .{
                .name = name_tok.text,
                .type_annotation = type_ann,
                .default_value = default,
            }});
        }

        try self.reporter.report(.{
            .message = "expected parameter name",
            .loc = .{ .file = "", .line = name_tok.line, .col = name_tok.col },
        });
        return error.ParseError;
    }

    // ============================================================
    // STRUCT DECLARATIONS
    // ============================================================

    fn parseStructDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        _ = try self.expect(.kw_struct);
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var members: std.ArrayListUnmanaged(*Node) = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;

            const member_pub = self.eat(.kw_pub);
            const tok = self.peek();

            const member: *Node = switch (tok.kind) {
                .kw_func => try self.parseFuncDecl(member_pub, false),
                .kw_var => blk: {
                    const n = try self.parseVarDecl(member_pub);
                    break :blk n;
                },
                .kw_const => try self.parseConstDecl(member_pub),
                .kw_compt => try self.parseComptDecl(),
                .identifier => try self.parseFieldDecl(member_pub),
                else => {
                    const msg = try std.fmt.allocPrint(self.alloc(),
                        "unexpected token in struct: '{s}'", .{tok.text});
                    defer self.alloc().free(msg);
                    try self.reporter.report(.{
                        .message = msg,
                        .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                    });
                    return error.ParseError;
                },
            };
            try members.append(self.alloc(), member);
            self.skipNewlines();
        }

        _ = try self.expect(.rbrace);

        return self.newNode(.{ .struct_decl = .{
            .name = name_tok.text,
            .members = try members.toOwnedSlice(self.alloc()),
            .is_pub = is_pub,
        }});
    }

    fn parseFieldDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.colon);
        const type_ann = try self.parseType();

        var default: ?*Node = null;
        if (self.check(.assign)) {
            _ = self.advance();
            default = try self.parseExpr();
        }

        try self.expectNewlineOrEof();
        return self.newNode(.{ .field_decl = .{
            .name = name_tok.text,
            .type_annotation = type_ann,
            .default_value = default,
            .is_pub = is_pub,
        }});
    }

    // ============================================================
    // ENUM DECLARATIONS
    // ============================================================

    fn parseEnumDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        _ = try self.expect(.kw_enum);
        _ = try self.expect(.lparen);
        const backing = try self.parseType();
        _ = try self.expect(.rparen);
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var members: std.ArrayListUnmanaged(*Node) = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;
            const member_pub = self.eat(.kw_pub);
            const tok = self.peek();
            if (tok.kind == .kw_func) {
                try members.append(self.alloc(), try self.parseFuncDecl(member_pub, false));
            } else {
                try members.append(self.alloc(), try self.parseEnumVariant());
            }
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.newNode(.{ .enum_decl = .{
            .name = name_tok.text,
            .backing_type = backing,
            .members = try members.toOwnedSlice(self.alloc()),
            .is_pub = is_pub,
        }});
    }

    fn parseBitfieldDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        _ = try self.expect(.kw_bitfield);
        _ = try self.expect(.lparen);
        const backing = try self.parseType();
        _ = try self.expect(.rparen);
        const name_tok = try self.expect(.identifier);
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var members: std.ArrayListUnmanaged([]const u8) = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;
            const flag_tok = try self.expect(.identifier);
            try members.append(self.alloc(), flag_tok.text);
            try self.expectNewlineOrEof();
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.newNode(.{ .bitfield_decl = .{
            .name = name_tok.text,
            .backing_type = backing,
            .members = try members.toOwnedSlice(self.alloc()),
            .is_pub = is_pub,
        }});
    }

    fn parseEnumVariant(self: *Parser) anyerror!*Node {
        const name_tok = try self.expect(.identifier);
        var fields: std.ArrayListUnmanaged(*Node) = .{};

        if (self.check(.lparen)) {
            _ = self.advance();
            self.skipNewlines();
            if (!self.check(.rparen)) {
                try fields.append(self.alloc(), try self.parseParam());
                while (self.check(.comma)) {
                    _ = self.advance();
                    self.skipNewlines();
                    if (self.check(.rparen)) break;
                    try fields.append(self.alloc(), try self.parseParam());
                }
            }
            _ = try self.expect(.rparen);
        }

        try self.expectNewlineOrEof();
        return self.newNode(.{ .enum_variant = .{
            .name = name_tok.text,
            .fields = try fields.toOwnedSlice(self.alloc()),
        }});
    }

    // ============================================================
    // VARIABLE DECLARATIONS
    // ============================================================

    fn parseConstDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        _ = try self.expect(.kw_const);
        const name_tok = try self.expect(.identifier);

        // Destructuring: const a, b = expr
        if (self.check(.comma)) return self.parseDestructDeclFrom(name_tok.text, true);

        var type_ann: ?*Node = null;
        if (self.check(.colon)) {
            _ = self.advance();
            type_ann = try self.parseType();
        }

        _ = try self.expect(.assign);
        const value = try self.parseExpr();
        try self.expectNewlineOrEof();

        return self.newNode(.{ .const_decl = .{
            .name = name_tok.text,
            .type_annotation = type_ann,
            .value = value,
            .is_pub = is_pub,
        }});
    }

    fn parseVarDecl(self: *Parser, is_pub: bool) anyerror!*Node {
        _ = try self.expect(.kw_var);
        const name_tok = try self.expect(.identifier);

        // Destructuring: var a, b = expr
        if (self.check(.comma)) return self.parseDestructDeclFrom(name_tok.text, false);

        var type_ann: ?*Node = null;
        if (self.check(.colon)) {
            _ = self.advance();
            type_ann = try self.parseType();
        }

        _ = try self.expect(.assign);
        const value = try self.parseExpr();
        try self.expectNewlineOrEof();

        return self.newNode(.{ .var_decl = .{
            .name = name_tok.text,
            .type_annotation = type_ann,
            .value = value,
            .is_pub = is_pub,
        }});
    }

    fn parseDestructDeclFrom(self: *Parser, first_name: []const u8, is_const: bool) anyerror!*Node {
        var names: std.ArrayListUnmanaged([]const u8) = .{};
        try names.append(self.alloc(), first_name);
        while (self.eat(.comma)) {
            const name_tok = try self.expect(.identifier);
            try names.append(self.alloc(), name_tok.text);
        }
        _ = try self.expect(.assign);
        const value = try self.parseExpr();
        try self.expectNewlineOrEof();
        return self.newNode(.{ .destruct_decl = .{
            .names = try names.toOwnedSlice(self.alloc()),
            .is_const = is_const,
            .value = value,
        }});
    }

    // ============================================================
    // TEST DECLARATIONS
    // ============================================================

    fn parseTestDecl(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_test);
        // Syntax: test"description" { }  — no parentheses, string directly after test
        const desc_tok = try self.expect(.string_literal);
        const body = try self.parseBlock();
        return self.newNode(.{ .test_decl = .{
            .description = desc_tok.text,
            .body = body,
        }});
    }

    // ============================================================
    // STATEMENTS
    // ============================================================

    fn parseBlock(self: *Parser) anyerror!*Node {
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var stmts: std.ArrayListUnmanaged(*Node) = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;
            const stmt = try self.parseStatement();
            try stmts.append(self.alloc(), stmt);
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.newNode(.{ .block = .{
            .statements = try stmts.toOwnedSlice(self.alloc()),
        }});
    }

    fn parseStatement(self: *Parser) anyerror!*Node {
        self.skipNewlines();
        const tok = self.peek();

        return switch (tok.kind) {
            .kw_var => try self.parseVarDecl(false),
            .kw_const => try self.parseConstDecl(false),
            .kw_compt => try self.parseComptDecl(),
            .kw_return => try self.parseReturn(),
            .kw_if => try self.parseIf(),
            .kw_while => try self.parseWhile(),
            .kw_for => try self.parseFor(),
            .kw_defer => try self.parseDefer(),
            .kw_match => try self.parseMatch(),
            .kw_break => try self.parseBreak(),
            .kw_continue => try self.parseContinue(),
            .kw_thread => try self.parseThreadBlock(),
            else => try self.parseExprOrAssignment(),
        };
    }

    fn parseReturn(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_return);
        var value: ?*Node = null;
        // Use raw positional check for newline — peek() skips newlines so
        // check(.newline) can never return true. We check self.tokens[self.pos]
        // directly to detect a bare return with no value.
        const at_end = self.pos >= self.tokens.len or
            self.tokens[self.pos].kind == .newline or
            self.tokens[self.pos].kind == .rbrace or
            self.tokens[self.pos].kind == .eof;
        if (!at_end) {
            value = try self.parseExpr();
        }
        try self.expectNewlineOrEof();
        return self.newNode(.{ .return_stmt = .{ .value = value } });
    }

    fn parseIf(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_if);
        _ = try self.expect(.lparen);
        const condition = try self.parseExpr();
        _ = try self.expect(.rparen);
        const then_block = try self.parseBlock();
        var else_block: ?*Node = null;
        if (self.check(.kw_else)) {
            _ = self.advance();
            else_block = try self.parseBlock();
        }
        return self.newNode(.{ .if_stmt = .{
            .condition = condition,
            .then_block = then_block,
            .else_block = else_block,
        }});
    }

    fn parseWhile(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const condition = try self.parseExpr();
        _ = try self.expect(.rparen);

        var continue_expr: ?*Node = null;
        if (self.check(.colon)) {
            _ = self.advance();
            _ = try self.expect(.lparen);
            continue_expr = try self.parseAssignExpr();
            _ = try self.expect(.rparen);
        }

        const body = try self.parseBlock();
        return self.newNode(.{ .while_stmt = .{
            .condition = condition,
            .continue_expr = continue_expr,
            .body = body,
        }});
    }

    fn parseFor(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_for);
        _ = try self.expect(.lparen);

        const iterable = try self.parseExpr();
        _ = try self.expect(.rparen);

        _ = try self.expect(.pipe);
        var captures: std.ArrayListUnmanaged([]const u8) = .{};
        var is_tuple_capture = false;
        var index_var: ?[]const u8 = null;

        if (self.check(.lparen)) {
            // Tuple capture: |(key, value)|
            _ = self.advance();
            is_tuple_capture = true;
            const v1 = try self.expect(.identifier);
            try captures.append(self.alloc(), v1.text);
            while (self.check(.comma)) {
                _ = self.advance();
                const v = try self.expect(.identifier);
                try captures.append(self.alloc(), v.text);
            }
            _ = try self.expect(.rparen);
            // Optional index after tuple: |(key, value), index|
            if (self.check(.comma)) {
                _ = self.advance();
                const idx = try self.expect(.identifier);
                index_var = idx.text;
            }
        } else {
            // Regular capture: |val| or |val, index|
            const v1 = try self.expect(.identifier);
            try captures.append(self.alloc(), v1.text);
            if (self.check(.comma)) {
                _ = self.advance();
                const idx = try self.expect(.identifier);
                index_var = idx.text;
            }
        }
        _ = try self.expect(.pipe);

        const body = try self.parseBlock();
        return self.newNode(.{ .for_stmt = .{
            .iterable = iterable,
            .captures = try captures.toOwnedSlice(self.alloc()),
            .index_var = index_var,
            .body = body,
            .is_compt = false,
            .is_tuple_capture = is_tuple_capture,
        }});
    }

    fn parseDefer(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_defer);
        const body = try self.parseBlock();
        return self.newNode(.{ .defer_stmt = .{ .body = body } });
    }

    fn parseMatch(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_match);
        const value = try self.parseExpr();
        _ = try self.expect(.lbrace);
        self.skipNewlines();

        var arms: std.ArrayListUnmanaged(*Node) = .{};
        while (!self.check(.rbrace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.rbrace)) break;
            try arms.append(self.alloc(), try self.parseMatchArm());
            self.skipNewlines();
        }
        _ = try self.expect(.rbrace);

        return self.newNode(.{ .match_stmt = .{
            .value = value,
            .arms = try arms.toOwnedSlice(self.alloc()),
        }});
    }

    fn parseMatchArm(self: *Parser) anyerror!*Node {
        const pattern = try self.parseMatchPattern();
        _ = try self.expect(.arrow);
        const body = try self.parseBlock();
        return self.newNode(.{ .match_arm = .{
            .pattern = pattern,
            .body = body,
        }});
    }

    fn parseMatchPattern(self: *Parser) anyerror!*Node {
        const tok = self.peek();

        // Wildcard — `else` is the catch-all arm
        if (tok.kind == .kw_else) {
            _ = self.advance();
            return self.newNode(.{ .identifier = "else" });
        }

        // Parse an expression — could be range, enum variant, literal, type check
        const expr = try self.parseExpr();

        // Range pattern: expr..expr
        if (self.check(.dotdot)) {
            _ = self.advance();
            const end = try self.parseExpr();
            return self.newNode(.{ .range_expr = .{
                .op = "..",
                .left = expr,
                .right = end,
            }});
        }

        return expr;
    }

    fn parseBreak(self: *Parser) anyerror!*Node {
        const tok = try self.expect(.kw_break);
        if (self.check(.identifier)) {
            const label_tok = self.peek();
            const msg = try std.fmt.allocPrint(self.alloc(),
                "labeled break is not supported — extract the loop into a func and use return", .{});
            defer self.alloc().free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = label_tok.line, .col = label_tok.col },
            });
            return error.ParseError;
        }
        try self.expectNewlineOrEof();
        _ = tok;
        return self.newNode(.{ .break_stmt = {} });
    }

    fn parseContinue(self: *Parser) anyerror!*Node {
        const tok = try self.expect(.kw_continue);
        if (self.check(.identifier)) {
            const label_tok = self.peek();
            const msg = try std.fmt.allocPrint(self.alloc(),
                "labeled continue is not supported — extract the loop into a func and use return", .{});
            defer self.alloc().free(msg);
            try self.reporter.report(.{
                .message = msg,
                .loc = .{ .file = "", .line = label_tok.line, .col = label_tok.col },
            });
            return error.ParseError;
        }
        try self.expectNewlineOrEof();
        _ = tok;
        return self.newNode(.{ .continue_stmt = {} });
    }

    fn parseThreadBlock(self: *Parser) anyerror!*Node {
        _ = try self.expect(.kw_thread);
        _ = try self.expect(.lparen);
        const result_type = try self.parseType();
        _ = try self.expect(.rparen);
        const name_tok = try self.expect(.identifier);
        const body = try self.parseBlock();
        return self.newNode(.{ .thread_block = .{
            .result_type = result_type,
            .name = name_tok.text,
            .body = body,
        }});
    }

    // Like parseExprOrAssignment but no trailing newline required.
    // Used for while continue expressions: while(cond) : (i += 1)
    fn parseAssignExpr(self: *Parser) anyerror!*Node {
        const expr = try self.parseExpr();
        if (self.check(.assign)) {
            _ = self.advance();
            const value = try self.parseExpr();
            return self.newNode(.{ .assignment = .{ .op = "=", .left = expr, .right = value } });
        }
        const tok = self.peek();
        const op: ?[]const u8 = switch (tok.kind) {
            .plus_assign => "+=",
            .minus_assign => "-=",
            .star_assign => "*=",
            .slash_assign => "/=",
            else => null,
        };
        if (op) |o| {
            _ = self.advance();
            const value = try self.parseExpr();
            return self.newNode(.{ .assignment = .{ .op = o, .left = expr, .right = value } });
        }
        return expr;
    }

    fn parseExprOrAssignment(self: *Parser) anyerror!*Node {
        const expr = try self.parseExpr();

        // Check for assignment
        if (self.check(.assign)) {
            _ = self.advance();
            const value = try self.parseExpr();
            try self.expectNewlineOrEof();
            return self.newNode(.{ .assignment = .{
                .op = "=",
                .left = expr,
                .right = value,
            }});
        }

        // Check for compound assignment
        const tok = self.peek();
        const op: ?[]const u8 = switch (tok.kind) {
            .plus_assign => "+=",
            .minus_assign => "-=",
            .star_assign => "*=",
            .slash_assign => "/=",
            else => null,
        };

        if (op) |o| {
            _ = self.advance();
            const value = try self.parseExpr();
            try self.expectNewlineOrEof();
            return self.newNode(.{ .assignment = .{
                .op = o,
                .left = expr,
                .right = value,
            }});
        }

        try self.expectNewlineOrEof();
        return expr;
    }

    // ============================================================
    // EXPRESSIONS — operator precedence tower
    // ============================================================

    pub fn parseExpr(self: *Parser) anyerror!*Node {
        return self.parseRangeExpr();
    }

    fn parseRangeExpr(self: *Parser) anyerror!*Node {
        const left = try self.parseOrExpr();
        if (self.check(.dotdot)) {
            _ = self.advance();
            const right = try self.parseOrExpr();
            return self.newNode(.{ .range_expr = .{ .op = "..", .left = left, .right = right } });
        }
        return left;
    }

    fn parseOrExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseAndExpr();
        while (self.check(.kw_or)) {
            _ = self.advance();
            const right = try self.parseAndExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = "or", .left = left, .right = right } });
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseNotExpr();
        while (self.check(.kw_and)) {
            _ = self.advance();
            const right = try self.parseNotExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = "and", .left = left, .right = right } });
        }
        return left;
    }

    fn parseNotExpr(self: *Parser) anyerror!*Node {
        if (self.check(.kw_not)) {
            _ = self.advance();
            const operand = try self.parseNotExpr();
            return self.newNode(.{ .unary_expr = .{ .op = "not", .operand = operand } });
        }
        return self.parseCompareExpr();
    }

    fn parseCompareExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseBitorExpr();
        const tok = self.peek();
        const op: ?[]const u8 = switch (tok.kind) {
            .eq => "==",
            .neq => "!=",
            .lt => "<",
            .gt => ">",
            .lte => "<=",
            .gte => ">=",
            else => null,
        };
        if (op) |o| {
            _ = self.advance();
            const right = try self.parseBitorExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = o, .left = left, .right = right } });
        } else if (self.eat(.kw_is)) {
            // `expr is Type` / `expr is not Type` — desugar to internal type check
            const negated = self.eat(.kw_not);
            const args = try self.alloc().alloc(*Node, 1);
            args[0] = left;
            const type_call = try self.newNode(.{ .compiler_func = .{ .name = "type", .args = args } });
            const rhs_tok = self.peek();
            const right = if (rhs_tok.kind == .kw_null) blk: {
                _ = self.advance();
                break :blk try self.newNode(.null_literal);
            } else blk: {
                const name_tok = try self.expect(.identifier);
                break :blk try self.newNode(.{ .identifier = name_tok.text });
            };
            const cmp_op: []const u8 = if (negated) "!=" else "==";
            left = try self.newNode(.{ .binary_expr = .{ .op = cmp_op, .left = type_call, .right = right } });
        }
        return left;
    }

    fn parseBitorExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseBitxorExpr();
        while (self.check(.pipe)) {
            _ = self.advance();
            const right = try self.parseBitxorExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = "|", .left = left, .right = right } });
        }
        return left;
    }

    fn parseBitxorExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseBitandExpr();
        while (self.check(.caret)) {
            _ = self.advance();
            const right = try self.parseBitandExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = "^", .left = left, .right = right } });
        }
        return left;
    }

    fn parseBitandExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseShiftExpr();
        while (self.check(.ampersand)) {
            _ = self.advance();
            const right = try self.parseShiftExpr();
            left = try self.newNode(.{ .binary_expr = .{ .op = "&", .left = left, .right = right } });
        }
        return left;
    }

    fn parseShiftExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseAddExpr();
        while (true) {
            const tok = self.peek();
            const op: ?[]const u8 = switch (tok.kind) {
                .lshift => "<<",
                .rshift => ">>",
                else => null,
            };
            if (op) |o| {
                _ = self.advance();
                const right = try self.parseAddExpr();
                left = try self.newNode(.{ .binary_expr = .{ .op = o, .left = left, .right = right } });
            } else break;
        }
        return left;
    }

    fn parseAddExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseMulExpr();
        while (true) {
            const tok = self.peek();
            const op: ?[]const u8 = switch (tok.kind) {
                .plus => "+",
                .plus_plus => "++",
                .minus => "-",
                else => null,
            };
            if (op) |o| {
                _ = self.advance();
                const right = try self.parseMulExpr();
                left = try self.newNode(.{ .binary_expr = .{ .op = o, .left = left, .right = right } });
            } else break;
        }
        return left;
    }

    fn parseMulExpr(self: *Parser) anyerror!*Node {
        var left = try self.parseUnaryExpr();
        while (true) {
            const tok = self.peek();
            const op: ?[]const u8 = switch (tok.kind) {
                .star => "*",
                .slash => "/",
                .percent => "%",
                else => null,
            };
            if (op) |o| {
                _ = self.advance();
                const right = try self.parseUnaryExpr();
                left = try self.newNode(.{ .binary_expr = .{ .op = o, .left = left, .right = right } });
            } else break;
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) anyerror!*Node {
        const tok = self.peek();
        switch (tok.kind) {
            .bang => {
                _ = self.advance();
                const operand = try self.parseUnaryExpr();
                return self.newNode(.{ .unary_expr = .{ .op = "!", .operand = operand } });
            },
            .ampersand => {
                _ = self.advance();
                const operand = try self.parseUnaryExpr();
                return self.newNode(.{ .borrow_expr = operand });
            },
            else => {},
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) anyerror!*Node {
        var expr = try self.parsePrimaryExpr();

        while (true) {
            if (self.check(.dot)) {
                _ = self.advance();
                const field_tok = self.peek();
                if (field_tok.kind == .identifier or field_tok.kind == .kw_var or
                    field_tok.kind == .kw_const)
                {
                    _ = self.advance();
                    // Check if it's a method call
                    if (self.check(.lparen)) {
                        _ = self.advance();
                        var args: std.ArrayListUnmanaged(*Node) = .{};
                        self.skipNewlines();
                        if (!self.check(.rparen)) {
                            try args.append(self.alloc(), try self.parseExpr());
                            while (self.check(.comma)) {
                                _ = self.advance();
                                self.skipNewlines();
                                if (self.check(.rparen)) break;
                                try args.append(self.alloc(), try self.parseExpr());
                            }
                        }
                        _ = try self.expect(.rparen);
                        // Build method call as field access then call
                        const field_access = try self.newNode(.{ .field_expr = .{
                            .object = expr,
                            .field = field_tok.text,
                        }});
                        expr = try self.newNode(.{ .call_expr = .{
                            .callee = field_access,
                            .args = try args.toOwnedSlice(self.alloc()),
                            .arg_names = &.{},
                        }});
                    } else {
                        expr = try self.newNode(.{ .field_expr = .{
                            .object = expr,
                            .field = field_tok.text,
                        }});
                    }
                } else {
                    try self.reporter.report(.{
                        .message = "expected field name after '.'",
                        .loc = .{ .file = "", .line = field_tok.line, .col = field_tok.col },
                    });
                    return error.ParseError;
                }
            } else if (self.check(.lbracket)) {
                _ = self.advance();
                // Parse below range level so `..` is not consumed by the sub-expression
                const first = try self.parseOrExpr();
                if (self.check(.dotdot)) {
                    _ = self.advance();
                    const high = try self.parseOrExpr();
                    _ = try self.expect(.rbracket);
                    expr = try self.newNode(.{ .slice_expr = .{ .object = expr, .low = first, .high = high } });
                } else {
                    _ = try self.expect(.rbracket);
                    expr = try self.newNode(.{ .index_expr = .{ .object = expr, .index = first } });
                }
            } else if (self.check(.lparen)) {
                _ = self.advance();
                var args: std.ArrayListUnmanaged(*Node) = .{};
                var arg_names: std.ArrayListUnmanaged([]const u8) = .{};
                var has_names = false;
                self.skipNewlines();
                if (!self.check(.rparen)) {
                    const first = try self.parseNamedOrPositionalArg();
                    try args.append(self.alloc(), first.value);
                    try arg_names.append(self.alloc(), first.name);
                    if (first.name.len > 0) has_names = true;
                    while (self.check(.comma)) {
                        _ = self.advance();
                        self.skipNewlines();
                        if (self.check(.rparen)) break;
                        const arg = try self.parseNamedOrPositionalArg();
                        try args.append(self.alloc(), arg.value);
                        try arg_names.append(self.alloc(), arg.name);
                        if (arg.name.len > 0) has_names = true;
                    }
                }
                _ = try self.expect(.rparen);
                expr = try self.newNode(.{ .call_expr = .{
                    .callee = expr,
                    .args = try args.toOwnedSlice(self.alloc()),
                    .arg_names = if (has_names) try arg_names.toOwnedSlice(self.alloc()) else &.{},
                }});
            } else {
                break;
            }
        }

        return expr;
    }

    const NamedArg = struct { name: []const u8, value: *Node };

    fn parseNamedOrPositionalArg(self: *Parser) anyerror!NamedArg {
        // Check for named argument: name: value
        if (self.peek().kind == .identifier and self.peekAt(1).kind == .colon) {
            const name_tok = self.advance();
            _ = self.advance(); // consume colon
            const value = try self.parseExpr();
            return .{ .name = name_tok.text, .value = value };
        }
        return .{ .name = "", .value = try self.parseExpr() };
    }

    fn parsePrimaryExpr(self: *Parser) anyerror!*Node {
        self.skipNewlines();
        const tok = self.peek();

        switch (tok.kind) {
            // Compiler functions — reserved keywords, called like regular functions
            .kw_cast, .kw_copy, .kw_move, .kw_swap,
            .kw_assert, .kw_size, .kw_align, .kw_typename, .kw_typeid => {
                const func_tok = self.advance();
                _ = try self.expect(.lparen);
                var args: std.ArrayListUnmanaged(*Node) = .{};
                self.skipNewlines();
                if (!self.check(.rparen)) {
                    try args.append(self.alloc(), try self.parseExpr());
                    while (self.check(.comma)) {
                        _ = self.advance();
                        self.skipNewlines();
                        if (self.check(.rparen)) break;
                        try args.append(self.alloc(), try self.parseExpr());
                    }
                }
                _ = try self.expect(.rparen);
                return self.newNode(.{ .compiler_func = .{
                    .name = func_tok.text,
                    .args = try args.toOwnedSlice(self.alloc()),
                }});
            },

            .invalid => {
                const msg = try std.fmt.allocPrint(self.alloc(),
                    "invalid numeric literal '{s}'", .{tok.text});
                defer self.alloc().free(msg);
                try self.reporter.report(.{
                    .message = msg,
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },

            // Literals
            .int_literal => {
                _ = self.advance();
                return self.newNode(.{ .int_literal = tok.text });
            },
            .float_literal => {
                _ = self.advance();
                return self.newNode(.{ .float_literal = tok.text });
            },
            .string_literal => {
                _ = self.advance();
                return self.newNode(.{ .string_literal = tok.text });
            },
            .kw_true => {
                _ = self.advance();
                return self.newNode(.{ .bool_literal = true });
            },
            .kw_false => {
                _ = self.advance();
                return self.newNode(.{ .bool_literal = false });
            },
            .kw_null => {
                _ = self.advance();
                return self.newNode(.{ .null_literal = {} });
            },

            // Array literal: [1, 2, 3]
            .lbracket => {
                _ = self.advance();
                var items: std.ArrayListUnmanaged(*Node) = .{};
                self.skipNewlines();
                if (!self.check(.rbracket)) {
                    try items.append(self.alloc(), try self.parseExpr());
                    while (self.check(.comma)) {
                        _ = self.advance();
                        self.skipNewlines();
                        if (self.check(.rbracket)) break;
                        try items.append(self.alloc(), try self.parseExpr());
                    }
                }
                _ = try self.expect(.rbracket);
                return self.newNode(.{ .array_literal = try items.toOwnedSlice(self.alloc()) });
            },

            // Grouped expression: (expr)
            .lparen => {
                _ = self.advance();
                // Named tuple literal: (name: val, name: val, ...)
                if (self.peek().kind == .identifier and self.peekAt(1).kind == .colon) {
                    var names: std.ArrayListUnmanaged([]const u8) = .{};
                    var values: std.ArrayListUnmanaged(*Node) = .{};
                    while (!self.check(.rparen) and !self.check(.eof)) {
                        self.skipNewlines();
                        const name_tok = try self.expect(.identifier);
                        _ = try self.expect(.colon);
                        const val = try self.parseExpr();
                        try names.append(self.alloc(), name_tok.text);
                        try values.append(self.alloc(), val);
                        self.skipNewlines();
                        if (!self.eat(.comma)) break;
                        self.skipNewlines();
                    }
                    _ = try self.expect(.rparen);
                    return self.newNode(.{ .tuple_literal = .{
                        .is_named = true,
                        .fields = try values.toOwnedSlice(self.alloc()),
                        .field_names = try names.toOwnedSlice(self.alloc()),
                    }});
                }
                const expr = try self.parseExpr();
                _ = try self.expect(.rparen);
                return expr;
            },

            // Identifier — could be variable, function call, enum variant, etc.
            .identifier => {
                _ = self.advance();

                // Error literal: Error("message")
                if (std.mem.eql(u8, tok.text, "Error") and self.check(.lparen)) {
                    _ = self.advance();
                    const msg = try self.expect(.string_literal);
                    _ = try self.expect(.rparen);
                    return self.newNode(.{ .error_literal = msg.text });
                }

                // Pointer instantiation: Ptr(T, &x) / RawPtr(T, addr) / VolatilePtr(T, addr)
                const is_safe = std.mem.eql(u8, tok.text, "Ptr");
                const is_raw = std.mem.eql(u8, tok.text, "RawPtr");
                const is_volatile = std.mem.eql(u8, tok.text, "VolatilePtr");
                if ((is_safe or is_raw or is_volatile) and self.check(.lparen)) {
                    _ = self.advance();
                    const type_arg = try self.parseType();
                    _ = try self.expect(.comma);
                    const addr_arg = try self.parseExpr();
                    _ = try self.expect(.rparen);
                    return self.newNode(.{ .ptr_expr = .{
                        .kind = tok.text,
                        .type_arg = type_arg,
                        .addr_arg = addr_arg,
                    }});
                }

                // Collection constructors: List(T, alloc) / Map(K, V, alloc) / Set(T, alloc) / Ring(T, n) / ORing(T, n)
                const is_list = std.mem.eql(u8, tok.text, "List");
                const is_map = std.mem.eql(u8, tok.text, "Map");
                const is_set = std.mem.eql(u8, tok.text, "Set");
                const is_ring = std.mem.eql(u8, tok.text, "Ring");
                const is_oring = std.mem.eql(u8, tok.text, "ORing");
                if ((is_list or is_map or is_set or is_ring or is_oring) and self.check(.lparen)) {
                    _ = self.advance(); // consume (
                    var type_args = std.ArrayListUnmanaged(*Node){};
                    const n_type_args: usize = if (is_map) 2 else 1;
                    for (0..n_type_args) |i| {
                        const type_arg = try self.parseType();
                        try type_args.append(self.alloc(), type_arg);
                        if (i < n_type_args - 1) _ = try self.expect(.comma);
                    }
                    // Ring/ORing require a size arg: Ring(T, n)
                    var size_arg: ?*Node = null;
                    if (is_ring or is_oring) {
                        _ = try self.expect(.comma);
                        size_arg = try self.parseExpr();
                    }
                    // Optional allocator arg (for List/Map/Set only)
                    const alloc_arg: ?*Node = if (self.eat(.rparen)) null else blk: {
                        _ = try self.expect(.comma);
                        const arg = try self.parseExpr();
                        _ = try self.expect(.rparen);
                        break :blk arg;
                    };
                    return self.newNode(.{ .coll_expr = .{
                        .kind = tok.text,
                        .type_args = try type_args.toOwnedSlice(self.alloc()),
                        .size_arg = size_arg,
                        .alloc_arg = alloc_arg,
                    }});
                }

                return self.newNode(.{ .identifier = tok.text });
            },

            // Anonymous struct type expression: struct { field: Type ... }
            // Used in compt func return position: compt func Box(T: any) type { return struct { value: T } }
            .kw_struct => {
                _ = self.advance(); // consume 'struct'
                _ = try self.expect(.lbrace);
                var fields = std.ArrayListUnmanaged(*Node){};
                while (!self.check(.rbrace) and !self.check(.eof)) {
                    const is_pub_field = self.eat(.kw_pub);
                    const field = try self.parseFieldDecl(is_pub_field);
                    try fields.append(self.alloc(), field);
                }
                _ = try self.expect(.rbrace);
                return self.newNode(.{ .struct_type = try fields.toOwnedSlice(self.alloc()) });
            },

            else => {
                const msg = try std.fmt.allocPrint(self.alloc(),
                    "unexpected token '{s}' in expression", .{tok.text});
                defer self.alloc().free(msg);
                try self.reporter.report(.{
                    .message = msg,
                    .loc = .{ .file = "", .line = tok.line, .col = tok.col },
                });
                return error.ParseError;
            },
        }
    }

    // ============================================================
    // TYPES
    // ============================================================

    pub fn parseType(self: *Parser) anyerror!*Node {
        self.skipNewlines();
        const tok = self.peek();

        // Borrow types: const &T (immutable) or &T (mutable)
        if (tok.kind == .kw_const and self.peekAt(1).kind == .ampersand) {
            _ = self.advance(); // consume const
            _ = self.advance(); // consume &
            const inner = try self.parseType();
            return self.newNode(.{ .type_ptr = .{ .kind = "const &", .elem = inner } });
        }

        // Reject var &T — redundant, use &T instead
        if (tok.kind == .kw_var and self.peekAt(1).kind == .ampersand) {
            try self.reporter.report(.{
                .message = "'var &T' is not valid — use '&T' for mutable references",
                .loc = .{ .file = "", .line = tok.line, .col = tok.col },
            });
            return error.ParseError;
        }

        // &T — mutable reference
        if (tok.kind == .ampersand) {
            _ = self.advance(); // consume &
            const inner = try self.parseType();
            return self.newNode(.{ .type_ptr = .{ .kind = "var &", .elem = inner } });
        }

        // Union type: (T | U | ...)
        if (tok.kind == .lparen) {
            // Peek to distinguish: (T | U) vs (T, U) vs (x: T, y: U)
            return self.parseParenType();
        }

        // Slice type: []T
        if (tok.kind == .lbracket) {
            _ = self.advance();
            if (self.check(.rbracket)) {
                _ = self.advance();
                const elem = try self.parseType();
                return self.newNode(.{ .type_slice = elem });
            }
            // Array type: [n]T
            const size = try self.parseExpr();
            _ = try self.expect(.rbracket);
            const elem = try self.parseType();
            return self.newNode(.{ .type_array = .{ .size = size, .elem = elem } });
        }

        // func type
        if (tok.kind == .kw_func) {
            _ = self.advance();
            _ = try self.expect(.lparen);
            var params: std.ArrayListUnmanaged(*Node) = .{};
            self.skipNewlines();
            if (!self.check(.rparen)) {
                try params.append(self.alloc(), try self.parseType());
                while (self.check(.comma)) {
                    _ = self.advance();
                    self.skipNewlines();
                    if (self.check(.rparen)) break;
                    try params.append(self.alloc(), try self.parseType());
                }
            }
            _ = try self.expect(.rparen);
            const ret = try self.parseType();
            return self.newNode(.{ .type_func = .{
                .params = try params.toOwnedSlice(self.alloc()),
                .ret = ret,
            }});
        }

        // Named type or generic: Name or Name(T, U)
        if (tok.kind == .identifier or isPrimitiveKeyword(tok.kind)) {
            _ = self.advance();
            // Check for generic: Name(T)
            if (self.check(.lparen)) {
                _ = self.advance();
                var args: std.ArrayListUnmanaged(*Node) = .{};
                const is_ring_type = std.mem.eql(u8, tok.text, "Ring") or std.mem.eql(u8, tok.text, "ORing");
                self.skipNewlines();
                if (!self.check(.rparen)) {
                    // First arg is always a type
                    try args.append(self.alloc(), try self.parseType());
                    while (self.check(.comma)) {
                        _ = self.advance();
                        self.skipNewlines();
                        if (self.check(.rparen)) break;
                        // Ring/ORing second arg is an integer size, not a type
                        if (is_ring_type and args.items.len == 1) {
                            try args.append(self.alloc(), try self.parseExpr());
                        } else {
                            try args.append(self.alloc(), try self.parseType());
                        }
                    }
                }
                _ = try self.expect(.rparen);
                return self.newNode(.{ .type_generic = .{
                    .name = tok.text,
                    .args = try args.toOwnedSlice(self.alloc()),
                }});
            }
            // Check for scoped type: mem.Allocator, etc.
            if (self.check(.dot)) {
                _ = self.advance();
                const field_tok = try self.expect(.identifier);
                const full_name = try std.fmt.allocPrint(self.alloc(), "{s}.{s}", .{ tok.text, field_tok.text });
                return self.newNode(.{ .type_named = full_name });
            }
            return self.newNode(.{ .type_named = tok.text });
        }

        // Special keywords as types
        if (tok.kind == .kw_any) {
            _ = self.advance();
            return self.newNode(.{ .type_named = "any" });
        }
        if (tok.kind == .kw_void) {
            _ = self.advance();
            return self.newNode(.{ .type_named = "void" });
        }
        if (tok.kind == .kw_null) {
            _ = self.advance();
            return self.newNode(.{ .type_named = "null" });
        }
        const msg = try std.fmt.allocPrint(self.alloc(),
            "expected type, found '{s}'", .{tok.text});
        defer self.alloc().free(msg);
        try self.reporter.report(.{
            .message = msg,
            .loc = .{ .file = "", .line = tok.line, .col = tok.col },
        });
        return error.ParseError;
    }

    fn parseParenType(self: *Parser) anyerror!*Node {
        _ = try self.expect(.lparen);
        self.skipNewlines();

        // Empty parens — void
        if (self.check(.rparen)) {
            _ = self.advance();
            return self.newNode(.{ .type_named = "void" });
        }

        // Named tuple type: (name: T, name: T, ...)
        if (self.peek().kind == .identifier and self.peekAt(1).kind == .colon) {
            var fields: std.ArrayListUnmanaged(NamedTypeField) = .{};
            while (!self.check(.rparen) and !self.check(.eof)) {
                self.skipNewlines();
                const name_tok = try self.expect(.identifier);
                _ = try self.expect(.colon);
                const field_type = try self.parseType();
                try fields.append(self.alloc(), .{
                    .name = name_tok.text,
                    .type_node = field_type,
                    .default = null,
                });
                self.skipNewlines();
                if (!self.eat(.comma)) break;
                self.skipNewlines();
            }
            _ = try self.expect(.rparen);
            return self.newNode(.{ .type_tuple_named = try fields.toOwnedSlice(self.alloc()) });
        }

        const first_type = try self.parseType();
        self.skipNewlines();

        // Union type: (T | U)
        if (self.check(.pipe)) {
            var types: std.ArrayListUnmanaged(*Node) = .{};
            try types.append(self.alloc(), first_type);
            while (self.check(.pipe)) {
                _ = self.advance();
                self.skipNewlines();
                try types.append(self.alloc(), try self.parseType());
                self.skipNewlines();
            }
            _ = try self.expect(.rparen);
            return self.newNode(.{ .type_union = try types.toOwnedSlice(self.alloc()) });
        }

        // Single type in parens — just return it
        _ = try self.expect(.rparen);
        return first_type;
    }

    fn isPrimitiveKeyword(kind: TokenKind) bool {
        _ = kind;
        return false; // Primitive types are identifiers in Kodr
    }
};

fn tokenFriendlyName(kind: lexer.TokenKind) []const u8 {
    return switch (kind) {
        .identifier => "identifier",
        .int_literal => "number",
        .float_literal => "number",
        .string_literal => "string",
        .lparen => "(",
        .rparen => ")",
        .lbrace => "{",
        .rbrace => "}",
        .lbracket => "[",
        .rbracket => "]",
        .comma => ",",
        .dot => ".",
        .colon => ":",
        .eq => "==",
        .neq => "!=",
        .assign => "=",
        .newline => "newline",
        .eof => "end of file",
        .kw_func => "func",
        .kw_var => "var",
        .kw_const => "const",
        .kw_return => "return",
        .kw_if => "if",
        .kw_else => "else",
        .kw_while => "while",
        .kw_for => "for",
        .kw_match => "match",
        .kw_struct => "struct",
        .kw_enum => "enum",
        .kw_import => "import",
        .kw_module => "module",
        .kw_pub => "pub",
        .kw_test => "test",
        .kw_main => "main",
        else => @tagName(kind),
    };
}

test "parser - module tokens debug" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    // 'main' is a keyword so it tokenizes as kw_main, not identifier
    try std.testing.expectEqual(lexer.TokenKind.kw_module,    tokens.items[0].kind);
    try std.testing.expectEqual(lexer.TokenKind.kw_main,      tokens.items[1].kind);
    try std.testing.expectEqualStrings("main",                tokens.items[1].text);
    try std.testing.expectEqual(lexer.TokenKind.newline,      tokens.items[2].kind);
    try std.testing.expectEqual(lexer.TokenKind.eof,          tokens.items[3].kind);
    try std.testing.expectEqual(@as(usize, 4),                tokens.items.len);
}

test "parser - module declaration" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var parser = Parser.init(tokens.items, alloc, &reporter);
    defer parser.deinit();

    const module = try parser.parseModuleDecl();
    try std.testing.expectEqualStrings("main", module.module_decl.name);
    try std.testing.expect(!reporter.hasErrors());
}

test "parser - simple function" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func add(a: i32, b: i32) i32 {
        \\return a
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var parser = Parser.init(tokens.items, alloc, &reporter);
    defer parser.deinit();

    const prog = try parser.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.top_level.len);
}

test "parser - var declaration inside function" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func test_fn() void {
        \\var x: i32 = 42
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var parser = Parser.init(tokens.items, alloc, &reporter);
    defer parser.deinit();

    const prog = try parser.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.top_level.len);
    try std.testing.expect(prog.program.top_level[0].* == .func_decl);
}

test "parser - extern func" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module console
        \\extern func print(msg: String) void
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.top_level.len);
    const f = prog.program.top_level[0];
    try std.testing.expect(f.* == .func_decl);
    try std.testing.expect(f.func_decl.is_extern);
    try std.testing.expect(f.func_decl.is_pub);
    try std.testing.expectEqualStrings("print", f.func_decl.name);
}

test "parser - scoped import" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\import std::console
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.imports.len);
    const imp = prog.program.imports[0].import_decl;
    try std.testing.expectEqualStrings("console", imp.path);
    try std.testing.expectEqualStrings("std", imp.scope.?);
    try std.testing.expect(imp.alias == null);
}

test "parser - scoped import with alias" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\import std::console as io
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const imp = prog.program.imports[0].import_decl;
    try std.testing.expectEqualStrings("console", imp.path);
    try std.testing.expectEqualStrings("std",    imp.scope.?);
    try std.testing.expectEqualStrings("io",     imp.alias.?);
}

test "parser - invalid scope rejected" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\import foo::bar
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    _ = p.parseProgram() catch {};
    try std.testing.expect(reporter.hasErrors());
}

test "parser - if else" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func check() void {
        \\if(true) {
        \\var x: i32 = 1
        \\} else {
        \\var x: i32 = 2
        \\}
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.top_level.len);
}

test "parser - struct declaration" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\struct Point {
        \\x: f64
        \\y: f64
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), prog.program.top_level.len);
    try std.testing.expect(prog.program.top_level[0].* == .struct_decl);
    try std.testing.expectEqualStrings("Point", prog.program.top_level[0].struct_decl.name);
    try std.testing.expectEqual(@as(usize, 2), prog.program.top_level[0].struct_decl.members.len);
}

test "parser - enum declaration" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\enum(u8) Direction {
        \\North
        \\South
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(prog.program.top_level[0].* == .enum_decl);
    try std.testing.expectEqualStrings("Direction", prog.program.top_level[0].enum_decl.name);
}

test "parser - compt func" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\compt func double(n: i32) i32 {
        \\return n * 2
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(prog.program.top_level[0].* == .func_decl);
    try std.testing.expect(prog.program.top_level[0].func_decl.is_compt);
}

test "parser - compt for is rejected" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func test_fn() void {
        \\compt for(items) |item| {
        \\var x: i32 = 0
        \\}
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    _ = p.parseProgram() catch {};
    try std.testing.expect(reporter.hasErrors());
}

test "parser - for with range" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func test_fn() void {
        \\for(0..10) |i| {
        \\var x: i32 = 0
        \\}
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const body = prog.program.top_level[0].func_decl.body;
    const for_node = body.block.statements[0];
    try std.testing.expect(for_node.* == .for_stmt);
    try std.testing.expect(for_node.for_stmt.iterable.* == .range_expr);
    try std.testing.expectEqualStrings("i", for_node.for_stmt.captures[0]);
}

test "parser - while loop" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func test_fn() void {
        \\var x: i32 = 0
        \\while (x < 10) {
        \\x = x + 1
        \\}
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const body = prog.program.top_level[0].func_decl.body;
    const while_node = body.block.statements[1];
    try std.testing.expect(while_node.* == .while_stmt);
}

test "parser - match on value" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func test_fn(x: i32) void {
        \\match x {
        \\1 => {}
        \\2 => {}
        \\else => {}
        \\}
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const body = prog.program.top_level[0].func_decl.body;
    const match_node = body.block.statements[0];
    try std.testing.expect(match_node.* == .match_stmt);
    try std.testing.expect(match_node.match_stmt.arms.len == 3);
}

test "parser - metadata #build and #version" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\#build = exe
        \\#version = Version(1, 2, 3)
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(prog.program.metadata.len == 2);
    try std.testing.expectEqualStrings("build", prog.program.metadata[0].metadata.field);
    try std.testing.expectEqualStrings("version", prog.program.metadata[1].metadata.field);
}

test "parser - metadata #dep with version" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\#dep "../mylib" Version(1, 0, 0)
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(prog.program.metadata.len == 1);
    try std.testing.expectEqualStrings("dep", prog.program.metadata[0].metadata.field);
    try std.testing.expect(prog.program.metadata[0].metadata.extra != null);
}

test "parser - bitfield declaration" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\bitfield(u8) Perms {
        \\Read
        \\Write
        \\Execute
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const bf = prog.program.top_level[0];
    try std.testing.expect(bf.* == .bitfield_decl);
    try std.testing.expectEqualStrings("Perms", bf.bitfield_decl.name);
    try std.testing.expect(bf.bitfield_decl.members.len == 3);
}

test "parser - tuple type" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func bounds() (min: i32, max: i32) {
        \\return (min: 0, max: 100)
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const func = prog.program.top_level[0];
    try std.testing.expect(func.func_decl.return_type.* == .type_tuple_named);
}

test "parser - function pointer type" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\func apply(f: func(i32) i32, x: i32) i32 {
        \\return f(x)
        \\}
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const prog = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());
    const func = prog.program.top_level[0];
    const param_type = func.func_decl.params[0].param.type_annotation;
    try std.testing.expect(param_type.* == .type_func);
}

test "parser - module-level var rejected" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\var x: i32 = 0
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    _ = p.parseProgram() catch {};
    try std.testing.expect(reporter.hasErrors());
}

test "parser - pub var rejected" {
    const alloc = std.testing.allocator;
    var lex = lexer.Lexer.init((
        \\module main
        \\pub var x: i32 = 0
        \\
    ));
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    _ = p.parseProgram() catch {};
    try std.testing.expect(reporter.hasErrors());
}
