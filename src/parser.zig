// parser.zig — Orhon AST type definitions
// AST uses arena allocation — entire tree freed in one call when done.
// Parsing is handled by the PEG engine (src/peg/).

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
    blueprint_decl,
    enum_decl,
    handle_decl,
    var_decl,
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
    // Expressions
    binary_expr,
    unary_expr,
    call_expr,
    index_expr,
    slice_expr,
    field_expr,
    mut_borrow_expr,
    const_borrow_expr,
    compiler_func,
    identifier,
    int_literal,
    float_literal,
    string_literal,
    bool_literal,
    null_literal,
    array_literal,
    tuple_literal,
    version_literal,
    error_literal,
    range_expr,
    interpolated_string,
    // Types
    type_slice,
    type_array,
    type_ptr,
    type_union,
    type_tuple_named,
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
    blueprint_decl: BlueprintDecl,
    enum_decl: EnumDecl,
    handle_decl: HandleDecl,
    var_decl: VarDecl,
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
    binary_expr: BinaryOp,
    unary_expr: UnaryOp,
    call_expr: CallExpr,
    index_expr: IndexExpr,
    slice_expr: SliceExpr,
    field_expr: FieldExpr,
    mut_borrow_expr: *Node,
    const_borrow_expr: *Node,
    compiler_func: CompilerFunc,
    identifier: []const u8,
    int_literal: []const u8,
    float_literal: []const u8,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal: void,
    array_literal: []*Node,
    tuple_literal: TupleLiteral,
    version_literal: [3][]const u8,
    error_literal: []const u8,
    range_expr: BinaryOp,
    interpolated_string: InterpolatedString,
    type_slice: *Node,
    type_array: TypeArray,
    type_ptr: TypePtr,
    type_union: []*Node,
    type_tuple_named: []NamedTypeField,
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
    doc: ?[]const u8 = null,
};

pub const ImportDecl = struct {
    path: []const u8,       // module name
    scope: ?[]const u8,     // "std", "global", or null for project-local
    alias: ?[]const u8,     // rename with `as`
    is_include: bool,       // `include` dumps symbols into namespace
};

pub const MetadataField = enum {
    build,
    version,
    description,

    const map = std.StaticStringMap(MetadataField).initComptime(.{
        .{ "build", .build },
        .{ "version", .version },
        .{ "description", .description },
    });

    pub fn parse(raw: []const u8) ?MetadataField {
        return map.get(raw);
    }
};

pub const Metadata = struct {
    field: MetadataField,
    value: *Node,
};

pub const FuncContext = enum {
    normal,
    compt,
};

pub const FuncDecl = struct {
    name: []const u8,
    params: []*Node,
    return_type: *Node,
    body: *Node,
    context: FuncContext,
    is_pub: bool,
    doc: ?[]const u8 = null,
};

pub const StructDecl = struct {
    name: []const u8,
    type_params: []*Node, // generic params: (T: type, U: type)
    members: []*Node,
    blueprints: []const []const u8 = &.{}, // blueprint names from `: Eq, Hash`
    is_pub: bool,
    doc: ?[]const u8 = null,
};

pub const BlueprintDecl = struct {
    name: []const u8,
    methods: []*Node, // func_decl nodes (signature only, no body)
    is_pub: bool,
    doc: ?[]const u8 = null,
};

pub const EnumDecl = struct {
    name: []const u8,
    backing_type: *Node,
    members: []*Node,
    is_pub: bool,
    doc: ?[]const u8 = null,
};

pub const HandleDecl = struct {
    name: []const u8,
    is_pub: bool,
    doc: ?[]const u8 = null,
};

pub const Mutability = enum { mutable, constant };

pub const VarDecl = struct {
    name: []const u8,
    type_annotation: ?*Node,
    value: *Node,
    is_pub: bool,
    mutability: Mutability = .mutable,
    doc: ?[]const u8 = null,
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
    doc: ?[]const u8 = null,
};

pub const EnumVariant = struct {
    name: []const u8,
    value: ?*Node = null,
    doc: ?[]const u8 = null,
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
    iterables: []*Node,
    captures: [][]const u8,
    body: *Node,
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
    guard: ?*Node,
    body: *Node,
};

pub const InterpolatedPart = union(enum) {
    literal: []const u8, // string chunk (raw text, no quotes)
    expr: *Node, // embedded expression
};

pub const InterpolatedString = struct {
    parts: []InterpolatedPart,
};

pub const Operator = enum {
    // arithmetic
    add,        // +
    sub,        // -
    mul,        // *
    div,        // /
    mod,        // %
    // string
    concat,     // ++
    // range
    range,      // ..
    // logical
    @"and",     // and
    @"or",      // or
    not,        // not
    // comparison
    eq,         // ==
    ne,         // !=
    lt,         // <
    gt,         // >
    le,         // <=
    ge,         // >=
    // bitwise
    bit_or,     // |
    bit_xor,    // ^
    bit_and,    // &
    shl,        // <<
    shr,        // >>
    // unary
    negate,     // - (unary)
    bang,       // !
    // assignment
    assign,     // =
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    div_assign, // /=

    const map = std.StaticStringMap(Operator).initComptime(.{
        .{ "+", .add },
        .{ "-", .sub },
        .{ "*", .mul },
        .{ "/", .div },
        .{ "%", .mod },
        .{ "++", .concat },
        .{ "..", .range },
        .{ "and", .@"and" },
        .{ "or", .@"or" },
        .{ "not", .not },
        .{ "==", .eq },
        .{ "!=", .ne },
        .{ "<", .lt },
        .{ ">", .gt },
        .{ "<=", .le },
        .{ ">=", .ge },
        .{ "|", .bit_or },
        .{ "^", .bit_xor },
        .{ "&", .bit_and },
        .{ "<<", .shl },
        .{ ">>", .shr },
        .{ "!", .bang },
        .{ "=", .assign },
        .{ "+=", .add_assign },
        .{ "-=", .sub_assign },
        .{ "*=", .mul_assign },
        .{ "/=", .div_assign },
    });

    pub fn parse(raw: []const u8) Operator {
        return map.get(raw) orelse .assign;
    }

    /// Convert to Zig source text for codegen emission.
    pub fn toZig(self: Operator) []const u8 {
        return switch (self) {
            .add => "+",
            .sub, .negate => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .concat => "++",
            .range => "..",
            .@"and" => "and",
            .@"or" => "or",
            .not => "!",
            .bang => "~",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .gt => ">",
            .le => "<=",
            .ge => ">=",
            .bit_or => "|",
            .bit_xor => "^",
            .bit_and => "&",
            .shl => "<<",
            .shr => ">>",
            .assign => "=",
            .add_assign => "+=",
            .sub_assign => "-=",
            .mul_assign => "*=",
            .div_assign => "/=",
        };
    }

    pub fn isComparison(self: Operator) bool {
        return switch (self) {
            .eq, .ne, .lt, .gt, .le, .ge => true,
            else => false,
        };
    }

    pub fn isLogical(self: Operator) bool {
        return switch (self) {
            .@"and", .@"or", .not => true,
            else => false,
        };
    }
};

pub const BinaryOp = struct {
    op: Operator,
    left: *Node,
    right: *Node,
};

pub const UnaryOp = struct {
    op: Operator,
    operand: *Node,
};

pub const CallExpr = struct {
    callee: *Node,
    args: []*Node,
    arg_names: [][]const u8, // non-empty for struct init: Player{name: "hero"}
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

pub const TupleLiteral = struct {
    /// Element expressions. For named form, `names[i]` is the key for `elements[i]`.
    elements: []*Node,
    /// null when all elements are positional; non-null (same length as elements) when named.
    names: ?[][]const u8,
};

pub const TypeArray = struct {
    size: *Node,
    elem: *Node,
};

/// Pointer kind — shared by AST TypePtr and ResolvedType.Ptr.
/// Replaces string-based "mut&"/"const&" comparisons.
pub const PtrKind = enum {
    const_ref,
    mut_ref,

    pub fn isMutable(self: PtrKind) bool {
        return self == .mut_ref;
    }
};

pub const TypePtr = struct {
    kind: PtrKind,
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

/// Map from AST node pointers to their source locations
pub const LocMap = std.AutoHashMap(*Node, errors.SourceLoc);

// ── Tests ──

test "Operator.parse - all operators" {
    try std.testing.expectEqual(Operator.add, Operator.parse("+"));
    try std.testing.expectEqual(Operator.sub, Operator.parse("-"));
    try std.testing.expectEqual(Operator.mul, Operator.parse("*"));
    try std.testing.expectEqual(Operator.div, Operator.parse("/"));
    try std.testing.expectEqual(Operator.mod, Operator.parse("%"));
    try std.testing.expectEqual(Operator.concat, Operator.parse("++"));
    try std.testing.expectEqual(Operator.range, Operator.parse(".."));
    try std.testing.expectEqual(Operator.@"and", Operator.parse("and"));
    try std.testing.expectEqual(Operator.@"or", Operator.parse("or"));
    try std.testing.expectEqual(Operator.not, Operator.parse("not"));
    try std.testing.expectEqual(Operator.eq, Operator.parse("=="));
    try std.testing.expectEqual(Operator.ne, Operator.parse("!="));
    try std.testing.expectEqual(Operator.lt, Operator.parse("<"));
    try std.testing.expectEqual(Operator.gt, Operator.parse(">"));
    try std.testing.expectEqual(Operator.le, Operator.parse("<="));
    try std.testing.expectEqual(Operator.ge, Operator.parse(">="));
    try std.testing.expectEqual(Operator.bit_or, Operator.parse("|"));
    try std.testing.expectEqual(Operator.bit_xor, Operator.parse("^"));
    try std.testing.expectEqual(Operator.bit_and, Operator.parse("&"));
    try std.testing.expectEqual(Operator.shl, Operator.parse("<<"));
    try std.testing.expectEqual(Operator.shr, Operator.parse(">>"));
    try std.testing.expectEqual(Operator.bang, Operator.parse("!"));
    try std.testing.expectEqual(Operator.assign, Operator.parse("="));
    try std.testing.expectEqual(Operator.add_assign, Operator.parse("+="));
    try std.testing.expectEqual(Operator.sub_assign, Operator.parse("-="));
    try std.testing.expectEqual(Operator.mul_assign, Operator.parse("*="));
    try std.testing.expectEqual(Operator.div_assign, Operator.parse("/="));
}

test "Operator.parse - unknown falls back to assign" {
    try std.testing.expectEqual(Operator.assign, Operator.parse("???"));
    try std.testing.expectEqual(Operator.assign, Operator.parse(""));
}

test "Operator.toZig - round trip" {
    const ops = [_]Operator{
        .add, .sub, .mul, .div, .mod, .eq, .ne,
        .lt,  .gt,  .le,  .ge,  .bit_or, .bit_xor, .bit_and,
        .shl, .shr, .assign, .add_assign, .sub_assign,
        .mul_assign, .div_assign, .concat, .range,
    };
    for (ops) |op| {
        const zig_str = op.toZig();
        try std.testing.expect(zig_str.len > 0);
    }
}

test "Operator.isComparison" {
    try std.testing.expect(Operator.eq.isComparison());
    try std.testing.expect(Operator.ne.isComparison());
    try std.testing.expect(Operator.lt.isComparison());
    try std.testing.expect(!Operator.add.isComparison());
    try std.testing.expect(!Operator.assign.isComparison());
}

// ============================================================
// AST UTILITIES
// ============================================================

/// Returns true if the given node or block contains an early exit
/// (return, break, continue) at the top level of its statements.
/// Recurses into nested blocks and if/else branches.
pub fn blockHasEarlyExit(node: *Node) bool {
    if (node.* != .block) return nodeIsEarlyExit(node);
    for (node.block.statements) |stmt| {
        if (nodeIsEarlyExit(stmt)) return true;
    }
    return false;
}

fn nodeIsEarlyExit(node: *Node) bool {
    return switch (node.*) {
        .return_stmt => true,
        .break_stmt => true,
        .continue_stmt => true,
        .block => blockHasEarlyExit(node),
        .if_stmt => |i| blk: {
            const else_block = i.else_block orelse break :blk false;
            break :blk blockHasEarlyExit(i.then_block) and blockHasEarlyExit(else_block);
        },
        .match_stmt => |m| blk: {
            if (m.arms.len == 0) break :blk false;
            for (m.arms) |arm| {
                if (arm.* != .match_arm) break :blk false;
                if (!blockHasEarlyExit(arm.match_arm.body)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

test "MetadataField.parse - known fields" {
    try std.testing.expectEqual(MetadataField.build, MetadataField.parse("build").?);
    try std.testing.expectEqual(MetadataField.version, MetadataField.parse("version").?);
    try std.testing.expectEqual(MetadataField.description, MetadataField.parse("description").?);
}

test "MetadataField.parse - unknown returns null" {
    try std.testing.expect(MetadataField.parse("foo") == null);
    try std.testing.expect(MetadataField.parse("") == null);
    try std.testing.expect(MetadataField.parse("name") == null);
}
