// propagation.zig — Error & Null Propagation Analysis pass (pass 9)
// Verifies all (Error | T) and (null | T) unions are handled before scope exit.
// If not handled — compiler propagates automatically with full trace.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const types = @import("types.zig");
const module = @import("module.zig");
const sema = @import("sema.zig");
const scope_mod = @import("scope.zig");

/// A tracked union variable — needs handling before scope exit
pub const UnionVar = struct {
    name: []const u8,
    handled: bool,
    is_error_union: bool, // true = Error union, false = null union
    line: usize,
    col: usize,
};

/// Scope frame for propagation tracking
pub const PropagationScope = struct {
    base: scope_mod.ScopeBase(UnionVar),
    func_returns_error: bool, // can this function propagate?

    pub fn init(allocator: std.mem.Allocator, parent: ?*PropagationScope, func_returns_error: bool) PropagationScope {
        return .{
            .base = scope_mod.ScopeBase(UnionVar).init(
                allocator,
                if (parent) |p| &p.base else null,
            ),
            .func_returns_error = func_returns_error,
        };
    }

    pub fn deinit(self: *PropagationScope) void {
        self.base.deinit();
    }

    pub fn define(self: *PropagationScope, name: []const u8, is_error: bool, line: usize, col: usize) !void {
        try self.base.define(name, .{
            .name = name,
            .handled = false,
            .is_error_union = is_error,
            .line = line,
            .col = col,
        });
    }

    pub fn markHandled(self: *PropagationScope, name: []const u8) void {
        if (self.base.lookupPtr(name)) |v| {
            v.handled = true;
        }
    }

    /// Check if a variable is tracked as a union in this scope or any parent
    pub fn isTracked(self: *const PropagationScope, name: []const u8) ?UnionVar {
        return self.base.lookup(name);
    }

    /// Reset a variable to unhandled (e.g. after reassignment to a new union value)
    pub fn resetHandled(self: *PropagationScope, name: []const u8, is_error: bool) void {
        if (self.base.lookupPtr(name)) |v| {
            v.handled = false;
            v.is_error_union = is_error;
        }
    }
};

/// The propagation checker
pub const PropagationChecker = struct {
    ctx: *const sema.SemanticContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *const sema.SemanticContext) PropagationChecker {
        return .{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn check(self: *PropagationChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.checkTopLevel(node);
        }
    }

    fn checkTopLevel(self: *PropagationChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                // Determine if function can propagate errors
                const returns_error = typeCanPropagate(f.return_type);

                var scope = PropagationScope.init(self.allocator, null, returns_error);
                defer scope.deinit();

                // Register function parameters with union types
                for (f.params) |param| {
                    if (param.* == .param) {
                        if (typeNodeIsUnion(param.param.type_annotation)) |is_error| {
                            try scope.define(param.param.name, is_error, 0, 0);
                        }
                    }
                }

                try self.checkNode(f.body, &scope);
                try self.checkScopeExit(&scope);
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
            .test_decl => |t| {
                var scope = PropagationScope.init(self.allocator, null, false);
                defer scope.deinit();
                try self.checkNode(t.body, &scope);
                try self.checkScopeExit(&scope);
            },
            else => {},
        }
    }

    fn checkNode(self: *PropagationChecker, node: *parser.Node, scope: *PropagationScope) anyerror!void {
        switch (node.*) {
            .block => |b| {
                var block_scope = PropagationScope.init(self.allocator, scope, scope.func_returns_error);
                defer block_scope.deinit();

                for (b.statements) |stmt| {
                    try self.checkStatement(stmt, &block_scope);
                }

                // Check scope exit — all unhandled unions must propagate
                try self.checkScopeExit(&block_scope);
            },
            else => {},
        }
    }

    fn checkStatement(self: *PropagationChecker, node: *parser.Node, scope: *PropagationScope) anyerror!void {
        switch (node.*) {
            .var_decl => |v| {
                // Check for unsafe unwrap in the value expression
                try self.checkExprForUnsafeUnwrap(v.value, scope);
                // Check type annotation first
                const from_annotation = if (v.type_annotation) |ta| typeNodeIsUnion(ta) else null;
                // Then check value expression
                const from_value = try self.exprReturnsUnion(v.value);
                // Annotation takes priority
                const is_union = from_annotation orelse from_value;
                if (is_union) |is_error| {
                    const loc = self.ctx.nodeLoc(node);
                    try scope.define(v.name, is_error, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                }
                // Assignment propagation: var y = x where x is a tracked union
                if (from_annotation == null and from_value == null) {
                    if (v.value.* == .identifier) {
                        if (scope.isTracked(v.value.identifier)) |tracked| {
                            const loc = self.ctx.nodeLoc(node);
                            try scope.define(v.name, tracked.is_error_union, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                        }
                    }
                }
            },

            .assignment => |a| {
                // Reassignment: if assigning a union value to a tracked variable, reset it
                const var_name = if (a.left.* == .identifier) a.left.identifier else null;
                if (var_name) |name| {
                    const new_union = try self.exprReturnsUnion(a.right);
                    if (new_union) |is_error| {
                        // Reassigning to a new union value — reset to unhandled
                        if (scope.isTracked(name) != null) {
                            scope.resetHandled(name, is_error);
                        } else {
                            const loc = self.ctx.nodeLoc(node);
                            try scope.define(name, is_error, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                        }
                    }
                    // Assignment propagation: x = y where y is a tracked union
                    if (new_union == null and a.right.* == .identifier) {
                        if (scope.isTracked(a.right.identifier)) |tracked| {
                            if (scope.isTracked(name) != null) {
                                scope.resetHandled(name, tracked.is_error_union);
                            } else {
                                const loc = self.ctx.nodeLoc(node);
                                try scope.define(name, tracked.is_error_union, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                            }
                        }
                    }
                }
            },

            .return_stmt => |r| {
                // Returning a union variable marks it as handled — it's being passed to caller
                if (r.value) |val| {
                    if (val.* == .identifier) {
                        scope.markHandled(val.identifier);
                    }
                    try self.checkExprForUnsafeUnwrap(val, scope);
                }
            },

            .if_stmt => |i| {
                // Walk the condition to find type checks — handles compound conditions
                // `x is Error` desugars to `@type(x) == Error`
                // `x is not null` desugars to `@type(x) != null`
                // Only mark as handled if the then-block has an early exit (return/break/continue)
                // This ensures type narrowing: code after the if can safely unwrap
                const has_early_exit = blockHasEarlyExit(i.then_block);
                if (has_early_exit) {
                    self.extractTypeChecks(i.condition, scope);
                }
                // Also mark as handled if there's an else branch (both paths covered)
                if (i.else_block != null and !has_early_exit) {
                    self.extractTypeChecks(i.condition, scope);
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

            .defer_stmt => |d| {
                try self.checkNode(d.body, scope);
            },

            .destruct_decl => |d| {
                // Check if the destructured value returns a union
                _ = try self.exprReturnsUnion(d.value);
            },

            .break_stmt, .continue_stmt => {},

            .block => try self.checkNode(node, scope),


            else => {},
        }
    }

    /// Check if an expression contains unsafe unwrap of an unhandled union (e.g. result.i32)
    fn checkExprForUnsafeUnwrap(self: *PropagationChecker, node: *parser.Node, scope: *PropagationScope) anyerror!void {
        switch (node.*) {
            .field_expr => |f| {
                // result.i32 / result.str — unwrap of union field
                if (f.object.* == .identifier) {
                    const name = f.object.identifier;
                    if (scope.isTracked(name)) |uvar| {
                        if (!uvar.handled) {
                            const kind = if (uvar.is_error_union) K.Type.ERROR else K.Type.NULL;
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "unsafe unwrap of {s} union '{s}' — check with 'is' or 'match' first",
                                .{ kind, name });
                        }
                    }
                }
                try self.checkExprForUnsafeUnwrap(f.object, scope);
            },
            .binary_expr => |b| {
                try self.checkExprForUnsafeUnwrap(b.left, scope);
                try self.checkExprForUnsafeUnwrap(b.right, scope);
            },
            .unary_expr => |u| try self.checkExprForUnsafeUnwrap(u.operand, scope),
            .call_expr => |c| {
                try self.checkExprForUnsafeUnwrap(c.callee, scope);
                for (c.args) |arg| try self.checkExprForUnsafeUnwrap(arg, scope);
            },
            .index_expr => |i| {
                try self.checkExprForUnsafeUnwrap(i.object, scope);
                try self.checkExprForUnsafeUnwrap(i.index, scope);
            },
            .slice_expr => |s| {
                try self.checkExprForUnsafeUnwrap(s.object, scope);
                try self.checkExprForUnsafeUnwrap(s.low, scope);
                try self.checkExprForUnsafeUnwrap(s.high, scope);
            },
            else => {},
        }
    }

    /// Walk a condition expression and extract all type checks, marking variables as handled.
    /// Handles simple conditions, AND/OR compound conditions, and nested type checks.
    fn extractTypeChecks(self: *const PropagationChecker, node: *parser.Node, scope: *PropagationScope) void {
        switch (node.*) {
            .binary_expr => |be| {
                // Compound conditions: walk both sides of `and` / `or`
                if (be.op == .@"and" or be.op == .@"or") {
                    self.extractTypeChecks(be.left, scope);
                    self.extractTypeChecks(be.right, scope);
                    return;
                }
                // Direct type check: @type(x) == Error / @type(x) != null
                if (be.op == .eq or be.op == .ne) {
                    if (be.left.* == .compiler_func and std.mem.eql(u8, be.left.compiler_func.name, K.Type.TYPE)) {
                        if (be.left.compiler_func.args.len > 0) {
                            const checked_var = be.left.compiler_func.args[0];
                            if (checked_var.* == .identifier) {
                                scope.markHandled(checked_var.identifier);
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Check if expression returns a union type
    /// Returns true = Error union, false = null union, null = not a union
    fn exprReturnsUnion(self: *PropagationChecker, node: *parser.Node) anyerror!?bool {
        switch (node.*) {
            .call_expr => |c| {
                {
                    const func_name = if (c.callee.* == .identifier)
                        c.callee.identifier
                    else if (c.callee.* == .field_expr)
                        c.callee.field_expr.field
                    else
                        null;

                    if (func_name) |fname| {
                        if (self.ctx.decls.funcs.get(fname)) |sig| {
                            if (sig.return_type.unionContainsError()) return true;
                            if (sig.return_type.unionContainsNull()) return false;
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
    fn checkScopeExit(self: *PropagationChecker, scope: *PropagationScope) anyerror!void {
        var it = scope.base.vars.iterator();
        while (it.next()) |entry| {
            const uvar = entry.value_ptr.*;
            if (!uvar.handled) {
                if (scope.func_returns_error) {
                    // OK — will automatically propagate with trace
                } else {
                    const kind = if (uvar.is_error_union) K.Type.ERROR else K.Type.NULL;
                    const loc: ?errors.SourceLoc = if (uvar.line > 0) blk: {
                        const resolved = module.resolveFileLoc(self.ctx.file_offsets, uvar.line);
                        break :blk .{ .file = resolved.file, .line = resolved.line, .col = uvar.col };
                    } else
                        null;
                    try self.ctx.reporter.reportFmt(loc, "unhandled {s} union '{s}' — enclosing function cannot propagate",
                        .{ kind, uvar.name });
                }
            }
        }
    }
};

/// Check if a type AST node is an Error or null union
/// Returns true = Error union, false = null union, null = not a union
fn typeNodeIsUnion(node: *parser.Node) ?bool {
    switch (node.*) {
        .type_union => |members| {
            for (members) |m| {
                if (m.* == .type_named and std.mem.eql(u8, m.type_named, K.Type.ERROR)) return true;
            }
            for (members) |m| {
                if (m.* == .type_named and std.mem.eql(u8, m.type_named, K.Type.NULL)) return false;
            }
            return null;
        },
        else => return null,
    }
}

const blockHasEarlyExit = parser.blockHasEarlyExit;

fn typeCanPropagate(node: *parser.Node) bool {
    switch (node.*) {
        .type_union => |members| {
            // (Error | T) can propagate errors, (null | T) can propagate null
            for (members) |m| {
                if (m.* == .type_named and (std.mem.eql(u8, m.type_named, K.Type.ERROR) or std.mem.eql(u8, m.type_named, K.Type.NULL)))
                    return true;
            }
            return false;
        },
        .type_named => return false,
        else => return false,
    }
}

test "propagation - handled error union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    var scope = PropagationScope.init(alloc, null, true);
    defer scope.deinit();

    // Define a union var and mark it handled
    try scope.define("result", true, 1, 1);
    scope.markHandled("result");

    try checker.checkScopeExit(&scope);
    try std.testing.expect(!reporter.hasErrors());
}

test "propagation - unhandled in non-propagating function" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    // Function that returns void — cannot propagate
    var scope = PropagationScope.init(alloc, null, false);
    defer scope.deinit();

    try scope.define("result", true, 1, 1);
    // Not marked as handled

    try checker.checkScopeExit(&scope);
    try std.testing.expect(reporter.hasErrors());
}

test "propagation - ResolvedType detects Error and null unions" {
    // Error union: (Error | i32)
    const err_union = types.ResolvedType{ .union_type = &.{ types.ResolvedType.err, types.ResolvedType{ .primitive = .i32 } } };
    try std.testing.expect(err_union.unionContainsError());
    try std.testing.expect(!err_union.unionContainsNull());

    // Null union: (null | i32)
    const null_union = types.ResolvedType{ .union_type = &.{ types.ResolvedType.null_type, types.ResolvedType{ .primitive = .i32 } } };
    try std.testing.expect(null_union.unionContainsNull());
    try std.testing.expect(!null_union.unionContainsError());

    // Plain type — not a union
    const plain = types.ResolvedType{ .primitive = .i32 };
    try std.testing.expect(!plain.isUnion());
    const void_t = types.ResolvedType{ .primitive = .void };
    try std.testing.expect(!void_t.isUnion());
}

test "propagation - typeNodeIsUnion detects union AST nodes" {
    // Build a type_union node: (Error | i32)
    var error_type = parser.Node{ .type_named = "Error" };
    var i32_type = parser.Node{ .type_named = "i32" };
    var err_members = [_]*parser.Node{ &error_type, &i32_type };
    var err_union_node = parser.Node{ .type_union = &err_members };

    // Should detect as Error union
    try std.testing.expect(typeNodeIsUnion(&err_union_node).? == true);

    // Build (null | User)
    var null_type = parser.Node{ .type_named = "null" };
    var user_type = parser.Node{ .type_named = "User" };
    var null_members = [_]*parser.Node{ &null_type, &user_type };
    var null_union_node = parser.Node{ .type_union = &null_members };

    try std.testing.expect(typeNodeIsUnion(&null_union_node).? == false);

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
    const err_members = try alloc.alloc(types.ResolvedType, 2);
    defer alloc.free(err_members);
    err_members[0] = types.ResolvedType.err;
    err_members[1] = types.ResolvedType{ .primitive = .i32 };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "i32" };

    const params = try alloc.alloc(declarations.ParamSig, 0);
    try decl_table.funcs.put("divide", .{
        .name = "divide",
        .params = params,
        .param_nodes = &.{},
        .return_type = .{ .union_type = err_members },
        .return_type_node = ret_node,
        .context = .normal,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    // Function that returns void — cannot propagate
    var scope = PropagationScope.init(alloc, null, false);
    defer scope.deinit();

    // Define a null union variable
    try scope.define("result", false, 1, 1);

    // Build: if(@type(result) != null) { return } — desugared from `if(result is not null)`
    var result_id = parser.Node{ .identifier = "result" };
    var type_args_arr = [_]*parser.Node{&result_id};
    var type_call = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &type_args_arr } };
    var null_node = parser.Node{ .type_named = K.Type.NULL };
    var condition = parser.Node{ .binary_expr = .{ .left = &type_call, .op = .ne, .right = &null_node } };
    var ret_stmt = parser.Node{ .return_stmt = .{ .value = null } };
    var body_stmts = [_]*parser.Node{&ret_stmt};
    var body_block = parser.Node{ .block = .{ .statements = &body_stmts } };
    var if_stmt = parser.Node{ .if_stmt = .{
        .condition = &condition,
        .then_block = &body_block,
        .else_block = null,
    } };

    try checker.checkStatement(&if_stmt, &scope);

    // result should be marked as handled
    const uvar = scope.base.vars.get("result").?;
    try std.testing.expect(uvar.handled);
}

test "propagation - return marks union as handled" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    var scope = PropagationScope.init(alloc, null, true);
    defer scope.deinit();

    // Define a union var
    try scope.define("result", true, 1, 1);

    // return result — passes union to caller
    var result_id = parser.Node{ .identifier = "result" };
    var ret = parser.Node{ .return_stmt = .{ .value = &result_id } };
    try checker.checkStatement(&ret, &scope);

    const uvar = scope.base.vars.get("result").?;
    try std.testing.expect(uvar.handled);
}

test "propagation - assignment propagation tracks union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    var scope = PropagationScope.init(alloc, null, false);
    defer scope.deinit();

    // Define x as an error union
    try scope.define("x", true, 1, 1);

    // var y = x → y should also be tracked as error union
    var x_id = parser.Node{ .identifier = "x" };
    var y_decl = parser.Node{ .var_decl = .{
        .name = "y",
        .type_annotation = null,
        .value = &x_id,
        .is_pub = false,
    } };
    try checker.checkStatement(&y_decl, &scope);

    const y_var = scope.base.vars.get("y").?;
    try std.testing.expect(!y_var.handled);
    try std.testing.expect(y_var.is_error_union);
}

test "propagation - reassignment resets handled status" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    // Set up decl table with a function returning error union
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const err_members = try alloc.alloc(types.ResolvedType, 2);
    defer alloc.free(err_members);
    err_members[0] = types.ResolvedType.err;
    err_members[1] = types.ResolvedType{ .primitive = .i32 };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const ret_node = try a.create(parser.Node);
    ret_node.* = .{ .type_named = "i32" };

    const params = try alloc.alloc(declarations.ParamSig, 0);
    try decl_table.funcs.put("divide", .{
        .name = "divide",
        .params = params,
        .param_nodes = &.{},
        .return_type = .{ .union_type = err_members },
        .return_type_node = ret_node,
        .context = .normal,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    var scope = PropagationScope.init(alloc, null, false);
    defer scope.deinit();

    // Define result, mark as handled
    try scope.define("result", true, 1, 1);
    scope.markHandled("result");
    try std.testing.expect(scope.base.vars.get("result").?.handled);

    // Reassign: result = divide(5, 0) — should reset to unhandled
    var result_id = parser.Node{ .identifier = "result" };
    var callee = parser.Node{ .identifier = "divide" };
    var call_node = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &[_]*parser.Node{},
        .arg_names = &.{},
    } };
    var assign = parser.Node{ .assignment = .{ .op = .assign, .left = &result_id, .right = &call_node } };
    try checker.checkStatement(&assign, &scope);

    try std.testing.expect(!scope.base.vars.get("result").?.handled);
}

test "propagation - compound condition handles multiple unions" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = PropagationChecker.init(alloc, &ctx);

    var scope = PropagationScope.init(alloc, null, false);
    defer scope.deinit();

    // Define two union variables
    try scope.define("x", true, 1, 1);
    try scope.define("y", false, 2, 1);

    // Build: if(@type(x) == Error and @type(y) != null)
    var x_id = parser.Node{ .identifier = "x" };
    var x_args = [_]*parser.Node{&x_id};
    var x_type = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &x_args } };
    var error_node = parser.Node{ .type_named = K.Type.ERROR };
    var left_cond = parser.Node{ .binary_expr = .{ .left = &x_type, .op = .eq, .right = &error_node } };

    var y_id = parser.Node{ .identifier = "y" };
    var y_args = [_]*parser.Node{&y_id};
    var y_type = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &y_args } };
    var null_node = parser.Node{ .type_named = K.Type.NULL };
    var right_cond = parser.Node{ .binary_expr = .{ .left = &y_type, .op = .ne, .right = &null_node } };

    var compound = parser.Node{ .binary_expr = .{ .left = &left_cond, .op = .@"and", .right = &right_cond } };
    var ret_stmt = parser.Node{ .return_stmt = .{ .value = null } };
    var body_stmts = [_]*parser.Node{&ret_stmt};
    var body_block = parser.Node{ .block = .{ .statements = &body_stmts } };
    var if_stmt = parser.Node{ .if_stmt = .{
        .condition = &compound,
        .then_block = &body_block,
        .else_block = null,
    } };

    try checker.checkStatement(&if_stmt, &scope);

    // Both should be marked as handled
    try std.testing.expect(scope.base.vars.get("x").?.handled);
    try std.testing.expect(scope.base.vars.get("y").?.handled);
}

test "propagation - scope isTracked walks parents" {
    const alloc = std.testing.allocator;

    var parent = PropagationScope.init(alloc, null, true);
    defer parent.deinit();

    try parent.define("x", true, 1, 1);

    var child = PropagationScope.init(alloc, &parent, true);
    defer child.deinit();

    // x should be visible from child scope
    const tracked = child.isTracked("x");
    try std.testing.expect(tracked != null);
    try std.testing.expect(tracked.?.is_error_union);

    // y should not be tracked
    try std.testing.expect(child.isTracked("y") == null);
}
