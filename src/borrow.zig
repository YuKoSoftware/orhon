// borrow.zig — Borrow Checking pass (pass 7)
// Validates const &T and var &T borrows.
// No simultaneous mutable and immutable borrows.
// Lexical lifetimes only.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");

/// A borrow record — tracks active borrows
/// `field` is null for whole-variable borrows, non-null for field-level borrows.
pub const Borrow = struct {
    variable: []const u8,
    field: ?[]const u8,
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
    decls: ?*declarations.DeclTable,
    current_node: ?*parser.Node,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) BorrowChecker {
        return .{
            .active_borrows = .{},
            .reporter = reporter,
            .allocator = allocator,
            .scope_depth = 0,
            .locs = null,
            .source_file = "",
            .decls = null,
            .current_node = null,
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
            .test_decl => |t| {
                self.scope_depth += 1;
                try self.checkNode(t.body);
                self.dropBorrowsAtDepth(self.scope_depth);
                self.scope_depth -= 1;
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
            else => {},
        }
    }

    fn checkStatement(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        self.current_node = node;
        switch (node.*) {
            .var_decl => |v| {
                // If the type is var &T and value is &x, it's a mutable borrow
                if (v.value.* == .borrow_expr) {
                    const is_mut = isMutableBorrowType(v.type_annotation);
                    if (extractBorrowTarget(v.value.borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, is_mut);
                    }
                } else {
                    try self.checkExpr(v.value);
                }
            },
            .const_decl => |v| {
                // Borrow mutability comes from the type annotation (&T vs const &T),
                // not from const/var — const binding to &T is still a mutable borrow
                if (v.value.* == .borrow_expr) {
                    const is_mut = isMutableBorrowType(v.type_annotation);
                    if (extractBorrowTarget(v.value.borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, is_mut);
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
            .compt_decl => |v| {
                try self.checkExpr(v.value);
            },
            .destruct_decl => |d| {
                try self.checkExpr(d.value);
            },
            .break_stmt, .continue_stmt => {},
            .assignment => |a| {
                // If assigning a borrow, check for conflicts
                if (a.right.* == .borrow_expr) {
                    const is_mut = isMutableBorrowType(null); // no type context in assignment
                    if (extractBorrowTarget(a.right.borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, is_mut);
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
                if (extractBorrowTarget(inner)) |target| {
                    try self.addBorrow(target.variable, target.field, false);
                }
                try self.checkExpr(inner);
            },
            .identifier => |name| {
                // Check if this variable is mutably borrowed — can't use it
                try self.checkNotMutablyBorrowedPath(name, null);
            },
            .call_expr => |c| {
                // Method call: obj.method(args) — temporary borrow for duration of call
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        const obj_name = fe.object.identifier;
                        const method_name = fe.field;
                        // Look up method to check self parameter mutability
                        if (self.decls) |decls| {
                            if (decls.funcs.get(method_name)) |sig| {
                                if (sig.params.len > 0 and std.mem.eql(u8, sig.params[0].name, "self")) {
                                    const self_node = sig.param_nodes[0];
                                    if (self_node.* == .param) {
                                        const is_mut = isMutableBorrowType(self_node.param.type_annotation);
                                        // Temporary borrow: check conflicts, add, then remove after call
                                        try self.addBorrow(obj_name, null, is_mut);
                                        // Check args while borrow is active
                                        for (c.args) |arg| try self.checkExpr(arg);
                                        // Release temporary borrow
                                        self.removeLastBorrow(obj_name);
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }
                try self.checkExpr(c.callee);
                for (c.args) |arg| try self.checkExpr(arg);
            },
            .binary_expr => |b| {
                try self.checkExpr(b.left);
                try self.checkExpr(b.right);
            },
            .unary_expr => |u| try self.checkExpr(u.operand),
            .field_expr => {
                // Field access: check with field-level awareness
                if (extractBorrowTarget(node)) |target| {
                    try self.checkNotMutablyBorrowedPath(target.variable, target.field);
                } else {
                    // Cannot extract base — fall back to recursive check
                    try self.checkExpr(node.field_expr.object);
                }
            },
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

    /// Check if accessing a variable/field that is mutably borrowed
    fn checkExprAccess(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .identifier => |name| try self.checkNotMutablyBorrowedPath(name, null),
            .field_expr => {
                if (extractBorrowTarget(node)) |target| {
                    try self.checkNotMutablyBorrowedPath(target.variable, target.field);
                } else {
                    try self.checkExprAccess(node.field_expr.object);
                }
            },
            .index_expr => |i| try self.checkExprAccess(i.object),
            .slice_expr => |s| try self.checkExprAccess(s.object),
            else => {},
        }
    }

    /// Error if a variable/field has an active mutable borrow that overlaps.
    /// Bare variable access (field=null) is blocked by any mutable borrow on the variable.
    /// Field access (field!=null) is only blocked by whole-variable or same-field borrows.
    fn checkNotMutablyBorrowedPath(self: *BorrowChecker, name: []const u8, field: ?[]const u8) !void {
        for (self.active_borrows.items) |b| {
            if (!std.mem.eql(u8, b.variable, name) or !b.is_mutable) continue;
            if (!pathsOverlap(b.field, field)) continue;

            const loc = if (self.current_node) |cn| self.nodeLoc(cn) else null;
            if (field) |f| {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "cannot use '{s}.{s}' while it is mutably borrowed", .{ name, f });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            } else {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "cannot use '{s}' while it is mutably borrowed", .{name});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            }
            return;
        }
    }

    /// Add a borrow — check for conflicts (field-level aware)
    fn addBorrow(self: *BorrowChecker, variable: []const u8, field: ?[]const u8, is_mutable: bool) !void {
        // Check existing borrows for conflicts
        for (self.active_borrows.items) |existing| {
            if (!std.mem.eql(u8, existing.variable, variable)) continue;
            if (!pathsOverlap(existing.field, field)) continue;

            if (is_mutable or existing.is_mutable) {
                const loc = if (self.current_node) |cn| self.nodeLoc(cn) else null;
                const label = borrowLabel(variable, field);
                const msg = try std.fmt.allocPrint(self.allocator,
                    "cannot borrow '{s}' as {s}: already borrowed as {s}",
                    .{
                        label,
                        if (is_mutable) "mutable" else "immutable",
                        if (existing.is_mutable) "mutable" else "immutable",
                    });
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
                return;
            }
            // Multiple immutable borrows are fine
        }

        try self.active_borrows.append(self.allocator, .{
            .variable = variable,
            .field = field,
            .is_mutable = is_mutable,
            .scope_depth = self.scope_depth,
        });
    }

    /// Remove the last borrow for a variable (used for temporary method call borrows)
    fn removeLastBorrow(self: *BorrowChecker, variable: []const u8) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.active_borrows.items[i].variable, variable)) {
                _ = self.active_borrows.swapRemove(i);
                return;
            }
        }
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

/// Two borrow paths overlap if either is a whole-variable borrow (null)
/// or both refer to the same field.
fn pathsOverlap(field_a: ?[]const u8, field_b: ?[]const u8) bool {
    const a = field_a orelse return true; // whole variable overlaps everything
    const b = field_b orelse return true;
    return std.mem.eql(u8, a, b);
}

/// Format a borrow target for error messages: "var" or "var.field"
fn borrowLabel(variable: []const u8, field: ?[]const u8) []const u8 {
    // For error messages we just return the variable name — field info is
    // included by the caller when needed. This avoids allocation.
    _ = field;
    return variable;
}

/// Extract the base variable and optional field from a borrow target expression.
/// Handles: identifier("x") → (x, null), field_expr(ident("p"), "name") → (p, name)
/// For deeper chains like a.b.c, tracks the first field level from the base.
fn extractBorrowTarget(node: *parser.Node) ?struct { variable: []const u8, field: ?[]const u8 } {
    switch (node.*) {
        .identifier => |name| return .{ .variable = name, .field = null },
        .field_expr => |f| {
            if (f.object.* == .identifier) {
                return .{ .variable = f.object.identifier, .field = f.field };
            }
            // Deeper nesting: a.b.c → walk to base, track first-level field
            var current = f.object;
            while (current.* == .field_expr and current.field_expr.object.* != .identifier) {
                current = current.field_expr.object;
            }
            if (current.* == .field_expr and current.field_expr.object.* == .identifier) {
                return .{ .variable = current.field_expr.object.identifier, .field = current.field_expr.field };
            }
            return null;
        },
        else => return null,
    }
}

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
    try checker.addBorrow("x", null, false);
    try checker.addBorrow("x", null, false);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - mutable conflicts immutable" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Immutable borrow then mutable — conflict
    try checker.addBorrow("x", null, false);
    try checker.addBorrow("x", null, true);
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
    try checker.addBorrow("data", null, false);

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
    try checker.addBorrow("x", null, true);

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
    try checker.addBorrow("x", null, true);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Exit scope — borrow should be dropped
    checker.dropBorrowsAtDepth(1);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);

    // Now x can be used again (no active borrows)
    var id = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - sibling field borrows do not conflict" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Mutable borrow of p.name and p.health — different fields, no conflict
    try checker.addBorrow("p", "name", true);
    try checker.addBorrow("p", "health", true);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - same field mutable borrow conflicts" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Two mutable borrows of same field — conflict
    try checker.addBorrow("p", "name", true);
    try checker.addBorrow("p", "name", true);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - whole variable borrow conflicts with field borrow" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Whole variable borrow then field borrow — conflict
    try checker.addBorrow("p", null, true);
    try checker.addBorrow("p", "name", false);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - field access while sibling mutably borrowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true);

    // Access p.health — different field, should be fine
    var p_ident = parser.Node{ .identifier = "p" };
    var health_access = parser.Node{ .field_expr = .{ .object = &p_ident, .field = "health" } };
    try checker.checkExpr(&health_access);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - field access while same field mutably borrowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true);

    // Access p.name — same field, should error
    var p_ident = parser.Node{ .identifier = "p" };
    var name_access = parser.Node{ .field_expr = .{ .object = &p_ident, .field = "name" } };
    try checker.checkExpr(&name_access);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - bare variable access while field mutably borrowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true);

    // Access bare p — whole variable includes borrowed field, should error
    var p_ident = parser.Node{ .identifier = "p" };
    try checker.checkExpr(&p_ident);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - field borrow from borrow_expr field_expr" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = BorrowChecker.init(alloc, &reporter);
    defer checker.deinit();

    // Simulate: var ref: var &String = &p.name
    var inner_type = parser.Node{ .type_named = "String" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = "var &", .elem = &inner_type } };
    var p_ident = parser.Node{ .identifier = "p" };
    var field_access = parser.Node{ .field_expr = .{ .object = &p_ident, .field = "name" } };
    var borrow_val = parser.Node{ .borrow_expr = &field_access };
    var decl = parser.Node{ .var_decl = .{
        .name = "ref",
        .type_annotation = &type_ann,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl);
    try std.testing.expect(!reporter.hasErrors());

    // Now borrow p.health — should be fine (sibling)
    try checker.addBorrow("p", "health", true);
    try std.testing.expect(!reporter.hasErrors());

    // But borrow p.name again as mutable — should conflict
    try checker.addBorrow("p", "name", false);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - extractBorrowTarget" {
    // identifier
    var id = parser.Node{ .identifier = "x" };
    const t1 = extractBorrowTarget(&id).?;
    try std.testing.expectEqualStrings("x", t1.variable);
    try std.testing.expect(t1.field == null);

    // field_expr: p.name
    var p_ident = parser.Node{ .identifier = "p" };
    var field = parser.Node{ .field_expr = .{ .object = &p_ident, .field = "name" } };
    const t2 = extractBorrowTarget(&field).?;
    try std.testing.expectEqualStrings("p", t2.variable);
    try std.testing.expectEqualStrings("name", t2.field.?);

    // nested field_expr: a.b.c → tracks first-level field "b"
    var a_ident = parser.Node{ .identifier = "a" };
    var ab = parser.Node{ .field_expr = .{ .object = &a_ident, .field = "b" } };
    var abc = parser.Node{ .field_expr = .{ .object = &ab, .field = "c" } };
    const t3 = extractBorrowTarget(&abc).?;
    try std.testing.expectEqualStrings("a", t3.variable);
    try std.testing.expectEqualStrings("b", t3.field.?);
}

test "borrow checker - pathsOverlap" {
    // null overlaps with everything
    try std.testing.expect(pathsOverlap(null, null));
    try std.testing.expect(pathsOverlap(null, "name"));
    try std.testing.expect(pathsOverlap("name", null));

    // same field overlaps
    try std.testing.expect(pathsOverlap("name", "name"));

    // different fields do not overlap
    try std.testing.expect(!pathsOverlap("name", "health"));
}
