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
    op: ?@import("../parser.zig").Operator = null,
    /// Literal value text: int, float, string literals.
    literal: ?[]const u8 = null,
    /// Bool literal value.
    bool_val: bool = false,
    /// Public visibility flag.
    is_pub: bool = false,
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
    /// Backing type AST node (for enum).
    backing_type: ?*parser.Node = null,
    /// Named call argument names.
    arg_names: ?[][]const u8 = null,
    /// For-loop capture variable names.
    captures: ?[][]const u8 = null,
    /// For-loop tuple capture flag (struct field destructuring).
    is_tuple_capture: bool = false,
    /// Number of iterables in for-loop (children[0..num_iterables] are iterables, last child is body).
    num_iterables: usize = 0,
    /// Destructuring binding names.
    names: ?[][]const u8 = null,
    /// Interpolated string parts (literal + expr interleaved).
    interp_parts: ?[]parser.InterpolatedPart = null,
    /// Identifier/type-expr name resolution stamped by MirLowerer from DeclTable.
    /// Lets codegen emit enum-aware output without querying declarations at emit time.
    resolved_kind: ?ResolvedKind = null,
    /// Expected operand type for `@overflow(a OP b)`. Stamped by MirLowerer onto
    /// the binary child when the enclosing var_decl has an explicit type annotation,
    /// so codegen doesn't need to walk mutable `type_ctx` state to resolve literal
    /// operand types to a concrete Zig type.
    overflow_type: ?*parser.Node = null,

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

    /// children[0..num_iterables] — iterables for for_stmt.
    pub fn iterables(self: *const MirNode) []*MirNode {
        return self.children[0..self.num_iterables];
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

/// Identifier/type-expr name resolution produced by MirLowerer from DeclTable.
/// Used so codegen doesn't need to query declarations at emit time.
pub const ResolvedKind = enum {
    /// Name matches an enum variant in some declared enum.
    enum_variant,
    /// Name matches a declared enum type.
    enum_type_name,
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
    handle_def,
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
    compiler_fn,
    array_lit,
    tuple_lit,
    version_lit,
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
    type_class: TypeClass = .plain, // union category for codegen unwrap expression
};

// ── Tests ──────────────────────────────────────────────────

test "MirNode - body returns last child" {
    var c0 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var c1 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var children = [_]*MirNode{ &c0, &c1 };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .func, .children = &children };
    try std.testing.expect(node.body() == &c1);
}

test "MirNode - condition and thenBlock" {
    var cond = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var then_blk = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var children = [_]*MirNode{ &cond, &then_blk };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .if_stmt, .children = &children };
    try std.testing.expect(node.condition() == &cond);
    try std.testing.expect(node.thenBlock() == &then_blk);
    try std.testing.expect(node.elseBlock() == null);
}

test "MirNode - elseBlock present" {
    var cond = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var then_blk = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var els = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var children = [_]*MirNode{ &cond, &then_blk, &els };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .if_stmt, .children = &children };
    try std.testing.expect(node.elseBlock().? == &els);
}

test "MirNode - lhs and rhs" {
    var left = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .identifier, .children = &.{} };
    var right = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var children = [_]*MirNode{ &left, &right };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .binary, .children = &children };
    try std.testing.expect(node.lhs() == &left);
    try std.testing.expect(node.rhs() == &right);
}

test "MirNode - callArgs" {
    var callee = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .identifier, .children = &.{} };
    var arg1 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var arg2 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var children = [_]*MirNode{ &callee, &arg1, &arg2 };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .call, .children = &children };
    try std.testing.expect(node.getCallee() == &callee);
    try std.testing.expectEqual(@as(usize, 2), node.callArgs().len);
}

test "MirNode - params excludes body" {
    var p1 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .param_def, .children = &.{} };
    var p2 = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .param_def, .children = &.{} };
    var body_node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var children = [_]*MirNode{ &p1, &p2, &body_node };
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .func, .children = &children };
    try std.testing.expectEqual(@as(usize, 2), node.params().len);
    try std.testing.expect(node.body() == &body_node);
}

test "MirNode - params empty" {
    var node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .func, .children = &.{} };
    try std.testing.expectEqual(@as(usize, 0), node.params().len);
}

test "MirNode - defaultChild" {
    var def_val = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var children = [_]*MirNode{&def_val};
    // field_def with children → has default
    var field = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .field_def, .children = &children };
    try std.testing.expect(field.defaultChild() != null);
    // non-field_def/param_def → no default
    var other = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &children };
    try std.testing.expect(other.defaultChild() == null);
    // field_def with no children → no default
    var empty_field = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .field_def, .children = &.{} };
    try std.testing.expect(empty_field.defaultChild() == null);
}

test "MirNode - matchArms and pattern" {
    var val = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .identifier, .children = &.{} };
    var pat = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var arm_body = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    var arm_children = [_]*MirNode{ &pat, &arm_body };
    var arm = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_arm, .children = &arm_children };
    var match_children = [_]*MirNode{ &val, &arm };
    var match_node = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_stmt, .children = &match_children };
    try std.testing.expectEqual(@as(usize, 1), match_node.matchArms().len);
    try std.testing.expect(arm.pattern() == &pat);
}

test "MirNode - guard present and absent" {
    var pat = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .literal, .children = &.{} };
    var arm_body = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .block, .children = &.{} };
    // No guard: 2 children [pattern, body]
    var children2 = [_]*MirNode{ &pat, &arm_body };
    var arm_no_guard = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_arm, .children = &children2 };
    try std.testing.expect(arm_no_guard.guard() == null);
    // With guard: 3 children [pattern, guard, body]
    var guard_n = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .binary, .children = &.{} };
    var children3 = [_]*MirNode{ &pat, &guard_n, &arm_body };
    var arm_with_guard = MirNode{ .ast = undefined, .resolved_type = .unknown, .type_class = .plain, .kind = .match_arm, .children = &children3 };
    try std.testing.expect(arm_with_guard.guard().? == &guard_n);
}
