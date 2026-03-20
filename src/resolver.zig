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
                        const t = try types.resolveTypeNode(self.decls.typeAllocator(), param.param.type_annotation);
                        try func_scope.define(param.param.name, t);
                    }
                }

                try self.resolveNode(f.body, &func_scope);
            },
            .struct_decl => |s| {
                var struct_scope = Scope.init(self.allocator, scope);
                defer struct_scope.deinit();
                for (s.members) |member| {
                    try self.resolveNode(member, &struct_scope);
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
                }
                try scope.define(v.name, resolved);
            },
            .const_decl => |v| {
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
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
                }
                try scope.define(v.name, resolved);
            },
            else => {},
        }
    }

    fn resolveStatement(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl, .compt_decl => try self.resolveNode(node, scope),
            .return_stmt => |r| {
                if (r.value) |v| _ = try self.resolveExpr(v, scope);
            },
            .if_stmt => |i| {
                _ = try self.resolveExpr(i.condition, scope);
                try self.resolveNode(i.then_block, scope);
                if (i.else_block) |e| try self.resolveNode(e, scope);
            },
            .while_stmt => |w| {
                _ = try self.resolveExpr(w.condition, scope);
                if (w.continue_expr) |c| _ = try self.resolveExpr(c, scope);
                try self.resolveNode(w.body, scope);
            },
            .for_stmt => |f| {
                _ = try self.resolveExpr(f.iterable, scope);
                var for_scope = Scope.init(self.allocator, scope);
                defer for_scope.deinit();
                for (f.captures) |v| try for_scope.define(v, RT.inferred);
                if (f.index_var) |idx| try for_scope.define(idx, RT.inferred);
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
                for (c.args) |arg| _ = try self.resolveExpr(arg, scope);

                if (c.callee.* == .identifier) {
                    if (scope.lookup(c.callee.identifier)) |t| {
                        if (t != .func_ptr) return t;
                    }
                    if (self.decls.funcs.get(c.callee.identifier)) |sig| {
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
                _ = try self.resolveExpr(i.object, scope);
                _ = try self.resolveExpr(i.index, scope);
                return RT.inferred;
            },

            .slice_expr => |s| {
                _ = try self.resolveExpr(s.object, scope);
                _ = try self.resolveExpr(s.low, scope);
                _ = try self.resolveExpr(s.high, scope);
                return RT.inferred;
            },

            .compiler_func => |cf| {
                for (cf.args) |arg| _ = try self.resolveExpr(arg, scope);
                if (std.mem.eql(u8, cf.name, "size") or std.mem.eql(u8, cf.name, "align")) return RT{ .primitive = "usize" };
                if (std.mem.eql(u8, cf.name, "typeid")) return RT{ .primitive = "usize" };
                if (std.mem.eql(u8, cf.name, "typename")) return RT{ .primitive = K.Type.STRING };
                return RT.unknown;
            },

            .array_literal => RT.inferred,

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
                    builtins.isBuiltinType(type_name) or
                    std.mem.eql(u8, type_name, K.Type.ANY) or
                    std.mem.eql(u8, type_name, K.Type.VOID) or
                    std.mem.eql(u8, type_name, K.Type.NULL) or
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
            else => {},
        }
    }
};

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
