// resolver.zig — Compt & Type Resolution pass (pass 5)
// Resolves 'any' to concrete types, evaluates compt expressions,
// validates all type annotations are correct and explicit.
// Interleaved: compt results feed back into type resolution.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const sema = @import("sema.zig");
const K = @import("constants.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const exprs_impl = @import("resolver_exprs.zig");
const validation_impl = @import("resolver_validation.zig");
const stmts_impl = @import("resolver_stmts.zig");
const RT = types.ResolvedType;
const ast_store_mod = @import("ast_store.zig");
const ast_typed = @import("ast_typed.zig");
const ast_conv = @import("ast_conv.zig");
pub const AstNodeIndex = ast_store_mod.AstNodeIndex;
const AstStore = ast_store_mod.AstStore;
const AstKind = ast_store_mod.AstKind;

/// Primitive type name candidates for "did you mean?" suggestions on unknown types.
pub const PRIMITIVE_NAMES = [_][]const u8{
    "i8", "i16", "i32", "i64", "i128",
    "u8", "u16", "u32", "u64", "u128",
    "isize", "usize",
    "f16", "f32", "f64", "f128",
    "bool", "str", "void",
};

/// Scope for variable type tracking
pub const Scope = scope_mod.ScopeBase(RT);

/// Per-recursion resolution context. Passed by value through the resolve tree
/// so each stack frame owns its own copy — enabling future per-function parallelism.
/// Fields that need to change on recursive descent create a local modified copy.
pub const ResolveCtx = struct {
    loop_depth: u32 = 0,
    in_is_condition: bool = false,
    type_decl_depth: u32 = 0,
    in_generic_struct: bool = false,
    current_return_type: ?RT = null,
    in_anytype_arg: bool = false,
    /// Parameter names of the current function — used for compt argument validation.
    /// Slice into a stack-allocated ArrayList; valid only for the duration of
    /// the enclosing func_decl resolveNode call.
    param_names: []const []const u8 = &.{},
};

/// The type resolver
pub const TypeResolver = struct {
    ctx: *const sema.SemanticContext,
    type_map: std.AutoHashMapUnmanaged(*parser.Node, RT),
    /// Parallel AstNodeIndex-keyed type map — consumed by MirBuilder (B5+).
    ast_type_map: std.AutoHashMapUnmanaged(AstNodeIndex, RT),
    /// AstStore for index-based traversal (Phase A).
    store: *const AstStore = undefined,
    /// Reverse map from AstNodeIndex back to *parser.Node for bridge calls.
    /// Reads from self.ctx.reverse_map — the separate field is kept for
    /// convenience but must always equal ctx.reverse_map.
    reverse_map: ?*const std.AutoHashMap(AstNodeIndex, *parser.Node) = null,
    /// Module names imported with `use` — their types are available unqualified.
    included_modules: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn init(ctx: *const sema.SemanticContext) TypeResolver {
        return .{
            .ctx = ctx,
            .type_map = .{},
            .ast_type_map = .{},
        };
    }

    pub fn deinit(self: *TypeResolver) void {
        self.type_map.deinit(self.ctx.allocator);
        self.ast_type_map.deinit(self.ctx.allocator);
        self.included_modules.deinit(self.ctx.allocator);
    }

    /// Look up the original *parser.Node for a given AstNodeIndex.
    /// Prefers ctx.reverse_map (set by the pipeline) over the local reverse_map
    /// field (used by tests and LSP). Returns null if neither is set or the
    /// index is not found.
    pub fn reverseNode(self: *const TypeResolver, idx: AstNodeIndex) ?*parser.Node {
        const rm = self.ctx.reverse_map orelse self.reverse_map orelse return null;
        return rm.get(idx);
    }

    /// Alias kept for call-site compatibility; identical to reverseNode.
    pub fn reverseNodeMut(self: *const TypeResolver, idx: AstNodeIndex) ?*parser.Node {
        return self.reverseNode(idx);
    }

    /// Get source location for an AstNodeIndex via reverse_map bridge.
    pub fn nodeLocFromIdx(self: *const TypeResolver, idx: AstNodeIndex) ?errors.SourceLoc {
        return self.ctx.nodeLocFromIdx(idx);
    }

    /// Store a resolved type in both type_maps: pointer-keyed (reverse_map compat)
    /// and index-keyed (for MirBuilder).
    pub fn putTypeMap(self: *TypeResolver, idx: AstNodeIndex, rt: RT) !void {
        if (self.reverseNodeMut(idx)) |n| try self.type_map.put(self.ctx.allocator, n, rt);
        try self.ast_type_map.put(self.ctx.allocator, idx, rt);
    }

    /// Get the *parser.Node for calling unmigrated APIs (types.resolveTypeNode).
    /// Returns error.MissingReverseNode if the reverse_map lookup fails.
    pub fn mustReverse(self: *const TypeResolver, idx: AstNodeIndex) !*parser.Node {
        return self.reverseNodeMut(idx) orelse return error.MissingReverseNode;
    }

    /// Check if a name exists in a parent scope within the function boundary.
    /// Walks the parent chain from scope.parent, stopping before the module-level
    /// root scope (parent == null). Used for cross-scope shadowing detection.
    pub fn lookupInFuncScope(_: *const TypeResolver, scope: *Scope, name: []const u8) bool {
        var s = scope.parent orelse return false;
        while (true) {
            if (s.vars.contains(name)) return true;
            if (s.is_func_root or s.parent == null) return false;
            s = s.parent.?;
        }
    }

    /// Check if a type name exists as a pub declaration in any `use`-d (included) module's DeclTable.
    pub fn isIncludedType(self: *const TypeResolver, name: []const u8) bool {
        const ad = self.ctx.all_decls orelse return false;
        for (self.included_modules.items) |mod_name| {
            if (ad.get(mod_name)) |mod_decls| {
                if (mod_decls.symbols.get(name)) |sym| if (sym.isPub()) return true;
            }
        }
        return false;
    }

    /// Resolve a type node, treating type alias names as opaque (returns .inferred).
    /// Type aliases are transparent — Zig handles the real type checking at codegen.
    /// Pass scope to also detect local type aliases (declared inside function bodies).
    pub fn resolveTypeAnnotation(self: *TypeResolver, idx: AstNodeIndex) !RT {
        return self.resolveTypeAnnotationInScope(idx, null);
    }

    pub fn resolveTypeAnnotationInScope(self: *TypeResolver, idx: AstNodeIndex, scope: ?*Scope) !RT {
        const node = try self.mustReverse(idx);
        const resolved = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), node);
        if (resolved == .named) {
            // Module-level type alias
            if (self.ctx.decls.symbols.get(resolved.named)) |sym| switch (sym) {
                .type_alias => return RT.inferred,
                else => {},
            };
            // Local type alias: stored in scope as RT.primitive(.@"type") (since "type" is a Primitive)
            if (scope) |s| {
                if (s.lookup(resolved.named)) |t| {
                    if (t == .primitive and t.primitive == .@"type") return RT.inferred;
                }
            }
        }
        return resolved;
    }

    /// Resolve types in a program AST (new index-based entry point).
    pub fn resolve(self: *TypeResolver, store: *const AstStore, root: AstNodeIndex) !void {
        self.store = store;
        if (store.getNode(root).tag != .program) return;

        const prog = ast_typed.Program.unpack(store, root);

        // Collect `use`-d module names for unqualified type resolution
        const imports_slice = store.extra_data.items[prog.imports_start..prog.imports_end];
        for (imports_slice) |imp_u32| {
            const imp_idx: AstNodeIndex = @enumFromInt(imp_u32);
            if (store.getNode(imp_idx).tag == .import_decl) {
                const imp = ast_typed.ImportDecl.unpack(store, imp_idx);
                // flags bit 0 = is_include
                if (imp.flags & 1 != 0) {
                    try self.included_modules.append(self.ctx.allocator, store.strings.get(imp.path));
                }
            }
        }

        var scope = Scope.init(self.ctx.allocator, null);
        defer scope.deinit();

        // First pass: register top-level declarations in scope
        const top_slice = store.extra_data.items[prog.top_level_start..prog.top_level_end];
        for (top_slice) |tl_u32| {
            const tl_idx: AstNodeIndex = @enumFromInt(tl_u32);
            try self.registerDecl(tl_idx, &scope);
        }

        // Second pass: resolve bodies
        for (top_slice) |tl_u32| {
            const tl_idx: AstNodeIndex = @enumFromInt(tl_u32);
            try self.resolveNode(tl_idx, &scope, .{});
        }
    }

    fn registerDecl(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope) anyerror!void {
        return stmts_impl.registerDecl(self, idx, scope);
    }

    pub fn resolveNode(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!void {
        return stmts_impl.resolveNode(self, idx, scope, rctx);
    }

    pub fn resolveStatement(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!void {
        return stmts_impl.resolveStatement(self, idx, scope, rctx);
    }

    /// Resolve an expression and return its ResolvedType.
    /// Accepts AstNodeIndex; delegates to resolver_exprs.zig.
    pub fn resolveExpr(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!RT {
        return exprs_impl.resolveExpr(self, idx, scope, rctx);
    }

    pub fn checkMatchExhaustiveness(self: *TypeResolver, match_type: RT, arms: []*parser.Node, match_node: *parser.Node) !void {
        return validation_impl.checkMatchExhaustiveness(self, match_type, arms, match_node);
    }

    pub fn validateMatchArm(self: *TypeResolver, pattern_name: []const u8, match_type: RT, arm_idx: AstNodeIndex) !void {
        // Bridge: pass *parser.Node to validation (unmigrated in this commit).
        // Assert the index must be in the reverse_map — a missing entry is a bug,
        // not a recoverable condition (silent no-op would skip type checking).
        const n = self.reverseNodeMut(arm_idx) orelse {
            std.debug.panic("validateMatchArm: reverse_map missing AstNodeIndex {}", .{@intFromEnum(arm_idx)});
        };
        return validation_impl.validateMatchArm(self, pattern_name, match_type, n);
    }

    pub fn validateType(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!void {
        // Bridge: pass *parser.Node to validation
        const node = try self.mustReverse(idx);
        return validation_impl.validateType(self, node, scope, rctx);
    }

    pub fn checkAssignCompat(self: *TypeResolver, expected: RT, actual: RT, idx: AstNodeIndex) !void {
        // Bridge: pass *parser.Node to validation.
        // Assert the index must be in the reverse_map — a missing entry is a bug,
        // not a recoverable condition (silent no-op would skip type checking).
        const n = self.reverseNodeMut(idx) orelse {
            std.debug.panic("checkAssignCompat: reverse_map missing AstNodeIndex {}", .{@intFromEnum(idx)});
        };
        return validation_impl.checkAssignCompat(self, expected, actual, n);
    }

    /// Returns true if `name` is a variant of any declared enum.
    /// Used to suppress false "unknown identifier" errors for enum variants used as match patterns.
    pub fn isEnumVariant(self: *const TypeResolver, name: []const u8) bool {
        var sym_it = self.ctx.decls.symbols.valueIterator();
        while (sym_it.next()) |sym| {
            if (sym.* == .@"enum") {
                for (sym.@"enum".variants) |v| {
                    if (std.mem.eql(u8, v, name)) return true;
                }
            }
        }
        return false;
    }

    pub fn checkByteSliceStringCoercion(self: *TypeResolver, c: parser.CallExpr, arg_types: []const RT, node: *parser.Node) !void {
        return validation_impl.checkByteSliceStringCoercion(self, c, arg_types, node);
    }

    pub fn checkBlueprintConformance(self: *TypeResolver, s: parser.StructDecl, loc: ?errors.SourceLoc) anyerror!void {
        return validation_impl.checkBlueprintConformance(self, s, loc);
    }
};

/// Compare two ResolvedTypes with blueprint→struct name substitution.
/// When a blueprint declares `self: const& Eq`, a struct implementing it
/// should have `self: const& Point` — this function treats Eq↔Point as a match.
pub fn typesMatchWithSubstitution(struct_type: RT, bp_type: RT, bp_name: []const u8, struct_name: []const u8) bool {
    switch (bp_type) {
        .named => |name| {
            if (std.mem.eql(u8, name, bp_name)) {
                // Blueprint's own name → must match struct's name
                return switch (struct_type) {
                    .named => |sn| std.mem.eql(u8, sn, struct_name),
                    else => false,
                };
            }
            // Non-self named type must match exactly
            return switch (struct_type) {
                .named => |sn| std.mem.eql(u8, sn, name),
                else => false,
            };
        },
        .primitive => |p| {
            return switch (struct_type) {
                .primitive => |sp| sp == p,
                else => false,
            };
        },
        .ptr => |bp_ptr| {
            return switch (struct_type) {
                .ptr => |sp| {
                    if (bp_ptr.kind != sp.kind) return false;
                    return typesMatchWithSubstitution(sp.elem.*, bp_ptr.elem.*, bp_name, struct_name);
                },
                else => false,
            };
        },
        .slice => |bp_elem| {
            return switch (struct_type) {
                .slice => |se| typesMatchWithSubstitution(se.*, bp_elem.*, bp_name, struct_name),
                else => false,
            };
        },
        .array => |bp_arr| {
            return switch (struct_type) {
                .array => |sa| typesMatchWithSubstitution(sa.elem.*, bp_arr.elem.*, bp_name, struct_name),
                else => false,
            };
        },
        .union_type => |bp_members| {
            return switch (struct_type) {
                .union_type => |sm| {
                    if (bp_members.len != sm.len) return false;
                    for (bp_members, sm) |bp_m, sm_m| {
                        if (!typesMatchWithSubstitution(sm_m, bp_m, bp_name, struct_name)) return false;
                    }
                    return true;
                },
                else => false,
            };
        },
        .err => return struct_type == .err,
        .null_type => return struct_type == .null_type,
        .inferred => return struct_type == .inferred,
        .unknown => return true,
        else => {
            // For other types (tuple, func_ptr, generic, etc.)
            // fall back to tag comparison
            return std.meta.activeTag(bp_type) == std.meta.activeTag(struct_type);
        },
    }
}

/// Infer the element type for for-loop captures from the iterable (*parser.Node version).
pub fn inferCaptureType(iterable: *parser.Node, iter_type: RT) RT {
    // Range expressions produce integers
    if (iterable.* == .range_expr) return RT{ .primitive = .usize };
    // str iteration produces u8 characters
    if (iter_type == .primitive and iter_type.primitive == .string)
        return RT{ .primitive = .u8 };
    // Slice/array of known type — element type is the inner type
    if (iter_type == .slice) return iter_type.slice.*;
    if (iter_type == .array) return iter_type.array.elem.*;
    return RT.inferred;
}

/// Infer capture type from AstNodeIndex (AstStore-based version).
pub fn inferCaptureTypeIdx(self: *const TypeResolver, iterable_idx: AstNodeIndex, iter_type: RT) RT {
    // Range expressions produce integers
    if (self.store.getNode(iterable_idx).tag == .range_expr) return RT{ .primitive = .usize };
    // str iteration produces u8 characters
    if (iter_type == .primitive and iter_type.primitive == .string)
        return RT{ .primitive = .u8 };
    // Slice/array of known type — element type is the inner type
    if (iter_type == .slice) return iter_type.slice.*;
    if (iter_type == .array) return iter_type.array.elem.*;
    return RT.inferred;
}

pub fn typesCompatible(a: RT, b: RT) bool {
    const a_name = a.name();
    const b_name = b.name();
    if (a_name.len > 0 and b_name.len > 0 and std.mem.eql(u8, a_name, b_name)) return true;
    // Numeric literals are compatible with any integer type
    if (a == .primitive and a.primitive == .numeric_literal and
        b == .primitive and b.primitive.isInteger()) return true;
    // Float literals are compatible with any float type
    if (a == .primitive and a.primitive == .float_literal and
        b == .primitive and b.primitive.isFloat()) return true;
    // Integer-to-integer and float-to-float are compatible (Zig handles coercion)
    if (a == .primitive and b == .primitive and a.primitive.isInteger() and b.primitive.isInteger()) return true;
    if (a == .primitive and b == .primitive and a.primitive.isFloat() and b.primitive.isFloat()) return true;
    // Unions accept any of their members, or unresolved literals matching any member.
    // This includes (Error | T) accepting Error/T and (null | T) accepting null/T.
    if (b == .union_type) {
        if (a == .inferred or a == .unknown) return true;
        for (b.union_type) |member| {
            if (std.mem.eql(u8, a_name, member.name())) return true;
            if (isLiteralCompatible(a, member)) return true;
        }
        return false;
    }
    if (a == .union_type) {
        if (b == .inferred or b == .unknown) return true;
        for (a.union_type) |member| {
            if (std.mem.eql(u8, b_name, member.name())) return true;
            if (isLiteralCompatible(b, member)) return true;
        }
        return false;
    }
    // func_ptr / func returns are hard to check without full inference — allow
    if (a == .func_ptr or b == .func_ptr) return true;
    // tuple literal compatible with named type alias — Zig validates structural match
    if ((a == .tuple and b == .named) or (a == .named and b == .tuple)) return true;
    return false;
}

/// Check if an unresolved literal type is compatible with a target type
/// e.g. numeric_literal is compatible with any integer member of a union
pub fn isLiteralCompatible(val: RT, target: RT) bool {
    if (val != .primitive) return false;
    if (target != .primitive) return false;
    if (val.primitive == .numeric_literal and target.primitive.isInteger()) return true;
    if (val.primitive == .float_literal and target.primitive.isFloat()) return true;
    return false;
}

// ── `is` check detection helpers ──────────────────────────────

/// Returns true if the node is a simple `is` check: binary_expr where left is compiler_func("type").
/// Matches both `x is T` (eq) and `x is not T` (ne).
pub fn isIsCheck(node: *parser.Node) bool {
    if (node.* != .binary_expr) return false;
    const b = node.binary_expr;
    if (b.op != .eq and b.op != .ne) return false;
    if (b.left.* != .compiler_func) return false;
    return types.Primitive.fromName(b.left.compiler_func.name) == .@"type";
}

/// Returns true if the expression tree contains any `is` check (possibly nested inside and/or).
pub fn containsIsCheck(node: *parser.Node) bool {
    if (isIsCheck(node)) return true;
    if (node.* != .binary_expr) return false;
    const b = node.binary_expr;
    if (b.op == .@"and" or b.op == .@"or") {
        return containsIsCheck(b.left) or containsIsCheck(b.right);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Test helpers — convert *parser.Node to AstStore for the new resolver API
// ---------------------------------------------------------------------------

/// Helper for tests: convert a *parser.Node to AstStore and set up the resolver.
const TestConv = struct {
    conv: ast_conv.ConvContext,
    root_idx: AstNodeIndex,

    fn init(node: *const parser.Node) !TestConv {
        var conv = ast_conv.ConvContext.init(std.testing.allocator);
        errdefer conv.deinit();
        const root_idx = try ast_conv.convertNode(&conv, node);
        return .{ .conv = conv, .root_idx = root_idx };
    }

    fn deinit(self: *TestConv) void {
        self.conv.deinit();
    }

    /// Set up a TypeResolver to use this converted store.
    fn setup(self: *TestConv, r: *TypeResolver) void {
        r.store = &self.conv.store;
        r.reverse_map = &self.conv.reverse_map;
    }
};

test "resolver init" {
    var decl_table = declarations.DeclTable.init(std.testing.allocator);
    defer decl_table.deinit();

    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    const ctx = sema.SemanticContext.initForTest(std.testing.allocator, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - untyped numeric literal requires explicit type" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const int_lit = try a.create(parser.Node);
    int_lit.* = .{ .int_literal = "42" };
    const var_decl = try a.create(parser.Node);
    var_decl.* = .{ .var_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = int_lit,
        .is_pub = false,
    } };

    const body = try a.create(parser.Node);
    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = var_decl;
    body.* = .{ .block = .{ .statements = stmts } };

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "main",
        .params = &.{},
        .return_type = ret_type,
        .body = body,
        .context = .normal,
        .is_pub = false,
    } };

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const program = try a.create(parser.Node);
    program.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    } };

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var type_resolver = TypeResolver.init(&ctx);
    defer type_resolver.deinit();

    var tc = try TestConv.init(program);
    defer tc.deinit();
    tc.setup(&type_resolver);
    try type_resolver.resolve(&tc.conv.store, tc.root_idx);

    try std.testing.expect(reporter.hasErrors());
}

test "resolver - function return type resolves" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "i32" };

    try decl_table.symbols.put("add", .{ .func = .{
        .name = "add",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .i32 },
        .context = .normal,
        .is_pub = false,
        .is_instance = false,
    } });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "add" };
    const arg1 = try a.create(parser.Node);
    arg1.* = .{ .int_literal = "1" };
    const arg2 = try a.create(parser.Node);
    arg2.* = .{ .int_literal = "2" };
    const args = try a.alloc(*parser.Node, 2);
    args[0] = arg1;
    args[1] = arg2;
    const call = try a.create(parser.Node);
    call.* = .{ .call_expr = .{ .callee = callee, .args = args, .arg_names = &.{} } };

    var tc = try TestConv.init(call);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("i32", result.name());
}

test "resolver - struct field type resolves" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 2);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    try decl_table.symbols.put("Point", .{ .@"struct" = .{
        .name = "Point",
        .fields = fields,
        .is_pub = true,
    } });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    try scope.define("p", RT{ .named = "Point" });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const obj = try a.create(parser.Node);
    obj.* = .{ .identifier = "p" };
    const field_node = try a.create(parser.Node);
    field_node.* = .{ .field_expr = .{ .object = obj, .field = "x" } };

    var tc = try TestConv.init(field_node);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("f32", result.name());
}

test "resolver - explicit type annotation preferred" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const type_ann = try a.create(parser.Node);
    type_ann.* = .{ .type_named = "i64" };
    const val = try a.create(parser.Node);
    val.* = .{ .int_literal = "42" };
    const decl = try a.create(parser.Node);
    decl.* = .{ .var_decl = .{
        .name = "x",
        .type_annotation = type_ann,
        .value = val,
        .is_pub = false,
    } };

    var tc = try TestConv.init(decl);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolveNode(tc.root_idx, &scope, .{});
    try std.testing.expect(!reporter.hasErrors());

    const x_type = scope.lookup("x").?;
    try std.testing.expectEqualStrings("i64", x_type.name());
}

test "resolver - compiler func cast resolves to target type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    try scope.define("x", RT{ .primitive = .i32 });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // cast(i64, x) → i64
    const target = try a.create(parser.Node);
    target.* = .{ .identifier = "i64" };
    const arg = try a.create(parser.Node);
    arg.* = .{ .identifier = "x" };
    const args = try a.alloc(*parser.Node, 2);
    args[0] = target;
    args[1] = arg;
    const cast_node = try a.create(parser.Node);
    cast_node.* = .{ .compiler_func = .{ .name = "cast", .args = args } };

    var tc = try TestConv.init(cast_node);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("i64", result.name());
}

test "resolver - compiler func copy preserves type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    try scope.define("data", RT{ .named = "Player" });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // copy(data) → Player
    const arg = try a.create(parser.Node);
    arg.* = .{ .identifier = "data" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const copy_node = try a.create(parser.Node);
    copy_node.* = .{ .compiler_func = .{ .name = "copy", .args = args } };

    var tc = try TestConv.init(copy_node);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("Player", result.name());
}

test "resolver - compiler func assert returns void" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try a.create(parser.Node);
    arg.* = .{ .bool_literal = true };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const assert_node = try a.create(parser.Node);
    assert_node.* = .{ .compiler_func = .{ .name = "assert", .args = args } };

    var tc = try TestConv.init(assert_node);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("void", result.name());
}

test "resolver - for range capture is usize" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    // Range expressions produce usize captures
    var low = parser.Node{ .int_literal = "0" };
    var high = parser.Node{ .int_literal = "10" };
    var range_node = parser.Node{ .range_expr = .{ .op = .range, .left = &low, .right = &high } };
    const capture_type = inferCaptureType(&range_node, RT.inferred);
    try std.testing.expectEqualStrings("usize", capture_type.name());
    _ = &resolver;
}

test "resolver - struct constructor resolves to named type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 1);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .i32 }, .has_default = false, .is_pub = true };
    try decl_table.symbols.put("Point", .{ .@"struct" = .{ .name = "Point", .fields = fields, .is_pub = true } });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Point{x: 5} → should resolve to "Point"
    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "Point" };
    const arg = try a.create(parser.Node);
    arg.* = .{ .int_literal = "5" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const names = try a.alloc([]const u8, 1);
    names[0] = "x";
    const call = try a.create(parser.Node);
    call.* = .{ .call_expr = .{ .callee = callee, .args = args, .arg_names = names } };

    var tc = try TestConv.init(call);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expectEqualStrings("Point", result.name());
    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - positional struct constructor rejected" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 1);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .i32 }, .has_default = false, .is_pub = true };
    try decl_table.symbols.put("Point", .{ .@"struct" = .{ .name = "Point", .fields = fields, .is_pub = true } });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Point(5) → positional call on struct name, should be rejected
    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "Point" };
    const arg = try a.create(parser.Node);
    arg.* = .{ .int_literal = "5" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const call = try a.create(parser.Node);
    call.* = .{ .call_expr = .{ .callee = callee, .args = args, .arg_names = &.{} } };

    var tc = try TestConv.init(call);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    // Still resolves to the struct type (soft error)
    try std.testing.expectEqualStrings("Point", result.name());
    // But an error was reported
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - validateType catches unknown generic" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // UnknownGeneric(i32) — should error
    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = i32_type;
    const generic_node = try a.create(parser.Node);
    generic_node.* = .{ .type_generic = .{ .name = "UnknownGeneric", .args = args } };

    var tc = try TestConv.init(generic_node);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.validateType(tc.root_idx, &scope, .{});
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - array literal resolves to array type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // [1, 2] — should resolve to [2]numeric_literal
    const e1 = try a.create(parser.Node);
    e1.* = .{ .int_literal = "1" };
    const e2 = try a.create(parser.Node);
    e2.* = .{ .int_literal = "2" };
    const elems = try a.alloc(*parser.Node, 2);
    elems[0] = e1;
    elems[1] = e2;
    const arr = try a.create(parser.Node);
    arr.* = .{ .array_literal = elems };

    var tc = try TestConv.init(arr);
    defer tc.deinit();
    tc.setup(&resolver);
    const result = try resolver.resolveExpr(tc.root_idx, &scope, .{});
    try std.testing.expect(result == .array);
    try std.testing.expect(result.array.elem.* == .primitive);
    try std.testing.expectEqualStrings("2", result.array.size.int_literal);
}

test "resolver - match exhaustiveness with many arms" {
    // Verify that match exhaustiveness checking works with >16 union members
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a union with 20 members: (T0 | T1 | ... | T19)
    const n_members = 20;
    const members = try a.alloc(RT, n_members);
    for (0..n_members) |i| {
        const name = try std.fmt.allocPrint(a, "T{d}", .{i});
        members[i] = .{ .named = name };
    }
    const union_type: RT = .{ .union_type = members };

    // Build match arms covering only 18 of 20 members (missing T18, T19)
    const n_arms = 18;
    const arms = try a.alloc(*parser.Node, n_arms);
    for (0..n_arms) |i| {
        const pat = try a.create(parser.Node);
        pat.* = .{ .identifier = try std.fmt.allocPrint(a, "T{d}", .{i}) };
        const body = try a.create(parser.Node);
        body.* = .{ .int_literal = "0" };
        const arm = try a.create(parser.Node);
        arm.* = .{ .match_arm = .{ .pattern = pat, .guard = null, .body = body } };
        arms[i] = arm;
    }

    const match_node = try a.create(parser.Node);
    match_node.* = .{ .int_literal = "0" }; // dummy node for location

    // Should report missing T18
    try resolver.checkMatchExhaustiveness(union_type, arms, match_node);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - match on primitive without else rejected" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build match on i32 with no else arm
    const pat = try a.create(parser.Node);
    pat.* = .{ .int_literal = "1" };
    const body = try a.create(parser.Node);
    body.* = .{ .int_literal = "0" };
    const arm = try a.create(parser.Node);
    arm.* = .{ .match_arm = .{ .pattern = pat, .guard = null, .body = body } };
    const arms = try a.alloc(*parser.Node, 1);
    arms[0] = arm;

    const match_node = try a.create(parser.Node);
    match_node.* = .{ .int_literal = "0" };

    try resolver.checkMatchExhaustiveness(RT{ .primitive = .i32 }, arms, match_node);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - validateType catches unknown qualified generic" {
    const alloc = std.testing.allocator;
    var local_decls = declarations.DeclTable.init(alloc);
    defer local_decls.deinit();
    var math_decls = declarations.DeclTable.init(alloc);
    defer math_decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    // math module exists but does NOT have "Vec2"
    try all_decls.put("math", &math_decls);

    const ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &local_decls,
        .locs = null,
        .file_offsets = &.{},
        .all_decls = &all_decls,
    };
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = i32_type;
    const generic_node = try a.create(parser.Node);
    generic_node.* = .{ .type_generic = .{ .name = "math.Vec2", .args = args } };

    var tc = try TestConv.init(generic_node);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.validateType(tc.root_idx, &scope, .{});
    try std.testing.expect(reporter.hasErrors());
}

test "typesCompatible - same primitive" {
    try std.testing.expect(typesCompatible(RT{ .primitive = .i32 }, RT{ .primitive = .i32 }));
}

test "typesCompatible - different primitive mismatch" {
    try std.testing.expect(!typesCompatible(RT{ .primitive = .i32 }, RT{ .primitive = .string }));
}

test "typesCompatible - numeric literal with integer" {
    try std.testing.expect(typesCompatible(RT{ .primitive = .numeric_literal }, RT{ .primitive = .i32 }));
    try std.testing.expect(typesCompatible(RT{ .primitive = .numeric_literal }, RT{ .primitive = .u64 }));
}

test "typesCompatible - float literal with float" {
    try std.testing.expect(typesCompatible(RT{ .primitive = .float_literal }, RT{ .primitive = .f32 }));
    try std.testing.expect(typesCompatible(RT{ .primitive = .float_literal }, RT{ .primitive = .f64 }));
}

test "typesCompatible - integer to integer compatible" {
    try std.testing.expect(typesCompatible(RT{ .primitive = .i32 }, RT{ .primitive = .i64 }));
}

test "typesCompatible - float to float compatible" {
    try std.testing.expect(typesCompatible(RT{ .primitive = .f32 }, RT{ .primitive = .f64 }));
}

test "typesCompatible - named union member" {
    const alloc = std.testing.allocator;
    const members = try alloc.alloc(RT, 2);
    defer alloc.free(members);
    members[0] = RT{ .named = "Error" };
    members[1] = RT{ .named = "i32" };
    const union_t = RT{ .union_type = members };

    try std.testing.expect(typesCompatible(RT{ .named = "Error" }, union_t));
    try std.testing.expect(typesCompatible(RT{ .named = "i32" }, union_t));
    try std.testing.expect(!typesCompatible(RT{ .named = "str" }, union_t));
}

test "typesCompatible - func_ptr always compatible" {
    const sentinel = &@as(RT, .unknown);
    const fp = RT{ .func_ptr = .{ .params = &.{}, .return_type = sentinel } };
    try std.testing.expect(typesCompatible(fp, RT{ .primitive = .i32 }));
    try std.testing.expect(typesCompatible(RT{ .primitive = .i32 }, fp));
}

test "typesCompatible - short-uppercase user struct names are NOT silently compatible (CB3 regression)" {
    // CB3: names like Node, Vec3, Iter, Cell, List, Pair are user struct types.
    // They must NOT be compatible with unrelated types — the old heuristic (len<=4 + uppercase)
    // falsely classified them as generic type parameters, disabling type checking.
    try std.testing.expect(!typesCompatible(RT{ .named = "Node" }, RT{ .primitive = .i32 }));
    try std.testing.expect(!typesCompatible(RT{ .named = "Vec3" }, RT{ .primitive = .string }));
    try std.testing.expect(!typesCompatible(RT{ .named = "Iter" }, RT{ .primitive = .bool }));
    try std.testing.expect(!typesCompatible(RT{ .named = "Cell" }, RT{ .primitive = .f32 }));
    try std.testing.expect(!typesCompatible(RT{ .named = "List" }, RT{ .primitive = .i64 }));
    try std.testing.expect(!typesCompatible(RT{ .named = "Pair" }, RT{ .primitive = .u8 }));
    // Same named type is still compatible with itself
    try std.testing.expect(typesCompatible(RT{ .named = "Node" }, RT{ .named = "Node" }));
}

test "typesMatchWithSubstitution - blueprint name maps to struct name" {
    const bp = RT{ .named = "Eq" };
    const st = RT{ .named = "Point" };
    try std.testing.expect(typesMatchWithSubstitution(st, bp, "Eq", "Point"));
    // Non-matching struct name
    try std.testing.expect(!typesMatchWithSubstitution(RT{ .named = "Other" }, bp, "Eq", "Point"));
}

test "typesMatchWithSubstitution - non-self named exact match" {
    try std.testing.expect(typesMatchWithSubstitution(RT{ .named = "i32" }, RT{ .named = "i32" }, "Eq", "Point"));
    try std.testing.expect(!typesMatchWithSubstitution(RT{ .named = "str" }, RT{ .named = "i32" }, "Eq", "Point"));
}

test "typesMatchWithSubstitution - primitive match" {
    try std.testing.expect(typesMatchWithSubstitution(RT{ .primitive = .bool }, RT{ .primitive = .bool }, "Eq", "Point"));
    try std.testing.expect(!typesMatchWithSubstitution(RT{ .primitive = .i32 }, RT{ .primitive = .bool }, "Eq", "Point"));
}

test "typesMatchWithSubstitution - ptr with substitution" {
    const alloc = std.testing.allocator;
    const bp_elem = try alloc.create(RT);
    defer alloc.destroy(bp_elem);
    bp_elem.* = RT{ .named = "Eq" };
    const st_elem = try alloc.create(RT);
    defer alloc.destroy(st_elem);
    st_elem.* = RT{ .named = "Point" };

    const bp_ptr = RT{ .ptr = .{ .kind = .const_ref, .elem = bp_elem } };
    const st_ptr = RT{ .ptr = .{ .kind = .const_ref, .elem = st_elem } };
    try std.testing.expect(typesMatchWithSubstitution(st_ptr, bp_ptr, "Eq", "Point"));

    // Wrong ptr kind
    const st_mut = RT{ .ptr = .{ .kind = .mut_ref, .elem = st_elem } };
    try std.testing.expect(!typesMatchWithSubstitution(st_mut, bp_ptr, "Eq", "Point"));
}

test "inferCaptureType - string produces u8" {
    var dummy = parser.Node{ .int_literal = "0" };
    const result = inferCaptureType(&dummy, RT{ .primitive = .string });
    try std.testing.expectEqual(types.Primitive.u8, result.primitive);
}

test "inferCaptureType - slice produces element type" {
    const alloc = std.testing.allocator;
    const inner = try alloc.create(RT);
    defer alloc.destroy(inner);
    inner.* = RT{ .primitive = .i32 };
    var dummy = parser.Node{ .int_literal = "0" };
    const result = inferCaptureType(&dummy, RT{ .slice = inner });
    try std.testing.expectEqual(types.Primitive.i32, result.primitive);
}

test "isLiteralCompatible" {
    try std.testing.expect(isLiteralCompatible(RT{ .primitive = .numeric_literal }, RT{ .primitive = .i32 }));
    try std.testing.expect(isLiteralCompatible(RT{ .primitive = .float_literal }, RT{ .primitive = .f64 }));
    try std.testing.expect(!isLiteralCompatible(RT{ .primitive = .numeric_literal }, RT{ .primitive = .f32 }));
    try std.testing.expect(!isLiteralCompatible(RT{ .primitive = .string }, RT{ .primitive = .i32 }));
}

test "resolver - validateType accepts known qualified generic" {
    const alloc = std.testing.allocator;
    var local_decls = declarations.DeclTable.init(alloc);
    defer local_decls.deinit();
    var math_decls = declarations.DeclTable.init(alloc);
    defer math_decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    // Add Vec2 to the math module's structs
    try math_decls.symbols.put("Vec2", .{ .@"struct" = .{
        .name = "Vec2",
        .fields = &.{},
        .is_pub = true,
    } });

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    try all_decls.put("math", &math_decls);

    const ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &local_decls,
        .locs = null,
        .file_offsets = &.{},
        .all_decls = &all_decls,
    };
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = i32_type;
    const generic_node = try a.create(parser.Node);
    generic_node.* = .{ .type_generic = .{ .name = "math.Vec2", .args = args } };

    var tc = try TestConv.init(generic_node);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.validateType(tc.root_idx, &scope, .{});
    try std.testing.expect(!reporter.hasErrors());
}

/// Build a minimal program AST with one func containing the given body statements.
/// Used by resolver error path tests.
fn buildTestProgram(a: std.mem.Allocator, top_level_nodes: []*parser.Node) !*parser.Node {
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level_nodes,
    } };
    return prog;
}

/// Wrap statements in a func_decl node for resolve testing.
fn wrapInFunc(a: std.mem.Allocator, stmts: []*parser.Node, ret_type_name: []const u8) !*parser.Node {
    const body = try a.create(parser.Node);
    body.* = .{ .block = .{ .statements = stmts } };
    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = ret_type_name };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "test_fn",
        .params = &.{},
        .return_type = ret,
        .body = body,
        .context = .normal,
        .is_pub = false,
    } };
    return func_node;
}

test "resolver - any as struct field type errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const field_type = try a.create(parser.Node);
    field_type.* = .{ .type_named = "any" };
    const field = try a.create(parser.Node);
    field.* = .{ .field_decl = .{ .name = "x", .type_annotation = field_type, .default_value = null, .is_pub = false } };
    const members = try a.alloc(*parser.Node, 1);
    members[0] = field;
    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{ .name = "Bad", .type_params = &.{}, .members = members, .is_pub = false } };

    const top = try a.alloc(*parser.Node, 1);
    top[0] = struct_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - any return without any param errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const body = try a.create(parser.Node);
    body.* = .{ .block = .{ .statements = &.{} } };
    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "any" };
    // No any-typed params
    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const param = try a.create(parser.Node);
    param.* = .{ .param = .{ .name = "x", .type_annotation = i32_type, .default_value = null } };
    const params = try a.alloc(*parser.Node, 1);
    params[0] = param;

    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "bad_func",
        .params = params,
        .return_type = ret,
        .body = body,
        .context = .normal,
        .is_pub = false,
    } };

    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - duplicate else in match errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build match with two else arms
    const match_val = try a.create(parser.Node);
    match_val.* = .{ .int_literal = "1" };

    const body1 = try a.create(parser.Node);
    body1.* = .{ .int_literal = "0" };
    const pat1 = try a.create(parser.Node);
    pat1.* = .{ .identifier = "else" };
    const arm1 = try a.create(parser.Node);
    arm1.* = .{ .match_arm = .{ .pattern = pat1, .guard = null, .body = body1 } };

    const body2 = try a.create(parser.Node);
    body2.* = .{ .int_literal = "0" };
    const pat2 = try a.create(parser.Node);
    pat2.* = .{ .identifier = "else" };
    const arm2 = try a.create(parser.Node);
    arm2.* = .{ .match_arm = .{ .pattern = pat2, .guard = null, .body = body2 } };

    const arms = try a.alloc(*parser.Node, 2);
    arms[0] = arm1;
    arms[1] = arm2;

    const match = try a.create(parser.Node);
    match.* = .{ .match_stmt = .{ .value = match_val, .arms = arms } };

    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = match;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - else arm not last in match errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const match_val = try a.create(parser.Node);
    match_val.* = .{ .int_literal = "1" };

    // else arm first
    const body1 = try a.create(parser.Node);
    body1.* = .{ .int_literal = "0" };
    const pat1 = try a.create(parser.Node);
    pat1.* = .{ .identifier = "else" };
    const arm1 = try a.create(parser.Node);
    arm1.* = .{ .match_arm = .{ .pattern = pat1, .guard = null, .body = body1 } };

    // non-else arm after
    const body2 = try a.create(parser.Node);
    body2.* = .{ .int_literal = "0" };
    const pat2 = try a.create(parser.Node);
    pat2.* = .{ .int_literal = "42" };
    const arm2 = try a.create(parser.Node);
    arm2.* = .{ .match_arm = .{ .pattern = pat2, .guard = null, .body = body2 } };

    const arms = try a.alloc(*parser.Node, 2);
    arms[0] = arm1;
    arms[1] = arm2;

    const match = try a.create(parser.Node);
    match.* = .{ .match_stmt = .{ .value = match_val, .arms = arms } };

    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = match;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - variable shadowing errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // const x: i32 = 1
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "i32" };
    const v1 = try a.create(parser.Node);
    v1.* = .{ .int_literal = "1" };
    const var1 = try a.create(parser.Node);
    var1.* = .{ .var_decl = .{ .name = "x", .type_annotation = t1, .value = v1, .is_pub = false, .mutability = .constant } };

    // nested block with const x: i32 = 2 (shadow)
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "i32" };
    const v2 = try a.create(parser.Node);
    v2.* = .{ .int_literal = "2" };
    const var2 = try a.create(parser.Node);
    var2.* = .{ .var_decl = .{ .name = "x", .type_annotation = t2, .value = v2, .is_pub = false, .mutability = .constant } };
    const inner_stmts = try a.alloc(*parser.Node, 1);
    inner_stmts[0] = var2;
    const inner_block = try a.create(parser.Node);
    inner_block.* = .{ .block = .{ .statements = inner_stmts } };

    // if(true) { inner_block }
    const cond = try a.create(parser.Node);
    cond.* = .{ .bool_literal = true };
    const if_stmt = try a.create(parser.Node);
    if_stmt.* = .{ .if_stmt = .{ .condition = cond, .then_block = inner_block, .else_block = null } };

    const stmts = try a.alloc(*parser.Node, 2);
    stmts[0] = var1;
    stmts[1] = if_stmt;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - reference type in var decl errors" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "i32" };
    const ptr_type = try a.create(parser.Node);
    ptr_type.* = .{ .type_ptr = .{ .kind = .const_ref, .elem = elem } };
    const val = try a.create(parser.Node);
    val.* = .{ .int_literal = "0" };
    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{ .name = "x", .type_annotation = ptr_type, .value = val, .is_pub = false, .mutability = .constant } };

    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = var_node;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}

test "resolver - stray @tuple outside anytype arg is rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: @tuple(1, 2)
    const elem1 = try a.create(parser.Node);
    elem1.* = .{ .int_literal = "1" };
    const elem2 = try a.create(parser.Node);
    elem2.* = .{ .int_literal = "2" };
    const elems = try a.alloc(*parser.Node, 2);
    elems[0] = elem1;
    elems[1] = elem2;
    const tuple_node = try a.create(parser.Node);
    tuple_node.* = .{ .tuple_literal = .{ .elements = elems, .names = null } };

    // Build: const _x = @tuple(1, 2)
    const var_decl_node = try a.create(parser.Node);
    var_decl_node.* = .{ .var_decl = .{
        .name = "_x",
        .type_annotation = null,
        .value = tuple_node,
        .is_pub = false,
    } };

    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = var_decl_node;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    var decl_table2 = declarations.DeclTable.init(alloc);
    defer decl_table2.deinit();
    var reporter2 = errors.Reporter.init(alloc, .debug);
    defer reporter2.deinit();
    const ctx2 = sema.SemanticContext.initForTest(alloc, &reporter2, &decl_table2);
    var resolver2 = TypeResolver.init(&ctx2);
    defer resolver2.deinit();
    var tc2 = try TestConv.init(prog);
    defer tc2.deinit();
    tc2.setup(&resolver2);
    try resolver2.resolve(&tc2.conv.store, tc2.root_idx);
    // @tuple outside anytype arg context must produce an error
    try std.testing.expect(reporter2.hasErrors());
}

test "resolver - @tuple accepted when slotted into anytype param" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: @tuple(1, 2, 3)
    const e1 = try a.create(parser.Node);
    e1.* = .{ .int_literal = "1" };
    const e2 = try a.create(parser.Node);
    e2.* = .{ .int_literal = "2" };
    const e3 = try a.create(parser.Node);
    e3.* = .{ .int_literal = "3" };
    const elems = try a.alloc(*parser.Node, 3);
    elems[0] = e1;
    elems[1] = e2;
    elems[2] = e3;
    const tuple_node = try a.create(parser.Node);
    tuple_node.* = .{ .tuple_literal = .{ .elements = elems, .names = null } };

    // Build: fake_zig_fn(@tuple(1, 2, 3))
    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .identifier = "fake_zig_fn" };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = tuple_node;
    const call_node = try a.create(parser.Node);
    call_node.* = .{ .call_expr = .{
        .callee = callee_node,
        .args = call_args,
        .arg_names = &.{},
    } };

    // Wrap in a func body: func test_fn(): void { fake_zig_fn(@tuple(1, 2, 3)) }
    // call_expr nodes are placed directly as statements in blocks (no expr_stmt wrapper).
    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = call_node;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    // Construct a DeclTable with fake_zig_fn having one `any` parameter.
    // `any` maps to RT{ .named = "any" } — how zig_module.zig's "anytype → any" text
    // is classified by types.classifyNamed (not a Primitive, so falls through to .named).
    // Zig validates the final shape; the resolver only needs to permit @tuple here.
    //
    // NOTE: DeclTable.deinit() calls self.allocator.free(sig.params) and
    //       self.allocator.free(sig.param_nodes), so these slices must be allocated
    //       with `alloc` (the DeclTable's main allocator), not the type arena.
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const params = try alloc.alloc(declarations.ParamSig, 1);
    params[0] = .{ .name = "x", .type_ = RT{ .named = "any" } };
    const dummy_param_node = try a.create(parser.Node);
    dummy_param_node.* = .{ .int_literal = "0" }; // placeholder; no default_value needed
    // param_nodes is NOT freed by DeclTable.deinit() — use the arena allocator.
    const param_nodes = try a.alloc(*parser.Node, 1);
    param_nodes[0] = dummy_param_node;
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "void" };
    try decl_table.symbols.put("fake_zig_fn", .{ .func = .{
        .name = "fake_zig_fn",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    } });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    // @tuple inside anytype arg must be accepted — no errors expected
    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - @tuple accepted when slotted into anytype param via field_expr callee" {
    // Tests the module-qualified call path: bitfield.fake_bitfield_fn(@tuple(1, 2, 3))
    // The callee is a field_expr{object: "bitfield", field: "fake_bitfield_fn"}.
    // The resolver must look up fake_bitfield_fn in the "bitfield" module's DeclTable
    // and detect its `any`-typed parameter so that in_anytype_arg is set correctly.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: @tuple(1, 2, 3)
    const e1 = try a.create(parser.Node);
    e1.* = .{ .int_literal = "1" };
    const e2 = try a.create(parser.Node);
    e2.* = .{ .int_literal = "2" };
    const e3 = try a.create(parser.Node);
    e3.* = .{ .int_literal = "3" };
    const elems = try a.alloc(*parser.Node, 3);
    elems[0] = e1;
    elems[1] = e2;
    elems[2] = e3;
    const tuple_node = try a.create(parser.Node);
    tuple_node.* = .{ .tuple_literal = .{ .elements = elems, .names = null } };

    // Build: bitfield.fake_bitfield_fn(@tuple(1, 2, 3))
    const obj_node = try a.create(parser.Node);
    obj_node.* = .{ .identifier = "bitfield" };
    const callee_node = try a.create(parser.Node);
    callee_node.* = .{ .field_expr = .{ .object = obj_node, .field = "fake_bitfield_fn" } };
    const call_args = try a.alloc(*parser.Node, 1);
    call_args[0] = tuple_node;
    const call_node = try a.create(parser.Node);
    call_node.* = .{ .call_expr = .{
        .callee = callee_node,
        .args = call_args,
        .arg_names = &.{},
    } };

    // Wrap in a func body: func test_fn(): void { bitfield.fake_bitfield_fn(@tuple(1, 2, 3)) }
    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = call_node;
    const func_node = try wrapInFunc(a, stmts, "void");
    const top = try a.alloc(*parser.Node, 1);
    top[0] = func_node;
    const prog = try buildTestProgram(a, top);

    // Build the "bitfield" module's DeclTable with fake_bitfield_fn(x: any): void
    const bitfield_ptr = try alloc.create(declarations.DeclTable);
    bitfield_ptr.* = declarations.DeclTable.init(alloc);
    defer {
        bitfield_ptr.deinit();
        alloc.destroy(bitfield_ptr);
    }
    const params = try alloc.alloc(declarations.ParamSig, 1);
    params[0] = .{ .name = "x", .type_ = RT{ .named = "any" } };
    const dummy_param_node = try a.create(parser.Node);
    dummy_param_node.* = .{ .int_literal = "0" };
    const param_nodes = try a.alloc(*parser.Node, 1);
    param_nodes[0] = dummy_param_node;
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "void" };
    try bitfield_ptr.symbols.put("fake_bitfield_fn", .{ .func = .{
        .name = "fake_bitfield_fn",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    } });

    // Build an empty root DeclTable (current module has no top-level funcs here).
    var root_decl = declarations.DeclTable.init(alloc);
    defer root_decl.deinit();

    // Wire up all_decls so the resolver can look up the "bitfield" module.
    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    try all_decls.put("bitfield", bitfield_ptr);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &root_decl,
        .locs = null,
        .file_offsets = &.{},
        .all_decls = &all_decls,
    };
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    var tc = try TestConv.init(prog);
    defer tc.deinit();
    tc.setup(&resolver);
    try resolver.resolve(&tc.conv.store, tc.root_idx);
    // @tuple inside anytype arg (via field_expr callee) must be accepted — no errors expected
    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - duplicate function params rejected" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: func foo(x: i32, x: str) -> void {}
    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const str_type = try a.create(parser.Node);
    str_type.* = .{ .type_named = "str" };
    const p1 = try a.create(parser.Node);
    p1.* = .{ .param = .{ .name = "x", .type_annotation = i32_type } };
    const p2 = try a.create(parser.Node);
    p2.* = .{ .param = .{ .name = "x", .type_annotation = str_type } };
    const params = try a.alloc(*parser.Node, 2);
    params[0] = p1;
    params[1] = p2;

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const body = try a.create(parser.Node);
    body.* = .{ .block = .{ .statements = &.{} } };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "foo",
        .params = params,
        .return_type = ret_type,
        .body = body,
        .context = .normal,
        .is_pub = false,
    } };

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;
    const program = try a.create(parser.Node);
    program.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    } };

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var type_resolver = TypeResolver.init(&ctx);
    defer type_resolver.deinit();
    var tc = try TestConv.init(program);
    defer tc.deinit();
    tc.setup(&type_resolver);
    try type_resolver.resolve(&tc.conv.store, tc.root_idx);
    try std.testing.expect(reporter.hasErrors());
}
