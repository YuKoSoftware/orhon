// mir_annotator_nodes.zig — AST annotation and coercion detection
// Satellite of mir_annotator.zig — all functions take *MirAnnotator as first parameter.

const std = @import("std");
const mir_annotator = @import("mir_annotator.zig");
const parser = @import("../parser.zig");
const types = @import("../types.zig");
const declarations = @import("../declarations.zig");
const mir_types = @import("mir_types.zig");

const MirAnnotator = mir_annotator.MirAnnotator;
const RT = types.ResolvedType;
const classifyType = mir_types.classifyType;

pub fn annotateNode(self: *MirAnnotator, node: *parser.Node) anyerror!void {
    switch (node.*) {
        .func_decl => |f| {
            // Annotate the function declaration itself
            if (self.decls.funcs.get(f.name)) |sig| {
                try self.recordNode(node, sig.return_type);
            }
            // Annotate parameters
            for (f.params) |param| {
                if (param.* == .param) {
                    const t = try types.resolveTypeNode(self.decls.typeAllocator(), param.param.type_annotation);
                    try self.recordNode(param, t);
                }
            }
            // Track current function for return coercions
            const prev_func = self.current_func_name;
            self.current_func_name = f.name;
            defer self.current_func_name = prev_func;
            // Annotate body
            try annotateNode(self, f.body);
        },

        .struct_decl => |s| {
            try self.recordNode(node, RT{ .named = s.name });
            for (s.members) |member| {
                try annotateNode(self, member);
            }
        },

        .enum_decl => |e| {
            try self.recordNode(node, RT{ .named = e.name });
            for (e.members) |member| {
                try annotateNode(self, member);
            }
        },

        .handle_decl => |h| {
            try self.recordNode(node, RT{ .named = h.name });
        },

        .block => |b| {
            for (b.statements) |stmt| {
                try annotateNode(self, stmt);
            }
        },

        .var_decl => |v| {
            const t = self.lookupType(node) orelse blk: {
                // Fall back: resolve from annotation or value
                if (v.type_annotation) |ta| {
                    break :blk try types.resolveTypeNode(self.decls.typeAllocator(), ta);
                }
                // Infer from function call return type
                if (v.value.* == .call_expr) {
                    if (self.lookupType(v.value)) |ct| break :blk ct;
                    const callee = v.value.call_expr.callee;
                    if (callee.* == .identifier) {
                        if (self.decls.funcs.get(callee.identifier)) |sig| {
                            break :blk sig.return_type;
                        }
                    }
                }
                break :blk RT.unknown;
            };
            const info = mir_types.NodeInfo{ .resolved_type = t };
            try self.recordNode(node, t);
            try self.var_types.put(self.allocator, v.name, info);
            // Canonicalize arb union types (exclude Error/null — handled as anyerror!/? by codegen)
            if (t == .union_type) {
                try registerUnionMembers(self, t.union_type);
            }

            // Annotate the value expression
            try annotateNode(self, v.value);
            // Coercion pass: detect wrapping needed for declarations
            try annotateDeclCoercions(self, v.value, t);
        },

        .return_stmt => |r| {
            if (r.value) |val| {
                try annotateNode(self, val);
                // Coercion pass: detect wrapping needed for return values
                try annotateReturnCoercions(self, val);
            }
        },

        .if_stmt => |i| {
            try annotateNode(self, i.condition);
            try annotateNode(self, i.then_block);
            if (i.else_block) |e| try annotateNode(self, e);
        },

        .while_stmt => |w| {
            try annotateNode(self, w.condition);
            if (w.continue_expr) |ce| try annotateNode(self, ce);
            try annotateNode(self, w.body);
        },

        .for_stmt => |fs| {
            for (fs.iterables) |iter| try annotateNode(self, iter);
            try annotateNode(self, fs.body);
        },

        .defer_stmt => |d| {
            try annotateNode(self, d.body);
        },

        .match_stmt => |m| {
            try annotateNode(self, m.value);
            for (m.arms) |arm| {
                if (arm.* == .match_arm) {
                    try annotateNode(self, arm.match_arm.pattern);
                    if (arm.match_arm.guard) |g| {
                        try annotateNode(self, g);
                    }
                    try annotateNode(self, arm.match_arm.body);
                }
            }
        },

        .assignment => |a| {
            try annotateNode(self, a.left);
            try annotateNode(self, a.right);
            // Coerce RHS when assigning to a null_union or error_union variable
            if (self.lookupType(a.left)) |lhs_type| {
                try annotateDeclCoercions(self, a.right, lhs_type);
            }
        },

        .test_decl => |td| {
            try annotateNode(self, td.body);
        },

        .destruct_decl => |d| {
            try annotateNode(self, d.value);
        },


        // Expressions
        .binary_expr => |b| {
            try annotateExpr(self, node);
            try annotateNode(self, b.left);
            try annotateNode(self, b.right);
        },
        .unary_expr => |u| {
            try annotateExpr(self, node);
            try annotateNode(self, u.operand);
        },
        .call_expr => |c| {
            try annotateExpr(self, node);
            try annotateNode(self, c.callee);
            for (c.args) |arg| try annotateNode(self, arg);
            // Coercion pass: compare arg types with param types
            try annotateCallCoercions(self, c);
        },
        .field_expr => |f| {
            try annotateExpr(self, node);
            try annotateNode(self, f.object);
        },
        .index_expr => |i| {
            try annotateExpr(self, node);
            try annotateNode(self, i.object);
            try annotateNode(self, i.index);
        },
        .slice_expr => |s| {
            try annotateExpr(self, node);
            try annotateNode(self, s.object);
            try annotateNode(self, s.low);
            try annotateNode(self, s.high);
        },
        .array_literal => |elems| {
            try annotateExpr(self, node);
            for (elems) |elem| try annotateNode(self, elem);
        },
        .version_literal => {},
        .compiler_func => |cf| {
            try annotateExpr(self, node);
            for (cf.args) |arg| try annotateNode(self, arg);
        },
        .mut_borrow_expr => |b| {
            try annotateExpr(self, node);
            try annotateNode(self, b);
        },
        .const_borrow_expr => |b| {
            try annotateExpr(self, node);
            try annotateNode(self, b);
        },
        .range_expr => |r| {
            try annotateExpr(self, node);
            try annotateNode(self, r.left);
            try annotateNode(self, r.right);
        },

        .interpolated_string => |interp| {
            try annotateExpr(self, node);
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |expr_node| try annotateNode(self, expr_node),
                    .literal => {},
                }
            }
        },

        // Leaf expressions
        .int_literal,
        .float_literal,
        .string_literal,
        .bool_literal,
        .null_literal,
        .error_literal,
        .identifier,
        => try annotateExpr(self, node),

        .field_decl => |f| {
            if (f.default_value) |dv| try annotateNode(self, dv);
        },

        // Structural/type/metadata nodes don't need type annotation
        else => {},
    }
}

pub fn annotateExpr(self: *MirAnnotator, node: *parser.Node) !void {
    const t = self.lookupType(node) orelse RT.unknown;
    try self.recordNode(node, t);
}

/// Detect coercions in function call arguments.
/// Compares arg types with param types and marks coercion annotations.
pub fn annotateCallCoercions(self: *MirAnnotator, c: parser.CallExpr) !void {
    const sig = self.resolveCallSig(c) orelse return;
    // Instance method calls (field_expr callee) do not pass the receiver as an explicit arg.
    // Bridge method sigs include 'self' as params[0] — skip it when matching call args.
    const param_offset: usize = if (c.callee.* == .field_expr and sig.is_instance) 1 else 0;
    const effective_params = sig.params[param_offset..];
    const param_count = @min(c.args.len, effective_params.len);
    for (c.args[0..param_count], effective_params[0..param_count]) |arg, param| {
        const arg_type = self.lookupType(arg) orelse continue;
        const coercion = MirAnnotator.detectCoercion(arg_type, param.type_);
        switch (coercion) {
            .none => {},
            .simple => |kind| try self.node_map.put(self.allocator, arg, .{
                .resolved_type = arg_type,
                .coercion = kind,
            }),
            .wrap_union => |tag| try self.node_map.put(self.allocator, arg, .{
                .resolved_type = arg_type,
                .coercion = .{ .arbitrary_union_wrap = tag },
            }),
        }
    }
}

/// Detect coercions for variable/const declarations.
/// When the declared type differs from the value type, mark the value node.
pub fn annotateDeclCoercions(self: *MirAnnotator, value: *parser.Node, decl_type: RT) !void {
    const val_type = self.lookupType(value) orelse {
        // null_literal has no type in the type_map — handle directly
        const decl_tc = classifyType(decl_type);
        if (value.* == .null_literal and (decl_tc == .null_union or decl_tc == .null_error_union)) {
            try self.node_map.put(self.allocator, value, .{
                .resolved_type = .null_type,
                .coercion = .null_wrap,
            });
        }
        return;
    };
    const coercion = MirAnnotator.detectCoercion(val_type, decl_type);
    switch (coercion) {
        .none => {},
        .simple => |kind| try self.node_map.put(self.allocator, value, .{
            .resolved_type = val_type,
            .coercion = kind,
        }),
        .wrap_union => |tag| try self.node_map.put(self.allocator, value, .{
            .resolved_type = val_type,
            .coercion = .{ .arbitrary_union_wrap = tag },
        }),
    }
}

/// Register an arbitrary union (filtered for null/Error) in the shared registry.
/// Only the arity is recorded; comptime-memoized generic types in _unions.zig
/// handle structural dedup at the Zig type-system level.
fn registerUnionMembers(self: *MirAnnotator, members: []const RT) !void {
    var arity: usize = 0;
    for (members) |m| {
        const name = m.name();
        if (!std.mem.eql(u8, name, "Error") and !std.mem.eql(u8, name, "null")) {
            arity += 1;
        }
    }
    if (arity < 2) return;
    try self.union_registry.registerArity(self.current_module_name, arity);
}

/// Detect coercions for return statements.
/// When the return value type differs from the function's return type, mark the value node.
pub fn annotateReturnCoercions(self: *MirAnnotator, value: *parser.Node) !void {
    const func_name = self.current_func_name orelse return;
    const sig = self.decls.funcs.get(func_name) orelse return;
    const val_type = self.lookupType(value) orelse return;
    const coercion = MirAnnotator.detectCoercion(val_type, sig.return_type);
    switch (coercion) {
        .none => {},
        .simple => |kind| try self.node_map.put(self.allocator, value, .{
            .resolved_type = val_type,
            .coercion = kind,
        }),
        .wrap_union => |tag| try self.node_map.put(self.allocator, value, .{
            .resolved_type = val_type,
            .coercion = .{ .arbitrary_union_wrap = tag },
        }),
    }
}
