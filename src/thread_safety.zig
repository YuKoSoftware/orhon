// thread_safety.zig — Thread Safety Analysis pass (pass 8)
// Ensures values moved into threads are not used after spawn.
// Ensures all threads are joined (.value or .wait()) before scope exit.
// Enforces: owned args moved, const borrows freeze, mutable borrows rejected.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const sema = @import("sema.zig");

/// Tracks which variables have been moved into threads
pub const ThreadSafetyChecker = struct {
    moved_to_thread: std.StringHashMap([]const u8), // var_name → thread_name
    frozen_for_thread: std.StringHashMap([]const u8), // var_name → thread_name (const borrow freeze)
    declared_threads: std.StringHashMap(void), // thread names declared in current scope
    joined_threads: std.StringHashMap(void), // thread names that had .value or .wait()
    consumed_threads: std.StringHashMap(void), // threads whose .value has been consumed (move)
    ctx: *const sema.SemanticContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *const sema.SemanticContext) ThreadSafetyChecker {
        return .{
            .moved_to_thread = std.StringHashMap([]const u8).init(allocator),
            .frozen_for_thread = std.StringHashMap([]const u8).init(allocator),
            .declared_threads = std.StringHashMap(void).init(allocator),
            .joined_threads = std.StringHashMap(void).init(allocator),
            .consumed_threads = std.StringHashMap(void).init(allocator),
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadSafetyChecker) void {
        self.moved_to_thread.deinit();
        self.frozen_for_thread.deinit();
        self.declared_threads.deinit();
        self.joined_threads.deinit();
        self.consumed_threads.deinit();
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
                const prev_frozen = self.frozen_for_thread;
                const prev_consumed = self.consumed_threads;
                self.declared_threads = std.StringHashMap(void).init(self.allocator);
                self.joined_threads = std.StringHashMap(void).init(self.allocator);
                self.moved_to_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.frozen_for_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.consumed_threads = std.StringHashMap(void).init(self.allocator);
                defer {
                    self.declared_threads.deinit();
                    self.joined_threads.deinit();
                    self.moved_to_thread.deinit();
                    self.frozen_for_thread.deinit();
                    self.consumed_threads.deinit();
                    self.declared_threads = prev_declared;
                    self.joined_threads = prev_joined;
                    self.moved_to_thread = prev_moved;
                    self.frozen_for_thread = prev_frozen;
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
                const prev_frozen = self.frozen_for_thread;
                const prev_consumed = self.consumed_threads;
                self.declared_threads = std.StringHashMap(void).init(self.allocator);
                self.joined_threads = std.StringHashMap(void).init(self.allocator);
                self.moved_to_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.frozen_for_thread = std.StringHashMap([]const u8).init(self.allocator);
                self.consumed_threads = std.StringHashMap(void).init(self.allocator);
                defer {
                    self.declared_threads.deinit();
                    self.joined_threads.deinit();
                    self.moved_to_thread.deinit();
                    self.frozen_for_thread.deinit();
                    self.consumed_threads.deinit();
                    self.declared_threads = prev_declared;
                    self.joined_threads = prev_joined;
                    self.moved_to_thread = prev_moved;
                    self.frozen_for_thread = prev_frozen;
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
                // Check thread call arg enforcement on the value
                if (v.value.* == .call_expr) {
                    try self.checkThreadCallArgs(v.value);
                }
                // Check if using a value that was moved into a thread
                try self.checkExprForThreadMoves(v.value);
                // Check for .value join via: const x = handle.value
                try self.checkJoinExpr(v.value);
            },

            .assignment => |a| {
                // Check if assigning to a frozen variable (const-borrowed by a thread)
                if (a.left.* == .identifier) {
                    if (self.frozen_for_thread.get(a.left.identifier)) |thread_name| {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "cannot mutate '{s}' while it is borrowed by thread '{s}'",
                            .{ a.left.identifier, thread_name });
                        defer self.allocator.free(msg);
                        try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(node) });
                    }
                }
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
                            // Unfreeze variables frozen by this thread
                            try self.unfreezeForThread(fe.object.identifier);
                            if (std.mem.eql(u8, method, "join")) {
                                try self.consumed_threads.put(fe.object.identifier, {});
                            }
                        }
                    }
                }
                // Check thread call arg enforcement
                try self.checkThreadCallArgs(node);
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

    const declarations = @import("declarations.zig");

    /// Check if a call_expr calls a thread function. Returns the callee name and func sig.
    fn isThreadCall(self: *ThreadSafetyChecker, node: *parser.Node) ?struct { name: []const u8, sig: declarations.FuncSig } {
        if (node.* != .call_expr) return null;
        const c = node.call_expr;
        if (c.callee.* != .identifier) return null;
        const callee_name = c.callee.identifier;
        if (self.ctx.decls.funcs.get(callee_name)) |sig| {
            if (sig.context == .thread) return .{ .name = callee_name, .sig = sig };
        }
        return null;
    }

    /// Enforce thread arg rules: owned args move, const borrows freeze, mutable borrows rejected.
    fn checkThreadCallArgs(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        const info = self.isThreadCall(node) orelse return;
        const c = node.call_expr;
        const thread_name = info.name;

        for (c.args, 0..) |arg, i| {
            if (arg.* == .mut_borrow_expr) {
                // Check if the corresponding param is a mutable borrow (mut& T)
                if (i < info.sig.param_nodes.len) {
                    const param_node = info.sig.param_nodes[i];
                    if (param_node.* == .param) {
                        const type_ann = param_node.param.type_annotation;
                        if (type_ann.* == .type_ptr and
                            type_ann.type_ptr.kind == .mut_ref)
                        {
                            // Mutable borrow to thread — immediate error
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "cannot pass mutable borrow to thread '{s}' — mutable borrows across threads are unsafe",
                                .{thread_name});
                            defer self.allocator.free(msg);
                            try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(arg) });
                            continue;
                        }
                    }
                }
                // Const borrow — freeze the inner variable
                const inner = arg.mut_borrow_expr;
                if (inner.* == .identifier) {
                    try self.frozen_for_thread.put(inner.identifier, thread_name);
                }
            } else if (arg.* == .const_borrow_expr) {
                // Explicit const& borrow — always immutable, safe for threads
                const inner = arg.const_borrow_expr;
                if (inner.* == .identifier) {
                    try self.frozen_for_thread.put(inner.identifier, thread_name);
                }
            } else if (arg.* == .identifier) {
                // Owned value — move into thread
                try self.moved_to_thread.put(arg.identifier, thread_name);
            }
        }
    }

    /// Remove frozen entries for a specific thread (called on join/wait)
    fn unfreezeForThread(self: *ThreadSafetyChecker, thread_name: []const u8) anyerror!void {
        // Collect keys to remove (can't modify during iteration)
        var to_remove: [32][]const u8 = undefined;
        var remove_count: usize = 0;

        var it = self.frozen_for_thread.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, thread_name)) {
                if (remove_count < to_remove.len) {
                    to_remove[remove_count] = entry.key_ptr.*;
                    remove_count += 1;
                }
            }
        }
        for (to_remove[0..remove_count]) |key| {
            _ = self.frozen_for_thread.remove(key);
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
                            try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(expr) });
                            return;
                        }
                        try self.joined_threads.put(name, {});
                        try self.consumed_threads.put(name, {});
                        _ = self.moved_to_thread.remove(name);
                        // Unfreeze variables frozen by this thread
                        try self.unfreezeForThread(name);
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
                try self.ctx.reporter.report(.{ .message = msg });
            }
        }
    }

    fn checkExprForThreadMoves(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .identifier => |name| {
                if (self.moved_to_thread.get(name)) |thread_name| {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "use of '{s}' after it was moved into thread '{s}' — shared mutable state requires synchronization",
                        .{ name, thread_name });
                    defer self.allocator.free(msg);
                    try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(node) });
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
            .mut_borrow_expr => |inner| try self.collectUsedVars(inner, vars),
            .const_borrow_expr => |inner| try self.collectUsedVars(inner, vars),
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

/// Collect variables that are borrowed (mut& x or const& x) in a node tree
fn collectBorrowedVars(node: *parser.Node, vars: *std.StringHashMap(void)) anyerror!void {
    switch (node.*) {
        .mut_borrow_expr => |inner| {
            if (inner.* == .identifier) {
                try vars.put(inner.identifier, {});
            } else if (inner.* == .field_expr and inner.field_expr.object.* == .identifier) {
                try vars.put(inner.field_expr.object.identifier, {});
            }
        },
        .const_borrow_expr => |inner| {
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

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
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

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    var id = parser.Node{ .identifier = "x" };
    try checker.checkExprForThreadMoves(&id);
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - unjoined thread is error" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
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

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
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

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
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

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
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

    // Build: mut& x
    var x_id = parser.Node{ .identifier = "x" };
    var borrow = parser.Node{ .mut_borrow_expr = &x_id };

    var borrows = std.StringHashMap(void).init(alloc);
    defer borrows.deinit();
    try collectBorrowedVars(&borrow, &borrows);

    try std.testing.expect(borrows.contains("x"));
}

test "thread safety - collectUsedVars walks unary and index" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Build: -x
    var x_id = parser.Node{ .identifier = "x" };
    var neg = parser.Node{ .unary_expr = .{ .op = "-", .operand = &x_id } };

    var used = std.StringHashMap(void).init(alloc);
    defer used.deinit();
    try checker.collectUsedVars(&neg, &used);

    try std.testing.expect(used.contains("x"));
}

test "thread safety - owned arg moved into thread" {
    const alloc = std.testing.allocator;
    const declarations = @import("declarations.zig");
    const types = @import("types.zig");
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register a thread function: thread consumer(data: i32) Handle(i32)
    var void_node = parser.Node{ .identifier = "void" };
    var i32_node = parser.Node{ .identifier = "i32" };
    var param_node = parser.Node{ .param = .{
        .name = "data",
        .type_annotation = &i32_node,
        .default_value = null,
    } };
    var param_nodes = [_]*parser.Node{&param_node};
    try decl_table.funcs.put("consumer", .{
        .name = "consumer",
        .params = &.{},
        .param_nodes = &param_nodes,
        .return_type = types.ResolvedType{ .primitive = .void },
        .return_type_node = &void_node,
        .context = .thread,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Build: consumer(x) — call thread func with owned arg
    var callee = parser.Node{ .identifier = "consumer" };
    var x_arg = parser.Node{ .identifier = "x" };
    var args = [_]*parser.Node{&x_arg};
    var arg_names = [_][]const u8{""};
    var call = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
    } };

    try checker.checkThreadCallArgs(&call);
    try std.testing.expect(checker.moved_to_thread.contains("x"));
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - const borrow arg freezes variable" {
    const alloc = std.testing.allocator;
    const declarations = @import("declarations.zig");
    const types = @import("types.zig");
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register: thread reader(val: &i32) Handle(void)
    var void_node = parser.Node{ .identifier = "void" };
    var i32_elem = parser.Node{ .identifier = "i32" };
    var param_type = parser.Node{ .type_ptr = .{
        .kind = .const_ref,
        .elem = &i32_elem,
    } };
    var param_node = parser.Node{ .param = .{
        .name = "val",
        .type_annotation = &param_type,
        .default_value = null,
    } };
    var param_nodes = [_]*parser.Node{&param_node};
    try decl_table.funcs.put("reader", .{
        .name = "reader",
        .params = &.{},
        .param_nodes = &param_nodes,
        .return_type = types.ResolvedType{ .primitive = .void },
        .return_type_node = &void_node,
        .context = .thread,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Build: reader(mut& x) — const borrow to thread
    var callee = parser.Node{ .identifier = "reader" };
    var x_inner = parser.Node{ .identifier = "x" };
    var borrow_arg = parser.Node{ .mut_borrow_expr = &x_inner };
    var args = [_]*parser.Node{&borrow_arg};
    var arg_names = [_][]const u8{""};
    var call = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
    } };

    try checker.checkThreadCallArgs(&call);
    try std.testing.expect(checker.frozen_for_thread.contains("x"));
    try std.testing.expect(!reporter.hasErrors());

    // Now simulate assignment to frozen x — should error
    var x_left = parser.Node{ .identifier = "x" };
    var lit = parser.Node{ .int_literal = "20" };
    var assignment = parser.Node{ .assignment = .{
        .left = &x_left,
        .right = &lit,
        .op = "=",
    } };
    try checker.checkStatement(&assignment);
    try std.testing.expect(reporter.hasErrors());
}

test "thread safety - mutable borrow arg rejected" {
    const alloc = std.testing.allocator;
    const declarations = @import("declarations.zig");
    const types = @import("types.zig");
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register: thread writer(val: var &i32) Handle(void)
    var void_node = parser.Node{ .identifier = "void" };
    var i32_elem = parser.Node{ .identifier = "i32" };
    var param_type = parser.Node{ .type_ptr = .{
        .kind = .mut_ref,
        .elem = &i32_elem,
    } };
    var param_node = parser.Node{ .param = .{
        .name = "val",
        .type_annotation = &param_type,
        .default_value = null,
    } };
    var param_nodes = [_]*parser.Node{&param_node};
    try decl_table.funcs.put("writer", .{
        .name = "writer",
        .params = &.{},
        .param_nodes = &param_nodes,
        .return_type = types.ResolvedType{ .primitive = .void },
        .return_type_node = &void_node,
        .context = .thread,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Build: writer(mut& x) — mutable borrow to thread
    var callee = parser.Node{ .identifier = "writer" };
    var x_inner = parser.Node{ .identifier = "x" };
    var borrow_arg = parser.Node{ .mut_borrow_expr = &x_inner };
    var args = [_]*parser.Node{&borrow_arg};
    var arg_names = [_][]const u8{""};
    var call = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
    } };

    try checker.checkThreadCallArgs(&call);
    try std.testing.expect(reporter.hasErrors());
}

test "thread safety - frozen var unfreezes after .value join" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Simulate: x is frozen for thread "t"
    try checker.frozen_for_thread.put("x", "t");
    try checker.declared_threads.put("t", {});

    // Simulate: t.value (join)
    var t_id = parser.Node{ .identifier = "t" };
    var val_expr = parser.Node{ .field_expr = .{ .object = &t_id, .field = "value" } };
    try checker.checkJoinExpr(&val_expr);

    // x should be unfrozen
    try std.testing.expect(!checker.frozen_for_thread.contains("x"));
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - frozen var unfreezes after .wait() join" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    const declarations = @import("declarations.zig");
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Simulate: x is frozen for thread "t"
    try checker.frozen_for_thread.put("x", "t");
    try checker.declared_threads.put("t", {});

    // Simulate: t.wait() — call_expr path, not field_expr path
    var t_id = parser.Node{ .identifier = "t" };
    var wait_field = parser.Node{ .field_expr = .{ .object = &t_id, .field = "wait" } };
    var no_args = [_]*parser.Node{};
    var no_names = [_][]const u8{};
    var wait_call = parser.Node{ .call_expr = .{
        .callee = &wait_field,
        .args = &no_args,
        .arg_names = &no_names,
    } };
    try checker.checkStatement(&wait_call);

    // x should be unfrozen
    try std.testing.expect(!checker.frozen_for_thread.contains("x"));
    try std.testing.expect(!reporter.hasErrors());
}

test "thread safety - multi-arg thread call: move + const borrow" {
    const alloc = std.testing.allocator;
    const declarations = @import("declarations.zig");
    const types = @import("types.zig");
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register: thread worker(a: i32, b: const& i32) Handle(void)
    var void_node = parser.Node{ .identifier = "void" };
    var i32_node = parser.Node{ .identifier = "i32" };
    var ref_node = parser.Node{ .type_ptr = .{ .kind = .const_ref, .elem = &i32_node } };
    var param_a = parser.Node{ .param = .{
        .name = "a",
        .type_annotation = &i32_node,
        .default_value = null,
    } };
    var param_b = parser.Node{ .param = .{
        .name = "b",
        .type_annotation = &ref_node,
        .default_value = null,
    } };
    var param_nodes = [_]*parser.Node{ &param_a, &param_b };
    try decl_table.funcs.put("worker", .{
        .name = "worker",
        .params = &.{},
        .param_nodes = &param_nodes,
        .return_type = types.ResolvedType{ .primitive = .void },
        .return_type_node = &void_node,
        .context = .thread,
        .is_pub = false,
    });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = ThreadSafetyChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Build: worker(x, mut& y) — owned move + const borrow
    var callee = parser.Node{ .identifier = "worker" };
    var x_arg = parser.Node{ .identifier = "x" };
    var y_id = parser.Node{ .identifier = "y" };
    var y_borrow = parser.Node{ .mut_borrow_expr = &y_id };
    var args = [_]*parser.Node{ &x_arg, &y_borrow };
    var arg_names = [_][]const u8{ "", "" };
    var call = parser.Node{ .call_expr = .{
        .callee = &callee,
        .args = &args,
        .arg_names = &arg_names,
    } };

    try checker.checkThreadCallArgs(&call);

    // x should be moved, y should be frozen
    try std.testing.expect(checker.moved_to_thread.contains("x"));
    try std.testing.expect(checker.frozen_for_thread.contains("y"));
    try std.testing.expect(!reporter.hasErrors());
}
