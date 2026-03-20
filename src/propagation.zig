// propagation.zig — Error & Null Propagation Analysis pass (pass 9)
// Verifies all (Error | T) and (null | T) unions are handled before scope exit.
// If not handled — compiler propagates automatically with full trace.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const types = @import("types.zig");

/// A tracked union variable — needs handling before scope exit
pub const UnionVar = struct {
    name: []const u8,
    handled: bool,
    is_error_union: bool, // true = Error union, false = null union
    line: usize,
    col: usize,
};

/// Scope frame for propagation tracking
pub const PropScope = struct {
    vars: std.StringHashMap(UnionVar),
    parent: ?*PropScope,
    allocator: std.mem.Allocator,
    func_returns_error: bool, // can this function propagate?

    pub fn init(allocator: std.mem.Allocator, parent: ?*PropScope, func_returns_error: bool) PropScope {
        return .{
            .vars = std.StringHashMap(UnionVar).init(allocator),
            .parent = parent,
            .allocator = allocator,
            .func_returns_error = func_returns_error,
        };
    }

    pub fn deinit(self: *PropScope) void {
        self.vars.deinit();
    }

    pub fn define(self: *PropScope, name: []const u8, is_error: bool, line: usize, col: usize) !void {
        try self.vars.put(name, .{
            .name = name,
            .handled = false,
            .is_error_union = is_error,
            .line = line,
            .col = col,
        });
    }

    pub fn markHandled(self: *PropScope, name: []const u8) void {
        if (self.vars.getPtr(name)) |v| {
            v.handled = true;
            return;
        }
        if (self.parent) |p| p.markHandled(name);
    }
};

/// The propagation checker
pub const PropChecker = struct {
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    decls: ?*declarations.DeclTable,
    locs: ?*const parser.LocMap,
    source_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter, decls: ?*declarations.DeclTable) PropChecker {
        return .{
            .reporter = reporter,
            .allocator = allocator,
            .decls = decls,
            .locs = null,
            .source_file = "",
        };
    }

    fn nodeLoc(self: *const PropChecker, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn check(self: *PropChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.checkTopLevel(node);
        }
    }

    fn checkTopLevel(self: *PropChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                // Determine if function can propagate errors
                const returns_error = typeCanPropagate(f.return_type);

                var scope = PropScope.init(self.allocator, null, returns_error);
                defer scope.deinit();

                try self.checkNode(f.body, &scope);
                try self.checkScopeExit(&scope, f.return_type);
            },
            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) try self.checkTopLevel(member);
                }
            },
            .enum_decl => |e| {
                for (e.members) |member| {
                    if (member.* == .func_decl) try self.checkTopLevel(member);
                }
            },
            .bitfield_decl => {},
            else => {},
        }
    }

    fn checkNode(self: *PropChecker, node: *parser.Node, scope: *PropScope) anyerror!void {
        switch (node.*) {
            .block => |b| {
                var block_scope = PropScope.init(self.allocator, scope, scope.func_returns_error);
                defer block_scope.deinit();

                for (b.statements) |stmt| {
                    try self.checkStatement(stmt, &block_scope);
                }

                // Check scope exit — all unhandled unions must propagate
                try self.checkScopeExit(&block_scope, null);
            },
            else => {},
        }
    }

    fn checkStatement(self: *PropChecker, node: *parser.Node, scope: *PropScope) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl => |v| {
                // Check type annotation first
                const from_annotation = if (v.type_annotation) |ta| typeNodeIsUnion(ta) else null;
                // Then check value expression
                const from_value = try self.exprReturnsUnion(v.value);
                // Annotation takes priority
                const is_union = from_annotation orelse from_value;
                if (is_union) |is_error| {
                    try scope.define(v.name, is_error, 0, 0);
                }
            },

            .if_stmt => |i| {
                // Check if condition is a type check that handles a union (via `is` / `is not`)
                // `x is Error` desugars to `@type(x) == Error`
                // `x is not null` desugars to `@type(x) != null`
                if (i.condition.* == .binary_expr) {
                    const be = i.condition.binary_expr;
                    if (std.mem.eql(u8, be.op, "==") or std.mem.eql(u8, be.op, "!=")) {
                        if (be.left.* == .compiler_func and std.mem.eql(u8, be.left.compiler_func.name, K.Type.TYPE)) {
                            if (be.left.compiler_func.args.len > 0) {
                                const checked_var = be.left.compiler_func.args[0];
                                if (checked_var.* == .identifier) {
                                    scope.markHandled(checked_var.identifier);
                                }
                            }
                        }
                    }
                }
                try self.checkNode(i.then_block, scope);
                if (i.else_block) |e| try self.checkNode(e, scope);
            },

            .while_stmt => |w| {
                try self.checkNode(w.body, scope);
            },

            .for_stmt => |f| {
                try self.checkNode(f.body, scope);
            },

            .match_stmt => |m| {
                // match on a variable handles it
                if (m.value.* == .identifier) {
                    scope.markHandled(m.value.identifier);
                }
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) try self.checkNode(arm.match_arm.body, scope);
                }
            },

            .block => try self.checkNode(node, scope),

            else => {},
        }
    }

    /// Check if expression returns a union type
    /// Returns true = Error union, false = null union, null = not a union
    fn exprReturnsUnion(self: *PropChecker, node: *parser.Node) anyerror!?bool {
        switch (node.*) {
            .call_expr => |c| {
                if (self.decls) |decls| {
                    const func_name = if (c.callee.* == .identifier)
                        c.callee.identifier
                    else if (c.callee.* == .field_expr)
                        c.callee.field_expr.field
                    else
                        null;

                    if (func_name) |fname| {
                        if (decls.funcs.get(fname)) |sig| {
                            if (sig.return_type.isErrorUnion()) return true;
                            if (sig.return_type.isNullUnion()) return false;
                        }
                    }
                }
                return null;
            },
            .error_literal => return true,
            .null_literal => return false,
            else => return null,
        }
    }

    /// Check scope exit — unhandled unions either propagate or error
    fn checkScopeExit(self: *PropChecker, scope: *PropScope, func_ret: ?*parser.Node) anyerror!void {
        var it = scope.vars.iterator();
        while (it.next()) |entry| {
            const uvar = entry.value_ptr.*;
            if (!uvar.handled) {
                if (scope.func_returns_error) {
                    // OK — will automatically propagate with trace
                    // In codegen, we emit the propagation code
                } else {
                    // Function doesn't return error union — can't propagate
                    if (func_ret) |_| {
                        const kind = if (uvar.is_error_union) K.Type.ERROR else K.Type.NULL;
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "unhandled {s} union '{s}' — enclosing function cannot propagate",
                            .{ kind, uvar.name });
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg });
                    }
                }
            }
        }
    }
};

/// Check if a type AST node is an Error or null union
/// Returns true = Error union, false = null union, null = not a union
fn typeNodeIsUnion(node: *parser.Node) ?bool {
    switch (node.*) {
        .type_union => |u| {
            for (u) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) return true;
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) return false;
            }
            return null;
        },
        else => return null,
    }
}

fn typeCanPropagate(node: *parser.Node) bool {
    switch (node.*) {
        .type_union => |u| {
            for (u) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) return true;
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) return true;
            }
            return false;
        },
        .type_named => |n| return std.mem.eql(u8, n, K.Type.VOID) == false,
        else => return false,
    }
}

test "propagation - handled error union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    var scope = PropScope.init(alloc, null, true);
    defer scope.deinit();

    // Define a union var and mark it handled
    try scope.define("result", true, 1, 1);
    scope.markHandled("result");

    try checker.checkScopeExit(&scope, null);
    try std.testing.expect(!reporter.hasErrors());
}

test "propagation - unhandled in non-propagating function" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    // Function that returns void — cannot propagate
    var scope = PropScope.init(alloc, null, false);
    defer scope.deinit();

    try scope.define("result", true, 1, 1);
    // Not marked as handled

    var ret_type = parser.Node{ .type_named = "void" };
    try checker.checkScopeExit(&scope, &ret_type);
    try std.testing.expect(reporter.hasErrors());
}

test "propagation - ResolvedType detects Error and null unions" {
    const alloc = std.testing.allocator;

    // Error union
    const inner = try alloc.create(types.ResolvedType);
    defer alloc.destroy(inner);
    inner.* = .{ .primitive = "i32" };
    const err_union = types.ResolvedType{ .error_union = inner };
    try std.testing.expect(err_union.isErrorUnion());
    try std.testing.expect(!err_union.isNullUnion());

    // Null union
    const null_union = types.ResolvedType{ .null_union = inner };
    try std.testing.expect(null_union.isNullUnion());
    try std.testing.expect(!null_union.isErrorUnion());

    // Plain type — not a union
    const plain = types.ResolvedType{ .primitive = "i32" };
    try std.testing.expect(!plain.isUnion());
    const void_t = types.ResolvedType{ .primitive = "void" };
    try std.testing.expect(!void_t.isUnion());
}

test "propagation - typeNodeIsUnion detects union AST nodes" {
    const alloc = std.testing.allocator;

    // Build a type_union node: (Error | i32)
    var error_type = parser.Node{ .type_named = "Error" };
    var i32_type = parser.Node{ .type_named = "i32" };
    var members = try alloc.alloc(*parser.Node, 2);
    defer alloc.free(members);
    members[0] = &error_type;
    members[1] = &i32_type;
    var union_node = parser.Node{ .type_union = members };

    // Should detect as Error union
    try std.testing.expect(typeNodeIsUnion(&union_node).? == true);

    // Build a null union: (null | User)
    var null_type = parser.Node{ .type_named = "null" };
    var user_type = parser.Node{ .type_named = "User" };
    var null_members = try alloc.alloc(*parser.Node, 2);
    defer alloc.free(null_members);
    null_members[0] = &null_type;
    null_members[1] = &user_type;
    var null_union = parser.Node{ .type_union = null_members };

    try std.testing.expect(typeNodeIsUnion(&null_union).? == false);

    // Plain type — not a union
    var plain = parser.Node{ .type_named = "i32" };
    try std.testing.expect(typeNodeIsUnion(&plain) == null);
}

test "propagation - call expr resolved via decl table" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    // Set up a decl table with a function that returns (Error | i32)
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Build an error_union ResolvedType: (Error | i32)
    const inner = try alloc.create(types.ResolvedType);
    defer alloc.destroy(inner);
    inner.* = .{ .primitive = "i32" };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "i32" };

    const params = try alloc.alloc(declarations.ParamSig, 0);
    try decl_table.funcs.put("divide", .{
        .name = "divide",
        .params = params,
        .return_type = .{ .error_union = inner },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
    });

    var checker = PropChecker.init(alloc, &reporter, &decl_table);

    // Build a call_expr node: divide()
    var callee = parser.Node{ .identifier = "divide" };
    const args = &[_]*parser.Node{};
    var call_node = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = args,
        .arg_names = &.{},
    } };

    const result = try checker.exprReturnsUnion(&call_node);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == true); // Error union
}

test "propagation - is not check marks union as handled" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    // Function that returns void — cannot propagate
    var scope = PropScope.init(alloc, null, false);
    defer scope.deinit();

    // Define a null union variable
    try scope.define("result", false, 1, 1);

    // Build: if(@type(result) != null) — desugared from `if(result is not null)`
    var result_id = parser.Node{ .identifier = "result" };
    var type_args_arr = [_]*parser.Node{&result_id};
    var type_call = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &type_args_arr } };
    var null_node = parser.Node{ .type_named = K.Type.NULL };
    var condition = parser.Node{ .binary_expr = .{ .left = &type_call, .op = "!=", .right = &null_node } };
    var empty_block = parser.Node{ .block = .{ .statements = &.{} } };
    var if_stmt = parser.Node{ .if_stmt = .{
        .condition = &condition,
        .then_block = &empty_block,
        .else_block = null,
    } };

    try checker.checkStatement(&if_stmt, &scope);

    // result should be marked as handled
    const uvar = scope.vars.get("result").?;
    try std.testing.expect(uvar.handled);
}
