// ownership.zig — Ownership & Move Analysis pass (pass 6)
// Tracks ownership transfers, catches use-after-move,
// validates struct atomicity (no partial field moves).

const std = @import("std");
const parser = @import("parser.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const sema = @import("sema.zig");
const scope_mod = @import("scope.zig");
const checks_impl = @import("ownership_checks.zig");

/// Ownership state for a variable in current scope
pub const VarState = struct {
    name: []const u8,
    state: types.OwnershipState,
    is_primitive: bool, // primitives always copy, never move
    is_const: bool, // const values are implicitly copyable (never moved)
    type_name: []const u8, // type name for struct field lookup
};

/// Ownership scope — tracks variable states
pub const OwnershipScope = struct {
    base: scope_mod.ScopeBase(VarState),

    pub fn init(allocator: std.mem.Allocator, parent: ?*OwnershipScope) OwnershipScope {
        return .{ .base = scope_mod.ScopeBase(VarState).init(
            allocator,
            if (parent) |p| &p.base else null,
        ) };
    }

    pub fn deinit(self: *OwnershipScope) void {
        self.base.deinit();
    }

    pub fn define(self: *OwnershipScope, name: []const u8, is_primitive: bool) !void {
        try self.base.define(name, .{
            .name = name,
            .state = .owned,
            .is_primitive = is_primitive,
            .is_const = false,
            .type_name = "",
        });
    }

    pub fn defineTyped(self: *OwnershipScope, name: []const u8, is_primitive: bool, type_name: []const u8, is_const: bool) !void {
        try self.base.define(name, .{
            .name = name,
            .state = .owned,
            .is_primitive = is_primitive,
            .is_const = is_const,
            .type_name = type_name,
        });
    }

    pub fn getState(self: *const OwnershipScope, name: []const u8) ?VarState {
        return self.base.lookup(name);
    }

    pub fn setState(self: *OwnershipScope, name: []const u8, state: types.OwnershipState) bool {
        if (self.base.lookupPtr(name)) |v| {
            v.state = state;
            return true;
        }
        return false;
    }
};

/// The ownership checker
pub const OwnershipChecker = struct {
    ctx: *const sema.SemanticContext,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ctx: *const sema.SemanticContext) OwnershipChecker {
        return .{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    /// Check if a variable's type is a known struct in DeclTable.
    pub fn isKnownStruct(self: *const OwnershipChecker, scope: *OwnershipScope, obj_name: []const u8) bool {
        const var_state = scope.getState(obj_name) orelse return false;
        if (var_state.type_name.len > 0) {
            return self.ctx.decls.structs.contains(var_state.type_name);
        }
        return false;
    }

    pub fn lookupFieldType(self: *const OwnershipChecker, scope: *OwnershipScope, obj_name: []const u8, field_name: []const u8) ?bool {
        const decls = self.ctx.decls;
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

    /// Look up a struct method by type name first, then by iterating all structs.
    /// Returns the FuncSig if found, null otherwise.
    pub fn lookupStructMethod(self: *const OwnershipChecker, scope: *OwnershipScope, obj_name: []const u8, method_name: []const u8) ?declarations.FuncSig {
        const decls = self.ctx.decls;

        // Fast path: use the variable's type_name if available
        if (scope.getState(obj_name)) |state| {
            if (state.type_name.len > 0) {
                if (decls.getMethod(state.type_name, method_name)) |sig| return sig;
            }
        }

        // Slow path: scan all registered struct method tables (type_name may be empty)
        var it = decls.struct_methods.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.get(method_name)) |sig| return sig;
        }
        return null;
    }

    /// Infer whether for-loop captures are primitive based on the iterable.
    /// Returns true for ranges, primitive arrays/slices; false (conservative) otherwise.
    pub fn inferIterableElemPrimitive(_: *const OwnershipChecker, iterable: *parser.Node, scope: *OwnershipScope) bool {
        switch (iterable.*) {
            // Range expressions (0..10) always produce integer captures
            .range_expr => return true,
            // Array literals — check the first element
            .array_literal => |elems| {
                if (elems.len > 0) {
                    return switch (elems[0].*) {
                        .int_literal, .float_literal, .bool_literal, .string_literal, .interpolated_string => true,
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

    /// Check ownership rules in a program AST
    pub fn check(self: *OwnershipChecker, ast: *parser.Node) !void {
        if (ast.* != .program) return;

        var scope = OwnershipScope.init(self.allocator, null);
        defer scope.deinit();

        for (ast.program.top_level) |node| {
            try self.checkNode(node, &scope);
        }
    }

    pub fn checkNode(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void {
        switch (node.*) {
            .func_decl => |f| {
                var func_scope = OwnershipScope.init(self.allocator, scope);
                defer func_scope.deinit();

                for (f.params) |param| {
                    if (param.* == .param) {
                        const type_name = typeNodeName(param.param.type_annotation);
                        const is_prim = types.isPrimitiveName(type_name) or builtins.isValueType(type_name);
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

            },

            .test_decl => |t| {
                var test_scope = OwnershipScope.init(self.allocator, scope);
                defer test_scope.deinit();
                try self.checkNode(t.body, &test_scope);
            },

            .struct_decl => |s| {
                for (s.members) |member| {
                    if (member.* == .func_decl) {
                        try self.checkNode(member, scope);
                    }
                }
            },

            .enum_decl => {},
            .handle_decl => {},

            else => {},
        }
    }

    pub fn checkStatement(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void {
        return checks_impl.checkStatement(self, node, scope);
    }

    pub fn checkExpr(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope, is_borrow: bool) anyerror!void {
        return checks_impl.checkExpr(self, node, scope, is_borrow);
    }

    /// Snapshot the ownership states of all variables in the current scope
    pub const StateEntry = struct { name: []const u8, state: types.OwnershipState };

    pub fn snapshotScope(self: *OwnershipChecker, scope: *OwnershipScope) ![]StateEntry {
        var entries = std.ArrayListUnmanaged(StateEntry){};
        var it = scope.base.vars.iterator();
        while (it.next()) |entry| {
            try entries.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .state = entry.value_ptr.state,
            });
        }
        return entries.toOwnedSlice(self.allocator);
    }

    /// Restore scope states from a snapshot
    pub fn restoreScope(_: *OwnershipChecker, scope: *OwnershipScope, snapshot: []const StateEntry) void {
        for (snapshot) |entry| {
            _ = scope.setState(entry.name, entry.state);
        }
    }

    /// Merge moved states — if a variable is moved in the given snapshot, mark it moved
    pub fn mergeMovedStates(_: *OwnershipChecker, scope: *OwnershipScope, other: []const StateEntry) void {
        for (other) |entry| {
            if (entry.state == .moved) {
                _ = scope.setState(entry.name, .moved);
            }
        }
    }
};

/// Infer whether a value expression produces a primitive type (when no annotation exists).
/// Conservative: returns false if unknown.
pub fn inferPrimitiveFromValue(value: *parser.Node, scope: *OwnershipScope) bool {
    return switch (value.*) {
        .int_literal, .float_literal, .bool_literal, .string_literal, .interpolated_string => true,
        .binary_expr => true, // arithmetic/comparison results are primitive
        .unary_expr => true, // negation/not results are primitive
        .identifier => |name| {
            // If copying from a known variable, inherit its primitive status
            if (scope.getState(name)) |state| return state.is_primitive;
            return false;
        },
        else => false,
    };
}

/// Extract the type name string from an AST type node (for DeclTable lookups)
pub fn typeNodeName(node: *parser.Node) []const u8 {
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
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

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
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

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
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'name' as string (primitive — copies, never moves)
    try scope.define("name", types.isPrimitiveName("str"));

    var id1 = parser.Node{ .identifier = "name" };
    try checker.checkExpr(&id1, &scope, false);
    var id2 = parser.Node{ .identifier = "name" };
    try checker.checkExpr(&id2, &scope, false);

    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - copy borrows without moving" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'data' as non-primitive (struct)
    try scope.define("data", false);

    // copy(data) — should borrow, not move
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

test "ownership - move marks as moved" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'data' as non-primitive
    try scope.define("data", false);

    // move(data) — should move
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
    fields[0] = .{ .name = "x", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    fields[1] = .{ .name = "y", .type_ = .{ .primitive = .f32 }, .has_default = false, .is_pub = true };
    try decl_table.structs.put("Vec2", .{ .name = "Vec2", .fields = fields, .is_pub = true });

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'v' as Vec2 (non-primitive struct, var — can be moved)
    try scope.defineTyped("v", false, "Vec2", false);

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

    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'c' as Container (var — can be moved)
    try scope.defineTyped("c", false, "Container", false);

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
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

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
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

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

test "ownership - assignment restores ownership" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'data' as non-primitive, then move it
    try scope.define("data", false);
    _ = scope.setState("data", .moved);
    try std.testing.expect(scope.getState("data").?.state == .moved);

    // Assign new value: data = newData
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const left = try a.create(parser.Node);
    left.* = .{ .identifier = "data" };
    const right = try a.create(parser.Node);
    right.* = .{ .int_literal = "42" }; // value doesn't matter for ownership
    const assign = try a.create(parser.Node);
    assign.* = .{ .assignment = .{ .op = .assign, .left = left, .right = right } };

    try checker.checkStatement(assign, &scope);

    // data should be owned again
    try std.testing.expect(scope.getState("data").?.state == .owned);
    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - type inference from literal values" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // var x = 42 → should infer as primitive
    var int_val = parser.Node{ .int_literal = "42" };
    var decl = parser.Node{ .var_decl = .{
        .name = "x",
        .type_annotation = null,
        .value = &int_val,
        .is_pub = false,
    } };
    try checker.checkStatement(&decl, &scope);

    const state = scope.getState("x").?;
    try std.testing.expect(state.is_primitive);

    // x should be usable multiple times (primitive copies)
    var id1 = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id1, &scope, false);
    var id2 = parser.Node{ .identifier = "x" };
    try checker.checkExpr(&id2, &scope, false);
    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - match arm merging is conservative" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("data", false);
    try scope.define("val", true);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: match(val) { 1 => { var x = data }, 2 => { } }
    // data is moved in arm 1 but not arm 2 → should be moved after match

    // Arm 1: var x = data (moves data)
    const data_id = try a.create(parser.Node);
    data_id.* = .{ .identifier = "data" };
    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{ .name = "x", .type_annotation = null, .value = data_id, .is_pub = false } };
    const stmts1 = try a.alloc(*parser.Node, 1);
    stmts1[0] = var_node;
    const body1 = try a.create(parser.Node);
    body1.* = .{ .block = .{ .statements = stmts1 } };
    const pat1 = try a.create(parser.Node);
    pat1.* = .{ .int_literal = "1" };
    const arm1 = try a.create(parser.Node);
    arm1.* = .{ .match_arm = .{ .pattern = pat1, .guard = null, .body = body1 } };

    // Arm 2: empty block (doesn't move data)
    const body2 = try a.create(parser.Node);
    body2.* = .{ .block = .{ .statements = &.{} } };
    const pat2 = try a.create(parser.Node);
    pat2.* = .{ .int_literal = "2" };
    const arm2 = try a.create(parser.Node);
    arm2.* = .{ .match_arm = .{ .pattern = pat2, .guard = null, .body = body2 } };

    const arms = try a.alloc(*parser.Node, 2);
    arms[0] = arm1;
    arms[1] = arm2;

    const val_id = try a.create(parser.Node);
    val_id.* = .{ .identifier = "val" };
    const match_node = try a.create(parser.Node);
    match_node.* = .{ .match_stmt = .{ .value = val_id, .arms = arms } };

    try checker.checkStatement(match_node, &scope);
    try std.testing.expect(!reporter.hasErrors());

    // data should be moved (conservative: moved in any arm → moved)
    try std.testing.expect(scope.getState("data").?.state == .moved);
}

test "ownership - return marks non-primitive as moved" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("data", false);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const id = try a.create(parser.Node);
    id.* = .{ .identifier = "data" };
    const ret = try a.create(parser.Node);
    ret.* = .{ .return_stmt = .{ .value = id } };

    try checker.checkStatement(ret, &scope);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(scope.getState("data").?.state == .moved);
}

test "ownership - inferIterableElemPrimitive" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);
    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Range expression → primitive
    var low = parser.Node{ .int_literal = "0" };
    var high = parser.Node{ .int_literal = "10" };
    var range = parser.Node{ .range_expr = .{ .op = .range, .left = &low, .right = &high } };
    try std.testing.expect(checker.inferIterableElemPrimitive(&range, &scope));

    // Array of ints → primitive
    var e1 = parser.Node{ .int_literal = "1" };
    var elems = [_]*parser.Node{&e1};
    var arr = parser.Node{ .array_literal = &elems };
    try std.testing.expect(checker.inferIterableElemPrimitive(&arr, &scope));

    // Unknown call → not primitive
    var callee = parser.Node{ .identifier = "getItems" };
    var call = parser.Node{ .call_expr = .{ .callee = &callee, .args = &.{}, .arg_names = &.{} } };
    try std.testing.expect(!checker.inferIterableElemPrimitive(&call, &scope));

    // Identifier of primitive var → primitive
    try scope.define("nums", true);
    var id = parser.Node{ .identifier = "nums" };
    try std.testing.expect(checker.inferIterableElemPrimitive(&id, &scope));

    // Identifier of non-primitive var → not primitive
    try scope.define("structs", false);
    var id2 = parser.Node{ .identifier = "structs" };
    try std.testing.expect(!checker.inferIterableElemPrimitive(&id2, &scope));
}

test "ownership - inferPrimitiveFromValue" {
    var scope = OwnershipScope.init(std.testing.allocator, null);
    defer scope.deinit();

    // Literals are primitive
    var int_node = parser.Node{ .int_literal = "42" };
    try std.testing.expect(inferPrimitiveFromValue(&int_node, &scope));

    var float_node = parser.Node{ .float_literal = "3.14" };
    try std.testing.expect(inferPrimitiveFromValue(&float_node, &scope));

    var bool_node = parser.Node{ .bool_literal = true };
    try std.testing.expect(inferPrimitiveFromValue(&bool_node, &scope));

    var str_node = parser.Node{ .string_literal = "hello" };
    try std.testing.expect(inferPrimitiveFromValue(&str_node, &scope));

    // Binary expr result is primitive
    var left = parser.Node{ .int_literal = "1" };
    var right = parser.Node{ .int_literal = "2" };
    var bin = parser.Node{ .binary_expr = .{ .op = .add, .left = &left, .right = &right } };
    try std.testing.expect(inferPrimitiveFromValue(&bin, &scope));

    // Unknown call → conservative false
    var callee = parser.Node{ .identifier = "makeStruct" };
    var call = parser.Node{ .call_expr = .{ .callee = &callee, .args = &.{}, .arg_names = &.{} } };
    try std.testing.expect(!inferPrimitiveFromValue(&call, &scope));
}

test "ownership - const value reuse allowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'v' as const, non-primitive (struct)
    try scope.defineTyped("v", false, "Vec2", true);

    // First use — const values are implicitly copyable, not moved
    var id1 = parser.Node{ .identifier = "v" };
    try checker.checkExpr(&id1, &scope, false);
    try std.testing.expect(!reporter.hasErrors()); // first use ok

    // Second use — v should still be owned (const, never marked moved)
    var id2 = parser.Node{ .identifier = "v" };
    try checker.checkExpr(&id2, &scope, false);
    try std.testing.expect(!reporter.hasErrors()); // no use-after-move for const
}

test "ownership - var value still moves" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 'v' as var, non-primitive (struct) — is_const = false
    try scope.defineTyped("v", false, "Vec2", false);

    // First use — moves v
    var id1 = parser.Node{ .identifier = "v" };
    try checker.checkExpr(&id1, &scope, false);
    try std.testing.expect(!reporter.hasErrors()); // first use ok

    // Second use — v is now moved, should error
    var id2 = parser.Node{ .identifier = "v" };
    try checker.checkExpr(&id2, &scope, false);
    try std.testing.expect(reporter.hasErrors()); // use-after-move detected
}

test "ownership - interpolated string checks embedded exprs" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    // Define 's' as non-primitive, moved
    try scope.define("s", false);
    _ = scope.setState("s", .moved);

    // Use moved 's' inside interpolated string — should detect use-after-move
    var id_node = parser.Node{ .identifier = "s" };
    var parts = [_]parser.InterpolatedPart{
        .{ .literal = "hello " },
        .{ .expr = &id_node },
    };
    var interp = parser.Node{ .interpolated_string = .{ .parts = &parts } };
    try checker.checkExpr(&interp, &scope, false);
    try std.testing.expect(reporter.hasErrors());
}

test "ownership - if with return in then-block does not falsely move" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("result", false);

    // Build: if(flag) { return result }
    var cond = parser.Node{ .bool_literal = true };
    var ret_id = parser.Node{ .identifier = "result" };
    var ret_stmt = parser.Node{ .return_stmt = .{ .value = &ret_id } };
    var stmts = [_]*parser.Node{&ret_stmt};
    var then_block = parser.Node{ .block = .{ .statements = &stmts } };
    var if_node = parser.Node{ .if_stmt = .{
        .condition = &cond,
        .then_block = &then_block,
        .else_block = null,
    } };
    try checker.checkStatement(&if_node, &scope);

    // result should NOT be moved after if — the return exits the function
    try std.testing.expect(scope.getState("result").?.state == .owned);
    try std.testing.expect(!reporter.hasErrors());
}

test "ownership - if without return still marks moved (conservative)" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("data", false);

    // Build: if(flag) { use data (moves it) } — no return
    var cond = parser.Node{ .bool_literal = true };
    var use_id = parser.Node{ .identifier = "data" };
    var stmts = [_]*parser.Node{&use_id};
    var then_block = parser.Node{ .block = .{ .statements = &stmts } };
    var if_node = parser.Node{ .if_stmt = .{
        .condition = &cond,
        .then_block = &then_block,
        .else_block = null,
    } };
    try checker.checkStatement(&if_node, &scope);

    // data should be moved — then-block doesn't exit, conservative merge applies
    try std.testing.expect(scope.getState("data").?.state == .moved);
}

test "ownership - if/else both return discards moves" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    var checker = OwnershipChecker.init(alloc, &ctx);

    var scope = OwnershipScope.init(alloc, null);
    defer scope.deinit();

    try scope.define("x", false);

    // Build: if(flag) { return x } else { return x }
    var cond = parser.Node{ .bool_literal = true };
    var ret_id1 = parser.Node{ .identifier = "x" };
    var ret1 = parser.Node{ .return_stmt = .{ .value = &ret_id1 } };
    var then_stmts = [_]*parser.Node{&ret1};
    var then_block = parser.Node{ .block = .{ .statements = &then_stmts } };

    var ret_id2 = parser.Node{ .identifier = "x" };
    var ret2 = parser.Node{ .return_stmt = .{ .value = &ret_id2 } };
    var else_stmts = [_]*parser.Node{&ret2};
    var else_block = parser.Node{ .block = .{ .statements = &else_stmts } };

    var if_node = parser.Node{ .if_stmt = .{
        .condition = &cond,
        .then_block = &then_block,
        .else_block = &else_block,
    } };
    try checker.checkStatement(&if_node, &scope);

    // Both branches exit — x should be restored to pre-branch state (owned)
    try std.testing.expect(scope.getState("x").?.state == .owned);
}
