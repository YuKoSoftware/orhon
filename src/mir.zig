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

const RT = types.ResolvedType;

// ── Type Classification ─────────────────────────────────────

/// How codegen should treat a variable or expression.
/// Replaces the 7 ad-hoc hashmaps in CodeGen.
pub const TypeClass = enum {
    plain,
    error_union,
    null_union,
    arb_union,
    string,
    raw_ptr,
    safe_ptr,
};

/// Classify a resolved type into a codegen category.
pub fn classifyType(t: RT) TypeClass {
    return switch (t) {
        .error_union => .error_union,
        .null_union => .null_union,
        .union_type => .arb_union,
        .primitive => |n| if (std.mem.eql(u8, n, K.Type.STRING)) .string else .plain,
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "RawPtr") or std.mem.eql(u8, g.name, "VolatilePtr"))
                return .raw_ptr;
            if (std.mem.eql(u8, g.name, "Ptr"))
                return .safe_ptr;
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
    arb_union_wrap,
    optional_unwrap,
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
            },

            .compt_decl => |v| {
                const t = self.lookupType(node) orelse RT.unknown;
                try self.recordNode(node, t);
                try self.annotateNode(v.value);
            },

            .return_stmt => |r| {
                if (r.value) |val| {
                    try self.annotateNode(val);
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
                        try self.annotateNode(arm.match_arm.body);
                    }
                }
            },

            .assignment => |a| {
                try self.annotateNode(a.left);
                try self.annotateNode(a.right);
            },

            .test_decl => |td| {
                try self.annotateNode(td.body);
            },

            .destruct_decl => |d| {
                try self.annotateNode(d.value);
            },

            .thread_block, .async_block => {},

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
            .ptr_expr => |p| {
                try self.annotateExpr(node);
                try self.annotateNode(p.type_arg);
                try self.annotateNode(p.addr_arg);
            },
            .coll_expr => |c| {
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

test "classifyType - primitives" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = "i32" }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .primitive = "bool" }));
    try std.testing.expectEqual(TypeClass.string, classifyType(RT{ .primitive = K.Type.STRING }));
}

test "classifyType - unions" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = "i32" };
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
    const info = NodeInfo{ .resolved_type = RT{ .primitive = "i32" }, .type_class = .plain };
    try annotator.var_types.put(alloc, "x", info);
    try std.testing.expectEqual(@as(usize, 1), annotator.var_types.count());

    const got = annotator.var_types.get("x").?;
    try std.testing.expectEqual(TypeClass.plain, got.type_class);
    try std.testing.expectEqualStrings("i32", got.resolved_type.name());
}
