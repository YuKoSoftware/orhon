// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 10)
// Typed annotation pass: walks the AST + resolver type_map to produce
// a NodeMap (annotation table keyed by AST node pointer).
// Codegen reads AST + NodeMap instead of re-discovering types.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const types = @import("types.zig");
const K = @import("constants.zig");
const builtins = @import("builtins.zig");

const RT = types.ResolvedType;

// ── Type Classification ─────────────────────────────────────

/// How codegen should treat a variable or expression.
/// Replaces the 7 ad-hoc hashmaps in CodeGen.
pub const TypeClass = enum {
    plain,
    error_union,
    null_union,
    arbitrary_union,
    string,
    raw_ptr,
    safe_ptr,
    thread_handle,
};

/// Classify a resolved type into a codegen category.
pub fn classifyType(t: RT) TypeClass {
    return switch (t) {
        .error_union => .error_union,
        .null_union => .null_union,
        .union_type => .arbitrary_union,
        .primitive => |p| if (p == .string) .string else .plain,
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "RawPtr") or std.mem.eql(u8, g.name, "VolatilePtr"))
                return .raw_ptr;
            if (std.mem.eql(u8, g.name, "Ptr"))
                return .safe_ptr;
            if (std.mem.eql(u8, g.name, "Handle"))
                return .thread_handle;
            return .plain;
        },
        .ptr => .safe_ptr,
        else => .plain,
    };
}

// ── Coercion ────────────────────────────────────────────────

/// An explicit coercion that codegen should emit.
pub const Coercion = enum {
    array_to_slice,
    null_wrap,
    error_wrap,
    arbitrary_union_wrap,
    optional_unwrap,
    value_to_const_ref, // T → &T for const & parameters
};

// ── Node Info ───────────────────────────────────────────────

/// Per-AST-node annotation produced by the MIR annotator.
pub const NodeInfo = struct {
    resolved_type: RT,
    type_class: TypeClass,
    coercion: ?Coercion = null,
    coerce_tag: ?[]const u8 = null,
    narrowed_to: ?[]const u8 = null,
};

/// Annotation table: AST node pointer → NodeInfo.
pub const NodeMap = std.AutoHashMapUnmanaged(*parser.Node, NodeInfo);

// ── Union Registry ──────────────────────────────────────────

/// Canonical union type deduplication.
/// Same structural union across functions shares one Zig type name.
pub const UnionRegistry = struct {
    /// Sorted member names → canonical Zig type name
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        members: []const []const u8,
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) UnionRegistry {
        return .{
            .entries = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionRegistry) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.members);
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
    }

    /// Get or create a canonical name for a union type.
    pub fn canonicalize(self: *UnionRegistry, members: []const []const u8) ![]const u8 {
        const sorted = try self.allocator.alloc([]const u8, members.len);
        @memcpy(sorted, members);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        // Look for existing entry
        for (self.entries.items) |entry| {
            if (entry.members.len == sorted.len) {
                var match = true;
                for (entry.members, sorted) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    self.allocator.free(sorted);
                    return entry.name;
                }
            }
        }

        // Build name: "OrhonUnion_i32_String"
        var buf = std.ArrayListUnmanaged(u8){};
        try buf.appendSlice(self.allocator, "OrhonUnion");
        for (sorted) |m| {
            try buf.append(self.allocator, '_');
            try buf.appendSlice(self.allocator, m);
        }
        const name = try self.allocator.dupe(u8, buf.items);
        buf.deinit(self.allocator);

        try self.entries.append(self.allocator, .{
            .members = sorted,
            .name = name,
        });
        return name;
    }
};

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
            .borrow_expr => |b| {
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
        // Value → const ref (T → const &T)
        if (dst == .ptr) {
            if (std.mem.eql(u8, dst.ptr.kind, "const &")) {
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

// ── MIR Node Tree ──────────────────────────────────────────

/// MIR node — self-contained representation for codegen.
/// All semantic data is on MirNode fields. The `ast` back-pointer is retained
/// only for: source location queries, current_func_node tracking, and
/// type_expr/passthrough nodes where type trees are structural.
pub const MirNode = struct {
    /// Original AST node — used for source locations and type_expr/passthrough only.
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
    /// Bridge declaration flag.
    is_bridge: bool = false,
    /// Thread function flag.
    is_thread: bool = false,
    /// Compile-time declaration flag.
    is_compt: bool = false,
    /// Literal sub-kind (int, float, string, bool, null, error).
    literal_kind: ?LiteralKind = null,
    /// Const declaration flag (true for const_decl, false for var_decl).
    is_const: bool = false,
    /// Type annotation AST node (borrowed pointer — lives as long as AST arena).
    type_annotation: ?*parser.Node = null,
    /// Generic type parameters (for struct/func generics).
    type_params: ?[]*parser.Node = null,
    /// Return type AST node (for func_decl).
    return_type: ?*parser.Node = null,
    /// Backing type AST node (for enum/bitfield).
    backing_type: ?*parser.Node = null,
    /// Default value AST node (for field_decl).
    default_value: ?*parser.Node = null,
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
    var_decl, // var_decl, const_decl, compt_decl
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
    // Struct/enum members
    field_def,
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

// ── MIR Lowerer ────────────────────────────────────────────

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

        var mir_node = try self.allocator.create(MirNode);
        mir_node.* = .{
            .ast = node,
            .resolved_type = resolved,
            .type_class = tc,
            .coercion = coercion_val,
            .coerce_tag = coerce_tag_val,
            .kind = kind,
            .children = &.{},
        };

        // Populate self-contained data fields from AST
        populateData(mir_node, node);

        // Lower children based on AST node kind
        switch (node.*) {
            .program => |p| {
                mir_node.children = try self.lowerSlice(p.top_level);
            },
            .func_decl => |f| {
                // Children: [params..., body]
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (f.params) |param| {
                    try children.append(self.allocator, try self.lowerNode(param));
                }
                try children.append(self.allocator, try self.lowerNode(f.body));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .struct_decl => |s| {
                mir_node.children = try self.lowerSlice(s.members);
            },
            .enum_decl => |e| {
                mir_node.children = try self.lowerSlice(e.members);
            },
            .bitfield_decl => {
                mir_node.children = &.{};
            },
            .block => |b| {
                // Process block statements — hoist interpolation temps
                mir_node.children = try self.lowerBlock(b.statements);
            },
            .var_decl, .const_decl => |v| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(v.value));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .compt_decl => |v| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(v.value));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    var children = std.ArrayListUnmanaged(*MirNode){};
                    try children.append(self.allocator, try self.lowerNode(val));
                    mir_node.children = try children.toOwnedSlice(self.allocator);
                }
            },
            .if_stmt => |i| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(i.condition));
                try children.append(self.allocator, try self.lowerNode(i.then_block));
                if (i.else_block) |e| try children.append(self.allocator, try self.lowerNode(e));
                mir_node.children = try children.toOwnedSlice(self.allocator);
                // Pre-compute type narrowing from `is` checks
                mir_node.narrowing = self.extractNarrowing(i.condition, i.then_block);
                // Stamp narrowed_to on descendant identifier nodes
                if (mir_node.narrowing) |narrowing| {
                    if (narrowing.then_type) |tt| stampNarrowing(mir_node.thenBlock(), narrowing.var_name, tt);
                    if (mir_node.elseBlock()) |else_m| {
                        if (narrowing.else_type) |et| stampNarrowing(else_m, narrowing.var_name, et);
                    }
                }
            },
            .while_stmt => |w| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(w.condition));
                try children.append(self.allocator, try self.lowerNode(w.body));
                if (w.continue_expr) |ce| try children.append(self.allocator, try self.lowerNode(ce));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .for_stmt => |fs| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(fs.iterable));
                try children.append(self.allocator, try self.lowerNode(fs.body));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .defer_stmt => |d| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(d.body));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .match_stmt => |m| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(m.value));
                for (m.arms) |arm| try children.append(self.allocator, try self.lowerNode(arm));
                mir_node.children = try children.toOwnedSlice(self.allocator);
                // Stamp narrowing for arbitrary union match arms
                if (mir_node.value().type_class == .arbitrary_union) {
                    const match_val = mir_node.value();
                    const match_var = if (match_val.kind == .identifier) match_val.name else null;
                    if (match_var) |vname| {
                        for (mir_node.matchArms()) |arm_mir| {
                            const pat_m = arm_mir.pattern();
                            if (pat_m.kind == .identifier and !std.mem.eql(u8, pat_m.name orelse "", "else")) {
                                stampNarrowing(arm_mir.body(), vname, pat_m.name orelse "");
                            }
                        }
                    }
                }
            },
            .match_arm => |m| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(m.pattern));
                if (m.guard) |g| {
                    try children.append(self.allocator, try self.lowerNode(g));
                }
                try children.append(self.allocator, try self.lowerNode(m.body));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .assignment => |a| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(a.left));
                try children.append(self.allocator, try self.lowerNode(a.right));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .binary_expr => |b| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(b.left));
                try children.append(self.allocator, try self.lowerNode(b.right));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .unary_expr => |u| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(u.operand));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .call_expr => |c| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(c.callee));
                for (c.args) |arg| try children.append(self.allocator, try self.lowerNode(arg));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .field_expr => |f| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(f.object));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .index_expr => |i| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(i.object));
                try children.append(self.allocator, try self.lowerNode(i.index));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .slice_expr => |s| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(s.object));
                try children.append(self.allocator, try self.lowerNode(s.low));
                try children.append(self.allocator, try self.lowerNode(s.high));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .borrow_expr => |b| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(b));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .interpolated_string => |interp| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (interp.parts) |part| {
                    switch (part) {
                        .expr => |expr_node| try children.append(self.allocator, try self.lowerNode(expr_node)),
                        .literal => {},
                    }
                }
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .range_expr => |r| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(r.left));
                try children.append(self.allocator, try self.lowerNode(r.right));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .collection_expr => |c| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                for (c.type_args) |arg| try children.append(self.allocator, try self.lowerNode(arg));
                if (c.alloc_arg) |a| try children.append(self.allocator, try self.lowerNode(a));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .compiler_func => |c| {
                mir_node.children = try self.lowerSlice(c.args);
            },
            .array_literal => |a| {
                mir_node.children = try self.lowerSlice(a);
            },
            .tuple_literal => |t| {
                mir_node.children = try self.lowerSlice(t.fields);
            },
            .test_decl => |td| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(td.body));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .destruct_decl => |d| {
                var children = std.ArrayListUnmanaged(*MirNode){};
                try children.append(self.allocator, try self.lowerNode(d.value));
                mir_node.children = try children.toOwnedSlice(self.allocator);
            },
            .import_decl => {
                mir_node.children = &.{};
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
            .throw_stmt,
            .enum_variant,
            .field_decl,
            .param,
            .module_decl,
            .metadata,
            => {},
            // Type nodes — passthrough
            .type_primitive,
            .type_slice,
            .type_array,
            .type_ptr,
            .type_union,
            .type_tuple_named,
            .type_tuple_anon,
            .type_func,
            .type_generic,
            .type_named,
            .struct_type,
            => {},
        }

        return mir_node;
    }

    /// Lower a block's statements, hoisting interpolation temporaries.
    fn lowerBlock(self: *MirLowerer, statements: []*parser.Node) anyerror![]*MirNode {
        var result = std.ArrayListUnmanaged(*MirNode){};

        for (statements) |stmt| {
            // Check if this statement contains an interpolated string that needs hoisting
            if (self.findInterpolation(stmt)) |interp_node| {
                // Hoist: create temp var + defer before the statement
                const name = try std.fmt.allocPrint(self.allocator, "_orhon_interp_{d}", .{self.interp_counter});
                self.interp_counter += 1;

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

                // injected_defer: defer std.heap.page_allocator.free(_orhon_interp_N)
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

                // Mark the interpolation node so codegen emits the temp var name
                const lowered_stmt = try self.lowerNode(stmt);
                self.markInterpolationReplacement(lowered_stmt, interp_node, name);
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

    /// Find the first interpolated_string node in a statement (shallow search).
    fn findInterpolation(self: *const MirLowerer, node: *parser.Node) ?*parser.Node {
        _ = self;
        switch (node.*) {
            .var_decl, .const_decl => |v| return findInterpolationInExpr(v.value),
            .call_expr => |c| {
                for (c.args) |arg| {
                    if (arg.* == .interpolated_string) return arg;
                }
                // Check method call receiver (field_expr callee)
                if (c.callee.* == .field_expr) {
                    const obj = c.callee.field_expr.object;
                    if (obj.* == .interpolated_string) return obj;
                }
                return null;
            },
            .assignment => |a| return findInterpolationInExpr(a.right),
            .return_stmt => |r| {
                if (r.value) |v| return findInterpolationInExpr(v);
                return null;
            },
            else => return null,
        }
    }

    fn findInterpolationInExpr(node: *parser.Node) ?*parser.Node {
        if (node.* == .interpolated_string) return node;
        if (node.* == .call_expr) {
            for (node.call_expr.args) |arg| {
                if (arg.* == .interpolated_string) return arg;
            }
        }
        return null;
    }

    /// Walk a lowered MirNode tree and mark the interpolation node for replacement.
    fn markInterpolationReplacement(self: *MirLowerer, mir_node: *MirNode, target_ast: *parser.Node, name: []const u8) void {
        if (mir_node.ast == target_ast and mir_node.kind == .interpolation) {
            mir_node.injected_name = name;
            return;
        }
        for (mir_node.children) |child| {
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
        const is_eq = std.mem.eql(u8, b.op, "==");
        const is_ne = std.mem.eql(u8, b.op, "!=");
        if (!is_eq and !is_ne) return null;
        if (b.left.* != .compiler_func) return null;
        if (!std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE)) return null;
        if (b.left.compiler_func.args.len == 0) return null;
        const val_node = b.left.compiler_func.args[0];
        if (val_node.* != .identifier) return null;
        // Check if the variable is an arbitrary union via MIR annotation
        const info = self.node_map.get(val_node) orelse
            if (self.var_types.get(val_node.identifier)) |vi| vi else return null;
        if (info.type_class != .arbitrary_union) return null;
        // Get the type name from RHS
        const type_name: []const u8 = switch (b.right.*) {
            .identifier => |n| n,
            .null_literal => K.Type.NULL,
            else => return null,
        };
        // Skip Error/null checks — those are error/null union narrowing, not arb union
        if (std.mem.eql(u8, type_name, K.Type.ERROR) or std.mem.eql(u8, type_name, K.Type.NULL))
            return null;
        // Compute remaining type for opposite branch
        const members_rt = if (info.resolved_type == .union_type) info.resolved_type.union_type else null;
        const remaining = remainingUnionType(members_rt, type_name);
        const has_early_exit = blockHasEarlyExit(then_block);
        return .{
            .var_name = val_node.identifier,
            .then_type = if (is_eq) type_name else remaining,
            .else_type = if (is_eq) remaining else type_name,
            .post_type = if (has_early_exit) (if (is_eq) remaining else type_name) else null,
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

    fn blockHasEarlyExit(node: *parser.Node) bool {
        if (node.* != .block) return false;
        for (node.block.statements) |stmt| {
            switch (stmt.*) {
                .return_stmt, .break_stmt, .continue_stmt => return true,
                else => {},
            }
        }
        return false;
    }

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

/// Map AST node kind to MIR node kind.
/// Populate the self-contained data fields from the AST node.
/// Called once during lowering — these fields never change after.
fn populateData(m: *MirNode, node: *parser.Node) void {
    switch (node.*) {
        .func_decl => |f| {
            m.name = f.name;
            m.is_pub = f.is_pub;
            m.is_bridge = f.is_bridge;
            m.is_thread = f.is_thread;
            m.is_compt = f.is_compt;
            m.return_type = f.return_type;
        },
        .struct_decl => |s| {
            m.name = s.name;
            m.is_pub = s.is_pub;
            m.is_bridge = s.is_bridge;
            m.type_params = if (s.type_params.len > 0) s.type_params else null;
        },
        .enum_decl => |e| {
            m.name = e.name;
            m.is_pub = e.is_pub;
            m.backing_type = e.backing_type;
        },
        .bitfield_decl => |b| {
            m.name = b.name;
            m.is_pub = b.is_pub;
            m.backing_type = b.backing_type;
            m.bit_members = b.members;
        },
        .var_decl => |v| {
            m.name = v.name;
            m.is_pub = v.is_pub;
            m.is_bridge = v.is_bridge;
            m.type_annotation = v.type_annotation;
        },
        .const_decl => |v| {
            m.name = v.name;
            m.is_pub = v.is_pub;
            m.is_bridge = v.is_bridge;
            m.is_const = true;
            m.type_annotation = v.type_annotation;
        },
        .compt_decl => |v| {
            m.name = v.name;
            m.is_pub = v.is_pub;
            m.is_compt = true;
            m.is_const = true;
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
            m.default_value = f.default_value;
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
            m.op = "..";
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
            m.is_compt = f.is_compt;
            m.captures = f.captures;
            m.index_var = f.index_var;
        },
        .call_expr => |c| {
            m.arg_names = if (c.arg_names.len > 0) c.arg_names else null;
        },
        .tuple_literal => |t| {
            m.is_named_tuple = t.is_named;
            m.field_names = if (t.field_names.len > 0) t.field_names else null;
        },
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
        .throw_stmt => |t| {
            m.name = t.variable;
        },
        else => {},
    }
}

fn astToMirKind(node: *parser.Node) MirKind {
    return switch (node.*) {
        .func_decl => .func,
        .struct_decl => .struct_def,
        .enum_decl => .enum_def,
        .bitfield_decl => .bitfield_def,
        .field_decl => .field_def,
        .enum_variant => .enum_variant_def,
        .var_decl, .const_decl, .compt_decl => .var_decl,
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
        .throw_stmt => .throw_stmt,
        .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal, .error_literal => .literal,
        .identifier => .identifier,
        .binary_expr, .range_expr => .binary,
        .unary_expr => .unary,
        .call_expr => .call,
        .field_expr => .field_access,
        .index_expr => .index,
        .slice_expr => .slice,
        .borrow_expr => .borrow,
        .interpolated_string => .interpolation,
        .collection_expr => .collection,
        .compiler_func => .compiler_fn,
        .array_literal => .array_lit,
        .tuple_literal => .tuple_lit,
        .type_primitive, .type_slice, .type_array, .type_ptr, .type_union,
        .type_tuple_named, .type_tuple_anon, .type_func, .type_generic,
        .type_named, .struct_type,
        => .type_expr,
        else => .passthrough,
    };
}

// ── Tests ───────────────────────────────────────────────────

test "classifyType - primitives" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = .i32 }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = .bool }));
    try std.testing.expectEqual(TypeClass.string, classifyType(RT{ .primitive = .string }));
}

test "classifyType - unions" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };
    try std.testing.expectEqual(TypeClass.error_union, classifyType(RT{ .error_union = inner }));
    try std.testing.expectEqual(TypeClass.null_union, classifyType(RT{ .null_union = inner }));
}

test "classifyType - pointers and named" {
    try std.testing.expectEqual(TypeClass.raw_ptr, classifyType(RT{ .generic = .{
        .name = "RawPtr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.safe_ptr, classifyType(RT{ .generic = .{
        .name = "Ptr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .named = "MyStruct" }));
}

test "union registry - canonicalize" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "String" });
    const name2 = try reg.canonicalize(&.{ "String", "i32" });

    // Same structural union → same name
    try std.testing.expectEqualStrings(name1, name2);
    try std.testing.expect(std.mem.indexOf(u8, name1, "OrhonUnion") != null);
    try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);
}

test "union registry - different unions" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const name1 = try reg.canonicalize(&.{ "i32", "String" });
    const name2 = try reg.canonicalize(&.{ "i32", "f32" });

    try std.testing.expect(!std.mem.eql(u8, name1, name2));
    try std.testing.expectEqual(@as(usize, 2), reg.entries.items.len);
}

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
    const dst = RT{ .ptr = .{ .kind = "const &", .elem = elem } };
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
