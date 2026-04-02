// mir_node.zig — MIR tree node data structures

const std = @import("std");
const parser = @import("../parser.zig");
const mir_types = @import("mir_types.zig");

pub const RT = mir_types.RT;
pub const TypeClass = mir_types.TypeClass;
pub const Coercion = mir_types.Coercion;

// ── MIR Node Tree ──────────────────────────────────────────

/// MIR node — self-contained representation for codegen.
/// All semantic data is on MirNode fields. The `ast` back-pointer is retained
/// only as a permanent architectural boundary for two categories:
/// 1. typeToZig() walks the recursive AST type tree (type_named, type_slice,
///    type_array, type_union, type_ptr, etc.) for structural syntax-to-syntax
///    translation. Duplicating this tree into MirNode adds complexity with no
///    benefit — type trees are purely structural.
/// 2. type_expr and passthrough MirKinds carry AST pointers that codegen reads
///    via typeToZig() for the same reason.
/// Source locations read through ast via nodeLocMir().
pub const MirNode = struct {
    /// Original AST node — retained for typeToZig/type_expr structural type trees
    /// and source location queries (via nodeLocMir). See struct doc for details.
    ast: *parser.Node,
    /// Resolved type of this node.
    resolved_type: RT,
    /// How codegen should treat this node.
    type_class: TypeClass,
    /// Explicit coercion to emit.
    coercion: ?Coercion = null,
    coerce_tag: ?[]const u8 = null,
    /// For type narrowing after `is` checks.
    narrowed_to: ?[]const u8 = null,
    /// Node kind (grouped from 52 AST kinds to ~32 MIR kinds).
    kind: MirKind,
    /// Child nodes (ordered: statements in block, args in call, etc.).
    children: []*MirNode,
    /// For injected nodes (temp_var, injected_defer) that have no AST name.
    injected_name: ?[]const u8 = null,
    /// Pre-computed type narrowing for if_stmt with `is` checks.
    narrowing: ?IfNarrowing = null,

    // ── Self-contained data fields ──────────────────────────
    // These carry the essential data from the AST node so codegen
    // doesn't need to read through the ast back-pointer.

    /// Name: func name, struct name, enum name, var name, identifier, test description, param name.
    name: ?[]const u8 = null,
    /// Operator: binary op, unary op, assignment op.
    op: ?[]const u8 = null,
    /// Literal value text: int, float, string literals.
    literal: ?[]const u8 = null,
    /// Bool literal value.
    bool_val: bool = false,
    /// Public visibility flag.
    is_pub: bool = false,
    /// Thread function flag.
    is_thread: bool = false,
    /// Compile-time declaration flag.
    is_compt: bool = false,
    /// Literal sub-kind (int, float, string, bool, null, error).
    literal_kind: ?LiteralKind = null,
    /// Const declaration flag (true for constant, false for mutable).
    is_const: bool = false,
    /// Type annotation AST node (borrowed pointer — lives as long as AST arena).
    type_annotation: ?*parser.Node = null,
    /// Generic type parameters (for struct/func generics).
    type_params: ?[]*parser.Node = null,
    /// Return type AST node (for func_decl).
    return_type: ?*parser.Node = null,
    /// Backing type AST node (for enum/bitfield).
    backing_type: ?*parser.Node = null,
    /// Bitfield member names.
    bit_members: ?[][]const u8 = null,
    /// Named call argument names.
    arg_names: ?[][]const u8 = null,
    /// Named tuple flag.
    is_named_tuple: bool = false,
    /// Tuple field names.
    field_names: ?[][]const u8 = null,
    /// For-loop capture variable names.
    captures: ?[][]const u8 = null,
    /// For-loop index variable name.
    index_var: ?[]const u8 = null,
    /// Destructuring binding names.
    names: ?[][]const u8 = null,
    /// Interpolated string parts (literal + expr interleaved).
    interp_parts: ?[]parser.InterpolatedPart = null,

    // ── Child accessors ─────────────────────────────────────
    // Named access into children[] so codegen doesn't use raw indices.
    // Child layout per kind documented in MirLowerer.lowerNode().

    /// Last child — body block for func, test_def, defer_stmt, match_arm.
    pub fn body(self: *const MirNode) *MirNode {
        return self.children[self.children.len - 1];
    }

    /// children[0] — condition for if_stmt, while_stmt.
    pub fn condition(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// children[1] — then block for if_stmt.
    pub fn thenBlock(self: *const MirNode) *MirNode {
        return self.children[1];
    }

    /// children[2] if exists — else block for if_stmt.
    pub fn elseBlock(self: *const MirNode) ?*MirNode {
        if (self.children.len > 2) return self.children[2];
        return null;
    }

    /// children[0] — left operand for binary, assignment.
    pub fn lhs(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// children[1] — right operand for binary, assignment.
    pub fn rhs(self: *const MirNode) *MirNode {
        return self.children[1];
    }

    /// children[0] — callee for call.
    pub fn getCallee(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// children[1..] — arguments for call.
    pub fn callArgs(self: *const MirNode) []*MirNode {
        return self.children[1..];
    }

    /// children[0] — value for var_decl, return_stmt, destruct.
    pub fn value(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// children[0] — iterable for for_stmt.
    pub fn iterable(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// children[0..len-1] — params for func (everything except last child = body).
    pub fn params(self: *const MirNode) []*MirNode {
        if (self.children.len == 0) return &.{};
        return self.children[0 .. self.children.len - 1];
    }

    /// First child as default value (for field_def and param_def kinds with defaults).
    pub fn defaultChild(self: *const MirNode) ?*MirNode {
        if ((self.kind == .field_def or self.kind == .param_def) and self.children.len > 0)
            return self.children[0];
        return null;
    }

    /// children[1..] — match arms for match_stmt (children[0] = value).
    pub fn matchArms(self: *const MirNode) []*MirNode {
        return self.children[1..];
    }

    /// children[0] — pattern for match_arm.
    pub fn pattern(self: *const MirNode) *MirNode {
        return self.children[0];
    }

    /// Guard expression for match_arm.
    /// Returns children[1] when children.len == 3 (layout: [pattern, guard, body]),
    /// null when children.len == 2 (layout: [pattern, body]).
    pub fn guard(self: *const MirNode) ?*MirNode {
        if (self.children.len == 3) return self.children[1];
        return null;
    }
};

/// Disambiguates the 6 literal types collapsed into MirKind.literal.
pub const LiteralKind = enum {
    int,
    float,
    string,
    bool_lit,
    null_lit,
    error_lit,
};

/// MIR node kinds — grouped from 52 AST kinds.
pub const MirKind = enum {
    // Declarations
    func,
    struct_def,
    enum_def,
    bitfield_def,
    var_decl,
    test_def,
    destruct,
    import,
    // Statements
    block,
    return_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    defer_stmt,
    match_stmt,
    match_arm,
    assignment,
    break_stmt,
    continue_stmt,
    throw_stmt,
    // Expressions
    literal, // int, float, string, bool, null, error
    identifier,
    binary, // binary_expr, range_expr
    unary,
    call,
    field_access,
    index,
    slice,
    borrow,
    interpolation,
    collection,
    compiler_fn,
    array_lit,
    tuple_lit,
    // Types — passthrough (codegen reads ast.* via typeToZig)
    type_expr,
    // Injected nodes (no AST counterpart)
    temp_var,
    injected_defer,
    // Struct/enum members and function params
    field_def,
    param_def,
    enum_variant_def,
    // Passthrough for unhandled/structural nodes
    passthrough,
};

/// Pre-computed type narrowing for if_stmt with `is` checks.
pub const IfNarrowing = struct {
    var_name: []const u8,
    then_type: ?[]const u8 = null,
    else_type: ?[]const u8 = null,
    post_type: ?[]const u8 = null, // after if, if then-block has early exit
};
