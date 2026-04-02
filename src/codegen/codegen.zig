// codegen.zig — Zig Code Generation pass (pass 11)
// Translates MIR and AST to readable Zig source files.
// One .zig file per Orhon module. Uses std.fmt for output.

const std = @import("std");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const builtins = @import("../builtins.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const module = @import("../module.zig");
const RT = @import("../types.zig").ResolvedType;
const decls_impl = @import("codegen_decls.zig");
const stmts_impl = @import("codegen_stmts.zig");
const exprs_impl = @import("codegen_exprs.zig");
const match_impl = @import("codegen_match.zig");

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
    module_name: []const u8, // current module name — used for zig module re-exports
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
    // MIR annotation table — Phase 1+2 typed annotation pass
    node_map: ?*const mir.NodeMap = null,
    union_registry: ?*const mir.UnionRegistry = null,
    var_types: ?*const std.StringHashMapUnmanaged(mir.NodeInfo) = null,
    // Const auto-borrow: function name → set of param indices promoted to *const T
    const_ref_params: ?*const std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(usize, void)) = null,
    // MIR tree — Phase 3 lowered tree (available for incremental migration)
    mir_root: ?*mir.MirNode = null,
    // Zig-backed module — all declarations are re-exported from {name}_zig
    is_zig_module: bool = false,
    // MIR node for the current function — set by generateFuncMir/generateThreadFuncMir.
    current_func_mir: ?*mir.MirNode = null,
    // Pre-statement hoisting buffer — interpolation temp vars are appended here,
    // flushed to main output before the statement that references them.
    pre_stmts: std.ArrayListUnmanaged(u8) = .{},
    interp_count: u32 = 0,

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
    pub fn getUnionMembers(self: *const CodeGen, node: *parser.Node) ?[]const RT {
        if (self.getNodeInfo(node)) |info| {
            if (info.resolved_type == .union_type) return info.resolved_type.union_type;
        }
        return null;
    }

    /// Check if a function parameter should be promoted to *const T for const auto-borrow.
    pub fn isPromotedParam(self: *const CodeGen, func_name: []const u8, param_idx: usize) bool {
        const crp = self.const_ref_params orelse return false;
        const param_set = crp.get(func_name) orelse return false;
        return param_set.contains(param_idx);
    }

    /// Get the TypeClass of the current function's return type from MIR.
    /// Only valid in MIR-path codegen (current_func_mir set by generateFuncMir).
    pub fn funcReturnTypeClass(self: *const CodeGen) mir.TypeClass {
        if (self.current_func_mir) |m| return m.type_class;
        return .plain;
    }

    /// Get the union members of the current function's return type from MIR.
    /// Only valid in MIR-path codegen (current_func_mir set by generateFuncMir).
    pub fn funcReturnMembers(self: *const CodeGen) ?[]const RT {
        if (self.current_func_mir) |m| {
            if (m.resolved_type == .union_type) return m.resolved_type.union_type;
        }
        return null;
    }

    /// Name-based union member lookup via MIR var_types (fallback).
    pub fn getVarUnionMembers(self: *const CodeGen, name: []const u8) ?[]const RT {
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
    pub fn sanitizeErrorName(self: *CodeGen, msg: []const u8) ![]const u8 {
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
    pub fn getBitfieldName(self: *const CodeGen, node: *parser.Node) ?[]const u8 {
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

    pub fn nodeLoc(self: *const CodeGen, node: *parser.Node) ?errors.SourceLoc {
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
    }

    /// Source location from MirNode — convenience wrapper over nodeLoc.
    pub fn nodeLocMir(self: *const CodeGen, m: *const mir.MirNode) ?errors.SourceLoc {
        return self.nodeLoc(m.ast);
    }

    /// Check if a name is an enum variant in any declared enum
    pub fn isEnumVariant(self: *const CodeGen, name: []const u8) bool {
        const decls = self.decls orelse return false;
        var it = decls.enums.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.variants) |v| {
                if (std.mem.eql(u8, v, name)) return true;
            }
        }
        return false;
    }

    /// Check if an AST node refers to a declared enum type name.
    /// Used by cast() codegen to decide between @intCast and @enumFromInt.
    pub fn isEnumTypeName(self: *const CodeGen, node: *parser.Node) bool {
        const decls = self.decls orelse return false;
        const name = switch (node.*) {
            .type_named => |n| n,
            .identifier => |n| n,
            else => return false,
        };
        return decls.enums.contains(name);
    }

    pub fn deinit(self: *CodeGen) void {
        for (self.type_strings.items) |s| self.allocator.free(s);
        self.type_strings.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.reassigned_vars.deinit(self.allocator);
        self.error_narrowed.deinit(self.allocator);
        self.null_narrowed.deinit(self.allocator);
        self.pre_stmts.deinit(self.allocator);
    }

    /// Get the generated Zig source
    pub fn getOutput(self: *CodeGen) []const u8 {
        return self.output.items;
    }

    pub fn emit(self: *CodeGen, s: []const u8) !void {
        try self.output.appendSlice(self.allocator, s);
    }

    pub fn emitFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.output.appendSlice(self.allocator, s);
    }

    pub fn emitIndent(self: *CodeGen) !void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) {
            try self.emit("    ");
        }
    }

    pub fn emitLine(self: *CodeGen, s: []const u8) !void {
        try self.emitIndent();
        try self.emit(s);
        try self.emit("\n");
    }

    /// Emit a type-name path (a.b.c) from a MIR field_access chain without semantic transforms.
    /// Used only for `is` type-check RHS in MIR-path codegen.
    pub fn emitTypeMirPath(self: *CodeGen, m: *mir.MirNode) anyerror!void {
        if (m.kind == .field_access and m.children.len > 0) {
            try self.emitTypeMirPath(m.children[0]);
            try self.emit(".");
            try self.emit(m.name orelse "");
        } else {
            try self.emit(m.name orelse "");
        }
    }

    /// Flush hoisted pre-statement declarations (interpolation temp vars) to main output.
    /// Must be called before emitting the statement that references the hoisted vars.
    pub fn flushPreStmts(self: *CodeGen) !void {
        if (self.pre_stmts.items.len == 0) return;
        try self.output.appendSlice(self.allocator, self.pre_stmts.items);
        self.pre_stmts.clearRetainingCapacity();
    }

    pub fn emitLineFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
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

        // Auto-import str if not explicitly imported — needed for string method dispatch
        if (self.str_import_alias == null and !self.str_is_included) {
            self.str_import_alias = "str";
            try self.emit("const str = @import(\"_orhon_str\");\n");
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

    /// Generate a Zig union tag name from an Orhon type name: i32 → _i32
    pub fn unionTagName(self: *CodeGen, orhon_name: []const u8) ![]const u8 {
        return try self.allocTypeStr("_{s}", .{orhon_name});
    }

    /// Infer which union tag a value belongs to based on its literal type.
    pub fn inferArbitraryUnionTag(value: *parser.Node, members_rt: ?[]const RT) ?[]const u8 { return exprs_impl.inferArbitraryUnionTag(value, members_rt); }

    const TypeKind = enum { int, float, string, bool_ };

    pub fn matchesKind(n: []const u8, kind: TypeKind) bool { return exprs_impl.matchesKind(n, kind); }

    /// Search union members (MIR resolved types) for a type matching the given kind.
    pub fn findMemberByKind(members_rt: ?[]const RT, kind: TypeKind) ?[]const u8 { return exprs_impl.findMemberByKind(members_rt, kind); }

    /// MIR-path: wrap a MirNode expression in an arbitrary union tag.
    pub fn generateArbitraryUnionWrappedExprMir(self: *CodeGen, m: *mir.MirNode, members_rt: ?[]const RT) anyerror!void { return exprs_impl.generateArbitraryUnionWrappedExprMir(self, m, members_rt); }

    /// Infer union tag from MirNode literal_kind.
    pub fn inferArbitraryUnionTagMir(m: *const mir.MirNode, members_rt: ?[]const RT) ?[]const u8 { return exprs_impl.inferArbitraryUnionTagMir(m, members_rt); }

    /// Check if an identifier is a declared Error constant
    pub fn isErrorConstant(self: *const CodeGen, name: []const u8) bool {
        if (self.decls) |decls| {
            if (decls.vars.get(name)) |v| {
                if (v.type_) |t| {
                    return t == .err;
                }
            }
        }
        return false;
    }

    pub fn generateImport(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .import_decl) return;
        const imp = node.import_decl;

        if (imp.is_c_header) {
            const alias = imp.alias orelse imp.path;
            try self.emitLineFmt("// WARNING: C header import\nconst {s} = @cImport(@cInclude({s}));", .{ alias, imp.path });
            return;
        }

        // All inter-module imports use named module imports (no .zig extension).
        // Every Orhon module is registered as a named module in the generated build.zig
        // via createModule + addImport. This prevents Zig's "file exists in two modules"
        // error when multiple targets import the same module.
        const ext = "";

        // Track import aliases for str and collections
        if (std.mem.eql(u8, imp.path, "str")) {
            if (imp.is_include) {
                self.str_is_included = true;
            } else {
                self.str_import_alias = imp.alias orelse "str";
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
    pub fn generateTopLevelMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
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

    /// Emit a re-export for a zig-backed module declaration from the named zig module.
    pub fn generateZigReExport(self: *CodeGen, name: []const u8, is_pub: bool) anyerror!void { return decls_impl.generateZigReExport(self, name, is_pub); }

    /// MIR-path function codegen — reads all data from MirNode.
    pub fn generateFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateFuncMir(self, m); }

    /// MIR-path thread function codegen.
    pub fn generateThreadFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateThreadFuncMir(self, m); }

    /// MIR-path collectAssigned — traverses MirNode tree.
    pub fn collectAssignedMir(m: *mir.MirNode, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void { return decls_impl.collectAssignedMir(m, set, alloc); }

    pub fn getRootIdentMir(m: *const mir.MirNode) ?[]const u8 { return decls_impl.getRootIdentMir(m); }


    // ============================================================
    // STRUCTS
    // ============================================================

    /// MIR-path struct codegen — iterates MirNode children instead of AST members.
    pub fn generateStructMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateStructMir(self, m); }

    // ============================================================
    // ENUMS
    // ============================================================

    /// MIR-path enum codegen — iterates MirNode children instead of AST members.
    pub fn generateEnumMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateEnumMir(self, m); }

    // ============================================================
    // BITFIELDS
    // ============================================================

    pub fn generateBitfield(self: *CodeGen, b: parser.BitfieldDecl) anyerror!void { return decls_impl.generateBitfield(self, b); }

    pub fn generateBitfieldMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateBitfieldMir(self, m); }

    // ============================================================
    // VAR / CONST DECLARATIONS
    // ============================================================

    pub fn isTypeAlias(type_annotation: ?*parser.Node) bool { return decls_impl.isTypeAlias(type_annotation); }

    // ============================================================
    // TOP-LEVEL DISPATCH
    // ============================================================

    pub fn generateTopLevelDeclMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateTopLevelDeclMir(self, m); }

    pub fn generateTestMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateTestMir(self, m); }

    // ============================================================
    // BLOCKS AND STATEMENTS
    // ============================================================

    pub fn generateBlockMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return stmts_impl.generateBlockMir(self, m); }

    pub fn generateBodyStatements(self: *CodeGen, m: *mir.MirNode) anyerror!void { return stmts_impl.generateBodyStatements(self, m); }

    pub fn generateStatementMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return stmts_impl.generateStatementMir(self, m); }

    pub fn generateStmtDeclMir(self: *CodeGen, m: *mir.MirNode, decl_keyword: []const u8) anyerror!void { return stmts_impl.generateStmtDeclMir(self, m, decl_keyword); }

    // ============================================================
    // MIR EXPRESSIONS
    // ============================================================

    pub fn generateExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.generateExprMir(self, m); }

    pub fn generateCoercedExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.generateCoercedExprMir(self, m); }

    pub fn mirIsString(m: *const mir.MirNode) bool { return exprs_impl.mirIsString(m); }

    pub fn mirIsVector(m: *const mir.MirNode) bool { return exprs_impl.mirIsVector(m); }

    pub fn mirGetBitfieldName(m: *const mir.MirNode, decls_opt: ?*declarations.DeclTable) ?[]const u8 { return exprs_impl.mirGetBitfieldName(m, decls_opt); }

    pub fn generateContinueExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.generateContinueExprMir(self, m); }

    pub fn writeRangeExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.writeRangeExprMir(self, m); }

    pub fn generateForMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.generateForMir(self, m); }

    pub fn generateDestructMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return exprs_impl.generateDestructMir(self, m); }

    pub fn mirContainsIdentifier(m: *mir.MirNode, name: []const u8) bool { return match_impl.mirContainsIdentifier(m, name); }

    pub fn hasGuardedArm(arms: []*mir.MirNode) bool { return match_impl.hasGuardedArm(arms); }

    pub fn generateGuardedMatchMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateGuardedMatchMir(self, m); }

    pub fn generateMatchMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateMatchMir(self, m); }

    pub fn generateTypeMatchMir(self: *CodeGen, m: *mir.MirNode, is_null_union: bool) anyerror!void { return match_impl.generateTypeMatchMir(self, m, is_null_union); }

    pub fn generateStringMatchMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateStringMatchMir(self, m); }

    pub fn generateInterpolatedStringMirInline(self: *CodeGen, parts: []const parser.InterpolatedPart, expr_children: []*mir.MirNode) anyerror!void { return match_impl.generateInterpolatedStringMirInline(self, parts, expr_children); }

    pub fn generateInterpolatedStringMir(self: *CodeGen, parts: []const parser.InterpolatedPart, expr_children: []*mir.MirNode) anyerror!void { return match_impl.generateInterpolatedStringMir(self, parts, expr_children); }

    pub fn generateCollectionExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateCollectionExprMir(self, m); }

    pub fn generatePtrCoercionMir(self: *CodeGen, kind: []const u8, type_node: *parser.Node, val_m: *mir.MirNode) anyerror!void { return match_impl.generatePtrCoercionMir(self, kind, type_node, val_m); }

    pub fn generateCompilerFuncMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateCompilerFuncMir(self, m); }

    pub fn generateWrappingExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateWrappingExprMir(self, m); }

    pub fn generateSaturatingExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateSaturatingExprMir(self, m); }

    pub fn generateOverflowExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return match_impl.generateOverflowExprMir(self, m); }

    pub fn fillDefaultArgsMir(self: *CodeGen, callee_mir: *const mir.MirNode, actual_arg_count: usize) anyerror!void { return match_impl.fillDefaultArgsMir(self, callee_mir, actual_arg_count); }

    // ============================================================
    // TYPE TRANSLATION
    // ============================================================

    /// Allocate a type string and track it for cleanup
    pub fn allocTypeStr(self: *CodeGen, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.type_strings.append(self.allocator, s);
        return s;
    }

    pub fn typeToZig(self: *CodeGen, node: *parser.Node) anyerror![]const u8 {
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
                // Arbitrary union: (i32 | f32 | String) → union(enum) { _i32: i32, _f32: f32, _String: []const u8 }
                // Note: Error and null are banned from unions — use ErrorUnion(T) and NullUnion(T) instead.
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
                const inner = try self.typeToZig(p.elem);
                break :blk switch (p.kind) {
                    .const_ref => try self.allocTypeStr("*const {s}", .{inner}),
                    .mut_ref => try self.allocTypeStr("*{s}", .{inner}),
                };
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
                if (std.mem.eql(u8, g.name, builtins.BT.ERROR_UNION)) {
                    // ErrorUnion(T) → anyerror!T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("anyerror!{s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.NULL_UNION)) {
                    // NullUnion(T) → ?T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("?{s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Thread")) {
                    break :blk "std.Thread"; // Thread handle type
                } else if (std.mem.eql(u8, g.name, builtins.BT.HANDLE)) {
                    // Handle(T) → _OrhonHandle(zigT) (emitted as file-level helper)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("_OrhonHandle({s})", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.PTR)) {
                    // Ptr(T) → *const T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("*const {s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.RAW_PTR)) {
                    // RawPtr(T) → [*]T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]{s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.VOLATILE_PTR)) {
                    // VolatilePtr(T) → [*]volatile T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]volatile {s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.VECTOR)) {
                    // Vector(N, T) → @Vector(N, T)
                    if (g.args.len >= 2) {
                        const size_str = if (g.args[0].* == .int_literal) g.args[0].int_literal else "0";
                        const elem = try self.typeToZig(g.args[1]);
                        break :blk try self.allocTypeStr("@Vector({s}, {s})", .{ size_str, elem });
                    }
                }
                // Inside a generic struct, self-references use @This()
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, g.name, gsn)) break :blk "@This()";
                }

                // Generic type — Name(T, U) → Name(zigT, zigU)
                if (g.args.len > 0) {
                    var buf = std.ArrayListUnmanaged(u8){};
                    defer buf.deinit(self.allocator);
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
            // Generic type constructors in expression position: Ptr(T), List(T), Map(K,V), etc.
            // In type alias context (const Name: type = Ptr(u8)), the RHS is a call_expr.
            // Reuse the type_generic branch by extracting callee name and arg types.
            .call_expr => |c| blk: {
                const callee_name = if (c.callee.* == .identifier) c.callee.identifier else break :blk "anyopaque";
                // Reuse type_generic logic by treating call_expr as type_generic
                const g_node = try self.allocator.create(parser.Node);
                g_node.* = .{ .type_generic = .{ .name = callee_name, .args = c.args } };
                defer self.allocator.destroy(g_node);
                break :blk try self.typeToZig(g_node);
            },
            // Binary expr in type alias context: (null | T) or (Error | T) parsed as binary '|'
            // Try to detect error/null union patterns.
            .binary_expr => |b| blk: {
                if (!std.mem.eql(u8, b.op, "|")) break :blk "anyopaque";
                // Check for (Error | T) or (null | T) patterns
                const left_is_error = b.left.* == .identifier and std.mem.eql(u8, b.left.identifier, builtins.BT.ERROR);
                const left_is_null = b.left.* == .null_literal;
                if (left_is_error) {
                    const inner = try self.typeToZig(b.right);
                    break :blk try self.allocTypeStr("anyerror!{s}", .{inner});
                }
                if (left_is_null) {
                    const inner = try self.typeToZig(b.right);
                    break :blk try self.allocTypeStr("?{s}", .{inner});
                }
                break :blk "anyopaque";
            },
            else => "anyopaque",
        };
    }
};

pub fn opToZig(op: []const u8) []const u8 { return match_impl.opToZig(op); }

/// Check if a field name is a type name used for union value access (result.i32, result.User)
pub fn isResultValueField(name: []const u8, decls: ?*declarations.DeclTable) bool { return match_impl.isResultValueField(name, decls); }

/// Extract the value type from an ErrorUnion(T) or NullUnion(T) type annotation.
/// Returns null if not a recognized core type wrapper.
/// Available at file scope so helper modules (codegen_exprs.zig) can call codegen.extractValueType().
pub fn extractValueType(node: *parser.Node) ?*parser.Node {
    if (node.* == .type_generic) {
        const g = node.type_generic;
        if ((std.mem.eql(u8, g.name, builtins.BT.ERROR_UNION) or std.mem.eql(u8, g.name, builtins.BT.NULL_UNION)) and g.args.len > 0) {
            return g.args[0];
        }
    }
    return null;
}

/// File-scope isTypeAlias for helper modules.
pub fn isTypeAlias(type_annotation: ?*parser.Node) bool { return decls_impl.isTypeAlias(type_annotation); }

/// File-scope mirIsString for helper modules (codegen_match.zig needs this without importing exprs directly).
pub fn mirIsString(m: *const mir.MirNode) bool { return exprs_impl.mirIsString(m); }

/// File-scope mirIsVector for helper modules.
pub fn mirIsVector(m: *const mir.MirNode) bool { return exprs_impl.mirIsVector(m); }

/// File-scope mirGetBitfieldName for helper modules.
pub fn mirGetBitfieldName(m: *const mir.MirNode, decls_opt: ?*declarations.DeclTable) ?[]const u8 { return exprs_impl.mirGetBitfieldName(m, decls_opt); }

/// Check if a type annotation is a pointer wrapper type (Ptr/RawPtr/VolatilePtr) with an inner type.
/// Returns the wrapper name and inner type arg, or null if not a pointer coercion target.
pub const PtrCoercionInfo = struct { name: []const u8, inner_type: *parser.Node };
pub fn getPtrCoercionTarget(type_annotation: ?*parser.Node) ?PtrCoercionInfo {
    const t = type_annotation orelse return null;
    if (t.* != .type_generic) return null;
    if (t.type_generic.args.len == 0) return null;
    if (!builtins.isPtrType(t.type_generic.name)) return null;
    return .{ .name = t.type_generic.name, .inner_type = t.type_generic.args[0] };
}

/// File-scope mirContainsIdentifier for helper modules (codegen_match.zig calls this recursively).
pub fn mirContainsIdentifier(m: *mir.MirNode, name: []const u8) bool { return match_impl.mirContainsIdentifier(m, name); }

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

