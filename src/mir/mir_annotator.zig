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
    union_registry: UnionRegistry,
    /// Variable name → NodeInfo lookup (fallback when node pointer isn't in type_map).
    var_types: std.StringHashMapUnmanaged(NodeInfo),
    /// Current function name — for looking up return type during annotation.
    current_func_name: ?[]const u8 = null,
    /// All module DeclTables — for cross-module function signature resolution.
    all_decls: ?*const std.StringHashMap(*declarations.DeclTable) = null,
    /// Variable names declared as constant (for const auto-borrow detection).
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

    pub fn annotateNode(self: *MirAnnotator, node: *parser.Node) anyerror!void {
        return nodes_impl.annotateNode(self, node);
    }

    pub fn annotateExpr(self: *MirAnnotator, node: *parser.Node) !void {
        return nodes_impl.annotateExpr(self, node);
    }

    pub fn annotateCallCoercions(self: *MirAnnotator, c: parser.CallExpr) !void {
        return nodes_impl.annotateCallCoercions(self, c);
    }

    /// Returns true if the type requires a reference rather than a value copy.
    /// Primitives (i32, f32, bool, String, etc.) and value types (Vector) are excluded.
    pub fn isNonPrimitiveType(t: RT) bool {
        return switch (t) {
            .primitive => false,
            .generic => |g| !builtins.isValueType(g.name),
            .unknown, .inferred => false,
            else => true,
        };
    }

    /// Record that a function parameter at the given index needs *const T in Zig output.
    pub fn recordConstRefParam(self: *MirAnnotator, func_name: []const u8, param_idx: usize) !void {
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
        // Plain → null union (CoreType)
        if (dst.isCoreType(.null_union) and !src.isCoreType(.null_union) and src != .null_type)
            return .{ .kind = .null_wrap };
        // Plain → error union (CoreType)
        if (dst.isCoreType(.error_union) and !src.isCoreType(.error_union) and src != .err)
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
        if (src.isCoreType(.null_union) and !dst.isCoreType(.null_union))
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
        if (a == .core_type and b == .core_type) return a.core_type.kind == b.core_type.kind;
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
                    // Check current module's struct_methods first ("StructName.method" key).
                    // This covers struct methods which are not in funcs to avoid name collisions.
                    const qualified_key = std.fmt.allocPrint(
                        self.allocator, "{s}.{s}", .{ struct_name, method_name },
                    ) catch return null;
                    defer self.allocator.free(qualified_key);
                    if (self.decls.struct_methods.get(qualified_key)) |sig| return sig;
                    if (self.all_decls) |ad| {
                        // Also check all modules' struct_methods for cross-module calls.
                        var it = ad.iterator();
                        while (it.next()) |entry| {
                            if (entry.value_ptr.*.struct_methods.get(qualified_key)) |sig| return sig;
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

    const null_union_type = RT{ .core_type = .{ .kind = .null_union, .inner = inner } };

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
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    const error_union_type = RT{ .core_type = .{ .kind = .error_union, .inner = inner } };

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
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // null_union → plain → optional_unwrap
    const r1 = MirAnnotator.detectCoercion(RT{ .core_type = .{ .kind = .null_union, .inner = inner } }, RT{ .primitive = .i32 });
    try std.testing.expectEqual(Coercion.optional_unwrap, r1.kind.?);
}

test "detectCoercion - unknown types" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };

    // Unknown source → no coercion
    const r1 = MirAnnotator.detectCoercion(RT.unknown, RT{ .core_type = .{ .kind = .null_union, .inner = inner } });
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
        .return_type_node = ret_node,
        .context = .normal,
        .is_pub = true,
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
    // Verify that const_vars contains the name after annotating a constant var_decl,
    // but NOT the name after annotating a mutable var_decl.
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
    const_node.* = .{ .var_decl = .{ .name = "c", .type_annotation = null, .value = val_node, .is_pub = false, .mutability = .constant } };
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
        .context = .normal,
        .is_pub = false,
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
        .context = .normal,
        .is_pub = false,
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
        .context = .normal,
        .is_pub = false,
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

