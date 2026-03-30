// mir_annotator.zig — MIR annotation pass

const std = @import("std");
const parser = @import("../parser.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const K = @import("../constants.zig");
const builtins = @import("../builtins.zig");
const mir_types = @import("mir_types.zig");
const mir_registry = @import("mir_registry.zig");

const RT = mir_types.RT;
const TypeClass = mir_types.TypeClass;
const Coercion = mir_types.Coercion;
const NodeInfo = mir_types.NodeInfo;
const NodeMap = mir_types.NodeMap;
const classifyType = mir_types.classifyType;
const UnionRegistry = mir_registry.UnionRegistry;

// ── MIR Annotator ───────────────────────────────────────────

/// The MIR annotator pass. Walks AST + type_map → NodeMap.
pub const MirAnnotator = struct {
    allocator: std.mem.Allocator,
    reporter: *errors.Reporter,
    decls: *declarations.DeclTable,
    type_map: *const std.AutoHashMapUnmanaged(*parser.Node, RT),
    node_map: NodeMap,
    union_registry: UnionRegistry,
    /// Variable name → NodeInfo lookup (fallback when node pointer isn't in type_map).
    var_types: std.StringHashMapUnmanaged(NodeInfo),
    /// Current function name — for looking up return type during annotation.
    current_func_name: ?[]const u8 = null,
    /// All module DeclTables — for cross-module function signature resolution.
    all_decls: ?*const std.StringHashMap(*declarations.DeclTable) = null,
    /// Variable names declared via const_decl (for const auto-borrow detection).
    const_vars: std.StringHashMapUnmanaged(void) = .{},
    /// Function name → set of param indices that need *const T in Zig output.
    /// Populated by annotateCallCoercions when a const non-primitive arg is detected.
    const_ref_params: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(usize, void)) = .{},
    /// Function parameter names in the current function that have been promoted to *const T.
    /// Used to prevent double-borrow when forwarding const-ref params to other functions.
    promoted_params: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *errors.Reporter,
        decls: *declarations.DeclTable,
        type_map: *const std.AutoHashMapUnmanaged(*parser.Node, RT),
    ) MirAnnotator {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .decls = decls,
            .type_map = type_map,
            .node_map = .{},
            .union_registry = UnionRegistry.init(allocator),
            .var_types = .{},
        };
    }

    pub fn deinit(self: *MirAnnotator) void {
        self.node_map.deinit(self.allocator);
        self.union_registry.deinit();
        self.var_types.deinit(self.allocator);
        self.const_vars.deinit(self.allocator);
        var it = self.const_ref_params.valueIterator();
        while (it.next()) |inner| {
            inner.deinit(self.allocator);
        }
        self.const_ref_params.deinit(self.allocator);
        self.promoted_params.deinit(self.allocator);
    }

    /// Annotate the entire program AST.
    pub fn annotate(self: *MirAnnotator, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.annotateNode(node);
        }
    }

    fn annotateNode(self: *MirAnnotator, node: *parser.Node) anyerror!void {
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
                // Populate promoted_params from const_ref_params for this function.
                // This prevents double-borrow when forwarding const-ref params (Pitfall 3).
                self.promoted_params.clearRetainingCapacity();
                if (self.const_ref_params.get(f.name)) |param_indices| {
                    if (self.decls.funcs.get(f.name)) |sig| {
                        var idx_it = param_indices.keyIterator();
                        while (idx_it.next()) |idx| {
                            if (idx.* < sig.params.len) {
                                try self.promoted_params.put(self.allocator, sig.params[idx.*].name, {});
                            }
                        }
                    }
                }
                defer self.promoted_params.clearRetainingCapacity();
                // Annotate body
                try self.annotateNode(f.body);
            },

            .struct_decl => |s| {
                try self.recordNode(node, RT{ .named = s.name });
                for (s.members) |member| {
                    try self.annotateNode(member);
                }
            },

            .enum_decl => |e| {
                try self.recordNode(node, RT{ .named = e.name });
            },

            .bitfield_decl => |b| {
                try self.recordNode(node, RT{ .named = b.name });
            },

            .block => |b| {
                for (b.statements) |stmt| {
                    try self.annotateNode(stmt);
                }
            },

            .var_decl, .const_decl => |v| {
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
                const info = NodeInfo{ .resolved_type = t, .type_class = classifyType(t) };
                try self.recordNode(node, t);
                try self.var_types.put(self.allocator, v.name, info);
                // Track const variables for const auto-borrow at call sites
                if (node.* == .const_decl) {
                    try self.const_vars.put(self.allocator, v.name, {});
                }

                // Canonicalize arb union types
                if (t == .union_type) {
                    var members = try self.allocator.alloc([]const u8, t.union_type.len);
                    defer self.allocator.free(members);
                    for (t.union_type, 0..) |m, i| {
                        members[i] = m.name();
                    }
                    _ = try self.union_registry.canonicalize(members);
                }

                // Annotate the value expression
                try self.annotateNode(v.value);
                // Coercion pass: detect wrapping needed for declarations
                try self.annotateDeclCoercions(v.value, t);
            },

            .compt_decl => |v| {
                const t = self.lookupType(node) orelse RT.unknown;
                try self.recordNode(node, t);
                try self.annotateNode(v.value);
            },

            .return_stmt => |r| {
                if (r.value) |val| {
                    try self.annotateNode(val);
                    // Coercion pass: detect wrapping needed for return values
                    try self.annotateReturnCoercions(val);
                }
            },

            .if_stmt => |i| {
                try self.annotateNode(i.condition);
                try self.annotateNode(i.then_block);
                if (i.else_block) |e| try self.annotateNode(e);
            },

            .while_stmt => |w| {
                try self.annotateNode(w.condition);
                if (w.continue_expr) |ce| try self.annotateNode(ce);
                try self.annotateNode(w.body);
            },

            .for_stmt => |fs| {
                try self.annotateNode(fs.iterable);
                try self.annotateNode(fs.body);
            },

            .defer_stmt => |d| {
                try self.annotateNode(d.body);
            },

            .match_stmt => |m| {
                try self.annotateNode(m.value);
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        try self.annotateNode(arm.match_arm.pattern);
                        if (arm.match_arm.guard) |g| {
                            try self.annotateNode(g);
                        }
                        try self.annotateNode(arm.match_arm.body);
                    }
                }
            },

            .assignment => |a| {
                try self.annotateNode(a.left);
                try self.annotateNode(a.right);
                // Coerce RHS when assigning to a null_union or error_union variable
                if (self.lookupType(a.left)) |lhs_type| {
                    try self.annotateDeclCoercions(a.right, lhs_type);
                }
            },

            .test_decl => |td| {
                try self.annotateNode(td.body);
            },

            .destruct_decl => |d| {
                try self.annotateNode(d.value);
            },


            // Expressions
            .binary_expr => |b| {
                try self.annotateExpr(node);
                try self.annotateNode(b.left);
                try self.annotateNode(b.right);
            },
            .unary_expr => |u| {
                try self.annotateExpr(node);
                try self.annotateNode(u.operand);
            },
            .call_expr => |c| {
                try self.annotateExpr(node);
                try self.annotateNode(c.callee);
                for (c.args) |arg| try self.annotateNode(arg);
                // Coercion pass: compare arg types with param types
                try self.annotateCallCoercions(c);
            },
            .field_expr => |f| {
                try self.annotateExpr(node);
                try self.annotateNode(f.object);
            },
            .index_expr => |i| {
                try self.annotateExpr(node);
                try self.annotateNode(i.object);
                try self.annotateNode(i.index);
            },
            .slice_expr => |s| {
                try self.annotateExpr(node);
                try self.annotateNode(s.object);
                try self.annotateNode(s.low);
                try self.annotateNode(s.high);
            },
            .array_literal => |elems| {
                try self.annotateExpr(node);
                for (elems) |elem| try self.annotateNode(elem);
            },
            .tuple_literal => |t| {
                try self.annotateExpr(node);
                for (t.fields) |f| try self.annotateNode(f);
            },
            .compiler_func => |cf| {
                try self.annotateExpr(node);
                for (cf.args) |arg| try self.annotateNode(arg);
            },
            .mut_borrow_expr => |b| {
                try self.annotateExpr(node);
                try self.annotateNode(b);
            },
            .const_borrow_expr => |b| {
                try self.annotateExpr(node);
                try self.annotateNode(b);
            },
            .collection_expr => |c| {
                try self.annotateExpr(node);
                for (c.type_args) |arg| try self.annotateNode(arg);
                if (c.alloc_arg) |a| try self.annotateNode(a);
            },
            .range_expr => |r| {
                try self.annotateExpr(node);
                try self.annotateNode(r.left);
                try self.annotateNode(r.right);
            },

            .interpolated_string => |interp| {
                try self.annotateExpr(node);
                for (interp.parts) |part| {
                    switch (part) {
                        .expr => |expr_node| try self.annotateNode(expr_node),
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
            => try self.annotateExpr(node),

            else => {},
        }
    }

    fn annotateExpr(self: *MirAnnotator, node: *parser.Node) !void {
        const t = self.lookupType(node) orelse RT.unknown;
        try self.recordNode(node, t);
    }

    /// Detect coercions in function call arguments.
    /// Compares arg types with param types and marks coercion annotations.
    /// Also applies const auto-borrow: const non-primitive args passed to by-value params
    /// get value_to_const_ref coercion and are recorded in const_ref_params.
    /// Const auto-borrow is limited to same-module direct calls (c.callee is an identifier).
    /// Cross-module calls (field_expr callee) are excluded — function signature promotion
    /// must match across module boundaries, which requires cross-module coordination.
    fn annotateCallCoercions(self: *MirAnnotator, c: parser.CallExpr) !void {
        const sig = self.resolveCallSig(c) orelse return;
        // Resolve the callee name for const_ref_params tracking.
        // Only direct calls (identifier callee) qualify for const auto-borrow.
        const is_direct_call = c.callee.* == .identifier;
        const func_name: ?[]const u8 = if (c.callee.* == .identifier)
            c.callee.identifier
        else if (c.callee.* == .field_expr)
            c.callee.field_expr.field
        else
            null;
        // Instance method calls (field_expr callee) do not pass the receiver as an explicit arg.
        // Bridge method sigs include 'self' as params[0] — skip it when matching call args.
        const param_offset: usize = if (c.callee.* == .field_expr and sig.params.len > 0 and
            std.mem.eql(u8, sig.params[0].name, "self")) 1 else 0;
        const effective_params = sig.params[param_offset..];
        const param_count = @min(c.args.len, effective_params.len);
        var idx: usize = 0;
        for (c.args[0..param_count], effective_params[0..param_count]) |arg, param| {
            defer idx += 1;
            const arg_type = self.lookupType(arg) orelse continue;
            const coercion = detectCoercion(arg_type, param.type_);
            if (coercion.kind) |kind| {
                try self.node_map.put(self.allocator, arg, .{
                    .resolved_type = arg_type,
                    .type_class = classifyType(arg_type),
                    .coercion = kind,
                    .coerce_tag = coercion.tag,
                });
            } else {
                // Const auto-borrow: annotate const non-primitive args with value_to_const_ref.
                // Only applies to same-module direct calls (Pitfall 5: cross-module skipped).
                // Bridge functions are excluded — the sidecar .zig defines param types, so the
                // Orhon compiler must not promote their parameters; the const & case is handled
                // by detectCoercion above when the declared param type is already `const &`.
                // This guard covers all bridge call forms: direct calls (processTexture(tex)),
                // struct method calls (ren.createMaterial(tex)), and error-union-returning bridge
                // functions — all excluded via !sig.is_bridge regardless of return type.
                if (is_direct_call and arg.* == .identifier and !sig.is_bridge) {
                    const name = arg.identifier;
                    // Skip promoted params (already *const T — prevents double-borrow)
                    if (!self.promoted_params.contains(name) and self.const_vars.contains(name)) {
                        // Only non-primitive, non-value-type args qualify.
                        // Enums and bitfields are small value types — exclude them.
                        const is_enum_or_bitfield = if (arg_type == .named) blk: {
                            const n = arg_type.named;
                            break :blk self.decls.enums.contains(n) or self.decls.bitfields.contains(n);
                        } else false;
                        if (isNonPrimitiveType(arg_type) and !is_enum_or_bitfield) {
                            try self.node_map.put(self.allocator, arg, .{
                                .resolved_type = arg_type,
                                .type_class = classifyType(arg_type),
                                .coercion = .value_to_const_ref,
                            });
                            // Record (func_name, param_index) for Zig signature promotion
                            if (func_name) |fname| {
                                try self.recordConstRefParam(fname, idx);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Returns true if the type requires a reference rather than a value copy.
    /// Primitives (i32, f32, bool, String, etc.) and value types (Vector) are excluded.
    fn isNonPrimitiveType(t: RT) bool {
        return switch (t) {
            .primitive => false,
            .generic => |g| !builtins.isValueType(g.name),
            .unknown, .inferred => false,
            else => true,
        };
    }

    /// Record that a function parameter at the given index needs *const T in Zig output.
    fn recordConstRefParam(self: *MirAnnotator, func_name: []const u8, param_idx: usize) !void {
        const gop = try self.const_ref_params.getOrPut(self.allocator, func_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.put(self.allocator, param_idx, {});
    }

    /// Check if a function parameter should be emitted as *const T.
    pub fn isConstRefParam(self: *const MirAnnotator, func_name: []const u8, param_idx: usize) bool {
        const param_set = self.const_ref_params.get(func_name) orelse return false;
        return param_set.contains(param_idx);
    }

    /// Detect coercions for variable/const declarations.
    /// When the declared type differs from the value type, mark the value node.
    fn annotateDeclCoercions(self: *MirAnnotator, value: *parser.Node, decl_type: RT) !void {
        const val_type = self.lookupType(value) orelse {
            // null_literal has no type in the type_map — handle directly
            if (value.* == .null_literal and classifyType(decl_type) == .null_union) {
                try self.node_map.put(self.allocator, value, .{
                    .resolved_type = .null_type,
                    .type_class = .plain,
                    .coercion = .null_wrap,
                });
            }
            return;
        };
        const coercion = detectCoercion(val_type, decl_type);
        if (coercion.kind) |kind| {
            try self.node_map.put(self.allocator, value, .{
                .resolved_type = val_type,
                .type_class = classifyType(val_type),
                .coercion = kind,
                .coerce_tag = coercion.tag,
            });
        }
    }

    /// Detect coercions for return statements.
    /// When the return value type differs from the function's return type, mark the value node.
    fn annotateReturnCoercions(self: *MirAnnotator, value: *parser.Node) !void {
        const func_name = self.current_func_name orelse return;
        const sig = self.decls.funcs.get(func_name) orelse return;
        const val_type = self.lookupType(value) orelse return;
        const coercion = detectCoercion(val_type, sig.return_type);
        if (coercion.kind) |kind| {
            try self.node_map.put(self.allocator, value, .{
                .resolved_type = val_type,
                .type_class = classifyType(val_type),
                .coercion = kind,
                .coerce_tag = coercion.tag,
            });
        }
    }

    /// Core coercion detection: given a source type and a target type,
    /// determine if a coercion is needed and which kind.
    fn detectCoercion(src: RT, dst: RT) CoercionResult {
        // Can't determine coercion without concrete types
        if (src == .unknown or src == .inferred or dst == .unknown or dst == .inferred)
            return .{ .kind = null };
        // Array → slice
        if (src == .array and dst == .slice)
            return .{ .kind = .array_to_slice };
        // Plain → null union
        if (dst == .null_union and src != .null_union and src != .null_type)
            return .{ .kind = .null_wrap };
        // Plain → error union
        if (dst == .error_union and src != .error_union and src != .err)
            return .{ .kind = .error_wrap };
        // Plain → arbitrary union
        if (dst == .union_type and src != .union_type) {
            // null literal into a union that has null as a member:
            // typeToZig emits ?(union(enum) {...}) for such unions, so Zig handles
            // null coercion natively — no wrapping needed.
            if (src == .null_type) {
                for (dst.union_type) |member| {
                    if (member == .null_type) return .{ .kind = null };
                }
            }
            // For numeric/float literals, find the matching member type in the union
            if (src == .primitive and src.primitive == .numeric_literal) {
                for (dst.union_type) |member| {
                    if (member == .primitive and member.primitive.isInteger()) {
                        return .{ .kind = .arbitrary_union_wrap, .tag = member.name() };
                    }
                }
            } else if (src == .primitive and src.primitive == .float_literal) {
                for (dst.union_type) |member| {
                    if (member == .primitive and member.primitive.isFloat()) {
                        return .{ .kind = .arbitrary_union_wrap, .tag = member.name() };
                    }
                }
            }
            return .{ .kind = .arbitrary_union_wrap, .tag = src.name() };
        }
        // Null union → plain (optional unwrap)
        if (src == .null_union and dst != .null_union)
            return .{ .kind = .optional_unwrap };
        // Value → const ref (T → const& T)
        if (dst == .ptr) {
            if (std.mem.eql(u8, dst.ptr.kind, "const&")) {
                if (typesMatch(src, dst.ptr.elem.*)) {
                    return .{ .kind = .value_to_const_ref };
                }
            }
        }
        return .{ .kind = null };
    }

    /// Check if two resolved types are structurally equivalent for coercion purposes.
    fn typesMatch(a: RT, b: RT) bool {
        if (a == .primitive and b == .primitive) return a.primitive == b.primitive;
        if (a == .named and b == .named) return std.mem.eql(u8, a.named, b.named);
        if (a == .generic and b == .generic) return std.mem.eql(u8, a.generic.name, b.generic.name);
        return false;
    }

    const CoercionResult = struct {
        kind: ?Coercion = null,
        tag: ?[]const u8 = null,
    };

    /// Look up a FuncSig for a call expression's callee.
    fn resolveCallSig(self: *const MirAnnotator, c: parser.CallExpr) ?declarations.FuncSig {
        // Direct call: func_name(args)
        if (c.callee.* == .identifier) {
            return self.decls.funcs.get(c.callee.identifier);
        }
        // Module call: module.func_name(args) or module.Type.method(args)
        if (c.callee.* == .field_expr) {
            // First try current module's decls by function name
            const local = self.decls.funcs.get(c.callee.field_expr.field);
            if (local != null) return local;
            // Cross-module: module.func_name — object is a plain identifier (module name)
            if (c.callee.field_expr.object.* == .identifier) {
                if (self.all_decls) |ad| {
                    if (ad.get(c.callee.field_expr.object.identifier)) |mod_decls| {
                        return mod_decls.funcs.get(c.callee.field_expr.field);
                    }
                }
            }
            // Cross-module: module.Type.method — object is itself a field_expr
            if (c.callee.field_expr.object.* == .field_expr) {
                const inner = c.callee.field_expr.object.field_expr;
                if (inner.object.* == .identifier) {
                    if (self.all_decls) |ad| {
                        if (ad.get(inner.object.identifier)) |mod_decls| {
                            return mod_decls.funcs.get(c.callee.field_expr.field);
                        }
                    }
                }
            }
            // Instance method: obj.method(args) — resolve obj's type to find the declaring module.
            // The object is a variable; look up its resolved type then search the module that owns
            // the struct definition for the method signature.
            const method_name = c.callee.field_expr.field;
            if (self.lookupType(c.callee.field_expr.object)) |obj_type| {
                if (obj_type == .named) {
                    const struct_name = obj_type.named;
                    // Check current module's struct_methods first ("StructName.method" key).
                    // This covers bridge struct methods which are not in funcs to avoid name collisions.
                    const qualified_key = std.fmt.allocPrint(
                        self.allocator, "{s}.{s}", .{ struct_name, method_name },
                    ) catch return null;
                    defer self.allocator.free(qualified_key);
                    if (self.decls.struct_methods.get(qualified_key)) |sig| return sig;
                    if (self.all_decls) |ad| {
                        // Also check all modules' struct_methods for cross-module bridge calls.
                        var it = ad.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.*.struct_methods.get(qualified_key)) |sig| return sig;
                        }
                        // Fallback: funcs lookup by method name (non-bridge methods).
                        var it2 = ad.iterator();
                        while (it2.next()) |entry| {
                            if (entry.value_ptr.*.structs.contains(struct_name)) {
                                return entry.value_ptr.*.funcs.get(method_name);
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    fn lookupType(self: *const MirAnnotator, node: *parser.Node) ?RT {
        return self.type_map.get(node);
    }

    fn recordNode(self: *MirAnnotator, node: *parser.Node, t: RT) !void {
        try self.node_map.put(self.allocator, node, .{
            .resolved_type = t,
            .type_class = classifyType(t),
        });
    }
};

// ── Tests ───────────────────────────────────────────────────

test "mir annotator - basic" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var type_map: std.AutoHashMapUnmanaged(*parser.Node, RT) = .{};
    defer type_map.deinit(alloc);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    var annotator = MirAnnotator.init(alloc, &reporter, &decl_table, &type_map);
    defer annotator.deinit();

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), annotator.node_map.count());
    try std.testing.expectEqual(@as(usize, 0), annotator.var_types.count());
}

test "var_types - populated from var_decl" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var type_map: std.AutoHashMapUnmanaged(*parser.Node, RT) = .{};
    defer type_map.deinit(alloc);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    var annotator = MirAnnotator.init(alloc, &reporter, &decl_table, &type_map);
    defer annotator.deinit();

    // Manually insert a var_types entry to verify the registry works
    const info = NodeInfo{ .resolved_type = RT{ .primitive = .i32 }, .type_class = .plain };
    try annotator.var_types.put(alloc, "x", info);
    try std.testing.expectEqual(@as(usize, 1), annotator.var_types.count());

    const got = annotator.var_types.get("x").?;
    try std.testing.expectEqual(TypeClass.plain, got.type_class);
    try std.testing.expectEqualStrings("i32", got.resolved_type.name());
}

test "detectCoercion - null_wrap" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // Plain → null union → null_wrap
    const r1 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, RT{ .null_union = inner });
    try std.testing.expectEqual(Coercion.null_wrap, r1.kind.?);

    // null_union → null_union → no coercion
    const r2 = MirAnnotator.detectCoercion(RT{ .null_union = inner }, RT{ .null_union = inner });
    try std.testing.expect(r2.kind == null);

    // null_type → null_union → no coercion (null literal handled separately)
    const r3 = MirAnnotator.detectCoercion(RT.null_type, RT{ .null_union = inner });
    try std.testing.expect(r3.kind == null);
}

test "detectCoercion - error_wrap" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // Plain → error union → error_wrap
    const r1 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, RT{ .error_union = inner });
    try std.testing.expectEqual(Coercion.error_wrap, r1.kind.?);

    // error_union → error_union → no coercion
    const r2 = MirAnnotator.detectCoercion(RT{ .error_union = inner }, RT{ .error_union = inner });
    try std.testing.expect(r2.kind == null);

    // err → error_union → no coercion (error literal handled separately)
    const r3 = MirAnnotator.detectCoercion(RT.err, RT{ .error_union = inner });
    try std.testing.expect(r3.kind == null);
}

test "detectCoercion - arbitrary_union_wrap" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // Plain → union_type → arbitrary_union_wrap with tag
    const members = &[_]RT{ RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    const r1 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, RT{ .union_type = members });
    try std.testing.expectEqual(Coercion.arbitrary_union_wrap, r1.kind.?);
    try std.testing.expectEqualStrings("i32", r1.tag.?);

    // union_type → union_type → no coercion
    const r2 = MirAnnotator.detectCoercion(RT{ .union_type = members }, RT{ .union_type = members });
    try std.testing.expect(r2.kind == null);
}

test "detectCoercion - optional_unwrap" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // null_union → plain → optional_unwrap
    const r1 = MirAnnotator.detectCoercion(RT{ .null_union = inner }, RT{ .primitive = .i32 });
    try std.testing.expectEqual(Coercion.optional_unwrap, r1.kind.?);
}

test "detectCoercion - unknown types" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // Unknown source → no coercion
    const r1 = MirAnnotator.detectCoercion(RT.unknown, RT{ .null_union = inner });
    try std.testing.expect(r1.kind == null);

    // Unknown destination → no coercion
    const r2 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, RT.unknown);
    try std.testing.expect(r2.kind == null);

    // Same type → no coercion
    const r3 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, RT{ .primitive = .i32 });
    try std.testing.expect(r3.kind == null);
}

test "detectCoercion - value to const ref" {
    const alloc = std.testing.allocator;
    const elem = try alloc.create(RT);
    defer alloc.destroy(elem);
    elem.* = RT{ .named = "Vec2" };

    // named("Vec2") → const &Vec2 → value_to_const_ref
    const dst = RT{ .ptr = .{ .kind = "const&", .elem = elem } };
    const r1 = MirAnnotator.detectCoercion(RT{ .named = "Vec2" }, dst);
    try std.testing.expectEqual(Coercion.value_to_const_ref, r1.kind.?);

    // named("Vec2") → named("Vec2") → no coercion
    const r2 = MirAnnotator.detectCoercion(RT{ .named = "Vec2" }, RT{ .named = "Vec2" });
    try std.testing.expect(r2.kind == null);
}

test "resolveCallSig - cross-module lookup" {
    const alloc = std.testing.allocator;
    var local_decls = declarations.DeclTable.init(alloc);
    defer local_decls.deinit();
    var math_decls = declarations.DeclTable.init(alloc);
    defer math_decls.deinit();

    // Add a function to the math module
    const params = try alloc.alloc(declarations.ParamSig, 0);
    defer alloc.free(params);
    const param_nodes = try alloc.alloc(*parser.Node, 0);
    defer alloc.free(param_nodes);
    const ret_node = try alloc.create(parser.Node);
    defer alloc.destroy(ret_node);
    ret_node.* = .{ .type_named = "f32" };
    try math_decls.funcs.put("length", .{
        .name = "length",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .f32 },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = true,
        .is_thread = false,
    });

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    try all_decls.put("math", &math_decls);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &local_decls, &type_map);
    defer annotator.deinit();
    annotator.all_decls = &all_decls;

    // Build a field_expr callee: math.length
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const mod_ident = try a.create(parser.Node);
    mod_ident.* = .{ .identifier = "math" };
    const callee = try a.create(parser.Node);
    callee.* = .{ .field_expr = .{ .object = mod_ident, .field = "length" } };
    const call_args = try a.alloc(*parser.Node, 0);
    const call_arg_names = try a.alloc([]const u8, 0);
    const call: parser.CallExpr = .{ .callee = callee, .args = call_args, .arg_names = call_arg_names };

    const sig = annotator.resolveCallSig(call);
    try std.testing.expect(sig != null);
    try std.testing.expectEqualStrings("length", sig.?.name);
}

test "const auto-borrow - const_vars tracking" {
    // Verify that const_vars contains the name after annotating a const_decl,
    // but NOT the name after annotating a var_decl.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // const c: Vec2 = ...
    const val_node = try a.create(parser.Node);
    val_node.* = .{ .identifier = "someVal" };
    const const_node = try a.create(parser.Node);
    const_node.* = .{ .const_decl = .{ .name = "c", .type_annotation = null, .value = val_node, .is_pub = false } };
    try type_map.put(alloc, const_node, RT{ .named = "Vec2" });
    try type_map.put(alloc, val_node, RT{ .named = "Vec2" });

    // var v: Vec2 = ...
    const val_node2 = try a.create(parser.Node);
    val_node2.* = .{ .identifier = "someOtherVal" };
    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{ .name = "v", .type_annotation = null, .value = val_node2, .is_pub = false } };
    try type_map.put(alloc, var_node, RT{ .named = "Vec2" });
    try type_map.put(alloc, val_node2, RT{ .named = "Vec2" });

    try annotator.annotateNode(const_node);
    try annotator.annotateNode(var_node);

    // const_vars should contain "c" but not "v"
    try std.testing.expect(annotator.const_vars.contains("c"));
    try std.testing.expect(!annotator.const_vars.contains("v"));
}

test "const auto-borrow - annotateCallCoercions applies value_to_const_ref" {
    // When a const non-primitive arg is passed to a by-value param, it should get
    // value_to_const_ref coercion and the (func_name, param_index) should be recorded.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register the function: func process(cfg: Config) void
    // Note: params (ParamSig slice) is owned by decls — freed by decls.deinit()
    // param_nodes is NOT freed by decls.deinit() — must free separately
    const params = try alloc.alloc(declarations.ParamSig, 1);
    const param_nodes = try alloc.alloc(*parser.Node, 1);
    defer alloc.free(param_nodes);
    const param_type_node = try a.create(parser.Node);
    param_type_node.* = .{ .type_named = "Config" };
    param_nodes[0] = param_type_node;
    params[0] = .{ .name = "cfg", .type_ = RT{ .named = "Config" } };
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "void" };
    try decls.funcs.put("process", .{
        .name = "process",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
        .is_thread = false,
    });

    // Mark "cfg_val" as a const var
    try annotator.const_vars.put(alloc, "cfg_val", {});

    // Build call: process(cfg_val)
    const arg_node = try a.create(parser.Node);
    arg_node.* = .{ .identifier = "cfg_val" };
    try type_map.put(alloc, arg_node, RT{ .named = "Config" });

    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .identifier = "process" };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = arg_node;
    const call_arg_names = try a.alloc([]const u8, 1);
    call_arg_names[0] = "";

    const call_expr = parser.CallExpr{
        .callee = callee_node,
        .args = call_args,
        .arg_names = call_arg_names,
    };

    try annotator.annotateCallCoercions(call_expr);

    // The arg node should have value_to_const_ref coercion
    const info = annotator.node_map.get(arg_node);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(Coercion.value_to_const_ref, info.?.coercion.?);

    // const_ref_params should record ("process", 0)
    try std.testing.expect(annotator.isConstRefParam("process", 0));
}

test "const auto-borrow - primitives excluded" {
    // A const i32 arg should NOT get value_to_const_ref coercion.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register func add(x: i32) i32
    // Note: params (ParamSig slice) is owned by decls — freed by decls.deinit()
    // param_nodes is NOT freed by decls.deinit() — must free separately
    const params = try alloc.alloc(declarations.ParamSig, 1);
    const param_nodes = try alloc.alloc(*parser.Node, 1);
    defer alloc.free(param_nodes);
    const param_type_node = try a.create(parser.Node);
    param_type_node.* = .{ .type_named = "i32" };
    param_nodes[0] = param_type_node;
    params[0] = .{ .name = "x", .type_ = RT{ .primitive = .i32 } };
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "i32" };
    try decls.funcs.put("add", .{
        .name = "add",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .i32 },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
        .is_thread = false,
    });

    // Mark "n" as a const var (i32)
    try annotator.const_vars.put(alloc, "n", {});

    // Build call: add(n)
    const arg_node = try a.create(parser.Node);
    arg_node.* = .{ .identifier = "n" };
    try type_map.put(alloc, arg_node, RT{ .primitive = .i32 });

    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .identifier = "add" };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = arg_node;
    const call_arg_names = try a.alloc([]const u8, 1);
    call_arg_names[0] = "";

    const call_expr = parser.CallExpr{
        .callee = callee_node,
        .args = call_args,
        .arg_names = call_arg_names,
    };

    try annotator.annotateCallCoercions(call_expr);

    // No coercion should be applied (primitive type)
    const info = annotator.node_map.get(arg_node);
    if (info) |i| {
        try std.testing.expect(i.coercion == null or i.coercion.? != .value_to_const_ref);
    }
    // const_ref_params should NOT have "add"
    try std.testing.expect(!annotator.isConstRefParam("add", 0));
}

test "const auto-borrow - const_ref_params populated" {
    // Verify (func_name, param_index) is recorded when a const struct arg is passed by value.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register func render(scene: Scene) void
    // Note: params (ParamSig slice) is owned by decls — freed by decls.deinit()
    // param_nodes is NOT freed by decls.deinit() — must free separately
    const params = try alloc.alloc(declarations.ParamSig, 1);
    const param_nodes = try alloc.alloc(*parser.Node, 1);
    defer alloc.free(param_nodes);
    const param_type_node = try a.create(parser.Node);
    param_type_node.* = .{ .type_named = "Scene" };
    param_nodes[0] = param_type_node;
    params[0] = .{ .name = "scene", .type_ = RT{ .named = "Scene" } };
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "void" };
    try decls.funcs.put("render", .{
        .name = "render",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
        .is_thread = false,
    });

    // Mark "s" as const
    try annotator.const_vars.put(alloc, "s", {});

    // Build call: render(s)
    const arg_node = try a.create(parser.Node);
    arg_node.* = .{ .identifier = "s" };
    try type_map.put(alloc, arg_node, RT{ .named = "Scene" });

    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .identifier = "render" };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = arg_node;
    const call_arg_names = try a.alloc([]const u8, 1);
    call_arg_names[0] = "";

    const call_expr = parser.CallExpr{
        .callee = callee_node,
        .args = call_args,
        .arg_names = call_arg_names,
    };

    try annotator.annotateCallCoercions(call_expr);

    // ("render", 0) should be in const_ref_params
    try std.testing.expect(annotator.isConstRefParam("render", 0));
    // ("render", 1) should NOT be in const_ref_params
    try std.testing.expect(!annotator.isConstRefParam("render", 1));
}

test "const auto-borrow - bridge struct method with error-union return skips promotion" {
    // Verify that a bridge struct method call with (Error | T) return type and a struct
    // value param does NOT get const auto-borrow promotion. Covers the Tamga scenario:
    //   const tex = ...                          // const Texture local
    //   const mat = ren.createMaterial(..., tex) // bridge method, (Error | Material) return
    // The bridge sidecar owns the param type — promoting tex to *const Texture here
    // would cause a type mismatch with a by-value sidecar parameter.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register bridge struct method: Renderer.createMaterial(self: &Renderer, texture: Texture) (Error | Material)
    // params is owned by decls (freed by struct_methods deinit), param_nodes freed separately.
    const params = try alloc.alloc(declarations.ParamSig, 2);
    const param_nodes = try alloc.alloc(*parser.Node, 2);
    defer alloc.free(param_nodes);
    const self_type_node = try a.create(parser.Node);
    self_type_node.* = .{ .type_named = "Renderer" };
    const tex_type_node = try a.create(parser.Node);
    tex_type_node.* = .{ .type_named = "Texture" };
    param_nodes[0] = self_type_node;
    param_nodes[1] = tex_type_node;
    params[0] = .{ .name = "self", .type_ = RT{ .named = "Renderer" } };
    params[1] = .{ .name = "texture", .type_ = RT{ .named = "Texture" } };

    // Return type: (Error | Material)
    const ret_inner = try decls.typeAllocator().create(RT);
    ret_inner.* = RT{ .named = "Material" };
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "Material" };

    const key = try alloc.dupe(u8, "Renderer.createMaterial");
    try decls.struct_methods.put(alloc, key, .{
        .name = "createMaterial",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .error_union = ret_inner },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = true,
        .is_thread = false,
        .is_bridge = true, // bridge method — sidecar owns param types
    });

    // Mark "tex" as a const var of type Texture
    try annotator.const_vars.put(alloc, "tex", {});

    // Build call: ren.createMaterial(tex) — field_expr callee, one explicit arg
    const ren_node = try a.create(parser.Node);
    ren_node.* = .{ .identifier = "ren" };
    try type_map.put(alloc, ren_node, RT{ .named = "Renderer" });

    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .field_expr = .{ .object = ren_node, .field = "createMaterial" } };

    const tex_arg = try a.create(parser.Node);
    tex_arg.* = .{ .identifier = "tex" };
    try type_map.put(alloc, tex_arg, RT{ .named = "Texture" });

    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = tex_arg;
    const call_arg_names = try a.alloc([]const u8, 1);
    call_arg_names[0] = "";

    const call_expr = parser.CallExpr{
        .callee = callee_node,
        .args = call_args,
        .arg_names = call_arg_names,
    };

    try annotator.annotateCallCoercions(call_expr);

    // The tex arg must NOT have value_to_const_ref coercion — bridge owns its param types.
    const info = annotator.node_map.get(tex_arg);
    if (info) |i| {
        if (i.coercion) |c_kind| {
            try std.testing.expect(c_kind != .value_to_const_ref);
        }
    }
    // const_ref_params must NOT record "createMaterial" — bridge method calls are excluded.
    try std.testing.expect(!annotator.isConstRefParam("createMaterial", 0));
}

test "const auto-borrow - direct bridge function call skips promotion" {
    // Verify that a DIRECT call to a bridge function (not a method) does NOT get const
    // auto-borrow promotion, even with error-union return type and a struct value param.
    // The !sig.is_bridge guard at the call coercion site covers this case.
    const alloc = std.testing.allocator;
    var decls = declarations.DeclTable.init(alloc);
    defer decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var annotator = MirAnnotator.init(alloc, &reporter, &decls, &type_map);
    defer annotator.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register bridge function: processTexture(tex: Texture) (Error | Material)
    // is_bridge = true — the sidecar defines param types; Orhon must not promote.
    const params = try alloc.alloc(declarations.ParamSig, 1);
    const param_nodes = try alloc.alloc(*parser.Node, 1);
    defer alloc.free(param_nodes);
    const param_type_node = try a.create(parser.Node);
    param_type_node.* = .{ .type_named = "Texture" };
    param_nodes[0] = param_type_node;
    params[0] = .{ .name = "tex", .type_ = RT{ .named = "Texture" } };

    // Return type: (Error | Material)
    const ret_inner = try decls.typeAllocator().create(RT);
    ret_inner.* = RT{ .named = "Material" };
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "Material" };

    try decls.funcs.put("processTexture", .{
        .name = "processTexture",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .error_union = ret_inner },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = true,
        .is_thread = false,
        .is_bridge = true, // bridge function — sidecar owns param types
    });

    // Mark "myTex" as a const var of type Texture
    try annotator.const_vars.put(alloc, "myTex", {});

    // Build direct call: processTexture(myTex)
    const arg_node = try a.create(parser.Node);
    arg_node.* = .{ .identifier = "myTex" };
    try type_map.put(alloc, arg_node, RT{ .named = "Texture" });

    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .identifier = "processTexture" };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = arg_node;
    const call_arg_names = try a.alloc([]const u8, 1);
    call_arg_names[0] = "";

    const call_expr = parser.CallExpr{
        .callee = callee_node,
        .args = call_args,
        .arg_names = call_arg_names,
    };

    try annotator.annotateCallCoercions(call_expr);

    // The arg must NOT have value_to_const_ref coercion — bridge guard prevents promotion.
    const info = annotator.node_map.get(arg_node);
    if (info) |i| {
        if (i.coercion) |c_kind| {
            try std.testing.expect(c_kind != .value_to_const_ref);
        }
    }
    // const_ref_params must NOT record "processTexture" for any index.
    try std.testing.expect(!annotator.isConstRefParam("processTexture", 0));
}
