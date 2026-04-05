// ownership_checks.zig — Statement and expression ownership checks
// Satellite of ownership.zig — all functions take *OwnershipChecker as first parameter.

const std = @import("std");
const ownership = @import("ownership.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");

const OwnershipChecker = ownership.OwnershipChecker;
const OwnershipScope = ownership.OwnershipScope;

pub fn checkStatement(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void {
    switch (node.*) {
        .var_decl => |v| {
            // Check the value expression for use-after-move
            try checkExpr(self, v.value, scope, false);
            // Define the new variable as owned, with type name for field lookup
            const type_name = if (v.type_annotation) |t| ownership.typeNodeName(t) else "";
            const is_prim = if (type_name.len > 0)
                (types.isPrimitiveName(type_name) or builtins.isValueType(type_name))
            else
                ownership.inferPrimitiveFromValue(v.value, scope);
            const is_const = v.mutability == .constant;
            try scope.defineTyped(v.name, is_prim, type_name, is_const);
        },

        .destruct_decl => |d| {
            try checkExpr(self, d.value, scope, false);
            // Define new variables as owned
            for (d.names) |name| try scope.define(name, false);
            // @splitAt consumes the source — mark as moved
            if (d.value.* == .compiler_func) {
                const cf = d.value.compiler_func;
                if (std.mem.eql(u8, cf.name, "splitAt") and cf.args.len >= 1 and cf.args[0].* == .identifier) {
                    _ = scope.setState(cf.args[0].identifier, .moved);
                }
            }
        },

        .return_stmt => |r| {
            if (r.value) |v| {
                try checkExpr(self, v, scope, false);
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
            try checkExpr(self, a.right, scope, false);
            // If assigning from identifier (non-borrow), it's a move of the source
            if (a.right.* == .identifier) {
                const name = a.right.identifier;
                if (scope.getState(name)) |state| {
                    if (!state.is_primitive) {
                        _ = scope.setState(name, .moved);
                    }
                }
            }
            // Assignment to target restores ownership — the target receives a new value
            if (a.left.* == .identifier) {
                _ = scope.setState(a.left.identifier, .owned);
            }
        },

        .if_stmt => |i| {
            try checkExpr(self, i.condition, scope, true);

            const snapshot = try self.snapshotScope(scope);
            defer self.allocator.free(snapshot);

            try self.checkNode(i.then_block, scope);
            const after_then = try self.snapshotScope(scope);
            defer self.allocator.free(after_then);
            const then_exits = blockHasEarlyExit(i.then_block);

            // Restore for else branch
            self.restoreScope(scope, snapshot);

            if (i.else_block) |e| try self.checkNode(e, scope);
            const else_exits = if (i.else_block) |e| blockHasEarlyExit(e) else false;

            // Merge based on early-exit analysis:
            // - Branch that exits early cannot affect post-if scope
            // - Only merge moves from branches that fall through
            if (then_exits and else_exits) {
                // Both branches exit — code after if is unreachable
                self.restoreScope(scope, snapshot);
            } else if (then_exits) {
                // Then-branch exits — only else-branch state matters (already in scope)
            } else if (else_exits) {
                // Else-branch exits — only then-branch state matters
                self.restoreScope(scope, after_then);
            } else {
                // Neither exits — conservative merge (moved in either = moved)
                self.mergeMovedStates(scope, after_then);
            }
        },

        .while_stmt => |w| {
            try checkExpr(self, w.condition, scope, true);
            if (w.continue_expr) |c| try checkExpr(self, c, scope, false);
            try self.checkNode(w.body, scope);
        },

        .for_stmt => |f| {
            try checkExpr(self, f.iterable, scope, true);
            var for_scope = OwnershipScope.init(self.allocator, scope);
            defer for_scope.deinit();
            // Tuple captures are struct field copies — always value types
            const elem_is_prim = if (f.is_tuple_capture) true else self.inferIterableElemPrimitive(f.iterable, scope);
            for (f.captures) |v| try for_scope.define(v, elem_is_prim);
            // Index variable is always usize (primitive)
            if (f.index_var) |idx| try for_scope.define(idx, true);
            try self.checkNode(f.body, &for_scope);
        },

        .match_stmt => |m| {
            try checkExpr(self, m.value, scope, true);

            const snapshot = try self.snapshotScope(scope);
            defer self.allocator.free(snapshot);

            const ArmState = struct { snap: []OwnershipChecker.StateEntry, exits: bool };
            var arm_states = std.ArrayListUnmanaged(ArmState){};
            defer {
                for (arm_states.items) |s| self.allocator.free(s.snap);
                arm_states.deinit(self.allocator);
            }

            for (m.arms) |arm| {
                if (arm.* == .match_arm) {
                    self.restoreScope(scope, snapshot);
                    try checkExpr(self, arm.match_arm.pattern, scope, true);
                    if (arm.match_arm.guard) |g| try checkExpr(self, g, scope, true);
                    try self.checkNode(arm.match_arm.body, scope);
                    try arm_states.append(self.allocator, .{
                        .snap = try self.snapshotScope(scope),
                        .exits = blockHasEarlyExit(arm.match_arm.body),
                    });
                }
            }

            // Restore to pre-match state, then merge only non-exiting arms
            self.restoreScope(scope, snapshot);
            var all_exit = arm_states.items.len > 0;
            for (arm_states.items) |s| {
                if (!s.exits) {
                    self.mergeMovedStates(scope, s.snap);
                    all_exit = false;
                }
            }
            // If all arms exit, code after match is unreachable — restore pre-match
            if (all_exit) self.restoreScope(scope, snapshot);
        },

        .defer_stmt => |d| {
            try self.checkNode(d.body, scope);
        },

        .break_stmt, .continue_stmt => {},

        .block => try self.checkNode(node, scope),

        else => try checkExpr(self, node, scope, false),
    }
}

/// Check expression for use-after-move
/// is_borrow: true if this usage is a borrow (& prefix), doesn't consume
pub fn checkExpr(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope, is_borrow: bool) anyerror!void {
    switch (node.*) {
        .identifier => |name| {
            if (scope.getState(name)) |state| {
                if (state.state == .moved) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "use of moved value '{s}' — consider using @copy()", .{name});
                }
                // If not a borrow, not primitive, and not const, this is a move
                if (!is_borrow and !state.is_primitive and !state.is_const and state.state == .owned) {
                    _ = scope.setState(name, .moved);
                }
            }
        },

        .mut_borrow_expr => |inner| {
            try checkExpr(self, inner, scope, true);
        },

        .const_borrow_expr => |inner| {
            // Explicit const borrow — same as mut_borrow_expr, always read-only
            try checkExpr(self, inner, scope, true);
        },

        .binary_expr => |b| {
            // Operands of binary expressions are reads, not moves
            try checkExpr(self, b.left, scope, true);
            try checkExpr(self, b.right, scope, true);
        },

        .call_expr => |c| {
            try checkExpr(self, c.callee, scope, true); // callee is always borrowed
            for (c.args) |arg| {
                // Arguments passed by value are moves, by mut& or const& are borrows
                const arg_is_borrow = arg.* == .mut_borrow_expr or arg.* == .const_borrow_expr;
                try checkExpr(self, arg, scope, arg_is_borrow);
            }
        },

        .field_expr => |f| {
            // Accessing a field borrows the struct
            try checkExpr(self, f.object, scope, true);

            // If this field access is used as a move (not borrow),
            // check if the field type is primitive (copy) or non-primitive (move)
            if (!is_borrow and f.object.* == .identifier) {
                const obj_name = f.object.identifier;
                if (scope.getState(obj_name)) |state| {
                    if (!state.is_primitive) {
                        const field_is_prim = self.lookupFieldType(scope, obj_name, f.field);
                        if (field_is_prim) |is_prim| {
                            if (!is_prim) {
                                // Known non-primitive field → struct atomicity error
                                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "cannot move field '{s}' out of '{s}' — structs are atomic ownership units — consider using @copy()",
                                    .{ f.field, obj_name });
                            }
                        } else if (self.isKnownStruct(scope, obj_name)) {
                            // Known struct but field not found — conservative error
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "cannot move field '{s}' out of '{s}' — structs are atomic ownership units — consider using @copy()",
                                .{ f.field, obj_name });
                        }
                        // Unknown type (union unwrap, etc.) — skip check
                    }
                }
            }
        },

        .index_expr => |i| {
            try checkExpr(self, i.object, scope, true);
            try checkExpr(self, i.index, scope, true);
        },

        .slice_expr => |s| {
            try checkExpr(self, s.object, scope, true);
            try checkExpr(self, s.low, scope, true);
            try checkExpr(self, s.high, scope, true);
        },

        .compiler_func => |cf| {
            if (std.mem.eql(u8, cf.name, "move")) {
                // move(x) — explicit move, mark source as moved
                if (cf.args.len == 1) {
                    try checkExpr(self, cf.args[0], scope, false);
                }
            } else if (std.mem.eql(u8, cf.name, "copy")) {
                // copy(x) — explicit copy, borrows (no move)
                if (cf.args.len == 1) {
                    try checkExpr(self, cf.args[0], scope, true);
                }
            } else if (std.mem.eql(u8, cf.name, "swap")) {
                // swap(a, b) — both stay owned, values exchanged
                for (cf.args) |arg| {
                    try checkExpr(self, arg, scope, true);
                }
            } else {
                // Other compiler funcs — check args as borrows
                for (cf.args) |arg| {
                    try checkExpr(self, arg, scope, true);
                }
            }
        },

        .unary_expr => |u| {
            // Unary operands are reads, not moves
            try checkExpr(self, u.operand, scope, true);
        },

        .array_literal => |elems| {
            for (elems) |elem| {
                try checkExpr(self, elem, scope, false);
            }
        },

        .tuple_literal => |t| {
            for (t.fields) |field| {
                try checkExpr(self, field, scope, false);
            }
        },

        .interpolated_string => |interp| {
            // Embedded expressions are read (borrowed), not moved
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |e| try checkExpr(self, e, scope, true),
                    .literal => {},
                }
            }
        },

        else => {},
    }
}

/// Check if a block contains an early exit (return, break, continue).
/// For if statements, both branches must exit for the block to be an early exit.
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
            const else_block = i.else_block orelse break :blk false;
            break :blk blockHasEarlyExit(i.then_block) and blockHasEarlyExit(else_block);
        },
        else => false,
    };
}
