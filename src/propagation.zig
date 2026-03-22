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

    /// Check if a variable is tracked as a union in this scope or any parent
    pub fn isTracked(self: *const PropScope, name: []const u8) ?UnionVar {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.isTracked(name);
        return null;
    }

    /// Reset a variable to unhandled (e.g. after reassignment to a new union value)
    pub fn resetHandled(self: *PropScope, name: []const u8, is_error: bool) void {
        if (self.vars.getPtr(name)) |v| {
            v.handled = false;
            v.is_error_union = is_error;
            return;
        }
        if (self.parent) |p| p.resetHandled(name, is_error);
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
                var scope = PropScope.init(self.allocator, null, false);
                defer scope.deinit();
                try self.checkNode(t.body, &scope);
                try self.checkScopeExit(&scope);
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
                try self.checkScopeExit(&block_scope);
            },
            else => {},
        }
    }

    fn checkStatement(self: *PropChecker, node: *parser.Node, scope: *PropScope) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl => |v| {
                // Check for unsafe unwrap in the value expression
                try self.checkExprForUnsafeUnwrap(v.value, scope);
                // Check type annotation first
                const from_annotation = if (v.type_annotation) |ta| typeNodeIsUnion(ta) else null;
                // Then check value expression
                const from_value = try self.exprReturnsUnion(v.value);
                // Annotation takes priority
                const is_union = from_annotation orelse from_value;
                if (is_union) |is_error| {
                    const loc = self.nodeLoc(node);
                    try scope.define(v.name, is_error, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                }
                // Assignment propagation: var y = x where x is a tracked union
                if (from_annotation == null and from_value == null) {
                    if (v.value.* == .identifier) {
                        if (scope.isTracked(v.value.identifier)) |tracked| {
                            const loc = self.nodeLoc(node);
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
                            const loc = self.nodeLoc(node);
                            try scope.define(name, is_error, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                        }
                    }
                    // Assignment propagation: x = y where y is a tracked union
                    if (new_union == null and a.right.* == .identifier) {
                        if (scope.isTracked(a.right.identifier)) |tracked| {
                            if (scope.isTracked(name) != null) {
                                scope.resetHandled(name, tracked.is_error_union);
                            } else {
                                const loc = self.nodeLoc(node);
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

            .compt_decl => |v| {
                const from_value = try self.exprReturnsUnion(v.value);
                if (from_value) |is_error| {
                    const loc = self.nodeLoc(node);
                    try scope.define(v.name, is_error, if (loc) |l| l.line else 0, if (loc) |l| l.col else 0);
                }
            },

            .destruct_decl => |d| {
                // Check if the destructured value returns a union
                _ = try self.exprReturnsUnion(d.value);
            },

            .break_stmt, .continue_stmt => {},

            .block => try self.checkNode(node, scope),

            .thread_block => |t| {
                // Check thread body for unhandled unions
                var thread_scope = PropScope.init(self.allocator, scope, false);
                defer thread_scope.deinit();
                try self.checkNode(t.body, &thread_scope);
                try self.checkScopeExit(&thread_scope);
            },

            else => {},
        }
    }

    /// Check if an expression contains unsafe unwrap of an unhandled union (e.g. result.i32)
    fn checkExprForUnsafeUnwrap(self: *PropChecker, node: *parser.Node, scope: *PropScope) anyerror!void {
        switch (node.*) {
            .field_expr => |f| {
                // result.i32 / result.String — unwrap of union field
                if (f.object.* == .identifier) {
                    const name = f.object.identifier;
                    if (scope.isTracked(name)) |uvar| {
                        if (!uvar.handled) {
                            const kind = if (uvar.is_error_union) K.Type.ERROR else K.Type.NULL;
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "unsafe unwrap of {s} union '{s}' — check with 'is' or 'match' first",
                                .{ kind, name });
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
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
    fn extractTypeChecks(self: *const PropChecker, node: *parser.Node, scope: *PropScope) void {
        switch (node.*) {
            .binary_expr => |be| {
                // Compound conditions: walk both sides of `and` / `or`
                if (std.mem.eql(u8, be.op, "and") or std.mem.eql(u8, be.op, "or")) {
                    self.extractTypeChecks(be.left, scope);
                    self.extractTypeChecks(be.right, scope);
                    return;
                }
                // Direct type check: @type(x) == Error / @type(x) != null
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
            },
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
    fn checkScopeExit(self: *PropChecker, scope: *PropScope) anyerror!void {
        var it = scope.vars.iterator();
        while (it.next()) |entry| {
            const uvar = entry.value_ptr.*;
            if (!uvar.handled) {
                if (scope.func_returns_error) {
                    // OK — will automatically propagate with trace
                } else {
                    const kind = if (uvar.is_error_union) K.Type.ERROR else K.Type.NULL;
                    const loc: ?errors.SourceLoc = if (uvar.line > 0)
                        .{ .file = self.source_file, .line = uvar.line, .col = uvar.col }
                    else
                        null;
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "unhandled {s} union '{s}' — enclosing function cannot propagate",
                        .{ kind, uvar.name });
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = loc });
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

/// Check if a block contains an early exit (return, break, continue)
fn blockHasEarlyExit(node: *parser.Node) bool {
    if (node.* != .block) return nodeIsEarlyExit(node);
    for (node.block.statements) |stmt| {
        if (nodeIsEarlyExit(stmt)) return true;
    }
    return false;
}

fn nodeIsEarlyExit(node: *parser.Node) bool {
    return switch (node.*) {
        .return_stmt => true,
        .break_stmt => true,
        .continue_stmt => true,
        .block => blockHasEarlyExit(node),
        .if_stmt => |i| blk: {
            // if+else where both branches exit
            const else_block = i.else_block orelse break :blk false;
            break :blk blockHasEarlyExit(i.then_block) and blockHasEarlyExit(else_block);
        },
        else => false,
    };
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

    try checker.checkScopeExit(&scope);
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

    try checker.checkScopeExit(&scope);
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
        .param_nodes = &.{},
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

    // Build: if(@type(result) != null) { return } — desugared from `if(result is not null)`
    var result_id = parser.Node{ .identifier = "result" };
    var type_args_arr = [_]*parser.Node{&result_id};
    var type_call = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &type_args_arr } };
    var null_node = parser.Node{ .type_named = K.Type.NULL };
    var condition = parser.Node{ .binary_expr = .{ .left = &type_call, .op = "!=", .right = &null_node } };
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
    const uvar = scope.vars.get("result").?;
    try std.testing.expect(uvar.handled);
}

test "propagation - return marks union as handled" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    var scope = PropScope.init(alloc, null, true);
    defer scope.deinit();

    // Define a union var
    try scope.define("result", true, 1, 1);

    // return result — passes union to caller
    var result_id = parser.Node{ .identifier = "result" };
    var ret = parser.Node{ .return_stmt = .{ .value = &result_id } };
    try checker.checkStatement(&ret, &scope);

    const uvar = scope.vars.get("result").?;
    try std.testing.expect(uvar.handled);
}

test "propagation - assignment propagation tracks union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    var scope = PropScope.init(alloc, null, false);
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

    const y_var = scope.vars.get("y").?;
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
        .param_nodes = &.{},
        .return_type = .{ .error_union = inner },
        .return_type_node = ret_node,
        .is_compt = false,
        .is_pub = false,
    });

    var checker = PropChecker.init(alloc, &reporter, &decl_table);

    var scope = PropScope.init(alloc, null, false);
    defer scope.deinit();

    // Define result, mark as handled
    try scope.define("result", true, 1, 1);
    scope.markHandled("result");
    try std.testing.expect(scope.vars.get("result").?.handled);

    // Reassign: result = divide(5, 0) — should reset to unhandled
    var result_id = parser.Node{ .identifier = "result" };
    var callee = parser.Node{ .identifier = "divide" };
    var call_node = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &[_]*parser.Node{},
        .arg_names = &.{},
    } };
    var assign = parser.Node{ .assignment = .{ .op = "=", .left = &result_id, .right = &call_node } };
    try checker.checkStatement(&assign, &scope);

    try std.testing.expect(!scope.vars.get("result").?.handled);
}

test "propagation - compound condition handles multiple unions" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = PropChecker.init(alloc, &reporter, null);

    var scope = PropScope.init(alloc, null, false);
    defer scope.deinit();

    // Define two union variables
    try scope.define("x", true, 1, 1);
    try scope.define("y", false, 2, 1);

    // Build: if(@type(x) == Error and @type(y) != null)
    var x_id = parser.Node{ .identifier = "x" };
    var x_args = [_]*parser.Node{&x_id};
    var x_type = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &x_args } };
    var error_node = parser.Node{ .type_named = K.Type.ERROR };
    var left_cond = parser.Node{ .binary_expr = .{ .left = &x_type, .op = "==", .right = &error_node } };

    var y_id = parser.Node{ .identifier = "y" };
    var y_args = [_]*parser.Node{&y_id};
    var y_type = parser.Node{ .compiler_func = .{ .name = K.Type.TYPE, .args = &y_args } };
    var null_node = parser.Node{ .type_named = K.Type.NULL };
    var right_cond = parser.Node{ .binary_expr = .{ .left = &y_type, .op = "!=", .right = &null_node } };

    var compound = parser.Node{ .binary_expr = .{ .left = &left_cond, .op = "and", .right = &right_cond } };
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
    try std.testing.expect(scope.vars.get("x").?.handled);
    try std.testing.expect(scope.vars.get("y").?.handled);
}

test "propagation - scope isTracked walks parents" {
    const alloc = std.testing.allocator;

    var parent = PropScope.init(alloc, null, true);
    defer parent.deinit();

    try parent.define("x", true, 1, 1);

    var child = PropScope.init(alloc, &parent, true);
    defer child.deinit();

    // x should be visible from child scope
    const tracked = child.isTracked("x");
    try std.testing.expect(tracked != null);
    try std.testing.expect(tracked.?.is_error_union);

    // y should not be tracked
    try std.testing.expect(child.isTracked("y") == null);
}
