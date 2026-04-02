// resolver_exprs.zig — Expression type resolution
// Satellite of resolver.zig — all functions take *TypeResolver as first parameter.

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");

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
            if (self.ctx.decls.funcs.get(id_name)) |sig| return sig.return_type;
            if (self.ctx.decls.structs.contains(id_name)) return RT{ .named = id_name };
            if (self.ctx.decls.enums.contains(id_name)) return RT{ .named = id_name };
            if (self.ctx.decls.vars.get(id_name)) |v| return v.type_ orelse RT.unknown;
            if (builtins.isBuiltinType(id_name)) return RT{ .named = id_name };
            if (self.isIncludedType(id_name)) return RT{ .named = id_name };
            if (builtins.isBuiltinValue(id_name)) return RT{ .named = id_name };
            // Primitive type names (i32, f64, etc.) may appear as arguments to cast() and similar
            if (types.isPrimitiveName(id_name)) return RT{ .named = id_name };
            // Compiler-intrinsic functions are resolved by codegen, not tracked in decls
            if (builtins.isCompilerFunc(id_name)) return RT{ .named = id_name };
            // Arithmetic mode functions (wrap, sat, overflow) are codegen-level intrinsics
            if (std.mem.eql(u8, id_name, "wrap") or
                std.mem.eql(u8, id_name, "sat") or
                std.mem.eql(u8, id_name, "overflow")) return RT.unknown;
            // Known module names — used as qualified access prefixes (module.Type, module.func)
            if (self.ctx.all_decls) |ad| {
                if (ad.contains(id_name)) return RT.unknown;
            }

            // Enum variants, bitfield flags, and the 'else' match pattern are used as bare
            // identifiers in match patterns. They are not in the scope chain — silently
            // return unknown to avoid false errors.
            if (std.mem.eql(u8, id_name, "else")) return RT.unknown;
            if (self.isEnumVariantOrBitfieldFlag(id_name)) return RT.unknown;

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

            const suggestion = try errors.formatSuggestion(id_name, candidates.items, self.ctx.allocator);
            defer if (suggestion) |s| self.ctx.allocator.free(s);
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "unknown identifier '{s}'{s}", .{ id_name, suggestion orelse "" });
            return RT.unknown;
        },

        .binary_expr => |b| {
            const left = try resolveExpr(self, b.left, scope);
            _ = try resolveExpr(self, b.right, scope);
            if (std.mem.eql(u8, b.op, K.Op.AND) or
                std.mem.eql(u8, b.op, K.Op.OR) or
                std.mem.eql(u8, b.op, K.Op.EQ) or
                std.mem.eql(u8, b.op, K.Op.NE) or
                std.mem.eql(u8, b.op, K.Op.LT) or
                std.mem.eql(u8, b.op, K.Op.GT) or
                std.mem.eql(u8, b.op, K.Op.LE) or
                std.mem.eql(u8, b.op, K.Op.GE)) return RT{ .primitive = .bool };
            if (std.mem.eql(u8, b.op, K.Op.CONCAT)) return left;
            return left;
        },

        .unary_expr => |u| try resolveExpr(self, u.operand, scope),
        .mut_borrow_expr => |b| try resolveExpr(self, b, scope),
        .const_borrow_expr => |b| try resolveExpr(self, b, scope),

        .call_expr => |c| {
            const callee_type = try resolveExpr(self, c.callee, scope);
            // Resolve arg types and check for String/[]u8 coercion
            var arg_types_buf: [16]RT = undefined;
            const arg_count = @min(c.args.len, 16);
            for (c.args, 0..) |arg, idx| {
                const at = try resolveExpr(self, arg, scope);
                if (idx < 16) arg_types_buf[idx] = at;
            }
            // Check args against function signature — reject []u8 → String
            try self.checkByteSliceStringCoercion(c, arg_types_buf[0..arg_count], node);

            if (c.callee.* == .identifier) {
                const name = c.callee.identifier;
                // Struct constructor: Player(...) → Player
                if (self.ctx.decls.structs.contains(name)) return RT{ .named = name };
                // Builtin or included type constructor: Ptr(T)(...), List(i32)(...)
                if (builtins.isBuiltinType(name) or self.isIncludedType(name)) return RT{ .named = name };
                if (scope.lookup(name)) |t| {
                    if (t == .func_ptr) {
                        // Function pointer call — OK
                    } else if (!self.ctx.decls.funcs.contains(name) and
                        !self.ctx.decls.structs.contains(name) and
                        !self.ctx.decls.enums.contains(name) and
                        !self.ctx.decls.bitfields.contains(name) and
                        !builtins.isBuiltinType(name) and
                        !self.isIncludedType(name))
                    {
                        // Non-callable variable
                        try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "'{s}' is not callable — expected a function or constructor", .{name});
                        return t;
                    }
                }
                if (self.ctx.decls.funcs.get(name)) |sig| {
                    return sig.return_type;
                }
            }
            if (c.callee.* == .field_expr) {
                const fe = c.callee.field_expr;
                if (fe.object.* == .identifier) {
                    const obj_id = fe.object.identifier;
                    // Module-level function: module.func()
                    if (self.ctx.decls.funcs.get(fe.field)) |sig| {
                        return sig.return_type;
                    }
                    // Static or instance method on a struct.
                    // obj_id may be the struct type name (static: Renderer.create())
                    // or a variable whose type is a struct (instance: r.draw(m)).
                    const struct_name: []const u8 = blk: {
                        if (self.ctx.decls.structs.contains(obj_id)) break :blk obj_id;
                        if (scope.lookup(obj_id)) |var_type| {
                            // Unwrap error_union and null_union to get the underlying named type
                            if (var_type == .named) break :blk var_type.named;
                            if (var_type.coreInner()) |ci| {
                                if (ci.* == .named) break :blk ci.named;
                            }
                        }
                        break :blk "";
                    };
                    if (struct_name.len > 0) {
                        // Build "StructName.method" key and look in struct_methods
                        const key = std.fmt.allocPrint(self.ctx.allocator, "{s}.{s}", .{ struct_name, fe.field }) catch "";
                        defer if (key.len > 0) self.ctx.allocator.free(key);
                        if (key.len > 0) {
                            if (self.ctx.decls.struct_methods.get(key)) |sig| return sig.return_type;
                            // Cross-module: check all loaded module decls
                            if (self.ctx.all_decls) |ad| {
                                if (ad.get(obj_id)) |mod_decls| {
                                    if (mod_decls.struct_methods.get(key)) |sig| return sig.return_type;
                                }
                                var it = ad.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.*.struct_methods.get(key)) |sig| return sig.return_type;
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
                        const key = std.fmt.allocPrint(self.ctx.allocator, "{s}.{s}", .{ type_name, method_name }) catch "";
                        defer if (key.len > 0) self.ctx.allocator.free(key);
                        if (key.len > 0) {
                            if (self.ctx.decls.struct_methods.get(key)) |sig| return sig.return_type;
                            if (self.ctx.all_decls) |ad| {
                                var it = ad.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.*.struct_methods.get(key)) |sig| return sig.return_type;
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
                    if (builtins.isBuiltinType(name) or self.isIncludedType(name)) return RT{ .named = name };
                }
            }
            return callee_type;
        },

        .field_expr => |f| {
            const obj_type = try resolveExpr(self, f.object, scope);
            // .value on ErrorUnion(T) or NullUnion(T) unwraps to the inner type.
            // This lets the resolver track variables assigned via `var x = result.value`.
            if (std.mem.eql(u8, f.field, "value")) {
                if (obj_type.coreInner()) |ci| return ci.*;
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
            if (std.mem.eql(u8, cf.name, "size") or std.mem.eql(u8, cf.name, "align")) return RT{ .primitive = .usize };
            if (std.mem.eql(u8, cf.name, "typeid")) return RT{ .primitive = .usize };
            if (std.mem.eql(u8, cf.name, "typename")) return RT{ .primitive = .string };
            if (std.mem.eql(u8, cf.name, "typeOf")) return RT{ .primitive = .@"type" };
            if (std.mem.eql(u8, cf.name, "assert")) return RT{ .primitive = .void };
            if (std.mem.eql(u8, cf.name, "swap")) return RT{ .primitive = .void };
            // cast(T, x) → returns T (first arg is the target type)
            if (std.mem.eql(u8, cf.name, "cast")) {
                if (cf.args.len >= 1 and cf.args[0].* == .identifier) {
                    return RT{ .named = cf.args[0].identifier };
                }
                if (cf.args.len >= 1 and cf.args[0].* == .type_named) {
                    const tn = cf.args[0].type_named;
                    if (types.Primitive.fromName(tn)) |prim| return RT{ .primitive = prim };
                    return RT{ .named = tn };
                }
            }
            // copy(x), move(x) → returns same type as argument
            if (std.mem.eql(u8, cf.name, "copy") or std.mem.eql(u8, cf.name, "move")) {
                return first_arg_type;
            }
            // Introspection functions
            if (std.mem.eql(u8, cf.name, "hasField") or std.mem.eql(u8, cf.name, "hasDecl")) {
                if (cf.args.len != 2) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "@{s} takes exactly 2 arguments", .{cf.name});
                } else if (cf.args[1].* != .string_literal) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "@{s} requires a string literal as second argument", .{cf.name});
                }
                return RT{ .primitive = .bool };
            }
            if (std.mem.eql(u8, cf.name, "fieldType")) {
                if (cf.args.len != 2) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "@fieldType takes exactly 2 arguments", .{});
                } else if (cf.args[1].* != .string_literal) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "@fieldType requires a string literal as second argument", .{});
                }
                return RT{ .primitive = .@"type" };
            }
            if (std.mem.eql(u8, cf.name, "fieldNames")) {
                if (cf.args.len != 1) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "@fieldNames takes exactly 1 argument", .{});
                }
                return RT.inferred;
            }
            return RT.unknown;
        },

        .array_literal => |elems| {
            // Resolve element types; infer array type from first element
            var elem_type: RT = RT.inferred;
            for (elems) |elem| {
                const t = try resolveExpr(self, elem, scope);
                if (elem_type == .inferred) elem_type = t;
            }
            return elem_type;
        },

        .collection_expr => |c| {
            for (c.type_args) |arg| _ = try resolveExpr(self, arg, scope);
            if (c.alloc_arg) |a| _ = try resolveExpr(self, a, scope);
            return RT{ .named = c.kind };
        },

        .tuple_literal => |t| {
            for (t.fields) |f| _ = try resolveExpr(self, f, scope);
            return RT.inferred;
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
