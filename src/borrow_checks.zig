// borrow_checks.zig — Statement and expression borrow checks
// Satellite of borrow.zig — all functions take *BorrowChecker as first parameter.

const std = @import("std");
const borrow = @import("borrow.zig");
const parser = @import("parser.zig");
const BorrowChecker = borrow.BorrowChecker;

pub fn checkStatement(self: *BorrowChecker, node: *parser.Node) anyerror!void {
    self.current_node = node;
    switch (node.*) {
        .var_decl => |v| {
            // mut& is always a mutable borrow, const& is always immutable
            // NLL: borrow_ref is the declared variable name
            if (v.value.* == .mut_borrow_expr) {
                if (borrow.extractBorrowTarget(v.value.mut_borrow_expr)) |target| {
                    try self.addBorrow(target.variable, target.field, true, v.name);
                }
            } else if (v.value.* == .const_borrow_expr) {
                if (borrow.extractBorrowTarget(v.value.const_borrow_expr)) |target| {
                    try self.addBorrow(target.variable, target.field, false, v.name);
                }
            } else {
                try checkExpr(self, v.value);
            }
        },
        .return_stmt => |r| {
            if (r.value) |val| {
                // Cannot return a reference — only owned values
                if (val.* == .mut_borrow_expr or val.* == .const_borrow_expr) {
                    try self.ctx.reporter.report(.{
                        .message = "cannot return a reference — functions can only return owned values",
                        .loc = self.ctx.nodeLoc(node),
                    });
                }
                try checkExpr(self, val);
            }
        },
        .if_stmt => |i| {
            try checkExpr(self, i.condition);
            try self.checkNode(i.then_block);
            if (i.else_block) |e| try self.checkNode(e);
        },
        .while_stmt => |w| {
            try checkExpr(self, w.condition);
            if (w.continue_expr) |c| try checkExpr(self, c);
            try self.checkNode(w.body);
        },
        .for_stmt => |f| {
            for (f.iterables) |iter| try checkExpr(self, iter);
            try self.checkNode(f.body);
        },
        .match_stmt => |m| {
            try checkExpr(self, m.value);
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
            try checkExpr(self, d.value);
        },
        .break_stmt, .continue_stmt => {},
        .assignment => |a| {
            // If assigning a borrow, check for conflicts
            // NLL: borrow_ref is the LHS identifier (if it is one)
            const assign_ref: ?[]const u8 = if (a.left.* == .identifier) a.left.identifier else null;
            if (a.right.* == .mut_borrow_expr) {
                if (borrow.extractBorrowTarget(a.right.mut_borrow_expr)) |target| {
                    try self.addBorrow(target.variable, target.field, true, assign_ref);
                }
            } else if (a.right.* == .const_borrow_expr) {
                if (borrow.extractBorrowTarget(a.right.const_borrow_expr)) |target| {
                    try self.addBorrow(target.variable, target.field, false, assign_ref);
                }
            }
            // Check that borrowed variables aren't used while mutably borrowed
            try checkExprAccess(self, a.left);
            try checkExpr(self, a.right);
        },
        .block => try self.checkNode(node),
        else => try checkExpr(self, node),
    }
}

pub fn checkExpr(self: *BorrowChecker, node: *parser.Node) anyerror!void {
    switch (node.*) {
        .mut_borrow_expr => |inner| {
            // mut& in expression context (e.g. function call arg) — mutable borrow
            // NLL: null ref — temporary borrow, not tracked for NLL
            if (borrow.extractBorrowTarget(inner)) |target| {
                try self.addBorrow(target.variable, target.field, true, null);
            }
            try checkExpr(self, inner);
        },
        .const_borrow_expr => |inner| {
            // Explicit const& in expression context — always immutable
            // NLL: null ref — temporary borrow, not tracked for NLL
            if (borrow.extractBorrowTarget(inner)) |target| {
                try self.addBorrow(target.variable, target.field, false, null);
            }
            try checkExpr(self, inner);
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
                            self.lookupStructMethod(method_name)) |sig| {
                            if (sig.is_instance) {
                                const self_node = sig.param_nodes[0];
                                if (self_node.* == .param) {
                                    const is_mut = borrow.isMutableBorrowType(self_node.param.type_annotation);
                                    // Temporary borrow: check conflicts, add, then remove after call
                                    try self.addBorrow(obj_name, null, is_mut, null);
                                    // Check args while borrow is active
                                    for (c.args) |arg| try checkExpr(self, arg);
                                    // Release temporary borrow
                                    self.removeLastBorrow(obj_name);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
            try checkExpr(self, c.callee);
            for (c.args) |arg| try checkExpr(self, arg);
        },
        .binary_expr => |b| {
            try checkExpr(self, b.left);
            try checkExpr(self, b.right);
        },
        .unary_expr => |u| try checkExpr(self, u.operand),
        .field_expr => {
            // Field access: check with field-level awareness
            if (borrow.extractBorrowTarget(node)) |target| {
                try self.checkNotMutablyBorrowedPath(target.variable, target.field);
            } else {
                // Cannot extract base — fall back to recursive check
                try checkExpr(self, node.field_expr.object);
            }
        },
        .index_expr => |i| {
            try checkExpr(self, i.object);
            try checkExpr(self, i.index);
        },
        .slice_expr => |s| {
            try checkExpr(self, s.object);
            try checkExpr(self, s.low);
            try checkExpr(self, s.high);
        },
        .compiler_func => |cf| {
            for (cf.args) |arg| try checkExpr(self, arg);
        },
        .interpolated_string => |interp| {
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |e| try checkExpr(self, e),
                    .literal => {},
                }
            }
        },
        else => {},
    }
}

/// Check if accessing a variable/field that is mutably borrowed
pub fn checkExprAccess(self: *BorrowChecker, node: *parser.Node) anyerror!void {
    switch (node.*) {
        .identifier => |name| try self.checkNotMutablyBorrowedPath(name, null),
        .field_expr => {
            if (borrow.extractBorrowTarget(node)) |target| {
                try self.checkNotMutablyBorrowedPath(target.variable, target.field);
            } else {
                try checkExprAccess(self, node.field_expr.object);
            }
        },
        .index_expr => |i| try checkExprAccess(self, i.object),
        .slice_expr => |s| try checkExprAccess(self, s.object),
        else => {},
    }
}
