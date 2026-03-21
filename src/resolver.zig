// resolver.zig — Compt & Type Resolution pass (pass 5)
// Resolves 'any' to concrete types, evaluates compt expressions,
// validates all type annotations are correct and explicit.
// Interleaved: compt results feed back into type resolution.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const types = @import("types.zig");

const RT = types.ResolvedType;

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
    bitsize: ?u16 = null, // from #bitsize metadata
    locs: ?*const parser.LocMap = null,
    source_file: []const u8 = "",
    loop_depth: u32 = 0, // track nesting depth for break/continue validation
    current_return_type: ?RT = null, // expected return type of current function

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
        };
    }

    fn nodeLoc(self: *const TypeResolver, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn deinit(self: *TypeResolver) void {
        self.bindings.deinit(self.allocator);
    }

    /// Resolve types in a program AST
    pub fn resolve(self: *TypeResolver, ast: *parser.Node) !void {
        if (ast.* != .program) return;

        // Extract #bitsize from metadata
        for (ast.program.metadata) |meta| {
            if (std.mem.eql(u8, meta.metadata.field, "bitsize")) {
                if (meta.metadata.value.* == .int_literal) {
                    const val = std.fmt.parseInt(u16, meta.metadata.value.int_literal, 10) catch 0;
                    if (val == 32 or val == 64) {
                        self.bitsize = val;
                    } else if (val != 0) {
                        try self.reporter.report(.{
                            .message = "#bitsize must be 32 or 64",
                            .loc = self.nodeLoc(meta),
                        });
                    }
                }
            }
        }

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
                    try types.resolveTypeNode(self.decls.typeAllocator(), ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            .var_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try types.resolveTypeNode(self.decls.typeAllocator(), ta)
                else
                    RT.inferred;
                try scope.define(v.name, t);
            },
            .compt_decl => |v| {
                const t = if (v.type_annotation) |ta|
                    try types.resolveTypeNode(self.decls.typeAllocator(), ta)
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

                for (f.params) |param| {
                    if (param.* == .param) {
                        try self.validateType(param.param.type_annotation, &func_scope);
                        const t = try types.resolveTypeNode(self.decls.typeAllocator(), param.param.type_annotation);
                        try func_scope.define(param.param.name, t);
                    }
                }

                try self.validateType(f.return_type, scope);
                const prev_return = self.current_return_type;
                self.current_return_type = try types.resolveTypeNode(self.decls.typeAllocator(), f.return_type);
                defer self.current_return_type = prev_return;

                try self.resolveNode(f.body, &func_scope);
            },
            .struct_decl => |s| {
                var struct_scope = Scope.init(self.allocator, scope);
                defer struct_scope.deinit();
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
                    try types.resolveTypeNode(self.decls.typeAllocator(), t)
                else
                    val_type;
                if (v.type_annotation == null) {
                    if (val_type == .primitive and
                        (std.mem.eql(u8, val_type.primitive, "numeric_literal") or
                        std.mem.eql(u8, val_type.primitive, "float_literal")))
                    {
                        try self.reporter.report(.{
                            .message = "numeric literal requires explicit type or #bitsize",
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
                const val_type = try self.resolveExpr(v.value, scope);
                const resolved = if (v.type_annotation) |t|
                    try types.resolveTypeNode(self.decls.typeAllocator(), t)
                else
                    val_type;
                if (v.type_annotation == null) {
                    if (val_type == .primitive and
                        (std.mem.eql(u8, val_type.primitive, "numeric_literal") or
                        std.mem.eql(u8, val_type.primitive, "float_literal")))
                    {
                        try self.reporter.report(.{
                            .message = "numeric literal requires explicit type or #bitsize",
                            .loc = self.nodeLoc(node),
                        });
                    }
                } else {
                    try self.checkAssignCompat(resolved, val_type, node);
                }
                try scope.define(v.name, resolved);
            },
            .compt_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                }
                const val_type = try self.resolveExpr(v.value, scope);
                const resolved = if (v.type_annotation) |t|
                    try types.resolveTypeNode(self.decls.typeAllocator(), t)
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
                if (cond_type == .primitive and !std.mem.eql(u8, cond_type.primitive, "bool") and
                    cond_type != .unknown and cond_type != .inferred)
                {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "if condition must be bool, got '{s}'", .{cond_type.name()});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                try self.resolveNode(i.then_block, scope);
                if (i.else_block) |e| try self.resolveNode(e, scope);
            },
            .while_stmt => |w| {
                const cond_type = try self.resolveExpr(w.condition, scope);
                if (cond_type == .primitive and !std.mem.eql(u8, cond_type.primitive, "bool") and
                    cond_type != .unknown and cond_type != .inferred)
                {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "while condition must be bool, got '{s}'", .{cond_type.name()});
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
                if (f.index_var) |idx| try for_scope.define(idx, RT{ .primitive = "usize" });
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.resolveNode(f.body, &for_scope);
            },
            .match_stmt => |m| {
                _ = try self.resolveExpr(m.value, scope);
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        _ = try self.resolveExpr(arm.match_arm.pattern, scope);
                        try self.resolveNode(arm.match_arm.body, scope);
                    }
                }
            },
            .assignment => |a| {
                _ = try self.resolveExpr(a.left, scope);
                _ = try self.resolveExpr(a.right, scope);
            },
            .defer_stmt => |d| try self.resolveNode(d.body, scope),
            .thread_block => |t| {
                const prev_return = self.current_return_type;
                self.current_return_type = types.resolveTypeNode(self.decls.typeAllocator(), t.result_type) catch null;
                defer self.current_return_type = prev_return;
                try self.resolveNode(t.body, scope);
            },
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
        return switch (node.*) {
            .int_literal => if (self.bitsize) |bs| switch (bs) {
                32 => RT{ .primitive = "i32" },
                64 => RT{ .primitive = "i64" },
                else => RT{ .primitive = "numeric_literal" },
            } else RT{ .primitive = "numeric_literal" },
            .float_literal => if (self.bitsize) |bs| switch (bs) {
                32 => RT{ .primitive = "f32" },
                64 => RT{ .primitive = "f64" },
                else => RT{ .primitive = "float_literal" },
            } else RT{ .primitive = "float_literal" },
            .string_literal => RT{ .primitive = K.Type.STRING },
            .bool_literal => RT{ .primitive = "bool" },
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
                    std.mem.eql(u8, b.op, ">=")) return RT{ .primitive = "bool" };
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
                        if (self.decls.funcs.get(fe.field)) |sig| {
                            return sig.return_type;
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
                    if (std.mem.eql(u8, tn, "bool") or std.mem.eql(u8, tn, "void")) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "cannot index into type '{s}'", .{tn});
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
                if (std.mem.eql(u8, cf.name, "size") or std.mem.eql(u8, cf.name, "align")) return RT{ .primitive = "usize" };
                if (std.mem.eql(u8, cf.name, "typeid")) return RT{ .primitive = "usize" };
                if (std.mem.eql(u8, cf.name, "typename")) return RT{ .primitive = K.Type.STRING };
                if (std.mem.eql(u8, cf.name, "assert")) return RT{ .primitive = "void" };
                if (std.mem.eql(u8, cf.name, "swap")) return RT{ .primitive = "void" };
                // @cast(T, x) → returns T (first arg is the target type)
                if (std.mem.eql(u8, cf.name, "cast")) {
                    if (cf.args.len >= 1 and cf.args[0].* == .identifier) {
                        return RT{ .named = cf.args[0].identifier };
                    }
                    if (cf.args.len >= 1 and cf.args[0].* == .type_named) {
                        const tn = cf.args[0].type_named;
                        if (types.isPrimitiveName(tn)) return RT{ .primitive = tn };
                        return RT{ .named = tn };
                    }
                }
                // @copy(x), @move(x) → returns same type as argument
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

            .ptr_expr => |p| {
                _ = try self.resolveExpr(p.type_arg, scope);
                _ = try self.resolveExpr(p.addr_arg, scope);
                return RT{ .named = p.kind };
            },

            .coll_expr => |c| {
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

    fn validateType(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .type_named => |type_name| {
                const is_primitive = types.isPrimitiveName(type_name);
                const is_known = is_primitive or
                    self.decls.structs.contains(type_name) or
                    self.decls.enums.contains(type_name) or
                    self.decls.bitfields.contains(type_name) or
                    builtins.isBuiltinType(type_name) or
                    std.mem.eql(u8, type_name, K.Type.ANY) or
                    std.mem.eql(u8, type_name, K.Type.VOID) or
                    std.mem.eql(u8, type_name, K.Type.NULL) or
                    std.mem.eql(u8, type_name, "type") or
                    scope.lookup(type_name) != null;

                if (!is_known) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unknown type '{s}'", .{type_name});
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
                const is_known = builtins.isBuiltinType(g.name) or
                    self.decls.funcs.contains(g.name) or
                    self.decls.structs.contains(g.name) or
                    scope.lookup(g.name) != null;
                if (!is_known) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unknown generic type '{s}'", .{g.name});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                // Validate type arguments (Ring/ORing second arg is a size, not a type)
                const is_ring = std.mem.eql(u8, g.name, "Ring") or std.mem.eql(u8, g.name, "ORing");
                for (g.args, 0..) |arg, idx| {
                    if (is_ring and idx == 1) continue; // size arg, not a type
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
        if (expected == .primitive and std.mem.eql(u8, expected.primitive, K.Type.STRING) and
            actual == .slice and actual.slice.* == .primitive and std.mem.eql(u8, actual.slice.primitive, "u8"))
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
            if (param_type == .primitive and std.mem.eql(u8, param_type.primitive, K.Type.STRING)) {
                if (arg_type == .slice) {
                    if (arg_type.slice.* == .primitive and std.mem.eql(u8, arg_type.slice.primitive, "u8")) {
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
                if (param_type.slice.* == .primitive and std.mem.eql(u8, param_type.slice.primitive, "u8")) {
                    if (arg_type == .primitive and std.mem.eql(u8, arg_type.primitive, K.Type.STRING)) {
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
    if (iterable.* == .range_expr) return RT{ .primitive = "usize" };
    // String iteration produces u8 characters
    if (iter_type == .primitive and std.mem.eql(u8, iter_type.primitive, K.Type.STRING))
        return RT{ .primitive = "u8" };
    // Slice/array of known type — element type is the inner type
    if (iter_type == .slice) return iter_type.slice.*;
    if (iter_type == .array) return iter_type.array.elem.*;
    return RT.inferred;
}

/// Check if two resolved types are compatible (same kind and name).
/// Unions, error unions, and null unions are compatible with their inner types.
fn typesCompatible(a: RT, b: RT) bool {
    const a_name = a.name();
    const b_name = b.name();
    if (a_name.len > 0 and b_name.len > 0 and std.mem.eql(u8, a_name, b_name)) return true;
    // Numeric literals are compatible with any integer type
    if (a == .primitive and std.mem.eql(u8, a.primitive, "numeric_literal") and
        b == .primitive and isIntegerType(b.primitive)) return true;
    // Float literals are compatible with any float type
    if (a == .primitive and std.mem.eql(u8, a.primitive, "float_literal") and
        b == .primitive and isFloatType(b.primitive)) return true;
    // Integer-to-integer and float-to-float are compatible (Zig handles coercion)
    if (a == .primitive and b == .primitive and isIntegerType(a.primitive) and isIntegerType(b.primitive)) return true;
    if (a == .primitive and b == .primitive and isFloatType(a.primitive) and isFloatType(b.primitive)) return true;
    // Error/null/arbitrary unions accept their inner types
    if (b == .error_union or b == .null_union or b == .union_type) return true;
    if (a == .error_union or a == .null_union or a == .union_type) return true;
    // func_ptr / func returns are hard to check without full inference — allow
    if (a == .func_ptr or b == .func_ptr) return true;
    return false;
}

fn isIntegerType(name: []const u8) bool {
    return std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize");
}

fn isFloatType(name: []const u8) bool {
    return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
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

test "resolver - bitsize resolves numeric literals" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const bitsize_val = try a.create(parser.Node);
    bitsize_val.* = .{ .int_literal = "32" };
    const meta_node = try a.create(parser.Node);
    meta_node.* = .{ .metadata = .{ .field = "bitsize", .value = bitsize_val } };

    const int_lit = try a.create(parser.Node);
    int_lit.* = .{ .int_literal = "42" };
    const var_decl = try a.create(parser.Node);
    var_decl.* = .{ .var_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = int_lit,
        .is_pub = false,
    } };

    const float_lit = try a.create(parser.Node);
    float_lit.* = .{ .float_literal = "3.14" };
    const float_decl = try a.create(parser.Node);
    float_decl.* = .{ .var_decl = .{
        .name = "f",
        .type_annotation = null,
        .value = float_lit,
        .is_pub = false,
    } };

    const body = try a.create(parser.Node);
    const stmts = try a.alloc(*parser.Node, 2);
    stmts[0] = var_decl;
    stmts[1] = float_decl;
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
        .is_extern = false,
        .is_compt = false,
    } };

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };
    const meta_slice = try a.alloc(*parser.Node, 1);
    meta_slice[0] = meta_node;
    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const program = try a.create(parser.Node);
    program.* = .{ .program = .{
        .module = module_node,
        .metadata = meta_slice,
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

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(u16, 32), type_resolver.bitsize.?);
}

test "resolver - no bitsize errors on untyped literal" {
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
        .is_extern = false,
        .is_compt = false,
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
    try std.testing.expect(type_resolver.bitsize == null);
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
        .return_type = .{ .primitive = "i32" },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
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
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = "f32" }, .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_ = .{ .primitive = "f32" }, .has_default = false, .is_pub = true };
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
    resolver.bitsize = 32;

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

test "resolver - compiler func @cast resolves to target type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();
    var scope = Scope.init(alloc, null);
    defer scope.deinit();
    try scope.define("x", RT{ .primitive = "i32" });

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // @cast(i64, x) → i64
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

test "resolver - compiler func @copy preserves type" {
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

    // @copy(data) → Player
    const arg = try a.create(parser.Node);
    arg.* = .{ .identifier = "data" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const copy_node = try a.create(parser.Node);
    copy_node.* = .{ .compiler_func = .{ .name = "copy", .args = args } };

    const result = try resolver.resolveExpr(copy_node, &scope);
    try std.testing.expectEqualStrings("Player", result.name());
}

test "resolver - compiler func @assert returns void" {
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
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = "i32" }, .has_default = false, .is_pub = true };
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

test "resolver - builtin generic type resolves" {
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

    // List(i32) constructor → should resolve to "List"
    const callee = try a.create(parser.Node);
    callee.* = .{ .identifier = "List" };
    const call = try a.create(parser.Node);
    call.* = .{ .call_expr = .{ .callee = callee, .args = &.{}, .arg_names = &.{} } };

    const result = try resolver.resolveExpr(call, &scope);
    try std.testing.expectEqualStrings("List", result.name());
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

test "resolver - validateType accepts known generic" {
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

    // List(i32) — should be fine (List is a builtin)
    const i32_type = try a.create(parser.Node);
    i32_type.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = i32_type;
    const generic_node = try a.create(parser.Node);
    generic_node.* = .{ .type_generic = .{ .name = "List", .args = args } };

    try resolver.validateType(generic_node, &scope);
    try std.testing.expect(!reporter.hasErrors());
}

test "resolver - array literal infers element type" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();
    resolver.bitsize = 32;
    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // [1, 2, 3] → should resolve to i32 (with bitsize=32)
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
    try std.testing.expectEqualStrings("i32", result.name());
}
