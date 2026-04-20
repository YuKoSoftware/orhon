// resolver_validation.zig — Type validation and match exhaustiveness
// Satellite of resolver.zig — all functions take *TypeResolver as first parameter.

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const parser = @import("parser.zig");
const types = @import("types.zig");
const builtins = @import("builtins.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const cache = @import("cache.zig");

const TypeResolver = resolver_mod.TypeResolver;
const Scope = resolver_mod.Scope;
const RT = types.ResolvedType;

/// Check that a match on a union type covers all members
pub fn checkMatchExhaustiveness(self: *TypeResolver, match_type_raw: RT, arms: []*parser.Node, match_node: *parser.Node) !void {
    // Unwrap pointer/reference types — match(self) where self: const& T checks T
    const match_type: RT = if (match_type_raw == .ptr) match_type_raw.ptr.elem.* else match_type_raw;

    // Collect covered arm names
    var covered: std.ArrayListUnmanaged([]const u8) = .{};
    defer covered.deinit(self.ctx.allocator);
    for (arms) |arm| {
        if (arm.* == .match_arm) {
            const pat = arm.match_arm.pattern;
            if (pat.* == .identifier and !std.mem.eql(u8, pat.identifier, "else")) {
                try covered.append(self.ctx.allocator, pat.identifier);
            }
            if (pat.* == .null_literal) {
                try covered.append(self.ctx.allocator, "null");
            }
        }
    }

    const covered_slice = covered.items;

    switch (match_type) {
        .union_type => |members| {
            var missing: std.ArrayListUnmanaged([]const u8) = .{};
            defer missing.deinit(self.ctx.allocator);
            for (members) |member| {
                var found = false;
                for (covered_slice) |c| {
                    if (std.mem.eql(u8, c, member.name())) {
                        found = true;
                        break;
                    }
                }
                if (!found) try missing.append(self.ctx.allocator, member.name());
            }
            if (missing.items.len > 0) {
                try reportMissingArms(self, missing.items, match_node);
            }
        },
        .named => |name| {
            // Check enum exhaustiveness — look up variants in local or included DeclTables
            const enum_sig = self.ctx.decls.enums.get(name) orelse blk: {
                if (self.ctx.all_decls) |ad| {
                    for (self.included_modules.items) |mod_name| {
                        if (ad.get(mod_name)) |mod_decls| {
                            if (mod_decls.enums.get(name)) |sig| break :blk sig;
                        }
                    }
                }
                break :blk null;
            };
            if (enum_sig) |esig| {
                var missing: std.ArrayListUnmanaged([]const u8) = .{};
                defer missing.deinit(self.ctx.allocator);
                for (esig.variants) |variant| {
                    var found = false;
                    for (covered_slice) |c| {
                        if (std.mem.eql(u8, c, variant)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) try missing.append(self.ctx.allocator, variant);
                }
                if (missing.items.len > 0) {
                    try reportMissingArms(self, missing.items, match_node);
                }
            } else {
                // Named type is not a known enum — require else arm
                // (caller only calls us when !has_else)
                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(match_node),
                    "match on non-enum type requires an 'else' arm", .{});
            }
        },
        // Non-enum, non-union types (integers, strings, booleans, floats) —
        // caller only calls us when !has_else, so report directly
        else => {
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(match_node),
                "match on non-enum type requires an 'else' arm", .{});
        },
    }
}

fn reportMissingArms(self: *TypeResolver, missing: []const []const u8, match_node: *parser.Node) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(self.ctx.allocator);
    const w = buf.writer(self.ctx.allocator);
    try w.writeAll("non-exhaustive match — missing arm for ");
    for (missing, 0..) |name, idx| {
        if (idx > 0) try w.writeAll(", ");
        try w.print("'{s}'", .{name});
    }
    try w.writeAll(", add missing arms or use 'else'");
    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(match_node), "{s}", .{buf.items});
}

/// Validate that a match arm pattern is a valid member of the matched union type
pub fn validateMatchArm(self: *TypeResolver, pattern_name: []const u8, match_type: RT, arm_node: *parser.Node) !void {
    switch (match_type) {
        .union_type => |members| {
            // Valid arms: any member type name
            for (members) |member| {
                if (std.mem.eql(u8, pattern_name, member.name())) return;
            }
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(arm_node), "match arm '{s}' is not a member of this union type", .{pattern_name});
        },
        else => {
            // Not a union type — pattern matching on integer/string values, not type arms
            // These are validated by codegen, not here
        },
    }
}

pub fn validateType(self: *TypeResolver, node: *parser.Node, scope: *Scope) anyerror!void {
    switch (node.*) {
        .type_named => |type_name| {
            // Qualified names (module.Type) refer to imported module types.
            // The module import is validated by the module resolver; we trust the
            // qualified form here rather than trying to look up cross-module types.
            const is_qualified = std.mem.indexOfScalar(u8, type_name, '.') != null;
            const is_primitive = types.isPrimitiveName(type_name);
            const is_known = is_qualified or is_primitive or
                self.ctx.decls.structs.contains(type_name) or
                self.ctx.decls.enums.contains(type_name) or
                self.ctx.decls.types.contains(type_name) or // type aliases
                builtins.isBuiltinType(type_name) or
                self.isIncludedType(type_name) or
                types.Primitive.fromName(type_name) == .any or
                types.Primitive.fromName(type_name) == .void or
                types.Primitive.fromName(type_name) == .null_type or
                types.Primitive.fromName(type_name) == .@"type" or
                // @this is valid inside struct bodies — maps to @This() in codegen
                (types.Primitive.fromName(type_name) == .this and self.type_decl_depth > 0) or
                // Self is deprecated in favor of @this
                (types.Primitive.fromName(type_name) == .self_deprecated and self.type_decl_depth > 0) or
                scope.lookup(type_name) != null;

            // Deprecation warning: Self → @this
            if (is_known and types.Primitive.fromName(type_name) == .self_deprecated) {
                try self.ctx.reporter.warn(.{
                    .message = "'Self' is deprecated — use '@this' instead",
                    .loc = self.ctx.nodeLoc(node),
                });
            }

            if (!is_known) {
                // Auto-mapped zig module declarations may reference Zig-internal types
                // that don't exist in Orhon. Skip validation for these — the re-export
                // codegen passes them through to Zig which handles them natively.
                if (self.ctx.nodeLoc(node)) |loc| {
                    if (std.mem.startsWith(u8, loc.file, cache.ZIG_MODULES_DIR)) return;
                }

                // @this / Self outside struct gets a specific error message
                if (types.Primitive.fromName(type_name) == .this or types.Primitive.fromName(type_name) == .self_deprecated) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                        "'{s}' can only be used inside struct bodies — it refers to the enclosing struct type", .{type_name});
                    return;
                }
                // Build candidate list from declared types + primitives for suggestion
                var candidates: std.ArrayListUnmanaged([]const u8) = .{};
                defer candidates.deinit(self.ctx.allocator);
                var sti = self.ctx.decls.structs.keyIterator();
                while (sti.next()) |k| try candidates.append(self.ctx.allocator, k.*);
                var eni = self.ctx.decls.enums.keyIterator();
                while (eni.next()) |k| try candidates.append(self.ctx.allocator, k.*);
                var tyi = self.ctx.decls.types.keyIterator();
                while (tyi.next()) |k| try candidates.append(self.ctx.allocator, k.*);
                for (&resolver_mod.PRIMITIVE_NAMES) |pn| try candidates.append(self.ctx.allocator, pn);

                // Check if the type exists as a pub declaration in any other loaded module
                var cross_module_hint: ?[]const u8 = null;
                if (self.ctx.all_decls) |ad| {
                    var mod_it = ad.iterator();
                    while (mod_it.next()) |entry| {
                        const mod_name = entry.key_ptr.*;
                        const mod_decls = entry.value_ptr.*;
                        if (mod_decls == self.ctx.decls) continue;
                        const found = (if (mod_decls.structs.get(type_name)) |st| st.is_pub else false) or
                            (if (mod_decls.enums.get(type_name)) |e| e.is_pub else false) or
                            mod_decls.types.contains(type_name);
                        if (found) {
                            cross_module_hint = try std.fmt.allocPrint(self.ctx.allocator,
                                " \u{2014} '{s}' exists in module '{s}' (add 'use {s}')", .{ type_name, mod_name, mod_name });
                            break;
                        }
                    }
                }
                defer if (cross_module_hint) |h| self.ctx.allocator.free(h);

                const suggestion = try errors.formatSuggestion(type_name, candidates.items, self.ctx.allocator);
                defer if (suggestion) |s| self.ctx.allocator.free(s);

                const hint = cross_module_hint orelse suggestion orelse "";
                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "unknown type '{s}'{s}", .{ type_name, hint });
            }
        },
        .type_slice => |elem| try validateType(self, elem, scope),
        .type_array => |a| try validateType(self, a.elem, scope),
        .type_union => |u| {
            for (u) |t| try validateType(self, t, scope);
        },
        .type_generic => |g| {
            // Validate the base type name is known (builtin, compt func, or user-defined)
            const dot_pos = std.mem.indexOfScalar(u8, g.name, '.');
            const is_qualified = dot_pos != null;
            var is_known = builtins.isBuiltinType(g.name) or
                self.ctx.decls.funcs.contains(g.name) or
                self.ctx.decls.structs.contains(g.name) or
                self.isIncludedType(g.name) or
                scope.lookup(g.name) != null;

            // For qualified names (module.Type), validate against cross-module DeclTables
            if (is_qualified and !is_known) {
                if (dot_pos) |dp| {
                    const module_name = g.name[0..dp];
                    const type_name = g.name[dp + 1 ..];
                    if (self.ctx.all_decls) |ad| {
                        if (ad.get(module_name)) |mod_decls| {
                            is_known = mod_decls.structs.contains(type_name) or
                                mod_decls.enums.contains(type_name) or
                                mod_decls.funcs.contains(type_name) or
                                mod_decls.types.contains(type_name);
                        } else {
                            // Module not found in all_decls — may not yet be processed;
                            // trust qualified names in this case (Zig validates at compile time)
                            is_known = true;
                        }
                    } else {
                        // No cross-module info available — trust qualified names (fallback)
                        is_known = true;
                    }
                }
            } else if (is_qualified) {
                // Already known via local decls — nothing more to do
            }

            if (!is_known) {
                try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "unknown generic type '{s}'", .{g.name});
            }
            // Validate type arguments (Ring/ORing second arg is a size, Vector first arg is a size)
            const is_vector = types.Primitive.fromName(g.name) == .vector;
            for (g.args, 0..) |arg, idx| {
                if (is_vector and idx == 0) continue; // lane count, not a type
                try validateType(self, arg, scope);
            }
        },
        .type_ptr => |p| try validateType(self, p.elem, scope),
        .type_func => |f| {
            for (f.params) |p| try validateType(self, p, scope);
            try validateType(self, f.ret, scope);
        },
        .type_tuple_named => {
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "anonymous tuple types are not allowed — define a named type alias with 'const'", .{});
        },
        else => {},
    }
}

/// Check if a value type is compatible with an annotation type.
/// Only flags clear primitive-vs-primitive mismatches (e.g. i32 vs str).
/// Non-primitive types (arrays, structs, etc.) are left to Zig.
pub fn checkAssignCompat(self: *TypeResolver, expected: RT, actual: RT, node: *parser.Node) !void {
    if (actual == .unknown or actual == .inferred) return;
    if (expected == .unknown or expected == .inferred) return;
    // Block []u8 → str coercion
    if (expected == .primitive and expected.primitive == .string and
        actual == .slice and actual.slice.* == .primitive and actual.slice.primitive == .u8)
    {
        try self.ctx.reporter.report(.{
            .message = "cannot assign '[]u8' to 'str' — use string.fromBytes() for explicit conversion",
            .loc = self.ctx.nodeLoc(node),
        });
        return;
    }
    // Only check when both sides are primitive — that's where we can be confident
    if (expected != .primitive or actual != .primitive) return;
    if (resolver_mod.typesCompatible(actual, expected)) return;
    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "type mismatch: expected '{s}', got '{s}'",
        .{ expected.name(), actual.name() });
}

/// Check function call args for illegal []u8 → str coercion.
/// str is not []u8 — use string.fromBytes() for explicit conversion.
pub fn checkByteSliceStringCoercion(self: *TypeResolver, c: parser.CallExpr, arg_types: []const RT, node: *parser.Node) !void {
    // Look up the function signature
    const func_name: []const u8 = if (c.callee.* == .identifier)
        c.callee.identifier
    else if (c.callee.* == .field_expr)
        c.callee.field_expr.field
    else
        return;
    const sig = self.ctx.decls.funcs.get(func_name) orelse return;

    const param_count = @min(sig.params.len, arg_types.len);
    for (0..param_count) |i| {
        const param_type = sig.params[i].type_;
        const arg_type = arg_types[i];
        // Reject []u8 passed as str
        if (param_type == .primitive and param_type.primitive == .string) {
            if (arg_type == .slice) {
                if (arg_type.slice.* == .primitive and arg_type.slice.primitive == .u8) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "cannot pass '[]u8' as 'str' — use string.fromBytes() for explicit conversion",
                        .{});
                }
            }
        }
        // Reject str passed as []u8
        if (param_type == .slice) {
            if (param_type.slice.* == .primitive and param_type.slice.primitive == .u8) {
                if (arg_type == .primitive and arg_type.primitive == .string) {
                    try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node), "cannot pass 'str' as '[]u8' — use string.toBytes() for explicit conversion",
                        .{});
                }
            }
        }
    }
}

/// Check that a struct implements all methods required by its blueprints.
pub fn checkBlueprintConformance(self: *TypeResolver, s: parser.StructDecl, loc: ?errors.SourceLoc) anyerror!void {
    // Check for duplicate blueprint references
    for (s.blueprints, 0..) |bp_name, i| {
        for (s.blueprints[0..i]) |prev| {
            if (std.mem.eql(u8, bp_name, prev)) {
                try self.ctx.reporter.reportFmt(loc, "struct '{s}' lists blueprint '{s}' more than once", .{ s.name, bp_name });
            }
        }
    }

    for (s.blueprints) |bp_name| {
        // Look up blueprint in local or included module declarations
        const bp_sig = self.ctx.decls.blueprints.get(bp_name) orelse blk: {
            if (self.ctx.all_decls) |ad| {
                for (self.included_modules.items) |mod_name| {
                    if (ad.get(mod_name)) |mod_decls| {
                        if (mod_decls.blueprints.get(bp_name)) |sig| break :blk sig;
                    }
                }
            }
            try self.ctx.reporter.reportFmt(loc, "unknown blueprint '{s}'", .{bp_name});
            continue;
        };

        // Check each required method
        for (bp_sig.methods) |bp_method| {
            const struct_method = self.ctx.decls.getMethod(s.name, bp_method.name) orelse {
                try self.ctx.reporter.reportFmt(loc, "struct '{s}' does not implement '{s}' required by blueprint '{s}'",
                    .{ s.name, bp_method.name, bp_name });
                continue;
            };

            // Compare parameter count
            if (struct_method.params.len != bp_method.params.len) {
                try self.ctx.reporter.reportFmt(loc, "method '{s}' in struct '{s}' has {d} parameter(s), blueprint '{s}' requires {d}",
                    .{ bp_method.name, s.name, struct_method.params.len, bp_name, bp_method.params.len });
                continue;
            }

            // Compare parameter types (with blueprint→struct name substitution)
            for (struct_method.params, bp_method.params) |sp, bp| {
                if (!resolver_mod.typesMatchWithSubstitution(sp.type_, bp.type_, bp_name, s.name)) {
                    try self.ctx.reporter.reportFmt(loc, "method '{s}' in struct '{s}' does not match blueprint '{s}': parameter type mismatch",
                        .{ bp_method.name, s.name, bp_name });
                    break;
                }
            }

            // Compare return type
            if (!resolver_mod.typesMatchWithSubstitution(struct_method.return_type, bp_method.return_type, bp_name, s.name)) {
                try self.ctx.reporter.reportFmt(loc, "method '{s}' in struct '{s}' does not match blueprint '{s}': return type mismatch",
                    .{ bp_method.name, s.name, bp_name });
            }
        }
    }
}
