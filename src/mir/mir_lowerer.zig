// mir_lowerer.zig — MIR lowering pass

const std = @import("std");
const parser = @import("../parser.zig");
const declarations = @import("../declarations.zig");
const K = @import("../constants.zig");
const mir_types = @import("mir_types.zig");
const mir_node = @import("mir_node.zig");
const mir_registry = @import("mir_registry.zig");

const RT = mir_types.RT;
const NodeInfo = mir_types.NodeInfo;
const NodeMap = mir_types.NodeMap;
const classifyType = mir_types.classifyType;
const TypeClass = mir_types.TypeClass;
const MirNode = mir_node.MirNode;
const MirKind = mir_node.MirKind;
const LiteralKind = mir_node.LiteralKind;
const IfNarrowing = mir_node.IfNarrowing;
const UnionRegistry = mir_registry.UnionRegistry;

// ── MIR Lowerer ─────────────────────────────────────────────

/// Lowers AST + NodeMap into a MirNode tree.
/// Runs after MirAnnotator.annotate(), before codegen.
pub const MirLowerer = struct {
    allocator: std.mem.Allocator, // arena allocator — all nodes freed together
    arena: std.heap.ArenaAllocator,
    node_map: *const NodeMap,
    union_registry: *const UnionRegistry,
    decls: *const declarations.DeclTable,
    var_types: *const std.StringHashMapUnmanaged(NodeInfo),
    interp_counter: u32 = 0,

    pub fn init(
        backing: std.mem.Allocator,
        node_map: *const NodeMap,
        union_registry: *const UnionRegistry,
        decls: *const declarations.DeclTable,
        var_types: *const std.StringHashMapUnmanaged(NodeInfo),
    ) MirLowerer {
        return .{
            .allocator = undefined, // set in lower() from arena field
            .arena = std.heap.ArenaAllocator.init(backing),
            .node_map = node_map,
            .union_registry = union_registry,
            .decls = decls,
            .var_types = var_types,
        };
    }

    pub fn deinit(self: *MirLowerer) void {
        self.arena.deinit();
    }

    /// Lower the entire program AST into a MirNode tree.
    pub fn lower(self: *MirLowerer, ast: *parser.Node) !*MirNode {
        self.allocator = self.arena.allocator();
        return self.lowerNode(ast);
    }

    fn lowerNode(self: *MirLowerer, node: *parser.Node) anyerror!*MirNode {
        const info = self.node_map.get(node);
        const resolved = if (info) |i| i.resolved_type else RT.unknown;
        const tc = if (info) |i| i.type_class else classifyType(resolved);
        const coercion_val = if (info) |i| i.coercion else null;
        const coerce_tag_val = if (info) |i| i.coerce_tag else null;

        const kind = astToMirKind(node);

        var mir_node_ptr = try self.allocator.create(MirNode);
        mir_node_ptr.* = .{
            .ast = node,
            .resolved_type = resolved,
            .type_class = tc,
            .coercion = coercion_val,
            .coerce_tag = coerce_tag_val,
            .kind = kind,
            .children = &.{},
        };

        // Populate self-contained data fields from AST
        populateData(mir_node_ptr, node);

        // Lower children based on AST node kind
        switch (node.*) {
            .program => |p| {
                mir_node_ptr.children = try self.lowerSlice(p.top_level);
            },
            .func_decl => |f| {
                // Children: [params..., body]
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (f.params) |param| {
                    try children.append(self.allocator, try self.lowerNode(param));
                }
                try children.append(self.allocator, try self.lowerNode(f.body));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .struct_decl => |s| {
                mir_node_ptr.children = try self.lowerSlice(s.members);
            },
            .blueprint_decl => {
                // Blueprints are erased at codegen — no children to lower
                mir_node_ptr.children = &.{};
            },
            .enum_decl => |e| {
                mir_node_ptr.children = try self.lowerSlice(e.members);
            },
            .handle_decl => {
                mir_node_ptr.children = &.{};
            },
            .field_decl => |f| {
                if (f.default_value) |dv| {
                    var children = std.ArrayListUnmanaged(*MirNode){};
                    try children.append(self.allocator, try self.lowerNode(dv));
                    mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                }
            },
            .block => |b| {
                // Process block statements — hoist interpolation temps
                mir_node_ptr.children = try self.lowerBlock(b.statements);
            },
            .var_decl => |v| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(v.value));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    var children = std.ArrayListUnmanaged(*MirNode){};
                    try children.append(self.allocator, try self.lowerNode(val));
                    mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                }
            },
            .if_stmt => |i| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(i.condition));
                try children.append(self.allocator, try self.lowerNode(i.then_block));
                if (i.else_block) |e| try children.append(self.allocator, try self.lowerNode(e));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                // Pre-compute type narrowing from `is` checks
                mir_node_ptr.narrowing = self.extractNarrowing(i.condition, i.then_block);
                // Stamp narrowed_to on descendant identifier nodes
                if (mir_node_ptr.narrowing) |narrowing| {
                    if (narrowing.then_type) |tt| stampNarrowing(mir_node_ptr.thenBlock(), narrowing.var_name, tt);
                    if (mir_node_ptr.elseBlock()) |else_m| {
                        if (narrowing.else_type) |et| stampNarrowing(else_m, narrowing.var_name, et);
                    }
                }
            },
            .while_stmt => |w| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(w.condition));
                try children.append(self.allocator, try self.lowerNode(w.body));
                if (w.continue_expr) |ce| try children.append(self.allocator, try self.lowerNode(ce));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .for_stmt => |fs| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (fs.iterables) |iter| try children.append(self.allocator, try self.lowerNode(iter));
                try children.append(self.allocator, try self.lowerNode(fs.body));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                mir_node_ptr.num_iterables = fs.iterables.len;
            },
            .defer_stmt => |d| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(d.body));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .match_stmt => |m| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(m.value));
                for (m.arms) |arm| try children.append(self.allocator, try self.lowerNode(arm));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                // Stamp narrowing for arbitrary union match arms
                if (mir_node_ptr.value().type_class == .arbitrary_union) {
                    const match_val = mir_node_ptr.value();
                    const match_var = if (match_val.kind == .identifier) match_val.name else null;
                    if (match_var) |vname| {
                        for (mir_node_ptr.matchArms()) |arm_mir| {
                            const pat_m = arm_mir.pattern();
                            if (pat_m.kind == .identifier and !std.mem.eql(u8, pat_m.name orelse "", "else")) {
                                stampNarrowing(arm_mir.body(), vname, pat_m.name orelse "");
                            }
                        }
                    }
                }
            },
            .match_arm => |arm_data| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(arm_data.pattern));
                if (arm_data.guard) |g| {
                    try children.append(self.allocator, try self.lowerNode(g));
                }
                try children.append(self.allocator, try self.lowerNode(arm_data.body));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .assignment => |a| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(a.left));
                try children.append(self.allocator, try self.lowerNode(a.right));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .binary_expr => |b| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(b.left));
                try children.append(self.allocator, try self.lowerNode(b.right));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .unary_expr => |u| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(u.operand));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .call_expr => |c| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(c.callee));
                for (c.args) |arg| try children.append(self.allocator, try self.lowerNode(arg));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .field_expr => |f| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(f.object));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .index_expr => |i| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(i.object));
                try children.append(self.allocator, try self.lowerNode(i.index));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .slice_expr => |s| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(s.object));
                try children.append(self.allocator, try self.lowerNode(s.low));
                try children.append(self.allocator, try self.lowerNode(s.high));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .mut_borrow_expr => |b| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(b));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .const_borrow_expr => |b| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(b));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .interpolated_string => |interp| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (interp.parts) |part| {
                    switch (part) {
                        .expr => |expr_node| try children.append(self.allocator, try self.lowerNode(expr_node)),
                        .literal => {},
                    }
                }
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .range_expr => |r| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(r.left));
                try children.append(self.allocator, try self.lowerNode(r.right));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .compiler_func => |c| {
                mir_node_ptr.children = try self.lowerSlice(c.args);
            },
            .array_literal => |a| {
                mir_node_ptr.children = try self.lowerSlice(a);
            },
            .version_literal => {},
            .test_decl => |td| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(td.body));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .destruct_decl => |d| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(d.value));
                mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
            },
            .import_decl => {
                mir_node_ptr.children = &.{};
            },
            .param => |p| {
                if (p.default_value) |dv| {
                    var children = std.ArrayListUnmanaged(*MirNode){};
                    try children.append(self.allocator, try self.lowerNode(dv));
                    mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
                }
            },
            // Leaf nodes — no children
            .int_literal,
            .float_literal,
            .string_literal,
            .bool_literal,
            .null_literal,
            .error_literal,
            .identifier,
            .break_stmt,
            .continue_stmt,
            .enum_variant,
            .module_decl,
            .metadata,
            => {},
            // Type nodes — passthrough
            .type_slice,
            .type_array,
            .type_ptr,
            .type_union,
            .type_tuple_named,
            .type_func,
            .type_generic,
            .type_named,
            => {},
            // Anonymous struct — lower children (fields, methods) into MIR nodes
            .struct_type => |members| {
                mir_node_ptr.children = try self.lowerSlice(members);
            },
        }

        return mir_node_ptr;
    }

    /// Lower a block's statements, hoisting interpolation temporaries.
    fn lowerBlock(self: *MirLowerer, statements: []*parser.Node) anyerror![]*MirNode {
        var result = std.ArrayListUnmanaged(*MirNode){};

        for (statements) |stmt| {
            // Check if this statement contains interpolated strings that need hoisting
            const interp_nodes = try self.findInterpolation(stmt);
            if (interp_nodes.len > 0) {
                // Hoist: create temp var + defer for each interpolation before the statement
                var names = try self.allocator.alloc([]const u8, interp_nodes.len);
                for (interp_nodes, 0..) |interp_node, i| {
                    const name = try std.fmt.allocPrint(self.allocator, "_orhon_interp_{d}", .{self.interp_counter});
                    self.interp_counter += 1;
                    names[i] = name;

                    // Lower expr children from the interpolated string parts
                    const interp = interp_node.interpolated_string;
                    var expr_children = std.ArrayListUnmanaged(*MirNode){};
                    for (interp.parts) |part| {
                        switch (part) {
                            .expr => |expr_node| try expr_children.append(self.allocator, try self.lowerNode(expr_node)),
                            .literal => {},
                        }
                    }
                    const lowered_children = try expr_children.toOwnedSlice(self.allocator);

                    // temp_var: const _orhon_interp_N = allocPrint(...)
                    const temp = try self.allocator.create(MirNode);
                    temp.* = .{
                        .ast = interp_node,
                        .resolved_type = RT{ .primitive = .string },
                        .type_class = .string,
                        .kind = .temp_var,
                        .children = lowered_children,
                        .injected_name = name,
                        .interp_parts = interp.parts,
                    };

                    // injected_defer: defer std.heap.smp_allocator.free(_orhon_interp_N)
                    const defer_node = try self.allocator.create(MirNode);
                    defer_node.* = .{
                        .ast = interp_node,
                        .resolved_type = RT.unknown,
                        .type_class = .plain,
                        .kind = .injected_defer,
                        .children = &.{},
                        .injected_name = name,
                    };

                    try result.append(self.allocator, temp);
                    try result.append(self.allocator, defer_node);
                }

                // Lower the statement and mark each interpolation for replacement
                const lowered_stmt = try self.lowerNode(stmt);
                for (interp_nodes, names) |interp_node, name| {
                    self.markInterpolationReplacement(lowered_stmt, interp_node, name);
                }
                try result.append(self.allocator, lowered_stmt);
            } else {
                try result.append(self.allocator, try self.lowerNode(stmt));
            }
        }

        // Post-narrowing: if an if_stmt has early exit, stamp subsequent siblings
        const items = result.items;
        for (items, 0..) |item, idx| {
            if (item.kind == .if_stmt) {
                if (item.narrowing) |narrowing| {
                    if (narrowing.post_type) |pt| {
                        for (items[idx + 1 ..]) |sibling| {
                            stampNarrowing(sibling, narrowing.var_name, pt);
                        }
                    }
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Collect all interpolated_string nodes in a statement.
    fn findInterpolation(self: *MirLowerer, node: *parser.Node) ![]*parser.Node {
        var list = std.ArrayListUnmanaged(*parser.Node){};
        switch (node.*) {
            .var_decl => |v| findInterpolationInExpr(v.value, &list, self.allocator),
            .call_expr => |c| {
                findInterpolationInExpr(c.callee, &list, self.allocator);
                for (c.args) |arg| findInterpolationInExpr(arg, &list, self.allocator);
            },
            .assignment => |a| {
                findInterpolationInExpr(a.left, &list, self.allocator);
                findInterpolationInExpr(a.right, &list, self.allocator);
            },
            .return_stmt => |r| {
                if (r.value) |v| findInterpolationInExpr(v, &list, self.allocator);
            },
            .if_stmt => |i| findInterpolationInExpr(i.condition, &list, self.allocator),
            .while_stmt => |w| findInterpolationInExpr(w.condition, &list, self.allocator),
            .match_stmt => |m| findInterpolationInExpr(m.value, &list, self.allocator),
            else => findInterpolationInExpr(node, &list, self.allocator),
        }
        return list.toOwnedSlice(self.allocator);
    }

    /// Recursively collect all interpolated_string nodes in an expression tree.
    fn findInterpolationInExpr(node: *parser.Node, list: *std.ArrayListUnmanaged(*parser.Node), alloc: std.mem.Allocator) void {
        switch (node.*) {
            .interpolated_string => list.append(alloc, node) catch {},
            .call_expr => |c| {
                findInterpolationInExpr(c.callee, list, alloc);
                for (c.args) |arg| findInterpolationInExpr(arg, list, alloc);
            },
            .binary_expr => |b| {
                findInterpolationInExpr(b.left, list, alloc);
                findInterpolationInExpr(b.right, list, alloc);
            },
            .unary_expr => |u| findInterpolationInExpr(u.operand, list, alloc),
            .field_expr => |f| findInterpolationInExpr(f.object, list, alloc),
            .index_expr => |i| findInterpolationInExpr(i.object, list, alloc),
            .slice_expr => |s| {
                findInterpolationInExpr(s.object, list, alloc);
                findInterpolationInExpr(s.low, list, alloc);
                findInterpolationInExpr(s.high, list, alloc);
            },
            else => {},
        }
    }

    /// Walk a lowered MirNode tree and mark the interpolation node for replacement.
    fn markInterpolationReplacement(self: *MirLowerer, mir_node_ptr: *MirNode, target_ast: *parser.Node, name: []const u8) void {
        if (mir_node_ptr.ast == target_ast and mir_node_ptr.kind == .interpolation) {
            mir_node_ptr.injected_name = name;
            return;
        }
        for (mir_node_ptr.children) |child| {
            self.markInterpolationReplacement(child, target_ast, name);
        }
    }

    fn lowerSlice(self: *MirLowerer, nodes: []*parser.Node) anyerror![]*MirNode {
        var result = try self.allocator.alloc(*MirNode, nodes.len);
        for (nodes, 0..) |node, i| {
            result[i] = try self.lowerNode(node);
        }
        return result;
    }

    /// Extract type narrowing info from an if-condition.
    /// Matches the desugared form: `@type(x) == T` / `@type(x) != T`
    /// (parser desugars `x is T` into `compiler_func("type", [x]) == T`)
    fn extractNarrowing(self: *const MirLowerer, condition: *parser.Node, then_block: *parser.Node) ?IfNarrowing {
        if (condition.* != .binary_expr) return null;
        const b = condition.binary_expr;
        const is_eq = b.op == .eq;
        const is_ne = b.op == .ne;
        if (!is_eq and !is_ne) return null;
        if (b.left.* != .compiler_func) return null;
        if (!std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE)) return null;
        if (b.left.compiler_func.args.len == 0) return null;
        const val_node = b.left.compiler_func.args[0];
        if (val_node.* != .identifier) return null;
        // Check if the variable is a union type via MIR annotation
        const info = self.node_map.get(val_node) orelse
            if (self.var_types.get(val_node.identifier)) |vi| vi else return null;
        const tc = info.type_class;
        if (tc != .arbitrary_union and tc != .error_union and tc != .null_union and tc != .null_error_union)
            return null;
        // Get the type name from RHS
        const type_name: []const u8 = switch (b.right.*) {
            .identifier => |n| n,
            .null_literal => K.Type.NULL,
            else => return null,
        };
        // Compute remaining type for opposite branch
        const members_rt = if (info.resolved_type == .union_type) info.resolved_type.union_type else null;
        const remaining = remainingUnionType(members_rt, type_name);
        const has_early_exit = blockHasEarlyExit(then_block);
        return .{
            .var_name = val_node.identifier,
            .then_type = if (is_eq) type_name else remaining,
            .else_type = if (is_eq) remaining else type_name,
            .post_type = if (has_early_exit) (if (is_eq) remaining else type_name) else null,
            .type_class = tc,
        };
    }

    fn remainingUnionType(members_rt: ?[]const RT, excluded: []const u8) ?[]const u8 {
        const members = members_rt orelse return null;
        var remaining: ?[]const u8 = null;
        for (members) |m| {
            const n = m.name();
            if (std.mem.eql(u8, n, excluded)) continue;
            if (std.mem.eql(u8, n, K.Type.ERROR) or std.mem.eql(u8, n, K.Type.NULL)) continue;
            if (remaining != null) return null;
            remaining = n;
        }
        return remaining;
    }

    const blockHasEarlyExit = parser.blockHasEarlyExit;

    /// Stamp `narrowed_to` on all identifier MirNodes within a subtree that
    /// reference `var_name`. Skips nodes that already have a narrowing set
    /// (inner scopes take precedence).
    fn stampNarrowing(node: *MirNode, var_name: []const u8, narrowed_type: []const u8) void {
        if (node.kind == .identifier and node.narrowed_to == null) {
            if (node.ast.* == .identifier and std.mem.eql(u8, node.ast.identifier, var_name)) {
                node.narrowed_to = narrowed_type;
            }
        }
        for (node.children) |child| {
            stampNarrowing(child, var_name, narrowed_type);
        }
    }
};

/// Populate the self-contained data fields from the AST node.
/// Called once during lowering — these fields never change after.
fn populateData(m: *MirNode, node: *parser.Node) void {
    switch (node.*) {
        .func_decl => |f| {
            m.name = f.name;
            m.is_pub = f.is_pub;
            m.is_compt = (f.context == .compt);
            m.return_type = f.return_type;
        },
        .struct_decl => |s| {
            m.name = s.name;
            m.is_pub = s.is_pub;
            m.type_params = if (s.type_params.len > 0) s.type_params else null;
        },
        .enum_decl => |e| {
            m.name = e.name;
            m.is_pub = e.is_pub;
            m.backing_type = e.backing_type;
        },
        .handle_decl => |h| {
            m.name = h.name;
            m.is_pub = h.is_pub;
        },
        .var_decl => |v| {
            m.name = v.name;
            m.is_pub = v.is_pub;
            m.is_const = v.mutability == .constant;
            m.type_annotation = v.type_annotation;
        },
        .test_decl => |t| {
            m.name = t.description;
        },
        .param => |p| {
            m.name = p.name;
            m.type_annotation = p.type_annotation;
        },
        .field_decl => |f| {
            m.name = f.name;
            m.is_pub = f.is_pub;
            m.type_annotation = f.type_annotation;
        },
        .enum_variant => |v| {
            m.name = v.name;
            // Propagate explicit discriminant value as literal text for codegen
            if (v.value) |val| {
                m.literal = val.int_literal;
                m.literal_kind = .int;
            }
        },
        .identifier => |name| {
            m.name = name;
        },
        .binary_expr => |b| {
            m.op = b.op;
        },
        .unary_expr => |u| {
            m.op = u.op;
        },
        .assignment => |a| {
            m.op = a.op;
        },
        .range_expr => {
            m.op = .range;
        },
        .int_literal => |v| {
            m.literal = v;
            m.literal_kind = .int;
        },
        .float_literal => |v| {
            m.literal = v;
            m.literal_kind = .float;
        },
        .string_literal => |v| {
            m.literal = v;
            m.literal_kind = .string;
        },
        .bool_literal => |v| {
            m.bool_val = v;
            m.literal = if (v) "true" else "false";
            m.literal_kind = .bool_lit;
        },
        .error_literal => |v| {
            m.literal = v;
            m.literal_kind = .error_lit;
        },
        .null_literal => {
            m.literal = "null";
            m.literal_kind = .null_lit;
        },
        .field_expr => |f| {
            m.name = f.field;
        },
        .import_decl => |i| {
            m.name = i.path;
        },
        .for_stmt => |f| {
            m.captures = f.captures;
            m.is_tuple_capture = f.is_tuple_capture;
        },
        .call_expr => |c| {
            m.arg_names = if (c.arg_names.len > 0) c.arg_names else null;
        },
        .version_literal => {},
        .destruct_decl => |d| {
            m.names = d.names;
            m.is_const = d.is_const;
        },
        .interpolated_string => |interp| {
            m.interp_parts = interp.parts;
        },
        .compiler_func => |cf| {
            m.name = cf.name;
        },
        else => {},
    }
}

/// Map AST node kind to MIR node kind.
fn astToMirKind(node: *parser.Node) MirKind {
    return switch (node.*) {
        .func_decl => .func,
        .struct_decl => .struct_def,
        .enum_decl => .enum_def,
        .handle_decl => .handle_def,
        .field_decl => .field_def,
        .param => .param_def,
        .enum_variant => .enum_variant_def,
        .var_decl => .var_decl,
        .test_decl => .test_def,
        .destruct_decl => .destruct,
        .import_decl => .import,
        .block => .block,
        .return_stmt => .return_stmt,
        .if_stmt => .if_stmt,
        .while_stmt => .while_stmt,
        .for_stmt => .for_stmt,
        .defer_stmt => .defer_stmt,
        .match_stmt => .match_stmt,
        .match_arm => .match_arm,
        .assignment => .assignment,
        .break_stmt => .break_stmt,
        .continue_stmt => .continue_stmt,
        .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal, .error_literal => .literal,
        .identifier => .identifier,
        .binary_expr, .range_expr => .binary,
        .unary_expr => .unary,
        .call_expr => .call,
        .field_expr => .field_access,
        .index_expr => .index,
        .slice_expr => .slice,
        .mut_borrow_expr => .borrow,
        .const_borrow_expr => .borrow,
        .interpolated_string => .interpolation,
        .compiler_func => .compiler_fn,
        .array_literal => .array_lit,
        .version_literal => .passthrough,
        .type_slice, .type_array, .type_ptr, .type_union,
        .type_tuple_named, .type_func, .type_generic,
        .type_named, .struct_type,
        => .type_expr,
        else => .passthrough,
    };
}
