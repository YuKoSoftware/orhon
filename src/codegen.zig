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
    file_offsets: []const module.FileOffset, // combined-line → original file+line
    module_builds: ?*const std.StringHashMapUnmanaged(module.BuildType), // imported module → build type
    // Track variables narrowed by `is Error` or `is null` checks — used to resolve
    // `.value` unwrap when MIR type classification is unavailable (cross-module calls).
    error_narrowed: std.StringHashMapUnmanaged(void) = .{},
    null_narrowed: std.StringHashMapUnmanaged(void) = .{},
    // Track the captured error variable name per scope for `.Error` → `@errorName()`
    error_capture_var: std.StringHashMapUnmanaged([]const u8) = .{},
    // Import alias tracking — use the user's import name instead of hardcoded prefixes
    str_import_alias: ?[]const u8 = null,
    str_is_included: bool = false,
    collections_import_alias: ?[]const u8 = null,
    collections_is_included: bool = false,
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

    /// Sanitize an error message string literal into a Zig error name.
    /// Strips quotes, replaces spaces/non-identifier chars with underscores.
    /// "division by zero" → error.division_by_zero
    fn sanitizeErrorName(self: *CodeGen, msg: []const u8) ![]const u8 {
        // Strip surrounding quotes if present
        const raw = if (msg.len >= 2 and msg[0] == '"' and msg[msg.len - 1] == '"')
            msg[1 .. msg.len - 1]
        else
            msg;
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        for (raw) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                try buf.append(self.allocator, ch);
            } else if (ch == ' ' or ch == '-') {
                if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '_')
                    try buf.append(self.allocator, '_');
            }
        }
        // Trim trailing underscores
        while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_')
            buf.items.len -= 1;
        if (buf.items.len == 0) try buf.appendSlice(self.allocator, "unknown_error");
        return try self.allocTypeStr("{s}", .{buf.items});
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
            .file_offsets = &.{},
            .module_builds = null,
        };
    }

    fn nodeLoc(self: *const CodeGen, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                const resolved = module.resolveFileLoc(self.file_offsets, loc.line);
                return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
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
        self.error_narrowed.deinit(self.allocator);
        self.null_narrowed.deinit(self.allocator);
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

        // File header — only Zig std, no runtime libraries
        try self.emitFmt("// generated from module {s} — do not edit\n", .{module_name});
        try self.emit("const std = @import(\"std\");\n");

        // Generate imports — deduplicate across files in the same module
        // (multiple .orh files can import the same dependency)
        var seen_imports = std.StringHashMap(void).init(self.allocator);
        defer seen_imports.deinit();
        for (ast.program.imports) |imp| {
            if (imp.* != .import_decl) continue;
            const alias = imp.import_decl.alias orelse imp.import_decl.path;
            const gop = try seen_imports.getOrPut(alias);
            if (!gop.found_existing) {
                try self.generateImport(imp);
            }
        }

        // Auto-import str and collections if not explicitly imported.
        // These modules are always available via build.zig addImport — no
        // import needed in user code, but the generated Zig file needs them
        // if string/collection operations are used implicitly (e.g., String methods).
        if (self.str_import_alias == null and !self.str_is_included) {
            self.str_import_alias = "str";
            try self.emit("const str = @import(\"_orhon_str\");\n");
        }
        if (self.collections_import_alias == null and !self.collections_is_included) {
            self.collections_import_alias = "collections";
            try self.emit("const collections = @import(\"_orhon_collections\");\n");
        }

        try self.emit("\n");

        // Emit _OrhonHandle helper for thread handle types (comptime, zero cost if unused)
        try self.emit("fn _OrhonHandle(comptime T: type) type { return struct { thread: std.Thread, state: *SharedState, pub const SharedState = struct { result: T = undefined, completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false) }; const Self = @This(); pub fn getValue(self_h: *Self) T { self_h.thread.join(); const result = self_h.state.result; std.heap.page_allocator.destroy(self_h.state); return result; } pub fn wait(self_h: *Self) void { self_h.thread.join(); } pub fn done(self_h: *const Self) bool { return self_h.state.completed.load(.acquire); } pub fn join(self_h: *Self) void { self_h.thread.join(); std.heap.page_allocator.destroy(self_h.state); } }; }\n\n");

        // Generate top-level declarations from MIR tree
        const root = self.mir_root orelse return error.CompileError;
        for (root.children) |m| {
            try self.generateTopLevelMir(m);
            try self.emit("\n");
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

    /// Check if an expression is known to be a string (literal, interpolation, or MIR-typed)
    fn isStringExpr(self: *const CodeGen, node: *parser.Node) bool {
        return switch (node.*) {
            .string_literal, .interpolated_string => true,
            else => self.getTypeClass(node) == .string,
        };
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

    /// MIR-path: wrap a MirNode expression in an arbitrary union tag.
    fn generateArbitraryUnionWrappedExprMir(self: *CodeGen, m: *mir.MirNode, members_rt: ?[]const RT) anyerror!void {
        if (m.coercion) |_| {
            try self.generateCoercedExprMir(m);
            return;
        }
        const tag = inferArbitraryUnionTagMir(m, members_rt);
        if (tag) |t| {
            try self.emitFmt(".{{ ._{s} = ", .{t});
            try self.generateExprMir(m);
            try self.emit(" }");
        } else {
            try self.generateExprMir(m);
        }
    }

    /// Infer union tag from MirNode literal_kind.
    fn inferArbitraryUnionTagMir(m: *const mir.MirNode, members_rt: ?[]const RT) ?[]const u8 {
        const lk = m.literal_kind orelse return null;
        return switch (lk) {
            .int => findMemberByKind(members_rt, .int) orelse "i32",
            .float => findMemberByKind(members_rt, .float) orelse "f32",
            .string => findMemberByKind(members_rt, .string) orelse "String",
            .bool_lit => findMemberByKind(members_rt, .bool_) orelse "bool",
            else => null,
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

        if (imp.is_c_header) {
            const alias = imp.alias orelse imp.path;
            try self.emitLineFmt("// WARNING: C header import\nconst {s} = @cImport(@cInclude({s}));", .{ alias, imp.path });
            return;
        }

        // Check if the imported module is a lib target — if so, use build-system
        // module name (no .zig extension) since it's provided via addImport in build.zig
        const is_lib = if (self.module_builds) |mb| blk: {
            const bt = mb.get(imp.path) orelse break :blk false;
            break :blk bt == .static or bt == .dynamic;
        } else false;

        const ext = if (is_lib) "" else ".zig";

        // Track import aliases for str and collections
        if (std.mem.eql(u8, imp.path, "str")) {
            if (imp.is_include) {
                self.str_is_included = true;
            } else {
                self.str_import_alias = imp.alias orelse "str";
            }
        } else if (std.mem.eql(u8, imp.path, "collections")) {
            if (imp.is_include) {
                self.collections_is_included = true;
            } else {
                self.collections_import_alias = imp.alias orelse "collections";
            }
        }

        if (imp.is_include) {
            // include — dump all symbols into local namespace via individual re-exports
            const hidden = try std.fmt.allocPrint(self.allocator, "_included_{s}", .{imp.path});
            defer self.allocator.free(hidden);
            try self.emitLineFmt("const {s} = @import(\"{s}{s}\");", .{ hidden, imp.path, ext });
            // Re-export each known declaration from the included module
            if (self.all_decls) |ad| {
                if (ad.get(imp.path)) |dt| {
                    var func_iter = dt.funcs.iterator();
                    while (func_iter.next()) |entry| {
                        try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var struct_iter = dt.structs.iterator();
                    while (struct_iter.next()) |entry| {
                        try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var enum_iter = dt.enums.iterator();
                    while (enum_iter.next()) |entry| {
                        try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var bitfield_iter = dt.bitfields.iterator();
                    while (bitfield_iter.next()) |entry| {
                        try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var var_iter = dt.vars.iterator();
                    while (var_iter.next()) |entry| {
                        try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                }
            }
        } else {
            // import — namespaced access
            const alias = imp.alias orelse imp.path;
            try self.emitLineFmt("const {s} = @import(\"{s}{s}\");", .{ alias, imp.path, ext });
        }
    }

    /// MIR-path top-level dispatch — switches on MirKind.
    /// Struct/enum use MirNode children; func/var/test still read AST with MIR context.
    fn generateTopLevelMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .func => {
                const prev = self.current_func_mir;
                self.current_func_mir = m;
                defer self.current_func_mir = prev;
                try self.generateFuncMir(m);
            },
            .struct_def => try self.generateStructMir(m),
            .enum_def => try self.generateEnumMir(m),
            .bitfield_def => try self.generateBitfieldMir(m),
            .var_decl => try self.generateTopLevelDeclMir(m),
            .test_def => try self.generateTestMir(m),
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

    /// Emit a re-export for a bridge declaration from the paired sidecar .zig file.
    fn generateBridgeReExport(self: *CodeGen, name: []const u8, is_pub: bool) anyerror!void {
        const vis = if (is_pub) "pub " else "";
        try self.emitLineFmt("{s}const {s} = @import(\"{s}_bridge.zig\").{s};", .{ vis, name, self.module_name, name });
    }

    /// MIR-path function codegen — reads all data from MirNode.
    fn generateFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const func_name = m.name orelse return;

        // Thread function — generate body + spawn wrapper
        if (m.is_thread) return self.generateThreadFuncMir(m);

        // bridge func — re-export from paired sidecar file
        if (m.is_bridge) return self.generateBridgeReExport(func_name, m.is_pub);

        // Body-less declaration — skip codegen.
        // Never skip main (it can legitimately have an empty body).
        const body_m = m.body();
        if (body_m.kind == .block and body_m.children.len == 0 and
            !m.is_bridge and !std.mem.eql(u8, func_name, "main")) return;

        // Track current function for MIR return type queries
        const prev_func_node = self.current_func_node;
        self.current_func_node = m.ast;
        const prev_reassigned_vars = self.reassigned_vars;
        self.reassigned_vars = .{};
        try collectAssignedMir(m.body(), &self.reassigned_vars, self.allocator);
        defer {
            self.current_func_node = prev_func_node;
            self.reassigned_vars.deinit(self.allocator);
            self.reassigned_vars = prev_reassigned_vars;
        }

        const ret_type = m.return_type orelse return;

        // pub modifier
        if (m.is_pub or std.mem.eql(u8, func_name, "main")) try self.emit("pub ");

        const returns_type = ret_type.* == .type_named and
            std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
        const is_type_generic = m.is_compt and returns_type;

        if (m.is_compt and !is_type_generic) {
            try self.emitFmt("inline fn {s}(", .{func_name});
        } else {
            try self.emitFmt("fn {s}(", .{func_name});
        }

        // Parameters
        var first_any_param: ?[]const u8 = null;
        for (m.params(), 0..) |param_m, i| {
            if (i > 0) try self.emit(", ");
            const pname = param_m.name orelse continue;
            const pta = param_m.type_annotation orelse continue;
            const is_any = pta.* == .type_named and
                std.mem.eql(u8, pta.type_named, K.Type.ANY);
            const is_type_param = pta.* == .type_named and
                std.mem.eql(u8, pta.type_named, K.Type.TYPE);
            if (is_any and first_any_param == null) first_any_param = pname;
            if (is_type_param) {
                try self.emitFmt("comptime {s}: type", .{pname});
            } else if (is_type_generic and is_any) {
                try self.emitFmt("comptime {s}: type", .{pname});
            } else if (is_any) {
                try self.emitFmt("{s}: anytype", .{pname});
            } else {
                try self.emitFmt("{s}: {s}", .{ pname, try self.typeToZig(pta) });
            }
        }

        try self.emit(") ");

        // Return type
        const return_is_any = ret_type.* == .type_named and
            std.mem.eql(u8, ret_type.type_named, K.Type.ANY);
        if (return_is_any) {
            if (first_any_param) |pname| {
                try self.emitFmt("@TypeOf({s})", .{pname});
            } else {
                try self.emit("anyopaque");
            }
        } else {
            try self.emit(try self.typeToZig(ret_type));
        }
        try self.emit(" ");

        // Body
        try self.generateBlockMir(body_m);
        try self.emit("\n");
    }

    /// MIR-path thread function codegen.
    fn generateThreadFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const func_name = m.name orelse return;
        const ret_type = m.return_type orelse return;

        // Extract inner type T from Handle(T) return type
        const inner_type = if (ret_type.* == .type_generic and
            std.mem.eql(u8, ret_type.type_generic.name, "Handle") and
            ret_type.type_generic.args.len > 0)
            ret_type.type_generic.args[0]
        else
            ret_type;

        const inner_zig = try self.typeToZig(inner_type);
        const handle_zig = try self.typeToZig(ret_type);

        // Body function
        {
            const prev_func_node = self.current_func_node;
            self.current_func_node = m.ast;
            const prev_assigned = self.reassigned_vars;
            self.reassigned_vars = .{};
            try collectAssignedMir(m.body(), &self.reassigned_vars, self.allocator);
            defer {
                self.current_func_node = prev_func_node;
                self.reassigned_vars.deinit(self.allocator);
                self.reassigned_vars = prev_assigned;
            }

            try self.emitFmt("fn _{s}_body(", .{func_name});
            for (m.params(), 0..) |param_m, i| {
                if (i > 0) try self.emit(", ");
                const pname = param_m.name orelse continue;
                const pta = param_m.type_annotation orelse continue;
                try self.emitFmt("{s}: {s}", .{ pname, try self.typeToZig(pta) });
            }
            try self.emitFmt(") {s} ", .{inner_zig});
            try self.generateBlockMir(m.body());
            try self.emit("\n\n");
        }

        // Spawn wrapper
        if (m.is_pub) try self.emit("pub ");
        try self.emitFmt("fn {s}(", .{func_name});
        for (m.params(), 0..) |param_m, i| {
            if (i > 0) try self.emit(", ");
            const pname = param_m.name orelse continue;
            const pta = param_m.type_annotation orelse continue;
            try self.emitFmt("{s}: {s}", .{ pname, try self.typeToZig(pta) });
        }
        try self.emitFmt(") {s} ", .{handle_zig});
        try self.emit("{\n");
        self.indent += 1;

        try self.emitIndent();
        try self.emitFmt("const _state = std.heap.page_allocator.create({s}.SharedState) catch unreachable;\n", .{handle_zig});
        try self.emitIndent();
        try self.emit("_state.* = .{};\n");

        try self.emitIndent();
        try self.emitFmt("return .{{ .thread = std.Thread.spawn(.{{}}, struct {{ fn run(_s: *{s}.SharedState", .{handle_zig});
        for (m.params()) |param_m| {
            const pname = param_m.name orelse continue;
            const pta = param_m.type_annotation orelse continue;
            try self.emitFmt(", _{s}: {s}", .{ pname, try self.typeToZig(pta) });
        }
        try self.emit(") void { ");

        const is_void = std.mem.eql(u8, inner_zig, "void");
        if (!is_void) try self.emit("_s.result = ");
        try self.emitFmt("_{s}_body(", .{func_name});
        for (m.params(), 0..) |param_m, i| {
            if (i > 0) try self.emit(", ");
            const pname = param_m.name orelse continue;
            try self.emitFmt("_{s}", .{pname});
        }
        try self.emit("); _s.completed.store(true, .release); } }.run, .{ _state");
        for (m.params()) |param_m| {
            const pname = param_m.name orelse continue;
            try self.emitFmt(", {s}", .{pname});
        }
        try self.emit(" }) catch unreachable, .state = _state };\n");

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}\n");
    }

    /// MIR-path collectAssigned — traverses MirNode tree.
    fn collectAssignedMir(m: *mir.MirNode, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void {
        switch (m.kind) {
            .assignment => {
                if (getRootIdentMir(m.lhs())) |name| try set.put(alloc, name, {});
                try collectAssignedMir(m.rhs(), set, alloc);
            },
            .call => {
                const callee_m = m.getCallee();
                if (callee_m.kind == .field_access) {
                    if (callee_m.children.len > 0) {
                        if (getRootIdentMir(callee_m.children[0])) |name| {
                            try set.put(alloc, name, {});
                        }
                    }
                }
                for (m.callArgs()) |arg| try collectAssignedMir(arg, set, alloc);
            },
            .block => {
                for (m.children) |child| try collectAssignedMir(child, set, alloc);
            },
            .func => {}, // nested function — own scope
            .if_stmt => {
                try collectAssignedMir(m.condition(), set, alloc);
                if (m.children.len > 1) try collectAssignedMir(m.thenBlock(), set, alloc);
                if (m.elseBlock()) |e| try collectAssignedMir(e, set, alloc);
            },
            .while_stmt => {
                try collectAssignedMir(m.condition(), set, alloc);
                try collectAssignedMir(m.children[1], set, alloc);
                if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
            },
            .for_stmt => try collectAssignedMir(m.body(), set, alloc),
            .slice => {
                if (m.children.len > 0 and m.children[0].kind == .identifier) {
                    if (m.children[0].name) |name| try set.put(alloc, name, {});
                }
                if (m.children.len > 1) try collectAssignedMir(m.children[1], set, alloc);
                if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
            },
            .var_decl => {
                if (m.children.len > 0) try collectAssignedMir(m.value(), set, alloc);
            },
            .match_stmt => {
                for (m.matchArms()) |arm_mir| {
                    try collectAssignedMir(arm_mir.body(), set, alloc);
                }
            },
            .defer_stmt => try collectAssignedMir(m.body(), set, alloc),
            else => {},
        }
    }

    fn getRootIdentMir(m: *const mir.MirNode) ?[]const u8 {
        return switch (m.kind) {
            .identifier => m.name,
            .field_access => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
            .index => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
            else => null,
        };
    }

    fn generateFunc(self: *CodeGen, node: *parser.Node, f: parser.FuncDecl) anyerror!void {
        // Thread function — generate body + spawn wrapper
        if (f.is_thread) return self.generateThreadFunc(node, f);

        // bridge func — re-export from paired sidecar file
        if (f.is_bridge) return self.generateBridgeReExport(f.name, f.is_pub);

        // Body-less declaration (interface file import) — skip codegen.
        // Never skip main (it can legitimately have an empty body).
        if (f.body.* == .block and f.body.block.statements.len == 0 and
            !f.is_bridge and !std.mem.eql(u8, f.name, "main")) return;

        // Track current function for MIR return type queries
        const prev_func_node = self.current_func_node;
        self.current_func_node = node;
        // Clear per-function tracking maps — each function has its own scope
        const prev_reassigned_vars = self.reassigned_vars;
        self.reassigned_vars = .{};
        try collectAssigned(f.body, &self.reassigned_vars, self.allocator);
        defer {
            self.current_func_node = prev_func_node;
            self.reassigned_vars.deinit(self.allocator);
            self.reassigned_vars = prev_reassigned_vars;
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

        // Body — MIR block path
        const func_mir = self.current_func_mir orelse return error.CompileError;
        try self.generateBlockMir(func_mir.body());
        try self.emit("\n");
    }

    /// Generate a thread function: body function + spawn wrapper.
    /// `thread worker(n: i32) Handle(i32) { return n * 2 }` generates:
    ///   fn _worker_body(n: i32) i32 { return (n * 2); }
    ///   fn worker(n: i32) _OrhonHandle(i32) { ... spawn ... }
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
            self.reassigned_vars = .{};
            try collectAssigned(f.body, &self.reassigned_vars, self.allocator);
            defer {
                self.current_func_node = prev_func_node;
                self.reassigned_vars.deinit(self.allocator);
                self.reassigned_vars = prev_assigned;
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
            const func_mir = self.current_func_mir orelse return error.CompileError;
            try self.generateBlockMir(func_mir.body());
            try self.emit("\n\n");
        }

        // ── Spawn wrapper: fn name(params) _OrhonHandle(T) { ... } ──
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
        try self.emitFmt("const _state = std.heap.page_allocator.create({s}.SharedState) catch unreachable;\n", .{handle_zig});
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

    /// MIR-path struct codegen — iterates MirNode children instead of AST members.
    fn generateStructMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const struct_name = m.name orelse return;
        if (m.is_bridge) return self.generateBridgeReExport(struct_name, m.is_pub);

        const tp = m.type_params;
        const is_generic = tp != null and tp.?.len > 0;

        if (is_generic) {
            if (m.is_pub) try self.emit("pub ");
            try self.emitFmt("fn {s}(", .{struct_name});
            for (tp.?, 0..) |param, i| {
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
            self.generic_struct_name = struct_name;
        } else {
            if (m.is_pub) try self.emit("pub ");
            try self.emitFmt("const {s} = struct {{\n", .{struct_name});
            self.indent += 1;
        }

        for (m.children) |child| {
            switch (child.kind) {
                .field_def => {
                    const fname = child.name orelse continue;
                    try self.emitIndent();
                    try self.emitFmt("{s}: {s}", .{ fname, try self.typeToZig(child.type_annotation orelse continue) });
                    if (child.default_value) |dv| {
                        try self.emit(" = ");
                        try self.generateExpr(dv);
                    }
                    try self.emit(",\n");
                },
                .func => {
                    const prev = self.current_func_mir;
                    self.current_func_mir = child;
                    defer self.current_func_mir = prev;
                    try self.generateFuncMir(child);
                },
                .var_decl => {
                    const decl_kw: []const u8 = if (child.is_const) "const" else "var";
                    const cname = child.name orelse continue;
                    try self.emitIndent();
                    try self.emitFmt("{s} {s}", .{ decl_kw, cname });
                    if (child.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
                    try self.emit(" = ");
                    try self.generateExprMir(child.value());
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

    /// MIR-path enum codegen — iterates MirNode children instead of AST members.
    fn generateEnumMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const enum_name = m.name orelse return;
        if (m.is_pub) try self.emit("pub ");

        const backing = try self.typeToZig(m.backing_type orelse return);

        try self.emitFmt("const {s} = enum({s}) {{\n", .{ enum_name, backing });
        self.indent += 1;

        for (m.children) |child| {
            switch (child.kind) {
                .enum_variant_def => {
                    const vname = child.name orelse continue;
                    try self.emitIndent();
                    try self.emitFmt("{s},\n", .{vname});
                },
                .func => {
                    const prev = self.current_func_mir;
                    self.current_func_mir = child;
                    defer self.current_func_mir = prev;
                    try self.generateFuncMir(child);
                },
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

    /// MIR-path bitfield codegen.
    fn generateBitfieldMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const bf_name = m.name orelse return;
        if (m.is_pub) try self.emit("pub ");
        const backing = try self.typeToZig(m.backing_type orelse return);

        try self.emitFmt("const {s} = struct {{\n", .{bf_name});
        self.indent += 1;

        const members = m.bit_members orelse &.{};
        for (members, 0..) |flag_name, i| {
            try self.emitIndent();
            try self.emitFmt("pub const {s}: {s} = {d};\n", .{ flag_name, backing, @as(u64, 1) << @intCast(i) });
        }

        try self.emitIndent();
        try self.emitFmt("value: {s} = 0,\n", .{backing});

        try self.emitIndent();
        try self.emitFmt("pub fn has(self: {s}, flag: {s}) bool {{ return (self.value & flag) != 0; }}\n", .{ bf_name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn set(self: *{s}, flag: {s}) void {{ self.value |= flag; }}\n", .{ bf_name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn clear(self: *{s}, flag: {s}) void {{ self.value &= ~flag; }}\n", .{ bf_name, backing });
        try self.emitIndent();
        try self.emitFmt("pub fn toggle(self: *{s}, flag: {s}) void {{ self.value ^= flag; }}\n", .{ bf_name, backing });

        self.indent -= 1;
        try self.emit("};\n");
    }

    // ============================================================
    // VARIABLE DECLARATIONS
    // ============================================================

    fn generateConst(self: *CodeGen, node: *parser.Node, v: parser.VarDecl) anyerror!void {
        if (v.is_bridge) return self.generateBridgeReExport(v.name, v.is_pub);
        return self.generateDecl(node, v, "const");
    }

    fn generateVar(self: *CodeGen, node: *parser.Node, v: parser.VarDecl) anyerror!void {
        if (v.is_bridge) return self.generateBridgeReExport(v.name, v.is_pub);
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
        if (tc == .arbitrary_union) {
            try self.generateArbitraryUnionWrappedExpr(v.value, self.getUnionMembers(node));
        } else {
            // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
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
        if (tc == .arbitrary_union) {
            try self.generateArbitraryUnionWrappedExpr(v.value, self.getUnionMembers(node));
        } else {
            // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
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

    /// MIR-path top-level var/const/compt declaration.
    fn generateTopLevelDeclMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const name = m.name orelse return;
        if (m.is_bridge) return self.generateBridgeReExport(name, m.is_pub);

        if (m.is_compt) {
            // Top-level const is already comptime in Zig, so just emit const.
            if (m.is_pub) try self.emit("pub ");
            try self.emitFmt("const {s}: {s} = ", .{
                name,
                try self.typeToZig(m.type_annotation orelse return),
            });
            try self.generateExprMir(m.value());
            try self.emit(";\n");
            return;
        }

        const decl_keyword: []const u8 = if (m.is_const) "const" else "var";
        if (m.is_pub) try self.emit("pub ");
        try self.emitFmt("{s} {s}", .{ decl_keyword, name });
        if (m.type_annotation) |t| {
            try self.emitFmt(": {s}", .{try self.typeToZig(t)});
        }
        try self.emit(" = ");
        if (m.type_class == .arbitrary_union) {
            try self.generateCoercedExprMir(m.value());
        } else if (m.value().kind == .type_expr) {
            // Type in expression position = default constructor (.{})
            try self.emit(".{}");
        } else {
            // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
            try self.generateExprMir(m.value());
        }
        try self.emit(";\n");
    }

    // ============================================================
    // TESTS
    // ============================================================

    fn generateTestMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const description = m.name orelse return;
        try self.emitFmt("test {s} ", .{description});
        const prev_reassigned_vars = self.reassigned_vars;
        self.reassigned_vars = .{};
        try collectAssignedMir(m.body(), &self.reassigned_vars, self.allocator);
        self.in_test_block = true;
        try self.generateBlockMir(m.body());
        self.in_test_block = false;
        self.reassigned_vars.deinit(self.allocator);
        self.reassigned_vars = prev_reassigned_vars;
        try self.emit("\n");
    }

    // ============================================================
    // BLOCKS AND STATEMENTS
    // ============================================================

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

    /// MIR-path statement dispatch — switches on MirKind, reads type info from MirNode.
    /// All handlers use MirNode tree directly — no AST fallthrough.
    fn generateStatementMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .var_decl => {
                const var_name = m.name orelse return;
                if (m.is_compt) {
                    try self.emitFmt("const {s}: {s} = ", .{
                        var_name,
                        try self.typeToZig(m.type_annotation orelse return),
                    });
                    try self.generateExprMir(m.value());
                    try self.emit(";");
                } else if (m.is_const) {
                    try self.generateStmtDeclMir(m, "const");
                } else {
                    const is_handle = if (m.type_annotation) |ta|
                        ta.* == .type_generic and std.mem.eql(u8, ta.type_generic.name, "Handle")
                    else
                        false;
                    const is_mutated = is_handle or self.reassigned_vars.contains(var_name);
                    const decl_keyword: []const u8 = if (is_mutated) "var" else "const";
                    if (!is_mutated) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "'{s}' is declared as var but never reassigned — use const", .{var_name});
                        defer self.allocator.free(msg);
                        try self.reporter.warn(.{ .message = msg, .loc = self.nodeLoc(m.ast) });
                    }
                    try self.generateStmtDeclMir(m, decl_keyword);
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
                            // Native ?T and anyerror!T — Zig handles coercion natively
                            .null_wrap, .error_wrap => {
                                try self.generateExprMir(val_m);
                            },
                            .arbitrary_union_wrap => {
                                try self.generateArbitraryUnionWrappedExprMir(val_m, self.funcReturnMembers());
                            },
                            .array_to_slice, .value_to_const_ref => {
                                try self.emit("&");
                                try self.generateExprMir(val_m);
                            },
                            .optional_unwrap => {
                                // Native ?T: unwrap → .?
                                try self.generateExprMir(val_m);
                                try self.emit(".?");
                            },
                        }
                    } else {
                        // Native ?T and anyerror!T — Zig coerces values automatically
                        try self.generateExprMir(val_m);
                    }
                }
                try self.emit(";");
            },
            .if_stmt => {
                try self.emit("if (");
                try self.generateExprMir(m.condition());
                try self.emit(") ");
                // Narrowing is pre-stamped on MirNode descendants — no map needed
                if (m.children.len > 1) try self.generateBlockMir(m.thenBlock());
                if (m.elseBlock()) |else_m| {
                    try self.emit(" else ");
                    try self.generateBlockMir(else_m);
                }
            },
            .assignment => {
                const assign_op = m.op orelse "=";
                if (std.mem.eql(u8, assign_op, "/=")) {
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = @divTrunc(");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(");");
                } else if (std.mem.eql(u8, assign_op, "=") and
                    m.lhs().type_class == .null_union)
                {
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = ");
                    try self.generateCoercedExprMir(m.rhs());
                    try self.emit(";");
                } else if (std.mem.eql(u8, assign_op, "=") and
                    m.lhs().type_class == .arbitrary_union)
                {
                    const members_rt = if (m.lhs().resolved_type == .union_type)
                        m.lhs().resolved_type.union_type
                    else if (m.lhs().kind == .identifier) self.getVarUnionMembers(m.lhs().name orelse "") else null;
                    try self.generateExprMir(m.lhs());
                    try self.emit(" = ");
                    try self.generateArbitraryUnionWrappedExprMir(m.rhs(), members_rt);
                    try self.emit(";");
                } else {
                    try self.generateExprMir(m.lhs());
                    try self.emitFmt(" {s} ", .{assign_op});
                    try self.generateExprMir(m.rhs());
                    try self.emit(";");
                }
            },
            .destruct => try self.generateDestructMir(m),
            .while_stmt => {
                try self.emit("while (");
                try self.generateExprMir(m.condition());
                try self.emit(")");
                if (m.children.len > 2) {
                    const cont_m = m.children[2];
                    try self.emit(" : (");
                    try self.generateContinueExprMir(cont_m);
                    try self.emit(")");
                }
                try self.emit(" ");
                // Body is children[1]
                try self.generateBlockMir(m.children[1]);
            },
            .for_stmt => try self.generateForMir(m),
            .defer_stmt => {
                try self.emit("defer ");
                try self.generateBlockMir(m.body());
            },
            .match_stmt => try self.generateMatchMir(m),
            .break_stmt => try self.emit("break;"),
            .continue_stmt => try self.emit("continue;"),
            .block => try self.generateBlockMir(m),
            // Injected nodes from MirLowerer (interpolation hoisting)
            .temp_var => {
                if (m.injected_name) |name| {
                    try self.emitFmt("const {s} = ", .{name});
                    if (m.interp_parts) |parts| {
                        try self.generateInterpolatedStringMir(parts, m.children);
                    }
                    try self.emit(";");
                }
            },
            .injected_defer => {
                if (m.injected_name) |name| {
                    try self.emitFmt("defer std.heap.page_allocator.free({s});", .{name});
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
    fn generateStmtDeclMir(self: *CodeGen, m: *mir.MirNode, decl_keyword: []const u8) anyerror!void {
        const var_name = m.name orelse return;
        const val_m = m.value(); // children[0] = value expression
        try self.emitFmt("{s} {s}", .{ decl_keyword, var_name });
        if (m.type_annotation) |t| try self.emitFmt(": {s}", .{try self.typeToZig(t)});
        try self.emit(" = ");
        if (m.type_class == .arbitrary_union) {
            try self.generateCoercedExprMir(val_m);
        } else if (val_m.kind == .type_expr) {
            // Type in expression position = default constructor (.{})
            try self.emit(".{}");
        } else {
            // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
            const prev_ctx = self.type_ctx;
            self.type_ctx = m.type_annotation;
            try self.generateExprMir(val_m);
            self.type_ctx = prev_ctx;
        }
        try self.emitFmt("; _ = &{s};", .{var_name});
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
                // Error("message") → error.sanitized_name (native Zig error)
                const name = try self.sanitizeErrorName(msg);
                try self.emitFmt("error.{s}", .{name});
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
            .type_named => {
                // Type used as expression value (e.g. generic type arg in Ptr(i32, &x))
                try self.emit(try self.typeToZig(node));
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
                // `x is Error`   → if(x) false else true  (anyerror!T check)
                // `x is null`    → x == null    (?T check)
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
                        // Record narrowing for `.value` resolution
                        if (val_node.* == .identifier)
                            try self.null_narrowed.put(self.allocator, val_node.identifier, {});
                        // (null | T) → ?T: x is null → x == null
                        try self.emit("(");
                        try self.generateExpr(val_node);
                        try self.emitFmt(" {s} null)", .{cmp});
                        return;
                    }
                    if (b.right.* == .identifier) {
                        const rhs = b.right.identifier;
                        if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                            // Record narrowing for `.value` resolution
                            if (val_node.* == .identifier)
                                try self.error_narrowed.put(self.allocator, val_node.identifier, {});
                            // (Error | T) → anyerror!T: x is Error →
                            //   if (x) |_| false else |_| true  (for ==)
                            //   if (x) |_| true else |_| false  (for !=)
                            const t_val = if (is_eq) "false" else "true";
                            const f_val = if (is_eq) "true" else "false";
                            try self.emit("(if (");
                            try self.generateExpr(val_node);
                            try self.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
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
                // Collection constructor: List(T).new(), Map(K,V).new(), Set(T).new() → .{}
                // The collection_expr builder is transparent — List(i32) reduces to the
                // element type_primitive (i32) in the AST. The object is either a
                // collection_expr (if the builder is updated) or a type_primitive/type_named
                // (due to transparency). User struct .new() uses identifier (not type node).
                if (c.callee.* == .field_expr) {
                    const method = c.callee.field_expr.field;
                    const obj = c.callee.field_expr.object;
                    if (std.mem.eql(u8, method, "new") and c.args.len == 0) {
                        const is_type_node = obj.* == .collection_expr or
                            obj.* == .type_primitive or obj.* == .type_named or
                            obj.* == .type_generic;
                        if (is_type_node) {
                            try self.emit(".{}");
                            return;
                        }
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
                // s.method(args) → str.method(s, args) when s is a String
                // x.toString()   → str.toString(x) for any type
                // arr.join(sep)  → str.join(arr, sep) for array/slice join
                if (c.callee.* == .field_expr) {
                    const method = c.callee.field_expr.field;
                    const obj = c.callee.field_expr.object;
                    const is_handle = self.getTypeClass(obj) == .thread_handle;
                    if (!is_handle and (self.isStringExpr(obj) or
                        std.mem.eql(u8, method, "toString") or
                        std.mem.eql(u8, method, "join")))
                    {
                        if (self.str_is_included) {
                            try self.emitFmt("{s}(", .{method});
                        } else {
                            const prefix = self.str_import_alias orelse "str";
                            try self.emitFmt("{s}.{s}(", .{ prefix, method });
                        }
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
                    // Inside a generic struct, Name(T) self-instantiation → just @This()
                    // (skip the type args since @This() is already the instantiated type)
                    const is_self_generic = if (self.generic_struct_name) |gsn|
                        c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, gsn)
                    else
                        false;

                    if (is_self_generic) {
                        try self.emit("@This()");
                    } else {
                        // Positional arguments → regular function call
                        try self.generateExpr(c.callee);
                        try self.emit("(");
                        for (c.args, 0..) |arg, i| {
                            if (i > 0) try self.emit(", ");
                            try self.generateExpr(arg);
                        }
                        // Fill in default args if caller passed fewer than the function expects
                        try self.fillDefaultArgs(c);
                        try self.emit(")");
                    }
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
                    // result.Error → @errorName(captured_err) (native Zig error name)
                    if (f.object.* == .identifier) {
                        if (self.error_capture_var.get(f.object.identifier)) |cap| {
                            try self.emitFmt("@errorName({s})", .{cap});
                        } else {
                            // Fallback: should not happen if propagation analysis is correct
                            try self.generateExpr(f.object);
                            try self.emit(" catch |_e| @errorName(_e)");
                        }
                    } else {
                        try self.generateExpr(f.object);
                        try self.emit(" catch |_e| @errorName(_e)");
                    }
                } else if (std.mem.eql(u8, f.field, "value") and
                    (self.getTypeClass(f.object) == .arbitrary_union or self.getTypeClass(f.object) == .null_union or self.getTypeClass(f.object) == .error_union))
                {
                    // .value unwrap — emit native Zig unwrap based on union kind
                    const obj_tc = self.getTypeClass(f.object);
                    if (obj_tc == .arbitrary_union) {
                        try self.generateExpr(f.object);
                        // Use MIR union members to find the value type
                        if (f.object.* == .identifier) {
                            if (self.getUnionMembers(f.object) orelse self.getVarUnionMembers(f.object.identifier)) |members| {
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
                        // (null | T) → ?T: result.value → result.?
                        try self.generateExpr(f.object);
                        try self.emit(".?");
                    } else if (obj_tc == .error_union) {
                        // (Error | T) → anyerror!T: result.value → result catch unreachable
                        try self.generateExpr(f.object);
                        try self.emit(" catch unreachable");
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
                        // (null | T) → ?T: result.User → result.?
                        try self.generateExpr(f.object);
                        try self.emit(".?");
                    } else {
                        // (Error | T) → anyerror!T: result.value → result catch unreachable
                        try self.generateExpr(f.object);
                        try self.emit(" catch unreachable");
                    }
                } else if (std.mem.eql(u8, f.field, "value") and f.object.* == .identifier) {
                    // Fallback `.value` unwrap using narrowing info from `is Error` / `is null` checks.
                    if (self.error_narrowed.contains(f.object.identifier)) {
                        try self.generateExpr(f.object);
                        try self.emit(" catch unreachable");
                    } else if (self.null_narrowed.contains(f.object.identifier)) {
                        try self.generateExpr(f.object);
                        try self.emit(".?");
                    } else {
                        try self.generateExpr(f.object);
                        try self.emit(".value");
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
    /// All expression kinds handled via MirNode children — no AST-path fallthrough.
    fn generateExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        switch (m.kind) {
            .binary => {
                const bin_op = m.op orelse "==";
                const is_eq = std.mem.eql(u8, bin_op, "==");
                const is_ne = std.mem.eql(u8, bin_op, "!=");
                // `x is T` desugared form: @type(x) == T
                const lhs_mir = m.lhs();
                if ((is_eq or is_ne) and
                    lhs_mir.kind == .compiler_fn and
                    std.mem.eql(u8, lhs_mir.name orelse "", K.Type.TYPE) and
                    lhs_mir.children.len > 0)
                {
                    // val_mir is the MirNode for the variable being type-checked
                    const val_mir = lhs_mir.children[0];
                    const cmp = if (is_eq) "==" else "!=";
                    const rhs_mir = m.rhs();
                    if (rhs_mir.literal_kind == .null_lit) {
                        // Record narrowing for `.value` resolution
                        if (val_mir.kind == .identifier)
                            try self.null_narrowed.put(self.allocator, val_mir.name orelse "", {});
                        // (null | T) → ?T: x is null → x == null
                        try self.emit("(");
                        try self.generateExprMir(val_mir);
                        try self.emitFmt(" {s} null)", .{cmp});
                        return;
                    }
                    if (rhs_mir.kind == .identifier) {
                        const rhs = rhs_mir.name orelse "";
                        if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                            // Record narrowing for `.value` resolution
                            if (val_mir.kind == .identifier)
                                try self.error_narrowed.put(self.allocator, val_mir.name orelse "", {});
                            // (Error | T) → anyerror!T: x is Error → if/else pattern
                            const t_val = if (is_eq) "false" else "true";
                            const f_val = if (is_eq) "true" else "false";
                            try self.emit("(if (");
                            try self.generateExprMir(val_mir);
                            try self.emitFmt(") |_| {s} else |_| {s})", .{ t_val, f_val });
                            return;
                        }
                        if (lhs_mir.type_class == .arbitrary_union or
                            val_mir.type_class == .arbitrary_union)
                        {
                            try self.emit("(");
                            try self.generateExprMir(val_mir);
                            try self.emitFmt(" {s} ._{s})", .{ cmp, rhs });
                            return;
                        }
                        const zig_rhs = builtins.primitiveToZig(rhs);
                        try self.emit("(@TypeOf(");
                        try self.generateExprMir(val_mir);
                        try self.emitFmt(") {s} {s})", .{ cmp, zig_rhs });
                        return;
                    }
                }
                // Vector operand detection for arithmetic
                const lhs_is_vec = mirIsVector(m.lhs());
                const rhs_is_vec = mirIsVector(m.rhs());
                const any_vec = lhs_is_vec or rhs_is_vec;

                // Division → @divTrunc (skip for vectors — Zig @Vector supports native / and %)
                if (!any_vec and std.mem.eql(u8, bin_op, "/")) {
                    try self.emit("@divTrunc(");
                    try self.generateExprMir(m.lhs());
                    try self.emit(", ");
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                } else if (!any_vec and std.mem.eql(u8, bin_op, "%")) {
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
                } else if (any_vec and lhs_is_vec != rhs_is_vec) {
                    // Vector-scalar broadcast: wrap scalar side with @splat
                    const op = opToZig(bin_op);
                    try self.emit("(");
                    if (lhs_is_vec) {
                        try self.generateExprMir(m.lhs());
                        try self.emitFmt(" {s} ", .{op});
                        try self.emit("@as(@TypeOf(");
                        try self.generateExprMir(m.lhs());
                        try self.emit("), @splat(");
                        try self.generateExprMir(m.rhs());
                        try self.emit("))");
                    } else {
                        try self.emit("@as(@TypeOf(");
                        try self.generateExprMir(m.rhs());
                        try self.emit("), @splat(");
                        try self.generateExprMir(m.lhs());
                        try self.emit("))");
                        try self.emitFmt(" {s} ", .{op});
                        try self.generateExprMir(m.rhs());
                    }
                    try self.emit(")");
                } else {
                    const op = opToZig(bin_op);
                    try self.emit("(");
                    try self.generateExprMir(m.lhs());
                    try self.emitFmt(" {s} ", .{op});
                    try self.generateExprMir(m.rhs());
                    try self.emit(")");
                }
            },
            .call => {
                const callee_mir = m.getCallee();
                const callee_is_ident = callee_mir.kind == .identifier;
                const callee_is_field = callee_mir.kind == .field_access;
                const callee_name = callee_mir.name orelse "";
                const call_args = m.callArgs();
                // Version() rejection
                if (callee_is_ident and std.mem.eql(u8, callee_name, "Version")) {
                    try self.reporter.report(.{
                        .message = "Version() can only be used in #version metadata",
                        .loc = self.nodeLoc(m.ast),
                    });
                    return;
                }
                // Handle(value) → just emit the value
                if (callee_is_ident and std.mem.eql(u8, callee_name, "Handle") and call_args.len == 1) {
                    try self.generateExprMir(call_args[0]);
                    return;
                }
                // Bitfield constructor
                if (callee_is_ident) {
                    if (self.decls) |d| {
                        if (d.bitfields.get(callee_name)) |_| {
                            try self.emitFmt("{s}{{ .value = ", .{callee_name});
                            if (call_args.len == 0) {
                                try self.emit("0");
                            } else {
                                for (call_args, 0..) |arg, i| {
                                    if (i > 0) try self.emit(" | ");
                                    if (arg.kind == .identifier) {
                                        try self.emitFmt("{s}.{s}", .{ callee_name, arg.name orelse "" });
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
                if (callee_is_field) {
                    const obj_mir = callee_mir.children[0]; // field_access.children[0] = object
                    if (mirGetBitfieldName(obj_mir, self.decls)) |bf_name| {
                        try self.generateExprMir(callee_mir);
                        try self.emit("(");
                        for (call_args, 0..) |arg, i| {
                            if (i > 0) try self.emit(", ");
                            if (arg.kind == .identifier) {
                                try self.emitFmt("{s}.{s}", .{ bf_name, arg.name orelse "" });
                            } else {
                                try self.generateExprMir(arg);
                            }
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // Collection constructor: List(T).new(), Map(K,V).new(), Set(T).new() → .{}
                // The collection_expr builder is transparent — List(i32) reduces to the
                // element type_primitive (i32) in the AST. So the callee's object has
                // kind == .type_expr (a type in expression position), not .collection.
                // Calling .new() with no args on a type in expression position always
                // means "zero-initialize" — safe because user struct names parse as
                // .identifier (not .type_expr), so there's no false-positive risk.
                if (callee_is_field) {
                    const method = callee_mir.name orelse "";
                    if (std.mem.eql(u8, method, "new") and call_args.len == 0) {
                        if (callee_mir.children.len > 0) {
                            const obj_mir = callee_mir.children[0];
                            if (obj_mir.kind == .type_expr or obj_mir.kind == .collection) {
                                try self.emit(".{}");
                                return;
                            }
                        }
                    }
                }
                // overflow/wrap/sat builtins
                if (callee_is_ident and call_args.len == 1) {
                    const arg_m = call_args[0];
                    if (std.mem.eql(u8, callee_name, "wrap")) {
                        try self.generateWrappingExprMir(arg_m);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "sat")) {
                        try self.generateSaturatingExprMir(arg_m);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "overflow")) {
                        try self.generateOverflowExprMir(arg_m);
                        return;
                    }
                }
                // String method rewriting: s.method(args) → _str.method(s, args)
                if (callee_is_field) {
                    const method = callee_mir.name orelse "";
                    const obj_mir = callee_mir.children[0]; // field_access.children[0] = object
                    const is_handle = obj_mir.type_class == .thread_handle;
                    if (!is_handle and (mirIsString(obj_mir) or
                        std.mem.eql(u8, method, "toString") or
                        std.mem.eql(u8, method, "join")))
                    {
                        if (self.str_is_included) {
                            try self.emitFmt("{s}(", .{method});
                        } else {
                            const prefix = self.str_import_alias orelse "str";
                            try self.emitFmt("{s}.{s}(", .{ prefix, method });
                        }
                        try self.generateExprMir(obj_mir);
                        for (call_args) |arg| {
                            try self.emit(", ");
                            try self.generateExprMir(arg);
                        }
                        try self.emit(")");
                        return;
                    }
                }
                // Clean call generation
                const call_arg_names = m.arg_names;
                if (call_arg_names != null and call_arg_names.?.len > 0) {
                    const an = call_arg_names.?;
                    try self.generateExprMir(callee_mir);
                    try self.emit("{ ");
                    for (call_args, 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        if (i < an.len and an[i].len > 0) {
                            try self.emitFmt(".{s} = ", .{an[i]});
                        }
                        try self.generateExprMir(arg);
                    }
                    try self.emit(" }");
                } else {
                    // Inside a generic struct, Name(T) self-instantiation → just @This()
                    const is_self_generic_mir = if (self.generic_struct_name) |gsn|
                        callee_is_ident and std.mem.eql(u8, callee_name, gsn)
                    else
                        false;

                    if (is_self_generic_mir) {
                        try self.emit("@This()");
                    } else {
                        try self.generateExprMir(callee_mir);
                        try self.emit("(");
                        for (call_args, 0..) |arg, i| {
                            if (i > 0) try self.emit(", ");
                            try self.generateCoercedExprMir(arg);
                        }
                        try self.fillDefaultArgsMir(callee_mir, call_args.len);
                        try self.emit(")");
                    }
                }
            },
            .field_access => {
                const field = m.name orelse "";
                const obj_mir = m.children[0];
                const obj_tc = obj_mir.type_class;
                // handle.value → handle.getValue()
                if (std.mem.eql(u8, field, "value") and obj_tc == .thread_handle) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".getValue()");
                } else if (std.mem.eql(u8, field, "done") and obj_tc == .thread_handle) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".done()");
                } else if (std.mem.eql(u8, field, "value") and obj_tc == .safe_ptr) {
                    try self.generateExprMir(obj_mir);
                    try self.emit(".*");
                } else if (std.mem.eql(u8, field, "value") and obj_tc == .raw_ptr) {
                    try self.generateExprMir(obj_mir);
                    try self.emit("[0]");
                } else if (std.mem.eql(u8, field, K.Type.ERROR)) {
                    // result.Error → @errorName(captured_err) (native Zig error)
                    if (obj_mir.kind == .identifier) {
                        const obj_name = obj_mir.name orelse "";
                        if (self.error_capture_var.get(obj_name)) |cap| {
                            try self.emitFmt("@errorName({s})", .{cap});
                        } else {
                            try self.generateExprMir(obj_mir);
                            try self.emit(" catch |_e| @errorName(_e)");
                        }
                    } else {
                        try self.generateExprMir(obj_mir);
                        try self.emit(" catch |_e| @errorName(_e)");
                    }
                } else if (std.mem.eql(u8, field, "value") and
                    (obj_tc == .arbitrary_union or obj_tc == .null_union or obj_tc == .error_union))
                {
                    if (obj_tc == .arbitrary_union) {
                        try self.generateExprMir(obj_mir);
                        if (obj_mir.kind == .identifier) {
                            if (obj_mir.narrowed_to) |narrowed| {
                                try self.emitFmt("._{s}", .{narrowed});
                            } else {
                                const obj_name = obj_mir.name orelse "";
                                const members_rt = if (obj_mir.resolved_type == .union_type) obj_mir.resolved_type.union_type else
                                    if (self.getVarUnionMembers(obj_name)) |m2| m2 else null;
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
                        // (null | T) → ?T: result.value → result.?
                        try self.generateExprMir(obj_mir);
                        try self.emit(".?");
                    } else if (obj_tc == .error_union) {
                        // (Error | T) → anyerror!T: result.value → result catch unreachable
                        try self.generateExprMir(obj_mir);
                        try self.emit(" catch unreachable");
                    }
                } else if (obj_tc == .arbitrary_union and isResultValueField(field, self.decls)) {
                    try self.generateExprMir(obj_mir);
                    try self.emitFmt("._{s}", .{field});
                } else if (isResultValueField(field, self.decls)) {
                    if (obj_tc == .null_union) {
                        // (null | T) → ?T: result.value → result.?
                        try self.generateExprMir(obj_mir);
                        try self.emit(".?");
                    } else {
                        // (Error | T) → anyerror!T: result.value → result catch unreachable
                        try self.generateExprMir(obj_mir);
                        try self.emit(" catch unreachable");
                    }
                } else if (std.mem.eql(u8, field, "value") and obj_mir.kind == .identifier) {
                    // Fallback `.value` unwrap using narrowing info
                    const obj_name = obj_mir.name orelse "";
                    if (self.error_narrowed.contains(obj_name)) {
                        try self.generateExprMir(obj_mir);
                        try self.emit(" catch unreachable");
                    } else if (self.null_narrowed.contains(obj_name)) {
                        try self.generateExprMir(obj_mir);
                        try self.emit(".?");
                    } else {
                        try self.generateExprMir(obj_mir);
                        try self.emit(".value");
                    }
                } else {
                    try self.generateExprMir(obj_mir);
                    try self.emitFmt(".{s}", .{field});
                }
            },
            .literal => {
                const lk = m.literal_kind orelse return;
                switch (lk) {
                    .int, .float, .string => try self.emit(m.literal orelse return),
                    .bool_lit => try self.emit(if (m.bool_val) "true" else "false"),
                    .null_lit => try self.emit("null"),
                    .error_lit => {
                        // Error("message") → error.sanitized_name (native Zig error)
                        const msg = m.literal orelse return;
                        const name = try self.sanitizeErrorName(msg);
                        try self.emitFmt("error.{s}", .{name});
                    },
                }
            },
            .identifier => {
                const name = m.name orelse return;
                if (self.isEnumVariant(name)) {
                    try self.emitFmt(".{s}", .{name});
                } else if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, name, gsn)) {
                        try self.emit("@This()");
                    } else {
                        try self.emit(builtins.primitiveToZig(name));
                    }
                } else {
                    try self.emit(builtins.primitiveToZig(name));
                }
            },
            .unary => {
                const op = opToZig(m.op orelse return);
                try self.emitFmt("{s}(", .{op});
                try self.generateExprMir(m.children[0]);
                try self.emit(")");
            },
            .index => {
                try self.generateExprMir(m.children[0]);
                try self.emit("[");
                const index_is_literal = m.children[1].literal_kind == .int;
                if (!index_is_literal) {
                    try self.emit("@intCast(");
                    try self.generateExprMir(m.children[1]);
                    try self.emit(")");
                } else {
                    try self.generateExprMir(m.children[1]);
                }
                try self.emit("]");
            },
            .slice => {
                try self.generateExprMir(m.children[0]);
                try self.emit("[");
                if (m.children[1].literal_kind != .int) {
                    try self.emit("@intCast(");
                    try self.generateExprMir(m.children[1]);
                    try self.emit(")");
                } else {
                    try self.generateExprMir(m.children[1]);
                }
                try self.emit("..");
                if (m.children[2].literal_kind != .int) {
                    try self.emit("@intCast(");
                    try self.generateExprMir(m.children[2]);
                    try self.emit(")");
                } else {
                    try self.generateExprMir(m.children[2]);
                }
                try self.emit("]");
            },
            .borrow => {
                try self.emit("&");
                try self.generateExprMir(m.children[0]);
            },
            .interpolation => {
                if (m.interp_parts) |parts| {
                    try self.generateInterpolatedStringMir(parts, m.children);
                }
            },
            .collection => try self.generateCollectionExprMir(m),
            .ptr_expr => try self.generatePtrExprMir(m),
            .compiler_fn => try self.generateCompilerFuncMir(m),
            .array_lit => {
                try self.emit(".{");
                for (m.children, 0..) |child, i| {
                    if (i > 0) try self.emit(", ");
                    try self.generateExprMir(child);
                }
                try self.emit("}");
            },
            .tuple_lit => {
                try self.emit(".{");
                if (m.is_named_tuple) {
                    const fnames = m.field_names orelse &.{};
                    for (m.children, 0..) |child, i| {
                        if (i > 0) try self.emit(", ");
                        if (i < fnames.len) try self.emitFmt(".{s} = ", .{fnames[i]});
                        try self.generateExprMir(child);
                    }
                } else {
                    for (m.children, 0..) |child, i| {
                        if (i > 0) try self.emit(", ");
                        try self.generateExprMir(child);
                    }
                }
                try self.emit("}");
            },
            .type_expr => try self.generateExpr(m.ast), // type nodes are structural, no sub-expressions
            .passthrough => try self.generateExpr(m.ast), // structural fallback
            else => {},
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
            // Native ?T and anyerror!T — Zig handles coercion automatically
            .null_wrap, .error_wrap => {
                try self.generateExprMir(m);
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
                // Native ?T: unwrap → .?
                try self.generateExprMir(m);
                try self.emit(".?");
            },
            .value_to_const_ref => {
                // T → *const T: take address for const & parameter passing
                try self.emit("&");
                try self.generateExprMir(m);
            },
        }
    }

    /// Check if a MirNode represents a string expression (via type_class or literal_kind).
    fn mirIsString(m: *const mir.MirNode) bool {
        return m.type_class == .string or m.literal_kind == .string or m.kind == .interpolation;
    }

    /// Check if a MirNode represents a SIMD Vector type.
    fn mirIsVector(m: *const mir.MirNode) bool {
        if (m.resolved_type == .generic) {
            return std.mem.eql(u8, m.resolved_type.generic.name, "Vector");
        }
        return false;
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
    /// MIR-path continue expression for while loops.
    fn generateContinueExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        if (m.kind == .assignment) {
            const assign_op = m.op orelse "=";
            if (std.mem.eql(u8, assign_op, "/=")) {
                try self.generateExprMir(m.lhs());
                try self.emit(" = @divTrunc(");
                try self.generateExprMir(m.lhs());
                try self.emit(", ");
                try self.generateExprMir(m.rhs());
                try self.emit(")");
            } else {
                try self.generateExprMir(m.lhs());
                try self.emitFmt(" {s} ", .{assign_op});
                try self.generateExprMir(m.rhs());
            }
        } else {
            try self.generateExprMir(m);
        }
    }

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

    /// MIR-path range expression for for-loops.
    fn writeRangeExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const left_is_literal = m.lhs().literal_kind == .int;
        if (left_is_literal) {
            try self.generateExprMir(m.lhs());
        } else {
            try self.emit("@intCast(");
            try self.generateExprMir(m.lhs());
            try self.emit(")");
        }
        try self.emit("..");
        const right_is_literal = m.rhs().literal_kind == .int;
        if (right_is_literal) {
            try self.generateExprMir(m.rhs());
        } else {
            try self.emit("@intCast(");
            try self.generateExprMir(m.rhs());
            try self.emit(")");
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

    /// Generate string interpolation using std.fmt.allocPrint.
    /// "hello @{name}, value @{x}!" →
    ///   std.fmt.allocPrint(std.heap.page_allocator, "hello {s}, value {}", .{name, x}) catch unreachable
    fn generateInterpolatedString(self: *CodeGen, interp: parser.InterpolatedString) anyerror!void {
        try self.emit("std.fmt.allocPrint(std.heap.page_allocator, \"");
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
        try self.emit("}) catch |err| return err");
    }

    /// MIR-path for loop codegen.
    fn generateForMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const caps = m.captures orelse &.{};
        const idx_var = m.index_var;
        const iter_m = m.iterable();
        const is_range = iter_m.kind == .binary and std.mem.eql(u8, iter_m.op orelse "", "..");
        const needs_cast = is_range or idx_var != null;
        if (m.is_compt) try self.emit("inline ");
        try self.emit("for (");
        if (is_range) {
            try self.writeRangeExprMir(iter_m);
        } else {
            try self.generateExprMir(iter_m);
        }
        if (idx_var != null) try self.emit(", 0..");
        try self.emit(") |");
        if (caps.len > 0) {
            if (is_range) {
                try self.emitFmt("_orhon_{s}", .{caps[0]});
            } else {
                try self.emit(caps[0]);
            }
        }
        if (idx_var) |idx| {
            try self.emitFmt(", _orhon_{s}", .{idx});
        }
        if (needs_cast) {
            try self.emit("| {\n");
            self.indent += 1;
            if (is_range and caps.len > 0) {
                try self.emitIndent();
                try self.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ caps[0], caps[0] });
            }
            if (idx_var) |idx| {
                try self.emitIndent();
                try self.emitFmt("const {s}: i32 = @intCast(_orhon_{s});\n", .{ idx, idx });
            }
            for (m.body().children) |child| {
                try self.emitIndent();
                try self.generateStatementMir(child);
                try self.emit("\n");
            }
            self.indent -= 1;
            try self.emitIndent();
            try self.emit("}");
        } else {
            try self.emit("| ");
            try self.generateBlockMir(m.body());
        }
    }

    /// MIR-path destructuring codegen.
    fn generateDestructMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const d_names = m.names orelse &.{};
        const decl_keyword: []const u8 = if (m.is_const) "const" else "var";
        const val_m = m.value();
        // String split destructuring
        if (d_names.len == 2 and val_m.kind == .call) {
            const callee_m = val_m.getCallee();
            if (callee_m.kind == .field_access) {
                const method = callee_m.name orelse "";
                if (std.mem.eql(u8, method, "split")) {
                    const call_args = val_m.callArgs();
                    const destruct_idx = self.destruct_counter;
                    self.destruct_counter += 1;
                    try self.emitFmt("const _orhon_sp{d}_delim = ", .{destruct_idx});
                    if (call_args.len > 0) try self.generateExprMir(call_args[0]);
                    try self.emit(";\n");
                    try self.emitIndent();
                    try self.emitFmt("const _orhon_sp{d}_pos = std.mem.indexOf(u8, ", .{destruct_idx});
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emitFmt(", _orhon_sp{d}_delim);\n", .{destruct_idx});
                    try self.emitIndent();
                    try self.emitFmt("{s} {s} = if (_orhon_sp{d}_pos) |_idx| ", .{ decl_keyword, d_names[0], destruct_idx });
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emit("[0.._idx] else ");
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emit(";\n");
                    try self.emitIndent();
                    try self.emitFmt("{s} {s} = if (_orhon_sp{d}_pos) |_idx| ", .{ decl_keyword, d_names[1], destruct_idx });
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emitFmt("[_idx + _orhon_sp{d}_delim.len..] else \"\";", .{destruct_idx});
                    return;
                }
                if (std.mem.eql(u8, method, "splitAt") and val_m.callArgs().len == 1) {
                    const destruct_idx = self.destruct_counter;
                    self.destruct_counter += 1;
                    try self.emitFmt("var _orhon_s{d}: usize = @intCast(", .{destruct_idx});
                    try self.generateExprMir(val_m.callArgs()[0]);
                    try self.emit(");\n");
                    try self.emitIndent();
                    try self.emitFmt("_ = &_orhon_s{d};\n", .{destruct_idx});
                    try self.emitIndent();
                    try self.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[0] });
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emitFmt("[0.._orhon_s{d}];\n", .{destruct_idx});
                    try self.emitIndent();
                    try self.emitFmt("{s} {s} = ", .{ decl_keyword, d_names[1] });
                    try self.generateExprMir(callee_m.children[0]);
                    try self.emitFmt("[_orhon_s{d}..];", .{destruct_idx});
                    return;
                }
            }
        }
        // Normal tuple destructuring
        const idx = self.destruct_counter;
        self.destruct_counter += 1;
        try self.emitFmt("const _orhon_d{d} = ", .{idx});
        try self.generateExprMir(val_m);
        try self.emit(";");
        for (d_names) |name| {
            try self.emit("\n");
            try self.emitIndent();
            try self.emitFmt("{s} {s} = _orhon_d{d}.{s};", .{ decl_keyword, name, idx, name });
        }
    }

    /// MIR-path match codegen — dispatches to string, type, or regular switch.
    fn generateMatchMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        // String match — Zig has no string switch, desugar to if/else chain
        const is_string_match = blk: {
            for (m.matchArms()) |arm_mir| {
                if (arm_mir.pattern().literal_kind == .string) break :blk true;
            }
            break :blk false;
        };

        // Type match — any arm is `Error`, `null`, or value is an arbitrary union
        const is_type_match = blk: {
            if (m.value().type_class == .arbitrary_union) break :blk true;
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                if (pat_m.literal_kind == .null_lit) break :blk true;
                if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR))
                    break :blk true;
            }
            break :blk false;
        };

        const is_null_union = blk: {
            for (m.matchArms()) |arm_mir| {
                if (arm_mir.pattern().literal_kind == .null_lit) break :blk true;
            }
            break :blk false;
        };

        if (is_string_match) {
            try self.generateStringMatchMir(m);
        } else if (is_type_match) {
            try self.generateTypeMatchMir(m, is_null_union);
        } else {
            // Regular switch
            try self.emit("switch (");
            const val_m = m.value();
            if (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", "self")) {
                try self.emit("self.*");
            } else {
                try self.generateExprMir(val_m);
            }
            try self.emit(") {\n");
            self.indent += 1;
            var has_wildcard = false;
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                try self.emitIndent();
                if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", "else")) {
                    has_wildcard = true;
                    try self.emit("else");
                } else if (pat_m.kind == .binary and std.mem.eql(u8, pat_m.op orelse "", "..")) {
                    try self.generateExprMir(pat_m.lhs());
                    try self.emit("...");
                    try self.generateExprMir(pat_m.rhs());
                } else {
                    try self.generateExprMir(pat_m);
                }
                try self.emit(" => ");
                try self.generateBlockMir(arm_mir.body());
                try self.emit(",\n");
            }
            if (!has_wildcard) {
                var is_enum_switch = false;
                for (m.matchArms()) |arm_mir| {
                    const pat_m = arm_mir.pattern();
                    if (pat_m.kind == .identifier) {
                        if (self.isEnumVariant(pat_m.name orelse "")) {
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
        }
    }

    /// MIR-path type match (arbitrary/error/null union switch).
    fn generateTypeMatchMir(self: *CodeGen, m: *mir.MirNode, is_null_union: bool) anyerror!void {
        const is_arbitrary = blk: {
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR)) break :blk false;
                if (pat_m.literal_kind == .null_lit) break :blk false;
            }
            break :blk true;
        };

        const is_error_union = blk: {
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", K.Type.ERROR)) break :blk true;
            }
            break :blk false;
        };

        // For native ?T and anyerror!T, use if/else instead of switch
        if (is_error_union) {
            // match on anyerror!T → if (val) |_match_val| { ... } else |_match_err| { ... }
            var value_arm: ?*mir.MirNode = null;
            var error_arm: ?*mir.MirNode = null;
            var else_arm: ?*mir.MirNode = null;
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                const pat_name = pat_m.name orelse "";
                if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, K.Type.ERROR)) {
                    error_arm = arm_mir;
                } else if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                    else_arm = arm_mir;
                } else {
                    value_arm = arm_mir;
                }
            }
            try self.emit("if (");
            try self.generateExprMir(m.value());
            try self.emit(") |_match_val| ");
            if (value_arm orelse else_arm) |arm| {
                try self.generateBlockMir(arm.body());
            } else {
                try self.emit("{}");
            }
            try self.emit(" else |_match_err| ");
            if (error_arm) |arm| {
                try self.generateBlockMir(arm.body());
            } else {
                try self.emit("{}");
            }
            return;
        }

        if (is_null_union) {
            // match on ?T → if (val) |_match_val| { ... } else { ... }
            var value_arm: ?*mir.MirNode = null;
            var null_arm: ?*mir.MirNode = null;
            var else_arm: ?*mir.MirNode = null;
            for (m.matchArms()) |arm_mir| {
                const pat_m = arm_mir.pattern();
                const pat_name = pat_m.name orelse "";
                if (pat_m.literal_kind == .null_lit) {
                    null_arm = arm_mir;
                } else if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                    else_arm = arm_mir;
                } else {
                    value_arm = arm_mir;
                }
            }
            try self.emit("if (");
            try self.generateExprMir(m.value());
            try self.emit(") |_match_val| ");
            if (value_arm orelse else_arm) |arm| {
                try self.generateBlockMir(arm.body());
            } else {
                try self.emit("{}");
            }
            try self.emit(" else ");
            if (null_arm) |arm| {
                try self.generateBlockMir(arm.body());
            } else {
                try self.emit("{}");
            }
            return;
        }

        // Arbitrary union — keep as switch
        try self.emit("switch (");
        try self.generateExprMir(m.value());
        try self.emit(") {\n");
        self.indent += 1;

        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();
            const pat_name = pat_m.name orelse "";
            try self.emitIndent();

            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_name, "else")) {
                try self.emit("else");
            } else if (is_arbitrary and pat_m.kind == .identifier) {
                try self.emitFmt("._{s}", .{pat_name});
            }

            try self.emit(" => ");
            try self.generateBlockMir(arm_mir.body());
            try self.emit(",\n");
        }

        self.indent -= 1;
        try self.emitIndent();
        try self.emit("}");
    }

    /// MIR-path string match — desugars to if/else chain.
    fn generateStringMatchMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        var first = true;
        var wildcard_arm: ?*mir.MirNode = null;

        for (m.matchArms()) |arm_mir| {
            const pat_m = arm_mir.pattern();

            if (pat_m.kind == .identifier and std.mem.eql(u8, pat_m.name orelse "", "else")) {
                wildcard_arm = arm_mir;
                continue;
            }

            if (first) {
                try self.emit("if (std.mem.eql(u8, ");
                first = false;
            } else {
                try self.emit(" else if (std.mem.eql(u8, ");
            }

            const val_m = m.value();
            if (val_m.kind == .identifier and std.mem.eql(u8, val_m.name orelse "", "self")) {
                try self.emit("self.*");
            } else {
                try self.generateExprMir(val_m);
            }
            try self.emit(", ");
            try self.generateExprMir(pat_m);
            try self.emit(")) ");
            try self.generateBlockMir(arm_mir.body());
        }

        if (wildcard_arm) |wa| {
            if (first) {
                try self.generateBlockMir(wa.body());
            } else {
                try self.emit(" else ");
                try self.generateBlockMir(wa.body());
            }
        } else if (!first) {
            try self.emit(" else {}");
        }
    }

    /// MIR-path interpolated string — uses interp_parts for literals, children for exprs.
    fn generateInterpolatedStringMir(self: *CodeGen, parts: []const parser.InterpolatedPart, expr_children: []*mir.MirNode) anyerror!void {
        try self.emit("std.fmt.allocPrint(std.heap.page_allocator, \"");
        var expr_idx: usize = 0;
        // Build format string
        for (parts) |part| {
            switch (part) {
                .literal => |text| {
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
                .expr => {
                    if (expr_idx < expr_children.len and mirIsString(expr_children[expr_idx])) {
                        try self.emit("{s}");
                    } else {
                        try self.emit("{}");
                    }
                    expr_idx += 1;
                },
            }
        }
        try self.emit("\", .{");
        // Build args tuple
        var first = true;
        for (expr_children) |child| {
            if (!first) try self.emit(", ");
            try self.generateExprMir(child);
            first = false;
        }
        try self.emit("}) catch |err| return err");
    }

    /// MIR-path collection expr — all unmanaged collections zero-initialize.
    fn generateCollectionExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        _ = m;
        try self.emit(".{}");
    }

    /// MIR-path ptr expr.
    fn generatePtrExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const kind = m.name orelse return;
        // children = [type_arg, addr_arg]
        const type_arg = m.children[0];
        const addr_arg = m.children[1];
        if (std.mem.eql(u8, kind, "Ptr")) {
            try self.generateExprMir(addr_arg);
        } else if (std.mem.eql(u8, kind, "RawPtr")) {
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
                self.warned_rawptr = true;
            }
            const zig_type = try self.typeToZig(type_arg.ast);
            if (addr_arg.kind == .borrow) {
                try self.emitFmt("@as([*]{s}, @ptrCast(", .{zig_type});
                try self.generateExprMir(addr_arg);
                try self.emit("))");
            } else {
                try self.emitFmt("@as([*]{s}, @ptrFromInt(", .{zig_type});
                try self.generateExprMir(addr_arg);
                try self.emit("))");
            }
        } else if (std.mem.eql(u8, kind, "VolatilePtr")) {
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: VolatilePtr used — unsafe, hardware access only\n", .{});
                self.warned_rawptr = true;
            }
            const zig_type = try self.typeToZig(type_arg.ast);
            if (addr_arg.kind == .borrow) {
                try self.emitFmt("@as(*volatile {s}, @ptrCast(", .{zig_type});
                try self.generateExprMir(addr_arg);
                try self.emit("))");
            } else {
                try self.emitFmt("@as(*volatile {s}, @ptrFromInt(", .{zig_type});
                try self.generateExprMir(addr_arg);
                try self.emit("))");
            }
        }
    }

    /// MIR-path compiler function (@typename, @cast, @size, etc.).
    fn generateCompilerFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        const cf_name = m.name orelse return;
        const args = m.children;
        if (std.mem.eql(u8, cf_name, "typename")) {
            try self.emit("@typeName(@TypeOf(");
            if (args.len > 0) try self.generateExprMir(args[0]);
            try self.emit("))");
        } else if (std.mem.eql(u8, cf_name, "typeid")) {
            try self.emit("@intFromPtr(@typeName(@TypeOf(");
            if (args.len > 0) try self.generateExprMir(args[0]);
            try self.emit(")).ptr)");
        } else if (std.mem.eql(u8, cf_name, "cast")) {
            if (args.len >= 2) {
                const target_type = try self.typeToZig(args[0].ast);
                const target_is_float = target_type.len > 0 and target_type[0] == 'f';
                const source_is_float_literal = args[1].literal_kind == .float;
                try self.emitFmt("@as({s}, ", .{target_type});
                if (target_is_float and source_is_float_literal) {
                    try self.emit("@floatCast(");
                } else if (target_is_float) {
                    try self.emit("@floatFromInt(");
                } else if (source_is_float_literal) {
                    try self.emit("@intFromFloat(");
                } else {
                    try self.emit("@intCast(");
                }
                try self.generateExprMir(args[1]);
                try self.emit("))");
            } else if (args.len == 1) {
                try self.emit("@intCast(");
                try self.generateExprMir(args[0]);
                try self.emit(")");
            }
        } else if (std.mem.eql(u8, cf_name, "size")) {
            try self.emit("@sizeOf(");
            if (args.len > 0) try self.generateExprMir(args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf_name, "align")) {
            try self.emit("@alignOf(");
            if (args.len > 0) try self.generateExprMir(args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf_name, "copy")) {
            if (args.len > 0) try self.generateExprMir(args[0]);
        } else if (std.mem.eql(u8, cf_name, "move")) {
            if (args.len > 0) try self.generateExprMir(args[0]);
        } else if (std.mem.eql(u8, cf_name, "assert")) {
            if (self.in_test_block) {
                try self.emit("try std.testing.expect(");
            } else {
                try self.emit("std.debug.assert(");
            }
            if (args.len > 0) try self.generateExprMir(args[0]);
            try self.emit(")");
        } else if (std.mem.eql(u8, cf_name, "swap")) {
            if (args.len == 2) {
                try self.emit("std.mem.swap(@TypeOf(");
                try self.generateExprMir(args[0]);
                try self.emit("), &");
                try self.generateExprMir(args[0]);
                try self.emit(", &");
                try self.generateExprMir(args[1]);
                try self.emit(")");
            }
        } else {
            try self.emitFmt("/* unknown @{s} */", .{cf_name});
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
                //   if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(a), error.overflow)
                //   else break :blk @as(anyerror!@TypeOf(a), _ov[0]); })
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
                    try self.emitFmt("); if (_ov[1] != 0) break :blk @as(anyerror!{s}, error.overflow) else break :blk @as(anyerror!{s}, _ov[0]); }})", .{ ts, ts });
                } else {
                    try self.emit("); if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.emit("), error.overflow) else break :blk @as(anyerror!@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.emit("), _ov[0]); })");
                }
                return;
            }
        }
        try self.generateExpr(arg);
    }

    /// MIR-path wrapping arithmetic.
    fn generateWrappingExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        if (m.kind == .binary) {
            const bin_op = m.op orelse "";
            const wrap_op: ?[]const u8 =
                if (std.mem.eql(u8, bin_op, "+")) "+%"
                else if (std.mem.eql(u8, bin_op, "-")) "-%"
                else if (std.mem.eql(u8, bin_op, "*")) "*%"
                else null;
            if (wrap_op) |op| {
                try self.generateExprMir(m.lhs());
                try self.emitFmt(" {s} ", .{op});
                try self.generateExprMir(m.rhs());
                return;
            }
        }
        try self.generateExprMir(m);
    }

    /// MIR-path saturating arithmetic.
    fn generateSaturatingExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        if (m.kind == .binary) {
            const bin_op = m.op orelse "";
            const sat_op: ?[]const u8 =
                if (std.mem.eql(u8, bin_op, "+")) "+|"
                else if (std.mem.eql(u8, bin_op, "-")) "-|"
                else if (std.mem.eql(u8, bin_op, "*")) "*|"
                else null;
            if (sat_op) |op| {
                try self.generateExprMir(m.lhs());
                try self.emitFmt(" {s} ", .{op});
                try self.generateExprMir(m.rhs());
                return;
            }
        }
        try self.generateExprMir(m);
    }

    /// MIR-path overflow arithmetic.
    fn generateOverflowExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        if (m.kind == .binary) {
            const bin_op = m.op orelse "";
            const builtin_name: ?[]const u8 =
                if (std.mem.eql(u8, bin_op, "+")) "@addWithOverflow"
                else if (std.mem.eql(u8, bin_op, "-")) "@subWithOverflow"
                else if (std.mem.eql(u8, bin_op, "*")) "@mulWithOverflow"
                else null;
            if (builtin_name) |builtin| {
                const left_is_literal = m.lhs().literal_kind == .int or m.lhs().literal_kind == .float;
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
                    try self.generateExprMir(m.lhs());
                    try self.emit(")");
                } else {
                    try self.generateExprMir(m.lhs());
                }
                try self.emit(", ");
                try self.generateExprMir(m.rhs());
                if (type_str) |ts| {
                    try self.emitFmt("); if (_ov[1] != 0) break :blk @as(anyerror!{s}, error.overflow) else break :blk @as(anyerror!{s}, _ov[0]); }})", .{ ts, ts });
                } else {
                    try self.emit("); if (_ov[1] != 0) break :blk @as(anyerror!@TypeOf(");
                    try self.generateExprMir(m.lhs());
                    try self.emit("), error.overflow) else break :blk @as(anyerror!@TypeOf(");
                    try self.generateExprMir(m.lhs());
                    try self.emit("), _ov[0]); })");
                }
                return;
            }
        }
        try self.generateExprMir(m);
    }

    /// MIR-path fill default arguments.
    fn fillDefaultArgsMir(self: *CodeGen, callee_mir: *const mir.MirNode, actual_arg_count: usize) anyerror!void {
        // Resolve function name from callee MirNode
        const func_name: []const u8 = if (callee_mir.kind == .identifier)
            callee_mir.name orelse return
        else if (callee_mir.kind == .field_access)
            callee_mir.name orelse return
        else
            return;

        var fsig: ?declarations.FuncSig = null;
        if (self.decls) |d| {
            fsig = d.funcs.get(func_name);
        }
        if (fsig == null) {
            if (callee_mir.kind == .field_access) {
                const obj = callee_mir.children[0];
                const module_name = if (obj.kind == .identifier)
                    obj.name
                else if (obj.kind == .field_access and obj.children.len > 0 and obj.children[0].kind == .identifier)
                    obj.children[0].name
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
        if (actual_arg_count >= sig.param_nodes.len) return;
        var wrote_any = actual_arg_count > 0;
        for (sig.param_nodes[actual_arg_count..]) |p| {
            if (p.* == .param) {
                if (p.param.default_value) |dv| {
                    if (wrote_any) try self.emit(", ");
                    try self.generateExpr(dv);
                    wrote_any = true;
                }
            }
        }
    }

    fn generateCompilerFunc(self: *CodeGen, cf: parser.CompilerFunc) anyerror!void {
        // Map Orhon compiler functions to Zig equivalents
        if (std.mem.eql(u8, cf.name, "typename")) {
            // typename(x) → @typeName(@TypeOf(x))
            try self.emit("@typeName(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit("))");
        } else if (std.mem.eql(u8, cf.name, "typeid")) {
            // typeid(x) → @intFromPtr(@typeName(@TypeOf(x)).ptr)
            try self.emit("@intFromPtr(@typeName(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.emit(")).ptr)");
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
                if (std.mem.eql(u8, name, K.Type.ERROR)) return "anyerror";
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
                    // Native Zig: (Error | T) → anyerror!T, (null | T) → ?T
                    for (u) |t| {
                        if (t.* == .type_named and
                            !std.mem.eql(u8, t.type_named, K.Type.ERROR) and
                            !std.mem.eql(u8, t.type_named, K.Type.NULL))
                        {
                            const inner = try self.typeToZig(t);
                            if (has_error) break :blk try self.allocTypeStr("anyerror!{s}", .{inner});
                            if (has_null) break :blk try self.allocTypeStr("?{s}", .{inner});
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
                    // Handle(T) → _OrhonHandle(zigT) (emitted as file-level helper)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("_OrhonHandle({s})", .{inner});
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
                } else if (std.mem.eql(u8, g.name, "Vector")) {
                    // Vector(N, T) → @Vector(N, T)
                    if (g.args.len >= 2) {
                        const size_str = if (g.args[0].* == .int_literal) g.args[0].int_literal else "0";
                        const elem = try self.typeToZig(g.args[1]);
                        break :blk try self.allocTypeStr("@Vector({s}, {s})", .{ size_str, elem });
                    }
                }
                // Collection types → use import alias (or bare name if included)
                const is_collection = std.mem.eql(u8, g.name, "List") or
                    std.mem.eql(u8, g.name, "Map") or
                    std.mem.eql(u8, g.name, "Set");

                // Inside a generic struct, self-references use @This()
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, g.name, gsn)) break :blk "@This()";
                }

                // User-defined generic type — Name(T, U) → Name(zigT, zigU)
                if (g.args.len > 0) {
                    var buf = std.ArrayListUnmanaged(u8){};
                    defer buf.deinit(self.allocator);
                    if (is_collection and !self.collections_is_included) {
                        const prefix = self.collections_import_alias orelse "collections";
                        try buf.appendSlice(self.allocator, prefix);
                        try buf.append(self.allocator, '.');
                    }
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

