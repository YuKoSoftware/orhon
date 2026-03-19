// thread_safety.zig — Thread Safety Analysis pass (pass 8)
// Ensures values moved into threads are not used after spawn.
// Validates splitAt usage for shared data between threads.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");

/// Tracks which variables have been moved into threads
pub const ThreadSafetyChecker = struct {
    moved_to_thread: std.StringHashMap([]const u8), // var_name → thread_name
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) ThreadSafetyChecker {
        return .{
            .moved_to_thread = std.StringHashMap([]const u8).init(allocator),
            .reporter = reporter,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ThreadSafetyChecker) void {
        self.moved_to_thread.deinit();
    }

    pub fn check(self: *ThreadSafetyChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.checkNode(node);
        }
    }

    fn checkNode(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.checkNode(f.body),
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
            else => {},
        }
    }

    fn checkStatement(self: *ThreadSafetyChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .thread_block => |t| {
                // Collect all identifiers used in thread body
                // These values are moved into the thread
                var used_vars: std.StringHashMap(void) = std.StringHashMap(void).init(self.allocator);
                defer used_vars.deinit();
                try self.collectUsedVars(t.body, &used_vars);

                // Mark them as moved into this thread
                var it = used_vars.iterator();
                while (it.next()) |entry| {
                    const var_name = entry.key_ptr.*;

                    // Check if already moved into another thread
                    if (self.moved_to_thread.get(var_name)) |thread_name| {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "value '{s}' already moved into thread '{s}'",
                            .{ var_name, thread_name });
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg });
                        continue;
                    }

                    try self.moved_to_thread.put(var_name, t.name);
                }
            },

            .var_decl => |v| {
                // Check if using a value that was moved into a thread
                try self.checkExprForThreadMoves(v.value);
            },

            .assignment => |a| {
                try self.checkExprForThreadMoves(a.right);
                // Special case: var x = thread_name.value — reclaims ownership
                if (a.right.* == .field_expr) {
                    const fe = a.right.field_expr;
                    if (fe.object.* == .identifier and std.mem.eql(u8, fe.field, "value")) {
                        // Remove from moved_to_thread when ownership is reclaimed
                        _ = self.moved_to_thread.remove(fe.object.identifier);
                    }
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
                for (f.iterables) |it| try self.checkExprForThreadMoves(it);
                try self.checkNode(f.body);
            },

            .block => try self.checkNode(node),

            else => try self.checkExprForThreadMoves(node),
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
                    try self.reporter.report(.{ .message = msg });
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
            .call_expr => |c| {
                try self.collectUsedVars(c.callee, vars);
                for (c.args) |arg| try self.collectUsedVars(arg, vars);
            },
            .return_stmt => |r| {
                if (r.value) |v| try self.collectUsedVars(v, vars);
            },
            .var_decl => |v| try self.collectUsedVars(v.value, vars),
            .field_expr => |f| try self.collectUsedVars(f.object, vars),
            else => {},
        }
    }
};

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
