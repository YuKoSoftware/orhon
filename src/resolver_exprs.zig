// resolver_exprs.zig — Expression type resolution
// Satellite of resolver.zig — all functions take *TypeResolver as first parameter.

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");

const TypeResolver = resolver_mod.TypeResolver;
const Scope = resolver_mod.Scope;
const RT = types.ResolvedType;

/// Resolve an expression and return its ResolvedType
pub fn resolveExpr(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!RT {
    const result = try resolveExprInner(self, node, scope);
    try self.type_map.put(self.ctx.allocator, node, result);
    return result;
}

fn resolveExprInner(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!RT {
    return switch (node.*) {
        .int_literal => RT{ .primitive = .numeric_literal },
        .float_literal => RT{ .primitive = .float_literal },
        .string_literal => RT{ .primitive = .string },
        .interpolated_string => |interp| {
            // Resolve inner expressions so they appear in type_map
            for (interp.parts) |part| {
                switch (part) {
                    .expr => |expr_node| _ = try resolveExpr(self, expr_node, scope),
                    .literal => {},
                }
            }
            return RT{ .primitive = .string };
        },
        .bool_literal => RT{ .primitive = .bool },
        .null_literal => RT.null_type,
        .error_literal => RT.err,

        .identifier => |id_name| {
            if (scope.lookup(id_name)) |t| return t;
            if (self.ctx.decls.funcs.contains(id_name)) {
                const sentinel = &@as(RT, .unknown);
                return RT{ .func_ptr = .{ .params = &.{}, .return_type = sentinel } };
            }
            if (self.ctx.decls.structs.contains(id_name)) return RT{ .named = id_name };
            if (self.ctx.decls.enums.contains(id_name)) return RT{ .named = id_name };
            if (self.ctx.decls.vars.get(id_name)) |v| return v.type_ orelse RT.unknown;
            if (builtins.isBuiltinType(id_name)) return RT{ .named = id_name };
            if (self.isIncludedType(id_name)) return RT{ .named = id_name };
            if (builtins.isBuiltinValue(id_name)) return RT{ .named = id_name };
            // Primitive type names (i32, f64, etc.) may appear as arguments to cast() and similar
            if (types.isPrimitiveName(id_name)) return RT{ .named = id_name };
            // Compiler-intrinsic functions are resolved by codegen, not tracked in decls
            if (builtins.CompilerFunc.fromName(id_name) != null) return RT{ .named = id_name };
            // Known module names — used as qualified access prefixes (module.Type, module.func)
            if (self.ctx.all_decls) |ad| {
                if (ad.contains(id_name)) return RT.unknown;
            }

            // Enum variants and the 'else' match pattern are used as bare
            // identifiers in match patterns. They are not in the scope chain — silently
            // return unknown to avoid false errors.
            if (std.mem.eql(u8, id_name, "else")) return RT.unknown;
            if (self.isEnumVariant(id_name)) return RT.unknown;

            // Build candidate list from scope chain + module declarations for suggestion
            var candidates: std.ArrayListUnmanaged([]const u8) = .{};
            defer candidates.deinit(self.ctx.allocator);
            var sc: ?*const Scope = scope;
            while (sc) |s| : (sc = s.parent) {
                var it = s.vars.keyIterator();
                while (it.next()) |k| try candidates.append(self.ctx.allocator, k.*);
            }
            var fit = self.ctx.decls.funcs.keyIterator();
            while (fit.next()) |k| try candidates.append(self.ctx.allocator, k.*);
            var sit = self.ctx.decls.structs.keyIterator();
            while (sit.next()) |k| try candidates.append(self.ctx.allocator, k.*);
            var eit = self.ctx.decls.enums.keyIterator();
            while (eit.next()) |k| try candidates.append(self.ctx.allocator, k.*);
            var vit = self.ctx.decls.vars.keyIterator();
            while (vit.next()) |k| try candidates.append(self.ctx.allocator, k.*);

            // Check if the identifier exists as a pub declaration in any other loaded module
            var cross_module_hint: ?[]const u8 = null;
            if (self.ctx.all_decls) |ad| {
                var mod_it = ad.iterator();
                while (mod_it.next()) |entry| {
                    const mod_name = entry.key_ptr.*;
                    const mod_decls = entry.value_ptr.*;
                    // Skip current module — its decls were already checked above
                    if (mod_decls == self.ctx.decls) continue;
                    const found = (if (mod_decls.funcs.get(id_name)) |f| f.is_pub else false) or
                        (if (mod_decls.structs.get(id_name)) |st| st.is_pub else false) or
                        (if (mod_decls.enums.get(id_name)) |e| e.is_pub else false) or
                        mod_decls.vars.contains(id_name);
                    if (found) {
                        cross_module_hint = try std.fmt.allocPrint(self.ctx.allocator,
                            " \u{2014} '{s}' exists in module '{s}' (add 'import {s}')", .{ id_name, mod_name, mod_name });
                        break;
                    }
                }
            }
            defer if (cross_module_hint) |h| self.ctx.allocator.free(h);

            const suggestion = try errors.formatSuggestion(id_name, candidates.items, self.ctx.allocator);
            defer if (suggestion) |s| self.ctx.allocator.free(s);

            const hint = cross_module_hint orelse suggestion orelse "";
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "unknown identifier '{s}'{s}", .{ id_name, hint });
            return RT.unknown;
        },

        .binary_expr => |b| {
            const left = try resolveExpr(self, b.left, scope);
            const right = try resolveExpr(self, b.right, scope);
            const l_is_str = left == .primitive and left.primitive == .string;
            const r_is_str = right == .primitive and right.primitive == .string;
            // Reject == and != on str — use string.equals() instead
            if (b.op == .eq or b.op == .ne) {
                if (l_is_str or r_is_str) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "cannot use '{s}' on str — use string.equals() for content comparison",
                        .{if (b.op == .eq) "==" else "!="});
                }
            }
            // Reject arithmetic on strings — use ++ for concatenation
            const is_arithmetic = switch (b.op) {
                .add, .sub, .mul, .div, .mod => true,
                else => false,
            };
            if (is_arithmetic and (l_is_str or r_is_str)) {
                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                    "cannot use '{s}' on str — use '++' for concatenation", .{b.op.toZig()});
            }
            // Reject ++ on numeric types — use + for arithmetic
            if (b.op == .concat) {
                const l_is_num = left == .primitive and left.primitive.isNumeric();
                const r_is_num = right == .primitive and right.primitive.isNumeric();
                if (l_is_num or r_is_num) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "cannot use '++' on numeric types — use '+' for arithmetic", .{});
                }
            }
            // Mixed numeric type check — reject different numeric types in binary expressions.
            // Literals (numeric_literal, float_literal) are excluded — they coerce freely.
            // Assignment and argument widening are handled by typesCompatible, not here.
            if (left == .primitive and right == .primitive) {
                const lp = left.primitive;
                const rp = right.primitive;
                if (lp.isNumeric() and rp.isNumeric() and
                    lp != .numeric_literal and rp != .numeric_literal and
                    lp != .float_literal and rp != .float_literal and
                    lp != rp)
                {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "cannot mix {s} and {s} in binary expression — use @cast({s}, x) to convert",
                        .{ lp.toName(), rp.toName(), lp.toName() });
                }
            }
            if (b.op.isLogical() or b.op.isComparison()) return RT{ .primitive = .bool };
            if (b.op == .concat) return left;
            return left;
        },

        .unary_expr => |u| {
            const operand_type = try resolveExpr(self, u.operand, scope);
            if (u.op == .negate) {
                if (operand_type == .primitive and operand_type.primitive.isUnsigned()) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "cannot negate unsigned type '{s}'", .{operand_type.primitive.toName()});
                }
            }
            return operand_type;
        },
        .mut_borrow_expr => |b| try resolveExpr(self, b, scope),
        .const_borrow_expr => |b| try resolveExpr(self, b, scope),

        .call_expr => |c| {
            const callee_type = try resolveExpr(self, c.callee, scope);

            // Look up the callee's FuncSig so we can identify which arg slots into
            // an `any` param and set `in_anytype_arg` accordingly.
            // `any` is how zig_module.zig maps `comptime x: anytype` in the generated
            // .orh interface; RT{ .named = "any" } is how classifyNamed represents it.
            const callee_sig: ?declarations.FuncSig = blk: {
                if (c.callee.* == .identifier) {
                    if (self.ctx.decls.funcs.get(c.callee.identifier)) |sig| break :blk sig;
                }
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        const obj_id = fe.object.identifier;
                        // Module-qualified call: module.func(args).
                        // Look in the named module's decl table first, then current module.
                        if (self.ctx.all_decls) |ad| {
                            if (ad.get(obj_id)) |mod_decls| {
                                if (mod_decls.funcs.get(fe.field)) |sig| break :blk sig;
                                // Also check generic structs: Bitfield(T, flags: any) pattern.
                                // Synthesise a FuncSig from the struct's type_params so the
                                // anytype-arg detection below can set in_anytype_arg correctly.
                                if (mod_decls.structs.get(fe.field)) |ss| {
                                    if (ss.type_params.len > 0) break :blk declarations.FuncSig{
                                        .name = ss.name,
                                        .params = ss.type_params,
                                        .param_nodes = &.{},
                                        .return_type = RT{ .primitive = .@"type" },
                                        .return_type_node = undefined,
                                        .context = .normal,
                                        .is_pub = ss.is_pub,
                                        .is_instance = false,
                                    };
                                }
                            }
                        }
                        if (self.ctx.decls.funcs.get(fe.field)) |sig| break :blk sig;
                    }
                }
                break :blk null;
            };

            // Resolve arg types and check for String/[]u8 coercion.
            // Capped at 16 args — coercion checks skip later args (unlikely in practice).
            var arg_types_buf: [16]RT = undefined;
            const arg_count = @min(c.args.len, 16);
            for (c.args, 0..) |arg, idx| {
                const prev_any = self.in_anytype_arg;
                defer self.in_anytype_arg = prev_any;
                self.in_anytype_arg = false;
                if (callee_sig) |sig| {
                    if (idx < sig.params.len) {
                        const pt = sig.params[idx].type_;
                        if (pt == .named and std.mem.eql(u8, pt.named, "any")) {
                            self.in_anytype_arg = true;
                        }
                    }
                }
                const at = try resolveExpr(self, arg, scope);
                if (idx < 16) arg_types_buf[idx] = at;
            }
            // Check args against function signature — reject []u8 → String
            try self.checkByteSliceStringCoercion(c, arg_types_buf[0..arg_count], node);

            if (c.callee.* == .identifier) {
                const name = c.callee.identifier;
                // Struct constructor: Player{name: "john", ...} → Player
                // Tuple constructor: MinMax{min: 1, max: 2} → MinMax (type aliases)
                if (self.ctx.decls.structs.contains(name) or self.ctx.decls.types.contains(name)) {
                    // Reject positional arguments — struct/tuple constructors use {} syntax
                    if (c.args.len > 0 and c.arg_names.len == 0) {
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                            "struct constructors use '{{}}' syntax — use '{s}{{field: value}}' instead of '{s}(value)'", .{ name, name });
                    }
                    return RT{ .named = name };
                }
                // Builtin or included type constructor: Ptr(T)(...), List(i32)(...)
                if (builtins.isBuiltinType(name) or self.isIncludedType(name)) return RT{ .named = name };
                // Named args only valid for struct/tuple constructors
                if (c.arg_names.len > 0) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "named arguments are only valid for struct constructors — '{s}' is not a struct", .{name});
                }
                if (scope.lookup(name)) |t| {
                    if (t == .func_ptr) {
                        // Function pointer call — OK
                    } else if (t == .primitive and t.primitive == .@"type") {
                        // Local type alias used as a constructor (e.g. `const Perms: type = ...`)
                        return RT{ .named = name };
                    } else if (!self.ctx.decls.funcs.contains(name) and
                        !self.ctx.decls.structs.contains(name) and
                        !self.ctx.decls.enums.contains(name) and
                        !builtins.isBuiltinType(name) and
                        !self.isIncludedType(name))
                    {
                        // Non-callable variable
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "'{s}' is not callable — expected a function or constructor", .{name});
                        return t;
                    }
                }
                if (self.ctx.decls.funcs.get(name)) |sig| {
                    // Argument count validation
                    const n_defaults = blk: {
                        var count: usize = 0;
                        for (sig.param_nodes) |p| {
                            if (p.* == .param and p.param.default_value != null) count += 1;
                        }
                        break :blk count;
                    };
                    const min_args = sig.params.len - n_defaults;
                    const max_args = sig.params.len;
                    if (c.args.len < min_args or c.args.len > max_args) {
                        if (min_args == max_args) {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                                "'{s}' expects {d} argument(s), got {d}", .{ name, max_args, c.args.len });
                        } else {
                            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                                "'{s}' expects {d} to {d} argument(s), got {d}", .{ name, min_args, max_args, c.args.len });
                        }
                    }
                    // Compt constraint validation — reject non-comptime arguments
                    if (sig.context == .compt) {
                        for (c.args, 0..) |arg, idx| {
                            if (!isComptimeKnown(self, arg)) {
                                const arg_name = if (arg.* == .identifier) arg.identifier else "expression";
                                const is_type_param = if (idx < sig.params.len)
                                    switch (sig.params[idx].type_) {
                                        .primitive => |p| p == .@"type",
                                        else => false,
                                    }
                                else
                                    false;
                                if (is_type_param) {
                                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                                        "compt function '{s}' expects a type argument, but '{s}' is a function parameter", .{ name, arg_name });
                                } else {
                                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                                        "compt function '{s}' requires compile-time-known arguments, but '{s}' is a function parameter", .{ name, arg_name });
                                }
                            }
                        }
                    }
                    return sig.return_type;
                }
            }
            if (c.callee.* == .field_expr) {
                const fe = c.callee.field_expr;
                if (fe.object.* == .identifier) {
                    const obj_id = fe.object.identifier;
                    // Module-level function: module.func()
                    // Only validate arity when obj_id is a known module — otherwise this
                    // may match a same-named top-level function instead of the intended method.
                    if (self.ctx.decls.funcs.get(fe.field)) |sig| {
                        const is_module = if (self.ctx.all_decls) |ad| ad.contains(obj_id) else false;
                        if (is_module) {
                            try validateCallArity(self, sig, c.args.len, false, fe.field, node);
                        }
                        return sig.return_type;
                    }
                    // Static or instance method on a struct.
                    // obj_id may be the struct type name (static: Renderer.create())
                    // or a variable whose type is a struct (instance: r.draw(m)).
                    const called_on_type = self.ctx.decls.structs.contains(obj_id);
                    const struct_name: []const u8 = blk: {
                        if (called_on_type) break :blk obj_id;
                        if (scope.lookup(obj_id)) |var_type| {
                            // Unwrap error/null unions to get the underlying named type
                            if (var_type == .named) break :blk var_type.named;
                            if (var_type.unionInnerType()) |inner| {
                                if (inner == .named) break :blk inner.named;
                            }
                        }
                        break :blk "";
                    };
                    if (struct_name.len > 0) {
                        // Build "StructName.method" key and look in struct_methods
                        const key = try std.fmt.allocPrint(self.ctx.allocator, "{s}.{s}", .{ struct_name, fe.field });
                        defer self.ctx.allocator.free(key);
                        {
                            if (self.ctx.decls.struct_methods.get(key)) |sig| {
                                try validateCallStyle(self, sig, called_on_type, fe.field, struct_name, node);
                                try validateCallArity(self, sig, c.args.len, !called_on_type, fe.field, node);
                                return sig.return_type;
                            }
                            // Cross-module: check all loaded module decls
                            if (self.ctx.all_decls) |ad| {
                                if (ad.get(obj_id)) |mod_decls| {
                                    if (mod_decls.struct_methods.get(key)) |sig| {
                                        try validateCallStyle(self, sig, called_on_type, fe.field, struct_name, node);
                                        try validateCallArity(self, sig, c.args.len, !called_on_type, fe.field, node);
                                        return sig.return_type;
                                    }
                                }
                                var it = ad.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.*.struct_methods.get(key)) |sig| {
                                        try validateCallStyle(self, sig, called_on_type, fe.field, struct_name, node);
                                        try validateCallArity(self, sig, c.args.len, !called_on_type, fe.field, node);
                                        return sig.return_type;
                                    }
                                }
                            }
                        }
                    }
                }
                // Cross-module static method: module.Type.method(args) — e.g. tamga_vk3d.Renderer.create()
                // callee is field_expr{object: field_expr{object: module_id, field: TypeName}, field: method}
                if (fe.object.* == .field_expr) {
                    const inner = fe.object.field_expr;
                    if (inner.object.* == .identifier) {
                        const type_name = inner.field;
                        const method_name = fe.field;
                        const key = try std.fmt.allocPrint(self.ctx.allocator, "{s}.{s}", .{ type_name, method_name });
                        defer self.ctx.allocator.free(key);
                        {
                            if (self.ctx.decls.struct_methods.get(key)) |sig| {
                                try validateCallStyle(self, sig, true, method_name, type_name, node);
                                try validateCallArity(self, sig, c.args.len, false, fe.field, node);
                                return sig.return_type;
                            }
                            if (self.ctx.all_decls) |ad| {
                                var it = ad.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.*.struct_methods.get(key)) |sig| {
                                        try validateCallStyle(self, sig, true, method_name, type_name, node);
                                        try validateCallArity(self, sig, c.args.len, false, fe.field, node);
                                        return sig.return_type;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Generic constructor call: Vec2(f32)(...) — callee is itself a call
            if (c.callee.* == .call_expr) {
                const inner_c = c.callee.call_expr;
                if (inner_c.callee.* == .identifier) {
                    const name = inner_c.callee.identifier;
                    // compt func returning type: Vec2(f32)(...) → named type
                    if (self.ctx.decls.funcs.get(name)) |sig| {
                        if (sig.context == .compt) return RT{ .named = name };
                    }
                    // Generic struct: List(i32).new() — List is in decls.structs
                    if (self.ctx.decls.structs.contains(name)) return RT{ .named = name };
                    if (builtins.isBuiltinType(name) or self.isIncludedType(name)) return RT{ .named = name };
                }
            }
            return callee_type;
        },

        .field_expr => |f| {
            const obj_type = try resolveExpr(self, f.object, scope);
            // .value on (Error | T) or (null | T) unwraps to the inner type.
            // This lets the resolver track variables assigned via `var x = result.value`.
            if (std.mem.eql(u8, f.field, "value")) {
                if (obj_type.unionInnerType()) |inner| return inner;
            }
            const obj_name = obj_type.name();
            if (self.ctx.decls.structs.get(obj_name)) |sig| {
                for (sig.fields) |field| {
                    if (std.mem.eql(u8, field.name, f.field)) {
                        return field.type_;
                    }
                }
            }
            return RT.inferred;
        },

        .index_expr => |i| {
            const obj_type = try resolveExpr(self, i.object, scope);
            _ = try resolveExpr(self, i.index, scope);
            // Reject indexing non-indexable types (bool, void, etc.)
            if (obj_type == .primitive) {
                const tn = obj_type.primitive;
                if (tn == .bool or tn == .void) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "cannot index into type '{s}'", .{tn.toName()});
                }
            }
            return RT.inferred;
        },

        .slice_expr => |s| {
            _ = try resolveExpr(self, s.object, scope);
            _ = try resolveExpr(self, s.low, scope);
            _ = try resolveExpr(self, s.high, scope);
            return RT.inferred;
        },

        .compiler_func => |cf| {
            var first_arg_type: RT = RT.unknown;
            for (cf.args, 0..) |arg, idx| {
                const t = try resolveExpr(self, arg, scope);
                if (idx == 0) first_arg_type = t;
            }
            const loc = self.ctx.nodeLoc(node);
            const func = builtins.CompilerFunc.fromName(cf.name);

            const f = func orelse {
                try self.ctx.reporter.reportFmt(loc, "unknown compiler function '@{s}'", .{cf.name});
                return RT.unknown;
            };

            // @type is an internal desugaring artifact from `is` — reject outside if/elif
            if (f == .@"type" and !self.in_is_condition) {
                try self.ctx.reporter.reportFmt(loc,
                    "'is' can only be used in if/elif conditions — use @typeOf(x) == T for type checks elsewhere", .{});
            }

            // Argument count validation
            const ArgCount = struct { min: usize, max: usize };
            const expected: ArgCount = switch (f) {
                .cast, .swap, .splitAt, .hasField, .hasDecl, .fieldType => .{ .min = 2, .max = 2 },
                .assert => .{ .min = 1, .max = 2 },
                .copy, .move, .size, .@"align", .typename, .typeid, .typeOf,
                .fieldNames, .wrap, .sat, .overflow, .@"type", .compileError,
                => .{ .min = 1, .max = 1 },
            };

            if (cf.args.len < expected.min or cf.args.len > expected.max) {
                if (expected.min == expected.max) {
                    try self.ctx.reporter.reportFmt(loc, "@{s} takes exactly {d} argument(s)", .{ cf.name, expected.min });
                } else {
                    try self.ctx.reporter.reportFmt(loc, "@{s} takes {d} to {d} arguments", .{ cf.name, expected.min, expected.max });
                }
            }

            // String literal validation for introspection functions
            switch (f) {
                .hasField, .hasDecl, .fieldType => {
                    if (cf.args.len >= 2 and cf.args[1].* != .string_literal) {
                        try self.ctx.reporter.reportFmt(loc, "@{s} requires a string literal as second argument", .{cf.name});
                    }
                },
                else => {},
            }

            // Operator validation for wrapping/saturating/overflow builtins
            switch (f) {
                .wrap, .sat, .overflow => {
                    if (cf.args.len >= 1 and cf.args[0].* == .binary_expr) {
                        const op = cf.args[0].binary_expr.op;
                        if (op != .add and op != .sub and op != .mul) {
                            try self.ctx.reporter.reportFmt(loc, "@{s} only supports +, -, * operators — division and modulo have no wrapping equivalents", .{cf.name});
                        }
                    }
                },
                else => {},
            }

            // Return type resolution
            return switch (f) {
                .size, .@"align", .typeid => RT{ .primitive = .usize },
                .typename => RT{ .primitive = .string },
                .typeOf, .fieldType => RT{ .primitive = .@"type" },
                .assert, .swap, .compileError => RT{ .primitive = .void },
                .hasField, .hasDecl => RT{ .primitive = .bool },
                .fieldNames => RT.inferred,
                .cast => blk: {
                    if (cf.args.len >= 1 and cf.args[0].* == .identifier) {
                        break :blk RT{ .named = cf.args[0].identifier };
                    }
                    if (cf.args.len >= 1 and cf.args[0].* == .type_named) {
                        const tn = cf.args[0].type_named;
                        if (types.Primitive.fromName(tn)) |prim| break :blk RT{ .primitive = prim };
                        break :blk RT{ .named = tn };
                    }
                    break :blk RT.unknown;
                },
                .copy, .move, .wrap, .sat, .overflow => first_arg_type,
                .@"type" => RT{ .primitive = .@"type" },
                .splitAt => RT.inferred,
            };
        },

        .tuple_literal => |tl| {
            // Resolve each element so ordinary type errors inside still fire.
            for (tl.elements) |el| {
                _ = try resolveExpr(self, el, scope);
            }
            // Context check: @tuple is only legal while resolving an arg to an
            // `anytype` parameter of a Zig-backed function. The call-expr resolver
            // will set `in_anytype_arg` while iterating matching args (Task 5).
            if (!self.in_anytype_arg) {
                try self.ctx.reporter.reportFmt(
                    self.ctx.nodeLoc(node),
                    "@tuple(...) can only be used as an anytype argument to a Zig function",
                    .{},
                );
            }
            return RT.inferred;
        },

        .array_literal => |elems| {
            // Resolve element types; infer array type from first element
            var elem_type: RT = RT.inferred;
            for (elems) |elem| {
                const t = try resolveExpr(self, elem, scope);
                if (elem_type == .inferred) {
                    elem_type = t;
                } else if (t != .inferred and t != .unknown and elem_type != .unknown and
                    !resolver_mod.typesCompatible(t, elem_type))
                {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(elem),
                        "array element type mismatch — expected '{s}', got '{s}'", .{ elem_type.name(), t.name() });
                }
            }
            // Empty array or unknown element — can't construct array type
            if (elem_type == .inferred or elems.len == 0) return RT.inferred;

            // Return [N]T array type
            const alloc = self.ctx.decls.typeAllocator();
            const inner = try alloc.create(RT);
            inner.* = elem_type;
            const size_node = try alloc.create(parser.Node);
            size_node.* = .{ .int_literal = try std.fmt.allocPrint(alloc, "{d}", .{elems.len}) };
            return RT{ .array = .{ .elem = inner, .size = size_node } };
        },

        .version_literal => return RT.inferred,

        // Tuple type literal in expression position: const Point: type = {x: f32, y: f32}
        .type_tuple_named => |fields| {
            const alloc = self.ctx.decls.typeAllocator();
            const resolved = try alloc.alloc(RT.TupleField, fields.len);
            for (fields, 0..) |f, i| {
                resolved[i] = .{
                    .name = f.name,
                    .type_ = try types.resolveTypeNode(alloc, f.type_node),
                };
            }
            return RT{ .tuple = resolved };
        },

        .range_expr => |r| {
            _ = try resolveExpr(self, r.left, scope);
            _ = try resolveExpr(self, r.right, scope);
            return RT.inferred;
        },

        .break_stmt, .continue_stmt => RT.unknown,

        else => RT.unknown,
    };
}

const declarations = @import("declarations.zig");

/// Validate that the call style matches the method kind: instance methods must
/// be called on a value, static methods must be called on the type.
fn validateCallStyle(
    self: *TypeResolver,
    sig: declarations.FuncSig,
    called_on_type: bool,
    method_name: []const u8,
    struct_name: []const u8,
    node: *parser.Node,
) !void {
    if (sig.is_instance and called_on_type) {
        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
            "'{s}' is an instance method — call it on a value: 'value.{s}()'", .{ method_name, method_name });
    }
    if (!sig.is_instance and !called_on_type) {
        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
            "'{s}' is a static method — call it on the type: '{s}.{s}()'", .{ method_name, struct_name, method_name });
    }
}

/// Validate call argument count against a function signature, accounting for
/// the implicit self parameter in instance methods and default parameter values.
fn validateCallArity(
    self: *TypeResolver,
    sig: declarations.FuncSig,
    call_args_len: usize,
    is_method: bool,
    callee_name: []const u8,
    node: *parser.Node,
) !void {
    // Instance methods have self as params[0] — not passed explicitly by the caller
    const param_offset: usize = if (is_method and sig.is_instance) 1 else 0;

    // Count parameters with default values (excluding self)
    var n_defaults: usize = 0;
    for (sig.param_nodes[param_offset..]) |p| {
        if (p.* == .param and p.param.default_value != null) n_defaults += 1;
    }

    const total_params = sig.params.len - param_offset;
    const min_args = total_params - n_defaults;
    const max_args = total_params;

    if (call_args_len < min_args or call_args_len > max_args) {
        if (min_args == max_args) {
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                "'{s}' expects {d} argument(s), got {d}", .{ callee_name, max_args, call_args_len });
        } else {
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                "'{s}' expects {d} to {d} argument(s), got {d}", .{ callee_name, min_args, max_args, call_args_len });
        }
    }
}

/// Conservative check: returns false only for expressions that are DEFINITELY
/// not compile-time-known (function parameters). Returns true for everything else
/// to avoid false positives.
fn isComptimeKnown(self: *TypeResolver, node: *parser.Node) bool {
    return switch (node.*) {
        .int_literal, .float_literal, .string_literal, .bool_literal, .null_literal => true,
        .identifier => |name| !self.param_names.contains(name),
        .unary_expr => |u| isComptimeKnown(self, u.operand),
        .binary_expr => |b| isComptimeKnown(self, b.left) and isComptimeKnown(self, b.right),
        .call_expr => |c| {
            if (c.callee.* == .identifier) {
                if (self.ctx.decls.funcs.get(c.callee.identifier)) |sig| {
                    return sig.context == .compt;
                }
            }
            return true;
        },
        else => true,
    };
}
