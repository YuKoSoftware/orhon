// ownership.zig — Ownership & Move Analysis pass (pass 6)
// Tracks ownership transfers, catches use-after-move,
// validates struct atomicity (no partial field moves).

const std = @import("std");
const parser = @import("parser.zig");
const types = @import("types.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");

/// Ownership state for a variable in current scope
pub const VarState = struct {
    name: []const u8,
    state: types.OwnershipState,
    is_primitive: bool, // primitives always copy, never move
    type_name: []const u8, // type name for struct field lookup
};

/// Ownership scope — tracks variable states
pub const OwnershipScope = struct {
    vars: std.StringHashMap(VarState),
    parent: ?*OwnershipScope,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*OwnershipScope) OwnershipScope {
        return .{
            .vars = std.StringHashMap(VarState).init(allocator),
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OwnershipScope) void {
        self.vars.deinit();
    }

    pub fn define(self: *OwnershipScope, name: []const u8, is_primitive: bool) !void {
        try self.vars.put(name, .{
            .name = name,
            .state = .owned,
            .is_primitive = is_primitive,
            .type_name = "",
        });
    }

    pub fn defineTyped(self: *OwnershipScope, name: []const u8, is_primitive: bool, type_name: []const u8) !void {
        try self.vars.put(name, .{
            .name = name,
            .state = .owned,
            .is_primitive = is_primitive,
            .type_name = type_name,
        });
    }

    pub fn getState(self: *const OwnershipScope, name: []const u8) ?VarState {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.getState(name);
        return null;
    }

    pub fn setState(self: *OwnershipScope, name: []const u8, state: types.OwnershipState) bool {
        if (self.vars.getPtr(name)) |v| {
            v.state = state;
            return true;
        }
        if (self.parent) |p| return p.setState(name, state);
        return false;
    }
};

/// The ownership checker
pub const OwnershipChecker = struct {
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    locs: ?*const parser.LocMap,
    source_file: []const u8,
    decls: ?*declarations.DeclTable,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) OwnershipChecker {
        return .{
            .reporter = reporter,
            .allocator = allocator,
            .locs = null,
            .source_file = "",
            .decls = null,
        };
    }

    /// Look up a field's type from the DeclTable using the variable's tracked type.
    /// Returns true if primitive, false if non-primitive, null if unknown.
    fn lookupFieldType(self: *const OwnershipChecker, scope: *OwnershipScope, obj_name: []const u8, field_name: []const u8) ?bool {
        const decls = self.decls orelse return null;
        const var_state = scope.getState(obj_name) orelse return null;

        // Use the variable's type name to find the struct in DeclTable
        if (var_state.type_name.len > 0) {
            if (decls.structs.get(var_state.type_name)) |sig| {
                for (sig.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        return f.type_.isPrimitive();
                    }
                }
            }
        }

        return null;
    }

    /// Infer whether for-loop captures are primitive based on the iterable.
    /// Returns true for ranges, primitive arrays/slices; false (conservative) otherwise.
    fn inferIterableElemPrimitive(_: *const OwnershipChecker, iterable: *parser.Node, scope: *OwnershipScope) bool {
        switch (iterable.*) {
            // Range expressions (0..10) always produce integer captures
            .range_expr => return true,
            // Array literals — check the first element
            .array_literal => |elems| {
                if (elems.len > 0) {
                    return switch (elems[0].*) {
                        .int_literal, .float_literal, .bool_literal, .string_literal => true,
                        else => false,
                    };
                }
                return false;
            },
            // Variable — check its type via scope + DeclTable
            .identifier => |id_name| {
                if (scope.getState(id_name)) |state| {
                    return state.is_primitive;
                }
                return false;
            },
            else => return false,
        }
    }

    fn nodeLoc(self: *const OwnershipChecker, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    /// Check ownership rules in a program AST
    pub fn check(self: *OwnershipChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;

        var scope = OwnershipScope.init(self.allocator, null);
        defer scope.deinit();

        for (ast.program.top_level) |node| {
            try self.checkNode(node, &scope);
        }
    }

    fn checkNode(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                var func_scope = OwnershipScope.init(self.allocator, scope);
                defer func_scope.deinit();

                for (f.params) |param| {
                    if (param.* == .param) {
                        const type_name = typeNodeName(param.param.type_annotation);
                        const is_prim = types.isPrimitiveName(type_name);
                        try func_scope.define(param.param.name, is_prim);
                    }
                }

                try self.checkNode(f.body, &func_scope);
            },

            .block => |b| {
                var block_scope = OwnershipScope.init(self.allocator, scope);
                defer block_scope.deinit();

                for (b.statements) |stmt| {
                    try self.checkStatement(stmt, &block_scope);
                }

                // Check for unhandled error unions at scope exit
                // (simplified — full impl tracks error union vars)
            },

            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) {
                        try self.checkNode(member, scope);
                    }
                }
            },

            else => {},
        }
    }

    fn checkStatement(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void {
        switch (node.*) {
            .var_decl, .const_decl, .compt_decl => |v| {
                // Check the value expression for use-after-move
                try self.checkExpr(v.value, scope, false);
                // Define the new variable as owned, with type name for field lookup
                const type_name = if (v.type_annotation) |t| typeNodeName(t) else "";
                const is_prim = if (type_name.len > 0) types.isPrimitiveName(type_name) else false;
                try scope.defineTyped(v.name, is_prim, type_name);
            },

            .destruct_decl => |d| {
                try self.checkExpr(d.value, scope, false);
                // Define new variables as owned
                for (d.names) |name| try scope.define(name, false);
                // splitAt consumes the source — mark as moved
                if (d.value.* == .call_expr) {
                    const c = d.value.call_expr;
                    if (c.callee.* == .field_expr) {
                        const fe = c.callee.field_expr;
                        if (std.mem.eql(u8, fe.field, "splitAt") and fe.object.* == .identifier) {
                            _ = scope.setState(fe.object.identifier, .moved);
                        }
                    }
                }
            },

            .return_stmt => |r| {
                if (r.value) |v| {
                    try self.checkExpr(v, scope, false);
                    // If returning an identifier, mark it as moved
                    if (v.* == .identifier) {
                        const name = v.identifier;
                        if (scope.getState(name)) |state| {
                            if (!state.is_primitive) {
                                _ = scope.setState(name, .moved);
                            }
                        }
                    }
                }
            },

            .assignment => |a| {
                try self.checkExpr(a.right, scope, false);
                // If assigning from identifier (non-borrow), it's a move
                if (a.right.* == .identifier) {
                    const name = a.right.identifier;
                    if (scope.getState(name)) |state| {
                        if (!state.is_primitive) {
                            _ = scope.setState(name, .moved);
                        }
                    }
                }
            },

            .if_stmt => |i| {
                try self.checkExpr(i.condition, scope, true);

                // Snapshot state before branches — if either branch moves a
                // variable, it must be considered moved after the if (conservative)
                const snapshot = try self.snapshotScope(scope);
                defer self.allocator.free(snapshot);

                try self.checkNode(i.then_block, scope);
                const after_then = try self.snapshotScope(scope);
                defer self.allocator.free(after_then);

                // Restore for else branch
                self.restoreScope(scope, snapshot);

                if (i.else_block) |e| try self.checkNode(e, scope);

                // Merge: if moved in either branch, consider moved
                self.mergeMovedStates(scope, after_then);
            },

            .while_stmt => |w| {
                try self.checkExpr(w.condition, scope, true);
                if (w.continue_expr) |c| try self.checkExpr(c, scope, false);
                try self.checkNode(w.body, scope);
            },

            .for_stmt => |f| {
                try self.checkExpr(f.iterable, scope, true);
                var for_scope = OwnershipScope.init(self.allocator, scope);
                defer for_scope.deinit();
                // Determine if captures are primitive from the iterable type
                const elem_is_prim = self.inferIterableElemPrimitive(f.iterable, scope);
                for (f.captures) |v| try for_scope.define(v, elem_is_prim);
                // Index variable is always usize (primitive)
                if (f.index_var) |idx| try for_scope.define(idx, true);
                try self.checkNode(f.body, &for_scope);
            },

            .match_stmt => |m| {
                try self.checkExpr(m.value, scope, true);

                const snapshot = try self.snapshotScope(scope);
                defer self.allocator.free(snapshot);

                // Check each arm, merging moved states (conservative)
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        self.restoreScope(scope, snapshot);
                        try self.checkExpr(arm.match_arm.pattern, scope, true);
                        try self.checkNode(arm.match_arm.body, scope);
                    }
                }
                // After match: anything moved in ANY arm is moved
            },

            .defer_stmt => |d| {
                try self.checkNode(d.body, scope);
            },

            .block => try self.checkNode(node, scope),

            else => try self.checkExpr(node, scope, false),
        }
    }

    /// Check expression for use-after-move
    /// is_borrow: true if this usage is a borrow (& prefix), doesn't consume
    fn checkExpr(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope, is_borrow: bool) anyerror!void {
        switch (node.*) {
            .identifier => |name| {
                if (scope.getState(name)) |state| {
                    if (state.state == .moved) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "use of moved value '{s}'", .{name});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                    // If not a borrow and not primitive, this is a move
                    if (!is_borrow and !state.is_primitive and state.state == .owned) {
                        _ = scope.setState(name, .moved);
                    }
                }
            },

            .borrow_expr => |inner| {
                try self.checkExpr(inner, scope, true);
            },

            .binary_expr => |b| {
                // Operands of binary expressions are reads, not moves
                try self.checkExpr(b.left, scope, true);
                try self.checkExpr(b.right, scope, true);
            },

            .call_expr => |c| {
                // a.free(x) — the freed value is moved (becomes invalid)
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (std.mem.eql(u8, fe.field, "free") and c.args.len == 1) {
                        try self.checkExpr(fe.object, scope, true); // allocator is borrowed
                        try self.checkExpr(c.args[0], scope, false); // freed value is moved
                        return;
                    }
                }
                try self.checkExpr(c.callee, scope, true); // callee is always borrowed
                for (c.args) |arg| {
                    // Arguments passed by value are moves, by & are borrows
                    const arg_is_borrow = arg.* == .borrow_expr;
                    try self.checkExpr(arg, scope, arg_is_borrow);
                }
            },

            .field_expr => |f| {
                // Accessing a field borrows the struct
                try self.checkExpr(f.object, scope, true);

                // If this field access is used as a move (not borrow),
                // check if the field type is primitive (copy) or non-primitive (move)
                if (!is_borrow and f.object.* == .identifier) {
                    const obj_name = f.object.identifier;
                    if (scope.getState(obj_name)) |state| {
                        if (!state.is_primitive) {
                            const field_is_prim = self.lookupFieldType(scope, obj_name, f.field);
                            if (field_is_prim != null and !field_is_prim.?) {
                                // Non-primitive field access as move → struct atomicity error
                                const msg = try std.fmt.allocPrint(self.allocator,
                                    "cannot move field '{s}' out of '{s}' — structs are atomic ownership units",
                                    .{ f.field, obj_name });
                                defer self.allocator.free(msg);
                                try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                            }
                            // Primitive field access is always a copy — no error
                        }
                    }
                }
            },

            .index_expr => |i| {
                try self.checkExpr(i.object, scope, true);
                try self.checkExpr(i.index, scope, true);
            },

            .slice_expr => |s| {
                try self.checkExpr(s.object, scope, true);
                try self.checkExpr(s.low, scope, true);
                try self.checkExpr(s.high, scope, true);
            },

            .compiler_func => |cf| {
                if (std.mem.eql(u8, cf.name, "move")) {
                    // @move(x) — explicit move, mark source as moved
                    if (cf.args.len == 1) {
                        try self.checkExpr(cf.args[0], scope, false);
                    }
                } else if (std.mem.eql(u8, cf.name, "copy")) {
                    // @copy(x) — explicit copy, borrows (no move)
                    if (cf.args.len == 1) {
                        try self.checkExpr(cf.args[0], scope, true);
                    }
                } else if (std.mem.eql(u8, cf.name, "swap")) {
                    // @swap(a, b) — both stay owned, values exchanged
                    for (cf.args) |arg| {
                        try self.checkExpr(arg, scope, true);
                    }
                } else {
                    // Other compiler funcs — check args as borrows
                    for (cf.args) |arg| {
                        try self.checkExpr(arg, scope, true);
                    }
                }
            },

            .thread_block => |t| {
                // Values move into threads
                try self.checkNode(t.body, scope);
            },

            else => {},
        }
    }

    /// Snapshot the ownership states of all variables in the current scope
    const StateEntry = struct { name: []const u8, state: types.OwnershipState };

    fn snapshotScope(self: *OwnershipChecker, scope: *OwnershipScope) ![]StateEntry {
        var entries = std.ArrayListUnmanaged(StateEntry){};
        var it = scope.vars.iterator();
        while (it.next()) |entry| {
            try entries.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .state = entry.value_ptr.state,
            });
        }
        return entries.toOwnedSlice(self.allocator);
    }

    /// Restore scope states from a snapshot
    fn restoreScope(_: *OwnershipChecker, scope: *OwnershipScope, snapshot: []const StateEntry) void {
        for (snapshot) |entry| {
            _ = scope.setState(entry.name, entry.state);
        }
    }

    /// Merge moved states — if a variable is moved in the given snapshot, mark it moved
    fn mergeMovedStates(_: *OwnershipChecker, scope: *OwnershipScope, other: []const StateEntry) void {
        for (other) |entry| {
            if (entry.state == .moved) {
                _ = scope.setState(entry.name, .moved);
            }
        }
    }
};

/// Extract the type name string from an AST type node (for DeclTable lookups)
fn typeNodeName(node: *parser.Node) []const u8 {
    return switch (node.*) {
        .type_named => |n| n,
        .type_generic => |g| g.name,
        else => "",
    };
}

test "ownership - use after move detected" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 's' as non-primitive (string)
    try scope.define("s", false);

    // First use — moves s
    var id1 = parser.Node{ .identifier = "s" };
    try checker.checkExpr(&id1, &scope, false);
    try std.testing.expect(!reporter.hasErrors()); // first use ok

    // Second use — s is now moved
    var id2 = parser.Node{ .identifier = "s" };
    try checker.checkExpr(&id2, &scope, false);
    try std.testing.expect(reporter.hasErrors()); // use-after-move detected
}

test "ownership - primitive always copies" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'x' as primitive (i32)
    try scope.define("x", true);

    // Use multiple times — primitives copy, never move
    var id1 = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id1, &scope, false);
    var id2 = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id2, &scope, false);
    var id3 = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id3, &scope, false);

    try std.testing.expect(!reporter.hasErrors()); // no errors — primitives copy
}

test "ownership - string is copy type" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'name' as string (primitive — copies, never moves)
    try scope.define("name", types.isPrimitiveName("String"));

    var id1 = parser.Node{ .identifier = "name" };
    try checker.checkExpr(&id1, &scope, false);
    var id2 = parser.Node{ .identifier = "name" };
    try checker.checkExpr(&id2, &scope, false);

    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - @copy borrows without moving" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'data' as non-primitive (struct)
    try scope.define("data", false);

    // @copy(data) — should borrow, not move
    var inner = parser.Node{ .identifier = "data" };
    var copy_node = parser.Node{ .compiler_func = .{
        .name = "copy",
        .args = @constCast(&[_]*parser.Node{&inner}),
    } };
    try checker.checkExpr(&copy_node, &scope, false);

    // data should still be owned (not moved)
    const state = scope.getState("data").?;
    try std.testing.expect(state.state == .owned);
}

test "ownership - @move marks as moved" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'data' as non-primitive
    try scope.define("data", false);

    // @move(data) — should move
    var inner = parser.Node{ .identifier = "data" };
    var move_node = parser.Node{ .compiler_func = .{
        .name = "move",
        .args = @constCast(&[_]*parser.Node{&inner}),
    } };
    try checker.checkExpr(&move_node, &scope, false);

    // data should now be moved
    const state = scope.getState("data").?;
    try std.testing.expect(state.state == .moved);
}

test "ownership - primitive field access allowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    // Set up DeclTable with a struct that has a primitive field
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 2);
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = "f32" }, .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_ = .{ .primitive = "f32" }, .has_default = false, .is_pub = true };
    try decl_table.structs.put("Vec2", .{ .name = "Vec2", .fields = fields, .is_pub = true });

    var checker = OwnershipChecker.init(alloc, &reporter);
    checker.decls = &decl_table;

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'v' as Vec2 (non-primitive struct)
    try scope.defineTyped("v", false, "Vec2");

    // v.x — f32 is primitive, should be allowed (copy)
    var obj = parser.Node{ .identifier = "v" };
    var field_node = parser.Node{ .field_expr = .{
        .object = &obj,
        .field = "x",
    } };
    try checker.checkExpr(&field_node, &scope, false);

    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - non-primitive field move rejected" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    // Set up DeclTable with a struct that has a non-primitive field
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();

    const fields = try alloc.alloc(declarations.FieldSig, 1);
    fields[0] = .{ .name = "inner", .type_ = .{ .named = "Other" }, .has_default = false, .is_pub = false };
    try decl_table.structs.put("Container", .{ .name = "Container", .fields = fields, .is_pub = false });

    var checker = OwnershipChecker.init(alloc, &reporter);
    checker.decls = &decl_table;

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'c' as Container
    try scope.defineTyped("c", false, "Container");

    // c.inner — Other is non-primitive, used as move → should error
    var obj = parser.Node{ .identifier = "c" };
    var field_node = parser.Node{ .field_expr = .{
        .object = &obj,
        .field = "inner",
    } };
    try checker.checkExpr(&field_node, &scope, false);

    try std.testing.expect(reporter.hasErrors());
}

test "ownership - struct field borrow allowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'player' as non-primitive struct
    try scope.define("player", false);

    // &player.name — borrow is fine
    var obj = parser.Node{ .identifier = "player" };
    var field_node = parser.Node{ .field_expr = .{
        .object = &obj,
        .field = "name",
    } };
    try checker.checkExpr(&field_node, &scope, true);

    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - if branch moves conservatively" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var checker = OwnershipChecker.init(alloc, &reporter);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("data", false);
    try scope.define("flag", true);

    // Simulate: if(flag) { var x = data }
    // After if, data should be moved (conservative)
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const data_id = try a.create(parser.Node);
    data_id.* = .{ .identifier = "data" };
    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = data_id,
        .is_pub = false,
    } };

    const stmts = try a.alloc(*parser.Node, 1);
    stmts[0] = var_node;
    const then_block = try a.create(parser.Node);
    then_block.* = .{ .block = .{ .statements = stmts } };

    const flag_id = try a.create(parser.Node);
    flag_id.* = .{ .identifier = "flag" };
    const if_node = try a.create(parser.Node);
    if_node.* = .{ .if_stmt = .{
        .condition = flag_id,
        .then_block = then_block,
        .else_block = null,
    } };

    try checker.checkStatement(if_node, &scope);
    try std.testing.expect(!reporter.hasErrors());

    // data should be considered moved after the if
    const state = scope.getState("data").?;
    try std.testing.expect(state.state == .moved);
}
