// mir_annotator.zig — MIR annotation pass

const std = @import("std");
const parser = @import("../parser.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const types = @import("../types.zig");
const K = @import("../constants.zig");
const mir_types = @import("mir_types.zig");
const mir_registry = @import("mir_registry.zig");
const nodes_impl = @import("mir_annotator_nodes.zig");

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
    union_registry: *UnionRegistry,
    /// Variable name → NodeInfo lookup (fallback when node pointer isn't in type_map).
    var_types: std.StringHashMapUnmanaged(NodeInfo),
    /// Current function name — for looking up return type during annotation.
    current_func_name: ?[]const u8 = null,
    /// All module DeclTables — for cross-module function signature resolution.
    all_decls: ?*const std.StringHashMap(*declarations.DeclTable) = null,
    /// Module currently being annotated — for building type→module lookup in union canonicalization.
    current_module_name: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        reporter: *errors.Reporter,
        decls: *declarations.DeclTable,
        type_map: *const std.AutoHashMapUnmanaged(*parser.Node, RT),
        union_registry: *UnionRegistry,
    ) MirAnnotator {
        return .{
            .allocator = allocator,
            .reporter = reporter,
            .decls = decls,
            .type_map = type_map,
            .node_map = .{},
            .union_registry = union_registry,
            .var_types = .{},
        };
    }

    pub fn deinit(self: *MirAnnotator) void {
        self.node_map.deinit(self.allocator);
        self.var_types.deinit(self.allocator);
    }

    /// Annotate the entire program AST.
    pub fn annotate(self: *MirAnnotator, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.annotateNode(node);
        }
    }

    pub fn annotateNode(self: *MirAnnotator, node: *parser.Node) anyerror!void {
        return nodes_impl.annotateNode(self, node);
    }

    pub fn annotateExpr(self: *MirAnnotator, node: *parser.Node) !void {
        return nodes_impl.annotateExpr(self, node);
    }

    pub fn annotateCallCoercions(self: *MirAnnotator, c: parser.CallExpr) !void {
        return nodes_impl.annotateCallCoercions(self, c);
    }

    pub fn annotateDeclCoercions(self: *MirAnnotator, value: *parser.Node, decl_type: RT) !void {
        return nodes_impl.annotateDeclCoercions(self, value, decl_type);
    }

    pub fn annotateReturnCoercions(self: *MirAnnotator, value: *parser.Node) !void {
        return nodes_impl.annotateReturnCoercions(self, value);
    }

    /// Core coercion detection: given a source type and a target type,
    /// determine if a coercion is needed and which kind.
    pub fn detectCoercion(src: RT, dst: RT) CoercionResult {
        // Can't determine coercion without concrete types
        if (src == .unknown or src == .inferred or dst == .unknown or dst == .inferred)
            return .{ .kind = null };
        // Array → slice
        if (src == .array and dst == .slice)
            return .{ .kind = .array_to_slice };
        // Plain → null union: (null | T)
        if (dst.unionContainsNull() and !src.unionContainsNull() and src != .null_type)
            return .{ .kind = .null_wrap };
        // Plain → error union: (Error | T)
        if (dst.unionContainsError() and !src.unionContainsError() and src != .err)
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
            // err literal into an error-containing union:
            // typeToZig emits anyerror!T for such unions, so Zig handles natively.
            if (src == .err and dst.unionContainsError()) return .{ .kind = null };
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
        if (src.unionContainsNull() and !dst.unionContainsNull())
            return .{ .kind = .optional_unwrap };
        // Value → const ref (T → const& T)
        if (dst == .ptr) {
            if (dst.ptr.kind == .const_ref) {
                if (typesMatch(src, dst.ptr.elem.*)) {
                    return .{ .kind = .value_to_const_ref };
                }
            }
        }
        return .{ .kind = null };
    }

    /// Check if two resolved types are structurally equivalent for coercion purposes.
    pub fn typesMatch(a: RT, b: RT) bool {
        if (a == .primitive and b == .primitive) return a.primitive == b.primitive;
        if (a == .named and b == .named) return std.mem.eql(u8, a.named, b.named);
        if (a == .generic and b == .generic) return std.mem.eql(u8, a.generic.name, b.generic.name);
        return false;
    }

    pub const CoercionResult = struct {
        kind: ?Coercion = null,
        tag: ?[]const u8 = null,
    };

    /// Look up a FuncSig for a call expression's callee.
    pub fn resolveCallSig(self: *const MirAnnotator, c: parser.CallExpr) ?declarations.FuncSig {
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
                    // Check current module's struct methods first. This covers struct
                    // methods which are not in funcs to avoid name collisions.
                    if (self.decls.getMethod(struct_name, method_name)) |sig| return sig;
                    if (self.all_decls) |ad| {
                        // Also check all modules' struct methods for cross-module calls.
                        var it = ad.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.*.getMethod(struct_name, method_name)) |sig| return sig;
                        }
                        // Fallback: funcs lookup by method name.
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

    pub fn lookupType(self: *const MirAnnotator, node: *parser.Node) ?RT {
        return self.type_map.get(node);
    }

    pub fn recordNode(self: *MirAnnotator, node: *parser.Node, t: RT) !void {
        try self.node_map.put(self.allocator, node, .{ .resolved_type = t });
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

    var ureg = UnionRegistry.init(alloc);
    defer ureg.deinit();
    var annotator = MirAnnotator.init(alloc, &reporter, &decl_table, &type_map, &ureg);
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

    var ureg = UnionRegistry.init(alloc);
    defer ureg.deinit();
    var annotator = MirAnnotator.init(alloc, &reporter, &decl_table, &type_map, &ureg);
    defer annotator.deinit();

    // Manually insert a var_types entry to verify the registry works
    const info = NodeInfo{ .resolved_type = RT{ .primitive = .i32 } };
    try annotator.var_types.put(alloc, "x", info);
    try std.testing.expectEqual(@as(usize, 1), annotator.var_types.count());

    const got = annotator.var_types.get("x").?;
    try std.testing.expectEqual(TypeClass.plain, got.typeClass());
    try std.testing.expectEqualStrings("i32", got.resolved_type.name());
}

test "detectCoercion - null_wrap" {
    const null_union_type = RT{ .union_type = &.{ RT.null_type, RT{ .primitive = .i32 } } };

    // Plain → null union → null_wrap
    const r1 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, null_union_type);
    try std.testing.expectEqual(Coercion.null_wrap, r1.kind.?);

    // null_union → null_union → no coercion
    const r2 = MirAnnotator.detectCoercion(null_union_type, null_union_type);
    try std.testing.expect(r2.kind == null);

    // null_type → null_union → no coercion (null literal handled separately)
    const r3 = MirAnnotator.detectCoercion(RT.null_type, null_union_type);
    try std.testing.expect(r3.kind == null);
}

test "detectCoercion - error_wrap" {
    const error_union_type = RT{ .union_type = &.{ RT.err, RT{ .primitive = .i32 } } };

    // Plain → error union → error_wrap
    const r1 = MirAnnotator.detectCoercion(RT{ .primitive = .i32 }, error_union_type);
    try std.testing.expectEqual(Coercion.error_wrap, r1.kind.?);

    // error_union → error_union → no coercion
    const r2 = MirAnnotator.detectCoercion(error_union_type, error_union_type);
    try std.testing.expect(r2.kind == null);

    // err → error_union → no coercion (error literal handled separately)
    const r3 = MirAnnotator.detectCoercion(RT.err, error_union_type);
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
    // (null | i32) → i32 → optional_unwrap
    const null_union_type = RT{ .union_type = &.{ RT.null_type, RT{ .primitive = .i32 } } };
    const r1 = MirAnnotator.detectCoercion(null_union_type, RT{ .primitive = .i32 });
    try std.testing.expectEqual(Coercion.optional_unwrap, r1.kind.?);
}

test "detectCoercion - unknown types" {
    const null_union_type = RT{ .union_type = &.{ RT.null_type, RT{ .primitive = .i32 } } };

    // Unknown source → no coercion
    const r1 = MirAnnotator.detectCoercion(RT.unknown, null_union_type);
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
    const dst = RT{ .ptr = .{ .kind = .const_ref, .elem = elem } };
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
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    });

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    try all_decls.put("math", &math_decls);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, RT){};
    defer type_map.deinit(alloc);

    var ureg = UnionRegistry.init(alloc);
    defer ureg.deinit();
    var annotator = MirAnnotator.init(alloc, &reporter, &local_decls, &type_map, &ureg);
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

test "typesMatch" {
    // Primitive match
    try std.testing.expect(MirAnnotator.typesMatch(RT{ .primitive = .i32 }, RT{ .primitive = .i32 }));
    try std.testing.expect(!MirAnnotator.typesMatch(RT{ .primitive = .i32 }, RT{ .primitive = .f64 }));
    // Named match
    try std.testing.expect(MirAnnotator.typesMatch(RT{ .named = "Foo" }, RT{ .named = "Foo" }));
    try std.testing.expect(!MirAnnotator.typesMatch(RT{ .named = "Foo" }, RT{ .named = "Bar" }));
    // Generic match
    try std.testing.expect(MirAnnotator.typesMatch(
        RT{ .generic = .{ .name = "List", .args = &.{} } },
        RT{ .generic = .{ .name = "List", .args = &.{} } },
    ));
    try std.testing.expect(!MirAnnotator.typesMatch(
        RT{ .generic = .{ .name = "List", .args = &.{} } },
        RT{ .generic = .{ .name = "Map", .args = &.{} } },
    ));
    // Cross-category mismatch
    try std.testing.expect(!MirAnnotator.typesMatch(RT{ .primitive = .i32 }, RT{ .named = "i32" }));
}

test "detectCoercion - array_to_slice" {
    const alloc = std.testing.allocator;
    const elem = try alloc.create(RT);
    defer alloc.destroy(elem);
    elem.* = RT{ .primitive = .i32 };
    var size_node = parser.Node{ .int_literal = "3" };
    const src = RT{ .array = .{ .elem = elem, .size = &size_node } };
    const dst = RT{ .slice = elem };
    const result = MirAnnotator.detectCoercion(src, dst);
    try std.testing.expectEqual(Coercion.array_to_slice, result.kind.?);
}

test "detectCoercion - numeric literal to arbitrary union" {
    const members = &[_]RT{ RT{ .primitive = .i32 }, RT{ .primitive = .string } };
    const src = RT{ .primitive = .numeric_literal };
    const dst = RT{ .union_type = members };
    const result = MirAnnotator.detectCoercion(src, dst);
    try std.testing.expectEqual(Coercion.arbitrary_union_wrap, result.kind.?);
    try std.testing.expectEqualStrings("i32", result.tag.?);
}

test "detectCoercion - float literal to arbitrary union" {
    const members = &[_]RT{ RT{ .primitive = .f64 }, RT{ .primitive = .string } };
    const src = RT{ .primitive = .float_literal };
    const dst = RT{ .union_type = members };
    const result = MirAnnotator.detectCoercion(src, dst);
    try std.testing.expectEqual(Coercion.arbitrary_union_wrap, result.kind.?);
    try std.testing.expectEqualStrings("f64", result.tag.?);
}

test "detectCoercion - null literal to null-containing union no wrap" {
    const members = &[_]RT{ RT.null_type, RT{ .primitive = .i32 } };
    const src = RT.null_type;
    const dst = RT{ .union_type = members };
    const result = MirAnnotator.detectCoercion(src, dst);
    try std.testing.expect(result.kind == null);
}

