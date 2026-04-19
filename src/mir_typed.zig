// mir_typed.zig — typed wrappers per MirKind with pack/unpack round-trips (Phase B3)
//
// Each public namespace corresponds to one MirKind.  Every namespace exposes:
//   Record   — the semantic fields in index form (no pointers)
//   pack     — allocates store entries and returns the new MirNodeIndex
//   unpack   — reads a previously-packed node back into a Record
//
// pack signature always takes (store, allocator, span, type_id, type_class, rec).
// span is an AstNodeIndex back-pointer into AstStore for source locations.
// IfNarrowing and interp-part complex metadata are addressed in B6.

const std = @import("std");
const mir = @import("mir_store.zig");

pub const MirStore = mir.MirStore;
pub const MirNodeIndex = mir.MirNodeIndex;
pub const MirExtraIndex = mir.MirExtraIndex;
pub const MirData = mir.MirData;
pub const MirEntry = mir.MirEntry;
pub const MirKind = mir.MirKind;
pub const TypeClass = mir.TypeClass;
pub const AstNodeIndex = @import("ast_store.zig").AstNodeIndex;
pub const StringIndex = @import("string_pool.zig").StringIndex;
pub const TypeId = @import("type_store.zig").TypeId;

// Shorthand for the inner helper used by list-shaped nodes.
fn appendMirSlice(store: *MirStore, allocator: std.mem.Allocator, items: []const MirNodeIndex) !struct { start: u32, end: u32 } {
    const start: u32 = @intCast(store.extra_data.items.len);
    for (items) |it| try store.extra_data.append(allocator, @intFromEnum(it));
    const end: u32 = @intCast(store.extra_data.items.len);
    return .{ .start = start, .end = end };
}

// ---------------------------------------------------------------------------
// Declarations cluster
// ---------------------------------------------------------------------------

pub const Func = struct {
    pub const Record = struct {
        name: StringIndex,
        return_type: AstNodeIndex,
        body: MirNodeIndex,
        params_start: u32,
        params_end: u32,
        flags: u32, // is_pub | is_compt | generic
    };
    const FuncExtra = struct {
        return_type: AstNodeIndex,
        body: MirNodeIndex,
        params_start: u32,
        params_end: u32,
        flags: u32,
    };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, FuncExtra{
            .return_type = rec.return_type,
            .body = rec.body,
            .params_start = rec.params_start,
            .params_end = rec.params_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{ .tag = .func, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(FuncExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .return_type = extra.return_type, .body = extra.body, .params_start = extra.params_start, .params_end = extra.params_end, .flags = extra.flags };
    }
};

pub const StructDef = struct {
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
    const StructExtra = struct {
        members_start: u32,
        members_end: u32,
        type_params_start: u32,
        type_params_end: u32,
        blueprints_start: u32,
        blueprints_end: u32,
        flags: u32,
    };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, StructExtra{
            .members_start = rec.members_start,
            .members_end = rec.members_end,
            .type_params_start = rec.type_params_start,
            .type_params_end = rec.type_params_end,
            .blueprints_start = rec.blueprints_start,
            .blueprints_end = rec.blueprints_end,
            .flags = rec.flags,
        });
        return store.appendNode(allocator, .{ .tag = .struct_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(StructExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .members_start = extra.members_start, .members_end = extra.members_end, .type_params_start = extra.type_params_start, .type_params_end = extra.type_params_end, .blueprints_start = extra.blueprints_start, .blueprints_end = extra.blueprints_end, .flags = extra.flags };
    }
};

pub const EnumDef = struct {
    pub const Record = struct { name: StringIndex, backing_type: AstNodeIndex, members_start: u32, members_end: u32, flags: u32 };
    const EnumDefExtra = struct { backing_type: AstNodeIndex, members_start: u32, members_end: u32, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, EnumDefExtra{ .backing_type = rec.backing_type, .members_start = rec.members_start, .members_end = rec.members_end, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .enum_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(EnumDefExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .backing_type = extra.backing_type, .members_start = extra.members_start, .members_end = extra.members_end, .flags = extra.flags };
    }
};

pub const HandleDef = struct {
    pub const Record = struct { name: StringIndex, flags: u32 };
    const HandleDefExtra = struct { flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, HandleDefExtra{ .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .handle_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(HandleDefExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .flags = extra.flags };
    }
};

pub const VarDecl = struct {
    pub const Record = struct { name: StringIndex, value: MirNodeIndex, type_annotation: AstNodeIndex, flags: u32 };
    const VarDeclExtra = struct { value: MirNodeIndex, type_annotation: AstNodeIndex, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, VarDeclExtra{ .value = rec.value, .type_annotation = rec.type_annotation, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .var_decl, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(VarDeclExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .value = extra.value, .type_annotation = extra.type_annotation, .flags = extra.flags };
    }
};

pub const TestDef = struct {
    pub const Record = struct { description: StringIndex, body: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .test_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_node = .{ .str = rec.description, .node = rec.body } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        return .{ .description = entry.data.str_and_node.str, .body = entry.data.str_and_node.node };
    }
};

pub const Destruct = struct {
    pub const Record = struct { value: MirNodeIndex, names_start: u32, names_end: u32, flags: u32 };
    const DestructExtra = struct { names_start: u32, names_end: u32, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, DestructExtra{ .names_start = rec.names_start, .names_end = rec.names_end, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .destruct, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.value, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(DestructExtra, entry.data.node_and_extra.extra);
        return .{ .value = entry.data.node_and_extra.node, .names_start = extra.names_start, .names_end = extra.names_end, .flags = extra.flags };
    }
};

pub const Import = struct {
    pub const Record = struct { path: StringIndex, scope: StringIndex, alias: StringIndex, flags: u32 };
    const ImportExtra = struct { scope: StringIndex, alias: StringIndex, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, ImportExtra{ .scope = rec.scope, .alias = rec.alias, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .import, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.path, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(ImportExtra, entry.data.str_and_extra.extra);
        return .{ .path = entry.data.str_and_extra.str, .scope = extra.scope, .alias = extra.alias, .flags = extra.flags };
    }
};

// ---------------------------------------------------------------------------
// Statements cluster
// ---------------------------------------------------------------------------

pub const Block = struct {
    pub const Record = struct { stmts_start: u32, stmts_end: u32 };

    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, stmt_nodes: []const MirNodeIndex) !MirNodeIndex {
        const header_idx: MirExtraIndex = @enumFromInt(store.extra_data.items.len);
        try store.extra_data.append(allocator, 0);
        const children_start: u32 = @intCast(store.extra_data.items.len);
        for (stmt_nodes) |s| try store.extra_data.append(allocator, @intFromEnum(s));
        const children_end: u32 = @intCast(store.extra_data.items.len);
        store.extra_data.items[@intFromEnum(header_idx)] = children_end - children_start;
        return store.appendNode(allocator, .{ .tag = .block, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = header_idx } });
    }

    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const raw = @intFromEnum(entry.data.extra);
        const count = store.extra_data.items[raw];
        const stmts_start: u32 = raw + 1;
        return .{ .stmts_start = stmts_start, .stmts_end = stmts_start + count };
    }

    pub fn getStmts(store: *const MirStore, idx: MirNodeIndex) []const MirNodeIndex {
        const rec = unpack(store, idx);
        const slice = store.extra_data.items[rec.stmts_start..rec.stmts_end];
        return @ptrCast(slice);
    }
};

pub const ReturnStmt = struct {
    pub const Record = struct { value: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .return_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node = rec.value } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        return .{ .value = store.getNode(idx).data.node };
    }
};

// ── IfNarrowing storage ──────────────────────────────────────────────────────
// Stored in extra_data for if_stmt nodes whose condition is an `is` check.
// narrowing_extra == .none means no narrowing on this if_stmt.

/// One branch of type narrowing. 3 u32 fields.
pub const NarrowBranchExtra = struct {
    type_name: StringIndex,
    positional_tag: u32,  // 0xFFFF_FFFF = absent; else 0..31
    kind: u32,            // 0=plain 1=error_sentinel 2=null_sentinel
};

/// Full narrowing record for one if_stmt. 14 u32 fields = 56 bytes.
pub const IfNarrowingExtra = struct {
    var_name: StringIndex,
    type_class: u32,
    has_then: u32,
    then_type_name: StringIndex,
    then_positional_tag: u32,
    then_kind: u32,
    has_else: u32,
    else_type_name: StringIndex,
    else_positional_tag: u32,
    else_kind: u32,
    has_post: u32,
    post_type_name: StringIndex,
    post_positional_tag: u32,
    post_kind: u32,
};

pub const IfStmt = struct {
    pub const Record = struct {
        condition: MirNodeIndex,
        then_block: MirNodeIndex,
        else_block: MirNodeIndex,
        narrowing_extra: MirExtraIndex, // .none = no narrowing
    };
    const IfExtra = struct {
        then_block: MirNodeIndex,
        else_block: MirNodeIndex,
        narrowing_extra: MirExtraIndex,
    };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, IfExtra{
            .then_block = rec.then_block,
            .else_block = rec.else_block,
            .narrowing_extra = rec.narrowing_extra,
        });
        return store.appendNode(allocator, .{ .tag = .if_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.condition, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(IfExtra, entry.data.node_and_extra.extra);
        return .{
            .condition = entry.data.node_and_extra.node,
            .then_block = extra.then_block,
            .else_block = extra.else_block,
            .narrowing_extra = extra.narrowing_extra,
        };
    }
};

pub const WhileStmt = struct {
    pub const Record = struct { condition: MirNodeIndex, body: MirNodeIndex, continue_expr: MirNodeIndex };
    const WhileExtra = struct { body: MirNodeIndex, continue_expr: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, WhileExtra{ .body = rec.body, .continue_expr = rec.continue_expr });
        return store.appendNode(allocator, .{ .tag = .while_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.condition, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(WhileExtra, entry.data.node_and_extra.extra);
        return .{ .condition = entry.data.node_and_extra.node, .body = extra.body, .continue_expr = extra.continue_expr };
    }
};

pub const ForStmt = struct {
    pub const Record = struct { body: MirNodeIndex, iterables_start: u32, iterables_end: u32, captures_start: u32, captures_end: u32, flags: u32 };
    const ForExtra = struct { iterables_start: u32, iterables_end: u32, captures_start: u32, captures_end: u32, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, ForExtra{ .iterables_start = rec.iterables_start, .iterables_end = rec.iterables_end, .captures_start = rec.captures_start, .captures_end = rec.captures_end, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .for_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.body, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(ForExtra, entry.data.node_and_extra.extra);
        return .{ .body = entry.data.node_and_extra.node, .iterables_start = extra.iterables_start, .iterables_end = extra.iterables_end, .captures_start = extra.captures_start, .captures_end = extra.captures_end, .flags = extra.flags };
    }
};

pub const DeferStmt = struct {
    pub const Record = struct { body: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .defer_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node = rec.body } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        return .{ .body = store.getNode(idx).data.node };
    }
};

pub const MatchStmt = struct {
    pub const Record = struct { value: MirNodeIndex, arms_start: u32, arms_end: u32 };
    const MatchExtra = struct { arms_start: u32, arms_end: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, MatchExtra{ .arms_start = rec.arms_start, .arms_end = rec.arms_end });
        return store.appendNode(allocator, .{ .tag = .match_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.value, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(MatchExtra, entry.data.node_and_extra.extra);
        return .{ .value = entry.data.node_and_extra.node, .arms_start = extra.arms_start, .arms_end = extra.arms_end };
    }
};

pub const MatchArm = struct {
    pub const Record = struct { pattern: MirNodeIndex, guard: MirNodeIndex, body: MirNodeIndex };
    const MatchArmExtra = struct { guard: MirNodeIndex, body: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, MatchArmExtra{ .guard = rec.guard, .body = rec.body });
        return store.appendNode(allocator, .{ .tag = .match_arm, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.pattern, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(MatchArmExtra, entry.data.node_and_extra.extra);
        return .{ .pattern = entry.data.node_and_extra.node, .guard = extra.guard, .body = extra.body };
    }
};

pub const Assignment = struct {
    pub const Record = struct { op: u32, lhs: MirNodeIndex, rhs: MirNodeIndex };
    const AssignExtra = struct { op: u32, rhs: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, AssignExtra{ .op = rec.op, .rhs = rec.rhs });
        return store.appendNode(allocator, .{ .tag = .assignment, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.lhs, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(AssignExtra, entry.data.node_and_extra.extra);
        return .{ .op = extra.op, .lhs = entry.data.node_and_extra.node, .rhs = extra.rhs };
    }
};

pub const BreakStmt = struct {
    pub const Record = struct {};
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, _: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .break_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .none });
    }
    pub fn unpack(_: *const MirStore, _: MirNodeIndex) Record {
        return .{};
    }
};

pub const ContinueStmt = struct {
    pub const Record = struct {};
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, _: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .continue_stmt, .type_class = type_class, .span = span, .type_id = type_id, .data = .none });
    }
    pub fn unpack(_: *const MirStore, _: MirNodeIndex) Record {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Expressions cluster
// ---------------------------------------------------------------------------

/// literal_kind values match LiteralKind enum from mir_node.zig, encoded as u32.
/// bool_val: 1 = true, 0 = false (only meaningful when kind = bool_lit).
pub const Literal = struct {
    pub const Record = struct { text: StringIndex, kind: u32, bool_val: u32 };
    const LiteralExtra = struct { kind: u32, bool_val: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, LiteralExtra{ .kind = rec.kind, .bool_val = rec.bool_val });
        return store.appendNode(allocator, .{ .tag = .literal, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.text, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(LiteralExtra, entry.data.str_and_extra.extra);
        return .{ .text = entry.data.str_and_extra.str, .kind = extra.kind, .bool_val = extra.bool_val };
    }
};

/// resolved_kind: 0 = none, 1 = enum_variant, 2 = enum_type_name.
pub const Identifier = struct {
    pub const Record = struct { name: StringIndex, resolved_kind: u32 };
    const IdentExtra = struct { resolved_kind: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, IdentExtra{ .resolved_kind = rec.resolved_kind });
        return store.appendNode(allocator, .{ .tag = .identifier, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(IdentExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .resolved_kind = extra.resolved_kind };
    }
};

pub const Binary = struct {
    /// union_tag: 0 = no arbitrary-union tag; n+1 = positional tag n for `is` comparisons.
    pub const Record = struct { op: u32, lhs: MirNodeIndex, rhs: MirNodeIndex, union_tag: u32 = 0 };
    const BinExtra = struct { op: u32, rhs: MirNodeIndex, union_tag: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, BinExtra{ .op = rec.op, .rhs = rec.rhs, .union_tag = rec.union_tag });
        return store.appendNode(allocator, .{ .tag = .binary, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.lhs, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(BinExtra, entry.data.node_and_extra.extra);
        return .{ .op = extra.op, .lhs = entry.data.node_and_extra.node, .rhs = extra.rhs, .union_tag = extra.union_tag };
    }
};

pub const Unary = struct {
    pub const Record = struct { op: u32, operand: MirNodeIndex };
    const UnaryExtra = struct { op: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, UnaryExtra{ .op = rec.op });
        return store.appendNode(allocator, .{ .tag = .unary, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.operand, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(UnaryExtra, entry.data.node_and_extra.extra);
        return .{ .op = extra.op, .operand = entry.data.node_and_extra.node };
    }
};

pub const Call = struct {
    pub const Record = struct { callee: MirNodeIndex, args_start: u32, args_end: u32, arg_names_start: u32 };
    const CallExtra = struct { args_start: u32, args_end: u32, arg_names_start: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, CallExtra{ .args_start = rec.args_start, .args_end = rec.args_end, .arg_names_start = rec.arg_names_start });
        return store.appendNode(allocator, .{ .tag = .call, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.callee, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(CallExtra, entry.data.node_and_extra.extra);
        return .{ .callee = entry.data.node_and_extra.node, .args_start = extra.args_start, .args_end = extra.args_end, .arg_names_start = extra.arg_names_start };
    }
};

/// union_tag: 0 = none, else positional tag + 1 (for arbitrary-union member access).
pub const FieldAccess = struct {
    pub const Record = struct { field: StringIndex, object: MirNodeIndex, union_tag: u32 };
    const FieldExtra = struct { object: MirNodeIndex, union_tag: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, FieldExtra{ .object = rec.object, .union_tag = rec.union_tag });
        return store.appendNode(allocator, .{ .tag = .field_access, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.field, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(FieldExtra, entry.data.str_and_extra.extra);
        return .{ .field = entry.data.str_and_extra.str, .object = extra.object, .union_tag = extra.union_tag };
    }
};

pub const Index = struct {
    pub const Record = struct { object: MirNodeIndex, index: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .index, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .two_nodes = .{ .lhs = rec.object, .rhs = rec.index } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        return .{ .object = entry.data.two_nodes.lhs, .index = entry.data.two_nodes.rhs };
    }
};

pub const Slice = struct {
    pub const Record = struct { object: MirNodeIndex, low: MirNodeIndex, high: MirNodeIndex };
    const SliceExtra = struct { low: MirNodeIndex, high: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, SliceExtra{ .low = rec.low, .high = rec.high });
        return store.appendNode(allocator, .{ .tag = .slice, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.object, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(SliceExtra, entry.data.node_and_extra.extra);
        return .{ .object = entry.data.node_and_extra.node, .low = extra.low, .high = extra.high };
    }
};

/// kind: 0 = const_ref, 1 = mut_ref.
pub const Borrow = struct {
    pub const Record = struct { kind: u32, operand: MirNodeIndex };
    const BorrowExtra = struct { kind: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, BorrowExtra{ .kind = rec.kind });
        return store.appendNode(allocator, .{ .tag = .borrow, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node_and_extra = .{ .node = rec.operand, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(BorrowExtra, entry.data.node_and_extra.extra);
        return .{ .kind = extra.kind, .operand = entry.data.node_and_extra.node };
    }
};

/// Interpolated string: parts are (StringIndex literal, MirNodeIndex expr) pairs in extra_data.
pub const Interpolation = struct {
    pub const Record = struct { parts_start: u32, parts_end: u32 };
    const InterpExtra = struct { parts_start: u32, parts_end: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, InterpExtra{ .parts_start = rec.parts_start, .parts_end = rec.parts_end });
        return store.appendNode(allocator, .{ .tag = .interpolation, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = extra } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(InterpExtra, entry.data.extra);
        return .{ .parts_start = extra.parts_start, .parts_end = extra.parts_end };
    }
};

pub const CompilerFn = struct {
    pub const Record = struct { name: StringIndex, args_start: u32, args_end: u32 };
    const CompilerFnExtra = struct { args_start: u32, args_end: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, CompilerFnExtra{ .args_start = rec.args_start, .args_end = rec.args_end });
        return store.appendNode(allocator, .{ .tag = .compiler_fn, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(CompilerFnExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .args_start = extra.args_start, .args_end = extra.args_end };
    }
};

pub const ArrayLit = struct {
    pub const Record = struct { items_start: u32, items_end: u32 };

    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, item_nodes: []const MirNodeIndex) !MirNodeIndex {
        const header_idx: MirExtraIndex = @enumFromInt(store.extra_data.items.len);
        try store.extra_data.append(allocator, 0);
        const children_start: u32 = @intCast(store.extra_data.items.len);
        for (item_nodes) |it| try store.extra_data.append(allocator, @intFromEnum(it));
        const children_end: u32 = @intCast(store.extra_data.items.len);
        store.extra_data.items[@intFromEnum(header_idx)] = children_end - children_start;
        return store.appendNode(allocator, .{ .tag = .array_lit, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = header_idx } });
    }

    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const raw = @intFromEnum(entry.data.extra);
        const count = store.extra_data.items[raw];
        const items_start: u32 = raw + 1;
        return .{ .items_start = items_start, .items_end = items_start + count };
    }

    pub fn getItems(store: *const MirStore, idx: MirNodeIndex) []const MirNodeIndex {
        const rec = unpack(store, idx);
        const slice = store.extra_data.items[rec.items_start..rec.items_end];
        return @ptrCast(slice);
    }
};

pub const TupleLit = struct {
    pub const Record = struct { elements_start: u32, elements_end: u32, names_start: u32 };
    const TupleExtra = struct { elements_start: u32, elements_end: u32, names_start: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, TupleExtra{ .elements_start = rec.elements_start, .elements_end = rec.elements_end, .names_start = rec.names_start });
        return store.appendNode(allocator, .{ .tag = .tuple_lit, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = extra } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(TupleExtra, entry.data.extra);
        return .{ .elements_start = extra.elements_start, .elements_end = extra.elements_end, .names_start = extra.names_start };
    }
};

pub const VersionLit = struct {
    pub const Record = struct { major: StringIndex, minor: StringIndex, patch: StringIndex };
    const VersionExtra = struct { major: StringIndex, minor: StringIndex, patch: StringIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, VersionExtra{ .major = rec.major, .minor = rec.minor, .patch = rec.patch });
        return store.appendNode(allocator, .{ .tag = .version_lit, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = extra } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(VersionExtra, entry.data.extra);
        return .{ .major = extra.major, .minor = extra.minor, .patch = extra.patch };
    }
};

// ---------------------------------------------------------------------------
// Types cluster
// ---------------------------------------------------------------------------

/// type_expr: passthrough — span IS the AstNodeIndex of the type AST node.
/// Codegen reads through span via typeToZig().
pub const TypeExpr = struct {
    pub const Record = struct {};
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, _: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .type_expr, .type_class = type_class, .span = span, .type_id = type_id, .data = .none });
    }
    pub fn unpack(_: *const MirStore, _: MirNodeIndex) Record {
        return .{};
    }
};

/// Inline struct type expression — `return struct { ... }` in a compt func.
/// members_start..members_end are MirNodeIndex values in extra_data.
pub const InlineStruct = struct {
    pub const Record = struct { members_start: u32, members_end: u32 };
    const InlineStructExtra = struct { members_start: u32, members_end: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, InlineStructExtra{ .members_start = rec.members_start, .members_end = rec.members_end });
        return store.appendNode(allocator, .{ .tag = .inline_struct, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .extra = extra } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(InlineStructExtra, entry.data.extra);
        return .{ .members_start = extra.members_start, .members_end = extra.members_end };
    }
};

// ---------------------------------------------------------------------------
// Injected nodes cluster
// ---------------------------------------------------------------------------

pub const TempVar = struct {
    pub const Record = struct { name: StringIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .temp_var, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str = rec.name } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        return .{ .name = store.getNode(idx).data.str };
    }
};

pub const InjectedDefer = struct {
    pub const Record = struct { body: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .injected_defer, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .node = rec.body } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        return .{ .body = store.getNode(idx).data.node };
    }
};

// ---------------------------------------------------------------------------
// Members cluster
// ---------------------------------------------------------------------------

pub const FieldDef = struct {
    pub const Record = struct { name: StringIndex, type_annotation: AstNodeIndex, default: MirNodeIndex, flags: u32 };
    const FieldDefExtra = struct { type_annotation: AstNodeIndex, default: MirNodeIndex, flags: u32 };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, FieldDefExtra{ .type_annotation = rec.type_annotation, .default = rec.default, .flags = rec.flags });
        return store.appendNode(allocator, .{ .tag = .field_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(FieldDefExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .type_annotation = extra.type_annotation, .default = extra.default, .flags = extra.flags };
    }
};

pub const ParamDef = struct {
    pub const Record = struct { name: StringIndex, type_annotation: AstNodeIndex, default: MirNodeIndex };
    const ParamDefExtra = struct { type_annotation: AstNodeIndex, default: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        const extra = try store.appendExtra(allocator, ParamDefExtra{ .type_annotation = rec.type_annotation, .default = rec.default });
        return store.appendNode(allocator, .{ .tag = .param_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_extra = .{ .str = rec.name, .extra = extra } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        const extra = store.extraData(ParamDefExtra, entry.data.str_and_extra.extra);
        return .{ .name = entry.data.str_and_extra.str, .type_annotation = extra.type_annotation, .default = extra.default };
    }
};

pub const EnumVariantDef = struct {
    pub const Record = struct { name: StringIndex, value: MirNodeIndex };
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, rec: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .enum_variant_def, .type_class = type_class, .span = span, .type_id = type_id, .data = .{ .str_and_node = .{ .str = rec.name, .node = rec.value } } });
    }
    pub fn unpack(store: *const MirStore, idx: MirNodeIndex) Record {
        const entry = store.getNode(idx);
        return .{ .name = entry.data.str_and_node.str, .value = entry.data.str_and_node.node };
    }
};

// ---------------------------------------------------------------------------
// Passthrough
// ---------------------------------------------------------------------------

pub const Passthrough = struct {
    pub const Record = struct {};
    pub fn pack(store: *MirStore, allocator: std.mem.Allocator, span: AstNodeIndex, type_id: TypeId, type_class: TypeClass, _: Record) !MirNodeIndex {
        return store.appendNode(allocator, .{ .tag = .passthrough, .type_class = type_class, .span = span, .type_id = type_id, .data = .none });
    }
    pub fn unpack(_: *const MirStore, _: MirNodeIndex) Record {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Tests — one representative round-trip per data shape
// ---------------------------------------------------------------------------

test "break_stmt round-trip (none shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const idx = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const entry = store.getNode(idx);
    try std.testing.expectEqual(MirKind.break_stmt, entry.tag);
    try std.testing.expect(entry.data == .none);
    _ = BreakStmt.unpack(&store, idx);
}

test "return_stmt round-trip (node shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const val = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try ReturnStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .value = val });
    const rec = ReturnStmt.unpack(&store, idx);
    try std.testing.expectEqual(val, rec.value);
}

test "while_stmt round-trip (node_and_extra shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const cond = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const body = try ContinueStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try WhileStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .condition = cond, .body = body, .continue_expr = .none });
    const rec = WhileStmt.unpack(&store, idx);
    try std.testing.expectEqual(cond, rec.condition);
    try std.testing.expectEqual(body, rec.body);
    try std.testing.expectEqual(MirNodeIndex.none, rec.continue_expr);
}

test "test_def round-trip (str_and_node shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const desc = try store.strings.intern(std.testing.allocator, "my test");
    const body = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try TestDef.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .description = desc, .body = body });
    const rec = TestDef.unpack(&store, idx);
    try std.testing.expectEqual(desc, rec.description);
    try std.testing.expectEqual(body, rec.body);
    try std.testing.expectEqualStrings("my test", store.strings.get(rec.description));
}

test "if_stmt round-trip (node_and_extra shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const cond = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const then_b = try ContinueStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const else_b = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try IfStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .condition = cond, .then_block = then_b, .else_block = else_b, .narrowing_extra = .none });
    const rec = IfStmt.unpack(&store, idx);
    try std.testing.expectEqual(cond, rec.condition);
    try std.testing.expectEqual(then_b, rec.then_block);
    try std.testing.expectEqual(else_b, rec.else_block);
    try std.testing.expectEqual(MirExtraIndex.none, rec.narrowing_extra);
}

test "var_decl round-trip (str_and_extra shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const name = try store.strings.intern(std.testing.allocator, "x");
    const val = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try VarDecl.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .name = name, .value = val, .type_annotation = .none, .flags = 3 });
    const rec = VarDecl.unpack(&store, idx);
    try std.testing.expectEqual(name, rec.name);
    try std.testing.expectEqual(val, rec.value);
    try std.testing.expectEqual(AstNodeIndex.none, rec.type_annotation);
    try std.testing.expectEqual(@as(u32, 3), rec.flags);
    try std.testing.expectEqualStrings("x", store.strings.get(rec.name));
}

test "block round-trip (extra list shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const s1 = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const s2 = try ContinueStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try Block.pack(&store, std.testing.allocator, .none, .none, .plain, &.{ s1, s2 });
    const stmts = Block.getStmts(&store, idx);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
    try std.testing.expectEqual(s1, stmts[0]);
    try std.testing.expectEqual(s2, stmts[1]);
}

test "literal round-trip (str_and_extra with kind)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const text = try store.strings.intern(std.testing.allocator, "42");
    const idx = try Literal.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .text = text, .kind = 0, .bool_val = 0 });
    const rec = Literal.unpack(&store, idx);
    try std.testing.expectEqual(text, rec.text);
    try std.testing.expectEqual(@as(u32, 0), rec.kind);
    try std.testing.expectEqualStrings("42", store.strings.get(rec.text));
}

test "binary round-trip preserves op and operands" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const lhs = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const rhs = try ContinueStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try Binary.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .op = 7, .lhs = lhs, .rhs = rhs });
    const rec = Binary.unpack(&store, idx);
    try std.testing.expectEqual(@as(u32, 7), rec.op);
    try std.testing.expectEqual(lhs, rec.lhs);
    try std.testing.expectEqual(rhs, rec.rhs);
}

test "func round-trip with params range" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const fn_name = try store.strings.intern(std.testing.allocator, "greet");
    const p_name = try store.strings.intern(std.testing.allocator, "x");
    const param = try ParamDef.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .name = p_name, .type_annotation = .none, .default = .none });
    const params_start: u32 = @intCast(store.extra_data.items.len);
    try store.extra_data.append(std.testing.allocator, @intFromEnum(param));
    const params_end: u32 = @intCast(store.extra_data.items.len);
    const body = try Block.pack(&store, std.testing.allocator, .none, .none, .plain, &.{});
    const idx = try Func.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .name = fn_name, .return_type = .none, .body = body, .params_start = params_start, .params_end = params_end, .flags = 1 });
    const rec = Func.unpack(&store, idx);
    try std.testing.expectEqual(fn_name, rec.name);
    try std.testing.expectEqual(body, rec.body);
    try std.testing.expectEqual(params_start, rec.params_start);
    try std.testing.expectEqual(params_end, rec.params_end);
    try std.testing.expectEqual(@as(u32, 1), rec.flags);
}

test "type_id and type_class are preserved on pack" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const tid = try store.types.intern(std.testing.allocator, .{ .primitive = .bool });
    const fake_span: AstNodeIndex = @enumFromInt(5);
    const idx = try BreakStmt.pack(&store, std.testing.allocator, fake_span, tid, .error_union, .{});
    const entry = store.getNode(idx);
    try std.testing.expectEqual(tid, entry.type_id);
    try std.testing.expectEqual(TypeClass.error_union, entry.type_class);
    try std.testing.expectEqual(fake_span, entry.span);
}

test "array_lit round-trip with items" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const a = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const b = try ContinueStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const c = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try ArrayLit.pack(&store, std.testing.allocator, .none, .none, .plain, &.{ a, b, c });
    const items = ArrayLit.getItems(&store, idx);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(a, items[0]);
    try std.testing.expectEqual(b, items[1]);
    try std.testing.expectEqual(c, items[2]);
}

test "enum_variant_def round-trip (str_and_node shape)" {
    var store = MirStore.init();
    defer store.deinit(std.testing.allocator);

    const name = try store.strings.intern(std.testing.allocator, "Red");
    const val = try BreakStmt.pack(&store, std.testing.allocator, .none, .none, .plain, .{});
    const idx = try EnumVariantDef.pack(&store, std.testing.allocator, .none, .none, .plain, .{ .name = name, .value = val });
    const rec = EnumVariantDef.unpack(&store, idx);
    try std.testing.expectEqual(name, rec.name);
    try std.testing.expectEqual(val, rec.value);
}
