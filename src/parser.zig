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
    bitfield_decl,
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
    throw_stmt,
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
    collection_expr,
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
    interpolated_string,
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
    blueprint_decl: BlueprintDecl,
    enum_decl: EnumDecl,
    bitfield_decl: BitfieldDecl,
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
    throw_stmt: ThrowStmt,
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
    collection_expr: CollectionExpr,
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
    interpolated_string: InterpolatedString,
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
    doc: ?[]const u8 = null,
};

pub const ImportDecl = struct {
    path: []const u8,       // module name
    scope: ?[]const u8,     // "std", "global", or null for project-local
    alias: ?[]const u8,     // rename with `as`
    is_c_header: bool,
    is_include: bool,       // `include` dumps symbols into namespace
};

pub const Metadata = struct {
    field: []const u8,
    value: *Node,
    extra: ?*Node = null,              // version node for #dep, null otherwise
    cimport_include: ?[]const u8 = null, // include path from #cimport { include: "..." }
    cimport_source: ?[]const u8 = null,  // source file from #cimport { source: "..." }
};

pub const FuncContext = enum {
    normal,
    compt,
    thread, // thread declaration — generates spawn wrapper + body
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

pub const BitfieldDecl = struct {
    name: []const u8,
    backing_type: *Node,
    members: [][]const u8,  // flag names only — no data fields
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
    fields: []*Node, // params for data-carrying variants
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

pub const ThrowStmt = struct {
    variable: []const u8,
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

pub const CollectionExpr = struct {
    kind: []const u8, // "List", "Map", "Set", "Ring", "ORing"
    type_args: []*Node, // [T] for List/Set/Ring/ORing, [K, V] for Map
    size_arg: ?*Node = null, // capacity for Ring/ORing
    alloc_arg: ?*Node, // null = use default owned allocator
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
