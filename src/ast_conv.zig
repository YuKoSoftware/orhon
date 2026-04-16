// ast_conv.zig — Convert *parser.Node tree to AstStore (Phase A4)
//
// Walks the pointer-based AST produced by the PEG builder and builds an
// equivalent index-based AstStore using ast_typed.zig pack functions.
// This is the "dual output" bridge: the existing builder produces *Node
// unchanged, and this converter then builds the AstStore from it.

const std = @import("std");
const parser = @import("parser.zig");
const ast_store_mod = @import("ast_store.zig");
const ast_typed = @import("ast_typed.zig");

const AstStore = ast_store_mod.AstStore;
const AstNodeIndex = ast_store_mod.AstNodeIndex;
const StringIndex = ast_store_mod.StringIndex;
const ExtraIndex = ast_store_mod.ExtraIndex;
const SourceSpanIndex = ast_store_mod.SourceSpanIndex;
const Node = parser.Node;

pub const ConvContext = struct {
    allocator: std.mem.Allocator,
    store: AstStore,

    pub fn init(allocator: std.mem.Allocator) ConvContext {
        return .{
            .allocator = allocator,
            .store = AstStore.init(),
        };
    }

    pub fn deinit(self: *ConvContext) void {
        self.store.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Intern a string slice into the store's string pool.
fn internStr(ctx: *ConvContext, s: []const u8) !StringIndex {
    return ctx.store.strings.intern(ctx.allocator, s);
}

/// Intern an optional string; returns .none for null.
fn internOptStr(ctx: *ConvContext, s: ?[]const u8) !StringIndex {
    if (s) |val| return internStr(ctx, val);
    return .none;
}

/// Convert a child node, handling optionals by returning .none for null.
fn convertOpt(ctx: *ConvContext, node: ?*const Node) anyerror!AstNodeIndex {
    if (node) |n| return convertNode(ctx, n);
    return .none;
}

/// Convert a slice of *Node into a temporary slice of AstNodeIndex.
fn convertSlice(ctx: *ConvContext, nodes: []const *Node) anyerror![]AstNodeIndex {
    const result = try ctx.allocator.alloc(AstNodeIndex, nodes.len);
    for (nodes, 0..) |n, i| {
        result[i] = try convertNode(ctx, n);
    }
    return result;
}

/// Append a slice of AstNodeIndex values to extra_data, return start/end.
fn appendNodeSlice(ctx: *ConvContext, items: []const AstNodeIndex) !struct { start: u32, end: u32 } {
    const start: u32 = @intCast(ctx.store.extra_data.items.len);
    for (items) |item| try ctx.store.extra_data.append(ctx.allocator, @intFromEnum(item));
    const end: u32 = @intCast(ctx.store.extra_data.items.len);
    return .{ .start = start, .end = end };
}

/// Append a slice of StringIndex values to extra_data, return start/end.
fn appendStringSlice(ctx: *ConvContext, items: []const StringIndex) !struct { start: u32, end: u32 } {
    const start: u32 = @intCast(ctx.store.extra_data.items.len);
    for (items) |item| try ctx.store.extra_data.append(ctx.allocator, @intFromEnum(item));
    const end: u32 = @intCast(ctx.store.extra_data.items.len);
    return .{ .start = start, .end = end };
}

const span_none: SourceSpanIndex = .none;

// ---------------------------------------------------------------------------
// Main converter
// ---------------------------------------------------------------------------

/// Convert a *parser.Node tree into an AstStore.
/// Returns the AstNodeIndex of the converted node.
pub fn convertNode(ctx: *ConvContext, node: *const Node) anyerror!AstNodeIndex {
    switch (node.*) {
        .program => |p| {
            const module_idx = try convertNode(ctx, p.module);

            const meta_idxs = try convertSlice(ctx, p.metadata);
            defer ctx.allocator.free(meta_idxs);
            const import_idxs = try convertSlice(ctx, p.imports);
            defer ctx.allocator.free(import_idxs);
            const top_idxs = try convertSlice(ctx, p.top_level);
            defer ctx.allocator.free(top_idxs);

            return ast_typed.Program.pack(
                &ctx.store,
                ctx.allocator,
                span_none,
                module_idx,
                meta_idxs,
                import_idxs,
                top_idxs,
            );
        },

        .module_decl => |m| {
            const name_si = try internStr(ctx, m.name);
            // doc is stored as an identifier node if present, .none otherwise
            const doc_idx: AstNodeIndex = if (m.doc) |doc_str| blk: {
                const si = try internStr(ctx, doc_str);
                break :blk try ast_typed.Identifier.pack(&ctx.store, ctx.allocator, span_none, .{ .name = si });
            } else .none;
            return ast_typed.ModuleDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .doc = doc_idx,
            });
        },

        .import_decl => |imp| {
            const path_si = try internStr(ctx, imp.path);
            const scope_si = try internOptStr(ctx, imp.scope);
            const alias_si = try internOptStr(ctx, imp.alias);
            const flags: u32 = if (imp.is_include) 1 else 0;
            return ast_typed.ImportDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .path = path_si,
                .scope = scope_si,
                .alias = alias_si,
                .flags = flags,
            });
        },

        .metadata => |meta| {
            const value_idx = try convertNode(ctx, meta.value);
            return ast_typed.Metadata.pack(&ctx.store, ctx.allocator, span_none, .{
                .field = @intFromEnum(meta.field),
                .value = value_idx,
            });
        },

        .func_decl => |f| {
            const name_si = try internStr(ctx, f.name);
            const param_idxs = try convertSlice(ctx, f.params);
            defer ctx.allocator.free(param_idxs);
            const params_range = try appendNodeSlice(ctx, param_idxs);
            const ret_idx = try convertNode(ctx, f.return_type);
            const body_idx = try convertNode(ctx, f.body);
            // flags: bit 0 = is_pub, bit 1 = is_compt
            var flags: u32 = 0;
            if (f.is_pub) flags |= 1;
            if (f.context == .compt) flags |= 2;
            return ast_typed.FuncDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .return_type = ret_idx,
                .body = body_idx,
                .params_start = params_range.start,
                .params_end = params_range.end,
                .flags = flags,
            });
        },

        .struct_decl => |s| {
            const name_si = try internStr(ctx, s.name);
            const member_idxs = try convertSlice(ctx, s.members);
            defer ctx.allocator.free(member_idxs);
            const members_range = try appendNodeSlice(ctx, member_idxs);
            const tp_idxs = try convertSlice(ctx, s.type_params);
            defer ctx.allocator.free(tp_idxs);
            const tp_range = try appendNodeSlice(ctx, tp_idxs);
            // Intern blueprint names and store as string indices in extra_data
            const bp_names = try ctx.allocator.alloc(StringIndex, s.blueprints.len);
            defer ctx.allocator.free(bp_names);
            for (s.blueprints, 0..) |bp, i| {
                bp_names[i] = try internStr(ctx, bp);
            }
            const bp_range = try appendStringSlice(ctx, bp_names);
            var flags: u32 = 0;
            if (s.is_pub) flags |= 1;
            return ast_typed.StructDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .members_start = members_range.start,
                .members_end = members_range.end,
                .type_params_start = tp_range.start,
                .type_params_end = tp_range.end,
                .blueprints_start = bp_range.start,
                .blueprints_end = bp_range.end,
                .flags = flags,
            });
        },

        .blueprint_decl => |bp| {
            const name_si = try internStr(ctx, bp.name);
            const method_idxs = try convertSlice(ctx, bp.methods);
            defer ctx.allocator.free(method_idxs);
            const methods_range = try appendNodeSlice(ctx, method_idxs);
            var flags: u32 = 0;
            if (bp.is_pub) flags |= 1;
            return ast_typed.BlueprintDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .methods_start = methods_range.start,
                .methods_end = methods_range.end,
                .flags = flags,
            });
        },

        .enum_decl => |e| {
            const name_si = try internStr(ctx, e.name);
            const backing_idx = try convertNode(ctx, e.backing_type);
            const member_idxs = try convertSlice(ctx, e.members);
            defer ctx.allocator.free(member_idxs);
            const members_range = try appendNodeSlice(ctx, member_idxs);
            var flags: u32 = 0;
            if (e.is_pub) flags |= 1;
            return ast_typed.EnumDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .backing_type = backing_idx,
                .members_start = members_range.start,
                .members_end = members_range.end,
                .flags = flags,
            });
        },

        .handle_decl => |h| {
            const name_si = try internStr(ctx, h.name);
            var flags: u32 = 0;
            if (h.is_pub) flags |= 1;
            return ast_typed.HandleDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .flags = flags,
            });
        },

        .var_decl => |v| {
            const name_si = try internStr(ctx, v.name);
            const value_idx = try convertNode(ctx, v.value);
            const type_idx = try convertOpt(ctx, if (v.type_annotation) |ta| ta else null);
            // flags: bit 0 = is_pub, bit 1 = is_const
            var flags: u32 = 0;
            if (v.is_pub) flags |= 1;
            if (v.mutability == .constant) flags |= 2;
            return ast_typed.VarDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .value = value_idx,
                .type_annotation = type_idx,
                .flags = flags,
            });
        },

        .destruct_decl => |d| {
            const value_idx = try convertNode(ctx, d.value);
            // Intern names and store in extra_data
            const name_sis = try ctx.allocator.alloc(StringIndex, d.names.len);
            defer ctx.allocator.free(name_sis);
            for (d.names, 0..) |n, i| {
                name_sis[i] = try internStr(ctx, n);
            }
            const names_range = try appendStringSlice(ctx, name_sis);
            return ast_typed.DestructDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .value = value_idx,
                .names_start = names_range.start,
                .names_end = names_range.end,
                .is_const = if (d.is_const) @as(u32, 1) else 0,
            });
        },

        .test_decl => |t| {
            const desc_si = try internStr(ctx, t.description);
            const body_idx = try convertNode(ctx, t.body);
            return ast_typed.TestDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .description = desc_si,
                .body = body_idx,
            });
        },

        .field_decl => |f| {
            const name_si = try internStr(ctx, f.name);
            const type_idx = try convertNode(ctx, f.type_annotation);
            const default_idx = try convertOpt(ctx, if (f.default_value) |dv| dv else null);
            var flags: u32 = 0;
            if (f.is_pub) flags |= 1;
            return ast_typed.FieldDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .type_annotation = type_idx,
                .default_value = default_idx,
                .flags = flags,
            });
        },

        .enum_variant => |ev| {
            const name_si = try internStr(ctx, ev.name);
            const value_idx = try convertOpt(ctx, if (ev.value) |v| v else null);
            return ast_typed.EnumVariant.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .value = value_idx,
            });
        },

        .param => |p| {
            const name_si = try internStr(ctx, p.name);
            const type_idx = try convertNode(ctx, p.type_annotation);
            const default_idx = try convertOpt(ctx, if (p.default_value) |dv| dv else null);
            return ast_typed.Param.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .type_annotation = type_idx,
                .default_value = default_idx,
            });
        },

        .block => |blk| {
            const stmt_idxs = try convertSlice(ctx, blk.statements);
            defer ctx.allocator.free(stmt_idxs);
            return ast_typed.Block.pack(&ctx.store, ctx.allocator, span_none, stmt_idxs);
        },

        .return_stmt => |r| {
            const value_idx = try convertOpt(ctx, if (r.value) |v| v else null);
            return ast_typed.ReturnStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .value = value_idx,
            });
        },

        .if_stmt => |i| {
            const cond_idx = try convertNode(ctx, i.condition);
            const then_idx = try convertNode(ctx, i.then_block);
            const else_idx = try convertOpt(ctx, if (i.else_block) |eb| eb else null);
            return ast_typed.IfStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .condition = cond_idx,
                .then_block = then_idx,
                .else_block = else_idx,
            });
        },

        .while_stmt => |w| {
            const cond_idx = try convertNode(ctx, w.condition);
            const body_idx = try convertNode(ctx, w.body);
            const cont_idx = try convertOpt(ctx, if (w.continue_expr) |ce| ce else null);
            return ast_typed.WhileStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .condition = cond_idx,
                .body = body_idx,
                .continue_expr = cont_idx,
            });
        },

        .for_stmt => |f| {
            const body_idx = try convertNode(ctx, f.body);
            const iter_idxs = try convertSlice(ctx, f.iterables);
            defer ctx.allocator.free(iter_idxs);
            const iters_range = try appendNodeSlice(ctx, iter_idxs);
            // Intern capture names and store in extra_data
            const cap_sis = try ctx.allocator.alloc(StringIndex, f.captures.len);
            defer ctx.allocator.free(cap_sis);
            for (f.captures, 0..) |c, idx| {
                cap_sis[idx] = try internStr(ctx, c);
            }
            const caps_range = try appendStringSlice(ctx, cap_sis);
            var flags: u32 = 0;
            if (f.is_tuple_capture) flags |= 1;
            return ast_typed.ForStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .body = body_idx,
                .iterables_start = iters_range.start,
                .iterables_end = iters_range.end,
                .captures_start = caps_range.start,
                .captures_end = caps_range.end,
                .flags = flags,
            });
        },

        .defer_stmt => |d| {
            const body_idx = try convertNode(ctx, d.body);
            return ast_typed.DeferStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .body = body_idx,
            });
        },

        .match_stmt => |m| {
            const value_idx = try convertNode(ctx, m.value);
            const arm_idxs = try convertSlice(ctx, m.arms);
            defer ctx.allocator.free(arm_idxs);
            const arms_range = try appendNodeSlice(ctx, arm_idxs);
            return ast_typed.MatchStmt.pack(&ctx.store, ctx.allocator, span_none, .{
                .value = value_idx,
                .arms_start = arms_range.start,
                .arms_end = arms_range.end,
            });
        },

        .match_arm => |ma| {
            const pattern_idx = try convertNode(ctx, ma.pattern);
            const guard_idx = try convertOpt(ctx, if (ma.guard) |g| g else null);
            const body_idx = try convertNode(ctx, ma.body);
            return ast_typed.MatchArm.pack(&ctx.store, ctx.allocator, span_none, .{
                .pattern = pattern_idx,
                .guard = guard_idx,
                .body = body_idx,
            });
        },

        .break_stmt => {
            return ast_typed.BreakStmt.pack(&ctx.store, ctx.allocator, span_none, .{});
        },

        .continue_stmt => {
            return ast_typed.ContinueStmt.pack(&ctx.store, ctx.allocator, span_none, .{});
        },

        .assignment => |op| {
            const lhs_idx = try convertNode(ctx, op.left);
            const rhs_idx = try convertNode(ctx, op.right);
            return ast_typed.Assignment.pack(&ctx.store, ctx.allocator, span_none, .{
                .op = @intFromEnum(op.op),
                .lhs = lhs_idx,
                .rhs = rhs_idx,
            });
        },

        .binary_expr => |op| {
            const lhs_idx = try convertNode(ctx, op.left);
            const rhs_idx = try convertNode(ctx, op.right);
            return ast_typed.BinaryExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .op = @intFromEnum(op.op),
                .lhs = lhs_idx,
                .rhs = rhs_idx,
            });
        },

        .unary_expr => |op| {
            const operand_idx = try convertNode(ctx, op.operand);
            return ast_typed.UnaryExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .op = @intFromEnum(op.op),
                .operand = operand_idx,
            });
        },

        .call_expr => |c| {
            const callee_idx = try convertNode(ctx, c.callee);
            const arg_idxs = try convertSlice(ctx, c.args);
            defer ctx.allocator.free(arg_idxs);
            const args_range = try appendNodeSlice(ctx, arg_idxs);
            // Intern arg names and store in extra_data
            const name_sis = try ctx.allocator.alloc(StringIndex, c.arg_names.len);
            defer ctx.allocator.free(name_sis);
            for (c.arg_names, 0..) |n, i| {
                name_sis[i] = try internStr(ctx, n);
            }
            const names_range = try appendStringSlice(ctx, name_sis);
            return ast_typed.CallExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .callee = callee_idx,
                .args_start = args_range.start,
                .args_end = args_range.end,
                .arg_names_start = names_range.start,
            });
        },

        .index_expr => |ie| {
            const obj_idx = try convertNode(ctx, ie.object);
            const idx_idx = try convertNode(ctx, ie.index);
            return ast_typed.IndexExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .object = obj_idx,
                .index = idx_idx,
            });
        },

        .slice_expr => |se| {
            const obj_idx = try convertNode(ctx, se.object);
            const low_idx = try convertNode(ctx, se.low);
            const high_idx = try convertNode(ctx, se.high);
            return ast_typed.SliceExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .object = obj_idx,
                .low = low_idx,
                .high = high_idx,
            });
        },

        .field_expr => |fe| {
            const field_si = try internStr(ctx, fe.field);
            const obj_idx = try convertNode(ctx, fe.object);
            return ast_typed.FieldExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .field = field_si,
                .object = obj_idx,
            });
        },

        .mut_borrow_expr => |child| {
            const child_idx = try convertNode(ctx, child);
            return ast_typed.MutBorrowExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .child = child_idx,
            });
        },

        .const_borrow_expr => |child| {
            const child_idx = try convertNode(ctx, child);
            return ast_typed.ConstBorrowExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .child = child_idx,
            });
        },

        .compiler_func => |cf| {
            const name_si = try internStr(ctx, cf.name);
            const arg_idxs = try convertSlice(ctx, cf.args);
            defer ctx.allocator.free(arg_idxs);
            const args_range = try appendNodeSlice(ctx, arg_idxs);
            return ast_typed.CompilerFunc.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .args_start = args_range.start,
                .args_end = args_range.end,
            });
        },

        .identifier => |name| {
            const si = try internStr(ctx, name);
            return ast_typed.Identifier.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = si,
            });
        },

        .int_literal => |text| {
            const si = try internStr(ctx, text);
            return ast_typed.IntLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .text = si,
            });
        },

        .float_literal => |text| {
            const si = try internStr(ctx, text);
            return ast_typed.FloatLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .text = si,
            });
        },

        .string_literal => |text| {
            const si = try internStr(ctx, text);
            return ast_typed.StringLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .text = si,
            });
        },

        .bool_literal => |val| {
            return ast_typed.BoolLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .value = val,
            });
        },

        .null_literal => {
            return ast_typed.NullLiteral.pack(&ctx.store, ctx.allocator, span_none, .{});
        },

        .array_literal => |items| {
            const item_idxs = try convertSlice(ctx, items);
            defer ctx.allocator.free(item_idxs);
            return ast_typed.ArrayLiteral.pack(&ctx.store, ctx.allocator, span_none, item_idxs);
        },

        .tuple_literal => |tl| {
            const elem_idxs = try convertSlice(ctx, tl.elements);
            defer ctx.allocator.free(elem_idxs);
            const elems_range = try appendNodeSlice(ctx, elem_idxs);
            // Intern names if present
            const names_start: u32 = @intCast(ctx.store.extra_data.items.len);
            if (tl.names) |names| {
                for (names) |n| {
                    const si = try internStr(ctx, n);
                    try ctx.store.extra_data.append(ctx.allocator, @intFromEnum(si));
                }
            }
            return ast_typed.TupleLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .elements_start = elems_range.start,
                .elements_end = elems_range.end,
                .names_start = names_start,
            });
        },

        .version_literal => |parts| {
            const major = try internStr(ctx, parts[0]);
            const minor = try internStr(ctx, parts[1]);
            const patch = try internStr(ctx, parts[2]);
            return ast_typed.VersionLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .major = major,
                .minor = minor,
                .patch = patch,
            });
        },

        .error_literal => |name| {
            const si = try internStr(ctx, name);
            return ast_typed.ErrorLiteral.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = si,
            });
        },

        .range_expr => |op| {
            const lhs_idx = try convertNode(ctx, op.left);
            const rhs_idx = try convertNode(ctx, op.right);
            return ast_typed.RangeExpr.pack(&ctx.store, ctx.allocator, span_none, .{
                .op = @intFromEnum(op.op),
                .lhs = lhs_idx,
                .rhs = rhs_idx,
            });
        },

        .interpolated_string => |is| {
            // Each part is encoded as 2 u32 words: tag (0=literal, 1=expr), then payload
            const parts_start: u32 = @intCast(ctx.store.extra_data.items.len);
            for (is.parts) |part| {
                switch (part) {
                    .literal => |text| {
                        const si = try internStr(ctx, text);
                        try ctx.store.extra_data.append(ctx.allocator, 0); // tag: literal
                        try ctx.store.extra_data.append(ctx.allocator, @intFromEnum(si));
                    },
                    .expr => |expr_node| {
                        const expr_idx = try convertNode(ctx, expr_node);
                        try ctx.store.extra_data.append(ctx.allocator, 1); // tag: expr
                        try ctx.store.extra_data.append(ctx.allocator, @intFromEnum(expr_idx));
                    },
                }
            }
            const parts_end: u32 = @intCast(ctx.store.extra_data.items.len);
            return ast_typed.InterpolatedString.pack(&ctx.store, ctx.allocator, span_none, .{
                .parts_start = parts_start,
                .parts_end = parts_end,
            });
        },

        .type_slice => |elem| {
            const elem_idx = try convertNode(ctx, elem);
            return ast_typed.TypeSlice.pack(&ctx.store, ctx.allocator, span_none, .{
                .elem = elem_idx,
            });
        },

        .type_array => |ta| {
            const size_idx = try convertNode(ctx, ta.size);
            const elem_idx = try convertNode(ctx, ta.elem);
            return ast_typed.TypeArray.pack(&ctx.store, ctx.allocator, span_none, .{
                .size = size_idx,
                .elem = elem_idx,
            });
        },

        .type_ptr => |tp| {
            const elem_idx = try convertNode(ctx, tp.elem);
            return ast_typed.TypePtr.pack(&ctx.store, ctx.allocator, span_none, .{
                .kind = @intFromEnum(tp.kind),
                .elem = elem_idx,
            });
        },

        .type_union => |members| {
            const member_idxs = try convertSlice(ctx, members);
            defer ctx.allocator.free(member_idxs);
            return ast_typed.TypeUnion.pack(&ctx.store, ctx.allocator, span_none, member_idxs);
        },

        .type_tuple_named => |fields| {
            // Each NamedTypeField becomes a FieldDecl-like node in the store
            const field_idxs = try ctx.allocator.alloc(AstNodeIndex, fields.len);
            defer ctx.allocator.free(field_idxs);
            for (fields, 0..) |f, i| {
                const name_si = try internStr(ctx, f.name);
                const type_idx = try convertNode(ctx, f.type_node);
                const default_idx = try convertOpt(ctx, if (f.default) |d| d else null);
                field_idxs[i] = try ast_typed.FieldDecl.pack(&ctx.store, ctx.allocator, span_none, .{
                    .name = name_si,
                    .type_annotation = type_idx,
                    .default_value = default_idx,
                    .flags = 0,
                });
            }
            const fields_range = try appendNodeSlice(ctx, field_idxs);
            return ast_typed.TypeTupleNamed.pack(&ctx.store, ctx.allocator, span_none, .{
                .fields_start = fields_range.start,
                .fields_end = fields_range.end,
            });
        },

        .type_func => |tf| {
            const ret_idx = try convertNode(ctx, tf.ret);
            const param_idxs = try convertSlice(ctx, tf.params);
            defer ctx.allocator.free(param_idxs);
            const params_range = try appendNodeSlice(ctx, param_idxs);
            return ast_typed.TypeFunc.pack(&ctx.store, ctx.allocator, span_none, .{
                .ret = ret_idx,
                .params_start = params_range.start,
                .params_end = params_range.end,
            });
        },

        .type_generic => |tg| {
            const name_si = try internStr(ctx, tg.name);
            const arg_idxs = try convertSlice(ctx, tg.args);
            defer ctx.allocator.free(arg_idxs);
            const args_range = try appendNodeSlice(ctx, arg_idxs);
            return ast_typed.TypeGeneric.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = name_si,
                .args_start = args_range.start,
                .args_end = args_range.end,
            });
        },

        .type_named => |name| {
            const si = try internStr(ctx, name);
            return ast_typed.TypeNamed.pack(&ctx.store, ctx.allocator, span_none, .{
                .name = si,
            });
        },

        .struct_type => |fields| {
            const field_idxs = try convertSlice(ctx, fields);
            defer ctx.allocator.free(field_idxs);
            return ast_typed.StructType.pack(&ctx.store, ctx.allocator, span_none, field_idxs);
        },
    }
}

// ---------------------------------------------------------------------------
// Node counter — walks the pointer-based *Node tree
// ---------------------------------------------------------------------------

pub fn countNodes(node: *const Node) usize {
    var count: usize = 1;
    switch (node.*) {
        .program => |p| {
            count += countNodes(p.module);
            for (p.metadata) |m| count += countNodes(m);
            for (p.imports) |i| count += countNodes(i);
            for (p.top_level) |t| count += countNodes(t);
        },
        .module_decl => {},
        .import_decl => {},
        .metadata => |m| {
            count += countNodes(m.value);
        },
        .func_decl => |f| {
            for (f.params) |p| count += countNodes(p);
            count += countNodes(f.return_type);
            count += countNodes(f.body);
        },
        .struct_decl => |s| {
            for (s.type_params) |tp| count += countNodes(tp);
            for (s.members) |m| count += countNodes(m);
        },
        .blueprint_decl => |bp| {
            for (bp.methods) |m| count += countNodes(m);
        },
        .enum_decl => |e| {
            count += countNodes(e.backing_type);
            for (e.members) |m| count += countNodes(m);
        },
        .handle_decl => {},
        .var_decl => |v| {
            if (v.type_annotation) |ta| count += countNodes(ta);
            count += countNodes(v.value);
        },
        .destruct_decl => |d| {
            count += countNodes(d.value);
        },
        .test_decl => |t| {
            count += countNodes(t.body);
        },
        .field_decl => |f| {
            count += countNodes(f.type_annotation);
            if (f.default_value) |dv| count += countNodes(dv);
        },
        .enum_variant => |ev| {
            if (ev.value) |v| count += countNodes(v);
        },
        .param => |p| {
            count += countNodes(p.type_annotation);
            if (p.default_value) |dv| count += countNodes(dv);
        },
        .block => |blk| {
            for (blk.statements) |s| count += countNodes(s);
        },
        .return_stmt => |r| {
            if (r.value) |v| count += countNodes(v);
        },
        .if_stmt => |i| {
            count += countNodes(i.condition);
            count += countNodes(i.then_block);
            if (i.else_block) |eb| count += countNodes(eb);
        },
        .while_stmt => |w| {
            count += countNodes(w.condition);
            count += countNodes(w.body);
            if (w.continue_expr) |ce| count += countNodes(ce);
        },
        .for_stmt => |f| {
            for (f.iterables) |it| count += countNodes(it);
            count += countNodes(f.body);
        },
        .defer_stmt => |d| {
            count += countNodes(d.body);
        },
        .match_stmt => |m| {
            count += countNodes(m.value);
            for (m.arms) |a| count += countNodes(a);
        },
        .match_arm => |ma| {
            count += countNodes(ma.pattern);
            if (ma.guard) |g| count += countNodes(g);
            count += countNodes(ma.body);
        },
        .break_stmt, .continue_stmt => {},
        .assignment, .binary_expr, .range_expr => |op| {
            count += countNodes(op.left);
            count += countNodes(op.right);
        },
        .unary_expr => |op| {
            count += countNodes(op.operand);
        },
        .call_expr => |c| {
            count += countNodes(c.callee);
            for (c.args) |a| count += countNodes(a);
        },
        .index_expr => |ie| {
            count += countNodes(ie.object);
            count += countNodes(ie.index);
        },
        .slice_expr => |se| {
            count += countNodes(se.object);
            count += countNodes(se.low);
            count += countNodes(se.high);
        },
        .field_expr => |fe| {
            count += countNodes(fe.object);
        },
        .mut_borrow_expr, .const_borrow_expr => |child| {
            count += countNodes(child);
        },
        .compiler_func => |cf| {
            for (cf.args) |a| count += countNodes(a);
        },
        .identifier, .int_literal, .float_literal, .string_literal => {},
        .bool_literal => {},
        .null_literal => {},
        .array_literal => |items| {
            for (items) |it| count += countNodes(it);
        },
        .tuple_literal => |tl| {
            for (tl.elements) |e| count += countNodes(e);
        },
        .version_literal => {},
        .error_literal => {},
        .interpolated_string => |is| {
            for (is.parts) |part| {
                switch (part) {
                    .literal => {},
                    .expr => |e| count += countNodes(e),
                }
            }
        },
        .type_slice => |elem| {
            count += countNodes(elem);
        },
        .type_array => |ta| {
            count += countNodes(ta.size);
            count += countNodes(ta.elem);
        },
        .type_ptr => |tp| {
            count += countNodes(tp.elem);
        },
        .type_union => |members| {
            for (members) |m| count += countNodes(m);
        },
        .type_tuple_named => |fields| {
            for (fields) |f| {
                count += countNodes(f.type_node);
                if (f.default) |d| count += countNodes(d);
                // +1 for the FieldDecl node we synthesize in the store
                count += 1;
            }
            // Subtract 1 per field since FieldDecl nodes are extra, not counted in *Node tree
            // Actually, the *Node tree has one node for type_tuple_named; the store will have
            // 1 + N (type_tuple_named + N field_decl children). So the *Node tree count for
            // this branch starts at 1 (this node) and recurses into children; the store will
            // have 1 + N nodes. We need to account for the extra FieldDecl nodes.
            // Leave as-is — the parity test will compare: countNodes(root) vs (store.nodes.len - 1).
            // We need countNodes to count exactly what convertNode produces.
        },
        .type_func => |tf| {
            count += countNodes(tf.ret);
            for (tf.params) |p| count += countNodes(p);
        },
        .type_generic => |tg| {
            for (tg.args) |a| count += countNodes(a);
        },
        .type_named => {},
        .struct_type => |fields| {
            for (fields) |f| count += countNodes(f);
        },
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests — parity harness
// ---------------------------------------------------------------------------

const lexer = @import("lexer.zig");
const peg = @import("peg.zig");
const capture_mod = @import("peg/capture.zig");
const builder_mod = @import("peg/builder.zig");
const AstKind = ast_store_mod.AstKind;

fn parseAndConvert(source: []const u8) !struct { node_count: usize, store_count: usize, root: *const Node, store: AstStore, root_idx: AstNodeIndex, ctx: builder_mod.BuildContext } {
    const alloc = std.testing.allocator;

    var g = try peg.loadGrammar(alloc);
    defer g.deinit();

    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var engine = capture_mod.CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return error.TestFailed;

    const result = try builder_mod.buildAST(&cap, tokens.items, std.heap.page_allocator);
    // Note: result.ctx owns arena memory; caller must handle cleanup.

    const nc = countNodes(result.node);

    var conv = ConvContext.init(alloc);
    const root_idx = try convertNode(&conv, result.node);

    // store.nodes.len includes the sentinel at slot 0
    const sc = conv.store.nodes.len - 1;

    return .{
        .node_count = nc,
        .store_count = sc,
        .root = result.node,
        .store = conv.store,
        .root_idx = root_idx,
        .ctx = result.ctx,
    };
}

test "parity — minimal program node count" {
    var r = try parseAndConvert("module myapp\n");
    defer r.ctx.deinit();
    defer {
        var store = r.store;
        store.deinit(std.testing.allocator);
    }

    // Root must be .program
    const root_node = r.store.getNode(r.root_idx);
    try std.testing.expectEqual(AstKind.program, root_node.tag);

    // Verify module name round-trips through the store
    const prog_rec = ast_typed.Program.unpack(&r.store, r.root_idx);
    const mod_rec = ast_typed.ModuleDecl.unpack(&r.store, prog_rec.module);
    try std.testing.expectEqualStrings("myapp", r.store.strings.get(mod_rec.name));

    // Node count parity
    try std.testing.expectEqual(r.node_count, r.store_count);
}

test "parity — program with function" {
    const src =
        \\module myapp
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
    ;
    var r = try parseAndConvert(src);
    defer r.ctx.deinit();
    defer {
        var store = r.store;
        store.deinit(std.testing.allocator);
    }

    const root_node = r.store.getNode(r.root_idx);
    try std.testing.expectEqual(AstKind.program, root_node.tag);

    // Verify function name round-trips
    const prog_rec = ast_typed.Program.unpack(&r.store, r.root_idx);
    const tl_slice = r.store.extra_data.items[prog_rec.top_level_start..prog_rec.top_level_end];
    try std.testing.expect(tl_slice.len == 1);
    const func_idx: AstNodeIndex = @enumFromInt(tl_slice[0]);
    const func_node = r.store.getNode(func_idx);
    try std.testing.expectEqual(AstKind.func_decl, func_node.tag);
    const func_rec = ast_typed.FuncDecl.unpack(&r.store, func_idx);
    try std.testing.expectEqualStrings("add", r.store.strings.get(func_rec.name));

    // Node count parity
    try std.testing.expectEqual(r.node_count, r.store_count);
}

test "parity — struct with fields" {
    const src =
        \\module example
        \\
        \\pub struct Point {
        \\    pub x: f64
        \\    pub y: f64
        \\}
        \\
    ;
    var r = try parseAndConvert(src);
    defer r.ctx.deinit();
    defer {
        var store = r.store;
        store.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(AstKind.program, r.store.getNode(r.root_idx).tag);
    try std.testing.expectEqual(r.node_count, r.store_count);
}

test "parity — enum declaration" {
    const src =
        \\module mymod
        \\
        \\pub enum(u8) Direction {
        \\    North
        \\    South
        \\    East
        \\    West
        \\}
        \\
    ;
    var r = try parseAndConvert(src);
    defer r.ctx.deinit();
    defer {
        var store = r.store;
        store.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(r.node_count, r.store_count);
}

test "parity — if/match/while" {
    const src =
        \\module mymod
        \\
        \\func f(n: i32) i32 {
        \\    if(n > 0) {
        \\        return n
        \\    }
        \\    while(n < 10) {
        \\        n = n + 1
        \\    }
        \\    match(n) {
        \\        0 => { return 0 }
        \\        else => { return n }
        \\    }
        \\}
        \\
    ;
    var r = try parseAndConvert(src);
    defer r.ctx.deinit();
    defer {
        var store = r.store;
        store.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(r.node_count, r.store_count);
}
