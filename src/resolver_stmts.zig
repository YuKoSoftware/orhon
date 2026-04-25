// resolver_stmts.zig — Declaration registration and statement resolution
// Satellite of resolver.zig — all functions take *TypeResolver as first parameter.

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const declarations = @import("declarations.zig");
const ast_store_mod = @import("ast_store.zig");
const ast_typed = @import("ast_typed.zig");

const AstNodeIndex = ast_store_mod.AstNodeIndex;
const TypeResolver = resolver_mod.TypeResolver;
const Scope = resolver_mod.Scope;
const ResolveCtx = resolver_mod.ResolveCtx;
const RT = types.ResolvedType;

pub fn registerDecl(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope) anyerror!void {
    switch (self.store.getNode(idx).tag) {
        .func_decl => {
            const f = ast_typed.FuncDecl.unpack(self.store, idx);
            const ret_node = try self.mustReverse(f.return_type);
            const ret_type = try types.resolveTypeNode(self.ctx.decls.typeAllocator(), ret_node);
            try scope.define(self.store.strings.get(f.name), ret_type);
        },
        .struct_decl => {
            const s = ast_typed.StructDecl.unpack(self.store, idx);
            const name = self.store.strings.get(s.name);
            try scope.define(name, RT{ .named = name });
        },
        .enum_decl => {
            const e = ast_typed.EnumDecl.unpack(self.store, idx);
            const name = self.store.strings.get(e.name);
            try scope.define(name, RT{ .named = name });
            const members = self.store.extra_data.items[e.members_start..e.members_end];
            for (members) |m_u32| {
                const m_idx: AstNodeIndex = @enumFromInt(m_u32);
                if (self.store.getNode(m_idx).tag == .enum_variant) {
                    const ev = ast_typed.EnumVariant.unpack(self.store, m_idx);
                    try scope.define(self.store.strings.get(ev.name), RT{ .named = name });
                }
            }
        },
        .handle_decl => {
            const h = ast_typed.HandleDecl.unpack(self.store, idx);
            const name = self.store.strings.get(h.name);
            try scope.define(name, RT{ .named = name });
        },
        .blueprint_decl => {
            const b = ast_typed.BlueprintDecl.unpack(self.store, idx);
            const name = self.store.strings.get(b.name);
            try scope.define(name, RT{ .named = name });
        },
        .var_decl => {
            const v = ast_typed.VarDecl.unpack(self.store, idx);
            const t = if (v.type_annotation != .none)
                try self.resolveTypeAnnotation(v.type_annotation)
            else
                RT.inferred;
            try scope.define(self.store.strings.get(v.name), t);
        },
        else => {},
    }
}

/// Check name for duplicate/shadowing and define it in scope.
/// Reports an error if name already exists in scope (duplicate) or in any
/// enclosing scope up to the function boundary (shadowing).
fn defineUnique(self: *TypeResolver, scope: *Scope, name: []const u8, t: RT, idx: AstNodeIndex) !void {
    if (scope.vars.contains(name)) {
        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "'{s}' already declared in this scope", .{name});
    } else if (self.lookupInFuncScope(scope, name)) {
        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "'{s}' shadows a declaration in an outer scope — shadowing is not allowed", .{name});
    }
    try scope.define(name, t);
}

pub fn resolveNode(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!void {
    const tag = self.store.getNode(idx).tag;
    switch (tag) {
        .func_decl => {
            const f = ast_typed.FuncDecl.unpack(self.store, idx);
            const fname = self.store.strings.get(f.name);
            var func_scope = Scope.init(self.ctx.allocator, scope);
            func_scope.is_func_root = true;
            defer func_scope.deinit();

            var has_type_param = false;
            const params_slice = self.store.extra_data.items[f.params_start..f.params_end];
            for (params_slice) |p_u32| {
                const p_idx: AstNodeIndex = @enumFromInt(p_u32);
                if (self.store.getNode(p_idx).tag == .param) {
                    const p = ast_typed.Param.unpack(self.store, p_idx);
                    const pname = self.store.strings.get(p.name);
                    const ta_tag = self.store.getNode(p.type_annotation).tag;
                    const is_type_param = ta_tag == .type_named and
                        std.mem.eql(u8, self.store.strings.get(ast_typed.TypeNamed.unpack(self.store, p.type_annotation).name), "type");
                    if (is_type_param) {
                        has_type_param = true;
                        try defineUnique(self, &func_scope, pname,
                            .{ .type_param = .{ .name = pname, .binder = idx } }, p_idx);
                    } else {
                        try self.validateType(p.type_annotation, &func_scope, rctx);
                        const t: RT = blk: {
                            if (ta_tag == .type_named) {
                                const tname = self.store.strings.get(
                                    ast_typed.TypeNamed.unpack(self.store, p.type_annotation).name);
                                if (func_scope.lookup(tname)) |st| {
                                    if (st == .type_param) break :blk st;
                                }
                            }
                            const ta_node = try self.mustReverse(p.type_annotation);
                            break :blk try types.resolveTypeNode(self.ctx.decls.typeAllocator(), ta_node);
                        };
                        try defineUnique(self, &func_scope, pname, t, p_idx);
                        // Type-check default value against declared param type
                        if (p.default_value != .none) {
                            const dv_type = try self.resolveExpr(p.default_value, &func_scope, rctx);
                            try self.checkAssignCompat(t, dv_type, p_idx);
                        }
                    }
                }
            }

            // Build param_names slice for compt argument validation
            var param_buf = std.ArrayListUnmanaged([]const u8){};
            defer param_buf.deinit(self.ctx.allocator);
            for (params_slice) |p_u32| {
                const p_idx: AstNodeIndex = @enumFromInt(p_u32);
                if (self.store.getNode(p_idx).tag == .param) {
                    const p = ast_typed.Param.unpack(self.store, p_idx);
                    try param_buf.append(self.ctx.allocator, self.store.strings.get(p.name));
                }
            }

            // Validate return type in func_scope so type params (T: type) are visible
            try self.validateType(f.return_type, &func_scope, rctx);

            // Check: `any` return type requires at least one `any`-typed parameter
            // Skip for methods inside generic structs — `any` may be a fallback for unmappable types
            if (!rctx.in_generic_struct and
                self.store.getNode(f.return_type).tag == .type_named and
                types.Primitive.fromName(self.store.strings.get(ast_typed.TypeNamed.unpack(self.store, f.return_type).name)) == .any)
            {
                var has_any_param = false;
                for (params_slice) |p_u32| {
                    const p_idx: AstNodeIndex = @enumFromInt(p_u32);
                    if (self.store.getNode(p_idx).tag == .param) {
                        const p = ast_typed.Param.unpack(self.store, p_idx);
                        if (self.store.getNode(p.type_annotation).tag == .type_named and
                            types.Primitive.fromName(self.store.strings.get(ast_typed.TypeNamed.unpack(self.store, p.type_annotation).name)) == .any)
                        {
                            has_any_param = true;
                            break;
                        }
                    }
                }
                if (!has_any_param) {
                    try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx),
                        "function '{s}' returns 'any' but has no 'any'-typed parameter — return type cannot be determined", .{fname});
                }
            }

            var func_rctx = rctx;
            func_rctx.param_names = param_buf.items;
            // If function has type params, return type is generic — skip return type checking
            func_rctx.current_return_type = if (has_type_param)
                RT.inferred
            else
                try self.resolveTypeAnnotationInScope(f.return_type, &func_scope);

            try self.resolveNode(f.body, &func_scope, func_rctx);
        },
        .struct_decl => {
            const s = ast_typed.StructDecl.unpack(self.store, idx);
            var struct_scope = Scope.init(self.ctx.allocator, scope);
            defer struct_scope.deinit();
            // Add type params to scope (T: type → T is a known type)
            var has_struct_type_params = false;
            const tp_slice = self.store.extra_data.items[s.type_params_start..s.type_params_end];
            for (tp_slice) |tp_u32| {
                const tp_idx: AstNodeIndex = @enumFromInt(tp_u32);
                if (self.store.getNode(tp_idx).tag == .param) {
                    const p = ast_typed.Param.unpack(self.store, tp_idx);
                    const is_tp = self.store.getNode(p.type_annotation).tag == .type_named and
                        std.mem.eql(u8, self.store.strings.get(ast_typed.TypeNamed.unpack(self.store, p.type_annotation).name), "type");
                    if (is_tp) {
                        has_struct_type_params = true;
                        const tpname = self.store.strings.get(p.name);
                        try struct_scope.define(tpname,
                            .{ .type_param = .{ .name = tpname, .binder = idx } });
                    }
                }
            }
            var struct_rctx = rctx;
            struct_rctx.type_decl_depth += 1;
            if (has_struct_type_params) struct_rctx.in_generic_struct = true;
            const members_slice = self.store.extra_data.items[s.members_start..s.members_end];
            for (members_slice) |m_u32| {
                const m_idx: AstNodeIndex = @enumFromInt(m_u32);
                try self.resolveNode(m_idx, &struct_scope, struct_rctx);
            }
            // Check blueprint conformance — uses *parser.Node StructDecl via reverse_map
            if (self.reverseNodeMut(idx)) |n| {
                if (n.* == .struct_decl) {
                    try self.checkBlueprintConformance(n.struct_decl, self.nodeLocFromIdx(idx));
                }
            }
        },
        .blueprint_decl => {
            const b = ast_typed.BlueprintDecl.unpack(self.store, idx);
            // Validate method signatures resolve correctly
            var bp_scope = Scope.init(self.ctx.allocator, scope);
            defer bp_scope.deinit();
            // Blueprint name is a valid type within its own methods
            try bp_scope.define(self.store.strings.get(b.name), .{ .primitive = .@"type" });
            const methods_slice = self.store.extra_data.items[b.methods_start..b.methods_end];
            for (methods_slice) |m_u32| {
                const m_idx: AstNodeIndex = @enumFromInt(m_u32);
                try self.resolveNode(m_idx, &bp_scope, rctx);
            }
        },
        .enum_decl => {},
        .handle_decl => {},
        .block => {
            const stmts = ast_typed.Block.getStmts(self.store, idx);
            var block_scope = Scope.init(self.ctx.allocator, scope);
            defer block_scope.deinit();
            var found_exit = false;
            for (stmts) |stmt_idx| {
                if (found_exit) {
                    try self.ctx.reporter.warn(.{
                        .code = .unreachable_code,
                        .message = "unreachable code",
                        .loc = self.nodeLocFromIdx(stmt_idx),
                    });
                    // Only warn once per block, but keep resolving for other diagnostics
                    found_exit = false;
                }
                try self.resolveStatement(stmt_idx, &block_scope, rctx);
                // Check early exit via reverse_map bridge
                if (self.reverseNodeMut(stmt_idx)) |n| {
                    if (parser.blockHasEarlyExit(n)) found_exit = true;
                }
            }
        },
        .var_decl => {
            const v = ast_typed.VarDecl.unpack(self.store, idx);
            const vname = self.store.strings.get(v.name);
            if (v.type_annotation != .none) {
                try self.validateType(v.type_annotation, scope, rctx);
                // Reference types (const& T, mut& T) are only valid in function parameters
                if (self.store.getNode(v.type_annotation).tag == .type_ptr) {
                    try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "reference type not allowed in variable declaration — use '{s}' by value or as a function parameter",
                        .{vname});
                }
            }
            // Duplicate/shadowing check (only inside functions/blocks, not top-level)
            if (scope.parent != null) {
                if (scope.vars.contains(vname)) {
                    try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "variable '{s}' already declared in this scope", .{vname});
                } else if (self.lookupInFuncScope(scope, vname)) {
                    try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "variable '{s}' shadows a declaration in an outer scope — shadowing is not allowed", .{vname});
                }
            }
            {
                const val_type = try self.resolveExpr(v.value, scope, rctx);
                const resolved = if (v.type_annotation != .none)
                    try self.resolveTypeAnnotationInScope(v.type_annotation, scope)
                else
                    val_type;
                if (v.type_annotation == .none) {
                    if (val_type == .primitive and
                        (val_type.primitive == .numeric_literal or
                        val_type.primitive == .float_literal))
                    {
                        try self.ctx.reporter.report(.{
                            .code = .numeric_literal_needs_type,
                            .message = "numeric literal requires explicit type — use 'const x: i32 = 42'",
                            .loc = self.nodeLocFromIdx(idx),
                        });
                    }
                } else {
                    try self.checkAssignCompat(resolved, val_type, idx);
                }
                try scope.define(vname, resolved);
                try self.ast_type_map.put(self.ctx.allocator, idx, resolved);
            }
        },
        .field_decl => {
            const f = ast_typed.FieldDecl.unpack(self.store, idx);
            // Validate field type annotation
            try self.validateType(f.type_annotation, scope, rctx);
            // 'any' is not valid as a struct field type
            if (self.store.getNode(f.type_annotation).tag == .type_named and
                types.Primitive.fromName(self.store.strings.get(ast_typed.TypeNamed.unpack(self.store, f.type_annotation).name)) == .any)
            {
                try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx),
                    "'any' is not valid as a struct field type — use a type parameter instead", .{});
            }
            // Type-check default value against declared type
            if (f.default_value != .none) {
                const field_type = try self.resolveTypeAnnotationInScope(f.type_annotation, scope);
                const val_type = try self.resolveExpr(f.default_value, scope, rctx);
                try self.checkAssignCompat(field_type, val_type, idx);
            }
        },
        .test_decl => {
            const t = ast_typed.TestDecl.unpack(self.store, idx);
            var test_rctx = rctx;
            test_rctx.current_return_type = null;
            try self.resolveNode(t.body, scope, test_rctx);
        },
        else => {},
    }
}

pub fn resolveStatement(self: *TypeResolver, idx: AstNodeIndex, scope: *Scope, rctx: ResolveCtx) anyerror!void {
    const tag = self.store.getNode(idx).tag;
    switch (tag) {
        .var_decl => try self.resolveNode(idx, scope, rctx),
        .return_stmt => {
            const r = ast_typed.ReturnStmt.unpack(self.store, idx);
            if (r.value != .none) {
                const val_type = try self.resolveExpr(r.value, scope, rctx);
                // Check return type matches function signature
                if (rctx.current_return_type) |expected| {
                    if (expected != .unknown and expected != .inferred and
                        val_type != .unknown and val_type != .inferred and
                        !resolver_mod.typesCompatible(val_type, expected))
                    {
                        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "return type mismatch: expected '{s}', got '{s}'",
                            .{ expected.name(), val_type.name() });
                    }
                }
            }
        },
        .if_stmt => {
            const i = ast_typed.IfStmt.unpack(self.store, idx);
            // Validate `is` usage in condition via reverse_map bridge
            var cond_rctx = rctx;
            if (self.reverseNodeMut(i.condition)) |cond_node| {
                if (resolver_mod.isIsCheck(cond_node)) {
                    cond_rctx.in_is_condition = true;
                } else if (resolver_mod.containsIsCheck(cond_node)) {
                    cond_rctx.in_is_condition = true;
                    try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx),
                        "compound 'is' not supported — use nested if statements for multiple type checks", .{});
                }
            }
            const cond_type = try self.resolveExpr(i.condition, scope, cond_rctx);
            if (cond_type != .unknown and cond_type != .inferred and
                !(cond_type == .primitive and cond_type.primitive == .bool))
            {
                try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "type mismatch in if condition: expected bool, got '{s}'", .{cond_type.name()});
            }
            try self.resolveNode(i.then_block, scope, rctx);
            if (i.else_block != .none) try self.resolveNode(i.else_block, scope, rctx);
        },
        .while_stmt => {
            const w = ast_typed.WhileStmt.unpack(self.store, idx);
            const cond_type = try self.resolveExpr(w.condition, scope, rctx);
            if (cond_type != .unknown and cond_type != .inferred and
                !(cond_type == .primitive and cond_type.primitive == .bool))
            {
                try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "type mismatch in while condition: expected bool, got '{s}'", .{cond_type.name()});
            }
            if (w.continue_expr != .none) _ = try self.resolveExpr(w.continue_expr, scope, rctx);
            var loop_rctx = rctx;
            loop_rctx.loop_depth += 1;
            try self.resolveNode(w.body, scope, loop_rctx);
        },
        .for_stmt => {
            const f = ast_typed.ForStmt.unpack(self.store, idx);
            var for_scope = Scope.init(self.ctx.allocator, scope);
            defer for_scope.deinit();

            // Resolve all iterables
            var iter_types = std.ArrayListUnmanaged(RT){};
            defer iter_types.deinit(self.ctx.allocator);
            const iters_slice = self.store.extra_data.items[f.iterables_start..f.iterables_end];
            for (iters_slice) |it_u32| {
                const it_idx: AstNodeIndex = @enumFromInt(it_u32);
                const t = try self.resolveExpr(it_idx, scope, rctx);
                try iter_types.append(self.ctx.allocator, t);
            }

            // Get capture names from extra_data (stored as StringIndex values)
            const caps_slice = self.store.extra_data.items[f.captures_start..f.captures_end];
            const n_captures = caps_slice.len;
            const n_iterables = iters_slice.len;
            const is_tuple_capture = f.flags & 1 != 0;

            if (is_tuple_capture) {
                // Tuple capture — first iterable provides struct fields, rest are extra captures
                const first_type = if (iter_types.items.len > 0) iter_types.items[0] else RT.inferred;
                const capture_type = if (n_iterables > 0) blk: {
                    const first_iter_idx: AstNodeIndex = @enumFromInt(iters_slice[0]);
                    break :blk resolver_mod.inferCaptureTypeIdx(self, first_iter_idx, first_type);
                } else RT.inferred;
                const extra_iterables = if (iter_types.items.len > 1) iter_types.items.len - 1 else 0;
                const type_name = capture_type.name();
                const struct_sig: ?declarations.StructSig = if (self.ctx.decls.symbols.get(type_name)) |sym| switch (sym) {
                    .@"struct" => |sig| sig,
                    else => null,
                } else null;

                if (capture_type == .inferred or capture_type == .unknown) {
                    for (caps_slice) |c_u32| {
                        const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                        try defineUnique(self, &for_scope, self.store.strings.get(cap_si), RT.inferred, idx);
                    }
                } else if (struct_sig) |sig| {
                    const expected = sig.fields.len + extra_iterables;
                    if (n_captures != expected) {
                        try self.ctx.reporter.reportFmt(
                            self.nodeLocFromIdx(idx),
                            "tuple capture count ({d}) does not match struct '{s}' field count ({d}){s}",
                            .{ n_captures, type_name, sig.fields.len, if (extra_iterables > 0) " plus extra iterables" else "" },
                        );
                        for (caps_slice) |c_u32| {
                            const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                            try defineUnique(self, &for_scope, self.store.strings.get(cap_si), RT.inferred, idx);
                        }
                    } else {
                        // Struct field captures
                        for (caps_slice[0..sig.fields.len], sig.fields) |c_u32, field| {
                            const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                            try defineUnique(self, &for_scope, self.store.strings.get(cap_si), field.type_, idx);
                        }
                        // Extra captures from additional iterables (e.g., 0.. → usize)
                        for (caps_slice[sig.fields.len..], iter_types.items[1..]) |c_u32, it| {
                            const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                            const et = if (n_iterables > 1) blk: {
                                const sec_iter_idx: AstNodeIndex = @enumFromInt(iters_slice[1]);
                                break :blk resolver_mod.inferCaptureTypeIdx(self, sec_iter_idx, it);
                            } else RT.inferred;
                            try defineUnique(self, &for_scope, self.store.strings.get(cap_si), et, idx);
                        }
                    }
                } else {
                    try self.ctx.reporter.reportFmt(
                        self.nodeLocFromIdx(idx),
                        "tuple capture requires a struct element type, got '{s}'",
                        .{type_name},
                    );
                    for (caps_slice) |c_u32| {
                        const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                        try defineUnique(self, &for_scope, self.store.strings.get(cap_si), RT.inferred, idx);
                    }
                }
            } else {
                // Non-tuple: each capture maps 1:1 to an iterable
                if (n_captures != n_iterables) {
                    try self.ctx.reporter.reportFmt(
                        self.nodeLocFromIdx(idx),
                        "for loop has {d} iterable(s) but {d} capture(s)",
                        .{ n_iterables, n_captures },
                    );
                    for (caps_slice) |c_u32| {
                        const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                        try defineUnique(self, &for_scope, self.store.strings.get(cap_si), RT.inferred, idx);
                    }
                } else {
                    for (caps_slice, iters_slice, iter_types.items) |c_u32, it_u32, it| {
                        const cap_si: ast_store_mod.StringIndex = @enumFromInt(c_u32);
                        const it_idx: AstNodeIndex = @enumFromInt(it_u32);
                        try defineUnique(self, &for_scope, self.store.strings.get(cap_si), resolver_mod.inferCaptureTypeIdx(self, it_idx, it), idx);
                    }
                }
            }

            var loop_rctx = rctx;
            loop_rctx.loop_depth += 1;
            try self.resolveNode(f.body, &for_scope, loop_rctx);
        },
        .match_stmt => {
            const m = ast_typed.MatchStmt.unpack(self.store, idx);
            const match_type = try self.resolveExpr(m.value, scope, rctx);
            var has_else = false;
            var has_guard = false;
            const arms_slice = self.store.extra_data.items[m.arms_start..m.arms_end];
            for (arms_slice) |arm_u32| {
                const arm_idx: AstNodeIndex = @enumFromInt(arm_u32);
                if (self.store.getNode(arm_idx).tag == .match_arm) {
                    const ma = ast_typed.MatchArm.unpack(self.store, arm_idx);
                    const pat_tag = self.store.getNode(ma.pattern).tag;
                    // Check for else arm — must be last
                    if (pat_tag == .identifier) {
                        const pat_name = self.store.strings.get(ast_typed.Identifier.unpack(self.store, ma.pattern).name);
                        if (std.mem.eql(u8, pat_name, "else")) {
                            if (has_else) {
                                try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(arm_idx), "duplicate 'else' arm in match statement", .{});
                            }
                            has_else = true;
                        } else if (has_else) {
                            try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(arm_idx), "'else' arm must be the last arm in a match statement", .{});
                        }
                        // Validate union match arm patterns
                        if (!std.mem.eql(u8, pat_name, "else")) {
                            try self.validateMatchArm(pat_name, match_type, arm_idx);
                        }
                    } else {
                        if (has_else) {
                            try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(arm_idx), "'else' arm must be the last arm in a match statement", .{});
                        }
                        // resolve non-identifier pattern expressions
                        _ = try self.resolveExpr(ma.pattern, scope, rctx);
                    }
                    // Resolve guard expression
                    if (ma.guard != .none) {
                        has_guard = true;
                        var guard_scope = Scope.init(self.ctx.allocator, scope);
                        defer guard_scope.deinit();
                        if (pat_tag == .identifier) {
                            const pat_name = self.store.strings.get(ast_typed.Identifier.unpack(self.store, ma.pattern).name);
                            try defineUnique(self, &guard_scope, pat_name, match_type, arm_idx);
                        }
                        _ = try self.resolveExpr(ma.guard, &guard_scope, rctx);
                        try self.resolveNode(ma.body, &guard_scope, rctx);
                    } else {
                        try self.resolveNode(ma.body, scope, rctx);
                    }
                }
            }
            // Guards require else arm for exhaustiveness — guards don't guarantee coverage
            if (has_guard and !has_else) {
                try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "match with guards requires an 'else' arm", .{});
            }
            // Check exhaustiveness for union matches
            if (!has_else) {
                // Bridge: pass *parser.Node arms to checkMatchExhaustiveness
                if (self.reverseNodeMut(idx)) |n| {
                    if (n.* == .match_stmt) {
                        try self.checkMatchExhaustiveness(match_type, n.match_stmt.arms, n);
                    }
                }
            }
        },
        .assignment => {
            const a = ast_typed.Assignment.unpack(self.store, idx);
            const left = try self.resolveExpr(a.lhs, scope, rctx);
            const right = try self.resolveExpr(a.rhs, scope, rctx);
            // Mixed numeric check for compound assignments (+=, -=, *=, /=)
            const op: parser.Operator = @enumFromInt(a.op);
            if (op != .assign) {
                if (left == .primitive and right == .primitive) {
                    const lp = left.primitive;
                    const rp = right.primitive;
                    if (lp.isNumeric() and rp.isNumeric() and
                        lp != .numeric_literal and rp != .numeric_literal and
                        lp != .float_literal and rp != .float_literal and
                        lp != rp)
                    {
                        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx),
                            "cannot mix {s} and {s} in compound assignment — use @cast({s}, x) to convert",
                            .{ lp.toName(), rp.toName(), lp.toName() });
                    }
                }
            }
        },
        .defer_stmt => {
            const d = ast_typed.DeferStmt.unpack(self.store, idx);
            try self.resolveNode(d.body, scope, rctx);
        },
        .destruct_decl => {
            const d = ast_typed.DestructDecl.unpack(self.store, idx);
            _ = try self.resolveExpr(d.value, scope, rctx);
            const names_slice = self.store.extra_data.items[d.names_start..d.names_end];
            for (names_slice) |n_u32| {
                const name_si: ast_store_mod.StringIndex = @enumFromInt(n_u32);
                const name = self.store.strings.get(name_si);
                if (scope.parent != null) {
                    if (scope.vars.contains(name)) {
                        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "variable '{s}' already declared in this scope", .{name});
                    } else if (self.lookupInFuncScope(scope, name)) {
                        try self.ctx.reporter.reportFmt(self.nodeLocFromIdx(idx), "variable '{s}' shadows a declaration in an outer scope — shadowing is not allowed", .{name});
                    }
                }
                try scope.define(name, RT.inferred);
            }
        },
        .break_stmt => {
            if (rctx.loop_depth == 0) {
                try self.ctx.reporter.report(.{
                    .code = .break_outside_loop,
                    .message = "'break' outside of loop",
                    .loc = self.nodeLocFromIdx(idx),
                });
            }
        },
        .continue_stmt => {
            if (rctx.loop_depth == 0) {
                try self.ctx.reporter.report(.{
                    .code = .continue_outside_loop,
                    .message = "'continue' outside of loop",
                    .loc = self.nodeLocFromIdx(idx),
                });
            }
        },
        .block => try self.resolveNode(idx, scope, rctx),
        else => _ = try self.resolveExpr(idx, scope, rctx),
    }
}
