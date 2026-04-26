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
const types = @import("../types.zig");
const RT = types.ResolvedType;
const decls_impl = @import("codegen_decls.zig");
const stmts_impl = @import("codegen_stmts.zig");
const exprs_impl = @import("codegen_exprs.zig");
const match_impl = @import("codegen_match.zig");
const mir_store_mod = @import("../mir_store.zig");
const mir_typed = @import("../mir_typed.zig");
const type_store_mod = @import("../type_store.zig");
const ast_store_mod = @import("../ast_store.zig");

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
    module_name: []const u8, // current module name — used for zig module re-exports
    reassigned_vars: std.StringHashMapUnmanaged(void), // vars assigned after declaration in current func
    locs: ?*const parser.LocMap, // AST node → source location (set by main.zig)
    generic_struct_name: ?[]const u8, // inside a generic struct — name to replace with @This()
    in_struct: bool, // inside any struct (generic or not) — Self maps to @This()
    all_decls: ?*std.StringHashMap(*declarations.DeclTable), // all module decl tables for cross-module default args
    file_offsets: []const module.FileOffset, // combined-line → original file+line
    module_builds: ?*const std.StringHashMapUnmanaged(module.BuildType), // imported module → build type
    // Track variables narrowed by `is Error` or `is null` checks — fallback for type-name
    // unwrap when MIR type classification is unavailable (overflow results, cross-module calls).
    error_narrowed: std.StringHashMapUnmanaged(void) = .{},
    null_narrowed: std.StringHashMapUnmanaged(void) = .{},
    // Track the captured error variable name per scope for `.Error` → `@errorName()`
    // MIR annotation table — Phase 1+2 typed annotation pass
    union_registry: ?*mir.UnionRegistry = null,
    needs_unions_import: bool = false,
    /// Module currently being emitted — used to attribute arity registrations
    /// to the right module for incremental cache replay.
    current_module_name: []const u8 = "",
    // ── MirStore-based fields (Phase C) ─────────────────────────
    mir_store: ?*const mir_store_mod.MirStore = null,
    mir_root_idx: mir_store_mod.MirNodeIndex = .none,
    mir_type_store: ?*const type_store_mod.TypeStore = null,
    /// AstNodeIndex → MirNodeIndex reverse map built from MirStore in generate().
    span_to_mir: std.AutoHashMapUnmanaged(ast_store_mod.AstNodeIndex, mir_store_mod.MirNodeIndex) = .{},
    /// AstNodeIndex → *parser.Node bridge from ast_conv.ConvContext.reverse_map.
    /// Needed for typeToZig calls when type annotations are stored as AstNodeIndex in MirStore.
    ast_reverse_map: ?*const std.AutoHashMap(ast_store_mod.AstNodeIndex, *parser.Node) = null,
    // Zig-backed module — all declarations are re-exported from {name}_zig
    is_zig_module: bool = false,
    // Mixed module — user .orh + .zig sidecar; body-less decls re-exported from {name}_zig
    has_zig_sidecar: bool = false,
    // Tracks emitted declaration names for deduplication in mixed modules
    emitted_names: std.StringHashMapUnmanaged(void) = .{},
    // MirStore index for the current function — set by generateFuncMir (MirStore path).
    current_func_idx: mir_store_mod.MirNodeIndex = .none,
    // Pre-statement hoisting buffer — interpolation temp vars are appended here,
    // flushed to main output before the statement that references them.
    pre_stmts: std.ArrayListUnmanaged(u8) = .{},
    interp_count: u32 = 0,
    // Source map — zig_line → orh_file:orh_line, built during emit, one entry per decl/stmt.
    source_map: std.ArrayListUnmanaged(module.SourceMapEntry) = .{},
    // Match variable substitution — inside match arm bodies, the original variable
    // name compiles as the Zig capture variable (e.g., "result" → "_match_val").
    // Saved/restored for nested match support.
    match_var_subst: ?struct { original: []const u8, capture: []const u8, eff_tc: ?mir.TypeClass = null } = null,
    narrowing_count: u32 = 0, // unique counter for narrowing binding names

    /// Whether the current function is a compt function (all loops should be inline).
    pub fn inComptFunc(self: *const CodeGen) bool {
        if (self.current_func_idx != .none) {
            if (self.mir_store) |store| {
                const rec = mir_typed.Func.unpack(store, self.current_func_idx);
                return (rec.flags & 2) != 0; // FLAG_COMPT
            }
        }
        return false;
    }

    /// Get the TypeClass of the current function's return type from MIR.
    /// Only valid in MIR-path codegen (current_func_mir set by generateFuncMir).
    pub fn funcReturnTypeClass(self: *const CodeGen) mir.TypeClass {
        if (self.current_func_idx != .none) {
            if (self.mir_store) |store| {
                return store.getNode(self.current_func_idx).type_class;
            }
        }
        return .plain;
    }

    /// Get the union members of the current function's return type from MIR.
    /// Only valid in MIR-path codegen (current_func_mir set by generateFuncMir).
    pub fn funcReturnMembers(self: *const CodeGen) ?[]const RT {
        if (self.current_func_idx != .none) {
            if (self.mir_store) |store| {
                const entry = store.getNode(self.current_func_idx);
                if (entry.type_id != .none) {
                    const rt = store.types.get(entry.type_id);
                    if (rt == .union_type) return rt.union_type;
                }
            }
        }
        return null;
    }

    /// When this module is a pure Zig-backed module, emit a re-export for the
    /// given declaration and signal the caller to stop. Caller returns early on true.
    pub fn reExportIfZigModule(self: *CodeGen, name: []const u8, is_pub: bool) !bool {
        if (!self.is_zig_module) return false;
        try self.generateZigReExport(name, is_pub);
        return true;
    }

    /// When this module has a Zig sidecar, emit a re-export for the given
    /// declaration and signal the caller to stop. Used for body-less decls
    /// that live in the sidecar. Caller returns early on true.
    pub fn reExportIfSidecar(self: *CodeGen, name: []const u8, is_pub: bool) !bool {
        if (!self.has_zig_sidecar) return false;
        try self.generateZigReExport(name, is_pub);
        return true;
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
            .module_name = "",
            .reassigned_vars = .{},
            .generic_struct_name = null,
            .in_struct = false,
            .all_decls = null,
            .locs = null,
            .file_offsets = &.{},
            .module_builds = null,
        };
    }

    pub fn nodeLoc(self: *const CodeGen, node: *parser.Node) ?errors.SourceLoc {
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
    }

    pub fn deinit(self: *CodeGen) void {
        for (self.type_strings.items) |s| self.allocator.free(s);
        self.type_strings.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.reassigned_vars.deinit(self.allocator);
        self.error_narrowed.deinit(self.allocator);
        self.null_narrowed.deinit(self.allocator);
        self.pre_stmts.deinit(self.allocator);
        self.emitted_names.deinit(self.allocator);
        self.span_to_mir.deinit(self.allocator);
        self.source_map.deinit(self.allocator);
    }

    /// Get the generated Zig source
    pub fn getOutput(self: *CodeGen) []const u8 {
        return self.output.items;
    }

    /// Record a zig_line → orh_file:orh_line entry for the current emit position.
    /// Called before emitting each top-level declaration and each statement.
    /// Silently skips if the MirNode has no span or the span has no AST node.
    pub fn recordLoc(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) !void {
        const store = self.mir_store orelse return;
        const span = store.getNode(idx).span;
        if (span == .none) return;
        const ast_node = self.getAstNode(span) orelse return;
        const loc = self.nodeLoc(ast_node) orelse return;
        const zig_line: u32 = @intCast(std.mem.count(u8, self.output.items, "\n") + 1);
        try self.source_map.append(self.allocator, .{
            .zig_line = zig_line,
            .orh_file = loc.file,
            .orh_line = @intCast(loc.line),
        });
    }

    /// Return the built source map. Entries are sorted by zig_line (emission order).
    pub fn getSourceMap(self: *const CodeGen) []const module.SourceMapEntry {
        return self.source_map.items;
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

    /// Look up the MirNodeIndex for an AstNodeIndex span. Returns .none if not found.
    pub fn getMirNodeForSpan(self: *const CodeGen, span: ast_store_mod.AstNodeIndex) mir_store_mod.MirNodeIndex {
        return self.span_to_mir.get(span) orelse .none;
    }

    /// Bridge AstNodeIndex → *parser.Node via ast_reverse_map. Returns null if not wired or not found.
    pub fn getAstNode(self: *const CodeGen, idx: ast_store_mod.AstNodeIndex) ?*parser.Node {
        if (self.ast_reverse_map) |rm| return rm.get(idx);
        return null;
    }

    /// Generate Zig source from a program AST
    pub fn generate(self: *CodeGen, ast: *parser.Node, module_name: []const u8) !void {
        if (ast.* != .program) return;
        self.module_name = module_name;

        // Build AstNodeIndex → MirNodeIndex reverse map from MirStore.
        if (self.mir_store) |store| {
            const n = store.nodes.len;
            try self.span_to_mir.ensureTotalCapacity(self.allocator, @intCast(n));
            var i: u32 = 1; // skip sentinel at index 0
            while (i < n) : (i += 1) {
                const idx: mir_store_mod.MirNodeIndex = @enumFromInt(i);
                const entry = store.getNode(idx);
                if (entry.span != .none) {
                    self.span_to_mir.putAssumeCapacityNoClobber(entry.span, idx);
                }
            }
        }

        // File header — only Zig std, no runtime libraries
        try self.emitFmt("// generated from module {s} — do not edit\n", .{module_name});
        try self.emit("const std = @import(\"std\");\n");

        // Record position for optional _unions import (inserted after generation)
        const unions_import_pos = self.output.items.len;

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

        try self.emit("\n");

        // Generate top-level declarations.
        const store = self.mir_store.?;
        for (mir_typed.Block.getStmts(store, self.mir_root_idx)) |idx| {
            try self.generateTopLevelMir(idx);
            try self.emit("\n");
        }

        // Insert _unions import if any arbitrary unions were used in this module
        if (self.needs_unions_import) {
            const import_line = "const _unions = @import(\"_unions\");\n";
            try self.output.insertSlice(self.allocator, unions_import_pos, import_line);
        }
    }

    /// Generate a Zig union tag name from an Orhon type name: i32 → _i32
    pub fn unionTagName(self: *CodeGen, orhon_name: []const u8) ![]const u8 {
        return try self.allocTypeStr("_{s}", .{orhon_name});
    }

    /// MIR-path: wrap a MirNode expression in an arbitrary union tag.
    pub fn generateArbitraryUnionWrappedExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex, members_rt: ?[]const RT) anyerror!void { return exprs_impl.generateArbitraryUnionWrappedExprMir(self, idx, members_rt); }

    pub fn generateImport(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .import_decl) return;
        const imp = node.import_decl;

        // All inter-module imports use named module imports (no .zig extension).
        // Every Orhon module is registered as a named module in the generated build.zig
        // via createModule + addImport. This prevents Zig's "file exists in two modules"
        // error when multiple targets import the same module.
        const ext = "";

        if (imp.is_include) {
            // include — dump all symbols into local namespace via individual re-exports
            const hidden = try std.fmt.allocPrint(self.allocator, "_included_{s}", .{imp.path});
            defer self.allocator.free(hidden);
            try self.emitLineFmt("const {s} = @import(\"{s}{s}\");", .{ hidden, imp.path, ext });
            // Re-export each pub declaration from the included module
            if (self.all_decls) |ad| {
                if (ad.get(imp.path)) |dt| {
                    var iter = dt.symbols.iterator();
                    while (iter.next()) |entry| {
                        // Skip type aliases — handled separately below in the historic
                        // pattern; the previous code only re-exported funcs/structs/enums/vars/blueprints.
                        const should_export = switch (entry.value_ptr.*) {
                            .func => |s| s.is_pub,
                            .@"struct" => |s| s.is_pub,
                            .@"enum" => |s| s.is_pub,
                            .@"var" => |s| s.is_pub,
                            .blueprint => |s| s.is_pub,
                            .handle, .type_alias => false,
                        };
                        if (should_export)
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
    pub fn generateTopLevelMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void {
        // MirStore path — preferred when MirStore is available and idx is a real entry
        if (self.mir_store) |store| {
            const raw: u32 = @intFromEnum(idx);
            if (raw > 0 and raw < store.nodes.len) {
                const entry = store.getNode(idx);
                // Deduplicate: mixed modules merge sidecar .orh files, which can duplicate
                // declarations from the user's .orh. Skip if we already emitted this name.
                if (self.has_zig_sidecar) {
                    const name_opt: ?[]const u8 = switch (entry.tag) {
                        .func => store.strings.get(mir_typed.Func.unpack(store, idx).name),
                        .struct_def => store.strings.get(mir_typed.StructDef.unpack(store, idx).name),
                        .enum_def => store.strings.get(mir_typed.EnumDef.unpack(store, idx).name),
                        .handle_def => store.strings.get(mir_typed.HandleDef.unpack(store, idx).name),
                        .var_decl => store.strings.get(mir_typed.VarDecl.unpack(store, idx).name),
                        else => null,
                    };
                    if (name_opt) |name| {
                        if (self.emitted_names.contains(name)) return;
                        try self.emitted_names.put(self.allocator, name, {});
                    }
                }
                switch (entry.tag) {
                    .func => {
                        const prev_idx = self.current_func_idx;
                        self.current_func_idx = idx;
                        defer self.current_func_idx = prev_idx;
                        try self.generateFuncMir(idx);
                    },
                    .struct_def => try self.generateStructMir(idx),
                    .enum_def => try self.generateEnumMir(idx),
                    .handle_def => try self.generateHandleMir(idx),
                    .var_decl => try self.generateTopLevelDeclMir(idx),
                    .test_def => try self.generateTestMir(idx),
                    else => {},
                }
                return;
            }
        }
    }

    // ============================================================
    // FUNCTIONS
    // ============================================================

    /// Emit a re-export for a zig-backed module declaration from the named zig module.
    pub fn generateZigReExport(self: *CodeGen, name: []const u8, is_pub: bool) anyerror!void { return decls_impl.generateZigReExport(self, name, is_pub); }

    /// MIR-path function codegen — reads all data from MirNode.
    pub fn generateFuncMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateFuncMir(self, idx); }


    // ============================================================
    // STRUCTS
    // ============================================================

    /// MIR-path struct codegen — iterates MirNode children instead of AST members.
    pub fn generateStructMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateStructMir(self, idx); }

    // ============================================================
    // ENUMS
    // ============================================================

    /// MIR-path enum codegen — iterates MirNode children instead of AST members.
    pub fn generateEnumMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateEnumMir(self, idx); }

    // ============================================================
    // HANDLES
    // ============================================================

    /// MIR-path handle codegen — emits const Name = *anyopaque;
    pub fn generateHandleMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateHandleMir(self, idx); }

    // ============================================================
    // VAR / CONST DECLARATIONS
    // ============================================================

    pub fn isTypeAlias(type_annotation: ?*parser.Node) bool { return decls_impl.isTypeAlias(type_annotation); }

    // ============================================================
    // TOP-LEVEL DISPATCH
    // ============================================================

    pub fn generateTopLevelDeclMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateTopLevelDeclMir(self, idx); }

    pub fn generateTestMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return decls_impl.generateTestMir(self, idx); }

    // ============================================================
    // BLOCKS AND STATEMENTS
    // ============================================================

    pub fn generateBlockMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return stmts_impl.generateBlockMir(self, idx); }

    pub fn generateBodyStatements(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return stmts_impl.generateBodyStatements(self, idx); }

    pub fn generateStatementMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return stmts_impl.generateStatementMir(self, idx); }

    pub fn generateStmtDeclMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex, decl_keyword: []const u8) anyerror!void { return stmts_impl.generateStmtDeclMir(self, idx, decl_keyword); }

    // ============================================================
    // MIR EXPRESSIONS
    // ============================================================

    pub fn generateExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.generateExprMir(self, idx); }

    pub fn generateCoercedExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.generateCoercedExprMir(self, idx); }

    pub fn mirIsStringFromStore(store: *const mir_store_mod.MirStore, idx: mir_store_mod.MirNodeIndex) bool { return exprs_impl.mirIsStringFromStore(store, idx); }

    pub fn generateContinueExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.generateContinueExprMir(self, idx); }

    pub fn writeRangeExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.writeRangeExprMir(self, idx); }

    pub fn generateForMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.generateForMir(self, idx); }

    pub fn generateDestructMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return exprs_impl.generateDestructMir(self, idx); }

    pub fn mirContainsIdentifier(store: *const mir_store_mod.MirStore, idx: mir_store_mod.MirNodeIndex, name: []const u8) bool { return match_impl.mirContainsIdentifier(store, idx, name); }

    pub fn generateGuardedMatchMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateGuardedMatchMir(self, idx); }

    pub fn generateMatchMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateMatchMir(self, idx); }

    pub fn generateTypeMatchMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex, is_null_union: bool) anyerror!void { return match_impl.generateTypeMatchMir(self, idx, is_null_union); }

    pub fn generateStringMatchMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateStringMatchMir(self, idx); }

    pub fn generateInterpolatedStringMirFromStore(self: *CodeGen, store: *const mir_store_mod.MirStore, parts_start: u32, parts_end: u32) anyerror!void { return match_impl.generateInterpolatedStringMirFromStore(self, store, parts_start, parts_end); }

    pub fn generateCompilerFuncMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateCompilerFuncMir(self, idx); }

    pub fn generateWrappingExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateWrappingExprMir(self, idx); }

    pub fn generateSaturatingExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateSaturatingExprMir(self, idx); }

    pub fn generateOverflowExprMir(self: *CodeGen, idx: mir_store_mod.MirNodeIndex) anyerror!void { return match_impl.generateOverflowExprMir(self, idx); }

    pub fn fillDefaultArgsMir(self: *CodeGen, callee_idx: mir_store_mod.MirNodeIndex, actual_arg_count: usize) anyerror!void { return match_impl.fillDefaultArgsMir(self, callee_idx, actual_arg_count); }

    // ============================================================
    // TYPE TRANSLATION
    // ============================================================

    /// Allocate a type string and track it for cleanup
    pub fn allocTypeStr(self: *CodeGen, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.type_strings.append(self.allocator, s);
        return s;
    }

    /// Sanitize a type string into a valid Zig identifier for union tag names.
    /// Replaces non-alphanumeric/underscore characters with underscores,
    /// collapsing runs of underscores into one.
    fn sanitizeTagName(self: *CodeGen, raw: []const u8) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        var prev_underscore = true; // suppress leading underscore
        for (raw) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                try buf.append(self.allocator, c);
                prev_underscore = false;
            } else if (!prev_underscore) {
                try buf.append(self.allocator, '_');
                prev_underscore = true;
            }
        }
        // Trim trailing underscore
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') {
            buf.items.len -= 1;
        }
        if (buf.items.len == 0) return "_anon";
        return try self.allocTypeStr("{s}", .{buf.items});
    }

    /// Build a `_unions.OrhonUnionN` instantiation from resolved RT members.
    /// Sort key: RT.name() for flat types (.named, .primitive, .err, .null_type, .type_param),
    /// Zig output string for compound types — matches the annotator's sort order.
    fn canonicalUnionRefRT(self: *CodeGen, members: []const RT) anyerror![]const u8 {
        const Pair = struct { sort_key: []const u8, zig: []const u8 };
        var pairs = std.ArrayListUnmanaged(Pair){};
        defer pairs.deinit(self.allocator);
        for (members) |m| {
            const zig = try self.zigOfRT(m);
            const sort_key: []const u8 = switch (m) {
                .named, .primitive, .err, .null_type, .type_param => m.name(),
                else => zig,
            };
            try pairs.append(self.allocator, .{ .sort_key = sort_key, .zig = zig });
        }
        std.mem.sort(Pair, pairs.items, {}, struct {
            fn lt(_: void, a: Pair, b: Pair) bool {
                return std.mem.lessThan(u8, a.sort_key, b.sort_key);
            }
        }.lt);

        const arity = pairs.items.len;
        if (self.union_registry) |reg| {
            try reg.registerArity(self.current_module_name, arity);
        }

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try buf.writer(self.allocator).print("_unions.OrhonUnion{d}(", .{arity});
        for (pairs.items, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, p.zig);
        }
        try buf.append(self.allocator, ')');
        self.needs_unions_import = true;
        return try self.allocTypeStr("{s}", .{buf.items});
    }

    /// Write the Zig type string for `rt` to `w`. No intermediate allocations.
    fn zigOfRTInner(self: *CodeGen, rt: RT, w: anytype) anyerror!void {
        switch (rt) {
            .primitive => |p| try w.writeAll(p.toZig()),
            .named => |n| {
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, n, gsn)) {
                        try w.writeAll("@This()");
                        return;
                    }
                }
                try w.writeAll(types.Primitive.nameToZig(n));
            },
            .err => try w.writeAll("anyerror"),
            .null_type => try w.writeAll("null"),
            .slice => |elem| {
                try w.writeAll("[]");
                try self.zigOfRTInner(elem.*, w);
            },
            .array => |a| {
                const size_text = exprToString(a.size);
                try w.print("[{s}]", .{size_text});
                try self.zigOfRTInner(a.elem.*, w);
            },
            .ptr => |p| {
                switch (p.kind) {
                    .const_ref => try w.writeAll("*const "),
                    .mut_ref => try w.writeAll("*"),
                }
                try self.zigOfRTInner(p.elem.*, w);
            },
            .func_ptr => |f| {
                try w.writeAll("*const fn (");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try self.zigOfRTInner(p, w);
                }
                try w.writeAll(") ");
                try self.zigOfRTInner(f.return_type.*, w);
            },
            .generic => |g| {
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, g.name, gsn)) {
                        try w.writeAll("@This()");
                        return;
                    }
                }
                if (types.Primitive.fromName(g.name) == .vector and g.args.len >= 2) {
                    // Vector(N, T) → @Vector(N, T); first arg is size stored as .named = "N"
                    const size_str: []const u8 = switch (g.args[0]) {
                        .named => |n| n,
                        .primitive => |p| p.toName(),
                        else => "0",
                    };
                    try w.print("@Vector({s}, ", .{size_str});
                    try self.zigOfRTInner(g.args[1], w);
                    try w.writeByte(')');
                    return;
                }
                if (g.args.len > 0) {
                    try w.writeAll(g.name);
                    try w.writeByte('(');
                    for (g.args, 0..) |arg, i| {
                        if (i > 0) try w.writeAll(", ");
                        try self.zigOfRTInner(arg, w);
                    }
                    try w.writeByte(')');
                } else {
                    try w.writeAll(g.name);
                }
            },
            .tuple => |fields| {
                try w.writeAll("struct { ");
                for (fields) |f| {
                    try w.print("{s}: ", .{f.name});
                    try self.zigOfRTInner(f.type_, w);
                    try w.writeAll(", ");
                }
                try w.writeAll("}");
            },
            .union_type => |members| {
                var has_error = false;
                var has_null = false;
                var others = std.ArrayListUnmanaged(RT){};
                defer others.deinit(self.allocator);
                for (members) |m| {
                    if (m == .err) {
                        has_error = true;
                    } else if (m == .null_type) {
                        has_null = true;
                    } else {
                        try others.append(self.allocator, m);
                    }
                }
                if (has_null and has_error) {
                    try w.writeAll("?anyerror!");
                    if (others.items.len == 1) {
                        try self.zigOfRTInner(others.items[0], w);
                    } else {
                        try w.writeAll(try self.canonicalUnionRefRT(others.items));
                    }
                } else if (has_error) {
                    try w.writeAll("anyerror!");
                    if (others.items.len == 1) {
                        try self.zigOfRTInner(others.items[0], w);
                    } else {
                        try w.writeAll(try self.canonicalUnionRefRT(others.items));
                    }
                } else if (has_null) {
                    try w.writeByte('?');
                    if (others.items.len == 1) {
                        try self.zigOfRTInner(others.items[0], w);
                    } else {
                        try w.writeAll(try self.canonicalUnionRefRT(others.items));
                    }
                } else {
                    try w.writeAll(try self.canonicalUnionRefRT(members));
                }
            },
            .type_param => |tp| try w.writeAll(tp.name),
            .inferred, .unknown => {
                _ = try self.reporter.reportFmt(.internal_zig_codegen, null,
                    "internal: unresolvable type in codegen", .{});
                return error.CompileError;
            },
        }
    }

    /// Produce the Zig type string for `rt`. Single final allocation via allocTypeStr;
    /// intermediate writes use a local buffer (no quadratic string tracking).
    pub fn zigOfRT(self: *CodeGen, rt: RT) anyerror![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try self.zigOfRTInner(rt, buf.writer(self.allocator));
        return try self.allocTypeStr("{s}", .{buf.items});
    }

    pub fn typeToZig(self: *CodeGen, node: *parser.Node) anyerror![]const u8 {
        // compiler_func @typeOf(val) in type-alias position: const T: type = @typeOf(val)
        if (node.* == .compiler_func) {
            const cf = node.compiler_func;
            if (std.mem.eql(u8, cf.name, "typeOf") and cf.args.len > 0) {
                return try self.allocTypeStr("@TypeOf({s})", .{exprToString(cf.args[0])});
            }
            _ = try self.reporter.reportFmt(.internal_zig_codegen, null,
                "internal: unexpected compiler_func '{s}' in type position", .{cf.name});
            return error.CompileError;
        }
        // type_tuple_named: preserve default field values (RT.TupleField drops them)
        if (node.* == .type_tuple_named) {
            const fields = node.type_tuple_named;
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, "struct { ");
            for (fields) |f| {
                const ft = try self.typeToZig(f.type_node);
                if (f.default) |d| {
                    try buf.writer(self.allocator).print("{s}: {s} = {s}, ", .{ f.name, ft, exprToString(d) });
                } else {
                    try buf.writer(self.allocator).print("{s}: {s}, ", .{ f.name, ft });
                }
            }
            try buf.appendSlice(self.allocator, "}");
            return try self.allocTypeStr("{s}", .{buf.items});
        }
        // call_expr in type-alias position where callee is not a bare identifier
        // (e.g. module.Type(T) RHS). Handled before resolveTypeNode since
        // resolveTypeNode returns .unknown for non-identifier callees.
        if (node.* == .call_expr) {
            const c = node.call_expr;
            if (c.callee.* != .identifier) return "anyopaque";
        }
        // binary_expr in type-alias position with non-bit_or op.
        if (node.* == .binary_expr and node.binary_expr.op != .bit_or) return "anyopaque";
        // All other type-position nodes: lower to RT via a scratch arena, then emit.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const rt = try types.resolveTypeNode(scratch.allocator(), node);
        if (rt == .unknown or rt == .inferred) return "anyopaque";
        return self.zigOfRT(rt);
    }
};

pub fn opToZig(op: parser.Operator) []const u8 { return match_impl.opToZig(op); }

/// Check if a field name is a type name used for union value access (result.i32, result.User)
pub fn isResultValueField(name: []const u8, decls: ?*declarations.DeclTable) bool { return match_impl.isResultValueField(name, decls); }

/// Extract the value type from a union type annotation containing Error or null.
/// For (Error | T) or (null | T), returns the non-Error/non-null member.
/// Returns null if not a recognized error/null union pattern.
/// Available at file scope so helper modules (codegen_exprs.zig) can call codegen.extractValueType().
pub fn extractValueType(node: *parser.Node) ?*parser.Node {
    if (node.* == .type_union) {
        const members = node.type_union;
        var value_node: ?*parser.Node = null;
        for (members) |m| {
            if (m.* == .type_named and (types.Primitive.fromName(m.type_named) == .err or types.Primitive.fromName(m.type_named) == .null_type)) continue;
            if (value_node != null) return null; // multiple non-special members
            value_node = m;
        }
        return value_node;
    }
    return null;
}

/// Extract a literal expression as a string for use in type default values.
fn exprToString(node: *parser.Node) []const u8 {
    return switch (node.*) {
        .int_literal => |v| v,
        .float_literal => |v| v,
        .string_literal => |v| v,
        .bool_literal => |v| if (v) "true" else "false",
        .null_literal => "null",
        .identifier => |v| v,
        else => "undefined",
    };
}

/// File-scope isTypeAlias for helper modules.
pub fn isTypeAlias(type_annotation: ?*parser.Node) bool { return decls_impl.isTypeAlias(type_annotation); }

/// File-scope mirIsStringFromStore — MirStore path for new callers.
pub fn mirIsStringFromStore(store: *const mir_store_mod.MirStore, idx: mir_store_mod.MirNodeIndex) bool { return exprs_impl.mirIsStringFromStore(store, idx); }

/// File-scope mirContainsIdentifier for helper modules (new MirStore-based path).
pub fn mirContainsIdentifier(store: *const mir_store_mod.MirStore, idx: mir_store_mod.MirNodeIndex, name: []const u8) bool { return match_impl.mirContainsIdentifier(store, idx, name); }

/// Prefix/suffix pair for wrapping a union-typed expression to yield its
/// unwrapped value. Callers emit `prefix`, then the expression, then `suffix`.
///
/// Only the three "clean" single-operation unwraps live here (null, error,
/// null_error). `.arbitrary_union` is NOT covered because its suffix is a
/// runtime-resolved `._<tag>` that depends on caller-side type lookups —
/// each call site handles that case itself. Returns `null` for type classes
/// that have no unwrap form (e.g. `.plain`, `.union_type`).
pub const UnwrapForm = struct {
    prefix: []const u8,
    suffix: []const u8,
};

pub fn valueUnwrapForm(tc: mir.TypeClass) ?UnwrapForm {
    return switch (tc) {
        .null_union => .{ .prefix = "", .suffix = ".?" },
        .error_union => .{ .prefix = "", .suffix = " catch unreachable" },
        .null_error_union => .{ .prefix = "(", .suffix = ".? catch unreachable)" },
        else => null,
    };
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

    var str_type = parser.Node{ .type_named = "str" };
    try std.testing.expectEqualStrings("[]const u8", try gen.typeToZig(&str_type));

    var i32_type = parser.Node{ .type_named = "i32" };
    try std.testing.expectEqualStrings("i32", try gen.typeToZig(&i32_type));

    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "i32" };
    var slice_type = parser.Node{ .type_slice = elem };
    const slice_zig = try gen.typeToZig(&slice_type);
    try std.testing.expectEqualStrings("[]i32", slice_zig);
}

test "codegen - typeToZig Error type" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var err_type = parser.Node{ .type_named = "Error" };
    try std.testing.expectEqualStrings("anyerror", try gen.typeToZig(&err_type));
}

test "codegen - typeToZig error union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // (Error | i32) → anyerror!i32
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "Error" };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "i32" };
    const members = try a.alloc(*parser.Node, 2);
    members[0] = t1;
    members[1] = t2;
    var union_type = parser.Node{ .type_union = members };
    try std.testing.expectEqualStrings("anyerror!i32", try gen.typeToZig(&union_type));
}

test "codegen - typeToZig null union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // (null | str) → ?[]const u8
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "null" };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "str" };
    const members = try a.alloc(*parser.Node, 2);
    members[0] = t1;
    members[1] = t2;
    var union_type = parser.Node{ .type_union = members };
    try std.testing.expectEqualStrings("?[]const u8", try gen.typeToZig(&union_type));
}

test "codegen - typeToZig ptr types" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try a.create(parser.Node);
    inner.* = .{ .type_named = "Point" };
    var const_ptr = parser.Node{ .type_ptr = .{ .kind = .const_ref, .elem = inner } };
    try std.testing.expectEqualStrings("*const Point", try gen.typeToZig(&const_ptr));

    const inner2 = try a.create(parser.Node);
    inner2.* = .{ .type_named = "Point" };
    var mut_ptr = parser.Node{ .type_ptr = .{ .kind = .mut_ref, .elem = inner2 } };
    try std.testing.expectEqualStrings("*Point", try gen.typeToZig(&mut_ptr));
}

test "codegen - typeToZig array" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "f32" };
    const size = try a.create(parser.Node);
    size.* = .{ .int_literal = "4" };
    var arr = parser.Node{ .type_array = .{ .size = size, .elem = elem } };
    try std.testing.expectEqualStrings("[4]f32", try gen.typeToZig(&arr));
}

test "codegen - typeToZig generic" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const arg = try a.create(parser.Node);
    arg.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    var generic = parser.Node{ .type_generic = .{ .name = "List", .args = args } };
    try std.testing.expectEqualStrings("List(i32)", try gen.typeToZig(&generic));
}

test "codegen - typeToZig tuple named" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "i32" };
    const fields = try a.alloc(parser.NamedTypeField, 1);
    fields[0] = .{ .name = "x", .type_node = t1, .default = null };
    var tuple = parser.Node{ .type_tuple_named = fields };
    try std.testing.expectEqualStrings("struct { x: i32, }", try gen.typeToZig(&tuple));
}

test "codegen - typeToZig Self in struct" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    gen.in_struct = true;
    var this_type = parser.Node{ .type_named = "@this" };
    try std.testing.expectEqualStrings("@This()", try gen.typeToZig(&this_type));
    // Deprecated Self still works
    var self_type = parser.Node{ .type_named = "Self" };
    try std.testing.expectEqualStrings("@This()", try gen.typeToZig(&self_type));
}

test "codegen - sanitizeErrorName" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    try std.testing.expectEqualStrings("division_by_zero", try gen.sanitizeErrorName("\"division by zero\""));
    try std.testing.expectEqualStrings("not_found", try gen.sanitizeErrorName("not-found"));
    try std.testing.expectEqualStrings("unknown_error", try gen.sanitizeErrorName("---"));
    try std.testing.expectEqualStrings("unknown_error", try gen.sanitizeErrorName(""));
    try std.testing.expectEqualStrings("a_b", try gen.sanitizeErrorName("a--b"));
}

test "codegen - extractValueType" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // (Error | i32) → i32
    const err = try a.create(parser.Node);
    err.* = .{ .type_named = "Error" };
    const i32_n = try a.create(parser.Node);
    i32_n.* = .{ .type_named = "i32" };
    const m1 = try a.alloc(*parser.Node, 2);
    m1[0] = err;
    m1[1] = i32_n;
    var union1 = parser.Node{ .type_union = m1 };
    try std.testing.expect(extractValueType(&union1).? == i32_n);

    // (null | str) → str
    const null_n = try a.create(parser.Node);
    null_n.* = .{ .type_named = "null" };
    const str_n = try a.create(parser.Node);
    str_n.* = .{ .type_named = "str" };
    const m2 = try a.alloc(*parser.Node, 2);
    m2[0] = null_n;
    m2[1] = str_n;
    var union2 = parser.Node{ .type_union = m2 };
    try std.testing.expect(extractValueType(&union2).? == str_n);

    // non-union → null
    var plain = parser.Node{ .type_named = "i32" };
    try std.testing.expect(extractValueType(&plain) == null);
}

test "codegen - zigOfRT primitive str" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const s = try gen.zigOfRT(.{ .primitive = .string });
    try std.testing.expectEqualStrings("[]const u8", s);
}

test "codegen - zigOfRT err" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    try std.testing.expectEqualStrings("anyerror", try gen.zigOfRT(.err));
}

test "codegen - zigOfRT slice" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const elem = RT{ .primitive = .i32 };
    try std.testing.expectEqualStrings("[]i32", try gen.zigOfRT(.{ .slice = &elem }));
}

test "codegen - zigOfRT error union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const members = [_]RT{ .err, .{ .primitive = .i32 } };
    try std.testing.expectEqualStrings("anyerror!i32",
        try gen.zigOfRT(.{ .union_type = &members }));
}

test "codegen - zigOfRT null union" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const members = [_]RT{ .null_type, .{ .primitive = .string } };
    try std.testing.expectEqualStrings("?[]const u8",
        try gen.zigOfRT(.{ .union_type = &members }));
}

test "codegen - zigOfRT ptr" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const elem = RT{ .named = "Point" };
    try std.testing.expectEqualStrings("*const Point",
        try gen.zigOfRT(.{ .ptr = .{ .kind = .const_ref, .elem = &elem } }));
    try std.testing.expectEqualStrings("*Point",
        try gen.zigOfRT(.{ .ptr = .{ .kind = .mut_ref, .elem = &elem } }));
}

test "codegen - zigOfRT generic" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();
    const arg = RT{ .primitive = .i32 };
    try std.testing.expectEqualStrings("List(i32)",
        try gen.zigOfRT(.{ .generic = .{ .name = "List", .args = &.{arg} } }));
}

