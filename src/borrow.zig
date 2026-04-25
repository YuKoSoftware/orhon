// borrow.zig — Borrow Checking pass (pass 7)
// Validates const& T and mut& T borrows.
// No simultaneous mutable and immutable borrows.
// Non-lexical lifetimes — borrows end at last use, not scope exit.

const std = @import("std");
const parser = @import("parser.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const sema = @import("sema.zig");
const types = @import("types.zig");
const checks_impl = @import("borrow_checks.zig");

/// A borrow record — tracks active borrows
/// `field` is null for whole-variable borrows, non-null for field-level borrows.
/// `borrow_ref` is the variable holding the reference (null for temporary borrows).
/// NLL uses `borrow_ref` to determine when the borrow can be dropped — at the last
/// use of the reference variable, not at scope exit.
pub const Borrow = struct {
    variable: []const u8,
    field: ?[]const u8,
    is_mutable: bool,
    scope_depth: usize,
    borrow_ref: ?[]const u8,
};

/// The borrow checker
pub const BorrowChecker = struct {
    active_borrows: std.ArrayListUnmanaged(Borrow),
    ctx: *const sema.SemanticContext,
    allocator: std.mem.Allocator,
    scope_depth: usize,
    current_node: ?*parser.Node,

    pub fn init(allocator: std.mem.Allocator, ctx: *const sema.SemanticContext) BorrowChecker {
        return .{
            .active_borrows = .{},
            .ctx = ctx,
            .allocator = allocator,
            .scope_depth = 0,
            .current_node = null,
        };
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

    pub fn checkNode(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                self.scope_depth += 1;
                try self.checkNode(f.body);
                self.dropBorrowsAtDepth(self.scope_depth);
                self.scope_depth -= 1;
            },
            .block => |b| {
                self.scope_depth += 1;
                // NLL: pre-scan to find last-use index for each variable
                var last_use = try buildLastUseMap(b.statements, self.allocator);
                defer last_use.deinit(self.allocator);
                for (b.statements, 0..) |stmt, idx| {
                    try self.checkStatement(stmt);
                    self.dropExpiredBorrows(&last_use, idx);
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
            .enum_decl => {},
            .handle_decl => {},
            else => {},
        }
    }

    pub fn checkStatement(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        return checks_impl.checkStatement(self, node);
    }

    pub fn checkExpr(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        return checks_impl.checkExpr(self, node);
    }

    /// Check if accessing a variable/field that is mutably borrowed
    pub fn checkExprAccess(self: *BorrowChecker, node: *parser.Node) anyerror!void {
        return checks_impl.checkExprAccess(self, node);
    }

    /// Error if a variable/field has an active mutable borrow that overlaps.
    /// Bare variable access (field=null) is blocked by any mutable borrow on the variable.
    /// Field access (field!=null) is only blocked by whole-variable or same-field borrows.
    pub fn checkNotMutablyBorrowedPath(self: *BorrowChecker, name: []const u8, field: ?[]const u8) !void {
        for (self.active_borrows.items) |b| {
            if (!std.mem.eql(u8, b.variable, name) or !b.is_mutable) continue;
            if (!pathsOverlap(b.field, field)) continue;

            const loc = if (self.current_node) |cn| self.ctx.nodeLoc(cn) else null;
            if (field) |f| {
                try self.ctx.reporter.reportFmt(.use_while_borrowed, loc, "cannot use '{s}.{s}' while it is mutably borrowed — consider borrowing with const&", .{ name, f });
            } else {
                try self.ctx.reporter.reportFmt(.use_while_borrowed, loc, "cannot use '{s}' while it is mutably borrowed — consider borrowing with const&", .{name});
            }
            return;
        }
    }

    /// Add a borrow — check for conflicts (field-level aware)
    /// `borrow_ref` is the variable holding the reference (null for temporaries).
    pub fn addBorrow(self: *BorrowChecker, variable: []const u8, field: ?[]const u8, is_mutable: bool, borrow_ref: ?[]const u8) !void {
        // Check existing borrows for conflicts
        for (self.active_borrows.items) |existing| {
            if (!std.mem.eql(u8, existing.variable, variable)) continue;
            if (!pathsOverlap(existing.field, field)) continue;

            if (is_mutable or existing.is_mutable) {
                const loc = if (self.current_node) |cn| self.ctx.nodeLoc(cn) else null;
                const label = borrowLabel(variable);
                const hint: []const u8 = if (!is_mutable)
                    " — consider borrowing with const&"
                else
                    "";
                try self.ctx.reporter.reportFmt(.borrow_conflict, loc, "cannot borrow '{s}' as {s}: already borrowed as {s}{s}",
                    .{
                        label,
                        if (is_mutable) "mutable" else "immutable",
                        if (existing.is_mutable) "mutable" else "immutable",
                        hint,
                    });
                return;
            }
            // Multiple immutable borrows are fine
        }

        try self.active_borrows.append(self.allocator, .{
            .variable = variable,
            .field = field,
            .is_mutable = is_mutable,
            .scope_depth = self.scope_depth,
            .borrow_ref = borrow_ref,
        });
    }

    /// Remove the last borrow for a variable (used for temporary method call borrows)
    pub fn removeLastBorrow(self: *BorrowChecker, variable: []const u8) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.active_borrows.items[i].variable, variable)) {
                _ = self.active_borrows.swapRemove(i);
                return;
            }
        }
    }

    /// Look up a struct method given the call's receiver node.
    ///
    /// Preferred path: read the receiver's ResolvedType from `ctx.type_map` (populated
    /// by pass 5), extract the owning struct name, and look up the method on that
    /// struct's `StructSig.methods` map. This picks the correct per-struct signature
    /// so `self` mutability is accurate.
    ///
    /// Fallback path (object_node == null, or receiver type unknown / not a named struct):
    /// scan every struct symbol's methods map and return the first match. This keeps
    /// older/partial call sites working but is the ambiguous path that caused CB1.
    pub fn lookupStructMethod(
        self: *BorrowChecker,
        object_node: ?*parser.Node,
        method_name: []const u8,
    ) ?declarations.FuncSig {
        if (object_node) |obj| {
            if (self.ctx.type_map) |tm| {
                if (tm.get(obj)) |rt| {
                    if (receiverStructName(rt)) |sname| {
                        if (self.ctx.decls.symbols.get(sname)) |sym| switch (sym) {
                            .@"struct" => |sig| if (sig.methods.get(method_name)) |m| return m,
                            else => {},
                        };
                    }
                }
            }
        }
        // Slow path: scan all struct symbols for a matching method name.
        var sym_it = self.ctx.decls.symbols.valueIterator();
        while (sym_it.next()) |sym| switch (sym.*) {
            .@"struct" => |sig| if (sig.methods.get(method_name)) |m| return m,
            else => {},
        };
        return null;
    }

    /// Extract the owning struct name from a receiver ResolvedType. Unwraps borrow
    /// references (`const& T`, `mut& T`) and matches both `.named` and `.generic` forms.
    fn receiverStructName(rt: types.ResolvedType) ?[]const u8 {
        return switch (rt) {
            .named => |n| n,
            .generic => |g| g.name,
            .ptr => |p| receiverStructName(p.elem.*),
            else => null,
        };
    }

    /// Drop all borrows at or deeper than the given depth (scope exit)
    pub fn dropBorrowsAtDepth(self: *BorrowChecker, depth: usize) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            if (self.active_borrows.items[i].scope_depth >= depth) {
                _ = self.active_borrows.swapRemove(i);
            }
        }
    }

    /// NLL: drop expired borrows after each statement.
    /// - Named borrows (borrow_ref != null): expire after last use of the ref variable
    /// - Expression-level borrows (borrow_ref == null): expire after the statement
    ///   that created them — these are borrows from function call args that should
    ///   not persist across statements
    pub fn dropExpiredBorrows(self: *BorrowChecker, last_use: *const std.StringHashMapUnmanaged(usize), current_idx: usize) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            const borrow = self.active_borrows.items[i];
            if (borrow.borrow_ref) |ref_name| {
                // CB2: Only apply NLL to borrows created at the current scope depth or
                // deeper. Borrows from outer scopes carry block-relative last-use indices
                // from the outer block's buildLastUseMap — using inner-block indices to
                // drive their expiry produces wrong results. The outer block's own
                // dropExpiredBorrows call (with its own last_use map) handles them.
                if (borrow.scope_depth < self.scope_depth) continue;
                // Named borrow: expire after last use of the reference variable
                const drop = if (last_use.get(ref_name)) |last_idx|
                    last_idx <= current_idx
                else
                    true; // ref never used after creation — drop immediately
                if (drop) {
                    _ = self.active_borrows.swapRemove(i);
                }
            } else {
                // Expression-level borrow: expire after the creating statement.
                // Borrow conflict detection already ran during the statement —
                // no need to keep it active across subsequent statements.
                _ = self.active_borrows.swapRemove(i);
            }
        }
    }
};

/// NLL: build a map of variable name → last statement index where it appears.
/// Pre-scans all statements in a block to determine when each variable is last used.
fn buildLastUseMap(statements: []*parser.Node, allocator: std.mem.Allocator) !std.StringHashMapUnmanaged(usize) {
    var map = std.StringHashMapUnmanaged(usize){};
    for (statements, 0..) |stmt, idx| {
        try collectIdentifiers(stmt, &map, allocator, idx);
    }
    return map;
}

/// Recursively walk an AST node and record every identifier reference.
/// Each identifier updates the map to the current statement index, so after a full
/// scan the map holds the LAST statement index where each variable name appears.
fn collectIdentifiers(node: *parser.Node, map: *std.StringHashMapUnmanaged(usize), allocator: std.mem.Allocator, stmt_idx: usize) anyerror!void {
    switch (node.*) {
        .identifier => |name| {
            try map.put(allocator, name, stmt_idx);
        },
        .var_decl => |v| {
            try collectIdentifiers(v.value, map, allocator, stmt_idx);
        },
        .destruct_decl => |d| {
            try collectIdentifiers(d.value, map, allocator, stmt_idx);
        },
        .assignment => |a| {
            try collectIdentifiers(a.left, map, allocator, stmt_idx);
            try collectIdentifiers(a.right, map, allocator, stmt_idx);
        },
        .return_stmt => |r| {
            if (r.value) |val| try collectIdentifiers(val, map, allocator, stmt_idx);
        },
        .if_stmt => |i| {
            try collectIdentifiers(i.condition, map, allocator, stmt_idx);
            try collectIdentifiers(i.then_block, map, allocator, stmt_idx);
            if (i.else_block) |e| try collectIdentifiers(e, map, allocator, stmt_idx);
        },
        .while_stmt => |w| {
            try collectIdentifiers(w.condition, map, allocator, stmt_idx);
            if (w.continue_expr) |c| try collectIdentifiers(c, map, allocator, stmt_idx);
            try collectIdentifiers(w.body, map, allocator, stmt_idx);
        },
        .for_stmt => |f| {
            for (f.iterables) |iter| try collectIdentifiers(iter, map, allocator, stmt_idx);
            try collectIdentifiers(f.body, map, allocator, stmt_idx);
        },
        .match_stmt => |m| {
            try collectIdentifiers(m.value, map, allocator, stmt_idx);
            for (m.arms) |arm| {
                if (arm.* == .match_arm) {
                    if (arm.match_arm.guard) |g| try collectIdentifiers(g, map, allocator, stmt_idx);
                    try collectIdentifiers(arm.match_arm.body, map, allocator, stmt_idx);
                }
            }
        },
        .defer_stmt => |d| {
            try collectIdentifiers(d.body, map, allocator, stmt_idx);
        },
        .block => |b| {
            for (b.statements) |s| try collectIdentifiers(s, map, allocator, stmt_idx);
        },
        .binary_expr => |b| {
            try collectIdentifiers(b.left, map, allocator, stmt_idx);
            try collectIdentifiers(b.right, map, allocator, stmt_idx);
        },
        .unary_expr => |u| {
            try collectIdentifiers(u.operand, map, allocator, stmt_idx);
        },
        .call_expr => |c| {
            try collectIdentifiers(c.callee, map, allocator, stmt_idx);
            for (c.args) |arg| try collectIdentifiers(arg, map, allocator, stmt_idx);
        },
        .field_expr => |f| {
            try collectIdentifiers(f.object, map, allocator, stmt_idx);
        },
        .index_expr => |i| {
            try collectIdentifiers(i.object, map, allocator, stmt_idx);
            try collectIdentifiers(i.index, map, allocator, stmt_idx);
        },
        .slice_expr => |s| {
            try collectIdentifiers(s.object, map, allocator, stmt_idx);
            try collectIdentifiers(s.low, map, allocator, stmt_idx);
            try collectIdentifiers(s.high, map, allocator, stmt_idx);
        },
        .compiler_func => |cf| {
            for (cf.args) |arg| try collectIdentifiers(arg, map, allocator, stmt_idx);
        },
        .mut_borrow_expr => |inner| {
            try collectIdentifiers(inner, map, allocator, stmt_idx);
        },
        .const_borrow_expr => |inner| {
            try collectIdentifiers(inner, map, allocator, stmt_idx);
        },
        .interpolated_string => |interp| {
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |e| try collectIdentifiers(e, map, allocator, stmt_idx),
                    .literal => {},
                }
            }
        },
        else => {},
    }
}

/// Two borrow paths overlap if either is a whole-variable borrow (null)
/// or both refer to the same field.
fn pathsOverlap(field_a: ?[]const u8, field_b: ?[]const u8) bool {
    const a = field_a orelse return true; // whole variable overlaps everything
    const b = field_b orelse return true;
    return std.mem.eql(u8, a, b);
}

/// Format a borrow target for error messages.
fn borrowLabel(variable: []const u8) []const u8 {
    return variable;
}

/// Extract the base variable and optional field from a borrow target expression.
/// Handles: identifier("x") → (x, null), field_expr(ident("p"), "name") → (p, name)
/// For deeper chains like a.b.c, tracks the first field level from the base.
pub fn extractBorrowTarget(node: *parser.Node) ?struct { variable: []const u8, field: ?[]const u8 } {
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
pub fn isMutableBorrowType(type_ann: ?*parser.Node) bool {
    const ann = type_ann orelse return false;
    if (ann.* == .type_ptr) {
        return ann.type_ptr.kind == .mut_ref;
    }
    return false;
}

test "borrow checker - no conflict immutable borrows" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Two immutable borrows of same variable — OK
    try checker.addBorrow("x", null, false, null);
    try checker.addBorrow("x", null, false, null);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - mutable conflicts immutable" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Immutable borrow then mutable — conflict
    try checker.addBorrow("x", null, false, null);
    try checker.addBorrow("x", null, true, null);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - cannot return reference" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    var inner = parser.Node{ .identifier = "x" };
    var borrow = parser.Node{ .mut_borrow_expr = &inner };
    var ret = parser.Node{ .return_stmt = .{ .value = &borrow } };

    try checker.checkStatement(&ret);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - mutable borrow via var &T type" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // First: immutable borrow
    try checker.addBorrow("data", null, false, null);

    // Then: var decl with var &T type = &data → mutable borrow → conflict
    var inner_type = parser.Node{ .type_named = "MyStruct" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = .mut_ref, .elem = &inner_type } };
    var borrow_target = parser.Node{ .identifier = "data" };
    var borrow_val = parser.Node{ .mut_borrow_expr = &borrow_target };
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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Two const& borrows — should be fine (multiple immutable borrows allowed)
    var borrow_target = parser.Node{ .identifier = "data" };
    var borrow_val = parser.Node{ .const_borrow_expr = &borrow_target };
    var decl1 = parser.Node{ .var_decl = .{
        .name = "ref1",
        .type_annotation = null,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl1);

    var borrow_target2 = parser.Node{ .identifier = "data" };
    var borrow_val2 = parser.Node{ .const_borrow_expr = &borrow_target2 };
    var decl2 = parser.Node{ .var_decl = .{
        .name = "ref2",
        .type_annotation = null,
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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of x
    try checker.addBorrow("x", null, true, null);

    // Try to use x directly — should error
    var id = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - scope drops borrows" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Borrow at depth 1
    checker.scope_depth = 1;
    try checker.addBorrow("x", null, true, null);
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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of p.name and p.health — different fields, no conflict
    try checker.addBorrow("p", "name", true, null);
    try checker.addBorrow("p", "health", true, null);
    try std.testing.expect(!reporter.hasErrors());
}

test "borrow checker - same field mutable borrow conflicts" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Two mutable borrows of same field — conflict
    try checker.addBorrow("p", "name", true, null);
    try checker.addBorrow("p", "name", true, null);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - whole variable borrow conflicts with field borrow" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Whole variable borrow then field borrow — conflict
    try checker.addBorrow("p", null, true, null);
    try checker.addBorrow("p", "name", false, null);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - field access while sibling mutably borrowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true, null);

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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true, null);

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

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of p.name
    try checker.addBorrow("p", "name", true, null);

    // Access bare p — whole variable includes borrowed field, should error
    var p_ident = parser.Node{ .identifier = "p" };
    try checker.checkExpr(&p_ident);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - field borrow from mut_borrow_expr field_expr" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Simulate: var ref: var &str = &p.name
    var inner_type = parser.Node{ .type_named = "str" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = .mut_ref, .elem = &inner_type } };
    var p_ident = parser.Node{ .identifier = "p" };
    var field_access = parser.Node{ .field_expr = .{ .object = &p_ident, .field = "name" } };
    var borrow_val = parser.Node{ .mut_borrow_expr = &field_access };
    var decl = parser.Node{ .var_decl = .{
        .name = "ref",
        .type_annotation = &type_ann,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl);
    try std.testing.expect(!reporter.hasErrors());

    // Now borrow p.health — should be fine (sibling)
    try checker.addBorrow("p", "health", true, null);
    try std.testing.expect(!reporter.hasErrors());

    // But borrow p.name again as mutable — should conflict
    try checker.addBorrow("p", "name", false, null);
    try std.testing.expect(reporter.hasErrors());
}

test "borrow checker - isMutableBorrowType" {
    // null → false
    try std.testing.expect(!isMutableBorrowType(null));

    // const& T → false
    var elem1 = parser.Node{ .type_named = "Point" };
    var const_ptr = parser.Node{ .type_ptr = .{ .kind = .const_ref, .elem = &elem1 } };
    try std.testing.expect(!isMutableBorrowType(&const_ptr));

    // mut& T → true
    var elem2 = parser.Node{ .type_named = "Point" };
    var mut_ptr = parser.Node{ .type_ptr = .{ .kind = .mut_ref, .elem = &elem2 } };
    try std.testing.expect(isMutableBorrowType(&mut_ptr));

    // non-ptr type → false
    var named = parser.Node{ .type_named = "i32" };
    try std.testing.expect(!isMutableBorrowType(&named));
}

test "borrow checker - lookupStructMethod" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Register struct with its scale method on the StructSig itself.
    var point_methods: declarations.StructMethodMap = .{};
    try point_methods.put(alloc, "scale", .{
        .name = "scale",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = false,
    });
    try decl_table.symbols.put("Point", .{ .@"struct" = .{
        .name = "Point",
        .fields = &.{},
        .is_pub = true,
        .methods = point_methods,
    } });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Found (fallback scan path — no receiver node)
    const sig = checker.lookupStructMethod(null, "scale");
    try std.testing.expect(sig != null);
    try std.testing.expectEqualStrings("scale", sig.?.name);

    // Not found
    try std.testing.expect(checker.lookupStructMethod(null, "nonexistent") == null);
}

// CB1 regression — two structs with same-named method, different `self` mutability.
// The pre-fix behavior scanned all struct_method tables and returned whichever came
// first; after the fix, receiver type from `ctx.type_map` selects the correct signature.
test "borrow checker - lookupStructMethod resolves by receiver type (CB1)" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    // Two distinct param_nodes — param_nodes[0] drives isMutableBorrowType checks
    // in the borrow checker. We don't need realistic param shapes for this test, just
    // two signatures that differ in a discriminable way (return type).
    var writer_methods: declarations.StructMethodMap = .{};
    try writer_methods.put(alloc, "op", .{
        .name = "op_writer",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal,
        .is_pub = true,
        .is_instance = true,
    });
    try decl_table.symbols.put("Writer", .{ .@"struct" = .{
        .name = "Writer",
        .fields = &.{},
        .is_pub = true,
        .methods = writer_methods,
    } });

    var reader_methods: declarations.StructMethodMap = .{};
    try reader_methods.put(alloc, "op", .{
        .name = "op_reader",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .i32 },
        .context = .normal,
        .is_pub = true,
        .is_instance = true,
    });
    try decl_table.symbols.put("Reader", .{ .@"struct" = .{
        .name = "Reader",
        .fields = &.{},
        .is_pub = true,
        .methods = reader_methods,
    } });

    // Build a type_map with a receiver identifier node resolved to `.named = "Reader"`.
    var type_map = std.AutoHashMapUnmanaged(*parser.Node, types.ResolvedType){};
    defer type_map.deinit(alloc);

    var reader_obj = parser.Node{ .identifier = "r" };
    try type_map.put(alloc, &reader_obj, .{ .named = "Reader" });

    var ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    ctx.type_map = &type_map;

    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // With receiver type "Reader", must select Reader.op — not Writer.op (which
    // the naive scan might return first depending on hashmap order).
    const sig = checker.lookupStructMethod(&reader_obj, "op");
    try std.testing.expect(sig != null);
    try std.testing.expectEqualStrings("op_reader", sig.?.name);
    try std.testing.expect(sig.?.return_type == .primitive);
    try std.testing.expect(sig.?.return_type.primitive == .i32);

    // Also verify ptr-wrapped receiver types (const& Reader) unwrap correctly.
    var reader_elem: types.ResolvedType = .{ .named = "Reader" };
    var reader_ref_obj = parser.Node{ .identifier = "rr" };
    try type_map.put(alloc, &reader_ref_obj, .{ .ptr = .{ .kind = .const_ref, .elem = &reader_elem } });
    const sig2 = checker.lookupStructMethod(&reader_ref_obj, "op");
    try std.testing.expect(sig2 != null);
    try std.testing.expectEqualStrings("op_reader", sig2.?.name);
}

test "borrow checker - removeLastBorrow" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    try checker.addBorrow("x", null, true, null);
    try checker.addBorrow("y", null, false, null);
    try std.testing.expectEqual(@as(usize, 2), checker.active_borrows.items.len);

    checker.removeLastBorrow("x");
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Removing non-existent does nothing
    checker.removeLastBorrow("z");
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);
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

test "NLL - borrow dropped after last use of ref" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Simulate: borrow of "x" held by ref "r", last use of "r" is at stmt 0
    try checker.addBorrow("x", null, true, "r");
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Build a last-use map where "r" is last used at stmt 0
    var last_use = std.StringHashMapUnmanaged(usize){};
    defer last_use.deinit(alloc);
    try last_use.put(alloc, "r", 0);

    // After stmt 0: borrow should be expired
    checker.dropExpiredBorrows(&last_use, 0);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);
}

test "NLL - borrow kept alive while ref still used" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Borrow of "x" held by ref "r", last use of "r" is at stmt 2
    try checker.addBorrow("x", null, true, "r");

    var last_use = std.StringHashMapUnmanaged(usize){};
    defer last_use.deinit(alloc);
    try last_use.put(alloc, "r", 2);

    // After stmt 0: borrow still alive (last use is 2)
    checker.dropExpiredBorrows(&last_use, 0);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // After stmt 1: still alive
    checker.dropExpiredBorrows(&last_use, 1);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // After stmt 2: expired
    checker.dropExpiredBorrows(&last_use, 2);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);
}

test "NLL - unused borrow ref dropped immediately" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Borrow of "x" held by ref "r", but "r" never used (not in map)
    try checker.addBorrow("x", null, true, "r");

    var last_use = std.StringHashMapUnmanaged(usize){};
    defer last_use.deinit(alloc);
    // "r" not in map → borrow should drop immediately

    checker.dropExpiredBorrows(&last_use, 0);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);
}

test "NLL - expression-level borrow (null ref) expires after statement" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Expression-level borrow (null borrow_ref) — expires after statement
    try checker.addBorrow("x", null, false, null);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    var last_use = std.StringHashMapUnmanaged(usize){};
    defer last_use.deinit(alloc);

    // dropExpiredBorrows should clean up expression-level borrows
    checker.dropExpiredBorrows(&last_use, 0);
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);
}

test "NLL - collectIdentifiers finds all variable references" {
    const alloc = std.testing.allocator;

    // Build a small AST: two statements referencing "x" and "y"
    // Stmt 0: identifier "x"
    // Stmt 1: binary_expr("y", "x")
    var id_x = parser.Node{ .identifier = "x" };
    var id_y = parser.Node{ .identifier = "y" };
    var id_x2 = parser.Node{ .identifier = "x" };
    var bin = parser.Node{ .binary_expr = .{
        .left = &id_y,
        .right = &id_x2,
        .op = .add,
    } };

    var stmts = [_]*parser.Node{ &id_x, &bin };
    var last_use = try buildLastUseMap(&stmts, alloc);
    defer last_use.deinit(alloc);

    // "x" last used at stmt 1 (appears in both 0 and 1)
    try std.testing.expectEqual(@as(usize, 1), last_use.get("x").?);
    // "y" last used at stmt 1
    try std.testing.expectEqual(@as(usize, 1), last_use.get("y").?);
}

test "NLL - buildLastUseMap with nested expressions" {
    const alloc = std.testing.allocator;

    // Stmt 0: call_expr(callee="foo", args=["bar"])
    // Stmt 1: field_expr(object="obj", field="x")
    var foo = parser.Node{ .identifier = "foo" };
    var bar = parser.Node{ .identifier = "bar" };
    var args = [_]*parser.Node{&bar};
    var arg_names = [_][]const u8{};
    var call = parser.Node{ .call_expr = .{
        .callee = &foo,
        .args = &args,
        .arg_names = &arg_names,
    } };
    var obj = parser.Node{ .identifier = "obj" };
    var field = parser.Node{ .field_expr = .{ .object = &obj, .field = "x" } };

    var stmts = [_]*parser.Node{ &call, &field };
    var last_use = try buildLastUseMap(&stmts, alloc);
    defer last_use.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), last_use.get("foo").?);
    try std.testing.expectEqual(@as(usize, 0), last_use.get("bar").?);
    try std.testing.expectEqual(@as(usize, 1), last_use.get("obj").?);
}

test "borrow checker - interpolated string checks embedded exprs" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Mutable borrow of x
    try checker.addBorrow("x", null, true, null);

    // Use x inside interpolated string — should detect borrow violation
    var id_node = parser.Node{ .identifier = "x" };
    var parts = [_]parser.InterpolatedPart{
        .{ .literal = "value: " },
        .{ .expr = &id_node },
    };
    var interp = parser.Node{ .interpolated_string = .{ .parts = &parts } };
    try checker.checkExpr(&interp);
    try std.testing.expect(reporter.hasErrors());
}

test "NLL - CB2: outer-scope borrow not dropped by inner block's dropExpiredBorrows" {
    // Regression test for CB2: inner blocks must not drop borrows created in outer scopes.
    // Scenario: borrow created at depth=0, dropExpiredBorrows called from depth=1
    // (simulating inner block). The borrow must survive because the outer block's
    // dropExpiredBorrows — not the inner block's — is responsible for it.
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = BorrowChecker.init(alloc, &ctx);
    defer checker.deinit();

    // Outer scope (depth=0) creates a named borrow
    try checker.addBorrow("x", null, true, "r");
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Simulate entering an inner block (depth=1) whose last_use map says r → 0
    checker.scope_depth = 1;
    var inner_last_use = std.StringHashMapUnmanaged(usize){};
    defer inner_last_use.deinit(alloc);
    try inner_last_use.put(alloc, "r", 0);

    // Inner block calls dropExpiredBorrows — must NOT drop the outer borrow
    checker.dropExpiredBorrows(&inner_last_use, 0);
    try std.testing.expectEqual(@as(usize, 1), checker.active_borrows.items.len);

    // Simulate returning to outer scope (depth=0) — now NLL can drop it
    checker.scope_depth = 0;
    var outer_last_use = std.StringHashMapUnmanaged(usize){};
    defer outer_last_use.deinit(alloc);
    try outer_last_use.put(alloc, "r", 1); // outer last use of r is stmt 1

    checker.dropExpiredBorrows(&outer_last_use, 1); // after stmt 1: drop
    try std.testing.expectEqual(@as(usize, 0), checker.active_borrows.items.len);
}
