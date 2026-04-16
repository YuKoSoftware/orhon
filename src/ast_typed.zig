// ast_typed.zig — typed wrappers per AstKind with pack/unpack round-trips (Phase A3)
//
// Each public namespace corresponds to one AstKind.  Every namespace exposes:
//   Record   — the semantic fields in index form (no pointers)
//   pack     — allocates store entries and returns the new AstNodeIndex
//   unpack   — reads a previously-packed node back into a Record
//
// Encoding choices follow the Data slot guide from the A3 spec.

const std = @import("std");
const ast = @import("ast_store.zig");

pub const AstStore = ast.AstStore;
pub const AstNodeIndex = ast.AstNodeIndex;
pub const ExtraIndex = ast.ExtraIndex;
pub const StringIndex = ast.StringIndex;
pub const AstKind = ast.AstKind;
pub const SourceSpanIndex = ast.SourceSpanIndex;
pub const Data = ast.Data;

// ---------------------------------------------------------------------------
// Data.none — no payload
// ---------------------------------------------------------------------------

pub const BreakStmt = struct {
    pub const Record = struct {};
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, _: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .break_stmt, .span = span, .data = .none });
    }
    pub fn unpack(_: *const AstStore, _: AstNodeIndex) Record {
        return .{};
    }
};

pub const ContinueStmt = struct {
    pub const Record = struct {};
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, _: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .continue_stmt, .span = span, .data = .none });
    }
    pub fn unpack(_: *const AstStore, _: AstNodeIndex) Record {
        return .{};
    }
};

pub const NullLiteral = struct {
    pub const Record = struct {};
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, _: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .null_literal, .span = span, .data = .none });
    }
    pub fn unpack(_: *const AstStore, _: AstNodeIndex) Record {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Data.bool_val
// ---------------------------------------------------------------------------

pub const BoolLiteral = struct {
    pub const Record = struct { value: bool };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .bool_literal, .span = span, .data = .{ .bool_val = rec.value } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .value = node.data.bool_val };
    }
};

// ---------------------------------------------------------------------------
// Data.str — single StringIndex
// ---------------------------------------------------------------------------

pub const Identifier = struct {
    pub const Record = struct { name: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .identifier, .span = span, .data = .{ .str = rec.name } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .name = node.data.str };
    }
};

pub const IntLiteral = struct {
    pub const Record = struct { text: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .int_literal, .span = span, .data = .{ .str = rec.text } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .text = node.data.str };
    }
};

pub const FloatLiteral = struct {
    pub const Record = struct { text: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .float_literal, .span = span, .data = .{ .str = rec.text } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .text = node.data.str };
    }
};

pub const StringLiteral = struct {
    pub const Record = struct { text: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .string_literal, .span = span, .data = .{ .str = rec.text } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .text = node.data.str };
    }
};

pub const ErrorLiteral = struct {
    pub const Record = struct { name: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .error_literal, .span = span, .data = .{ .str = rec.name } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .name = node.data.str };
    }
};

pub const TypeNamed = struct {
    pub const Record = struct { name: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .type_named, .span = span, .data = .{ .str = rec.name } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .name = node.data.str };
    }
};

// ---------------------------------------------------------------------------
// Data.node — single child
// ---------------------------------------------------------------------------

pub const MutBorrowExpr = struct {
    pub const Record = struct { child: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .mut_borrow_expr, .span = span, .data = .{ .node = rec.child } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .child = node.data.node };
    }
};

pub const ConstBorrowExpr = struct {
    pub const Record = struct { child: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .const_borrow_expr, .span = span, .data = .{ .node = rec.child } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .child = node.data.node };
    }
};

pub const TypeSlice = struct {
    pub const Record = struct { elem: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .type_slice, .span = span, .data = .{ .node = rec.elem } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .elem = node.data.node };
    }
};

pub const DeferStmt = struct {
    pub const Record = struct { body: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .defer_stmt, .span = span, .data = .{ .node = rec.body } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .body = node.data.node };
    }
};

pub const ReturnStmt = struct {
    pub const Record = struct { value: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{ .tag = .return_stmt, .span = span, .data = .{ .node = rec.value } });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .value = node.data.node };
    }
};

// ---------------------------------------------------------------------------
// Data.two_nodes
// ---------------------------------------------------------------------------

pub const IndexExpr = struct {
    pub const Record = struct { object: AstNodeIndex, index: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{
            .tag = .index_expr,
            .span = span,
            .data = .{ .two_nodes = .{ .lhs = rec.object, .rhs = rec.index } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .object = node.data.two_nodes.lhs, .index = node.data.two_nodes.rhs };
    }
};

pub const TypeArray = struct {
    pub const Record = struct { size: AstNodeIndex, elem: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{
            .tag = .type_array,
            .span = span,
            .data = .{ .two_nodes = .{ .lhs = rec.size, .rhs = rec.elem } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .size = node.data.two_nodes.lhs, .elem = node.data.two_nodes.rhs };
    }
};

// ---------------------------------------------------------------------------
// Data.str_and_node
// ---------------------------------------------------------------------------

pub const FieldExpr = struct {
    pub const Record = struct { field: StringIndex, object: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{
            .tag = .field_expr,
            .span = span,
            .data = .{ .str_and_node = .{ .str = rec.field, .node = rec.object } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .field = node.data.str_and_node.str, .object = node.data.str_and_node.node };
    }
};

pub const TestDecl = struct {
    pub const Record = struct { description: StringIndex, body: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{
            .tag = .test_decl,
            .span = span,
            .data = .{ .str_and_node = .{ .str = rec.description, .node = rec.body } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .description = node.data.str_and_node.str, .body = node.data.str_and_node.node };
    }
};

pub const ModuleDecl = struct {
    pub const Record = struct { name: StringIndex, doc: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        return store.appendNode(allocator, .{
            .tag = .module_decl,
            .span = span,
            .data = .{ .str_and_node = .{ .str = rec.name, .node = rec.doc } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        return .{ .name = node.data.str_and_node.str, .doc = node.data.str_and_node.node };
    }
};

// ---------------------------------------------------------------------------
// Data.node_and_extra — node is first child; extra has remaining fixed fields
// ---------------------------------------------------------------------------

pub const UnaryExpr = struct {
    pub const Record = struct { op: u32, operand: AstNodeIndex };
    const UnaryExtra = struct { op: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, UnaryExtra{ .op = rec.op });
        return store.appendNode(allocator, .{
            .tag = .unary_expr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.operand, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(UnaryExtra, node.data.node_and_extra.extra);
        return .{ .op = extra.op, .operand = node.data.node_and_extra.node };
    }
};

pub const TypePtr = struct {
    pub const Record = struct { kind: u32, elem: AstNodeIndex };
    const PtrExtra = struct { kind: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, PtrExtra{ .kind = rec.kind });
        return store.appendNode(allocator, .{
            .tag = .type_ptr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.elem, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(PtrExtra, node.data.node_and_extra.extra);
        return .{ .kind = extra.kind, .elem = node.data.node_and_extra.node };
    }
};

pub const Metadata = struct {
    pub const Record = struct { field: u32, value: AstNodeIndex };
    const MetaExtra = struct { field: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, MetaExtra{ .field = rec.field });
        return store.appendNode(allocator, .{
            .tag = .metadata,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.value, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(MetaExtra, node.data.node_and_extra.extra);
        return .{ .field = extra.field, .value = node.data.node_and_extra.node };
    }
};

pub const MatchArm = struct {
    pub const Record = struct { pattern: AstNodeIndex, guard: AstNodeIndex, body: AstNodeIndex };
    const MatchArmExtra = struct { guard: AstNodeIndex, body: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, MatchArmExtra{ .guard = rec.guard, .body = rec.body });
        return store.appendNode(allocator, .{
            .tag = .match_arm,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.pattern, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(MatchArmExtra, node.data.node_and_extra.extra);
        return .{ .pattern = node.data.node_and_extra.node, .guard = extra.guard, .body = extra.body };
    }
};

pub const IfStmt = struct {
    pub const Record = struct { condition: AstNodeIndex, then_block: AstNodeIndex, else_block: AstNodeIndex };
    const IfExtra = struct { then_block: AstNodeIndex, else_block: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, IfExtra{ .then_block = rec.then_block, .else_block = rec.else_block });
        return store.appendNode(allocator, .{
            .tag = .if_stmt,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.condition, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(IfExtra, node.data.node_and_extra.extra);
        return .{ .condition = node.data.node_and_extra.node, .then_block = extra.then_block, .else_block = extra.else_block };
    }
};

pub const WhileStmt = struct {
    pub const Record = struct { condition: AstNodeIndex, body: AstNodeIndex, continue_expr: AstNodeIndex };
    const WhileExtra = struct { body: AstNodeIndex, continue_expr: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, WhileExtra{ .body = rec.body, .continue_expr = rec.continue_expr });
        return store.appendNode(allocator, .{
            .tag = .while_stmt,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.condition, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(WhileExtra, node.data.node_and_extra.extra);
        return .{ .condition = node.data.node_and_extra.node, .body = extra.body, .continue_expr = extra.continue_expr };
    }
};

pub const SliceExpr = struct {
    pub const Record = struct { object: AstNodeIndex, low: AstNodeIndex, high: AstNodeIndex };
    const SliceExtra = struct { low: AstNodeIndex, high: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, SliceExtra{ .low = rec.low, .high = rec.high });
        return store.appendNode(allocator, .{
            .tag = .slice_expr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.object, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(SliceExtra, node.data.node_and_extra.extra);
        return .{ .object = node.data.node_and_extra.node, .low = extra.low, .high = extra.high };
    }
};

// assignment, binary_expr, range_expr share the same BinExtra layout
const BinExtra = struct { op: u32, rhs: AstNodeIndex };

pub const Assignment = struct {
    pub const Record = struct { op: u32, lhs: AstNodeIndex, rhs: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, BinExtra{ .op = rec.op, .rhs = rec.rhs });
        return store.appendNode(allocator, .{
            .tag = .assignment,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.lhs, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(BinExtra, node.data.node_and_extra.extra);
        return .{ .op = extra.op, .lhs = node.data.node_and_extra.node, .rhs = extra.rhs };
    }
};

pub const BinaryExpr = struct {
    pub const Record = struct { op: u32, lhs: AstNodeIndex, rhs: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, BinExtra{ .op = rec.op, .rhs = rec.rhs });
        return store.appendNode(allocator, .{
            .tag = .binary_expr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.lhs, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(BinExtra, node.data.node_and_extra.extra);
        return .{ .op = extra.op, .lhs = node.data.node_and_extra.node, .rhs = extra.rhs };
    }
};

pub const RangeExpr = struct {
    pub const Record = struct { op: u32, lhs: AstNodeIndex, rhs: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, BinExtra{ .op = rec.op, .rhs = rec.rhs });
        return store.appendNode(allocator, .{
            .tag = .range_expr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.lhs, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(BinExtra, node.data.node_and_extra.extra);
        return .{ .op = extra.op, .lhs = node.data.node_and_extra.node, .rhs = extra.rhs };
    }
};

pub const MatchStmt = struct {
    pub const Record = struct { value: AstNodeIndex, arms_start: u32, arms_end: u32 };
    const MatchStmtExtra = struct { arms_start: u32, arms_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, MatchStmtExtra{ .arms_start = rec.arms_start, .arms_end = rec.arms_end });
        return store.appendNode(allocator, .{
            .tag = .match_stmt,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.value, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(MatchStmtExtra, node.data.node_and_extra.extra);
        return .{ .value = node.data.node_and_extra.node, .arms_start = extra.arms_start, .arms_end = extra.arms_end };
    }
};

pub const DestructDecl = struct {
    pub const Record = struct { value: AstNodeIndex, names_start: u32, names_end: u32, is_const: u32 };
    const DestructExtra = struct { names_start: u32, names_end: u32, is_const: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, DestructExtra{
            .names_start = rec.names_start,
            .names_end = rec.names_end,
            .is_const = rec.is_const,
        });
        return store.appendNode(allocator, .{
            .tag = .destruct_decl,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.value, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(DestructExtra, node.data.node_and_extra.extra);
        return .{ .value = node.data.node_and_extra.node, .names_start = extra.names_start, .names_end = extra.names_end, .is_const = extra.is_const };
    }
};

pub const ForStmt = struct {
    pub const Record = struct {
        body: AstNodeIndex,
        iterables_start: u32,
        iterables_end: u32,
        captures_start: u32,
        captures_end: u32,
        flags: u32,
    };
    const ForExtra = struct {
        iterables_start: u32,
        iterables_end: u32,
        captures_start: u32,
        captures_end: u32,
        flags: u32,
    };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, ForExtra{
            .iterables_start = rec.iterables_start,
            .iterables_end = rec.iterables_end,
            .captures_start = rec.captures_start,
            .captures_end = rec.captures_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .for_stmt,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.body, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(ForExtra, node.data.node_and_extra.extra);
        return .{
            .body = node.data.node_and_extra.node,
            .iterables_start = extra.iterables_start,
            .iterables_end = extra.iterables_end,
            .captures_start = extra.captures_start,
            .captures_end = extra.captures_end,
            .flags = extra.flags,
        };
    }
};

pub const CallExpr = struct {
    pub const Record = struct { callee: AstNodeIndex, args_start: u32, args_end: u32, arg_names_start: u32 };
    const CallExtra = struct { args_start: u32, args_end: u32, arg_names_start: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, CallExtra{
            .args_start = rec.args_start,
            .args_end = rec.args_end,
            .arg_names_start = rec.arg_names_start,
        });
        return store.appendNode(allocator, .{
            .tag = .call_expr,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.callee, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(CallExtra, node.data.node_and_extra.extra);
        return .{ .callee = node.data.node_and_extra.node, .args_start = extra.args_start, .args_end = extra.args_end, .arg_names_start = extra.arg_names_start };
    }
};

pub const TypeFunc = struct {
    pub const Record = struct { ret: AstNodeIndex, params_start: u32, params_end: u32 };
    const TypeFuncExtra = struct { params_start: u32, params_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, TypeFuncExtra{ .params_start = rec.params_start, .params_end = rec.params_end });
        return store.appendNode(allocator, .{
            .tag = .type_func,
            .span = span,
            .data = .{ .node_and_extra = .{ .node = rec.ret, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(TypeFuncExtra, node.data.node_and_extra.extra);
        return .{ .ret = node.data.node_and_extra.node, .params_start = extra.params_start, .params_end = extra.params_end };
    }
};

// ---------------------------------------------------------------------------
// Data.str_and_extra
// ---------------------------------------------------------------------------

pub const VarDecl = struct {
    pub const Record = struct { name: StringIndex, value: AstNodeIndex, type_annotation: AstNodeIndex, flags: u32 };
    const VarDeclExtra = struct { value: AstNodeIndex, type_annotation: AstNodeIndex, flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, VarDeclExtra{
            .value = rec.value,
            .type_annotation = rec.type_annotation,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .var_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(VarDeclExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .value = extra.value, .type_annotation = extra.type_annotation, .flags = extra.flags };
    }
};

pub const Param = struct {
    pub const Record = struct { name: StringIndex, type_annotation: AstNodeIndex, default_value: AstNodeIndex };
    const ParamExtra = struct { type_annotation: AstNodeIndex, default_value: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, ParamExtra{ .type_annotation = rec.type_annotation, .default_value = rec.default_value });
        return store.appendNode(allocator, .{
            .tag = .param,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(ParamExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .type_annotation = extra.type_annotation, .default_value = extra.default_value };
    }
};

pub const EnumVariant = struct {
    pub const Record = struct { name: StringIndex, value: AstNodeIndex };
    const EnumVariantExtra = struct { value: AstNodeIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, EnumVariantExtra{ .value = rec.value });
        return store.appendNode(allocator, .{
            .tag = .enum_variant,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(EnumVariantExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .value = extra.value };
    }
};

pub const FieldDecl = struct {
    pub const Record = struct { name: StringIndex, type_annotation: AstNodeIndex, default_value: AstNodeIndex, flags: u32 };
    const FieldExtra = struct { type_annotation: AstNodeIndex, default_value: AstNodeIndex, flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, FieldExtra{
            .type_annotation = rec.type_annotation,
            .default_value = rec.default_value,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .field_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(FieldExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .type_annotation = extra.type_annotation, .default_value = extra.default_value, .flags = extra.flags };
    }
};

pub const ImportDecl = struct {
    pub const Record = struct { path: StringIndex, scope: StringIndex, alias: StringIndex, flags: u32 };
    const ImportExtra = struct { scope: StringIndex, alias: StringIndex, flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, ImportExtra{ .scope = rec.scope, .alias = rec.alias, .flags = rec.flags });
        return store.appendNode(allocator, .{
            .tag = .import_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.path, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(ImportExtra, node.data.str_and_extra.extra);
        return .{ .path = node.data.str_and_extra.str, .scope = extra.scope, .alias = extra.alias, .flags = extra.flags };
    }
};

pub const FuncDecl = struct {
    pub const Record = struct {
        name: StringIndex,
        return_type: AstNodeIndex,
        body: AstNodeIndex,
        params_start: u32,
        params_end: u32,
        flags: u32,
    };
    const FuncDeclExtra = struct {
        return_type: AstNodeIndex,
        body: AstNodeIndex,
        params_start: u32,
        params_end: u32,
        flags: u32,
    };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, FuncDeclExtra{
            .return_type = rec.return_type,
            .body = rec.body,
            .params_start = rec.params_start,
            .params_end = rec.params_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .func_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(FuncDeclExtra, node.data.str_and_extra.extra);
        return .{
            .name = node.data.str_and_extra.str,
            .return_type = extra.return_type,
            .body = extra.body,
            .params_start = extra.params_start,
            .params_end = extra.params_end,
            .flags = extra.flags,
        };
    }
};

pub const StructDecl = struct {
    pub const Record = struct {
        name: StringIndex,
        members_start: u32,
        members_end: u32,
        type_params_start: u32,
        type_params_end: u32,
        blueprints_start: u32,
        blueprints_end: u32,
        flags: u32,
    };
    const StructDeclExtra = struct {
        members_start: u32,
        members_end: u32,
        type_params_start: u32,
        type_params_end: u32,
        blueprints_start: u32,
        blueprints_end: u32,
        flags: u32,
    };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, StructDeclExtra{
            .members_start = rec.members_start,
            .members_end = rec.members_end,
            .type_params_start = rec.type_params_start,
            .type_params_end = rec.type_params_end,
            .blueprints_start = rec.blueprints_start,
            .blueprints_end = rec.blueprints_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .struct_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(StructDeclExtra, node.data.str_and_extra.extra);
        return .{
            .name = node.data.str_and_extra.str,
            .members_start = extra.members_start,
            .members_end = extra.members_end,
            .type_params_start = extra.type_params_start,
            .type_params_end = extra.type_params_end,
            .blueprints_start = extra.blueprints_start,
            .blueprints_end = extra.blueprints_end,
            .flags = extra.flags,
        };
    }
};

pub const BlueprintDecl = struct {
    pub const Record = struct { name: StringIndex, methods_start: u32, methods_end: u32, flags: u32 };
    const BlueprintExtra = struct { methods_start: u32, methods_end: u32, flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, BlueprintExtra{
            .methods_start = rec.methods_start,
            .methods_end = rec.methods_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .blueprint_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(BlueprintExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .methods_start = extra.methods_start, .methods_end = extra.methods_end, .flags = extra.flags };
    }
};

pub const EnumDecl = struct {
    pub const Record = struct { name: StringIndex, backing_type: AstNodeIndex, members_start: u32, members_end: u32, flags: u32 };
    const EnumDeclExtra = struct { backing_type: AstNodeIndex, members_start: u32, members_end: u32, flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, EnumDeclExtra{
            .backing_type = rec.backing_type,
            .members_start = rec.members_start,
            .members_end = rec.members_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{
            .tag = .enum_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(EnumDeclExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .backing_type = extra.backing_type, .members_start = extra.members_start, .members_end = extra.members_end, .flags = extra.flags };
    }
};

pub const HandleDecl = struct {
    pub const Record = struct { name: StringIndex, flags: u32 };
    const HandleExtra = struct { flags: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, HandleExtra{ .flags = rec.flags });
        return store.appendNode(allocator, .{
            .tag = .handle_decl,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(HandleExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .flags = extra.flags };
    }
};

pub const CompilerFunc = struct {
    pub const Record = struct { name: StringIndex, args_start: u32, args_end: u32 };
    const CompilerFuncExtra = struct { args_start: u32, args_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, CompilerFuncExtra{ .args_start = rec.args_start, .args_end = rec.args_end });
        return store.appendNode(allocator, .{
            .tag = .compiler_func,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(CompilerFuncExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .args_start = extra.args_start, .args_end = extra.args_end };
    }
};

pub const TypeGeneric = struct {
    pub const Record = struct { name: StringIndex, args_start: u32, args_end: u32 };
    const TypeGenericExtra = struct { args_start: u32, args_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra = try store.appendExtra(allocator, TypeGenericExtra{ .args_start = rec.args_start, .args_end = rec.args_end });
        return store.appendNode(allocator, .{
            .tag = .type_generic,
            .span = span,
            .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(TypeGenericExtra, node.data.str_and_extra.extra);
        return .{ .name = node.data.str_and_extra.str, .args_start = extra.args_start, .args_end = extra.args_end };
    }
};

// ---------------------------------------------------------------------------
// Data.extra — variable-length child arrays
// ---------------------------------------------------------------------------

// Helper: append a slice of AstNodeIndex values to extra_data, return start/end.
fn appendNodeSlice(store: *AstStore, allocator: std.mem.Allocator, items: []const AstNodeIndex) !struct { start: u32, end: u32 } {
    const start: u32 = @intCast(store.extra_data.items.len);
    for (items) |item| try store.extra_data.append(allocator, @intFromEnum(item));
    const end: u32 = @intCast(store.extra_data.items.len);
    return .{ .start = start, .end = end };
}

pub const Block = struct {
    pub const Record = struct { stmts_start: u32, stmts_end: u32 };
    const BlockExtra = struct { count: u32 };

    /// pack: children are the stmt AstNodeIndex values stored inline in extra_data.
    /// Layout: BlockExtra{ count } followed immediately by count AstNodeIndex words.
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, stmt_nodes: []const AstNodeIndex) !AstNodeIndex {
        // Reserve room for the header first so we know where children start.
        const header_idx: ExtraIndex = @enumFromInt(store.extra_data.items.len);
        // Placeholder for count — will be filled below.
        try store.extra_data.append(allocator, 0);
        const children_start: u32 = @intCast(store.extra_data.items.len);
        for (stmt_nodes) |s| try store.extra_data.append(allocator, @intFromEnum(s));
        const children_end: u32 = @intCast(store.extra_data.items.len);
        // Fill in count.
        store.extra_data.items[@intFromEnum(header_idx)] = children_end - children_start;
        return store.appendNode(allocator, .{
            .tag = .block,
            .span = span,
            .data = .{ .extra = header_idx },
        });
    }

    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const raw = @intFromEnum(node.data.extra);
        const count = store.extra_data.items[raw];
        const stmts_start: u32 = raw + 1;
        const stmts_end: u32 = stmts_start + count;
        return .{ .stmts_start = stmts_start, .stmts_end = stmts_end };
    }

    /// Convenience: return the stmt node indices as a slice into store.extra_data.
    pub fn getStmts(store: *const AstStore, idx: AstNodeIndex) []const AstNodeIndex {
        const rec = unpack(store, idx);
        const slice = store.extra_data.items[rec.stmts_start..rec.stmts_end];
        return @ptrCast(slice);
    }
};

// Generic list helper for array_literal, type_union, struct_type.
// Layout: ListExtra{ count } followed by count AstNodeIndex words.
fn packListNode(store: *AstStore, allocator: std.mem.Allocator, tag: AstKind, span: SourceSpanIndex, items: []const AstNodeIndex) !AstNodeIndex {
    const header_idx: ExtraIndex = @enumFromInt(store.extra_data.items.len);
    try store.extra_data.append(allocator, 0);
    const children_start: u32 = @intCast(store.extra_data.items.len);
    for (items) |it| try store.extra_data.append(allocator, @intFromEnum(it));
    const children_end: u32 = @intCast(store.extra_data.items.len);
    store.extra_data.items[@intFromEnum(header_idx)] = children_end - children_start;
    return store.appendNode(allocator, .{
        .tag = tag,
        .span = span,
        .data = .{ .extra = header_idx },
    });
}

fn unpackListNode(store: *const AstStore, idx: AstNodeIndex) struct { items_start: u32, items_end: u32 } {
    const node = store.getNode(idx);
    const raw = @intFromEnum(node.data.extra);
    const count = store.extra_data.items[raw];
    const items_start: u32 = raw + 1;
    return .{ .items_start = items_start, .items_end = items_start + count };
}

pub const ArrayLiteral = struct {
    pub const Record = struct { items_start: u32, items_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, item_nodes: []const AstNodeIndex) !AstNodeIndex {
        return packListNode(store, allocator, .array_literal, span, item_nodes);
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        return unpackListNode(store, idx);
    }
    pub fn getItems(store: *const AstStore, idx: AstNodeIndex) []const AstNodeIndex {
        const rec = unpack(store, idx);
        return @ptrCast(store.extra_data.items[rec.items_start..rec.items_end]);
    }
};

pub const TypeUnion = struct {
    pub const Record = struct { items_start: u32, items_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, items_slice: []const AstNodeIndex) !AstNodeIndex {
        return packListNode(store, allocator, .type_union, span, items_slice);
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        return unpackListNode(store, idx);
    }
};

pub const StructType = struct {
    pub const Record = struct { items_start: u32, items_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, items_slice: []const AstNodeIndex) !AstNodeIndex {
        return packListNode(store, allocator, .struct_type, span, items_slice);
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        return unpackListNode(store, idx);
    }
};

pub const Program = struct {
    pub const Record = struct {
        module: AstNodeIndex,
        metadata_start: u32,
        metadata_end: u32,
        imports_start: u32,
        imports_end: u32,
        top_level_start: u32,
        top_level_end: u32,
    };
    const ProgramExtra = struct {
        module: AstNodeIndex,
        metadata_start: u32,
        metadata_end: u32,
        imports_start: u32,
        imports_end: u32,
        top_level_start: u32,
        top_level_end: u32,
    };

    /// pack: append the three node arrays to extra_data, record their indices,
    /// then append ProgramExtra.  All four sub-arrays are adjacent in extra_data.
    pub fn pack(
        store: *AstStore,
        allocator: std.mem.Allocator,
        span: SourceSpanIndex,
        module: AstNodeIndex,
        metadata: []const AstNodeIndex,
        imports: []const AstNodeIndex,
        top_level: []const AstNodeIndex,
    ) !AstNodeIndex {
        const meta_range = try appendNodeSlice(store, allocator, metadata);
        const imp_range = try appendNodeSlice(store, allocator, imports);
        const tl_range = try appendNodeSlice(store, allocator, top_level);
        const extra_idx = try store.appendExtra(allocator, ProgramExtra{
            .module = module,
            .metadata_start = meta_range.start,
            .metadata_end = meta_range.end,
            .imports_start = imp_range.start,
            .imports_end = imp_range.end,
            .top_level_start = tl_range.start,
            .top_level_end = tl_range.end,
        });
        return store.appendNode(allocator, .{
            .tag = .program,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }

    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(ProgramExtra, node.data.extra);
        return .{
            .module = extra.module,
            .metadata_start = extra.metadata_start,
            .metadata_end = extra.metadata_end,
            .imports_start = extra.imports_start,
            .imports_end = extra.imports_end,
            .top_level_start = extra.top_level_start,
            .top_level_end = extra.top_level_end,
        };
    }
};

pub const TupleLiteral = struct {
    pub const Record = struct { elements_start: u32, elements_end: u32, names_start: u32 };
    const TupleExtra = struct { elements_start: u32, elements_end: u32, names_start: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra_idx = try store.appendExtra(allocator, TupleExtra{
            .elements_start = rec.elements_start,
            .elements_end = rec.elements_end,
            .names_start = rec.names_start,
        });
        return store.appendNode(allocator, .{
            .tag = .tuple_literal,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(TupleExtra, node.data.extra);
        return .{ .elements_start = extra.elements_start, .elements_end = extra.elements_end, .names_start = extra.names_start };
    }
};

pub const VersionLiteral = struct {
    pub const Record = struct { major: StringIndex, minor: StringIndex, patch: StringIndex };
    const VersionExtra = struct { major: StringIndex, minor: StringIndex, patch: StringIndex };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra_idx = try store.appendExtra(allocator, VersionExtra{ .major = rec.major, .minor = rec.minor, .patch = rec.patch });
        return store.appendNode(allocator, .{
            .tag = .version_literal,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(VersionExtra, node.data.extra);
        return .{ .major = extra.major, .minor = extra.minor, .patch = extra.patch };
    }
};

pub const InterpolatedString = struct {
    pub const Record = struct { parts_start: u32, parts_end: u32 };
    const InterpExtra = struct { parts_start: u32, parts_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra_idx = try store.appendExtra(allocator, InterpExtra{ .parts_start = rec.parts_start, .parts_end = rec.parts_end });
        return store.appendNode(allocator, .{
            .tag = .interpolated_string,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(InterpExtra, node.data.extra);
        return .{ .parts_start = extra.parts_start, .parts_end = extra.parts_end };
    }
};

pub const TypeTupleNamed = struct {
    pub const Record = struct { fields_start: u32, fields_end: u32 };
    const TypeTupleNamedExtra = struct { fields_start: u32, fields_end: u32 };
    pub fn pack(store: *AstStore, allocator: std.mem.Allocator, span: SourceSpanIndex, rec: Record) !AstNodeIndex {
        const extra_idx = try store.appendExtra(allocator, TypeTupleNamedExtra{ .fields_start = rec.fields_start, .fields_end = rec.fields_end });
        return store.appendNode(allocator, .{
            .tag = .type_tuple_named,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }
    pub fn unpack(store: *const AstStore, idx: AstNodeIndex) Record {
        const node = store.getNode(idx);
        const extra = store.extraData(TypeTupleNamedExtra, node.data.extra);
        return .{ .fields_start = extra.fields_start, .fields_end = extra.fields_end };
    }
};

// ---------------------------------------------------------------------------
// Tests — 6 required round-trips
// ---------------------------------------------------------------------------

test "break_stmt round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const idx = try BreakStmt.pack(&store, std.testing.allocator, .none, .{});
    const node = store.getNode(idx);
    try std.testing.expectEqual(AstKind.break_stmt, node.tag);
    try std.testing.expect(node.data == .none);
    _ = BreakStmt.unpack(&store, idx);
}

test "identifier round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const si = try store.strings.intern(std.testing.allocator, "myVar");
    const idx = try Identifier.pack(&store, std.testing.allocator, .none, .{ .name = si });
    const rec = Identifier.unpack(&store, idx);
    try std.testing.expectEqual(si, rec.name);
    try std.testing.expectEqualStrings("myVar", store.strings.get(rec.name));
}

test "binary_expr round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    // Build two identifier operands first.
    const lhs_si = try store.strings.intern(std.testing.allocator, "a");
    const rhs_si = try store.strings.intern(std.testing.allocator, "b");
    const lhs = try Identifier.pack(&store, std.testing.allocator, .none, .{ .name = lhs_si });
    const rhs = try Identifier.pack(&store, std.testing.allocator, .none, .{ .name = rhs_si });

    const idx = try BinaryExpr.pack(&store, std.testing.allocator, .none, .{ .op = 42, .lhs = lhs, .rhs = rhs });
    const rec = BinaryExpr.unpack(&store, idx);
    try std.testing.expectEqual(@as(u32, 42), rec.op);
    try std.testing.expectEqual(lhs, rec.lhs);
    try std.testing.expectEqual(rhs, rec.rhs);
}

test "func_decl round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const name_si = try store.strings.intern(std.testing.allocator, "greet");
    const p1_si = try store.strings.intern(std.testing.allocator, "x");
    const p2_si = try store.strings.intern(std.testing.allocator, "y");

    // Two param nodes.
    const p1 = try Param.pack(&store, std.testing.allocator, .none, .{ .name = p1_si, .type_annotation = .none, .default_value = .none });
    const p2 = try Param.pack(&store, std.testing.allocator, .none, .{ .name = p2_si, .type_annotation = .none, .default_value = .none });

    // Append param indices to extra_data and record range.
    const params_start: u32 = @intCast(store.extra_data.items.len);
    try store.extra_data.append(std.testing.allocator, @intFromEnum(p1));
    try store.extra_data.append(std.testing.allocator, @intFromEnum(p2));
    const params_end: u32 = @intCast(store.extra_data.items.len);

    const body = try Block.pack(&store, std.testing.allocator, .none, &.{});

    const idx = try FuncDecl.pack(&store, std.testing.allocator, .none, .{
        .name = name_si,
        .return_type = .none,
        .body = body,
        .params_start = params_start,
        .params_end = params_end,
        .flags = 0,
    });

    const rec = FuncDecl.unpack(&store, idx);
    try std.testing.expectEqual(name_si, rec.name);
    try std.testing.expectEqualStrings("greet", store.strings.get(rec.name));
    try std.testing.expectEqual(body, rec.body);
    try std.testing.expectEqual(params_start, rec.params_start);
    try std.testing.expectEqual(params_end, rec.params_end);
    try std.testing.expectEqual(@as(u32, 0), rec.flags);

    // Verify param indices round-trip.
    const p_slice = store.extra_data.items[rec.params_start..rec.params_end];
    try std.testing.expectEqual(@intFromEnum(p1), p_slice[0]);
    try std.testing.expectEqual(@intFromEnum(p2), p_slice[1]);
}

test "block round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    // Three break_stmt children.
    const s1 = try BreakStmt.pack(&store, std.testing.allocator, .none, .{});
    const s2 = try ContinueStmt.pack(&store, std.testing.allocator, .none, .{});
    const s3 = try NullLiteral.pack(&store, std.testing.allocator, .none, .{});

    const idx = try Block.pack(&store, std.testing.allocator, .none, &.{ s1, s2, s3 });
    const node = store.getNode(idx);
    try std.testing.expectEqual(AstKind.block, node.tag);

    const rec = Block.unpack(&store, idx);
    try std.testing.expectEqual(@as(u32, 3), rec.stmts_end - rec.stmts_start);

    const got = Block.getStmts(&store, idx);
    try std.testing.expectEqual(s1, got[0]);
    try std.testing.expectEqual(s2, got[1]);
    try std.testing.expectEqual(s3, got[2]);
}

test "bool_literal round-trip" {
    var store = AstStore.init();
    defer store.deinit(std.testing.allocator);

    const t_idx = try BoolLiteral.pack(&store, std.testing.allocator, .none, .{ .value = true });
    const f_idx = try BoolLiteral.pack(&store, std.testing.allocator, .none, .{ .value = false });

    try std.testing.expectEqual(true, BoolLiteral.unpack(&store, t_idx).value);
    try std.testing.expectEqual(false, BoolLiteral.unpack(&store, f_idx).value);
}
