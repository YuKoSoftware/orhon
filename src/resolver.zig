// resolver.zig — Compt & Type Resolution pass (pass 5)
// Resolves 'any' to concrete types, evaluates compt expressions,
// validates all type annotations are correct and explicit.
// Interleaved: compt results feed back into type resolution.

const std = @import("std");
const parser = @import("parser.zig");
const types = @import("types.zig");
const declarations = @import("declarations.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");

/// A resolved type binding — maps expression nodes to their resolved types
pub const TypeBinding = struct {
    node: *parser.Node,
    resolved_type: []const u8, // simplified type string for now
};

/// Scope for variable type tracking
pub const Scope = struct {
    vars: std.StringHashMap([]const u8), // name → type string
    parent: ?*Scope,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Scope) Scope {
        return .{
            .vars = std.StringHashMap([]const u8).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scope) void {
        self.vars.deinit();
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?[]const u8 {
        if (self.vars.get(name)) |t| return t;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    pub fn define(self: *Scope, name: []const u8, type_str: []const u8) !void {
        try self.vars.put(name, type_str);
    }
};

/// The type resolver
pub const TypeResolver = struct {
    decls: *declarations.DeclTable,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(TypeBinding),
    bitsize: ?u16 = null, // from main.bitsize metadata
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

        // Extract main.bitsize from metadata
        for (ast.program.metadata) |meta| {
            if (std.mem.endsWith(u8, meta.metadata.field, ".bitsize")) {
                if (meta.metadata.value.* == .int_literal) {
                    const val = std.fmt.parseInt(u16, meta.metadata.value.int_literal, 10) catch 0;
                    if (val == 32 or val == 64) {
                        self.bitsize = val;
                    } else if (val != 0) {
                        try self.reporter.report(.{
                            .message = "main.bitsize must be 32 or 64",
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
                // Register with return type so call sites can resolve
                const ret_type = self.typeNodeStr(f.return_type);
                try scope.define(f.name, ret_type);
            },
            .struct_decl => |s| {
                try scope.define(s.name, s.name);
            },
            .enum_decl => |e| {
                try scope.define(e.name, "enum");
                // Register enum variants in scope
                for (e.members) |member| {
                    if (member.* == .enum_variant) {
                        try scope.define(member.enum_variant.name, e.name);
                    }
                }
            },
            .bitfield_decl => |b| {
                try scope.define(b.name, b.name);
                // Register flag names in scope so the resolver doesn't error on them
                for (b.members) |flag_name| {
                    try scope.define(flag_name, b.name);
                }
            },
            .const_decl => |v| {
                const type_str = if (v.type_annotation) |t| self.typeNodeStr(t) else "inferred";
                try scope.define(v.name, type_str);
            },
            .var_decl => |v| {
                const type_str = if (v.type_annotation) |t| self.typeNodeStr(t) else "inferred";
                try scope.define(v.name, type_str);
            },
            .compt_decl => |v| {
                const type_str = if (v.type_annotation) |t| self.typeNodeStr(t) else "inferred";
                try scope.define(v.name, type_str);
            },
            else => {},
        }
    }

    fn resolveNode(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                var func_scope = Scope.init(self.allocator, scope);
                defer func_scope.deinit();

                // Register params in function scope
                for (f.params) |param| {
                    if (param.* == .param) {
                        const type_str = self.typeNodeStr(param.param.type_annotation);
                        try func_scope.define(param.param.name, type_str);
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
                // Validate type annotation
                if (v.type_annotation) |t| {
                    try self.validateType(t, scope);
                }
                // Resolve value expression
                const val_type = try self.resolveExpr(v.value, scope);
                // Prefer explicit type annotation over inferred
                const resolved = if (v.type_annotation) |t| self.typeNodeStr(t) else val_type;
                // If no annotation, check the value is unambiguous
                if (v.type_annotation == null) {
                    if (std.mem.eql(u8, val_type, "numeric_literal") or
                        std.mem.eql(u8, val_type, "float_literal"))
                    {
                        try self.reporter.report(.{
                            .message = "numeric literal requires explicit type or main.bitsize",
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
                const resolved = if (v.type_annotation) |t| self.typeNodeStr(t) else val_type;
                if (v.type_annotation == null) {
                    if (std.mem.eql(u8, val_type, "numeric_literal") or
                        std.mem.eql(u8, val_type, "float_literal"))
                    {
                        try self.reporter.report(.{
                            .message = "numeric literal requires explicit type or main.bitsize",
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
                for (f.iterables) |it| _ = try self.resolveExpr(it, scope);
                var for_scope = Scope.init(self.allocator, scope);
                defer for_scope.deinit();
                for (f.variables) |v| try for_scope.define(v, "inferred");
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

    /// Resolve an expression and return its type string
    fn resolveExpr(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror![]const u8 {
        return switch (node.*) {
            .int_literal => if (self.bitsize) |bs| switch (bs) {
                32 => "i32",
                64 => "i64",
                else => "numeric_literal",
            } else "numeric_literal",
            .float_literal => if (self.bitsize) |bs| switch (bs) {
                32 => "f32",
                64 => "f64",
                else => "float_literal",
            } else "float_literal",
            .string_literal => "String",
            .bool_literal => "bool",
            .null_literal => "null",
            .error_literal => "Error",

            .identifier => |name| {
                // Check scope first (has most precise info)
                if (scope.lookup(name)) |t| return t;
                // Check declarations
                if (self.decls.funcs.get(name)) |sig| return sig.return_type;
                if (self.decls.structs.contains(name)) return name;
                if (self.decls.enums.contains(name)) return name;
                if (self.decls.vars.get(name)) |v| return v.type_str orelse "unknown";
                // Check builtins
                if (builtins.isBuiltinType(name)) return name;
                if (builtins.isBuiltinValue(name)) return name;
                // Unknown identifier — may be from another module
                return "unknown";
            },

            .binary_expr => |b| {
                const left = try self.resolveExpr(b.left, scope);
                _ = try self.resolveExpr(b.right, scope);
                // Boolean operators return bool
                if (std.mem.eql(u8, b.op, "and") or
                    std.mem.eql(u8, b.op, "or") or
                    std.mem.eql(u8, b.op, "==") or
                    std.mem.eql(u8, b.op, "!=") or
                    std.mem.eql(u8, b.op, "<") or
                    std.mem.eql(u8, b.op, ">") or
                    std.mem.eql(u8, b.op, "<=") or
                    std.mem.eql(u8, b.op, ">=")) return "bool";
                // String/array concat returns same type
                if (std.mem.eql(u8, b.op, "++")) return left;
                return left; // arithmetic preserves type
            },

            .unary_expr => |u| try self.resolveExpr(u.operand, scope),
            .borrow_expr => |b| try self.resolveExpr(b, scope),

            .call_expr => |c| {
                const callee_type = try self.resolveExpr(c.callee, scope);
                for (c.args) |arg| _ = try self.resolveExpr(arg, scope);

                // If callee is an identifier, look up its return type
                if (c.callee.* == .identifier) {
                    // Scope stores the return type for functions
                    if (scope.lookup(c.callee.identifier)) |t| {
                        // If it's not a generic "func", it's the return type
                        if (!std.mem.eql(u8, t, "func")) return t;
                    }
                    // Check declaration table
                    if (self.decls.funcs.get(c.callee.identifier)) |sig| {
                        return sig.return_type;
                    }
                }
                // Module-qualified call: module.func()
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        // Look up func_name in declarations
                        if (self.decls.funcs.get(fe.field)) |sig| {
                            return sig.return_type;
                        }
                    }
                }
                return callee_type;
            },

            .field_expr => |f| {
                const obj_type = try self.resolveExpr(f.object, scope);
                // Look up struct field type
                if (self.decls.structs.get(obj_type)) |sig| {
                    for (sig.fields) |field| {
                        if (std.mem.eql(u8, field.name, f.field)) {
                            return field.type_str;
                        }
                    }
                }
                return "inferred";
            },

            .index_expr => |i| {
                _ = try self.resolveExpr(i.object, scope);
                _ = try self.resolveExpr(i.index, scope);
                return "inferred";
            },

            .slice_expr => |s| {
                _ = try self.resolveExpr(s.object, scope);
                _ = try self.resolveExpr(s.low, scope);
                _ = try self.resolveExpr(s.high, scope);
                return "inferred";
            },

            .compiler_func => |cf| {
                for (cf.args) |arg| _ = try self.resolveExpr(arg, scope);
                // size/align return usize, typeid returns usize, typename returns String
                if (std.mem.eql(u8, cf.name, "size") or std.mem.eql(u8, cf.name, "align")) return "usize";
                if (std.mem.eql(u8, cf.name, "typeid")) return "usize";
                if (std.mem.eql(u8, cf.name, "typename")) return "String";
                return "unknown";
            },

            .array_literal => "[]inferred",

            else => "unknown",
        };
    }

    fn validateType(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
        switch (node.*) {
            .type_named => |name| {
                // Check it's a known type
                const is_primitive = isPrimitive(name);
                const is_known = is_primitive or
                    self.decls.structs.contains(name) or
                    self.decls.enums.contains(name) or
                    builtins.isBuiltinType(name) or
                    std.mem.eql(u8, name, "any") or
                    std.mem.eql(u8, name, "void") or
                    std.mem.eql(u8, name, "null") or
                    scope.lookup(name) != null;

                if (!is_known) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unknown type '{s}'", .{name});
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

    fn typeNodeStr(self: *TypeResolver, node: *parser.Node) []const u8 {
        _ = self;
        return switch (node.*) {
            .type_named => |n| n,
            .type_slice => "slice",
            .type_array => "array",
            .type_union => "union",
            .type_tuple_named, .type_tuple_anon => "tuple",
            .type_func => "func",
            .type_generic => |g| g.name,
            .type_ptr => |p| p.kind,
            else => "unknown",
        };
    }
};

fn isPrimitive(name: []const u8) bool {
    const primitives = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "isize", "usize",
        "f16", "bf16", "f32", "f64", "f128",
        "bool", "String",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

test "resolver - primitive check" {
    try std.testing.expect(isPrimitive("i32"));
    try std.testing.expect(isPrimitive("String"));
    try std.testing.expect(!isPrimitive("Player"));
    try std.testing.expect(!isPrimitive("MyStruct"));
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

    // Build metadata: main.bitsize = 32
    const bitsize_val = try a.create(parser.Node);
    bitsize_val.* = .{ .int_literal = "32" };
    const meta_node = try a.create(parser.Node);
    meta_node.* = .{ .metadata = .{ .field = "main.bitsize", .value = bitsize_val } };

    // Build: var x = 42 (no type annotation)
    const int_lit = try a.create(parser.Node);
    int_lit.* = .{ .int_literal = "42" };
    const var_decl = try a.create(parser.Node);
    var_decl.* = .{ .var_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = int_lit,
        .is_pub = false,
    } };

    // Build: var f = 3.14 (no type annotation)
    const float_lit = try a.create(parser.Node);
    float_lit.* = .{ .float_literal = "3.14" };
    const float_decl = try a.create(parser.Node);
    float_decl.* = .{ .var_decl = .{
        .name = "f",
        .type_annotation = null,
        .value = float_lit,
        .is_pub = false,
    } };

    // Wrap in a block (func body)
    const body = try a.create(parser.Node);
    const stmts = try a.alloc(*parser.Node, 2);
    stmts[0] = var_decl;
    stmts[1] = float_decl;
    body.* = .{ .block = .{ .statements = stmts } };

    // Build func main
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

    // Build program
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

    // With bitsize=32, no errors for untyped numeric literals
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expectEqual(@as(u16, 32), type_resolver.bitsize.?);
}

test "resolver - no bitsize errors on untyped literal" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // No metadata — no bitsize
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

    // Without bitsize, untyped numeric literal should produce an error
    try std.testing.expect(reporter.hasErrors());
    try std.testing.expect(type_resolver.bitsize == null);
}

test "resolver - function return type resolves" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register a function: add(i32, i32) -> i32
    try decl_table.funcs.put("add", .{
        .name = "add",
        .params = &.{},
        .return_type = "i32",
        .is_compt = false,
        .is_pub = false,
    });

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var resolver = TypeResolver.init(alloc, &decl_table, &reporter);
    defer resolver.deinit();

    var scope = Scope.init(alloc, null);
    defer scope.deinit();

    // Simulate: add(1, 2)
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

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
    try std.testing.expectEqualStrings("i32", result);
}

test "resolver - struct field type resolves" {
    const alloc = std.testing.allocator;
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register struct: Point { x: f32, y: f32 }
    // Use the decl_table's allocator since deinit frees these
    const fields = try alloc.alloc(declarations.FieldSig, 2);
    fields[0] = .{ .name = "x", .type_str = "f32", .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_str = "f32", .has_default = false, .is_pub = true };
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
    try scope.define("p", "Point");

    // Simulate: p.x
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const obj = try a.create(parser.Node);
    obj.* = .{ .identifier = "p" };
    const field_node = try a.create(parser.Node);
    field_node.* = .{ .field_expr = .{ .object = obj, .field = "x" } };

    const result = try resolver.resolveExpr(field_node, &scope);
    try std.testing.expectEqualStrings("f32", result);
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

    // Simulate: var x: i64 = 42  (annotation should override bitsize default)
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

    // x should be i64 (from annotation), not i32 (from bitsize)
    const x_type = scope.lookup("x").?;
    try std.testing.expectEqualStrings("i64", x_type);
}
