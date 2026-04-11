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
    type_ctx: ?*parser.Node, // expected type from enclosing decl (for overflow codegen)
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
    node_map: ?*const mir.NodeMap = null,
    union_registry: ?*const mir.UnionRegistry = null,
    needs_unions_import: bool = false,
    var_types: ?*const std.StringHashMapUnmanaged(mir.NodeInfo) = null,
    // MIR tree — Phase 3 lowered tree (available for incremental migration)
    mir_root: ?*mir.MirNode = null,
    // Zig-backed module — all declarations are re-exported from {name}_zig
    is_zig_module: bool = false,
    // Mixed module — user .orh + .zig sidecar; body-less decls re-exported from {name}_zig
    has_zig_sidecar: bool = false,
    // Tracks emitted declaration names for deduplication in mixed modules
    emitted_names: std.StringHashMapUnmanaged(void) = .{},
    // MIR node for the current function — set by generateFuncMir.
    current_func_mir: ?*mir.MirNode = null,
    // Pre-statement hoisting buffer — interpolation temp vars are appended here,
    // flushed to main output before the statement that references them.
    pre_stmts: std.ArrayListUnmanaged(u8) = .{},
    interp_count: u32 = 0,
    // Match variable substitution — inside match arm bodies, the original variable
    // name compiles as the Zig capture variable (e.g., "result" → "_match_val").
    // Saved/restored for nested match support.
    match_var_subst: ?struct { original: []const u8, capture: []const u8, eff_tc: ?mir.TypeClass = null } = null,
    narrowing_count: u32 = 0, // unique counter for narrowing binding names

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

    /// Whether the current function is a compt function (all loops should be inline).
    pub fn inComptFunc(self: *const CodeGen) bool {
        if (self.current_func_mir) |m| return m.is_compt;
        return false;
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
            .type_ctx = null,
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
        self.emitted_names.deinit(self.allocator);
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

        // Generate top-level declarations from MIR tree
        const root = self.mir_root orelse return error.CompileError;
        for (root.children) |m| {
            try self.generateTopLevelMir(m);
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
                    var func_iter = dt.funcs.iterator();
                    while (func_iter.next()) |entry| {
                        if (entry.value_ptr.is_pub)
                            try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var struct_iter = dt.structs.iterator();
                    while (struct_iter.next()) |entry| {
                        if (entry.value_ptr.is_pub)
                            try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var enum_iter = dt.enums.iterator();
                    while (enum_iter.next()) |entry| {
                        if (entry.value_ptr.is_pub)
                            try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var var_iter = dt.vars.iterator();
                    while (var_iter.next()) |entry| {
                        if (entry.value_ptr.is_pub)
                            try self.emitLineFmt("const {s} = {s}.{s};", .{ entry.key_ptr.*, hidden, entry.key_ptr.* });
                    }
                    var bp_iter = dt.blueprints.iterator();
                    while (bp_iter.next()) |entry| {
                        if (entry.value_ptr.is_pub)
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
        // Deduplicate: mixed modules merge sidecar .orh files, which can duplicate
        // declarations from the user's .orh. Skip if we already emitted this name.
        if (self.has_zig_sidecar) {
            if (m.name) |name| {
                if (self.emitted_names.contains(name)) return;
                try self.emitted_names.put(self.allocator, name, {});
            }
        }

        switch (m.kind) {
            .func => {
                const prev = self.current_func_mir;
                self.current_func_mir = m;
                defer self.current_func_mir = prev;
                try self.generateFuncMir(m);
            },
            .struct_def => try self.generateStructMir(m),
            .enum_def => try self.generateEnumMir(m),
            .handle_def => try self.generateHandleMir(m),
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

    /// MIR-path collectAssigned — traverses MirNode tree.
    pub fn collectAssignedMir(m: *mir.MirNode, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void { return decls_impl.collectAssignedMir(m, set, alloc); }

    pub fn getRootIdentMir(m: *const mir.MirNode) ?[]const u8 { return decls_impl.getRootIdentMir(m); }


    // ============================================================
    // STRUCTS
    // ============================================================

    /// MIR-path struct codegen — iterates MirNode children instead of AST members.
    pub fn generateStructMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateStructMir(self, m); }
    pub fn emitStructBody(self: *CodeGen, children: []*mir.MirNode) anyerror!void { return decls_impl.emitStructBody(self, children); }

    // ============================================================
    // ENUMS
    // ============================================================

    /// MIR-path enum codegen — iterates MirNode children instead of AST members.
    pub fn generateEnumMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateEnumMir(self, m); }

    // ============================================================
    // HANDLES
    // ============================================================

    /// MIR-path handle codegen — emits const Name = *anyopaque;
    pub fn generateHandleMir(self: *CodeGen, m: *mir.MirNode) anyerror!void { return decls_impl.generateHandleMir(self, m); }

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

    /// Collect all leaf members from a tree of binary '|' expressions.
    fn collectBinaryUnionMembers(self: *CodeGen, b: parser.BinaryOp, out: *std.ArrayListUnmanaged(*parser.Node)) !void {
        // Recurse left
        if (b.left.* == .binary_expr and b.left.binary_expr.op == .bit_or) {
            try self.collectBinaryUnionMembers(b.left.binary_expr, out);
        } else {
            try out.append(self.allocator, b.left);
        }
        // Recurse right
        if (b.right.* == .binary_expr and b.right.binary_expr.op == .bit_or) {
            try self.collectBinaryUnionMembers(b.right.binary_expr, out);
        } else {
            try out.append(self.allocator, b.right);
        }
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

    /// Build a canonical `_unions.OrhonUnion_*` reference for a set of union member AST nodes.
    /// Sets `needs_unions_import = true` as a side effect.
    fn canonicalUnionRef(self: *CodeGen, members: []const *parser.Node) ![]const u8 {
        // Collect member names, sort, build canonical name
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(self.allocator);
        for (members) |m| {
            const name = if (m.* == .type_named) m.type_named else try self.typeToZig(m);
            try names.append(self.allocator, name);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "_unions.OrhonUnion");
        for (names.items) |name| {
            try buf.append(self.allocator, '_');
            // Include module name for user types (matches registry naming)
            if (!types.isPrimitiveName(name)) {
                if (self.union_registry) |reg| {
                    // Search registry entries for this type's module
                    for (reg.entries.items) |entry| {
                        for (entry.module_types) |mt| {
                            if (std.mem.eql(u8, mt.type_name, name)) {
                                try buf.appendSlice(self.allocator, mt.module_name);
                                try buf.append(self.allocator, '_');
                                break;
                            }
                        }
                    }
                }
            }
            try buf.appendSlice(self.allocator, name);
        }

        self.needs_unions_import = true;
        return try self.allocTypeStr("{s}", .{buf.items});
    }

    pub fn typeToZig(self: *CodeGen, node: *parser.Node) anyerror![]const u8 {
        return switch (node.*) {
            .type_named => |name| {
                if (std.mem.eql(u8, name, K.Type.ERROR)) return "anyerror";
                // @this / Self maps to @This() inside any struct
                if (self.in_struct and (std.mem.eql(u8, name, K.Type.THIS) or std.mem.eql(u8, name, K.Type.SELF_DEPRECATED))) return "@This()";
                // Inside a generic struct, the struct's own name also maps to @This()
                if (self.generic_struct_name) |gsn| {
                    if (std.mem.eql(u8, name, gsn)) return "@This()";
                }
                return types.Primitive.nameToZig(name);
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
                // Check for Error/null union patterns first
                var has_error = false;
                var has_null = false;
                var other_types = std.ArrayListUnmanaged(*parser.Node){};
                defer other_types.deinit(self.allocator);
                for (u) |t| {
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) {
                        has_error = true;
                    } else if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) {
                        has_null = true;
                    } else {
                        try other_types.append(self.allocator, t);
                    }
                }
                // (Error | T) → anyerror!T, (null | T) → ?T, (null | Error | T) → ?anyerror!T
                if (has_error or has_null) {
                    // Build the inner type from remaining members
                    const inner_zig = if (other_types.items.len == 1)
                        try self.typeToZig(other_types.items[0])
                    else inner: {
                        // Multiple remaining types → _unions.OrhonUnion_*
                        break :inner try self.canonicalUnionRef(other_types.items);
                    };
                    if (has_null and has_error) {
                        break :blk try self.allocTypeStr("?anyerror!{s}", .{inner_zig});
                    } else if (has_error) {
                        break :blk try self.allocTypeStr("anyerror!{s}", .{inner_zig});
                    } else {
                        break :blk try self.allocTypeStr("?{s}", .{inner_zig});
                    }
                }
                // Regular arbitrary union: (i32 | f32 | str) → _unions.OrhonUnion_*
                break :blk try self.canonicalUnionRef(u);
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
                if (std.mem.eql(u8, g.name, K.Type.VECTOR)) {
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
                    if (f.default) |d| {
                        // Emit field with default: name: type = value
                        const dv = exprToString(d);
                        try buf.writer(self.allocator).print("{s}: {s} = {s}, ", .{ f.name, ft, dv });
                    } else {
                        try buf.writer(self.allocator).print("{s}: {s}, ", .{ f.name, ft });
                    }
                }
                try buf.appendSlice(self.allocator, "}");
                break :blk try self.allocTypeStr("{s}", .{buf.items});
            },
            // cast(i64, x) — type arg parsed as identifier by parseExpr
            .identifier => |name| types.Primitive.nameToZig(name),
            // Generic type constructors in expression position: List(T), Map(K,V), etc.
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
                if (b.op != .bit_or) break :blk "anyopaque";
                // Check for (Error | T) or (null | T) patterns
                const left_is_error = b.left.* == .identifier and std.mem.eql(u8, b.left.identifier, K.Type.ERROR);
                const left_is_null = b.left.* == .null_literal;
                if (left_is_error) {
                    const inner = try self.typeToZig(b.right);
                    break :blk try self.allocTypeStr("anyerror!{s}", .{inner});
                }
                if (left_is_null) {
                    const inner = try self.typeToZig(b.right);
                    break :blk try self.allocTypeStr("?{s}", .{inner});
                }
                // Regular arbitrary union: (A | B) → _unions.OrhonUnion_*
                var members = std.ArrayListUnmanaged(*parser.Node){};
                defer members.deinit(self.allocator);
                try self.collectBinaryUnionMembers(b, &members);
                break :blk try self.canonicalUnionRef(members.items);
            },
            else => "anyopaque",
        };
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
            if (m.* == .type_named and (std.mem.eql(u8, m.type_named, K.Type.ERROR) or std.mem.eql(u8, m.type_named, "null"))) continue;
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

/// File-scope mirIsString for helper modules (codegen_match.zig needs this without importing exprs directly).
pub fn mirIsString(m: *const mir.MirNode) bool { return exprs_impl.mirIsString(m); }

/// File-scope mirIsVector for helper modules.
pub fn mirIsVector(m: *const mir.MirNode) bool { return exprs_impl.mirIsVector(m); }

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

