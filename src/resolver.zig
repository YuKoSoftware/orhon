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
const RT = types.ResolvedType;

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

/// The type resolver
pub const TypeResolver = struct {
    ctx: *const sema.SemanticContext,
    type_map: std.AutoHashMapUnmanaged(*parser.Node, RT),
    loop_depth: u32 = 0, // track nesting depth for break/continue validation
    in_is_condition: bool = false, // true while resolving a simple `is` check in if/elif condition
    type_decl_depth: u32 = 0, // track nesting depth for Self validation (structs and enums)
    in_generic_struct: bool = false, // true inside a generic struct (type params on struct)
    current_return_type: ?RT = null, // expected return type of current function
    /// True when resolving an argument expression that will be passed to an
    /// `anytype` parameter of a Zig-backed function. `@tuple(...)` is only
    /// allowed when this flag is set.
    in_anytype_arg: bool = false,
    /// Module names imported with `use` — their types are available unqualified.
    included_modules: std.ArrayListUnmanaged([]const u8) = .{},
    /// Parameter names of the current function — used to detect non-comptime arguments.
    param_names: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(ctx: *const sema.SemanticContext) TypeResolver {
        return .{
            .ctx = ctx,
            .type_map = .{},
        };
    }

    pub fn deinit(self: *TypeResolver) void {
        self.type_map.deinit(self.ctx.allocator);
        self.included_modules.deinit(self.ctx.allocator);
        self.param_names.deinit(self.ctx.allocator);
    }

    /// Check if a name exists in a parent scope within the function boundary.
    /// Walks the parent chain from scope.parent, stopping before the module-level
    /// root scope (parent == null). Used for cross-scope shadowing detection.
    fn lookupInFuncScope(_: *const TypeResolver, scope: *Scope, name: []const u8) bool {
        var s = scope.parent orelse return false;
        while (s.parent != null) : (s = s.parent.?) {
            if (s.vars.contains(name)) return true;
        }
        return false;
    }

    /// Check if a type name exists as a pub declaration in any `use`-d (included) module's DeclTable.
    pub fn isIncludedType(self: *const TypeResolver, name: []const u8) bool {
        const ad = self.ctx.all_decls orelse return false;
        for (self.included_modules.items) |mod_name| {
            if (ad.get(mod_name)) |mod_decls| {
                if (mod_decls.structs.get(name)) |s| { if (s.is_pub) return true; }
                if (mod_decls.enums.get(name)) |e| { if (e.is_pub) return true; }
                if (mod_decls.funcs.get(name)) |f| { if (f.is_pub) return true; }
                // Type aliases don't have is_pub — they are always visible
                if (mod_decls.types.contains(name)) return true;
            }
        }
        return false;
    }

    /// Resolve a type node, treating type alias names as opaque (returns .inferred).
    /// Type aliases are transparent — Zig handles the real type checking at codegen.
    /// Pass scope to also detect local type aliases (declared inside function bodies).
    pub fn resolveTypeAnnotation(self: *TypeResolver, node: *parser.Node) !RT {
        return self.resolveTypeAnnotationInScope(node, null);
    }

    pub fn resolveTypeAnnotationInScope(self: *TypeResolver, node: *parser.Node, scope: ?*Scope) !RT {
        const resolved = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), node);
        if (resolved == .named) {
            // Module-level type alias
            if (self.ctx.decls.types.contains(resolved.named)) return RT.inferred;
            // Local type alias: stored in scope as RT.primitive(.@"type") (since "type" is a Primitive)
            if (scope) |s| {
                if (s.lookup(resolved.named)) |t| {
                    if (t == .primitive and t.primitive == .@"type") return RT.inferred;
                }
            }
        }
        return resolved;
    }

    /// Resolve types in a program AST
    pub fn resolve(self: *TypeResolver, ast: *parser.Node) !void {
        if (ast.* != .program) return;

        // Collect `use`-d module names for unqualified type resolution
        for (ast.program.imports) |imp| {
            if (imp.* == .import_decl and imp.import_decl.is_include) {
                try self.included_modules.append(self.ctx.allocator, imp.import_decl.path);
            }
        }

        var scope = Scope.init(self.ctx.allocator, null);
        defer scope.deinit();

        // First pass: register top-level declarations in scope
        for (ast.program.top_level) |node| {
            try self.registerDecl(node, &scope);
        }

        // Second pass: resolve bodies
        for (ast.program.top_level) |node| {
            try self.resolveNode(node, &scope);
        }
    }

    fn registerDecl(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                const ret_type = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), f.return_type);
                try scope.define(f.name, ret_type);
            },
            .struct_decl => |s| {
                try scope.define(s.name, RT{ .named = s.name });
            },
            .enum_decl => |e| {
                try scope.define(e.name, RT{ .named = e.name });
                for (e.members) |member| {
                    if (member.* == .enum_variant) {
                        try scope.define(member.enum_variant.name, RT{ .named = e.name });
                    }
                }
            },
            .handle_decl => |h| {
                try scope.define(h.name, RT{ .named = h.name });
            },
            .blueprint_decl => |b| {
                try scope.define(b.name, RT{ .named = b.name });
            },
            .var_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try self.resolveTypeAnnotation(ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            else => {},
        }
    }

    pub fn resolveNode(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                var func_scope = Scope.init(self.ctx.allocator, scope);
                defer func_scope.deinit();

                var has_type_param = false;
                for (f.params) |param| {
                    if (param.* == .param) {
                        const is_type_param = param.param.type_annotation.* == .type_named and
                            std.mem.eql(u8, param.param.type_annotation.type_named, "type");
                        if (is_type_param) {
                            has_type_param = true;
                            try func_scope.define(param.param.name, .{ .primitive = .@"type" });
                        } else {
                            try self.validateType(param.param.type_annotation, &func_scope);
                            const t = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), param.param.type_annotation);
                            try func_scope.define(param.param.name, t);
                            // Type-check default value against declared param type
                            if (param.param.default_value) |dv| {
                                const dv_type = try self.resolveExpr(dv, &func_scope);
                                try self.checkAssignCompat(t, dv_type, param);
                            }
                        }
                    }
                }

                // Track parameter names for compt argument validation
                self.param_names.clearRetainingCapacity();
                for (f.params) |param| {
                    if (param.* == .param) {
                        try self.param_names.put(self.ctx.allocator, param.param.name, {});
                    }
                }

                // Validate return type in func_scope so type params (T: type) are visible
                try self.validateType(f.return_type, &func_scope);

                // Check: `any` return type requires at least one `any`-typed parameter
                // Skip for methods inside generic structs — `any` may be a fallback for unmappable types
                if (!self.in_generic_struct and
                    f.return_type.* == .type_named and std.mem.eql(u8, f.return_type.type_named, K.Type.ANY))
                {
                    var has_any_param = false;
                    for (f.params) |param| {
                        if (param.* == .param and param.param.type_annotation.* == .type_named and
                            std.mem.eql(u8, param.param.type_annotation.type_named, K.Type.ANY))
                        {
                            has_any_param = true;
                            break;
                        }
                    }
                    if (!has_any_param) {
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                            "function '{s}' returns 'any' but has no 'any'-typed parameter — return type cannot be determined", .{f.name});
                    }
                }

                const prev_return = self.current_return_type;
                // If function has type params, return type is generic — skip return type checking
                if (has_type_param) {
                    self.current_return_type = .inferred;
                } else {
                    self.current_return_type = try self.resolveTypeAnnotationInScope(f.return_type, &func_scope);
                }
                defer self.current_return_type = prev_return;

                try self.resolveNode(f.body, &func_scope);
            },
            .struct_decl => |s| {
                self.type_decl_depth += 1;
                defer self.type_decl_depth -= 1;
                var struct_scope = Scope.init(self.ctx.allocator, scope);
                defer struct_scope.deinit();
                // Add type params to scope (T: type → T is a known type)
                var has_struct_type_params = false;
                for (s.type_params) |param| {
                    if (param.* == .param) {
                        const is_tp = param.param.type_annotation.* == .type_named and
                            std.mem.eql(u8, param.param.type_annotation.type_named, "type");
                        if (is_tp) {
                            has_struct_type_params = true;
                            try struct_scope.define(param.param.name, .{ .primitive = .@"type" });
                        }
                    }
                }
                const prev_in_generic = self.in_generic_struct;
                if (has_struct_type_params) self.in_generic_struct = true;
                defer self.in_generic_struct = prev_in_generic;
                for (s.members) |member| {
                    try self.resolveNode(member, &struct_scope);
                }
                // Check blueprint conformance
                try self.checkBlueprintConformance(s, self.ctx.nodeLoc(node));
            },
            .blueprint_decl => |b| {
                // Validate method signatures resolve correctly
                var bp_scope = Scope.init(self.ctx.allocator, scope);
                defer bp_scope.deinit();
                // Blueprint name is a valid type within its own methods
                try bp_scope.define(b.name, .{ .primitive = .@"type" });
                for (b.methods) |method| {
                    try self.resolveNode(method, &bp_scope);
                }
            },
            .enum_decl => {},
            .handle_decl => {},
            .block => |b| {
                var block_scope = Scope.init(self.ctx.allocator, scope);
                defer block_scope.deinit();
                var found_exit = false;
                for (b.statements) |stmt| {
                    if (found_exit) {
                        try self.ctx.reporter.warn(.{
                            .message = "unreachable code",
                            .loc = self.ctx.nodeLoc(stmt),
                        });
                        // Only warn once per block, but keep resolving for other diagnostics
                        found_exit = false;
                    }
                    try self.resolveStatement(stmt, &block_scope);
                    if (parser.blockHasEarlyExit(stmt)) found_exit = true;
                }
            },
            .var_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                    // Reference types (const& T, mut& T) are only valid in function parameters
                    if (t.* == .type_ptr) {
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "reference type not allowed in variable declaration — use '{s}' by value or as a function parameter",
                            .{v.name});
                    }
                }
                // Duplicate/shadowing check (only inside functions/blocks, not top-level)
                if (scope.parent != null) {
                    if (scope.vars.contains(v.name)) {
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "variable '{s}' already declared in this scope", .{v.name});
                    } else if (self.lookupInFuncScope(scope, v.name)) {
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "variable '{s}' shadows a declaration in an outer scope — shadowing is not allowed", .{v.name});
                    }
                }
                {
                    const val_type = try self.resolveExpr(v.value, scope);
                    const resolved = if (v.type_annotation) |t|
                        try self.resolveTypeAnnotationInScope(t, scope)
                    else
                        val_type;
                    if (v.type_annotation == null) {
                        if (val_type == .primitive and
                            (val_type.primitive == .numeric_literal or
                            val_type.primitive == .float_literal))
                        {
                            try self.ctx.reporter.report(.{
                                .message = "numeric literal requires explicit type — use 'const x: i32 = 42'",
                                .loc = self.ctx.nodeLoc(node),
                            });
                        }
                    } else {
                        try self.checkAssignCompat(resolved, val_type, node);
                    }
                    try scope.define(v.name, resolved);
                }
            },
            .field_decl => |f| {
                // Validate field type annotation
                try self.validateType(f.type_annotation, scope);
                // 'any' is not valid as a struct field type
                if (f.type_annotation.* == .type_named and std.mem.eql(u8, f.type_annotation.type_named, K.Type.ANY)) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "'any' is not valid as a struct field type — use a type parameter instead", .{});
                }
                // Type-check default value against declared type
                if (f.default_value) |dv| {
                    const field_type = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), f.type_annotation);
                    const val_type = try self.resolveExpr(dv, scope);
                    try self.checkAssignCompat(field_type, val_type, node);
                }
            },
            .test_decl => |t| {
                const prev_return = self.current_return_type;
                self.current_return_type = null;
                defer self.current_return_type = prev_return;
                try self.resolveNode(t.body, scope);
            },
            else => {},
        }
    }

    pub fn resolveStatement(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .var_decl => try self.resolveNode(node, scope),
            .return_stmt => |r| {
                if (r.value) |v| {
                    const val_type = try self.resolveExpr(v, scope);
                    // Check return type matches function signature
                    if (self.current_return_type) |expected| {
                        if (expected != .unknown and expected != .inferred and
                            val_type != .unknown and val_type != .inferred and
                            !typesCompatible(val_type, expected))
                        {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "return type mismatch: expected '{s}', got '{s}'",
                                .{ expected.name(), val_type.name() });
                        }
                    }
                }
            },
            .if_stmt => |i| {
                // Validate `is` usage in condition
                if (isIsCheck(i.condition)) {
                    // Simple `is` — valid. Set flag so compiler_func("type") is allowed.
                    self.in_is_condition = true;
                } else if (containsIsCheck(i.condition)) {
                    // Compound `is` (e.g. `if(x is T and y is U)`) — reject.
                    // Set flag to suppress secondary "is outside if" errors on the inner checks.
                    self.in_is_condition = true;
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "compound 'is' not supported — use nested if statements for multiple type checks", .{});
                }
                const cond_type = try self.resolveExpr(i.condition, scope);
                self.in_is_condition = false;
                if (cond_type != .unknown and cond_type != .inferred and
                    !(cond_type == .primitive and cond_type.primitive == .bool))
                {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "type mismatch in if condition: expected bool, got '{s}'", .{cond_type.name()});
                }
                try self.resolveNode(i.then_block, scope);
                if (i.else_block) |e| try self.resolveNode(e, scope);
            },
            .while_stmt => |w| {
                const cond_type = try self.resolveExpr(w.condition, scope);
                if (cond_type != .unknown and cond_type != .inferred and
                    !(cond_type == .primitive and cond_type.primitive == .bool))
                {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "type mismatch in while condition: expected bool, got '{s}'", .{cond_type.name()});
                }
                if (w.continue_expr) |c| _ = try self.resolveExpr(c, scope);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.resolveNode(w.body, scope);
            },
            .for_stmt => |f| {
                var for_scope = Scope.init(self.ctx.allocator, scope);
                defer for_scope.deinit();

                // Resolve all iterables
                var iter_types = std.ArrayListUnmanaged(RT){};
                defer iter_types.deinit(self.ctx.allocator);
                for (f.iterables) |iter| {
                    const t = try self.resolveExpr(iter, scope);
                    try iter_types.append(self.ctx.allocator, t);
                }

                if (f.is_tuple_capture) {
                    // Tuple capture — first iterable provides struct fields, rest are extra captures
                    const first_type = if (iter_types.items.len > 0) iter_types.items[0] else RT.inferred;
                    const capture_type = if (f.iterables.len > 0) inferCaptureType(f.iterables[0], first_type) else RT.inferred;
                    const extra_iterables = if (iter_types.items.len > 1) iter_types.items.len - 1 else 0;
                    const type_name = capture_type.name();
                    const struct_sig = self.ctx.decls.structs.get(type_name);

                    if (capture_type == .inferred or capture_type == .unknown) {
                        for (f.captures) |v| try for_scope.define(v, RT.inferred);
                    } else if (struct_sig) |sig| {
                        const expected = sig.fields.len + extra_iterables;
                        if (f.captures.len != expected) {
                            try self.ctx.reporter.reportFmt(
                                self.ctx.nodeLoc(node),
                                "tuple capture count ({d}) does not match struct '{s}' field count ({d}){s}",
                                .{ f.captures.len, type_name, sig.fields.len, if (extra_iterables > 0) " plus extra iterables" else "" },
                            );
                            for (f.captures) |v| try for_scope.define(v, RT.inferred);
                        } else {
                            // Struct field captures
                            for (f.captures[0..sig.fields.len], sig.fields) |v, field| {
                                try for_scope.define(v, field.type_);
                            }
                            // Extra captures from additional iterables (e.g., 0.. → usize)
                            for (f.captures[sig.fields.len..], iter_types.items[1..]) |v, it| {
                                const et = if (f.iterables.len > 1) inferCaptureType(f.iterables[1], it) else RT.inferred;
                                try for_scope.define(v, et);
                            }
                        }
                    } else {
                        try self.ctx.reporter.reportFmt(
                            self.ctx.nodeLoc(node),
                            "tuple capture requires a struct element type, got '{s}'",
                            .{type_name},
                        );
                        for (f.captures) |v| try for_scope.define(v, RT.inferred);
                    }
                } else {
                    // Non-tuple: each capture maps 1:1 to an iterable
                    if (f.captures.len != f.iterables.len) {
                        try self.ctx.reporter.reportFmt(
                            self.ctx.nodeLoc(node),
                            "for loop has {d} iterable(s) but {d} capture(s)",
                            .{ f.iterables.len, f.captures.len },
                        );
                        for (f.captures) |v| try for_scope.define(v, RT.inferred);
                    } else {
                        for (f.captures, f.iterables, iter_types.items) |v, iter, it| {
                            try for_scope.define(v, inferCaptureType(iter, it));
                        }
                    }
                }

                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.resolveNode(f.body, &for_scope);
            },
            .match_stmt => |m| {
                const match_type = try self.resolveExpr(m.value, scope);
                var has_else = false;
                var has_guard = false;
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        const ma = arm.match_arm;
                        const pat = ma.pattern;
                        // Check for else arm — must be last
                        if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                            if (has_else) {
                                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(arm), "duplicate 'else' arm in match statement", .{});
                            }
                            has_else = true;
                        } else if (has_else) {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(arm), "'else' arm must be the last arm in a match statement", .{});
                        }
                        // Validate union match arm patterns
                        if (pat.* == .identifier and !std.mem.eql(u8, pat.identifier, "else")) {
                            try self.validateMatchArm(pat.identifier, match_type, arm);
                        }
                        // Skip resolveExpr for identifier patterns — they are enum variants,
                        // 'else', or guard-bound variables, not expressions in scope.
                        if (pat.* != .identifier) _ = try self.resolveExpr(pat, scope);
                        // Resolve guard expression in a child scope that includes the bound
                        // variable. The bound variable (e.g. 'x' in '(x if x > 0)') has
                        // the same type as the match value. Without this child scope,
                        // resolving 'x > 0' would fail because 'x' is not in the enclosing scope.
                        if (ma.guard) |g| {
                            has_guard = true;
                            var guard_scope = Scope.init(self.ctx.allocator, scope);
                            defer guard_scope.deinit();
                            if (pat.* == .identifier) {
                                try guard_scope.define(pat.identifier, match_type);
                            }
                            _ = try self.resolveExpr(g, &guard_scope);
                            // Body of a guarded arm can use the bound variable — resolve with guard_scope
                            try self.resolveNode(ma.body, &guard_scope);
                        } else {
                            try self.resolveNode(ma.body, scope);
                        }
                    }
                }
                // Guards require else arm for exhaustiveness — guards don't guarantee coverage
                if (has_guard and !has_else) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "match with guards requires an 'else' arm", .{});
                }
                // Check exhaustiveness for union matches
                if (!has_else) {
                    try self.checkMatchExhaustiveness(match_type, m.arms, node);
                }
            },
            .assignment => |a| {
                const left = try self.resolveExpr(a.left, scope);
                const right = try self.resolveExpr(a.right, scope);
                // Mixed numeric check for compound assignments (+=, -=, *=, /=)
                if (a.op != .assign) {
                    if (left == .primitive and right == .primitive) {
                        const lp = left.primitive;
                        const rp = right.primitive;
                        if (lp.isNumeric() and rp.isNumeric() and
                            lp != .numeric_literal and rp != .numeric_literal and
                            lp != .float_literal and rp != .float_literal and
                            lp != rp)
                        {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                                "cannot mix {s} and {s} in compound assignment — use @cast({s}, x) to convert",
                                .{ lp.toName(), rp.toName(), lp.toName() });
                        }
                    }
                }
            },
            .defer_stmt => |d| try self.resolveNode(d.body, scope),
            .destruct_decl => |d| {
                _ = try self.resolveExpr(d.value, scope);
                for (d.names) |name| {
                    if (scope.parent != null) {
                        if (scope.vars.contains(name)) {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "variable '{s}' already declared in this scope", .{name});
                        } else if (self.lookupInFuncScope(scope, name)) {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "variable '{s}' shadows a declaration in an outer scope — shadowing is not allowed", .{name});
                        }
                    }
                    try scope.define(name, RT.inferred);
                }
            },
            .break_stmt => {
                if (self.loop_depth == 0) {
                    try self.ctx.reporter.report(.{
                        .message = "'break' outside of loop",
                        .loc = self.ctx.nodeLoc(node),
                    });
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    try self.ctx.reporter.report(.{
                        .message = "'continue' outside of loop",
                        .loc = self.ctx.nodeLoc(node),
                    });
                }
            },
            .block => try self.resolveNode(node, scope),
            else => _ = try self.resolveExpr(node, scope),
        }
    }

    /// Resolve an expression and return its ResolvedType
    pub fn resolveExpr(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!RT {
        return exprs_impl.resolveExpr(self, node, scope);
    }

    pub fn checkMatchExhaustiveness(self: *TypeResolver, match_type: RT, arms: []*parser.Node, match_node: *parser.Node) !void {
        return validation_impl.checkMatchExhaustiveness(self, match_type, arms, match_node);
    }

    pub fn validateMatchArm(self: *TypeResolver, pattern_name: []const u8, match_type: RT, arm_node: *parser.Node) !void {
        return validation_impl.validateMatchArm(self, pattern_name, match_type, arm_node);
    }

    pub fn validateType(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        return validation_impl.validateType(self, node, scope);
    }

    pub fn checkAssignCompat(self: *TypeResolver, expected: RT, actual: RT, node: *parser.Node) !void {
        return validation_impl.checkAssignCompat(self, expected, actual, node);
    }

    /// Returns true if `name` is a variant of any declared enum.
    /// Used to suppress false "unknown identifier" errors for enum variants used as match patterns.
    pub fn isEnumVariant(self: *const TypeResolver, name: []const u8) bool {
        var enum_it = self.ctx.decls.enums.valueIterator();
        while (enum_it.next()) |sig| {
            for (sig.variants) |v| {
                if (std.mem.eql(u8, v, name)) return true;
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

/// Infer the element type for for-loop captures from the iterable.
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

/// Check if a resolved type looks like a generic type parameter (e.g. T, V, Key).
/// Heuristic: named type starting with uppercase, length <= 4.
pub fn isTypeParam(t: RT) bool {
    // A type param is a .named type that isn't a known primitive and looks like a param name.
    // Type params defined via T: type get stored as .primitive = "type" in scope,
    // but field types referencing T resolve as .named = "T" since T isn't a declared struct.
    if (t != .named) return false;
    const n = t.named;
    // Single uppercase letter or short uppercase name — likely a type param
    if (n.len == 0) return false;
    if (n[0] >= 'A' and n[0] <= 'Z' and n.len <= 4) return true;
    return false;
}

pub fn typesCompatible(a: RT, b: RT) bool {
    const a_name = a.name();
    const b_name = b.name();
    if (a_name.len > 0 and b_name.len > 0 and std.mem.eql(u8, a_name, b_name)) return true;
    // Unresolved type params are compatible with anything — resolved at compile time by Zig
    if (isTypeParam(a) or isTypeParam(b)) return true;
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
    return std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE);
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

    try type_resolver.resolve(program);

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

    try decl_table.funcs.put("add", .{
        .name = "add",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .i32 },
        .context = .normal,
        .is_pub = false,
        .is_instance = false,
    });

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

    const result = try resolver.resolveExpr(call, &scope);
    try std.testing.expectEqualStrings("i32", result.name());
}

test "resolver - struct field type resolves" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 2);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    try decl_table.structs.put("Point", .{
        .name = "Point",
        .fields = fields,
        .is_pub = true,
    });

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

    const result = try resolver.resolveExpr(field_node, &scope);
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

    try resolver.resolveNode(decl, &scope);
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

    const result = try resolver.resolveExpr(cast_node, &scope);
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

    const result = try resolver.resolveExpr(copy_node, &scope);
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

    const result = try resolver.resolveExpr(assert_node, &scope);
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
    try decl_table.structs.put("Point", .{ .name = "Point", .fields = fields, .is_pub = true });

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

    const result = try resolver.resolveExpr(call, &scope);
    try std.testing.expectEqualStrings("Point", result.name());
    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - positional struct constructor rejected" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 1);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .i32 }, .has_default = false, .is_pub = true };
    try decl_table.structs.put("Point", .{ .name = "Point", .fields = fields, .is_pub = true });

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

    const result = try resolver.resolveExpr(call, &scope);
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

    try resolver.validateType(generic_node, &scope);
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

    const result = try resolver.resolveExpr(arr, &scope);
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

    try resolver.validateType(generic_node, &scope);
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

test "typesCompatible - type param compatible with anything" {
    try std.testing.expect(typesCompatible(RT{ .named = "T" }, RT{ .primitive = .i32 }));
    try std.testing.expect(typesCompatible(RT{ .primitive = .string }, RT{ .named = "V" }));
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

test "isTypeParam - single uppercase letter" {
    try std.testing.expect(isTypeParam(RT{ .named = "T" }));
    try std.testing.expect(isTypeParam(RT{ .named = "V" }));
    try std.testing.expect(isTypeParam(RT{ .named = "Key" }));
}

test "isTypeParam - rejects non-type-params" {
    try std.testing.expect(!isTypeParam(RT{ .named = "point" })); // lowercase
    try std.testing.expect(!isTypeParam(RT{ .named = "Player" })); // too long
    try std.testing.expect(!isTypeParam(RT{ .primitive = .i32 })); // not named
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
    try math_decls.structs.put("Vec2", .{
        .name = "Vec2",
        .fields = &.{},
        .is_pub = true,
    });

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

    try resolver.validateType(generic_node, &scope);
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
    try resolver.resolve(prog);
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
    try resolver.resolve(prog);
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
    try resolver.resolve(prog);
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
    try resolver.resolve(prog);
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
    try resolver.resolve(prog);
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
    try resolver.resolve(prog);
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
    try resolver2.resolve(prog);
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
    try decl_table.funcs.put("fake_zig_fn", .{
        .name = "fake_zig_fn",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var resolver = TypeResolver.init(&ctx);
    defer resolver.deinit();
    try resolver.resolve(prog);
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
    try bitfield_ptr.funcs.put("fake_bitfield_fn", .{
        .name = "fake_bitfield_fn",
        .params = params,
        .param_nodes = param_nodes,
        .return_type = RT{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    });

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
    try resolver.resolve(prog);
    // @tuple inside anytype arg (via field_expr callee) must be accepted — no errors expected
    try std.testing.expect(!reporter.hasErrors());
}
