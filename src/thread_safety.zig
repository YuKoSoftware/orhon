// thread_safety.zig — Thread Safety Analysis pass (pass 8)
// Ensures values moved into threads are not used after spawn.
// Ensures all threads are joined (.value or .wait()) before scope exit.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");

/// Tracks which variables have been moved into threads
pub const ThreadSafetyChecker = struct {
    moved_to_thread: std.StringHashMap([]const u8), // var_name → thread_name
    declared_threads: std.StringHashMap(void), // thread names declared in current scope
    joined_threads: std.StringHashMap(void), // thread names that had .value or .wait()
    consumed_threads: std.StringHashMap(void), // threads whose .value has been consumed (move)
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    locs: ?*const parser.LocMap,
    file_offsets: []const module.FileOffset,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) ThreadSafetyChecker {
        return .{
            .moved_to_thread = std.StringHashMap([]const u8).init(allocator),
            .declared_threads = std.StringHashMap(void).init(allocator),
            .joined_threads = std.StringHashMap(void).init(allocator),
            .consumed_threads = std.StringHashMap(void).init(allocator),
            .reporter = reporter,
            .allocator = allocator,
            .locs = null,
            .file_offsets = &.{},
        };
    }

    pub fn deinit(self: *ThreadSafetyChecker) void {
        self.moved_to_thread.deinit();
        self.declared_threads.deinit();
        self.joined_threads.deinit();
        self.consumed_threads.deinit();
    }

    fn nodeLoc(self: *const ThreadSafetyChecker, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                const resolved = module.resolveFileLoc(self.file_offsets, loc.line);
                return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn check(self: *ThreadSafetyChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.checkNode(node);
        }
    }

    fn checkNode(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                // Save/restore thread tracking per function
                const prev_declared = self.declared_threads;
                const prev_joined = self.joined_threads;
                const prev_moved = self.moved_to_thread;
                const prev_consumed = self.consumed_threads;
                self.declared_threads = std.StringHashMap(void).init(self.allocator);
                self.joined_threads = std.StringHashMap(void).init(self.allocator);
                self.moved_to_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.consumed_threads = std.StringHashMap(void).init(self.allocator);
                defer {
                    self.declared_threads.deinit();
                    self.joined_threads.deinit();
                    self.moved_to_thread.deinit();
                    self.consumed_threads.deinit();
                    self.declared_threads = prev_declared;
                    self.joined_threads = prev_joined;
                    self.moved_to_thread = prev_moved;
                    self.consumed_threads = prev_consumed;
                }
                try self.checkNode(f.body);
                // Check for unjoined threads at function exit
                try self.checkUnjoinedThreads();
            },
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.checkStatement(stmt);
                }
            },
            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) try self.checkNode(member);
                }
            },
            .enum_decl => |e| {
                for (e.members) |member| {
                    if (member.* == .func_decl) try self.checkNode(member);
                }
            },
            .test_decl => |t| {
                // Treat test bodies like function bodies for thread safety
                const prev_declared = self.declared_threads;
                const prev_joined = self.joined_threads;
                const prev_moved = self.moved_to_thread;
                const prev_consumed = self.consumed_threads;
                self.declared_threads = std.StringHashMap(void).init(self.allocator);
                self.joined_threads = std.StringHashMap(void).init(self.allocator);
                self.moved_to_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.consumed_threads = std.StringHashMap(void).init(self.allocator);
                defer {
                    self.declared_threads.deinit();
                    self.joined_threads.deinit();
                    self.moved_to_thread.deinit();
                    self.consumed_threads.deinit();
                    self.declared_threads = prev_declared;
                    self.joined_threads = prev_joined;
                    self.moved_to_thread = prev_moved;
                    self.consumed_threads = prev_consumed;
                }
                try self.checkNode(t.body);
                try self.checkUnjoinedThreads();
            },
            else => {},
        }
    }

    fn checkStatement(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl => |v| {
                // Register Handle variables as thread handles
                if (isHandleType(v.type_annotation)) {
                    try self.declared_threads.put(v.name, {});
                }
                // Check if using a value that was moved into a thread
                try self.checkExprForThreadMoves(v.value);
                // Check for .value join via: const x = handle.value
                try self.checkJoinExpr(v.value);
            },

            .assignment => |a| {
                try self.checkExprForThreadMoves(a.right);
                // Check for .value join via: x = thread_name.value
                try self.checkJoinExpr(a.right);
            },

            .call_expr => |c| {
                // Check for handle.wait() / handle.join() calls
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        const method = fe.field;
                        if ((std.mem.eql(u8, method, "wait") or std.mem.eql(u8, method, "join")) and
                            self.declared_threads.contains(fe.object.identifier))
                        {
                            try self.joined_threads.put(fe.object.identifier, {});
                            if (std.mem.eql(u8, method, "join")) {
                                try self.consumed_threads.put(fe.object.identifier, {});
                            }
                        }
                    }
                }
                try self.checkExprForThreadMoves(node);
            },

            .return_stmt => |r| {
                if (r.value) |v| {
                    try self.checkJoinExpr(v);
                    try self.checkExprForThreadMoves(v);
                }
            },

            .if_stmt => |i| {
                try self.checkExprForThreadMoves(i.condition);
                try self.checkNode(i.then_block);
                if (i.else_block) |e| try self.checkNode(e);
            },

            .while_stmt => |w| {
                try self.checkExprForThreadMoves(w.condition);
                try self.checkNode(w.body);
            },

            .for_stmt => |f| {
                try self.checkExprForThreadMoves(f.iterable);
                try self.checkNode(f.body);
            },

            .match_stmt => |m| {
                try self.checkExprForThreadMoves(m.value);
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) try self.checkNode(arm.match_arm.body);
                }
            },

            .defer_stmt => |d| {
                try self.checkNode(d.body);
            },

            .destruct_decl => |d| {
                try self.checkExprForThreadMoves(d.value);
            },

            .compt_decl => |v| {
                try self.checkExprForThreadMoves(v.value);
            },

            .break_stmt, .continue_stmt => {},

            .block => try self.checkNode(node),

            else => try self.checkExprForThreadMoves(node),
        }
    }

    /// Recursively check if an expression contains thread joins (thread_name.value)
    fn checkJoinExpr(self: *ThreadSafetyChecker, expr: *parser.Node) anyerror!void {
        switch (expr.*) {
            .field_expr => |fe| {
                if (fe.object.* == .identifier and std.mem.eql(u8, fe.field, "value")) {
                    const name = fe.object.identifier;
                    if (self.declared_threads.contains(name)) {
                        // Check for second .value call — .value is a move
                        if (self.consumed_threads.contains(name)) {
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "thread '{s}' .value already consumed — .value is a move, can only be called once",
                                .{name});
                            defer self.allocator.free(msg);
                            try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(expr) });
                            return;
                        }
                        try self.joined_threads.put(name, {});
                        try self.consumed_threads.put(name, {});
                        _ = self.moved_to_thread.remove(name);
                    }
                }
            },
            .binary_expr => |b| {
                try self.checkJoinExpr(b.left);
                try self.checkJoinExpr(b.right);
            },
            .call_expr => |c| {
                try self.checkJoinExpr(c.callee);
                for (c.args) |arg| try self.checkJoinExpr(arg);
            },
            else => {},
        }
    }

    /// Error on any threads not joined before scope exit
    fn checkUnjoinedThreads(self: *ThreadSafetyChecker) anyerror!void {
        var it = self.declared_threads.iterator();
        while (it.next()) |entry| {
            const thread_name = entry.key_ptr.*;
            if (!self.joined_threads.contains(thread_name)) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "thread '{s}' must be joined before scope exit — use .value or .wait()",
                    .{thread_name});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            }
        }
    }

    fn checkExprForThreadMoves(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .identifier => |name| {
                if (self.moved_to_thread.get(name)) |thread_name| {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "use of '{s}' after it was moved into thread '{s}'",
                        .{ name, thread_name });
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
            },
            .binary_expr => |b| {
                try self.checkExprForThreadMoves(b.left);
                try self.checkExprForThreadMoves(b.right);
            },
            .call_expr => |c| {
                try self.checkExprForThreadMoves(c.callee);
                for (c.args) |arg| try self.checkExprForThreadMoves(arg);
            },
            .field_expr => |f| try self.checkExprForThreadMoves(f.object),
            .index_expr => |i| {
                try self.checkExprForThreadMoves(i.object);
                try self.checkExprForThreadMoves(i.index);
            },
            .slice_expr => |s| {
                try self.checkExprForThreadMoves(s.object);
                try self.checkExprForThreadMoves(s.low);
                try self.checkExprForThreadMoves(s.high);
            },
            else => {},
        }
    }

    fn collectUsedVars(self: *ThreadSafetyChecker, node: *parser.Node, vars: *std.StringHashMap(void)) anyerror!void {
        switch (node.*) {
            .identifier => |name| try vars.put(name, {}),
            .block => |b| {
                for (b.statements) |stmt| try self.collectUsedVars(stmt, vars);
            },
            .binary_expr => |b| {
                try self.collectUsedVars(b.left, vars);
                try self.collectUsedVars(b.right, vars);
            },
            .unary_expr => |u| try self.collectUsedVars(u.operand, vars),
            .call_expr => |c| {
                // Only capture callee if method call (field_expr), not plain function name
                if (c.callee.* == .field_expr) try self.collectUsedVars(c.callee, vars);
                for (c.args) |arg| try self.collectUsedVars(arg, vars);
            },
            .return_stmt => |r| {
                if (r.value) |v| try self.collectUsedVars(v, vars);
            },
            .var_decl, .const_decl => |v| try self.collectUsedVars(v.value, vars),
            .assignment => |a| {
                try self.collectUsedVars(a.left, vars);
                try self.collectUsedVars(a.right, vars);
            },
            .field_expr => |f| try self.collectUsedVars(f.object, vars),
            .index_expr => |i| {
                try self.collectUsedVars(i.object, vars);
                try self.collectUsedVars(i.index, vars);
            },
            .slice_expr => |s| {
                try self.collectUsedVars(s.object, vars);
                try self.collectUsedVars(s.low, vars);
                try self.collectUsedVars(s.high, vars);
            },
            .borrow_expr => |inner| try self.collectUsedVars(inner, vars),
            .compiler_func => |cf| {
                for (cf.args) |arg| try self.collectUsedVars(arg, vars);
            },
            .if_stmt => |i| {
                try self.collectUsedVars(i.condition, vars);
                try self.collectUsedVars(i.then_block, vars);
                if (i.else_block) |e| try self.collectUsedVars(e, vars);
            },
            .while_stmt => |w| {
                try self.collectUsedVars(w.condition, vars);
                if (w.continue_expr) |c| try self.collectUsedVars(c, vars);
                try self.collectUsedVars(w.body, vars);
            },
            .for_stmt => |f| {
                try self.collectUsedVars(f.iterable, vars);
                try self.collectUsedVars(f.body, vars);
            },
            .match_stmt => |m| {
                try self.collectUsedVars(m.value, vars);
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) try self.collectUsedVars(arm.match_arm.body, vars);
                }
            },
            .defer_stmt => |d| try self.collectUsedVars(d.body, vars),
            .destruct_decl => |d| try self.collectUsedVars(d.value, vars),
            else => {},
        }
    }

    /// Collect locally declared variable names in a body
    fn collectLocalDecls(node: *parser.Node, decls: *std.StringHashMap(void)) anyerror!void {
        switch (node.*) {
            .block => |b| {
                for (b.statements) |stmt| try collectLocalDecls(stmt, decls);
            },
            .var_decl => |v| try decls.put(v.name, {}),
            .const_decl => |v| try decls.put(v.name, {}),
            .destruct_decl => |d| {
                for (d.names) |name| try decls.put(name, {});
            },
            .if_stmt => |i| {
                try collectLocalDecls(i.then_block, decls);
                if (i.else_block) |e| try collectLocalDecls(e, decls);
            },
            .while_stmt => |w| try collectLocalDecls(w.body, decls),
            .for_stmt => |f| {
                for (f.captures) |cap| try decls.put(cap, {});
                if (f.index_var) |idx| try decls.put(idx, {});
                try collectLocalDecls(f.body, decls);
            },
            else => {},
        }
    }
};

/// Check if a type annotation node is Handle(T)
fn isHandleType(type_ann: ?*parser.Node) bool {
    const t = type_ann orelse return false;
    return t.* == .type_generic and std.mem.eql(u8, t.type_generic.name, "Handle");
}

/// Collect variables that are borrowed (&x) in a node tree
fn collectBorrowedVars(node: *parser.Node, vars: *std.StringHashMap(void)) anyerror!void {
    switch (node.*) {
        .borrow_expr => |inner| {
            if (inner.* == .identifier) {
                try vars.put(inner.identifier, {});
            } else if (inner.* == .field_expr and inner.field_expr.object.* == .identifier) {
                try vars.put(inner.field_expr.object.identifier, {});
            }
        },
        .block => |b| {
            for (b.statements) |stmt| try collectBorrowedVars(stmt, vars);
        },
        .var_decl, .const_decl => |v| try collectBorrowedVars(v.value, vars),
        .assignment => |a| {
            try collectBorrowedVars(a.left, vars);
            try collectBorrowedVars(a.right, vars);
        },
        .call_expr => |c| {
            try collectBorrowedVars(c.callee, vars);
            for (c.args) |arg| try collectBorrowedVars(arg, vars);
        },
        .binary_expr => |b| {
            try collectBorrowedVars(b.left, vars);
            try collectBorrowedVars(b.right, vars);
        },
        .return_stmt => |r| {
            if (r.value) |v| try collectBorrowedVars(v, vars);
        },
        .if_stmt => |i| {
            try collectBorrowedVars(i.condition, vars);
            try collectBorrowedVars(i.then_block, vars);
            if (i.else_block) |e| try collectBorrowedVars(e, vars);
        },
        else => {},
    }
}

test "thread safety - use after move into thread" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Simulate: data moved into thread, then used after
    try checker.moved_to_thread.put("data", "my_thread");

    var id = parser.Node{ .identifier = "data" };
    try checker.checkExprForThreadMoves(&id);
    try std.testing.expect(reporter.hasErrors());
}

test "thread safety - clean state" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    var id = parser.Node{ .identifier = "x" };
    try checker.checkExprForThreadMoves(&id);
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - unjoined thread is error" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Simulate: thread declared but not joined
    try checker.declared_threads.put("worker", {});
    try checker.checkUnjoinedThreads();
    try std.testing.expect(reporter.hasErrors());
}

test "thread safety - joined thread is ok" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Simulate: thread declared and joined
    try checker.declared_threads.put("worker", {});
    try checker.joined_threads.put("worker", {});
    try checker.checkUnjoinedThreads();
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - second .value call is error" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    try checker.declared_threads.put("t", {});

    // First .value — ok
    var t_id = parser.Node{ .identifier = "t" };
    var val1 = parser.Node{ .field_expr = .{ .object = &t_id, .field = "value" } };
    try checker.checkJoinExpr(&val1);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(checker.consumed_threads.contains("t"));

    // Second .value — should error
    var t_id2 = parser.Node{ .identifier = "t" };
    var val2 = parser.Node{ .field_expr = .{ .object = &t_id2, .field = "value" } };
    try checker.checkJoinExpr(&val2);
    try std.testing.expect(reporter.hasErrors());
}

test "thread safety - collectUsedVars walks if/while/for" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Build: if(flag) { return data }
    var flag_id = parser.Node{ .identifier = "flag" };
    var data_id = parser.Node{ .identifier = "data" };
    var ret = parser.Node{ .return_stmt = .{ .value = &data_id } };
    var stmts = [_]*parser.Node{&ret};
    var body = parser.Node{ .block = .{ .statements = &stmts } };
    var if_node = parser.Node{ .if_stmt = .{
        .condition = &flag_id,
        .then_block = &body,
        .else_block = null,
    } };

    var used = std.StringHashMap(void).init(alloc);
    defer used.deinit();
    try checker.collectUsedVars(&if_node, &used);

    try std.testing.expect(used.contains("flag"));
    try std.testing.expect(used.contains("data"));
}

test "thread safety - collectBorrowedVars" {
    const alloc = std.testing.allocator;

    // Build: &x
    var x_id = parser.Node{ .identifier = "x" };
    var borrow = parser.Node{ .borrow_expr = &x_id };

    var borrows = std.StringHashMap(void).init(alloc);
    defer borrows.deinit();
    try collectBorrowedVars(&borrow, &borrows);

    try std.testing.expect(borrows.contains("x"));
}

test "thread safety - collectUsedVars walks unary and index" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = ThreadSafetyChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Build: -x
    var x_id = parser.Node{ .identifier = "x" };
    var neg = parser.Node{ .unary_expr = .{ .op = "-", .operand = &x_id } };

    var used = std.StringHashMap(void).init(alloc);
    defer used.deinit();
    try checker.collectUsedVars(&neg, &used);

    try std.testing.expect(used.contains("x"));
}
