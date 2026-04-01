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
                // NLL: pre-scan to find last-use index for each variable
                var last_use = buildLastUseMap(b.statements, self.allocator);
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
                // Borrow mutability comes from the type annotation (mut& T vs const& T),
                // not from const/var — const binding to mut& T is still a mutable borrow
                // NLL: borrow_ref is the declared variable name
                if (v.value.* == .mut_borrow_expr) {
                    const is_mut = isMutableBorrowType(v.type_annotation);
                    if (extractBorrowTarget(v.value.mut_borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, is_mut, v.name);
                    }
                } else if (v.value.* == .const_borrow_expr) {
                    if (extractBorrowTarget(v.value.const_borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, false, v.name);
                    }
                } else {
                    try self.checkExpr(v.value);
                }
            },
            .return_stmt => |r| {
                if (r.value) |val| {
                    // Cannot return a reference — only owned values
                    if (val.* == .mut_borrow_expr) {
                        try self.ctx.reporter.report(.{
                            .message = "cannot return a reference — functions can only return owned values",
                            .loc = self.ctx.nodeLoc(node),
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
            .destruct_decl => |d| {
                try self.checkExpr(d.value);
            },
            .break_stmt, .continue_stmt => {},
            .assignment => |a| {
                // If assigning a borrow, check for conflicts
                // NLL: borrow_ref is the LHS identifier (if it is one)
                const assign_ref: ?[]const u8 = if (a.left.* == .identifier) a.left.identifier else null;
                if (a.right.* == .mut_borrow_expr) {
                    const is_mut = isMutableBorrowType(null); // no type context in assignment
                    if (extractBorrowTarget(a.right.mut_borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, is_mut, assign_ref);
                    }
                } else if (a.right.* == .const_borrow_expr) {
                    if (extractBorrowTarget(a.right.const_borrow_expr)) |target| {
                        try self.addBorrow(target.variable, target.field, false, assign_ref);
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
            .mut_borrow_expr => |inner| {
                // mut& in expression context (e.g. function call arg) — default immutable
                // NLL: null ref — temporary borrow, not tracked for NLL
                if (extractBorrowTarget(inner)) |target| {
                    try self.addBorrow(target.variable, target.field, false, null);
                }
                try self.checkExpr(inner);
            },
            .const_borrow_expr => |inner| {
                // Explicit const& in expression context — always immutable
                // NLL: null ref — temporary borrow, not tracked for NLL
                if (extractBorrowTarget(inner)) |target| {
                    try self.addBorrow(target.variable, target.field, false, null);
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
                        // Look up method to check self parameter mutability.
                        // Try top-level funcs first, then struct_methods ("Type.method" key).
                        {
                            if (self.ctx.decls.funcs.get(method_name) orelse
                                self.lookupStructMethod(obj_name, method_name)) |sig| {
                                if (sig.params.len > 0 and std.mem.eql(u8, sig.params[0].name, "self")) {
                                    const self_node = sig.param_nodes[0];
                                    if (self_node.* == .param) {
                                        const is_mut = isMutableBorrowType(self_node.param.type_annotation);
                                        // Temporary borrow: check conflicts, add, then remove after call
                                        try self.addBorrow(obj_name, null, is_mut, null);
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

            const loc = if (self.current_node) |cn| self.ctx.nodeLoc(cn) else null;
            if (field) |f| {
                try self.ctx.reporter.reportFmt(loc, "cannot use '{s}.{s}' while it is mutably borrowed — consider borrowing with const&", .{ name, f });
            } else {
                try self.ctx.reporter.reportFmt(loc, "cannot use '{s}' while it is mutably borrowed — consider borrowing with const&", .{name});
            }
            return;
        }
    }

    /// Add a borrow — check for conflicts (field-level aware)
    /// `borrow_ref` is the variable holding the reference (null for temporaries).
    fn addBorrow(self: *BorrowChecker, variable: []const u8, field: ?[]const u8, is_mutable: bool, borrow_ref: ?[]const u8) !void {
        // Check existing borrows for conflicts
        for (self.active_borrows.items) |existing| {
            if (!std.mem.eql(u8, existing.variable, variable)) continue;
            if (!pathsOverlap(existing.field, field)) continue;

            if (is_mutable or existing.is_mutable) {
                const loc = if (self.current_node) |cn| self.ctx.nodeLoc(cn) else null;
                const label = borrowLabel(variable, field);
                const hint: []const u8 = if (!is_mutable)
                    " — consider borrowing with const&"
                else
                    "";
                try self.ctx.reporter.reportFmt(loc, "cannot borrow '{s}' as {s}: already borrowed as {s}{s}",
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

    /// Look up a struct method by searching struct_methods with all known struct type names.
    /// Returns the FuncSig if found, null otherwise.
    fn lookupStructMethod(self: *BorrowChecker, obj_name: []const u8, method_name: []const u8) ?declarations.FuncSig {
        // Try all struct types — check if "TypeName.method" exists in struct_methods.
        // The object variable's type name is not available here (borrow checker runs
        // without type info), so iterate known structs that have this method.
        var it = self.ctx.decls.structs.iterator();
        while (it.next()) |entry| {
            const struct_name = entry.key_ptr.*;
            // Check struct_methods for "StructName.method"
            const sm_it = self.ctx.decls.struct_methods;
            // Build the key "StructName.method" and look it up
            var buf: [256]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}.{s}", .{ struct_name, method_name }) catch continue;
            if (sm_it.get(key)) |sig| {
                // Verify the struct has a field/relationship with the object name,
                // or just trust that if the method exists, it's a valid candidate.
                _ = obj_name;
                return sig;
            }
        }
        return null;
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

    /// NLL: drop expired borrows after each statement.
    /// - Named borrows (borrow_ref != null): expire after last use of the ref variable
    /// - Expression-level borrows (borrow_ref == null): expire after the statement
    ///   that created them — these are borrows from function call args that should
    ///   not persist across statements
    fn dropExpiredBorrows(self: *BorrowChecker, last_use: *const std.StringHashMapUnmanaged(usize), current_idx: usize) void {
        var i: usize = self.active_borrows.items.len;
        while (i > 0) {
            i -= 1;
            const borrow = self.active_borrows.items[i];
            if (borrow.borrow_ref) |ref_name| {
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
fn buildLastUseMap(statements: []*parser.Node, allocator: std.mem.Allocator) std.StringHashMapUnmanaged(usize) {
    var map = std.StringHashMapUnmanaged(usize){};
    for (statements, 0..) |stmt, idx| {
        collectIdentifiers(stmt, &map, allocator, idx);
    }
    return map;
}

/// Recursively walk an AST node and record every identifier reference.
/// Each identifier updates the map to the current statement index, so after a full
/// scan the map holds the LAST statement index where each variable name appears.
fn collectIdentifiers(node: *parser.Node, map: *std.StringHashMapUnmanaged(usize), allocator: std.mem.Allocator, stmt_idx: usize) void {
    switch (node.*) {
        .identifier => |name| {
            map.put(allocator, name, stmt_idx) catch {};
        },
        .var_decl => |v| {
            // Scan value expression, not the declared name (that's a definition)
            collectIdentifiers(v.value, map, allocator, stmt_idx);
        },
        .destruct_decl => |d| {
            collectIdentifiers(d.value, map, allocator, stmt_idx);
        },
        .assignment => |a| {
            collectIdentifiers(a.left, map, allocator, stmt_idx);
            collectIdentifiers(a.right, map, allocator, stmt_idx);
        },
        .return_stmt => |r| {
            if (r.value) |val| collectIdentifiers(val, map, allocator, stmt_idx);
        },
        .throw_stmt => |t| {
            // throw references its variable by name
            map.put(allocator, t.variable, stmt_idx) catch {};
        },
        .if_stmt => |i| {
            collectIdentifiers(i.condition, map, allocator, stmt_idx);
            collectIdentifiers(i.then_block, map, allocator, stmt_idx);
            if (i.else_block) |e| collectIdentifiers(e, map, allocator, stmt_idx);
        },
        .while_stmt => |w| {
            collectIdentifiers(w.condition, map, allocator, stmt_idx);
            if (w.continue_expr) |c| collectIdentifiers(c, map, allocator, stmt_idx);
            collectIdentifiers(w.body, map, allocator, stmt_idx);
        },
        .for_stmt => |f| {
            collectIdentifiers(f.iterable, map, allocator, stmt_idx);
            collectIdentifiers(f.body, map, allocator, stmt_idx);
        },
        .match_stmt => |m| {
            collectIdentifiers(m.value, map, allocator, stmt_idx);
            for (m.arms) |arm| {
                if (arm.* == .match_arm) {
                    collectIdentifiers(arm.match_arm.body, map, allocator, stmt_idx);
                }
            }
        },
        .defer_stmt => |d| {
            collectIdentifiers(d.body, map, allocator, stmt_idx);
        },
        .block => |b| {
            for (b.statements) |s| collectIdentifiers(s, map, allocator, stmt_idx);
        },
        .binary_expr => |b| {
            collectIdentifiers(b.left, map, allocator, stmt_idx);
            collectIdentifiers(b.right, map, allocator, stmt_idx);
        },
        .unary_expr => |u| {
            collectIdentifiers(u.operand, map, allocator, stmt_idx);
        },
        .call_expr => |c| {
            collectIdentifiers(c.callee, map, allocator, stmt_idx);
            for (c.args) |arg| collectIdentifiers(arg, map, allocator, stmt_idx);
        },
        .field_expr => |f| {
            collectIdentifiers(f.object, map, allocator, stmt_idx);
        },
        .index_expr => |i| {
            collectIdentifiers(i.object, map, allocator, stmt_idx);
            collectIdentifiers(i.index, map, allocator, stmt_idx);
        },
        .slice_expr => |s| {
            collectIdentifiers(s.object, map, allocator, stmt_idx);
            collectIdentifiers(s.low, map, allocator, stmt_idx);
            collectIdentifiers(s.high, map, allocator, stmt_idx);
        },
        .compiler_func => |cf| {
            for (cf.args) |arg| collectIdentifiers(arg, map, allocator, stmt_idx);
        },
        .mut_borrow_expr => |inner| {
            collectIdentifiers(inner, map, allocator, stmt_idx);
        },
        .const_borrow_expr => |inner| {
            collectIdentifiers(inner, map, allocator, stmt_idx);
        },
        .interpolated_string => |interp| {
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |e| collectIdentifiers(e, map, allocator, stmt_idx),
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

    // Two const &T borrows — should be fine
    var inner_type = parser.Node{ .type_named = "MyStruct" };
    var type_ann = parser.Node{ .type_ptr = .{ .kind = .const_ref, .elem = &inner_type } };
    var borrow_target = parser.Node{ .identifier = "data" };
    var borrow_val = parser.Node{ .mut_borrow_expr = &borrow_target };
    var decl1 = parser.Node{ .var_decl = .{
        .name = "ref1",
        .type_annotation = &type_ann,
        .value = &borrow_val,
        .is_pub = false,
    } };

    try checker.checkStatement(&decl1);

    var borrow_target2 = parser.Node{ .identifier = "data" };
    var borrow_val2 = parser.Node{ .mut_borrow_expr = &borrow_target2 };
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

    // Simulate: var ref: var &String = &p.name
    var inner_type = parser.Node{ .type_named = "String" };
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
        .op = "+",
    } };

    var stmts = [_]*parser.Node{ &id_x, &bin };
    var last_use = buildLastUseMap(&stmts, alloc);
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
    var last_use = buildLastUseMap(&stmts, alloc);
    defer last_use.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), last_use.get("foo").?);
    try std.testing.expectEqual(@as(usize, 0), last_use.get("bar").?);
    try std.testing.expectEqual(@as(usize, 1), last_use.get("obj").?);
}
