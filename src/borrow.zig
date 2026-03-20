// borrow.zig — Borrow Checking pass (pass 7)
// Validates const &T and var &T borrows.
// No simultaneous mutable and immutable borrows.
// Lexical lifetimes only.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");

/// A borrow record — tracks active borrows
pub const Borrow = struct {
    variable: []const u8,
    is_mutable: bool,
    scope_depth: usize,
};

/// The borrow checker
pub const BorrowChecker = struct {
    active_borrows: std.ArrayListUnmanaged(Borrow),
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    scope_depth: usize,
    locs: ?*const parser.LocMap,
    source_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) BorrowChecker {
        return .{
            .active_borrows = .{},
            .reporter = reporter,
            .allocator = allocator,
            .scope_depth = 0,
            .locs = null,
            .source_file = "",
        };
    }

    fn nodeLoc(self: *const BorrowChecker, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn deinit(self: *BorrowChecker) void {
        self.active_borrows.deinit(self.allocator);
    }

    pub fn check(self: *BorrowChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.checkNode(node);
        }
    }

    fn checkNode(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                self.scope_depth += 1;
                try self.checkNode(f.body);
                self.dropBorrowsAtDepth(self.scope_depth);
                self.scope_depth -= 1;
            },
            .block => |b| {
                self.scope_depth += 1;
                for (b.statements) |stmt| {
                    try self.checkStatement(stmt);
                }
                self.dropBorrowsAtDepth(self.scope_depth);
                self.scope_depth -= 1;
            },
            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) try self.checkNode(member);
                }
            },
            else => {},
        }
    }

    fn checkStatement(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .var_decl => |v| {
                // If the type is var &T and value is &x, it's a mutable borrow
                if (v.value.* == .borrow_expr) {
                    const is_mut = isMutableBorrowType(v.type_annotation);
                    if (v.value.borrow_expr.* == .identifier) {
                        try self.addBorrow(v.value.borrow_expr.identifier, is_mut);
                    }
                } else {
                    try self.checkExpr(v.value);
                }
            },
            .const_decl => |v| {
                // const declarations with borrows are always immutable
                if (v.value.* == .borrow_expr) {
                    if (v.value.borrow_expr.* == .identifier) {
                        try self.addBorrow(v.value.borrow_expr.identifier, false);
                    }
                } else {
                    try self.checkExpr(v.value);
                }
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    // Cannot return a reference — only owned values
                    if (val.* == .borrow_expr) {
                        try self.reporter.report(.{
                            .message = "cannot return a reference — functions can only return owned values",
                            .loc = self.nodeLoc(node),
                        });
                    }
                    try self.checkExpr(val);
                }
            },
            .if_stmt => |i| {
                try self.checkExpr(i.condition);
                try self.checkNode(i.then_block);
                if (i.else_block) |e| try self.checkNode(e);
            },
            .while_stmt => |w| {
                try self.checkExpr(w.condition);
                if (w.continue_expr) |c| try self.checkExpr(c);
                try self.checkNode(w.body);
            },
            .for_stmt => |f| {
                try self.checkExpr(f.iterable);
                try self.checkNode(f.body);
            },
            .match_stmt => |m| {
                try self.checkExpr(m.value);
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        try self.checkNode(arm.match_arm.body);
                    }
                }
            },
            .defer_stmt => |d| {
                try self.checkNode(d.body);
            },
            .assignment => |a| {
                // If assigning a borrow, check for conflicts
                if (a.right.* == .borrow_expr) {
                    const is_mut = isMutableBorrowType(null); // no type context in assignment
                    if (a.right.borrow_expr.* == .identifier) {
                        try self.addBorrow(a.right.borrow_expr.identifier, is_mut);
                    }
                }
                // Check that borrowed variables aren't used while mutably borrowed
                try self.checkExprAccess(a.left);
                try self.checkExpr(a.right);
            },
            .block => try self.checkNode(node),
            else => try self.checkExpr(node),
        }
    }

    fn checkExpr(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .borrow_expr => |inner| {
                // Bare & in expression context (e.g. function call arg) — default immutable
                if (inner.* == .identifier) {
                    try self.addBorrow(inner.identifier, false);
                }
                try self.checkExpr(inner);
            },
            .identifier => |name| {
                // Check if this variable is mutably borrowed — can't use it
                try self.checkNotMutablyBorrowed(name);
            },
            .call_expr => |c| {
                try self.checkExpr(c.callee);
                for (c.args) |arg| try self.checkExpr(arg);
            },
            .binary_expr => |b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary_expr => |u| try self.checkExpr(u.operand),
            .field_expr => |f| try self.checkExpr(f.object),
            .index_expr => |i| {
                try self.checkExpr(i.object);
                try self.checkExpr(i.index);
            },
            .slice_expr => |s| {
                try self.checkExpr(s.object);
                try self.checkExpr(s.low);
                try self.checkExpr(s.high);
            },
            .compiler_func => |cf| {
                for (cf.args) |arg| try self.checkExpr(arg);
            },
            else => {},
        }
    }

    /// Check if accessing a variable that is mutably borrowed
    fn checkExprAccess(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .identifier => |name| try self.checkNotMutablyBorrowed(name),
            .field_expr => |f| try self.checkExprAccess(f.object),
            .index_expr => |i| try self.checkExprAccess(i.object),
            .slice_expr => |s| try self.checkExprAccess(s.object),
            else => {},
        }
    }

    /// Error if a variable has an active mutable borrow
    fn checkNotMutablyBorrowed(self: *BorrowChecker, name: []const u8) !void {
        for (self.active_borrows.items) |b| {
            if (std.mem.eql(u8, b.variable, name) and b.is_mutable) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "cannot use '{s}' while it is mutably borrowed", .{name});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
                return;
            }
        }
    }

    /// Add a borrow — check for conflicts
    fn addBorrow(self: *BorrowChecker, variable: []const u8, is_mutable: bool) !void {
        // Check existing borrows for conflicts
        for (self.active_borrows.items) |existing| {
            if (!std.mem.eql(u8, existing.variable, variable)) continue;

            if (is_mutable or existing.is_mutable) {
                // Mutable borrow conflicts with any existing borrow
                const msg = try std.fmt.allocPrint(self.allocator,
                    "cannot borrow '{s}' as {s}: already borrowed as {s}",
                    .{
                        variable,
                        if (is_mutable) "mutable" else "immutable",
                        if (existing.is_mutable) "mutable" else "immutable",
                    });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
                return;
            }
            // Multiple immutable borrows are fine
        }

        try self.active_borrows.append(self.allocator, .{
            .variable = variable,
            .is_mutable = is_mutable,
            .scope_depth = self.scope_depth,
        });
    }

    /// Drop all borrows at or deeper than the given depth (scope exit)
    fn dropBorrowsAtDepth(self: *BorrowChecker, depth: usize) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            if (self.active_borrows.items[i].scope_depth >= depth) {
                _ = self.active_borrows.swapRemove(i);
            }
        }
    }
};

/// Check if a type annotation is a mutable borrow type (var &T)
fn isMutableBorrowType(type_ann: ?*parser.Node) bool {
    const ann = type_ann orelse return false;
    if (ann.* == .type_ptr) {
        return std.mem.eql(u8, ann.type_ptr.kind, K.Ptr.VAR_REF);
    }
    return false;
}

test "borrow checker - no conflict immutable borrows" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Two immutable borrows of same variable — OK
    try checker.addBorrow("x", false);
    try checker.addBorrow("x", false);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - mutable conflicts immutable" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Immutable borrow then mutable — conflict
    try checker.addBorrow("x", false);
    try checker.addBorrow("x", true);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - cannot return reference" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    var inner = parser.Node{ .identifier = "x" };
    var borrow = parser.Node{ .borrow_expr = &inner };
    var ret = parser.Node{ .return_stmt = .{ .value = &borrow } };

    try checker.checkStatement(&ret);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - mutable borrow via var &T type" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // First: immutable borrow
    try checker.addBorrow("data", false);

    // Then: var decl with var &T type = &data → mutable borrow → conflict
    var inner_type = parser.Node{ .type_named = "MyStruct" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = "var &", .elem = &inner_type } };
    var borrow_target = parser.Node{ .identifier = "data" };
    var borrow_val = parser.Node{ .borrow_expr = &borrow_target };
    var decl = parser.Node{ .var_decl = .{
        .name = "ref",
        .type_annotation = &type_ann,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - const &T borrow is immutable" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Two const &T borrows — should be fine
    var inner_type = parser.Node{ .type_named = "MyStruct" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = "const &", .elem = &inner_type } };
    var borrow_target = parser.Node{ .identifier = "data" };
    var borrow_val = parser.Node{ .borrow_expr = &borrow_target };
    var decl1 = parser.Node{ .var_decl = .{
        .name = "ref1",
        .type_annotation = &type_ann,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl1);

    var borrow_target2 = parser.Node{ .identifier = "data" };
    var borrow_val2 = parser.Node{ .borrow_expr = &borrow_target2 };
    var decl2 = parser.Node{ .var_decl = .{
        .name = "ref2",
        .type_annotation = &type_ann,
        .value = &borrow_val2,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl2);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - cannot use while mutably borrowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Mutable borrow of x
    try checker.addBorrow("x", true);

    // Try to use x directly — should error
    var id = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - scope drops borrows" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Borrow at depth 1
    checker.scope_depth = 1;
    try checker.addBorrow("x", true);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Exit scope — borrow should be dropped
    checker.dropBorrowsAtDepth(1);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);

    // Now x can be used again (no active borrows)
    var id = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id);
    try std.testing.expect(!reporter.hasErrors());
}
