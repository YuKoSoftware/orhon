// codegen.zig — Zig Code Generation pass (pass 11)
// Translates MIR and AST to readable Zig source files.
// One .zig file per Orhon module. Uses std.fmt for output.

const std = @import("std");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const builtins = @import("builtins.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const module = @import("module.zig");
const RT = @import("types.zig").ResolvedType;

/// The Zig code generator
pub const CodeGen = struct {
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8),
    indent: usize,
    is_debug: bool,
    type_strings: std.ArrayListUnmanaged([]const u8), // allocated type strings to free
    decls: ?*declarations.DeclTable,
    in_test_block: bool, // inside a test { } block — assert uses std.testing.expect
    destruct_counter: usize, // unique index for destructuring temp vars
    warned_rawptr: bool,     // RawPtr/VolatilePtr warning printed once per module
    module_name: []const u8, // current module name — used for bridge re-exports
    reassigned_vars: std.StringHashMapUnmanaged(void), // vars assigned after declaration in current func
    type_ctx: ?*parser.Node, // expected type from enclosing decl (for overflow codegen)
    locs: ?*const parser.LocMap, // AST node → source location (set by main.zig)
    generic_struct_name: ?[]const u8, // inside a generic struct — name to replace with @This()
    all_decls: ?*std.StringHashMap(*declarations.DeclTable), // all module decl tables for cross-module default args
    source_file: []const u8,     // anchor file path for location reporting
    module_builds: ?*const std.StringHashMapUnmanaged(module.BuildType), // imported module → build type
    type_narrowed_vars: std.StringHashMapUnmanaged([]const u8), // var name → narrowed type (from `is` checks)
    // MIR annotation table — Phase 1+2 typed annotation pass
    node_map: ?*const mir.NodeMap = null,
    union_registry: ?*const mir.UnionRegistry = null,
    var_types: ?*const std.StringHashMapUnmanaged(mir.NodeInfo) = null,
    current_func_node: ?*parser.Node = null,
    // MIR tree — Phase 3 lowered tree (available for incremental migration)
    mir_root: ?*mir.MirNode = null,
    // MIR node for the current function — replaces current_func_node progressively
    current_func_mir: ?*mir.MirNode = null,

    /// Query MIR annotation for an AST node.
    pub fn getNodeInfo(self: *const CodeGen, node: *parser.Node) ?mir.NodeInfo {
        if (self.node_map) |nm| return nm.get(node);
        return null;
    }

    /// Get the TypeClass for an AST node from MIR annotations.
    pub fn getTypeClass(self: *const CodeGen, node: *parser.Node) mir.TypeClass {
        if (self.getNodeInfo(node)) |info| return info.type_class;
        return .plain;
    }

    /// Get the union member types for an arb union node from MIR annotations.
    /// Returns null if the node is not an arb union or not in the node_map.
    fn getUnionMembers(self: *const CodeGen, node: *parser.Node) ?[]const RT {
        if (self.getNodeInfo(node)) |info| {
            if (info.resolved_type == .union_type) return info.resolved_type.union_type;
        }
        return null;
    }

    /// Get the TypeClass of the current function's return type from MIR.
    fn funcReturnTypeClass(self: *const CodeGen) mir.TypeClass {
        if (self.current_func_mir) |m| return m.type_class;
        if (self.current_func_node) |fn_node| {
            if (self.getNodeInfo(fn_node)) |info| return info.type_class;
        }
        return .plain;
    }

    /// Get the union members of the current function's return type from MIR.
    fn funcReturnMembers(self: *const CodeGen) ?[]const RT {
        if (self.current_func_mir) |m| {
            if (m.resolved_type == .union_type) return m.resolved_type.union_type;
        }
        if (self.current_func_node) |fn_node| {
            if (self.getNodeInfo(fn_node)) |info| {
                if (info.resolved_type == .union_type) return info.resolved_type.union_type;
            }
        }
        return null;
    }

    /// Name-based union member lookup via MIR var_types (fallback).
    fn getVarUnionMembers(self: *const CodeGen, name: []const u8) ?[]const RT {
        if (self.var_types) |vt| {
            if (vt.get(name)) |info| {
                if (info.resolved_type == .union_type) return info.resolved_type.union_type;
            }
        }
        return null;
    }

    /// If a node is typed as a bitfield, return the bitfield name. Uses MIR + decls.
    fn getBitfieldName(self: *const CodeGen, node: *parser.Node) ?[]const u8 {
        const d = self.decls orelse return null;
        if (self.getNodeInfo(node)) |info| {
            if (info.resolved_type == .named) {
                if (d.bitfields.contains(info.resolved_type.named)) return info.resolved_type.named;
            }
        }
        return null;
    }

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter, is_debug: bool) CodeGen {
        return .{
            .reporter = reporter,
            .allocator = allocator,
            .output = .{},
            .indent = 0,
            .is_debug = is_debug,
            .type_strings = .{},
            .decls = null,
            .in_test_block = false,
            .destruct_counter = 0,
            .warned_rawptr = false,
            .module_name = "",
            .reassigned_vars = .{},
            .type_ctx = null,
            .generic_struct_name = null,
            .all_decls = null,
            .locs = null,
            .source_file = "",
            .module_builds = null,
            .type_narrowed_vars = .{},
        };
    }

    fn nodeLoc(self: *const CodeGen, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    /// Check if a name is an enum variant in any declared enum
    fn isEnumVariant(self: *const CodeGen, name: []const u8) bool {
        const decls = self.decls orelse return false;
        var it = decls.enums.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.variants) |v| {
                if (std.mem.eql(u8, v, name)) return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *CodeGen) void {
        for (self.type_strings.items) |s| self.allocator.free(s);
        self.type_strings.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.reassigned_vars.deinit(self.allocator);
        self.type_narrowed_vars.deinit(self.allocator);
    }

    /// Get the generated Zig source
    pub fn getOutput(self: *CodeGen) []const u8 {
        return self.output.items;
    }

    fn emit(self: *CodeGen, s: []const u8) !void {
        try self.output.appendSlice(self.allocator, s);
    }

    fn emitFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.output.appendSlice(self.allocator, s);
    }

    fn emitIndent(self: *CodeGen) !void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) {
            try self.emit("    ");
        }
    }

    fn emitLine(self: *CodeGen, s: []const u8) !void {
        try self.emitIndent();
        try self.emit(s);
        try self.emit("\n");
    }

    fn emitLineFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.emitIndent();
        try self.emitFmt(fmt, args);
        try self.emit("\n");
    }

    /// Generate Zig source from a program AST
    pub fn generate(self: *CodeGen, ast: *parser.Node, module_name: []const u8) !void {
        if (ast.* != .program) return;
        self.module_name = module_name;

        // File header
        try self.emitFmt("// generated from module {s} — do not edit\n", .{module_name});
        try self.emit("const std = @import(\"std\");\n");
        try self.emit("const _rt = @import(\"_orhon_rt\");\n");
        try self.emit("const _str = @import(\"_orhon_str\");\n");
        try self.emit("const _collections = @import(\"_orhon_collections\");\n");

        // Generate imports (always from AST — MirNode tree doesn't carry imports separately)
        for (ast.program.imports) |imp| {
            try self.generateImport(imp);
        }

        try self.emit("\n");

        // Generate top-level declarations — prefer MIR tree when available
        if (self.mir_root) |root| {
            for (root.children) |m| {
                try self.generateTopLevelMir(m);
                try self.emit("\n");
            }
        } else {
            for (ast.program.top_level) |node| {
                try self.generateTopLevel(node);
                try self.emit("\n");
            }
        }
    }

    /// Extract the value type from a (Error | T) or (null | T) union type annotation.
    /// Returns null if not a recognized union or no non-Error/non-null type found.
    fn extractValueType(node: *parser.Node) ?*parser.Node {
        if (node.* != .type_union) return null;
        for (node.type_union) |t| {
            if (t.* == .type_named and
                (std.mem.eql(u8, t.type_named, K.Type.ERROR) or std.mem.eql(u8, t.type_named, K.Type.NULL)))
                continue;
            return t;
        }
        return null;
    }

    /// Generate a Zig union tag name from an Orhon type name: i32 → _i32
    fn unionTagName(self: *CodeGen, orhon_name: []const u8) ![]const u8 {
        return try self.allocTypeStr("_{s}", .{orhon_name});
    }

    /// Check if a variable name is a tracked error union variable


    /// Check if an expression is known to be a string (literal, interpolation, or MIR-typed)
    fn isStringExpr(self: *const CodeGen, node: *parser.Node) bool {
        return switch (node.*) {
            .string_literal, .interpolated_string => true,
            else => self.getTypeClass(node) == .string,
        };
    }

    /// Info about an `x is T` / `x is not T` condition
    const IsCheckInfo = struct {
        var_name: []const u8,
        var_node: *parser.Node,
        type_name: []const u8,
        is_positive: bool, // true for `is`, false for `is not`
    };

    /// Extract `is` check info from an if-condition.
    /// Returns info if the condition is `x is T` or `x is not T` on an arb union var.
    fn extractIsCheck(self: *const CodeGen, cond: *parser.Node) ?IsCheckInfo {
        if (cond.* != .binary_expr) return null;
        const b = cond.binary_expr;
        const is_eq = std.mem.eql(u8, b.op, "==");
        const is_ne = std.mem.eql(u8, b.op, "!=");
        if (!is_eq and !is_ne) return null;
        if (b.left.* != .compiler_func) return null;
        if (!std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE)) return null;
        if (b.left.compiler_func.args.len == 0) return null;
        const val_node = b.left.compiler_func.args[0];
        if (val_node.* != .identifier) return null;
        if (self.getTypeClass(val_node) != .arbitrary_union) return null;
        if (b.right.* != .identifier) return null;
        const rhs = b.right.identifier;
        if (std.mem.eql(u8, rhs, K.Type.ERROR) or std.mem.eql(u8, rhs, K.Type.NULL)) return null;
        return .{
            .var_name = val_node.identifier,
            .var_node = val_node,
            .type_name = rhs,
            .is_positive = is_eq,
        };
    }

    /// Compute the remaining type after narrowing one type out of an arbitrary union.
    /// Returns the single remaining type name, or null if multiple types remain.
    /// Works with both AST type nodes and MIR resolved types.
    /// Given union members and an excluded type, find the single remaining non-special member.
    fn remainingUnionType(members_rt: ?[]const RT, excluded: []const u8) ?[]const u8 {
        const members = members_rt orelse return null;
        var remaining: ?[]const u8 = null;
        for (members) |m| {
            const n = m.name();
            if (std.mem.eql(u8, n, excluded)) continue;
            if (std.mem.eql(u8, n, K.Type.ERROR) or std.mem.eql(u8, n, K.Type.NULL)) continue;
            if (remaining != null) return null;
            remaining = n;
        }
        return remaining;
    }


    /// Check if a block has an early exit (return, break, continue).
    fn blockHasEarlyExit(node: *parser.Node) bool {
        if (node.* != .block) return false;
        for (node.block.statements) |stmt| {
            switch (stmt.*) {
                .return_stmt => return true,
                .break_stmt => return true,
                .continue_stmt => return true,
                else => {},
            }
        }
        return false;
    }


    /// Generate a value expression, wrapping it for null union context if needed.
    /// Uses MIR coercion annotations when available, falls back to heuristic.
    fn generateNullWrappedExpr(self: *CodeGen, value: *parser.Node) anyerror!void {
        if (value.* == .null_literal) {
            try self.emit(".{ .none = {} }");
            return;
        }
        // If MIR explicitly says wrap, wrap
        if (self.getNodeInfo(value)) |info| {
            if (info.coercion != null and info.coercion.? == .null_wrap) {
                try self.emit(".{ .some = ");
                try self.generateExpr(value);
                try self.emit(" }");
                return;
            }
        }
        // Heuristic: function calls and values already typed as null union pass through
        if (self.exprReturnsNullUnion(value)) {
            try self.generateExpr(value);
        } else {
            try self.emit(".{ .some = ");
            try self.generateExpr(value);
            try self.emit(" }");
        }
    }

    /// Generate an expression with MIR coercion applied if annotated.
    /// Used for call arguments where the target type comes from the function signature.
    fn generateCoercedExpr(self: *CodeGen, value: *parser.Node) anyerror!void {
        const info = self.getNodeInfo(value) orelse return self.generateExpr(value);
        const coercion = info.coercion orelse return self.generateExpr(value);
        switch (coercion) {
            .array_to_slice => {
                try self.emit("&");
                try self.generateExpr(value);
            },
            .null_wrap => {
                if (value.* == .null_literal) {
                    try self.emit(".{ .none = {} }");
                } else {
                    try self.emit(".{ .some = ");
                    try self.generateExpr(value);
                    try self.emit(" }");
                }
            },
            .error_wrap => {
                try self.emit(".{ .ok = ");
                try self.generateExpr(value);
                try self.emit(" }");
            },
            .arbitrary_union_wrap => {
                if (info.coerce_tag) |tag| {
                    try self.emitFmt(".{{ ._{s} = ", .{tag});
                    try self.generateExpr(value);
                    try self.emit(" }");
                } else {
                    try self.generateExpr(value);
                }
            },
            .optional_unwrap => {
                try self.generateExpr(value);
                try self.emit(".some");
            },
        }
    }

    /// Wrap a value for an arbitrary union: 42 → .{ ._i32 = 42 }
    fn generateArbitraryUnionWrappedExpr(self: *CodeGen, value: *parser.Node, members_rt: ?[]const RT) anyerror!void {
        const tag = inferArbitraryUnionTag(value, members_rt);
        if (tag) |t| {
            try self.emitFmt(".{{ ._{s} = ", .{t});
            try self.generateExpr(value);
            try self.emit(" }");
        } else {
            try self.generateExpr(value);
        }
    }

    /// Infer which union tag a value belongs to based on its literal type.
    fn inferArbitraryUnionTag(value: *parser.Node, members_rt: ?[]const RT) ?[]const u8 {
        return switch (value.*) {
            .int_literal => findMemberByKind(members_rt, .int) orelse "i32",
            .float_literal => findMemberByKind(members_rt, .float) orelse "f32",
            .string_literal => findMemberByKind(members_rt, .string) orelse "String",
            .bool_literal => findMemberByKind(members_rt, .bool_) orelse "bool",
            else => null,
        };
    }

    const TypeKind = enum { int, float, string, bool_ };

    fn matchesKind(n: []const u8, kind: TypeKind) bool {
        return switch (kind) {
            .int => std.mem.eql(u8, n, "i8") or std.mem.eql(u8, n, "i16") or
                std.mem.eql(u8, n, "i32") or std.mem.eql(u8, n, "i64") or
                std.mem.eql(u8, n, "u8") or std.mem.eql(u8, n, "u16") or
                std.mem.eql(u8, n, "u32") or std.mem.eql(u8, n, "u64") or
                std.mem.eql(u8, n, "usize"),
            .float => std.mem.eql(u8, n, "f32") or std.mem.eql(u8, n, "f64"),
            .string => std.mem.eql(u8, n, "String"),
            .bool_ => std.mem.eql(u8, n, "bool"),
        };
    }

    /// Search union members (MIR resolved types) for a type matching the given kind.
    fn findMemberByKind(members_rt: ?[]const RT, kind: TypeKind) ?[]const u8 {
        const members = members_rt orelse return null;
        for (members) |m| {
            const n = m.name();
            if (matchesKind(n, kind)) return n;
        }
        return null;
    }

    /// Check if an expression already produces a null union value.
    /// Function calls (positional args) to a function typed as returning a union
    /// already return OrhonNullable — don't double-wrap.
    fn exprReturnsNullUnion(self: *const CodeGen, node: *parser.Node) bool {
        return switch (node.*) {
            // Positional function calls returning a null union already produce OrhonNullable
            .call_expr => |c| c.arg_names.len == 0,
            // A variable typed as null union via MIR
            else => self.getTypeClass(node) == .null_union,
        };
    }

    /// Check if an identifier is a declared Error constant
    fn isErrorConstant(self: *const CodeGen, name: []const u8) bool {
        if (self.decls) |decls| {
            if (decls.vars.get(name)) |v| {
                if (v.type_) |t| {
                    return t == .err;
                }
            }
        }
        return false;
    }

    fn generateImport(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .import_decl) return;
        const imp = node.import_decl;

        // Alias defaults to the module name (last segment of path)
        const alias = imp.alias orelse imp.path;

        if (imp.is_c_header) {
            try self.emitLineFmt("// WARNING: C header import\nconst {s} = @cImport(@cInclude({s}));", .{ alias, imp.path });
        } else {
            // Check if the imported module is a lib target — if so, use build-system
            // module name (no .zig extension) since it's provided via addImport in build.zig
            const is_lib = if (self.module_builds) |mb| blk: {
                const bt = mb.get(imp.path) orelse break :blk false;
                break :blk bt == .static or bt == .dynamic;
            } else false;

            if (is_lib) {
                try self.emitLineFmt("const {s} = @import(\"{s}\");", .{ alias, imp.path });
            } else {
                try self.emitLineFmt("const {s} = @import(\"{s}.zig\");", .{ alias, imp.path });
            }
        }
    }

    fn generateTopLevel(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.generateFunc(node, f),
            .struct_decl => |s| try self.generateStruct(s),
            .enum_decl => |e| try self.generateEnum(e),
            .bitfield_decl => |b| try self.generateBitfield(b),
            .const_decl => |v| try self.generateConst(node, v),
            .var_decl => |v| try self.generateVar(node, v),
            .compt_decl => |v| try self.generateCompt(v),
            .test_decl => |t| try self.generateTest(t),
            else => {},
        }
    }

    /// MIR-path top-level dispatch — switches on MirKind, delegates to AST-based generators.
    /// During migration, sets current_func_mir for type queries, then calls existing generators.
    fn generateTopLevelMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .func => {
                const prev = self.current_func_mir;
                self.current_func_mir = m;
                defer self.current_func_mir = prev;
                try self.generateFunc(m.ast, m.ast.func_decl);
            },
            .struct_def => try self.generateStruct(m.ast.struct_decl),
            .enum_def => try self.generateEnum(m.ast.enum_decl),
            .bitfield_def => try self.generateBitfield(m.ast.bitfield_decl),
            .var_decl => {
                // var_decl MirKind covers var_decl, const_decl, compt_decl
                switch (m.ast.*) {
                    .const_decl => |v| try self.generateConst(m.ast, v),
                    .var_decl => |v| try self.generateVar(m.ast, v),
                    .compt_decl => |v| try self.generateCompt(v),
                    else => {},
                }
            },
            .test_def => try self.generateTest(m.ast.test_decl),
            .import => {}, // imports handled separately in generate()
            else => {},
        }
    }

    // ============================================================
    // FUNCTIONS
    // ============================================================

    /// Walk a node tree and collect all variable names that appear as the
    /// LHS of an assignment (simple, compound, field, or index). Stops at
    /// nested func_decl boundaries so inner functions don't pollute the outer set.
    fn collectAssigned(node: *parser.Node, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void {
        switch (node.*) {
            .assignment => |a| {
                if (getRootIdent(a.left)) |name| try set.put(alloc, name, {});
                try collectAssigned(a.right, set, alloc);
            },
            .call_expr => |c| {
                // Method call on a receiver: foo.method(args) — treat the receiver as
                // potentially mutated so we don't promote it to const incorrectly.
                if (c.callee.* == .field_expr) {
                    if (getRootIdent(c.callee.field_expr.object)) |name| {
                        try set.put(alloc, name, {});
                    }
                }
                for (c.args) |arg| try collectAssigned(arg, set, alloc);
            },
            .block => |b| {
                for (b.statements) |s| try collectAssigned(s, set, alloc);
            },
            .func_decl => {}, // nested function — own scope, don't descend
            .if_stmt => |i| {
                try collectAssigned(i.condition, set, alloc);
                try collectAssigned(i.then_block, set, alloc);
                if (i.else_block) |e| try collectAssigned(e, set, alloc);
            },
            .while_stmt => |w| {
                try collectAssigned(w.condition, set, alloc);
                if (w.continue_expr) |c| try collectAssigned(c, set, alloc);
                try collectAssigned(w.body, set, alloc);
            },
            .for_stmt => |f| try collectAssigned(f.body, set, alloc),
            .slice_expr => |s| {
                // Slice base must stay `var` so the slice type is []T not *const [N]T
                if (s.object.* == .identifier)
                    try set.put(alloc, s.object.identifier, {});
                try collectAssigned(s.low, set, alloc);
                try collectAssigned(s.high, set, alloc);
            },
            .var_decl => |v| try collectAssigned(v.value, set, alloc),
            .const_decl => |v| try collectAssigned(v.value, set, alloc),
            .match_stmt => |m| {
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) try collectAssigned(arm.match_arm.body, set, alloc);
                }
            },
            .defer_stmt => |d| try collectAssigned(d.body, set, alloc),
            else => {},
        }
    }

    fn getRootIdent(node: *parser.Node) ?[]const u8 {
        return switch (node.*) {
            .identifier => |name| name,
            .field_expr => |f| getRootIdent(f.object),
            .index_expr => |i| getRootIdent(i.object),
            else => null,
        };
    }

    /// Emit a re-export for an bridge declaration from the paired sidecar .zig file.
    fn generateBridgeReExport(self: *CodeGen, name: []const u8) anyerror!void {
        try self.emitLineFmt("pub const {s} = @import(\"{s}_bridge.zig\").{s};", .{ name, self.module_name, name });
    }

    fn generateFunc(self: *CodeGen, node: *parser.Node, f: parser.FuncDecl) anyerror!void {
        // Thread function — generate body + spawn wrapper
        if (f.is_thread) return self.generateThreadFunc(node, f);

        // bridge func — re-export from paired sidecar file
        if (f.is_bridge) return self.generateBridgeReExport(f.name);

        // Body-less declaration (interface file import) — skip codegen.
        // Never skip main (it can legitimately have an empty body).
        if (f.body.* == .block and f.body.block.statements.len == 0 and
            !f.is_bridge and !std.mem.eql(u8, f.name, "main")) return;

        // Track current function for MIR return type queries
        const prev_func_node = self.current_func_node;
        self.current_func_node = node;
        // Clear per-function tracking maps — each function has its own scope
        const prev_reassigned_vars = self.reassigned_vars;
        const prev_type_narrowed_vars = self.type_narrowed_vars;
        self.reassigned_vars = .{};
        self.type_narrowed_vars = .{};
        try collectAssigned(f.body, &self.reassigned_vars, self.allocator);
        defer {
            self.current_func_node = prev_func_node;
            self.reassigned_vars.deinit(self.allocator);
            self.reassigned_vars = prev_reassigned_vars;
            self.type_narrowed_vars.deinit(self.allocator);
            self.type_narrowed_vars = prev_type_narrowed_vars;
        }

        // pub modifier — always pub for main (Zig requires pub fn main for exe entry)
        if (f.is_pub or std.mem.eql(u8, f.name, "main")) try self.emit("pub ");

        // compt func + `type` return → generic type fn with `comptime T: type` params
        // compt func + other return  → inline fn with `anytype` params
        // regular func               → fn (anytype params handled in loop below)
        const returns_type = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, K.Type.TYPE);
        const is_type_generic = f.is_compt and returns_type;

        if (f.is_compt and !is_type_generic) {
            try self.emitFmt("inline fn {s}(", .{f.name});
        } else {
            try self.emitFmt("fn {s}(", .{f.name});
        }

        // Parameters — track first `any` param name for return type inference
        var first_any_param: ?[]const u8 = null;
        for (f.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            if (param.* == .param) {
                const is_any = param.param.type_annotation.* == .type_named and
                    std.mem.eql(u8, param.param.type_annotation.type_named, K.Type.ANY);
                const is_type_param = param.param.type_annotation.* == .type_named and
                    std.mem.eql(u8, param.param.type_annotation.type_named, K.Type.TYPE);
                if (is_any and first_any_param == null) first_any_param = param.param.name;
                if (is_type_param) {
                    // `T: type` → `comptime T: type`
                    try self.emitFmt("comptime {s}: type", .{param.param.name});
                } else if (is_type_generic and is_any) {
                    // `compt func F(T: any) type` → `fn F(comptime T: type)`
                    try self.emitFmt("comptime {s}: type", .{param.param.name});
                } else if (is_any) {
                    // generic value param → anytype
                    try self.emitFmt("{s}: anytype", .{param.param.name});
                } else {
                    try self.emitFmt("{s}: {s}", .{
                        param.param.name,
                        try self.typeToZig(param.param.type_annotation),
                    });
                    // Default params handled at call site, not in Zig signature
                }
            }
        }

        try self.emit(") ");

        // Return type — `any` return becomes @TypeOf(first_any_param)
        const return_is_any = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, K.Type.ANY);
        if (return_is_any) {
            if (first_any_param) |pname| {
                try self.emitFmt("@TypeOf({s})", .{pname});
            } else {
                try self.emit("anyopaque"); // fallback: no any param found
            }
        } else {
            try self.emit(try self.typeToZig(f.return_type));
        }
        try self.emit(" ");

        // Body — use MIR block path when available
        if (self.current_func_mir) |func_mir| {
            try self.generateBlockMir(func_mir.body());
        } else {
            try self.generateBlock(f.body);
        }
        try self.emit("\n");
    }

    /// Generate a thread function: body function + spawn wrapper.
    /// `thread worker(n: i32) Handle(i32) { return n * 2 }` generates:
    ///   fn _worker_body(n: i32) i32 { return (n * 2); }
    ///   fn worker(n: i32) _rt.OrhonHandle(i32) { ... spawn ... }
    fn generateThreadFunc(self: *CodeGen, node: *parser.Node, f: parser.FuncDecl) anyerror!void {
        // Extract inner type T from Handle(T) return type
        const inner_type = if (f.return_type.* == .type_generic and
            std.mem.eql(u8, f.return_type.type_generic.name, "Handle") and
            f.return_type.type_generic.args.len > 0)
            f.return_type.type_generic.args[0]
        else
            f.return_type;

        const inner_zig = try self.typeToZig(inner_type);
        const handle_zig = try self.typeToZig(f.return_type);

        // ── Body function: fn _name_body(params) T { ... } ──
        {
            const prev_func_node = self.current_func_node;
            self.current_func_node = node;
            const prev_assigned = self.reassigned_vars;
            const prev_narrowed = self.type_narrowed_vars;
            self.reassigned_vars = .{};
            self.type_narrowed_vars = .{};
            try collectAssigned(f.body, &self.reassigned_vars, self.allocator);
            defer {
                self.current_func_node = prev_func_node;
                self.reassigned_vars.deinit(self.allocator);
                self.reassigned_vars = prev_assigned;
                self.type_narrowed_vars.deinit(self.allocator);
                self.type_narrowed_vars = prev_narrowed;
            }

            try self.emitFmt("fn _{s}_body(", .{f.name});
            for (f.params, 0..) |param, i| {
                if (i > 0) try self.emit(", ");
                if (param.* == .param) {
                    try self.emitFmt("{s}: {s}", .{
                        param.param.name,
                        try self.typeToZig(param.param.type_annotation),
                    });
                }
            }
            try self.emitFmt(") {s} ", .{inner_zig});
            try self.generateBlock(f.body);
            try self.emit("\n\n");
        }

        // ── Spawn wrapper: fn name(params) _rt.OrhonHandle(T) { ... } ──
        if (f.is_pub) try self.emit("pub ");
        try self.emitFmt("fn {s}(", .{f.name});
        for (f.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            if (param.* == .param) {
                try self.emitFmt("{s}: {s}", .{
                    param.param.name,
                    try self.typeToZig(param.param.type_annotation),
                });
            }
        }
        try self.emitFmt(") {s} ", .{handle_zig});
        try self.emit("{\n");
        self.indent += 1;

        // Allocate shared state
        try self.emitIndent();
        try self.emitFmt("const _state = _rt.alloc.create({s}.SharedState) catch unreachable;\n", .{handle_zig});
        try self.emitIndent();
        try self.emit("_state.* = .{};\n");

        // Spawn thread with body function
        try self.emitIndent();
        try self.emitFmt("return .{{ .thread = std.Thread.spawn(.{{}}, struct {{ fn run(_s: *{s}.SharedState", .{handle_zig});
        for (f.params) |param| {
            if (param.* == .param) {
                try self.emitFmt(", _{s}: {s}", .{
                    param.param.name,
                    try self.typeToZig(param.param.type_annotation),
                });
            }
        }
        try self.emit(") void { ");

        // Call body function with unwrapped params
        const is_void = std.mem.eql(u8, inner_zig, "void");
        if (!is_void) try self.emit("_s.result = ");
        try self.emitFmt("_{s}_body(", .{f.name});
        for (f.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            if (param.* == .param) {
                try self.emitFmt("_{s}", .{param.param.name});
            }
        }
        try self.emit("); _s.completed.store(true, .release); } }.run, .{ _state");
        for (f.params) |param| {
            if (param.* == .param) {
                try self.emitFmt(", {s}", .{param.param.name});
            }
        }
        try self.emit(" }) catch unreachable, .state = _state };\n");

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}\n");
    }

    // ============================================================
    // STRUCTS
    // ============================================================

    fn generateStruct(self: *CodeGen, s: parser.StructDecl) anyerror!void {
        if (s.is_bridge) return self.generateBridgeReExport(s.name);

        const is_generic = s.type_params.len > 0;

        if (is_generic) {
            // Generic struct: fn Name(comptime T: type) type { return struct { ... }; }
            if (s.is_pub) try self.emit("pub ");
            try self.emitFmt("fn {s}(", .{s.name});
            for (s.type_params, 0..) |param, i| {
                if (i > 0) try self.emit(", ");
                if (param.* == .param) {
                    try self.emitFmt("comptime {s}: type", .{param.param.name});
                }
            }
            try self.emit(") type {\n");
            self.indent += 1;
            try self.emitIndent();
            try self.emit("return struct {\n");
            self.indent += 1;
            self.generic_struct_name = s.name;
        } else {
            if (s.is_pub) try self.emit("pub ");
            try self.emitFmt("const {s} = struct {{\n", .{s.name});
            self.indent += 1;
        }

        for (s.members) |member| {
            switch (member.*) {
                .field_decl => |f| {
                    try self.emitIndent();
                    try self.emitFmt("{s}: {s}", .{ f.name, try self.typeToZig(f.type_annotation) });
                    if (f.default_value) |dv| {
                        try self.emit(" = ");
                        try self.generateExpr(dv);
                    }
                    try self.emit(",\n");
                },
                .func_decl => |f| try self.generateFunc(member, f),
                .var_decl => |v| {
                    try self.emitIndent();
                    try self.emitFmt("var {s}", .{v.name});
                    if (v.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
                    try self.emit(" = ");
                    try self.generateExpr(v.value);
                    try self.emit(";\n");
                },
                .const_decl => |v| {
                    try self.emitIndent();
                    try self.emitFmt("const {s}", .{v.name});
                    if (v.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
                    try self.emit(" = ");
                    try self.generateExpr(v.value);
                    try self.emit(";\n");
                },
                else => {},
            }
        }

        if (is_generic) {
            self.generic_struct_name = null;
            self.indent -= 1;
            try self.emitIndent();
            try self.emit("};\n");
            self.indent -= 1;
            try self.emit("}\n");
        } else {
            self.indent -= 1;
            try self.emit("};\n");
        }
    }

    // ============================================================
    // ENUMS
    // ============================================================

    fn generateEnum(self: *CodeGen, e: parser.EnumDecl) anyerror!void {
        if (e.is_pub) try self.emit("pub ");

        const backing = try self.typeToZig(e.backing_type);

        // Regular enum
        try self.emitFmt("const {s} = enum({s}) {{\n", .{ e.name, backing });
        self.indent += 1;

        for (e.members) |member| {
            switch (member.*) {
                .enum_variant => |v| {
                    try self.emitIndent();
                    if (v.fields.len > 0) {
                        // Data-carrying variant — generate as tagged union
                        try self.emitFmt("{s},\n", .{v.name});
                    } else {
                        try self.emitFmt("{s},\n", .{v.name});
                    }
                },
                .func_decl => |f| try self.generateFunc(member, f),
                else => {},
            }
        }

        self.indent -= 1;
        try self.emit("};\n");
    }

    fn generateBitfield(self: *CodeGen, b: parser.BitfieldDecl) anyerror!void {
        if (b.is_pub) try self.emit("pub ");
        const backing = try self.typeToZig(b.backing_type);

        try self.emitFmt("const {s} = struct {{\n", .{b.name});
        self.indent += 1;

        // Named flag constants — powers of 2
        for (b.members, 0..) |flag_name, i| {
            try self.emitIndent();
            try self.emitFmt("pub const {s}: {s} = {d};\n", .{ flag_name, backing, @as(u64, 1) << @intCast(i) });
        }

        // value field
        try self.emitIndent();
        try self.emitFmt("value: {s} = 0,\n", .{backing});

        // methods
        try self.emitIndent();
        try self.emitFmt("pub fn has(self: {s}, flag: {s}) bool {{ return (self.value & flag) != 0; }}\n", .{ b.name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn set(self: *{s}, flag: {s}) void {{ self.value |= flag; }}\n", .{ b.name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn clear(self: *{s}, flag: {s}) void {{ self.value &= ~flag; }}\n", .{ b.name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn toggle(self: *{s}, flag: {s}) void {{ self.value ^= flag; }}\n", .{ b.name, backing });

        self.indent -= 1;
        try self.emit("};\n");
    }


    // ============================================================
    // VARIABLE DECLARATIONS
    // ============================================================

    fn generateConst(self: *CodeGen, node: *parser.Node, v: parser.VarDecl) anyerror!void {
        if (v.is_bridge) return self.generateBridgeReExport(v.name);
        return self.generateDecl(node, v, "const");
    }

    fn generateVar(self: *CodeGen, node: *parser.Node, v: parser.VarDecl) anyerror!void {
        if (v.is_bridge) return self.generateBridgeReExport(v.name);
        return self.generateDecl(node, v, "var");
    }

    /// Shared codegen for var and const declarations
    fn generateDecl(self: *CodeGen, node: *parser.Node, v: parser.VarDecl, decl_keyword: []const u8) anyerror!void {
        if (v.is_pub) try self.emit("pub ");
        try self.emitFmt("{s} {s}", .{ decl_keyword, v.name });
        const tc = self.getTypeClass(node);
        if (v.type_annotation) |t| {
            try self.emitFmt(": {s}", .{try self.typeToZig(t)});
        }
        try self.emit(" = ");
        if (tc == .error_union) {
            try self.generateExpr(v.value);
        } else if (tc == .null_union) {
            try self.generateNullWrappedExpr(v.value);
        } else if (tc == .arbitrary_union) {
            try self.generateArbitraryUnionWrappedExpr(v.value, self.getUnionMembers(node));
        } else {
            try self.generateExpr(v.value);
        }
        try self.emit(";\n");
    }

    /// Shared codegen for var/const declarations inside function blocks.
    /// Handles type tracking, null unions, and type_ctx for overflow codegen.
    fn generateStmtDecl(self: *CodeGen, node: *parser.Node, v: parser.VarDecl, decl_keyword: []const u8) anyerror!void {
        const tc = self.getTypeClass(node);
        try self.emitFmt("{s} {s}", .{ decl_keyword, v.name });
        if (v.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
        try self.emit(" = ");
        if (tc == .error_union) {
            try self.generateExpr(v.value);
        } else if (tc == .null_union) {
            try self.generateNullWrappedExpr(v.value);
        } else if (tc == .arbitrary_union) {
            try self.generateArbitraryUnionWrappedExpr(v.value, self.getUnionMembers(node));
        } else {
            const prev_ctx = self.type_ctx;
            self.type_ctx = v.type_annotation;
            try self.generateExpr(v.value);
            self.type_ctx = prev_ctx;
        }
        try self.emitFmt("; _ = &{s};", .{v.name});
    }


    fn generateCompt(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        // Top-level const is already comptime in Zig, so just emit const.
        if (v.is_pub) try self.emit("pub ");
        try self.emitFmt("const {s}: {s} = ", .{
            v.name,
            try self.typeToZig(v.type_annotation orelse return),
        });
        try self.generateExpr(v.value);
        try self.emit(";\n");
    }

    // ============================================================
    // TESTS
    // ============================================================

    fn generateTest(self: *CodeGen, t: parser.TestDecl) anyerror!void {
        try self.emitFmt("test {s} ", .{t.description});
        const prev_reassigned_vars = self.reassigned_vars;
        self.reassigned_vars = .{};
        try collectAssigned(t.body, &self.reassigned_vars, self.allocator);
        self.in_test_block = true;
        try self.generateBlock(t.body);
        self.in_test_block = false;
        self.reassigned_vars.deinit(self.allocator);
        self.reassigned_vars = prev_reassigned_vars;
        try self.emit("\n");
    }

    // ============================================================
    // BLOCKS AND STATEMENTS
    // ============================================================

    fn generateBlock(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .block) return;
        try self.emit("{\n");
        self.indent += 1;

        for (node.block.statements) |stmt| {
            try self.emitIndent();
            try self.generateStatement(stmt);
            try self.emit("\n");
        }

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}");
    }

    /// MIR-path block generation — walks MirNode children instead of AST statements.
    /// Handles injected temp_var/injected_defer nodes from MirLowerer.
    fn generateBlockMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        try self.emit("{\n");
        self.indent += 1;

        for (m.children) |child| {
            try self.emitIndent();
            try self.generateStatementMir(child);
            try self.emit("\n");
        }

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}");
    }

    fn generateStatement(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .var_decl => |v| {
                // var → const promotion: warn if never reassigned
                // Handle(T) variables are always var — methods mutate via *Self
                const is_handle = if (v.type_annotation) |ta|
                    ta.* == .type_generic and std.mem.eql(u8, ta.type_generic.name, "Handle")
                else
                    false;
                const is_mutated = is_handle or self.reassigned_vars.contains(v.name);
                const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "'{s}' is declared as var but never reassigned — use const", .{v.name});
                    defer self.allocator.free(msg);
                    try self.reporter.warn(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                try self.generateStmtDecl(node, v, decl_keyword);
            },
            .const_decl => |v| {
                try self.generateStmtDecl(node, v, "const");
            },
            .destruct_decl => |d| {
                // String split destructuring:
                // var before, after = s.split(",")
                if (d.names.len == 2 and d.value.* == .call_expr) {
                    const c = d.value.call_expr;
                    if (c.callee.* == .field_expr) {
                        const fe = c.callee.field_expr;
                        if (std.mem.eql(u8, fe.field, "split"))
                        {
                            const destruct_idx = self.destruct_counter;
                            self.destruct_counter += 1;
                            const decl_keyword = if (d.is_const) "const" else "var";
                            // const _orhon_sp0_delim = <arg>;
                            try self.emitFmt("const _orhon_sp{d}_delim = ", .{destruct_idx});
                            if (c.args.len > 0) try self.generateExpr(c.args[0]);
                            try self.emit(";\n");
                            try self.emitIndent();
                            // const _orhon_sp0_pos = std.mem.indexOf(u8, s, delim);
                            try self.emitFmt("const _orhon_sp{d}_pos = std.mem.indexOf(u8, ", .{destruct_idx});
                            try self.generateExpr(fe.object);
                            try self.emitFmt(", _orhon_sp{d}_delim);\n", .{destruct_idx});
                            try self.emitIndent();
                            // const before = if (pos) |_idx| s[0.._idx] else s;
                            try self.emitFmt("{s} {s} = if (_orhon_sp{d}_pos) |_idx| ", .{ decl_keyword, d.names[0], destruct_idx });
                            try self.generateExpr(fe.object);
                            try self.emit("[0.._idx] else ");
                            try self.generateExpr(fe.object);
                            try self.emit(";\n");
                            try self.emitIndent();
                            // const after = if (pos) |_idx| s[_idx + delim.len..] else "";
                            try self.emitFmt("{s} {s} = if (_orhon_sp{d}_pos) |_idx| ", .{ decl_keyword, d.names[1], destruct_idx });
                            try self.generateExpr(fe.object);
                            try self.emitFmt("[_idx + _orhon_sp{d}_delim.len..] else \"\";", .{destruct_idx});
                            return;
                        }
                    }
                }
                // splitAt destructuring:
                // var left, right = data.splitAt(3)
                if (d.names.len == 2 and d.value.* == .call_expr) {
                    const c = d.value.call_expr;
                    if (c.callee.* == .field_expr) {
                        const fe = c.callee.field_expr;
                        if (std.mem.eql(u8, fe.field, "splitAt") and c.args.len == 1) {
                            const decl_keyword = if (d.is_const) "const" else "var";
                            const destruct_idx = self.destruct_counter;
                            self.destruct_counter += 1;
                            // Force runtime index so Zig returns a slice, not a pointer-to-array
                            try self.emitFmt("var _orhon_s{d}: usize = @intCast(", .{destruct_idx});
                            try self.generateExpr(c.args[0]);
                            try self.emit(");\n");
                            try self.emitIndent();
                            try self.emitFmt("_ = &_orhon_s{d};\n", .{destruct_idx});
                            try self.emitIndent();
                            try self.emitFmt("{s} {s} = ", .{ decl_keyword, d.names[0] });
                            try self.generateExpr(fe.object);
                            try self.emitFmt("[0.._orhon_s{d}];\n", .{destruct_idx});
                            try self.emitIndent();
                            try self.emitFmt("{s} {s} = ", .{ decl_keyword, d.names[1] });
                            try self.generateExpr(fe.object);
                            try self.emitFmt("[_orhon_s{d}..];", .{destruct_idx});
                            return;
                        }
                    }
                }
                // Normal tuple destructuring:
                // var (a, b) = expr  →  const _orhon_dN = expr; var/const a = _orhon_dN.a; ...
                const idx = self.destruct_counter;
                self.destruct_counter += 1;
                try self.emitFmt("const _orhon_d{d} = ", .{idx});
                try self.generateExpr(d.value);
                try self.emit(";");
                const decl_keyword = if (d.is_const) "const" else "var";
                for (d.names) |name| {
                    try self.emit("\n");
                    try self.emitIndent();
                    try self.emitFmt("{s} {s} = _orhon_d{d}.{s};", .{ decl_keyword, name, idx, name });
                }
            },
            .compt_decl => |v| {
                try self.emitFmt("const {s}: {s} = ", .{
                    v.name,
                    try self.typeToZig(v.type_annotation orelse return),
                });
                try self.generateExpr(v.value);
                try self.emit(";");
            },
            .return_stmt => |r| {
                try self.emit("return");
                if (r.value) |v| {
                    try self.emit(" ");
                    // Use MIR coercion if available
                    const coercion = if (self.getNodeInfo(v)) |info| info.coercion else null;
                    if (coercion) |c| {
                        switch (c) {
                            .null_wrap => {
                                try self.emit(".{ .some = ");
                                try self.generateExpr(v);
                                try self.emit(" }");
                            },
                            .error_wrap => {
                                try self.emit(".{ .ok = ");
                                try self.generateExpr(v);
                                try self.emit(" }");
                            },
                            .arbitrary_union_wrap => {
                                try self.generateArbitraryUnionWrappedExpr(v, self.funcReturnMembers());
                            },
                            .array_to_slice => {
                                try self.emit("&");
                                try self.generateExpr(v);
                            },
                            .optional_unwrap => {
                                try self.generateExpr(v);
                                try self.emit(".some");
                            },
                        }
                    } else {
                        // No coercion — handle special literals and passthrough
                        const ret_tc = self.funcReturnTypeClass();
                        if (ret_tc == .error_union) {
                            if (v.* == .error_literal) {
                                try self.generateExpr(v);
                            } else if (v.* == .identifier and self.isErrorConstant(v.identifier)) {
                                try self.emit(".{ .err = ");
                                try self.generateExpr(v);
                                try self.emit(" }");
                            } else {
                                try self.generateExpr(v);
                            }
                        } else if (ret_tc == .null_union and v.* == .null_literal) {
                            try self.emit(".{ .none = {} }");
                        } else {
                            try self.generateExpr(v);
                        }
                    }
                }
                try self.emit(";");
            },
            .if_stmt => |i| {
                try self.emit("if (");
                try self.generateExpr(i.condition);
                try self.emit(") ");
                // Track type narrowing from `is` checks on arbitrary unions
                const is_info = self.extractIsCheck(i.condition);
                if (is_info) |info| {
                    // Inside then-block: positive `is T` narrows to T, negative `is not T` narrows to remaining
                    const members_rt = self.getUnionMembers(info.var_node) orelse
                        if (info.var_node.* == .identifier) self.getVarUnionMembers(info.var_node.identifier) else null;
                    if (info.is_positive) {
                        try self.type_narrowed_vars.put(self.allocator, info.var_name, info.type_name);
                    } else if (remainingUnionType(members_rt, info.type_name)) |rem| {
                        try self.type_narrowed_vars.put(self.allocator, info.var_name, rem);
                    }
                }
                try self.generateBlock(i.then_block);
                if (is_info) |info| _ = self.type_narrowed_vars.remove(info.var_name);
                if (i.else_block) |e| {
                    try self.emit(" else ");
                    // Inside else-block: opposite narrowing
                    if (is_info) |info| {
                        const members_rt = self.getUnionMembers(info.var_node) orelse
                            if (info.var_node.* == .identifier) self.getVarUnionMembers(info.var_node.identifier) else null;
                        if (info.is_positive) {
                            if (remainingUnionType(members_rt, info.type_name)) |rem|
                                try self.type_narrowed_vars.put(self.allocator, info.var_name, rem);
                        } else {
                            try self.type_narrowed_vars.put(self.allocator, info.var_name, info.type_name);
                        }
                    }
                    try self.generateBlock(e);
                    if (is_info) |info| _ = self.type_narrowed_vars.remove(info.var_name);
                }
                // After if with early exit: narrow to the opposite
                if (is_info) |info| {
                    if (blockHasEarlyExit(i.then_block)) {
                        const members_rt = self.getUnionMembers(info.var_node) orelse
                            if (info.var_node.* == .identifier) self.getVarUnionMembers(info.var_node.identifier) else null;
                        if (info.is_positive) {
                            if (remainingUnionType(members_rt, info.type_name)) |rem|
                                try self.type_narrowed_vars.put(self.allocator, info.var_name, rem);
                        } else {
                            try self.type_narrowed_vars.put(self.allocator, info.var_name, info.type_name);
                        }
                    }
                }
            },
            .while_stmt => |w| {
                try self.emit("while (");
                try self.generateExpr(w.condition);
                try self.emit(")");
                if (w.continue_expr) |c| {
                    try self.emit(" : (");
                    try self.generateContinueExpr(c);
                    try self.emit(")");
                }
                try self.emit(" ");
                try self.generateBlock(w.body);
            },
            .for_stmt => |f| {
                const is_range = f.iterable.* == .range_expr;
                // Array, slice, or range → Zig for
                const needs_cast = is_range or f.index_var != null;
                if (f.is_compt) try self.emit("inline ");
                try self.emit("for (");
                if (is_range) {
                    try self.writeRangeExpr(f.iterable.range_expr);
                } else {
                    try self.generateExpr(f.iterable);
                }
                // Inject 0.. counter when index variable is requested
                if (f.index_var != null) try self.emit(", 0..");
                try self.emit(") |");
                if (is_range) {
                    // Range produces usize — rename and cast to i32
                    try self.emitFmt("_orhon_{s}", .{f.captures[0]});
                } else {
                    try self.emit(f.captures[0]);
                }
                if (f.index_var) |idx| {
                    // Index from 0.. is usize — rename and cast to i32
                    try self.emitFmt(", _orhon_{s}", .{idx});
                }
                if (needs_cast) {
                    try self.emit("| {\n");
                    self.indent += 1;
                    if (is_range) {
                        try self.emitIndent();
                        try self.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ f.captures[0], f.captures[0] });
                    }
                    if (f.index_var) |idx| {
                        try self.emitIndent();
                        try self.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ idx, idx });
                    }
                    for (f.body.block.statements) |stmt| {
                        try self.emitIndent();
                        try self.generateStatement(stmt);
                        try self.emit("\n");
                    }
                    self.indent -= 1;
                    try self.emitIndent();
                    try self.emit("}");
                } else {
                    try self.emit("| ");
                    try self.generateBlock(f.body);
                }
            },
            .defer_stmt => |d| {
                try self.emit("defer ");
                try self.generateBlock(d.body);
            },
            .match_stmt => |m| {
                // String match — Zig has no string switch, desugar to if/else chain
                const is_string_match = blk: {
                    for (m.arms) |arm| {
                        if (arm.* == .match_arm and arm.match_arm.pattern.* == .string_literal)
                            break :blk true;
                    }
                    break :blk false;
                };

                // Type match — any arm is `Error`, `null`, or value is an arbitrary union
                // match result { Error => { } i32 => { } }
                // match user   { null  => { } User => { } }
                // match val    { i32   => { } f32  => { } }
                const is_type_match = blk: {
                    // Check if the match value is an arbitrary union variable
                    if (self.getTypeClass(m.value) == .arbitrary_union)
                        break :blk true;
                    for (m.arms) |arm| {
                        if (arm.* != .match_arm) continue;
                        const pat = arm.match_arm.pattern;
                        if (pat.* == .null_literal) break :blk true;
                        if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, K.Type.ERROR))
                            break :blk true;
                    }
                    break :blk false;
                };

                // Determine whether the union is a null union (has `null` arm)
                // vs an error union (has `Error` arm) — affects which tag non-special arms map to
                const is_null_union = blk: {
                    for (m.arms) |arm| {
                        if (arm.* == .match_arm and arm.match_arm.pattern.* == .null_literal)
                            break :blk true;
                    }
                    break :blk false;
                };

                if (is_string_match) {
                    try self.generateStringMatch(m);
                } else if (is_type_match) {
                    try self.generateTypeMatch(m, is_null_union);
                } else {

                try self.emit("switch (");
                // self in a method is *T in Zig — must dereference for switch
                if (m.value.* == .identifier and std.mem.eql(u8, m.value.identifier, "self")) {
                    try self.emit("self.*");
                } else {
                    try self.generateExpr(m.value);
                }
                try self.emit(") {\n");
                self.indent += 1;
                var has_wildcard = false;
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        try self.emitIndent();
                        // Check for wildcard pattern (else)
                        if (arm.match_arm.pattern.* == .identifier and
                            std.mem.eql(u8, arm.match_arm.pattern.identifier, "else"))
                        {
                            has_wildcard = true;
                            try self.emit("else");
                        } else if (arm.match_arm.pattern.* == .range_expr) {
                            // Range pattern: 4..8 in Orhon → 4...8 in Zig switch (inclusive)
                            const r = arm.match_arm.pattern.range_expr;
                            try self.generateExpr(r.left);
                            try self.emit("...");
                            try self.generateExpr(r.right);
                        } else {
                            try self.generateExpr(arm.match_arm.pattern);
                        }
                        try self.emit(" => ");
                        try self.generateBlock(arm.match_arm.body);
                        try self.emit(",\n");
                    }
                }
                // Zig requires exhaustive switches — add else if no wildcard
                // But for enum switches, if all variants are handled, else is invalid
                if (!has_wildcard) {
                    var is_enum_switch = false;
                    for (m.arms) |arm| {
                        if (arm.* == .match_arm and arm.match_arm.pattern.* == .identifier) {
                            if (self.isEnumVariant(arm.match_arm.pattern.identifier)) {
                                is_enum_switch = true;
                                break;
                            }
                        }
                    }
                    if (!is_enum_switch) {
                        try self.emitIndent();
                        try self.emit("else => {},\n");
                    }
                }
                self.indent -= 1;
                try self.emitIndent();
                try self.emit("}");
                } // close else (non-string, non-type match)
            },
            .break_stmt => try self.emit("break;"),
            .continue_stmt => try self.emit("continue;"),
            .assignment => |a| {
                if (std.mem.eql(u8, a.op, "/=")) {
                    // x /= y → x = @divTrunc(x, y)
                    try self.generateExpr(a.left);
                    try self.emit(" = @divTrunc(");
                    try self.generateExpr(a.left);
                    try self.emit(", ");
                    try self.generateExpr(a.right);
                    try self.emit(");");
                } else if (std.mem.eql(u8, a.op, "=") and
                    self.getTypeClass(a.left) == .null_union)
                {
                    // Assignment to null union var → wrap value
                    try self.generateExpr(a.left);
                    try self.emit(" = ");
                    try self.generateNullWrappedExpr(a.right);
                    try self.emit(";");
                } else if (std.mem.eql(u8, a.op, "=") and
                    self.getTypeClass(a.left) == .arbitrary_union)
                {
                    // Assignment to arb union var → wrap value
                    const members_rt = self.getUnionMembers(a.left) orelse
                        if (a.left.* == .identifier) self.getVarUnionMembers(a.left.identifier) else null;
                    try self.generateExpr(a.left);
                    try self.emit(" = ");
                    try self.generateArbitraryUnionWrappedExpr(a.right, members_rt);
                    try self.emit(";");
                } else {
                    try self.generateExpr(a.left);
                    try self.emitFmt(" {s} ", .{a.op});
                    try self.generateExpr(a.right);
                    try self.emit(";");
                }
            },
            .block => try self.generateBlock(node),
            else => {
                // Bare call expression as statement — discard return value so Zig
                // doesn't error on unused non-void results.  _ = void is also valid.
                if (node.* == .call_expr) try self.emit("_ = ");
                try self.generateExpr(node);
                try self.emit(";");
            },
        }
    }

    /// MIR-path statement dispatch — switches on MirKind, reads type info from MirNode.
    /// Migrated handlers use m.type_class/m.coercion directly; unmigrated handlers delegate to AST.
    fn generateStatementMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .var_decl => {
                switch (m.ast.*) {
                    .var_decl => |v| {
                        const is_handle = if (v.type_annotation) |ta|
                            ta.* == .type_generic and std.mem.eql(u8, ta.type_generic.name, "Handle")
                        else
                            false;
                        const is_mutated = is_handle or self.reassigned_vars.contains(v.name);
                        const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                        if (!is_mutated) {
                            const msg = try std.fmt.allocPrint(self.allocator,
                                "'{s}' is declared as var but never reassigned — use const", .{v.name});
                            defer self.allocator.free(msg);
                            try self.reporter.warn(.{ .message = msg, .loc = self.nodeLoc(m.ast) });
                        }
                        try self.generateStmtDeclMir(m, v, decl_keyword);
                    },
                    .const_decl => |v| try self.generateStmtDeclMir(m, v, "const"),
                    .compt_decl => |v| {
                        try self.emitFmt("const {s}: {s} = ", .{
                            v.name,
                            try self.typeToZig(v.type_annotation orelse return),
                        });
                        try self.generateExpr(v.value);
                        try self.emit(";");
                    },
                    else => {},
                }
            },
            .return_stmt => {
                try self.emit("return");
                if (m.children.len > 0) {
                    const val_m = m.value();
                    try self.emit(" ");
                    // Use MIR coercion from child MirNode directly
                    if (val_m.coercion) |c| {
                        switch (c) {
                            .null_wrap => {
                                try self.emit(".{ .some = ");
                                try self.generateExprMir(val_m);
                                try self.emit(" }");
                            },
                            .error_wrap => {
                                try self.emit(".{ .ok = ");
                                try self.generateExprMir(val_m);
                                try self.emit(" }");
                            },
                            .arbitrary_union_wrap => {
                                try self.generateArbitraryUnionWrappedExpr(val_m.ast, self.funcReturnMembers());
                            },
                            .array_to_slice => {
                                try self.emit("&");
                                try self.generateExprMir(val_m);
                            },
                            .optional_unwrap => {
                                try self.generateExprMir(val_m);
                                try self.emit(".some");
                            },
                        }
                    } else {
                        const ret_tc = self.funcReturnTypeClass();
                        if (ret_tc == .error_union) {
                            if (val_m.ast.* == .error_literal) {
                                try self.generateExprMir(val_m);
                            } else if (val_m.ast.* == .identifier and self.isErrorConstant(val_m.ast.identifier)) {
                                try self.emit(".{ .err = ");
                                try self.generateExprMir(val_m);
                                try self.emit(" }");
                            } else {
                                try self.generateExprMir(val_m);
                            }
                        } else if (ret_tc == .null_union and val_m.ast.* == .null_literal) {
                            try self.emit(".{ .none = {} }");
                        } else {
                            try self.generateExprMir(val_m);
                        }
                    }
                }
                try self.emit(";");
            },
            .if_stmt => {
                try self.emit("if (");
                try self.generateExprMir(m.condition());
                try self.emit(") ");
                // Use pre-computed narrowing from MirNode
                if (m.narrowing) |narrowing| {
                    // then-block narrowing
                    if (narrowing.then_type) |tt|
                        try self.type_narrowed_vars.put(self.allocator, narrowing.var_name, tt);
                }
                if (m.children.len > 1) try self.generateBlockMir(m.thenBlock());
                if (m.narrowing) |narrowing| _ = self.type_narrowed_vars.remove(narrowing.var_name);
                if (m.elseBlock()) |else_m| {
                    try self.emit(" else ");
                    if (m.narrowing) |narrowing| {
                        if (narrowing.else_type) |et|
                            try self.type_narrowed_vars.put(self.allocator, narrowing.var_name, et);
                    }
                    try self.generateBlockMir(else_m);
                    if (m.narrowing) |narrowing| _ = self.type_narrowed_vars.remove(narrowing.var_name);
                }
                // After if with early exit: apply post narrowing
                if (m.narrowing) |narrowing| {
                    if (narrowing.post_type) |pt|
                        try self.type_narrowed_vars.put(self.allocator, narrowing.var_name, pt);
                }
            },
            .assignment => {
                const a = m.ast.assignment;
                if (std.mem.eql(u8, a.op, "/=")) {
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = @divTrunc(");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(");");
                } else if (std.mem.eql(u8, a.op, "=") and
                    m.lhs().type_class == .null_union)
                {
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = ");
                    try self.generateNullWrappedExpr(a.right);
                    try self.emit(";");
                } else if (std.mem.eql(u8, a.op, "=") and
                    m.lhs().type_class == .arbitrary_union)
                {
                    const members_rt = if (m.lhs().resolved_type == .union_type)
                        m.lhs().resolved_type.union_type
                    else if (a.left.* == .identifier) self.getVarUnionMembers(a.left.identifier) else null;
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = ");
                    try self.generateArbitraryUnionWrappedExpr(a.right, members_rt);
                    try self.emit(";");
                } else {
                    try self.generateExprMir(m.lhs());
                    try self.emitFmt(" {s} ", .{a.op});
                    try self.generateExprMir(m.rhs());
                    try self.emit(";");
                }
            },
            .destruct => try self.generateStatement(m.ast), // complex, stays on AST
            .while_stmt => {
                const w = m.ast.while_stmt;
                try self.emit("while (");
                try self.generateExprMir(m.condition());
                try self.emit(")");
                if (w.continue_expr) |c| {
                    try self.emit(" : (");
                    try self.generateContinueExpr(c);
                    try self.emit(")");
                }
                try self.emit(" ");
                // Body is children[1] (not last — continue_expr may follow)
                try self.generateBlockMir(m.children[1]);
            },
            .for_stmt => try self.generateStatement(m.ast), // complex range/index, stays on AST
            .defer_stmt => {
                try self.emit("defer ");
                try self.generateBlockMir(m.body());
            },
            .match_stmt => try self.generateStatement(m.ast), // complex dispatch, stays on AST
            .break_stmt => try self.emit("break;"),
            .continue_stmt => try self.emit("continue;"),
            .block => try self.generateBlockMir(m),
            // Injected nodes from MirLowerer (interpolation hoisting)
            .temp_var => {
                if (m.injected_name) |name| {
                    try self.emitFmt("const {s} = ", .{name});
                    try self.generateInterpolatedString(m.ast.interpolated_string);
                    try self.emit(";");
                }
            },
            .injected_defer => {
                if (m.injected_name) |name| {
                    try self.emitFmt("defer _rt.alloc.free({s});", .{name});
                }
            },
            // Bare expression as statement — discard return value
            else => {
                if (m.kind == .call) try self.emit("_ = ");
                try self.generateExprMir(m);
                try self.emit(";");
            },
        }
    }

    /// MIR-path statement var/const declaration — uses m.type_class directly.
    fn generateStmtDeclMir(self: *CodeGen, m: *mir.MirNode, v: parser.VarDecl, decl_keyword: []const u8) anyerror!void {
        const val_m = m.value(); // children[0] = value expression
        try self.emitFmt("{s} {s}", .{ decl_keyword, v.name });
        if (v.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
        try self.emit(" = ");
        if (m.type_class == .error_union) {
            try self.generateExprMir(val_m);
        } else if (m.type_class == .null_union) {
            try self.generateNullWrappedExpr(v.value);
        } else if (m.type_class == .arbitrary_union) {
            const members_rt = if (m.resolved_type == .union_type) m.resolved_type.union_type else null;
            try self.generateArbitraryUnionWrappedExpr(v.value, members_rt);
        } else {
            const prev_ctx = self.type_ctx;
            self.type_ctx = v.type_annotation;
            try self.generateExprMir(val_m);
            self.type_ctx = prev_ctx;
        }
        try self.emitFmt("; _ = &{s};", .{v.name});
    }

    // ============================================================
    // EXPRESSIONS
    // ============================================================

    fn generateExpr(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .int_literal => |text| {
                // Remove underscore separators for Zig (Zig uses _ too, so keep them)
                try self.emit(text);
            },
            .float_literal => |text| try self.emit(text),
            .string_literal => |text| try self.emit(text),
            .interpolated_string => |interp| try self.generateInterpolatedString(interp),
            .bool_literal => |b| try self.emit(if (b) "true" else "false"),
            .null_literal => try self.emit("null"),
            .error_literal => |msg| {
                if (self.funcReturnTypeClass() == .error_union) {
                    // Inside a function returning (Error | T) → union variant
                    try self.emitFmt(".{{ .err = .{{ .message = {s} }} }}", .{msg});
                } else {
                    // Standalone Error value (const, assignment)
                    try self.emitFmt("_rt.OrhonError{{ .message = {s} }}", .{msg});
                }
            },
            .identifier => |name| {
                if (self.isEnumVariant(name)) {
                    try self.emitFmt(".{s}", .{name});
                } else if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, name, gsn)) {
                        try self.emit("@This()");
                    } else {
                        const mapped = builtins.primitiveToZig(name);
                        try self.emit(mapped);
                    }
                } else {
                    // Map type names used as values (e.g. generic type args)
                    const mapped = builtins.primitiveToZig(name);
                    try self.emit(mapped);
                }
            },
            .borrow_expr => |inner| {
                try self.emit("&");
                try self.generateExpr(inner);
            },
            .array_literal => |items| {
                try self.emit(".{");
                for (items, 0..) |item, i| {
                    if (i > 0) try self.emit(", ");
                    try self.generateExpr(item);
                }
                try self.emit("}");
            },
            .tuple_literal => |t| {
                try self.emit(".{");
                if (t.is_named) {
                    for (t.fields, 0..) |field, i| {
                        if (i > 0) try self.emit(", ");
                        try self.emitFmt(".{s} = ", .{t.field_names[i]});
                        try self.generateExpr(field);
                    }
                } else {
                    for (t.fields, 0..) |field, i| {
                        if (i > 0) try self.emit(", ");
                        try self.generateExpr(field);
                    }
                }
                try self.emit("}");
            },
            .binary_expr => |b| {
                // `x is Error`   → x == .err    (error union tag check)
                // `x is null`    → x == .none   (null union tag check)
                // `x is T`       → @TypeOf(x) == T  (comptime type check for `any` params)
                // `x is not ...` → same but with !=
                const is_eq = std.mem.eql(u8, b.op, "==");
                const is_ne = std.mem.eql(u8, b.op, "!=");
                if ((is_eq or is_ne) and
                    b.left.* == .compiler_func and
                    std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE) and
                    b.left.compiler_func.args.len > 0)
                {
                    const val_node = b.left.compiler_func.args[0];
                    const cmp = if (is_eq) "==" else "!=";
                    // null is a keyword, parsed as .null_literal not .identifier
                    if (b.right.* == .null_literal) {
                        try self.emit("(");
                        try self.generateExpr(val_node);
                        try self.emitFmt(" {s} .none)", .{cmp});
                        return;
                    }
                    if (b.right.* == .identifier) {
                        const rhs = b.right.identifier;
                        if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                            try self.emit("(");
                            try self.generateExpr(val_node);
                            try self.emitFmt(" {s} .err)", .{cmp});
                            return;
                        }
                        // Arbitrary union type check: `val is i32` → `val == ._i32`
                        if (self.getTypeClass(val_node) == .arbitrary_union) {
                            try self.emit("(");
                            try self.generateExpr(val_node);
                            try self.emitFmt(" {s} ._{s})", .{ cmp, rhs });
                            return;
                        }
                        // General type check: `val is i32` → `@TypeOf(val) == i32`
                        // Map Orhon type names to Zig (e.g. String → []const u8)
                        const zig_rhs = builtins.primitiveToZig(rhs);
                        try self.emit("(@TypeOf(");
                        try self.generateExpr(val_node);
                        try self.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                        return;
                    }
                }
                // Division on signed ints → @divTrunc in Zig
                if (std.mem.eql(u8, b.op, "/")) {
                    try self.emit("@divTrunc(");
                    try self.generateExpr(b.left);
                    try self.emit(", ");
                    try self.generateExpr(b.right);
                    try self.emit(")");
                } else if (std.mem.eql(u8, b.op, "%")) {
                    try self.emit("@mod(");
                    try self.generateExpr(b.left);
                    try self.emit(", ");
                    try self.generateExpr(b.right);
                    try self.emit(")");
                } else if ((is_eq or is_ne) and (self.isStringExpr(b.left) or self.isStringExpr(b.right))) {
                    // String ([]const u8) comparison → std.mem.eql
                    if (is_ne) try self.emit("!");
                    try self.emit("std.mem.eql(u8, ");
                    try self.generateExpr(b.left);
                    try self.emit(", ");
                    try self.generateExpr(b.right);
                    try self.emit(")");
                } else {
                    const op = opToZig(b.op);
                    try self.emit("(");
                    try self.generateExpr(b.left);
                    try self.emitFmt(" {s} ", .{op});
                    try self.generateExpr(b.right);
                    try self.emit(")");
                }
            },
            .unary_expr => |u| {
                const op = opToZig(u.op);
                try self.emitFmt("{s}(", .{op});
                try self.generateExpr(u.operand);
                try self.emit(")");
            },
            .call_expr => |c| {
                // Version() is metadata-only — reject in expressions
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "Version")) {
                    try self.reporter.report(.{
                        .message = "Version() can only be used in #version metadata",
                        .loc = self.nodeLoc(node),
                    });
                    return;
                }
                // Handle(value) → just emit the value (wrapping done by spawn wrapper)
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "Handle") and c.args.len == 1) {
                    try self.generateExpr(c.args[0]);
                    return;
                }
                // Bitfield constructor: Permissions(Read, Write) → Permissions{ .value = Permissions.Read | Permissions.Write }
                if (c.callee.* == .identifier) {
                    if (self.decls) |d| {
                        if (d.bitfields.get(c.callee.identifier)) |_| {
                            const bf_name = c.callee.identifier;
                            try self.emitFmt("{s}{{ .value = ", .{bf_name});
                            if (c.args.len == 0) {
                                try self.emit("0");
                            } else {
                                for (c.args, 0..) |arg, i| {
                                    if (i > 0) try self.emit(" | ");
                                    if (arg.* == .identifier) {
                                        try self.emitFmt("{s}.{s}", .{ bf_name, arg.identifier });
                                    } else {
                                        try self.generateExpr(arg);
                                    }
                                }
                            }
                            try self.emit(" }");
                            return;
                        }
                    }
                }
                // Bitfield method: p.has(Read) → p.has(Permissions.Read) — qualify flag args
                if (c.callee.* == .field_expr) {
                    const obj = c.callee.field_expr.object;
                    if (self.getBitfieldName(obj)) |bf_name| {
                        try self.generateExpr(c.callee);
                        try self.emit("(");
                        for (c.args, 0..) |arg, i| {
                            if (i > 0) try self.emit(", ");
                            if (arg.* == .identifier) {
                                try self.emitFmt("{s}.{s}", .{ bf_name, arg.identifier });
                            } else {
                                try self.generateExpr(arg);
                            }
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // overflow/wrap/sat builtins
                if (c.callee.* == .identifier and c.args.len == 1) {
                    const callee_name = c.callee.identifier;
                    if (std.mem.eql(u8, callee_name, "wrap")) {
                        try self.generateWrappingExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "sat")) {
                        try self.generateSaturatingExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "overflow")) {
                        try self.generateOverflowExpr(c.args[0]);
                        return;
                    }
                }
                // ── String method rewriting ──
                // s.method(args) → _str.method(s, args) when s is a String
                // x.toString()   → _str.toString(x) for any type
                // arr.join(sep)  → _str.join(arr, sep) for array/slice join
                if (c.callee.* == .field_expr) {
                    const method = c.callee.field_expr.field;
                    const obj = c.callee.field_expr.object;
                    const is_handle = self.getTypeClass(obj) == .thread_handle;
                    if (!is_handle and (self.isStringExpr(obj) or
                        std.mem.eql(u8, method, "toString") or
                        std.mem.eql(u8, method, "join")))
                    {
                        try self.emitFmt("_str.{s}(", .{method});
                        try self.generateExpr(obj);
                        for (c.args) |arg| {
                            try self.emit(", ");
                            try self.generateExpr(arg);
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // ── Clean call generation — pure 1:1 translation ──
                if (c.arg_names.len > 0) {
                    // Named arguments → struct instantiation: Type{ .field = value, ... }
                    try self.generateExpr(c.callee);
                    try self.emit("{ ");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        if (i < c.arg_names.len and c.arg_names[i].len > 0) {
                            try self.emitFmt(".{s} = ", .{c.arg_names[i]});
                        }
                        try self.generateExpr(arg);
                    }
                    try self.emit(" }");
                } else {
                    // Positional arguments → regular function call
                    try self.generateExpr(c.callee);
                    try self.emit("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        try self.generateCoercedExpr(arg);
                    }
                    // Fill in default args if caller passed fewer than the function expects
                    try self.fillDefaultArgs(c);
                    try self.emit(")");
                }
            },
            .field_expr => |f| {
                // handle.value → handle.getValue() (thread Handle(T) — blocks + moves result)
                if (std.mem.eql(u8, f.field, "value") and
                    self.getTypeClass(f.object) == .thread_handle)
                {
                    try self.generateExpr(f.object);
                    try self.emit(".getValue()");
                // handle.done → handle.done() (thread Handle(T) — non-blocking check)
                } else if (std.mem.eql(u8, f.field, "done") and
                    self.getTypeClass(f.object) == .thread_handle)
                {
                    try self.generateExpr(f.object);
                    try self.emit(".done()");
                // ptr.value → ptr.* (safe Ptr(T) dereference)
                } else if (std.mem.eql(u8, f.field, "value") and
                    self.getTypeClass(f.object) == .safe_ptr)
                {
                    try self.generateExpr(f.object);
                    try self.emit(".*");
                // raw.value → raw[0] (RawPtr/VolatilePtr dereference)
                } else if (std.mem.eql(u8, f.field, "value") and
                    self.getTypeClass(f.object) == .raw_ptr)
                {
                    try self.generateExpr(f.object);
                    try self.emit("[0]");
                } else if (std.mem.eql(u8, f.field, K.Type.ERROR)) {
                    try self.generateExpr(f.object);
                    try self.emit(".err");
                } else if (std.mem.eql(u8, f.field, "value") and
                    (self.getTypeClass(f.object) == .arbitrary_union or self.getTypeClass(f.object) == .null_union or self.getTypeClass(f.object) == .error_union))
                {
                    // .value unwrap — emit correct Zig field based on union kind
                    const obj_tc = self.getTypeClass(f.object);
                    try self.generateExpr(f.object);
                    if (obj_tc == .arbitrary_union) {
                        // Use narrowed type from `is` checks if available
                        if (f.object.* == .identifier) {
                            if (self.type_narrowed_vars.get(f.object.identifier)) |narrowed| {
                                try self.emitFmt("._{s}", .{narrowed});
                            } else if (self.getUnionMembers(f.object) orelse self.getVarUnionMembers(f.object.identifier)) |members| {
                                // MIR: fall back to first non-error/non-null type
                                for (members) |m| {
                                    const n = m.name();
                                    if (!std.mem.eql(u8, n, K.Type.ERROR) and !std.mem.eql(u8, n, K.Type.NULL)) {
                                        try self.emitFmt("._{s}", .{n});
                                        break;
                                    }
                                }
                            }
                        }
                    } else if (obj_tc == .null_union) {
                        try self.emit(".some");
                    } else if (obj_tc == .error_union) {
                        try self.emit(".ok");
                    }
                } else if (self.getTypeClass(f.object) == .arbitrary_union and
                    isResultValueField(f.field, self.decls))
                {
                    // Arbitrary union field access: result.i32 → result._i32
                    try self.generateExpr(f.object);
                    try self.emitFmt("._{s}", .{f.field});
                } else if (isResultValueField(f.field, self.decls)) {
                    // Check if the object is a null union variable
                    if (self.getTypeClass(f.object) == .null_union) {
                        // result.User → result.some (null union access)
                        try self.generateExpr(f.object);
                        try self.emit(".some");
                    } else {
                        // result.i32 / result.User etc → result.ok (error union access)
                        try self.generateExpr(f.object);
                        try self.emit(".ok");
                    }
                } else {
                    try self.generateExpr(f.object);
                    try self.emitFmt(".{s}", .{f.field});
                }
            },
            .index_expr => |i| {
                try self.generateExpr(i.object);
                try self.emit("[");
                // Zig requires usize for indices — cast non-literal indices
                const index_is_literal = i.index.* == .int_literal;
                if (!index_is_literal) {
                    try self.emit("@intCast(");
                    try self.generateExpr(i.index);
                    try self.emit(")");
                } else {
                    try self.generateExpr(i.index);
                }
                try self.emit("]");
            },
            .slice_expr => |s| {
                try self.generateExpr(s.object);
                try self.emit("[");
                const low_is_literal = s.low.* == .int_literal;
                if (!low_is_literal) {
                    try self.emit("@intCast(");
                    try self.generateExpr(s.low);
                    try self.emit(")");
                } else {
                    try self.generateExpr(s.low);
                }
                try self.emit("..");
                const high_is_literal = s.high.* == .int_literal;
                if (!high_is_literal) {
                    try self.emit("@intCast(");
                    try self.generateExpr(s.high);
                    try self.emit(")");
                } else {
                    try self.generateExpr(s.high);
                }
                try self.emit("]");
            },
            .compiler_func => |cf| {
                try self.generateCompilerFunc(cf);
            },
            .range_expr => |r| {
                try self.generateExpr(r.left);
                try self.emit("..");
                try self.generateExpr(r.right);
            },
            .ptr_expr => |p| {
                try self.generatePtrExpr(p);
            },
            .collection_expr => |c| {
                try self.generateCollectionExpr(c);
            },
            .struct_type => |fields| {
                try self.emit("struct {\n");
                self.indent += 1;
                for (fields) |f| {
                    if (f.* == .field_decl) {
                        try self.emitIndent();
                        try self.emitFmt("{s}: {s},\n", .{
                            f.field_decl.name,
                            try self.typeToZig(f.field_decl.type_annotation),
                        });
                    }
                }
                self.indent -= 1;
                try self.emitIndent();
                try self.emit("}");
            },
            else => {
                const msg = try std.fmt.allocPrint(self.allocator, "internal codegen error: unhandled expression kind '{s}'", .{@tagName(node.*)});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
                return error.CompileError;
            },
        }
    }

    /// MIR-path expression dispatch — switches on MirKind, reads type info from MirNode.
    /// Handlers for binary, call, field_access use m.type_class/m.children directly.
    /// All other expression kinds delegate to the AST path via generateExpr(m.ast).
    fn generateExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .binary => {
                const b = m.ast.binary_expr;
                const is_eq = std.mem.eql(u8, b.op, "==");
                const is_ne = std.mem.eql(u8, b.op, "!=");
                // `x is T` desugared form: @type(x) == T
                if ((is_eq or is_ne) and
                    b.left.* == .compiler_func and
                    std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE) and
                    b.left.compiler_func.args.len > 0)
                {
                    const val_node = b.left.compiler_func.args[0];
                    const cmp = if (is_eq) "==" else "!=";
                    if (b.right.* == .null_literal) {
                        try self.emit("(");
                        try self.generateExpr(val_node);
                        try self.emitFmt(" {s} .none)", .{cmp});
                        return;
                    }
                    if (b.right.* == .identifier) {
                        const rhs = b.right.identifier;
                        if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                            try self.emit("(");
                            try self.generateExpr(val_node);
                            try self.emitFmt(" {s} .err)", .{cmp});
                            return;
                        }
                        // Use MIR type info from the LHS child (the @type call node)
                        if (m.lhs().type_class == .arbitrary_union or
                            self.getTypeClass(val_node) == .arbitrary_union)
                        {
                            try self.emit("(");
                            try self.generateExpr(val_node);
                            try self.emitFmt(" {s} ._{s})", .{ cmp, rhs });
                            return;
                        }
                        const zig_rhs = builtins.primitiveToZig(rhs);
                        try self.emit("(@TypeOf(");
                        try self.generateExpr(val_node);
                        try self.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                        return;
                    }
                }
                // Division → @divTrunc
                if (std.mem.eql(u8, b.op, "/")) {
                    try self.emit("@divTrunc(");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                } else if (std.mem.eql(u8, b.op, "%")) {
                    try self.emit("@mod(");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                } else if ((is_eq or is_ne) and (mirIsString(m.lhs()) or mirIsString(m.rhs()))) {
                    // String comparison → std.mem.eql
                    if (is_ne) try self.emit("!");
                    try self.emit("std.mem.eql(u8, ");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                } else {
                    const op = opToZig(b.op);
                    try self.emit("(");
                    try self.generateExprMir(m.lhs());
                    try self.emitFmt(" {s} ", .{op});
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                }
            },
            .call => {
                const c = m.ast.call_expr;
                // Version() rejection
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "Version")) {
                    try self.reporter.report(.{
                        .message = "Version() can only be used in #version metadata",
                        .loc = self.nodeLoc(m.ast),
                    });
                    return;
                }
                // Handle(value) → just emit the value
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "Handle") and c.args.len == 1) {
                    try self.generateExprMir(m.callArgs()[0]);
                    return;
                }
                // Bitfield constructor
                if (c.callee.* == .identifier) {
                    if (self.decls) |d| {
                        if (d.bitfields.get(c.callee.identifier)) |_| {
                            const bf_name = c.callee.identifier;
                            try self.emitFmt("{s}{{ .value = ", .{bf_name});
                            if (c.args.len == 0) {
                                try self.emit("0");
                            } else {
                                for (m.callArgs(), 0..) |arg, i| {
                                    if (i > 0) try self.emit(" | ");
                                    if (arg.ast.* == .identifier) {
                                        try self.emitFmt("{s}.{s}", .{ bf_name, arg.ast.identifier });
                                    } else {
                                        try self.generateExprMir(arg);
                                    }
                                }
                            }
                            try self.emit(" }");
                            return;
                        }
                    }
                }
                // Bitfield method: p.has(Read) → p.has(Permissions.Read)
                if (c.callee.* == .field_expr) {
                    const obj_mir = m.getCallee().children[0]; // field_access.children[0] = object
                    if (mirGetBitfieldName(obj_mir, self.decls)) |bf_name| {
                        try self.generateExpr(c.callee);
                        try self.emit("(");
                        for (m.callArgs(), 0..) |arg, i| {
                            if (i > 0) try self.emit(", ");
                            if (arg.ast.* == .identifier) {
                                try self.emitFmt("{s}.{s}", .{ bf_name, arg.ast.identifier });
                            } else {
                                try self.generateExprMir(arg);
                            }
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // overflow/wrap/sat builtins
                if (c.callee.* == .identifier and c.args.len == 1) {
                    const callee_name = c.callee.identifier;
                    if (std.mem.eql(u8, callee_name, "wrap")) {
                        try self.generateWrappingExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "sat")) {
                        try self.generateSaturatingExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "overflow")) {
                        try self.generateOverflowExpr(c.args[0]);
                        return;
                    }
                }
                // String method rewriting: s.method(args) → _str.method(s, args)
                if (c.callee.* == .field_expr) {
                    const method = c.callee.field_expr.field;
                    const obj = c.callee.field_expr.object;
                    const obj_mir = m.getCallee().children[0]; // field_access.children[0] = object
                    const is_handle = obj_mir.type_class == .thread_handle;
                    if (!is_handle and (mirIsString(obj_mir) or
                        std.mem.eql(u8, method, "toString") or
                        std.mem.eql(u8, method, "join")))
                    {
                        try self.emitFmt("_str.{s}(", .{method});
                        try self.generateExpr(obj);
                        for (m.callArgs()) |arg| {
                            try self.emit(", ");
                            try self.generateExprMir(arg);
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // Clean call generation
                if (c.arg_names.len > 0) {
                    try self.generateExprMir(m.getCallee());
                    try self.emit("{ ");
                    for (m.callArgs(), 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        if (i < c.arg_names.len and c.arg_names[i].len > 0) {
                            try self.emitFmt(".{s} = ", .{c.arg_names[i]});
                        }
                        try self.generateExprMir(arg);
                    }
                    try self.emit(" }");
                } else {
                    try self.generateExprMir(m.getCallee());
                    try self.emit("(");
                    for (m.callArgs(), 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        try self.generateCoercedExprMir(arg);
                    }
                    try self.fillDefaultArgs(c);
                    try self.emit(")");
                }
            },
            .field_access => {
                const f = m.ast.field_expr;
                const obj_mir = m.children[0];
                const obj_tc = obj_mir.type_class;
                // handle.value → handle.getValue()
                if (std.mem.eql(u8, f.field, "value") and obj_tc == .thread_handle) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".getValue()");
                } else if (std.mem.eql(u8, f.field, "done") and obj_tc == .thread_handle) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".done()");
                } else if (std.mem.eql(u8, f.field, "value") and obj_tc == .safe_ptr) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".*");
                } else if (std.mem.eql(u8, f.field, "value") and obj_tc == .raw_ptr) {
                    try self.generateExprMir(obj_mir);
                    try self.emit("[0]");
                } else if (std.mem.eql(u8, f.field, K.Type.ERROR)) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".err");
                } else if (std.mem.eql(u8, f.field, "value") and
                    (obj_tc == .arbitrary_union or obj_tc == .null_union or obj_tc == .error_union))
                {
                    try self.generateExprMir(obj_mir);
                    if (obj_tc == .arbitrary_union) {
                        if (f.object.* == .identifier) {
                            if (self.type_narrowed_vars.get(f.object.identifier)) |narrowed| {
                                try self.emitFmt("._{s}", .{narrowed});
                            } else {
                                const members_rt = if (obj_mir.resolved_type == .union_type) obj_mir.resolved_type.union_type else
                                    if (self.getVarUnionMembers(f.object.identifier)) |m2| m2 else null;
                                if (members_rt) |members| {
                                    for (members) |mem| {
                                        const n = mem.name();
                                        if (!std.mem.eql(u8, n, K.Type.ERROR) and !std.mem.eql(u8, n, K.Type.NULL)) {
                                            try self.emitFmt("._{s}", .{n});
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    } else if (obj_tc == .null_union) {
                        try self.emit(".some");
                    } else if (obj_tc == .error_union) {
                        try self.emit(".ok");
                    }
                } else if (obj_tc == .arbitrary_union and isResultValueField(f.field, self.decls)) {
                    try self.generateExprMir(obj_mir);
                    try self.emitFmt("._{s}", .{f.field});
                } else if (isResultValueField(f.field, self.decls)) {
                    if (obj_tc == .null_union) {
                        try self.generateExprMir(obj_mir);
                        try self.emit(".some");
                    } else {
                        try self.generateExprMir(obj_mir);
                        try self.emit(".ok");
                    }
                } else {
                    try self.generateExprMir(obj_mir);
                    try self.emitFmt(".{s}", .{f.field});
                }
            },
            // All other expression kinds — delegate to AST path
            else => try self.generateExpr(m.ast),
        }
    }

    /// MIR-path coerced expression — reads coercion from MirNode directly.
    fn generateCoercedExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const coercion = m.coercion orelse return self.generateExprMir(m);
        switch (coercion) {
            .array_to_slice => {
                try self.emit("&");
                try self.generateExprMir(m);
            },
            .null_wrap => {
                if (m.ast.* == .null_literal) {
                    try self.emit(".{ .none = {} }");
                } else {
                    try self.emit(".{ .some = ");
                    try self.generateExprMir(m);
                    try self.emit(" }");
                }
            },
            .error_wrap => {
                try self.emit(".{ .ok = ");
                try self.generateExprMir(m);
                try self.emit(" }");
            },
            .arbitrary_union_wrap => {
                if (m.coerce_tag) |tag| {
                    try self.emitFmt(".{{ ._{s} = ", .{tag});
                    try self.generateExprMir(m);
                    try self.emit(" }");
                } else {
                    try self.generateExprMir(m);
                }
            },
            .optional_unwrap => {
                try self.generateExprMir(m);
                try self.emit(".some");
            },
        }
    }

    /// Check if a MirNode represents a string expression (via type_class or AST kind).
    fn mirIsString(m: *const mir.MirNode) bool {
        return m.type_class == .string or m.ast.* == .string_literal or m.ast.* == .interpolated_string;
    }

    /// Check if a MirNode is typed as a bitfield, return the bitfield name.
    fn mirGetBitfieldName(m: *const mir.MirNode, decls_opt: ?*declarations.DeclTable) ?[]const u8 {
        const d = decls_opt orelse return null;
        if (m.resolved_type == .named) {
            if (d.bitfields.contains(m.resolved_type.named)) return m.resolved_type.named;
        }
        return null;
    }

    // Generate a while continue expression — same as assignment but no trailing semicolon.
    fn generateContinueExpr(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* == .assignment) {
            const a = node.assignment;
            if (std.mem.eql(u8, a.op, "/=")) {
                try self.generateExpr(a.left);
                try self.emit(" = @divTrunc(");
                try self.generateExpr(a.left);
                try self.emit(", ");
                try self.generateExpr(a.right);
                try self.emit(")");
            } else {
                try self.generateExpr(a.left);
                try self.emitFmt(" {s} ", .{a.op});
                try self.generateExpr(a.right);
            }
        } else {
            try self.generateExpr(node);
        }
    }

    fn writeRangeExpr(self: *CodeGen, r: parser.BinaryOp) anyerror!void {
        // Zig for-range endpoints must be usize. Cast non-literal values.
        const left_is_literal = r.left.* == .int_literal;
        if (left_is_literal) {
            try self.generateExpr(r.left);
        } else {
            try self.emit("@intCast(");
            try self.generateExpr(r.left);
            try self.emit(")");
        }
        try self.emit("..");
        const right_is_literal = r.right.* == .int_literal;
        if (right_is_literal) {
            try self.generateExpr(r.right);
        } else {
            try self.emit("@intCast(");
            try self.generateExpr(r.right);
            try self.emit(")");
        }
    }


    /// Desugar a type match on (Error|T), (null|T), or arbitrary union into a Zig switch.
    /// match result { Error => { } i32 => { } }
    /// → switch (result) { .err => { }, .ok => { } }
    /// match val { i32 => { } f32 => { } }
    /// → switch (val) { ._i32 => { }, ._f32 => { } }
    fn generateTypeMatch(self: *CodeGen, m: parser.MatchStmt, is_null_union: bool) anyerror!void {
        // Detect arbitrary union (no Error/null arms)
        const is_arbitrary = blk: {
            for (m.arms) |arm| {
                if (arm.* != .match_arm) continue;
                const pat = arm.match_arm.pattern;
                if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, K.Type.ERROR)) break :blk false;
                if (pat.* == .null_literal) break :blk false;
            }
            break :blk true;
        };

        try self.emit("switch (");
        try self.generateExpr(m.value);
        try self.emit(") {\n");
        self.indent += 1;

        for (m.arms) |arm| {
            if (arm.* != .match_arm) continue;
            const pat = arm.match_arm.pattern;
            try self.emitIndent();

            if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, K.Type.ERROR)) {
                // Error arm → .err
                try self.emit(".err");
            } else if (pat.* == .null_literal) {
                // null arm → .none
                try self.emit(".none");
            } else if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                // catch-all
                try self.emit("else");
            } else if (is_arbitrary and pat.* == .identifier) {
                // Arbitrary union arm: i32 → ._i32
                try self.emitFmt("._{s}", .{pat.identifier});
            } else {
                // The value type arm → .ok (error union) or .some (null union)
                if (is_null_union) {
                    try self.emit(".some");
                } else {
                    try self.emit(".ok");
                }
            }

            try self.emit(" => ");
            // Set narrowing for the match value inside the arm body
            const match_var = if (m.value.* == .identifier) m.value.identifier else null;
            if (match_var) |vname| {
                if (is_arbitrary and pat.* == .identifier and
                    !std.mem.eql(u8, pat.identifier, "else"))
                {
                    try self.type_narrowed_vars.put(self.allocator, vname, pat.identifier);
                }
            }
            try self.generateBlock(arm.match_arm.body);
            if (match_var) |vname| _ = self.type_narrowed_vars.remove(vname);
            try self.emit(",\n");
        }

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}");
    }

    /// Generate string interpolation using std.fmt.allocPrint.
    /// "hello @{name}, value @{x}!" →
    ///   std.fmt.allocPrint(_rt.alloc, "hello {s}, value {}", .{name, x}) catch unreachable
    fn generateInterpolatedString(self: *CodeGen, interp: parser.InterpolatedString) anyerror!void {
        try self.emit("std.fmt.allocPrint(_rt.alloc, \"");
        // Build format string
        for (interp.parts) |part| {
            switch (part) {
                .literal => |text| {
                    // Escape any braces and special chars in the literal
                    for (text) |ch| {
                        switch (ch) {
                            '{' => try self.emit("{{"),
                            '}' => try self.emit("}}"),
                            '\\' => try self.emit("\\"),
                            else => {
                                const buf: [1]u8 = .{ch};
                                try self.emit(&buf);
                            },
                        }
                    }
                },
                .expr => |node| {
                    if (self.isStringExpr(node)) {
                        try self.emit("{s}");
                    } else {
                        try self.emit("{}");
                    }
                },
            }
        }
        try self.emit("\", .{");
        // Build args tuple
        var first = true;
        for (interp.parts) |part| {
            switch (part) {
                .literal => {},
                .expr => |node| {
                    if (!first) try self.emit(", ");
                    try self.generateExpr(node);
                    first = false;
                },
            }
        }
        try self.emit("}) catch unreachable");
    }

    /// Desugar a string match into an if/else chain.
    /// match s { "hello" => { } "world" => { } else => { } }
    /// → if (std.mem.eql(u8, s, "hello")) { } else if (...) { } else { }
    fn generateStringMatch(self: *CodeGen, m: parser.MatchStmt) anyerror!void {
        var first = true;
        var wildcard_body: ?*parser.Node = null;

        for (m.arms) |arm| {
            if (arm.* != .match_arm) continue;
            const pat = arm.match_arm.pattern;
            const body = arm.match_arm.body;

            // Wildcard (else) — save for the final else
            if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                wildcard_body = body;
                continue;
            }

            if (first) {
                try self.emit("if (std.mem.eql(u8, ");
                first = false;
            } else {
                try self.emit(" else if (std.mem.eql(u8, ");
            }

            // The value being matched
            if (m.value.* == .identifier and std.mem.eql(u8, m.value.identifier, "self")) {
                try self.emit("self.*");
            } else {
                try self.generateExpr(m.value);
            }
            try self.emit(", ");
            try self.generateExpr(pat);
            try self.emit(")) ");
            try self.generateBlock(body);
        }

        if (wildcard_body) |wb| {
            if (first) {
                // All arms were wildcards — just emit the body
                try self.generateBlock(wb);
            } else {
                try self.emit(" else ");
                try self.generateBlock(wb);
            }
        } else if (!first) {
            // No wildcard — close with empty else to be safe
            try self.emit(" else {}");
        }
    }

    fn generateWrappingExpr(self: *CodeGen, arg: *parser.Node) anyerror!void {
        if (arg.* == .binary_expr) {
            const b = arg.binary_expr;
            const wrap_op: ?[]const u8 =
                if (std.mem.eql(u8, b.op, "+")) "+%"
                else if (std.mem.eql(u8, b.op, "-")) "-%"
                else if (std.mem.eql(u8, b.op, "*")) "*%"
                else null;
            if (wrap_op) |op| {
                try self.generateExpr(b.left);
                try self.emitFmt(" {s} ", .{op});
                try self.generateExpr(b.right);
                return;
            }
        }
        try self.generateExpr(arg);
    }

    fn generateSaturatingExpr(self: *CodeGen, arg: *parser.Node) anyerror!void {
        if (arg.* == .binary_expr) {
            const b = arg.binary_expr;
            const sat_op: ?[]const u8 =
                if (std.mem.eql(u8, b.op, "+")) "+|"
                else if (std.mem.eql(u8, b.op, "-")) "-|"
                else if (std.mem.eql(u8, b.op, "*")) "*|"
                else null;
            if (sat_op) |op| {
                try self.generateExpr(b.left);
                try self.emitFmt(" {s} ", .{op});
                try self.generateExpr(b.right);
                return;
            }
        }
        try self.generateExpr(arg);
    }

    fn generateOverflowExpr(self: *CodeGen, arg: *parser.Node) anyerror!void {
        if (arg.* == .binary_expr) {
            const b = arg.binary_expr;
            const builtin_name: ?[]const u8 =
                if (std.mem.eql(u8, b.op, "+")) "@addWithOverflow"
                else if (std.mem.eql(u8, b.op, "-")) "@subWithOverflow"
                else if (std.mem.eql(u8, b.op, "*")) "@mulWithOverflow"
                else null;
            if (builtin_name) |builtin| {
                // overflow(a + b) → (blk: { const _ov = @addWithOverflow(a, b);
                //   if (_ov[1] != 0) break :blk _rt.OrhonResult(@TypeOf(a)){ .err = .{ .message = "overflow" } }
                //   else break :blk _rt.OrhonResult(@TypeOf(a)){ .ok = _ov[0] }; })
                // When operands are literals, @TypeOf gives comptime_int which Zig rejects.
                // Use the concrete type from the enclosing decl's type_ctx if available.
                const left_is_literal = b.left.* == .int_literal or b.left.* == .float_literal;
                const type_str: ?[]const u8 = if (left_is_literal) blk: {
                    if (self.type_ctx) |ctx| {
                        if (extractValueType(ctx)) |vt| break :blk try self.typeToZig(vt);
                    }
                    break :blk null;
                } else null;

                try self.emit("(blk: { const _ov = ");
                try self.emitFmt("{s}(", .{builtin});
                if (type_str) |ts| {
                    try self.emitFmt("@as({s}, ", .{ts});
                    try self.generateExpr(b.left);
                    try self.emit(")");
                } else {
                    try self.generateExpr(b.left);
                }
                try self.emit(", ");
                try self.generateExpr(b.right);
                if (type_str) |ts| {
                    try self.emit("); if (_ov[1] != 0) break :blk _rt.OrhonResult(");
                    try self.emit(ts);
                    try self.emit("){ .err = .{ .message = \"overflow\" } } else break :blk _rt.OrhonResult(");
                    try self.emit(ts);
                    try self.emit("){ .ok = _ov[0] }; })");
                } else {
                    try self.emit("); if (_ov[1] != 0) break :blk _rt.OrhonResult(@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.emit(")){ .err = .{ .message = \"overflow\" } } else break :blk _rt.OrhonResult(@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.emit(")){ .ok = _ov[0] }; })");
                }
                return;
            }
        }
        try self.generateExpr(arg);
    }

    fn generateCompilerFunc(self: *CodeGen, cf: parser.CompilerFunc) anyerror!void {
        // Map Orhon compiler functions to Zig equivalents
        if (std.mem.eql(u8, cf.name, "typename")) {
            // typename(x) → @typeName(@TypeOf(x))
            try self.emit("@typeName(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit("))");
        } else if (std.mem.eql(u8, cf.name, "typeid")) {
            // typeid(x) → _rt.orhonTypeId(@TypeOf(x))
            try self.emit("_rt.orhonTypeId(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit("))");
        } else if (std.mem.eql(u8, cf.name, "typeOf")) {
            // typeOf(x) → @TypeOf(x)
            try self.emit("@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf.name, "cast")) {
            // cast(T, x) → Zig cast depending on target and source types:
            //   int target,   float source literal: @as(T, @intFromFloat(x))
            //   int target,   other source:          @as(T, @intCast(x))
            //   float target, float source:          @as(T, @floatCast(x))
            //   float target, other source:          @as(T, @floatFromInt(x))
            if (cf.args.len >= 2) {
                const target_type = try self.typeToZig(cf.args[0]);
                const target_is_float = target_type.len > 0 and target_type[0] == 'f';
                const source_is_float_literal = cf.args[1].* == .float_literal;
                try self.emitFmt("@as({s}, ", .{target_type});
                if (target_is_float and source_is_float_literal) {
                    // float literal to float type — direct cast
                    try self.emit("@floatCast(");
                } else if (target_is_float) {
                    try self.emit("@floatFromInt(");
                } else if (source_is_float_literal) {
                    try self.emit("@intFromFloat(");
                } else {
                    try self.emit("@intCast(");
                }
                try self.generateExpr(cf.args[1]);
                try self.emit("))");
            } else if (cf.args.len == 1) {
                try self.emit("@intCast(");
                try self.generateExpr(cf.args[0]);
                try self.emit(")");
            }
        } else if (std.mem.eql(u8, cf.name, "size")) {
            // size(T) → @sizeOf(T)
            try self.emit("@sizeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf.name, "align")) {
            // align(T) → @alignOf(T)
            try self.emit("@alignOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf.name, "copy")) {
            // copy(x) — for non-primitives, generate a copy
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
        } else if (std.mem.eql(u8, cf.name, "move")) {
            // move(x) — explicit move, same as value in Zig
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
        } else if (std.mem.eql(u8, cf.name, "assert")) {
            if (self.in_test_block) {
                try self.emit("try std.testing.expect(");
            } else {
                try self.emit("std.debug.assert(");
            }
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf.name, "swap")) {
            // swap(a, b) → std.mem.swap(@TypeOf(a), &a, &b)
            if (cf.args.len == 2) {
                try self.emit("std.mem.swap(@TypeOf(");
                try self.generateExpr(cf.args[0]);
                try self.emit("), &");
                try self.generateExpr(cf.args[0]);
                try self.emit(", &");
                try self.generateExpr(cf.args[1]);
                try self.emit(")");
            }
        } else {
            try self.emitFmt("/* unknown @{s} */", .{cf.name});
        }
    }

    fn generatePtrExpr(self: *CodeGen, p: parser.PtrExpr) anyerror!void {
        if (std.mem.eql(u8, p.kind, "Ptr")) {
            // Ptr(T, &x) → &x  (safe const pointer, ownership tracked)
            try self.generateExpr(p.addr_arg);
        } else if (std.mem.eql(u8, p.kind, "RawPtr")) {
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
                self.warned_rawptr = true;
            }
            const zig_type = try self.typeToZig(p.type_arg);
            if (p.addr_arg.* == .borrow_expr) {
                // RawPtr(T, &x) → @as([*]T, @ptrCast(&x))
                try self.emitFmt("@as([*]{s}, @ptrCast(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.emit("))");
            } else {
                // RawPtr(T, 0xB8000) → @as([*]T, @ptrFromInt(addr))
                try self.emitFmt("@as([*]{s}, @ptrFromInt(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.emit("))");
            }
        } else if (std.mem.eql(u8, p.kind, "VolatilePtr")) {
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: VolatilePtr used — unsafe, hardware access only\n", .{});
                self.warned_rawptr = true;
            }
            const zig_type = try self.typeToZig(p.type_arg);
            if (p.addr_arg.* == .borrow_expr) {
                // VolatilePtr(T, &x) → @as(*volatile T, @ptrCast(&x))
                try self.emitFmt("@as(*volatile {s}, @ptrCast(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.emit("))");
            } else {
                // VolatilePtr(T, 0xFF200000) → @as(*volatile T, @ptrFromInt(addr))
                try self.emitFmt("@as(*volatile {s}, @ptrFromInt(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.emit("))");
            }
        }
    }


    /// Write the allocator argument for an allocating string method.
    /// Last arg is allocator if it's a mem.* call, otherwise default to smp_allocator.
    /// Fill in default argument values when a call provides fewer args than the function expects.
    fn fillDefaultArgs(self: *CodeGen, c: parser.CallExpr) anyerror!void {
        const func_name: []const u8 = if (c.callee.* == .identifier)
            c.callee.identifier
        else if (c.callee.* == .field_expr)
            c.callee.field_expr.field
        else
            return;

        // Look up function signature — first in current module, then imported modules
        var fsig: ?declarations.FuncSig = null;
        if (self.decls) |d| {
            fsig = d.funcs.get(func_name);
        }
        if (fsig == null) {
            // Cross-module call: module.func() — look up in imported module's decls
            if (c.callee.* == .field_expr) {
                const module_name = if (c.callee.field_expr.object.* == .identifier)
                    c.callee.field_expr.object.identifier
                else if (c.callee.field_expr.object.* == .field_expr)
                    // module.Type.method — get the module name
                    if (c.callee.field_expr.object.field_expr.object.* == .identifier)
                        c.callee.field_expr.object.field_expr.object.identifier
                    else
                        null
                else
                    null;
                if (module_name) |mn| {
                    if (self.all_decls) |ad| {
                        if (ad.get(mn)) |mod_decls| {
                            fsig = mod_decls.funcs.get(func_name);
                        }
                    }
                }
            }
        }

        const sig = fsig orelse return;
        if (c.args.len >= sig.param_nodes.len) return;
        var wrote_any = c.args.len > 0;
        for (sig.param_nodes[c.args.len..]) |p| {
            if (p.* == .param) {
                if (p.param.default_value) |dv| {
                    if (wrote_any) try self.emit(", ");
                    try self.generateExpr(dv);
                    wrote_any = true;
                }
            }
        }
    }

    /// Generate a shared-allocator collection expression (named alloc only).
    /// Unmanaged API: emit .{} — allocator is passed to each method call, not stored.
    /// Collections use the unmanaged API: .{} init, allocator passed to each method.
    fn generateCollectionExpr(self: *CodeGen, c: parser.CollectionExpr) anyerror!void {
        _ = c.alloc_arg; // allocator tracked at declaration level, not embedded in init
        // All unmanaged collections zero-initialize: the type annotation carries the type.
        try self.emit(".{}");
    }

    // ============================================================
    // TYPE TRANSLATION
    // ============================================================

    /// Allocate a type string and track it for cleanup
    fn allocTypeStr(self: *CodeGen, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.type_strings.append(self.allocator, s);
        return s;
    }

    fn typeToZig(self: *CodeGen, node: *parser.Node) ![]const u8 {
        return switch (node.*) {
            .type_named => |name| {
                if (std.mem.eql(u8, name, K.Type.ERROR)) return "_rt.OrhonError";
                // Inside a generic struct, self-references use @This()
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, name, gsn)) return "@This()";
                }
                return builtins.primitiveToZig(name);
            },
            .type_slice => |elem| blk: {
                const inner = try self.typeToZig(elem);
                break :blk try self.allocTypeStr("[]{s}", .{inner});
            },
            .type_array => |a| blk: {
                const inner = try self.typeToZig(a.elem);
                const size_text = if (a.size.* == .int_literal) a.size.int_literal else "0";
                break :blk try self.allocTypeStr("[{s}]{s}", .{ size_text, inner });
            },
            .type_union => |u| blk: {
                var has_error = false;
                var has_null = false;
                for (u) |t| {
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) has_error = true;
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) has_null = true;
                }
                if (has_error or has_null) {
                    // Find the non-Error/non-null type
                    for (u) |t| {
                        if (t.* == .type_named and
                            !std.mem.eql(u8, t.type_named, K.Type.ERROR) and
                            !std.mem.eql(u8, t.type_named, K.Type.NULL))
                        {
                            const inner = try self.typeToZig(t);
                            if (has_error) break :blk try self.allocTypeStr("_rt.OrhonResult({s})", .{inner});
                            if (has_null) break :blk try self.allocTypeStr("_rt.OrhonNullable({s})", .{inner});
                        }
                    }
                }
                // Arbitrary union: (i32 | f32 | String) → union(enum) { _i32: i32, _f32: f32, _String: []const u8 }
                var buf = std.ArrayListUnmanaged(u8){};
                defer buf.deinit(self.allocator);
                try buf.appendSlice(self.allocator, "union(enum) { ");
                for (u) |t| {
                    const zig_type = try self.typeToZig(t);
                    const type_name = if (t.* == .type_named) t.type_named else zig_type;
                    try buf.writer(self.allocator).print("_{s}: {s}, ", .{ type_name, zig_type });
                }
                try buf.appendSlice(self.allocator, "}");
                break :blk try self.allocTypeStr("{s}", .{buf.items});
            },
            .type_ptr => |p| blk: {
                if (std.mem.eql(u8, p.kind, K.Ptr.CONST_REF)) {
                    const inner = try self.typeToZig(p.elem);
                    break :blk try self.allocTypeStr("*const {s}", .{inner});
                } else if (std.mem.eql(u8, p.kind, K.Ptr.VAR_REF)) {
                    const inner = try self.typeToZig(p.elem);
                    break :blk try self.allocTypeStr("*{s}", .{inner});
                }
                break :blk "?*anyopaque";
            },
            .type_func => |f| blk: {
                var params_str = std.ArrayListUnmanaged(u8){};
                defer params_str.deinit(self.allocator);
                for (f.params, 0..) |p, i| {
                    if (i > 0) try params_str.appendSlice(self.allocator, ", ");
                    try params_str.appendSlice(self.allocator, try self.typeToZig(p));
                }
                const ret = try self.typeToZig(f.ret);
                break :blk try self.allocTypeStr("*const fn ({s}) {s}",
                    .{ params_str.items, ret });
            },
            .type_generic => |g| blk: {
                if (std.mem.eql(u8, g.name, "Thread")) {
                    break :blk "std.Thread"; // Thread handle type
                } else if (std.mem.eql(u8, g.name, "Async")) {
                    break :blk "void"; // Async not yet implemented
                } else if (std.mem.eql(u8, g.name, "Handle")) {
                    // Handle(T) → _rt.OrhonHandle(zigT)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("_rt.OrhonHandle({s})", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Ptr")) {
                    // Ptr(T) → *const T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("*const {s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "RawPtr")) {
                    // RawPtr(T) → [*]T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]{s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "VolatilePtr")) {
                    // VolatilePtr(T) → [*]volatile T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]volatile {s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Ring")) {
                    if (g.args.len >= 2) {
                        const inner = try self.typeToZig(g.args[0]);
                        const size_str = if (g.args[1].* == .int_literal) g.args[1].int_literal else "0";
                        break :blk try self.allocTypeStr("OrhonRing({s}, {s})", .{ inner, size_str });
                    }
                } else if (std.mem.eql(u8, g.name, "ORing")) {
                    if (g.args.len >= 2) {
                        const inner = try self.typeToZig(g.args[0]);
                        const size_str = if (g.args[1].* == .int_literal) g.args[1].int_literal else "0";
                        break :blk try self.allocTypeStr("OrhonORing({s}, {s})", .{ inner, size_str });
                    }
                }
                // Collection types → _collections.Name(zigT, ...)
                const is_collection = std.mem.eql(u8, g.name, "List") or
                    std.mem.eql(u8, g.name, "Map") or
                    std.mem.eql(u8, g.name, "Set");

                // User-defined generic type — Name(T, U) → Name(zigT, zigU)
                if (g.args.len > 0) {
                    var buf = std.ArrayListUnmanaged(u8){};
                    defer buf.deinit(self.allocator);
                    if (is_collection) try buf.appendSlice(self.allocator, "_collections.");
                    try buf.appendSlice(self.allocator, g.name);
                    try buf.append(self.allocator, '(');
                    for (g.args, 0..) |arg, ai| {
                        if (ai > 0) try buf.appendSlice(self.allocator, ", ");
                        const zig_type = try self.typeToZig(arg);
                        try buf.appendSlice(self.allocator, zig_type);
                    }
                    try buf.append(self.allocator, ')');
                    break :blk try self.allocTypeStr("{s}", .{buf.items});
                }
                break :blk g.name;
            },
            .type_tuple_named => |fields| blk: {
                var buf = std.ArrayListUnmanaged(u8){};
                defer buf.deinit(self.allocator);
                try buf.appendSlice(self.allocator, "struct { ");
                for (fields) |f| {
                    const ft = try self.typeToZig(f.type_node);
                    try buf.writer(self.allocator).print("{s}: {s}, ", .{ f.name, ft });
                }
                try buf.appendSlice(self.allocator, "}");
                break :blk try self.allocTypeStr("{s}", .{buf.items});
            },
            .type_tuple_anon => |types| blk: {
                var buf = std.ArrayListUnmanaged(u8){};
                defer buf.deinit(self.allocator);
                try buf.appendSlice(self.allocator, "struct { ");
                for (types, 0..) |t, i| {
                    const ft = try self.typeToZig(t);
                    try buf.writer(self.allocator).print("@\"{d}\": {s}, ", .{ i, ft });
                }
                try buf.appendSlice(self.allocator, "}");
                break :blk try self.allocTypeStr("{s}", .{buf.items});
            },
            // cast(i64, x) — type arg parsed as identifier by parseExpr
            .identifier => |name| builtins.primitiveToZig(name),
            else => "anyopaque",
        };
    }
};

fn opToZig(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "and")) return "and";
    if (std.mem.eql(u8, op, "or")) return "or";
    if (std.mem.eql(u8, op, "not")) return "!";
    return op; // most operators are the same in Zig
}

/// Check if a field name is a type name used for union value access (result.i32, result.User)
fn isResultValueField(name: []const u8, decls: ?*declarations.DeclTable) bool {
    // Primitive type names — always valid as union payload access
    const primitives = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "isize", "usize",
        "f16", "bf16", "f32", "f64", "f128",
        "bool", "String", "void",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    // Known user-defined types from the declaration table
    if (decls) |d| {
        if (d.structs.contains(name)) return true;
        if (d.enums.contains(name)) return true;
        if (d.bitfields.contains(name)) return true;
    }
    // Builtin types that can appear in unions
    if (builtins.isBuiltinType(name)) return true;
    return false;
}

test "codegen - simple program" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    // Build a minimal AST
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };

    const block = try a.create(parser.Node);
    block.* = .{ .block = .{ .statements = &.{} } };

    const func = try a.create(parser.Node);
    func.* = .{ .func_decl = .{
        .name = "main",
        .params = &.{},
        .return_type = ret_type,
        .body = block,
        .is_compt = false,
        .is_pub = false,
        .is_bridge = false,
        .is_thread = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    try gen.generate(prog, "main");
    try std.testing.expect(!reporter.hasErrors());
    const output = gen.getOutput();
    try std.testing.expect(output.len > 0);
    // main must be pub — Zig requires pub fn main for executables
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn main()") != null);
}

test "codegen - runtime import in preamble" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const block = try a.create(parser.Node);
    block.* = .{ .block = .{ .statements = &.{} } };
    const func = try a.create(parser.Node);
    func.* = .{ .func_decl = .{
        .name = "main",
        .params = &.{},
        .return_type = ret_type,
        .body = block,
        .is_compt = false,
        .is_pub = false,
        .is_bridge = false,
        .is_thread = false,
    }};
    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    try gen.generate(prog, "main");
    try std.testing.expect(!reporter.hasErrors());
    const output = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "@import(\"_orhon_rt\")") != null);
}

test "codegen - type to zig" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var str_type = parser.Node{ .type_named = "String" };
    try std.testing.expectEqualStrings("[]const u8", try gen.typeToZig(&str_type));

    var i32_type = parser.Node{ .type_named = "i32" };
    try std.testing.expectEqualStrings("i32", try gen.typeToZig(&i32_type));

    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "i32" };
    var slice_type = parser.Node{ .type_slice = elem };
    const slice_zig = try gen.typeToZig(&slice_type);
    try std.testing.expectEqualStrings("[]i32", slice_zig);
}

test "codegen - bridge func emits re-export" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };

    // empty block placeholder — bridge func body is never used
    const empty_block = try a.create(parser.Node);
    empty_block.* = .{ .block = .{ .statements = &.{} } };

    const func = try a.create(parser.Node);
    func.* = .{ .func_decl = .{
        .name = "print",
        .params = &.{},
        .return_type = ret_type,
        .body = empty_block,
        .is_compt = false,
        .is_pub = true,
        .is_bridge = true,
        .is_thread = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "console" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    try gen.generate(prog, "console");
    try std.testing.expect(!reporter.hasErrors());

    // bridge func should re-export from sidecar, not emit a function definition
    const output = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "fn print(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "console_bridge.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const print =") != null);
}

test "codegen - scoped import generates correct @import" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const imp = try a.create(parser.Node);
    imp.* = .{ .import_decl = .{
        .path = "console",
        .scope = "std",
        .alias = null,
        .is_c_header = false,
    }};

    const imports = try a.alloc(*parser.Node, 1);
    imports[0] = imp;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = imports,
        .top_level = &.{},
    }};

    try gen.generate(prog, "main");
    try std.testing.expect(!reporter.hasErrors());
    const output = gen.getOutput();
    // alias defaults to module name "console", not scope "std"
    try std.testing.expect(std.mem.indexOf(u8, output, "const console = @import(\"console.zig\")") != null);
}

test "codegen - overflow helpers wrap/sat/overflow" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: func check(x: i32, y: i32) i32 { return wrap(x + y) }
    const id_x = try a.create(parser.Node);
    id_x.* = .{ .identifier = "x" };
    const id_y = try a.create(parser.Node);
    id_y.* = .{ .identifier = "y" };
    const id_x2 = try a.create(parser.Node);
    id_x2.* = .{ .identifier = "x" };
    const id_y2 = try a.create(parser.Node);
    id_y2.* = .{ .identifier = "y" };
    const id_x3 = try a.create(parser.Node);
    id_x3.* = .{ .identifier = "x" };
    const id_y3 = try a.create(parser.Node);
    id_y3.* = .{ .identifier = "y" };

    const bin_add = try a.create(parser.Node);
    bin_add.* = .{ .binary_expr = .{ .op = "+", .left = id_x, .right = id_y } };
    const bin_add2 = try a.create(parser.Node);
    bin_add2.* = .{ .binary_expr = .{ .op = "+", .left = id_x2, .right = id_y2 } };
    const bin_add3 = try a.create(parser.Node);
    bin_add3.* = .{ .binary_expr = .{ .op = "+", .left = id_x3, .right = id_y3 } };

    // wrap(x + y)
    const wrap_callee = try a.create(parser.Node);
    wrap_callee.* = .{ .identifier = "wrap" };
    const wrap_args = try a.alloc(*parser.Node, 1);
    wrap_args[0] = bin_add;
    const wrap_call = try a.create(parser.Node);
    wrap_call.* = .{ .call_expr = .{ .callee = wrap_callee, .args = wrap_args, .arg_names = &.{} } };

    // sat(x + y)
    const sat_callee = try a.create(parser.Node);
    sat_callee.* = .{ .identifier = "sat" };
    const sat_args = try a.alloc(*parser.Node, 1);
    sat_args[0] = bin_add2;
    const sat_call = try a.create(parser.Node);
    sat_call.* = .{ .call_expr = .{ .callee = sat_callee, .args = sat_args, .arg_names = &.{} } };

    // overflow(x + y)
    const ov_callee = try a.create(parser.Node);
    ov_callee.* = .{ .identifier = "overflow" };
    const ov_args = try a.alloc(*parser.Node, 1);
    ov_args[0] = bin_add3;
    const ov_call = try a.create(parser.Node);
    ov_call.* = .{ .call_expr = .{ .callee = ov_callee, .args = ov_args, .arg_names = &.{} } };

    // Verify wrap codegen
    gen.output.clearRetainingCapacity();
    try gen.generateExpr(wrap_call);
    const wrap_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, wrap_out, "+%") != null);

    // Verify sat codegen
    gen.output.clearRetainingCapacity();
    try gen.generateExpr(sat_call);
    const sat_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, sat_out, "+|") != null);

    // Verify overflow codegen uses @addWithOverflow and OrhonResult
    gen.output.clearRetainingCapacity();
    try gen.generateExpr(ov_call);
    const ov_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, ov_out, "@addWithOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, ov_out, "_rt.OrhonResult") != null);
}

// BRIDGE TODO: string method codegen test removed — string methods now go through bridge
