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
const K = @import("constants.zig");
const types = @import("types.zig");

const RT = types.ResolvedType;

/// Primitive type name candidates for "did you mean?" suggestions on unknown types.
const PRIMITIVE_NAMES = [_][]const u8{
    "i8", "i16", "i32", "i64",
    "u8", "u16", "u32", "u64",
    "f32", "f64",
    "bool", "usize", "void",
};

/// A resolved type binding — maps expression nodes to their resolved types
pub const TypeBinding = struct {
    node: *parser.Node,
    resolved_type: RT,
};

/// Scope for variable type tracking
pub const Scope = struct {
    vars: std.StringHashMap(RT),
    parent: ?*Scope,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .vars = std.StringHashMap(RT).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.vars.deinit();
    }

    pub fn lookup(self: *const Scope, name_str: []const u8) ?RT {
        if (self.vars.get(name_str)) |t| return t;
        if (self.parent) |p| return p.lookup(name_str);
        return null;
    }

    pub fn define(self: *Scope, name_str: []const u8, t: RT) !void {
        try self.vars.put(name_str, t);
    }
};

/// The type resolver
pub const TypeResolver = struct {
    decls: *declarations.DeclTable,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(TypeBinding),
    type_map: std.AutoHashMapUnmanaged(*parser.Node, RT),
    locs: ?*const parser.LocMap = null,
    file_offsets: []const module.FileOffset = &.{},
    loop_depth: u32 = 0, // track nesting depth for break/continue validation
    current_return_type: ?RT = null, // expected return type of current function
    /// All module DeclTables — for cross-module qualified generic type validation.
    all_decls: ?*const std.StringHashMap(*declarations.DeclTable) = null,

    pub fn init(
        allocator: std.mem.Allocator,
        decls: *declarations.DeclTable,
        reporter: *errors.Reporter,
    ) TypeResolver {
        return .{
            .decls = decls,
            .reporter = reporter,
            .allocator = allocator,
            .bindings = .{},
            .type_map = .{},
        };
    }

    fn nodeLoc(self: *const TypeResolver, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                const resolved = module.resolveFileLoc(self.file_offsets, loc.line);
                return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn deinit(self: *TypeResolver) void {
        self.bindings.deinit(self.allocator);
        self.type_map.deinit(self.allocator);
    }

    /// Resolve a type node, treating type alias names as opaque (returns .inferred).
    /// Type aliases are transparent — Zig handles the real type checking at codegen.
    /// Pass scope to also detect local type aliases (declared inside function bodies).
    fn resolveTypeAnnotation(self: *TypeResolver, node: *parser.Node) !RT {
        return self.resolveTypeAnnotationInScope(node, null);
    }

    fn resolveTypeAnnotationInScope(self: *TypeResolver, node: *parser.Node, scope: ?*Scope) !RT {
        const resolved = try types.resolveTypeNode(self.decls.typeAllocator(), node);
        if (resolved == .named) {
            // Module-level type alias
            if (self.decls.types.contains(resolved.named)) return RT.inferred;
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

        var scope = Scope.init(self.allocator, null);
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
                const ret_type = try types.resolveTypeNode(self.decls.typeAllocator(), f.return_type);
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
            .bitfield_decl => |b| {
                try scope.define(b.name, RT{ .named = b.name });
                for (b.members) |flag_name| {
                    try scope.define(flag_name, RT{ .named = b.name });
                }
            },
            .const_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try self.resolveTypeAnnotation(ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            .var_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try self.resolveTypeAnnotation(ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            .compt_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try self.resolveTypeAnnotation(ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            else => {},
        }
    }

    fn resolveNode(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                var func_scope = Scope.init(self.allocator, scope);
                defer func_scope.deinit();

                // Bridge safety: bridge funcs cannot accept mutable refs (&T)
                // Exception: self param on bridge struct methods (Zig mutates its own data)
                if (f.is_bridge) {
                    for (f.params) |param| {
                        if (param.* == .param) {
                            const ta = param.param.type_annotation;
                            if (ta.* == .type_ptr and std.mem.eql(u8, ta.type_ptr.kind, K.Ptr.VAR_REF)) {
                                // Allow self: &StructName on bridge struct methods
                                if (std.mem.eql(u8, param.param.name, "self")) continue;
                                const msg = try std.fmt.allocPrint(self.allocator,
                                    "mutable reference '&{s}' not allowed across bridge — use 'const &{s}' or pass by value",
                                    .{ param.param.name, param.param.name });
                                defer self.allocator.free(msg);
                                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                            }
                        }
                    }
                    // Bridge safety: bridge funcs cannot return mutable refs
                    if (f.return_type.* == .type_ptr and
                        std.mem.eql(u8, f.return_type.type_ptr.kind, K.Ptr.VAR_REF))
                    {
                        try self.reporter.report(.{
                            .message = "mutable reference return not allowed across bridge — return by value or const &",
                            .loc = self.nodeLoc(node),
                        });
                    }
                }

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
                            const t = try types.resolveTypeNode(self.decls.typeAllocator(), param.param.type_annotation);
                            try func_scope.define(param.param.name, t);
                        }
                    }
                }

                // Validate return type in func_scope so type params (T: type) are visible
                try self.validateType(f.return_type, &func_scope);
                const prev_return = self.current_return_type;
                // If function has type params, return type is generic — skip return type checking
                if (has_type_param) {
                    self.current_return_type = .inferred;
                } else {
                    self.current_return_type = try types.resolveTypeNode(self.decls.typeAllocator(), f.return_type);
                }
                defer self.current_return_type = prev_return;

                try self.resolveNode(f.body, &func_scope);
            },
            .struct_decl => |s| {
                var struct_scope = Scope.init(self.allocator, scope);
                defer struct_scope.deinit();
                // Add type params to scope (T: type → T is a known type)
                for (s.type_params) |param| {
                    if (param.* == .param) {
                        const is_tp = param.param.type_annotation.* == .type_named and
                            std.mem.eql(u8, param.param.type_annotation.type_named, "type");
                        if (is_tp) {
                            try struct_scope.define(param.param.name, .{ .primitive = .@"type" });
                        }
                    }
                }
                for (s.members) |member| {
                    try self.resolveNode(member, &struct_scope);
                }
            },
            .enum_decl => |e| {
                var enum_scope = Scope.init(self.allocator, scope);
                defer enum_scope.deinit();
                for (e.members) |member| {
                    if (member.* == .func_decl) try self.resolveNode(member, &enum_scope);
                }
            },
            .block => |b| {
                var block_scope = Scope.init(self.allocator, scope);
                defer block_scope.deinit();
                for (b.statements) |stmt| {
                    try self.resolveStatement(stmt, &block_scope);
                }
            },
            .var_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                }
                // Duplicate variable check (only inside functions/blocks, not top-level)
                if (scope.parent != null and scope.vars.contains(v.name)) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "variable '{s}' already declared in this scope", .{v.name});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
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
                        try self.reporter.report(.{
                            .message = "numeric literal requires explicit type",
                            .loc = self.nodeLoc(node),
                        });
                    }
                } else {
                    // Type mismatch: annotation vs value
                    try self.checkAssignCompat(resolved, val_type, node);
                }
                try scope.define(v.name, resolved);
            },
            .const_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                }
                if (scope.parent != null and scope.vars.contains(v.name)) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "variable '{s}' already declared in this scope", .{v.name});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                // bridge consts have no value — skip value type checking
                if (v.is_bridge) {
                    const resolved = if (v.type_annotation) |t|
                        try self.resolveTypeAnnotationInScope(t, scope)
                    else
                        RT.inferred;
                    try scope.define(v.name, resolved);
                } else {
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
                            try self.reporter.report(.{
                                .message = "numeric literal requires explicit type",
                                .loc = self.nodeLoc(node),
                            });
                        }
                    } else {
                        try self.checkAssignCompat(resolved, val_type, node);
                    }
                    try scope.define(v.name, resolved);
                }
            },
            .compt_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                }
                const val_type = try self.resolveExpr(v.value, scope);
                const resolved = if (v.type_annotation) |t|
                    try self.resolveTypeAnnotationInScope(t, scope)
                else
                    val_type;
                try scope.define(v.name, resolved);
            },
            else => {},
        }
    }

    fn resolveStatement(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl, .compt_decl => try self.resolveNode(node, scope),
            .return_stmt => |r| {
                if (r.value) |v| {
                    const val_type = try self.resolveExpr(v, scope);
                    // Check return type matches function signature
                    if (self.current_return_type) |expected| {
                        if (expected != .unknown and expected != .inferred and
                            val_type != .unknown and val_type != .inferred and
                            !typesCompatible(val_type, expected))
                        {
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "return type mismatch: expected '{s}', got '{s}'",
                                .{ expected.name(), val_type.name() });
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                        }
                    }
                }
            },
            .if_stmt => |i| {
                const cond_type = try self.resolveExpr(i.condition, scope);
                if (cond_type == .primitive and cond_type.primitive != .bool and
                    cond_type != .unknown and cond_type != .inferred)
                {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "type mismatch in if condition: expected bool, got '{s}'", .{cond_type.name()});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                try self.resolveNode(i.then_block, scope);
                if (i.else_block) |e| try self.resolveNode(e, scope);
            },
            .while_stmt => |w| {
                const cond_type = try self.resolveExpr(w.condition, scope);
                if (cond_type == .primitive and cond_type.primitive != .bool and
                    cond_type != .unknown and cond_type != .inferred)
                {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "type mismatch in while condition: expected bool, got '{s}'", .{cond_type.name()});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                if (w.continue_expr) |c| _ = try self.resolveExpr(c, scope);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.resolveNode(w.body, scope);
            },
            .for_stmt => |f| {
                const iter_type = try self.resolveExpr(f.iterable, scope);
                var for_scope = Scope.init(self.allocator, scope);
                defer for_scope.deinit();
                // Infer capture type from iterable
                const capture_type = inferCaptureType(f.iterable, iter_type);
                for (f.captures) |v| try for_scope.define(v, capture_type);
                if (f.index_var) |idx| try for_scope.define(idx, RT{ .primitive = .usize });
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
                        // Check for else arm
                        if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                            has_else = true;
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
                            var guard_scope = Scope.init(self.allocator, scope);
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
                    const msg = try std.fmt.allocPrint(self.allocator, "match with guards requires an 'else' arm", .{});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                // Check exhaustiveness for union matches
                if (!has_else) {
                    try self.checkMatchExhaustiveness(match_type, m.arms, node);
                }
            },
            .assignment => |a| {
                _ = try self.resolveExpr(a.left, scope);
                _ = try self.resolveExpr(a.right, scope);
            },
            .defer_stmt => |d| try self.resolveNode(d.body, scope),
            .destruct_decl => |d| {
                _ = try self.resolveExpr(d.value, scope);
                for (d.names) |name| try scope.define(name, RT.inferred);
            },
            .break_stmt => {
                if (self.loop_depth == 0) {
                    try self.reporter.report(.{
                        .message = "'break' outside of loop",
                        .loc = self.nodeLoc(node),
                    });
                }
            },
            .continue_stmt => {
                if (self.loop_depth == 0) {
                    try self.reporter.report(.{
                        .message = "'continue' outside of loop",
                        .loc = self.nodeLoc(node),
                    });
                }
            },
            .block => try self.resolveNode(node, scope),
            else => _ = try self.resolveExpr(node, scope),
        }
    }

    /// Resolve an expression and return its ResolvedType
    fn resolveExpr(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!RT {
        const result = try self.resolveExprInner(node, scope);
        try self.type_map.put(self.allocator, node, result);
        return result;
    }

    fn resolveExprInner(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!RT {
        return switch (node.*) {
            .int_literal => RT{ .primitive = .numeric_literal },
            .float_literal => RT{ .primitive = .float_literal },
            .string_literal => RT{ .primitive = .string },
            .interpolated_string => |interp| {
                // Resolve inner expressions so they appear in type_map
                for (interp.parts) |part| {
                    switch (part) {
                        .expr => |expr_node| _ = try self.resolveExpr(expr_node, scope),
                        .literal => {},
                    }
                }
                return RT{ .primitive = .string };
            },
            .bool_literal => RT{ .primitive = .bool },
            .null_literal => RT.null_type,
            .error_literal => RT.err,

            .identifier => |id_name| {
                if (scope.lookup(id_name)) |t| return t;
                if (self.decls.funcs.get(id_name)) |sig| return sig.return_type;
                if (self.decls.structs.contains(id_name)) return RT{ .named = id_name };
                if (self.decls.enums.contains(id_name)) return RT{ .named = id_name };
                if (self.decls.vars.get(id_name)) |v| return v.type_ orelse RT.unknown;
                if (builtins.isBuiltinType(id_name)) return RT{ .named = id_name };
                if (builtins.isBuiltinValue(id_name)) return RT{ .named = id_name };
                // Primitive type names (i32, f64, etc.) may appear as arguments to cast() and similar
                if (types.isPrimitiveName(id_name)) return RT{ .named = id_name };
                // Compiler-intrinsic functions are resolved by codegen, not tracked in decls
                if (builtins.isCompilerFunc(id_name)) return RT{ .named = id_name };
                // Arithmetic mode functions (wrap, sat, overflow) are codegen-level intrinsics
                if (std.mem.eql(u8, id_name, "wrap") or
                    std.mem.eql(u8, id_name, "sat") or
                    std.mem.eql(u8, id_name, "overflow")) return RT.unknown;
                // Known module names — used as qualified access prefixes (module.Type, module.func)
                if (self.all_decls) |ad| {
                    if (ad.contains(id_name)) return RT.unknown;
                }

                // Enum variants, bitfield flags, and the 'else' match pattern are used as bare
                // identifiers in match patterns. They are not in the scope chain — silently
                // return unknown to avoid false errors.
                if (std.mem.eql(u8, id_name, "else")) return RT.unknown;
                if (self.isEnumVariantOrBitfieldFlag(id_name)) return RT.unknown;

                // Build candidate list from scope chain + module declarations for suggestion
                var candidates: std.ArrayListUnmanaged([]const u8) = .{};
                defer candidates.deinit(self.allocator);
                var sc: ?*const Scope = scope;
                while (sc) |s| : (sc = s.parent) {
                    var it = s.vars.keyIterator();
                    while (it.next()) |k| try candidates.append(self.allocator, k.*);
                }
                var fit = self.decls.funcs.keyIterator();
                while (fit.next()) |k| try candidates.append(self.allocator, k.*);
                var sit = self.decls.structs.keyIterator();
                while (sit.next()) |k| try candidates.append(self.allocator, k.*);
                var eit = self.decls.enums.keyIterator();
                while (eit.next()) |k| try candidates.append(self.allocator, k.*);
                var vit = self.decls.vars.keyIterator();
                while (vit.next()) |k| try candidates.append(self.allocator, k.*);

                const suggestion = try errors.formatSuggestion(id_name, candidates.items, self.allocator);
                defer if (suggestion) |s| self.allocator.free(s);
                const msg = try std.fmt.allocPrint(self.allocator,
                    "unknown identifier '{s}'{s}", .{ id_name, suggestion orelse "" });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                return RT.unknown;
            },

            .binary_expr => |b| {
                const left = try self.resolveExpr(b.left, scope);
                _ = try self.resolveExpr(b.right, scope);
                if (std.mem.eql(u8, b.op, "and") or
                    std.mem.eql(u8, b.op, "or") or
                    std.mem.eql(u8, b.op, "==") or
                    std.mem.eql(u8, b.op, "!=") or
                    std.mem.eql(u8, b.op, "<") or
                    std.mem.eql(u8, b.op, ">") or
                    std.mem.eql(u8, b.op, "<=") or
                    std.mem.eql(u8, b.op, ">=")) return RT{ .primitive = .bool };
                if (std.mem.eql(u8, b.op, "++")) return left;
                return left;
            },

            .unary_expr => |u| try self.resolveExpr(u.operand, scope),
            .borrow_expr => |b| try self.resolveExpr(b, scope),

            .call_expr => |c| {
                const callee_type = try self.resolveExpr(c.callee, scope);
                // Resolve arg types and check for String/[]u8 coercion
                var arg_types_buf: [16]RT = undefined;
                const arg_count = @min(c.args.len, 16);
                for (c.args, 0..) |arg, idx| {
                    const at = try self.resolveExpr(arg, scope);
                    if (idx < 16) arg_types_buf[idx] = at;
                }
                // Check args against function signature — reject []u8 → String
                try self.checkByteSliceStringCoercion(c, arg_types_buf[0..arg_count], node);

                if (c.callee.* == .identifier) {
                    const name = c.callee.identifier;
                    // Struct constructor: Player(...) → Player
                    if (self.decls.structs.contains(name)) return RT{ .named = name };
                    // Builtin generic constructor: List(i32)(...) → List(i32)
                    if (builtins.isBuiltinType(name)) return RT{ .named = name };
                    if (scope.lookup(name)) |t| {
                        if (t == .func_ptr) {
                            // Function pointer call — OK
                        } else if (!self.decls.funcs.contains(name) and
                            !self.decls.structs.contains(name) and
                            !self.decls.enums.contains(name) and
                            !self.decls.bitfields.contains(name) and
                            !builtins.isBuiltinType(name))
                        {
                            // Non-callable variable
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "'{s}' is not callable — expected a function or constructor", .{name});
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                            return t;
                        }
                    }
                    if (self.decls.funcs.get(name)) |sig| {
                        return sig.return_type;
                    }
                }
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        const obj_id = fe.object.identifier;
                        // Module-level function: module.func()
                        if (self.decls.funcs.get(fe.field)) |sig| {
                            return sig.return_type;
                        }
                        // Static or instance method on a bridge struct.
                        // obj_id may be the struct type name (static: Renderer.create())
                        // or a variable whose type is a struct (instance: r.draw(m)).
                        const struct_name: []const u8 = blk: {
                            if (self.decls.structs.contains(obj_id)) break :blk obj_id;
                            if (scope.lookup(obj_id)) |var_type| {
                                // Unwrap error_union and null_union to get the underlying named type
                                if (var_type == .named) break :blk var_type.named;
                                if (var_type == .error_union) {
                                    if (var_type.error_union.* == .named) break :blk var_type.error_union.named;
                                }
                                if (var_type == .null_union) {
                                    if (var_type.null_union.* == .named) break :blk var_type.null_union.named;
                                }
                            }
                            break :blk "";
                        };
                        if (struct_name.len > 0) {
                            // Build "StructName.method" key and look in struct_methods
                            const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ struct_name, fe.field }) catch "";
                            defer if (key.len > 0) self.allocator.free(key);
                            if (key.len > 0) {
                                if (self.decls.struct_methods.get(key)) |sig| return sig.return_type;
                                // Cross-module: check all loaded module decls
                                if (self.all_decls) |ad| {
                                    if (ad.get(obj_id)) |mod_decls| {
                                        if (mod_decls.struct_methods.get(key)) |sig| return sig.return_type;
                                    }
                                    var it = ad.iterator();
                                    while (it.next()) |entry| {
                                        if (entry.value_ptr.*.struct_methods.get(key)) |sig| return sig.return_type;
                                    }
                                }
                            }
                        }
                    }
                    // Cross-module static method: module.Type.method(args) — e.g. tamga_vk3d.Renderer.create()
                    // callee is field_expr{object: field_expr{object: module_id, field: TypeName}, field: method}
                    if (fe.object.* == .field_expr) {
                        const inner = fe.object.field_expr;
                        if (inner.object.* == .identifier) {
                            const type_name = inner.field;
                            const method_name = fe.field;
                            const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ type_name, method_name }) catch "";
                            defer if (key.len > 0) self.allocator.free(key);
                            if (key.len > 0) {
                                if (self.decls.struct_methods.get(key)) |sig| return sig.return_type;
                                if (self.all_decls) |ad| {
                                    var it = ad.iterator();
                                    while (it.next()) |entry| {
                                        if (entry.value_ptr.*.struct_methods.get(key)) |sig| return sig.return_type;
                                    }
                                }
                            }
                        }
                    }
                }
                // Generic constructor call: Vec2(f32)(...) — callee is itself a call
                if (c.callee.* == .call_expr) {
                    const inner_c = c.callee.call_expr;
                    if (inner_c.callee.* == .identifier) {
                        const name = inner_c.callee.identifier;
                        // compt func returning type: Vec2(f32)(...) → named type
                        if (self.decls.funcs.get(name)) |sig| {
                            if (sig.is_compt) return RT{ .named = name };
                        }
                        if (builtins.isBuiltinType(name)) return RT{ .named = name };
                    }
                }
                return callee_type;
            },

            .field_expr => |f| {
                const obj_type = try self.resolveExpr(f.object, scope);
                // .value on (Error | T) or (null | T) unwraps to the inner type.
                // This lets the resolver track variables assigned via `var x = result.value`.
                if (std.mem.eql(u8, f.field, "value")) {
                    if (obj_type == .error_union) return obj_type.error_union.*;
                    if (obj_type == .null_union) return obj_type.null_union.*;
                }
                const obj_name = obj_type.name();
                if (self.decls.structs.get(obj_name)) |sig| {
                    for (sig.fields) |field| {
                        if (std.mem.eql(u8, field.name, f.field)) {
                            return field.type_;
                        }
                    }
                }
                return RT.inferred;
            },

            .index_expr => |i| {
                const obj_type = try self.resolveExpr(i.object, scope);
                _ = try self.resolveExpr(i.index, scope);
                // Reject indexing non-indexable types (bool, void, etc.)
                if (obj_type == .primitive) {
                    const tn = obj_type.primitive;
                    if (tn == .bool or tn == .void) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "cannot index into type '{s}'", .{tn.toName()});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                }
                return RT.inferred;
            },

            .slice_expr => |s| {
                _ = try self.resolveExpr(s.object, scope);
                _ = try self.resolveExpr(s.low, scope);
                _ = try self.resolveExpr(s.high, scope);
                return RT.inferred;
            },

            .compiler_func => |cf| {
                var first_arg_type: RT = RT.unknown;
                for (cf.args, 0..) |arg, idx| {
                    const t = try self.resolveExpr(arg, scope);
                    if (idx == 0) first_arg_type = t;
                }
                if (std.mem.eql(u8, cf.name, "size") or std.mem.eql(u8, cf.name, "align")) return RT{ .primitive = .usize };
                if (std.mem.eql(u8, cf.name, "typeid")) return RT{ .primitive = .usize };
                if (std.mem.eql(u8, cf.name, "typename")) return RT{ .primitive = .string };
                if (std.mem.eql(u8, cf.name, "typeOf")) return RT{ .primitive = .@"type" };
                if (std.mem.eql(u8, cf.name, "assert")) return RT{ .primitive = .void };
                if (std.mem.eql(u8, cf.name, "swap")) return RT{ .primitive = .void };
                // cast(T, x) → returns T (first arg is the target type)
                if (std.mem.eql(u8, cf.name, "cast")) {
                    if (cf.args.len >= 1 and cf.args[0].* == .identifier) {
                        return RT{ .named = cf.args[0].identifier };
                    }
                    if (cf.args.len >= 1 and cf.args[0].* == .type_named) {
                        const tn = cf.args[0].type_named;
                        if (types.Primitive.fromName(tn)) |prim| return RT{ .primitive = prim };
                        return RT{ .named = tn };
                    }
                }
                // copy(x), move(x) → returns same type as argument
                if (std.mem.eql(u8, cf.name, "copy") or std.mem.eql(u8, cf.name, "move")) {
                    return first_arg_type;
                }
                return RT.unknown;
            },

            .array_literal => |elems| {
                // Resolve element types; infer array type from first element
                var elem_type: RT = RT.inferred;
                for (elems) |elem| {
                    const t = try self.resolveExpr(elem, scope);
                    if (elem_type == .inferred) elem_type = t;
                }
                return elem_type;
            },

            .collection_expr => |c| {
                for (c.type_args) |arg| _ = try self.resolveExpr(arg, scope);
                if (c.alloc_arg) |a| _ = try self.resolveExpr(a, scope);
                return RT{ .named = c.kind };
            },

            .tuple_literal => |t| {
                for (t.fields) |f| _ = try self.resolveExpr(f, scope);
                return RT.inferred;
            },

            .range_expr => |r| {
                _ = try self.resolveExpr(r.left, scope);
                _ = try self.resolveExpr(r.right, scope);
                return RT.inferred;
            },

            .break_stmt, .continue_stmt => RT.unknown,

            else => RT.unknown,
        };
    }

    /// Check that a match on a union type covers all members
    fn checkMatchExhaustiveness(self: *TypeResolver, match_type: RT, arms: []*parser.Node, match_node: *parser.Node) !void {
        // Collect covered arm names
        var covered: std.ArrayListUnmanaged([]const u8) = .{};
        defer covered.deinit(self.allocator);
        for (arms) |arm| {
            if (arm.* == .match_arm) {
                const pat = arm.match_arm.pattern;
                if (pat.* == .identifier and !std.mem.eql(u8, pat.identifier, "else")) {
                    try covered.append(self.allocator, pat.identifier);
                }
                if (pat.* == .null_literal) {
                    try covered.append(self.allocator, "null");
                }
            }
        }

        const covered_slice = covered.items;

        switch (match_type) {
            .error_union => |inner| {
                const required = [_][]const u8{ "Error", inner.name() };
                for (required) |req| {
                    var found = false;
                    for (covered_slice) |c| {
                        if (std.mem.eql(u8, c, req)) { found = true; break; }
                    }
                    if (!found) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "non-exhaustive match — missing arm for '{s}', add it or use 'else'", .{req});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(match_node) });
                        return;
                    }
                }
            },
            .null_union => |inner| {
                const required = [_][]const u8{ "null", inner.name() };
                for (required) |req| {
                    var found = false;
                    for (covered_slice) |c| {
                        if (std.mem.eql(u8, c, req)) { found = true; break; }
                    }
                    if (!found) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "non-exhaustive match — missing arm for '{s}', add it or use 'else'", .{req});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(match_node) });
                        return;
                    }
                }
            },
            .union_type => |members| {
                for (members) |member| {
                    var found = false;
                    for (covered_slice) |c| {
                        if (std.mem.eql(u8, c, member.name())) { found = true; break; }
                    }
                    if (!found) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "non-exhaustive match — missing arm for '{s}', add it or use 'else'", .{member.name()});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(match_node) });
                        return;
                    }
                }
            },
            else => {}, // integer/string matches — no exhaustiveness required
        }
    }

    /// Validate that a match arm pattern is a valid member of the matched union type
    fn validateMatchArm(self: *TypeResolver, pattern_name: []const u8, match_type: RT, arm_node: *parser.Node) !void {
        switch (match_type) {
            .error_union => |inner| {
                // Valid arms: Error, and the inner type
                if (std.mem.eql(u8, pattern_name, "Error")) return;
                if (std.mem.eql(u8, pattern_name, inner.name())) return;
                const msg = try std.fmt.allocPrint(self.allocator,
                    "match arm '{s}' is not a member of (Error | {s})", .{ pattern_name, inner.name() });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(arm_node) });
            },
            .null_union => |inner| {
                // Valid arms: null, and the inner type
                if (std.mem.eql(u8, pattern_name, "null")) return;
                if (std.mem.eql(u8, pattern_name, inner.name())) return;
                const msg = try std.fmt.allocPrint(self.allocator,
                    "match arm '{s}' is not a member of (null | {s})", .{ pattern_name, inner.name() });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(arm_node) });
            },
            .union_type => |members| {
                // Valid arms: any member type name
                for (members) |member| {
                    if (std.mem.eql(u8, pattern_name, member.name())) return;
                }
                const msg = try std.fmt.allocPrint(self.allocator,
                    "match arm '{s}' is not a member of this union type", .{pattern_name});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(arm_node) });
            },
            else => {
                // Not a union type — pattern matching on integer/string values, not type arms
                // These are validated by codegen, not here
            },
        }
    }

    fn validateType(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .type_named => |type_name| {
                // Qualified names (module.Type) refer to bridge/imported module types.
                // The module import is validated by the module resolver; we trust the
                // qualified form here rather than trying to look up cross-module types.
                const is_qualified = std.mem.indexOfScalar(u8, type_name, '.') != null;
                const is_primitive = types.isPrimitiveName(type_name);
                const is_known = is_qualified or is_primitive or
                    self.decls.structs.contains(type_name) or
                    self.decls.enums.contains(type_name) or
                    self.decls.bitfields.contains(type_name) or
                    self.decls.types.contains(type_name) or // type aliases
                    builtins.isBuiltinType(type_name) or
                    std.mem.eql(u8, type_name, K.Type.ANY) or
                    std.mem.eql(u8, type_name, K.Type.VOID) or
                    std.mem.eql(u8, type_name, K.Type.NULL) or
                    std.mem.eql(u8, type_name, "type") or
                    scope.lookup(type_name) != null;

                if (!is_known) {
                    // Build candidate list from declared types + primitives for suggestion
                    var candidates: std.ArrayListUnmanaged([]const u8) = .{};
                    defer candidates.deinit(self.allocator);
                    var sti = self.decls.structs.keyIterator();
                    while (sti.next()) |k| try candidates.append(self.allocator, k.*);
                    var eni = self.decls.enums.keyIterator();
                    while (eni.next()) |k| try candidates.append(self.allocator, k.*);
                    var bfi = self.decls.bitfields.keyIterator();
                    while (bfi.next()) |k| try candidates.append(self.allocator, k.*);
                    var tyi = self.decls.types.keyIterator();
                    while (tyi.next()) |k| try candidates.append(self.allocator, k.*);
                    for (&PRIMITIVE_NAMES) |pn| try candidates.append(self.allocator, pn);

                    const suggestion = try errors.formatSuggestion(type_name, candidates.items, self.allocator);
                    defer if (suggestion) |s| self.allocator.free(s);
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unknown type '{s}'{s}", .{ type_name, suggestion orelse "" });
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
            },
            .type_slice => |elem| try self.validateType(elem, scope),
            .type_array => |a| try self.validateType(a.elem, scope),
            .type_union => |u| {
                for (u) |t| try self.validateType(t, scope);
            },
            .type_generic => |g| {
                // Validate the base type name is known (builtin, compt func, or user-defined)
                const dot_pos = std.mem.indexOfScalar(u8, g.name, '.');
                const is_qualified = dot_pos != null;
                var is_known = builtins.isBuiltinType(g.name) or
                    self.decls.funcs.contains(g.name) or
                    self.decls.structs.contains(g.name) or
                    scope.lookup(g.name) != null;

                // For qualified names (module.Type), validate against cross-module DeclTables
                if (is_qualified and !is_known) {
                    if (dot_pos) |dp| {
                        const module_name = g.name[0..dp];
                        const type_name = g.name[dp + 1 ..];
                        if (self.all_decls) |ad| {
                            if (ad.get(module_name)) |mod_decls| {
                                is_known = mod_decls.structs.contains(type_name) or
                                    mod_decls.enums.contains(type_name) or
                                    mod_decls.funcs.contains(type_name) or
                                    mod_decls.types.contains(type_name);
                            } else {
                                // Module not found in all_decls — may not yet be processed;
                                // trust qualified names in this case (Zig validates at compile time)
                                is_known = true;
                            }
                        } else {
                            // No cross-module info available — trust qualified names (fallback)
                            is_known = true;
                        }
                    }
                } else if (is_qualified) {
                    // Already known via local decls — nothing more to do
                }

                if (!is_known) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unknown generic type '{s}'", .{g.name});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                // Validate type arguments (Ring/ORing second arg is a size, Vector first arg is a size)
                const is_ring = std.mem.eql(u8, g.name, "Ring") or std.mem.eql(u8, g.name, "ORing");
                const is_vector = std.mem.eql(u8, g.name, "Vector");
                for (g.args, 0..) |arg, idx| {
                    if (is_ring and idx == 1) continue; // size arg, not a type
                    if (is_vector and idx == 0) continue; // lane count, not a type
                    try self.validateType(arg, scope);
                }
            },
            .type_ptr => |p| try self.validateType(p.elem, scope),
            .type_func => |f| {
                for (f.params) |p| try self.validateType(p, scope);
                try self.validateType(f.ret, scope);
            },
            .type_tuple_anon => |members| {
                for (members) |m| try self.validateType(m, scope);
            },
            .type_tuple_named => |fields| {
                for (fields) |f| try self.validateType(f.type_node, scope);
            },
            else => {},
        }
    }

    /// Check if a value type is compatible with an annotation type.
    /// Only flags clear primitive-vs-primitive mismatches (e.g. i32 vs String).
    /// Non-primitive types (arrays, structs, etc.) are left to Zig.
    fn checkAssignCompat(self: *TypeResolver, expected: RT, actual: RT, node: *parser.Node) !void {
        if (actual == .unknown or actual == .inferred) return;
        if (expected == .unknown or expected == .inferred) return;
        // Block []u8 → String coercion
        if (expected == .primitive and expected.primitive == .string and
            actual == .slice and actual.slice.* == .primitive and actual.slice.primitive == .u8)
        {
            try self.reporter.report(.{
                .message = "cannot assign '[]u8' to 'String' — use str.fromBytes() for explicit conversion",
                .loc = self.nodeLoc(node),
            });
            return;
        }
        // Only check when both sides are primitive — that's where we can be confident
        if (expected != .primitive or actual != .primitive) return;
        if (typesCompatible(actual, expected)) return;
        const msg = try std.fmt.allocPrint(self.allocator,
            "type mismatch: expected '{s}', got '{s}'",
            .{ expected.name(), actual.name() });
        defer self.allocator.free(msg);
        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
    }

    /// Returns true if `name` is a variant of any declared enum or a flag of any declared bitfield.
    /// Used to suppress false "unknown identifier" errors for enum variants used as match patterns.
    fn isEnumVariantOrBitfieldFlag(self: *const TypeResolver, name: []const u8) bool {
        var enum_it = self.decls.enums.valueIterator();
        while (enum_it.next()) |sig| {
            for (sig.variants) |v| {
                if (std.mem.eql(u8, v, name)) return true;
            }
        }
        var bf_it = self.decls.bitfields.valueIterator();
        while (bf_it.next()) |sig| {
            for (sig.flags) |f| {
                if (std.mem.eql(u8, f, name)) return true;
            }
        }
        return false;
    }

    /// Check function call args for illegal []u8 → String coercion.
    /// String is not []u8 — use str.fromBytes() for explicit conversion.
    fn checkByteSliceStringCoercion(self: *TypeResolver, c: parser.CallExpr, arg_types: []const RT, node: *parser.Node) !void {
        // Look up the function signature
        const func_name: []const u8 = if (c.callee.* == .identifier)
            c.callee.identifier
        else if (c.callee.* == .field_expr)
            c.callee.field_expr.field
        else
            return;
        const sig = self.decls.funcs.get(func_name) orelse return;

        const param_count = @min(sig.params.len, arg_types.len);
        for (0..param_count) |i| {
            const param_type = sig.params[i].type_;
            const arg_type = arg_types[i];
            // Reject []u8 passed as String
            if (param_type == .primitive and param_type.primitive == .string) {
                if (arg_type == .slice) {
                    if (arg_type.slice.* == .primitive and arg_type.slice.primitive == .u8) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "cannot pass '[]u8' as 'String' — use str.fromBytes() for explicit conversion",
                            .{});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                }
            }
            // Reject String passed as []u8
            if (param_type == .slice) {
                if (param_type.slice.* == .primitive and param_type.slice.primitive == .u8) {
                    if (arg_type == .primitive and arg_type.primitive == .string) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "cannot pass 'String' as '[]u8' — use str.toBytes() for explicit conversion",
                            .{});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                }
            }
        }
    }
};

/// Infer the element type for for-loop captures from the iterable.
fn inferCaptureType(iterable: *parser.Node, iter_type: RT) RT {
    // Range expressions produce integers
    if (iterable.* == .range_expr) return RT{ .primitive = .usize };
    // String iteration produces u8 characters
    if (iter_type == .primitive and iter_type.primitive == .string)
        return RT{ .primitive = .u8 };
    // Slice/array of known type — element type is the inner type
    if (iter_type == .slice) return iter_type.slice.*;
    if (iter_type == .array) return iter_type.array.elem.*;
    return RT.inferred;
}

/// Check if two resolved types are compatible (same kind and name).
/// Unions, error unions, and null unions are compatible with their inner types.
fn isTypeParam(t: RT) bool {
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

fn typesCompatible(a: RT, b: RT) bool {
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
    // Error unions accept their inner type, Error, or unresolved literals
    if (b == .error_union) return a == .err or a == .inferred or a == .unknown or
        std.mem.eql(u8, a_name, b.error_union.name()) or isLiteralCompatible(a, b.error_union.*);
    if (a == .error_union) return b == .err or b == .inferred or b == .unknown or
        std.mem.eql(u8, b_name, a.error_union.name()) or isLiteralCompatible(b, a.error_union.*);
    // Null unions accept their inner type, null, or unresolved literals
    if (b == .null_union) return a == .null_type or a == .inferred or a == .unknown or
        std.mem.eql(u8, a_name, b.null_union.name()) or isLiteralCompatible(a, b.null_union.*);
    if (a == .null_union) return b == .null_type or b == .inferred or b == .unknown or
        std.mem.eql(u8, b_name, a.null_union.name()) or isLiteralCompatible(b, a.null_union.*);
    // Arbitrary unions accept any of their members, or unresolved literals matching any member
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
    return false;
}

/// Check if an unresolved literal type is compatible with a target type
/// e.g. numeric_literal is compatible with any integer member of a union
fn isLiteralCompatible(val: RT, target: RT) bool {
    if (val != .primitive) return false;
    if (target != .primitive) return false;
    if (val.primitive == .numeric_literal and target.primitive.isInteger()) return true;
    if (val.primitive == .float_literal and target.primitive.isFloat()) return true;
    return false;
}

test "resolver init" {
    var decl_table = declarations.DeclTable.init(std.testing.allocator);
    defer decl_table.deinit();

    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var resolver = TypeResolver.init(std.testing.allocator, &decl_table, &reporter);
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
        .is_pub = false,
        .is_bridge = false,
        .is_compt = false,
        .is_thread = false,
    } };

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };
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

    var type_resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
        .is_thread = false,
    });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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

    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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

    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();

    // Range expressions produce usize captures
    var low = parser.Node{ .int_literal = "0" };
    var high = parser.Node{ .int_literal = "10" };
    var range_node = parser.Node{ .range_expr = .{ .op = "..", .left = &low, .right = &high } };
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
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Point(x: 5) → should resolve to "Point"
    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "Point" };
    const arg = try a.create(parser.Node);
    arg.* = .{ .int_literal = "5" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const call = try a.create(parser.Node);
    call.* = .{ .call_expr = .{ .callee = callee, .args = args, .arg_names = &.{} } };

    const result = try resolver.resolveExpr(call, &scope);
    try std.testing.expectEqualStrings("Point", result.name());
}

test "resolver - validateType catches unknown generic" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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

test "resolver - array literal infers element type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // [1, 2] — bare int literals are numeric_literal without explicit type
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
    try std.testing.expectEqualStrings("numeric_literal", result.name());
}

test "resolver - match exhaustiveness with many arms" {
    // Verify that match exhaustiveness checking works with >16 union members
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
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

test "resolver - validateType catches unknown qualified generic" {
    const alloc = std.testing.allocator;
    var local_decls = declarations.DeclTable.init(alloc);
    defer local_decls.deinit();
    var math_decls = declarations.DeclTable.init(alloc);
    defer math_decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &local_decls, &reporter);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    // math module exists but does NOT have "Vec2"
    try all_decls.put("math", &math_decls);
    resolver.all_decls = &all_decls;

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

test "resolver - validateType accepts known qualified generic" {
    const alloc = std.testing.allocator;
    var local_decls = declarations.DeclTable.init(alloc);
    defer local_decls.deinit();
    var math_decls = declarations.DeclTable.init(alloc);
    defer math_decls.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &local_decls, &reporter);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    // Add Vec2 to the math module's structs
    try math_decls.structs.put("Vec2", .{
        .name = "Vec2",
        .fields = &.{},
        .is_pub = true,
    });

    var all_decls = std.StringHashMap(*declarations.DeclTable).init(alloc);
    defer all_decls.deinit();
    try all_decls.put("math", &math_decls);
    resolver.all_decls = &all_decls;

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
