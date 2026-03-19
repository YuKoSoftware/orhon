// codegen.zig — Zig Code Generation pass (pass 11)
// Translates MIR and AST to readable Zig source files.
// One .zig file per Kodr module. Uses std.fmt for output.

const std = @import("std");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const builtins = @import("builtins.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");

/// Built-in allocator kinds from std::mem
const AllocKind = enum { gpa, arena, temp, page };

/// Info tracked per allocator variable
const AllocInfo = struct {
    kind: AllocKind,
    impl_name: []const u8, // backing Zig var name, e.g. "_a_impl"
};

/// The Zig code generator
pub const CodeGen = struct {
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8),
    indent: usize,
    is_debug: bool,
    type_strings: std.ArrayListUnmanaged([]const u8), // allocated type strings to free
    decls: ?*declarations.DeclTable,
    in_error_union_func: bool, // current function returns (Error | T)
    in_null_union_func: bool, // current function returns (null | T)
    null_vars: std.StringHashMapUnmanaged(void),       // variables with (null | T) type
    rawptr_vars: std.StringHashMapUnmanaged(void),     // variables holding RawPtr(T) or VolatilePtr(T)
    ptr_vars: std.StringHashMapUnmanaged(void),        // variables holding Ptr(T)
    allocator_vars: std.StringHashMapUnmanaged(AllocInfo), // variables holding a mem.* allocator
    heap_single_vars: std.StringHashMapUnmanaged([]const u8), // heap singles: var → allocator name
    in_test_block: bool, // inside a test { } block — @assert uses std.testing.expect
    destruct_counter: usize, // unique index for destructuring temp vars

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter, is_debug: bool) CodeGen {
        return .{
            .reporter = reporter,
            .allocator = allocator,
            .output = .{},
            .indent = 0,
            .is_debug = is_debug,
            .type_strings = .{},
            .decls = null,
            .in_error_union_func = false,
            .in_null_union_func = false,
            .null_vars = .{},
            .rawptr_vars = .{},
            .ptr_vars = .{},
            .allocator_vars = .{},
            .heap_single_vars = .{},
            .in_test_block = false,
            .destruct_counter = 0,
        };
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
        self.null_vars.deinit(self.allocator);
        self.rawptr_vars.deinit(self.allocator);
        self.ptr_vars.deinit(self.allocator);
        var it = self.allocator_vars.iterator();
        while (it.next()) |e| if (e.value_ptr.impl_name.len > 0) self.allocator.free(e.value_ptr.impl_name);
        self.allocator_vars.deinit(self.allocator);
        var hs_it = self.heap_single_vars.iterator();
        while (hs_it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.heap_single_vars.deinit(self.allocator);
    }

    /// Get the generated Zig source
    pub fn getOutput(self: *CodeGen) []const u8 {
        return self.output.items;
    }

    fn write(self: *CodeGen, s: []const u8) !void {
        try self.output.appendSlice(self.allocator, s);
    }

    fn writeFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(s);
        try self.output.appendSlice(self.allocator, s);
    }

    fn writeIndent(self: *CodeGen) !void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) {
            try self.write("    ");
        }
    }

    fn writeLine(self: *CodeGen, s: []const u8) !void {
        try self.writeIndent();
        try self.write(s);
        try self.write("\n");
    }

    fn writeLineFmt(self: *CodeGen, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        try self.writeFmt(fmt, args);
        try self.write("\n");
    }

    /// Generate Zig source from a program AST
    pub fn generate(self: *CodeGen, ast: *parser.Node, module_name: []const u8) !void {
        if (ast.* != .program) return;

        // File header
        try self.writeFmt("// generated from module {s} — do not edit\n", .{module_name});
        try self.write("const std = @import(\"std\");\n");

        // Kodr runtime types — only emit if the module uses Error or null unions
        if (self.moduleUsesErrorUnion(ast)) {
            try self.write("const KodrError = struct { message: []const u8 };\n");
            try self.write("fn KodrResult(comptime T: type) type { return union(enum) { ok: T, err: KodrError }; }\n");
        }
        if (self.moduleUsesNullUnion(ast)) {
            try self.write("fn KodrNullable(comptime T: type) type { return union(enum) { some: T, none: void }; }\n");
        }

        // Generate imports
        for (ast.program.imports) |imp| {
            try self.generateImport(imp);
        }

        try self.write("\n");

        // Generate top-level declarations
        for (ast.program.top_level) |node| {
            try self.generateTopLevel(node);
            try self.write("\n");
        }
    }

    fn moduleUsesErrorUnion(_: *CodeGen, ast: *parser.Node) bool {
        if (ast.* != .program) return false;
        for (ast.program.top_level) |node| {
            if (nodeContainsErrorUnion(node)) return true;
        }
        return false;
    }

    fn moduleUsesNullUnion(_: *CodeGen, ast: *parser.Node) bool {
        if (ast.* != .program) return false;
        for (ast.program.top_level) |node| {
            if (nodeContainsNullUnion(node)) return true;
        }
        return false;
    }

    /// Check if a type annotation AST node is a (null | T) union
    fn isNullUnionType(node: *parser.Node) bool {
        if (node.* == .type_union) {
            for (node.type_union) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) return true;
            }
        }
        return false;
    }

    /// Check if a variable name is a tracked null union variable
    fn isNullVar(self: *const CodeGen, name: []const u8) bool {
        return self.null_vars.contains(name);
    }

    /// Check if a variable name holds a RawPtr or VolatilePtr
    fn isRawPtrVar(self: *const CodeGen, name: []const u8) bool {
        return self.rawptr_vars.contains(name);
    }

    /// Check if a value expression is a RawPtr/VolatilePtr instantiation
    fn isPtrExpr(value: *parser.Node) bool {
        return value.* == .ptr_expr and
            (std.mem.eql(u8, value.ptr_expr.kind, "RawPtr") or
             std.mem.eql(u8, value.ptr_expr.kind, "VolatilePtr"));
    }

    /// Check if a value expression is a safe Ptr(T) instantiation
    fn isSafePtrExpr(value: *parser.Node) bool {
        return value.* == .ptr_expr and std.mem.eql(u8, value.ptr_expr.kind, "Ptr");
    }

    /// Check if a variable holds a safe Ptr(T)
    fn isPtrVar(self: *const CodeGen, name: []const u8) bool {
        return self.ptr_vars.contains(name);
    }

    /// Generate a value expression, wrapping it for null union context if needed
    fn generateNullWrappedExpr(self: *CodeGen, value: *parser.Node) anyerror!void {
        if (value.* == .null_literal) {
            try self.write(".{ .none = {} }");
        } else if (self.exprReturnsNullUnion(value)) {
            // Value already returns KodrNullable — don't double-wrap
            try self.generateExpr(value);
        } else {
            try self.write(".{ .some = ");
            try self.generateExpr(value);
            try self.write(" }");
        }
    }

    /// Check if an expression already produces a null union value.
    /// Function calls (positional args) to a function typed as returning a union
    /// already return KodrNullable — don't double-wrap.
    fn exprReturnsNullUnion(self: *const CodeGen, node: *parser.Node) bool {
        return switch (node.*) {
            // Positional function calls returning a null union already produce KodrNullable
            .call_expr => |c| c.arg_names.len == 0,
            // A variable already tracked as null union
            .identifier => |name| self.null_vars.contains(name),
            else => false,
        };
    }

    /// Check if an identifier is a declared Error constant
    fn isErrorConstant(self: *const CodeGen, name: []const u8) bool {
        if (self.decls) |decls| {
            if (decls.vars.get(name)) |v| {
                if (v.type_str) |ts| {
                    return std.mem.eql(u8, ts, "Error");
                }
            }
        }
        return false;
    }

    fn generateImport(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .import_decl) return;
        const imp = node.import_decl;

        // std::mem is a built-in compiler module — no Zig import needed,
        // allocator types map directly to std.heap.* which is always available.
        if (imp.scope) |sc| {
            if (std.mem.eql(u8, sc, "std") and std.mem.eql(u8, imp.path, "mem")) return;
        }

        // Alias defaults to the module name (last segment of path)
        const alias = imp.alias orelse imp.path;

        if (imp.is_c_header) {
            try self.writeLineFmt("// WARNING: C header import\nconst {s} = @cImport(@cInclude({s}));", .{ alias, imp.path });
        } else {
            // Generated .zig file is always named after the module, regardless of scope
            try self.writeLineFmt("const {s} = @import(\"{s}.zig\");", .{ alias, imp.path });
        }
    }

    fn generateTopLevel(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .func_decl => |f| try self.generateFunc(f),
            .struct_decl => |s| try self.generateStruct(s),
            .enum_decl => |e| try self.generateEnum(e),
            .const_decl => |v| try self.generateConst(v),
            .var_decl => |v| try self.generateVar(v),
            .compt_decl => |v| try self.generateCompt(v),
            .test_decl => |t| try self.generateTest(t),
            else => {},
        }
    }

    // ============================================================
    // FUNCTIONS
    // ============================================================

    fn generateFunc(self: *CodeGen, f: parser.FuncDecl) anyerror!void {
        // extern func — implementation in paired .zig file, emit nothing
        if (f.is_extern) return;

        // Track if this function returns an error or null union
        const prev_error = self.in_error_union_func;
        const prev_null = self.in_null_union_func;
        // Clear per-function tracking maps — each function has its own scope
        const prev_null_vars = self.null_vars;
        const prev_rawptr_vars = self.rawptr_vars;
        const prev_ptr_vars = self.ptr_vars;
        const prev_allocator_vars = self.allocator_vars;
        const prev_heap_single_vars = self.heap_single_vars;
        self.null_vars = .{};
        self.rawptr_vars = .{};
        self.ptr_vars = .{};
        self.allocator_vars = .{};
        self.heap_single_vars = .{};
        self.in_error_union_func = false;
        self.in_null_union_func = false;
        if (f.return_type.* == .type_union) {
            for (f.return_type.type_union) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, "Error")) self.in_error_union_func = true;
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) self.in_null_union_func = true;
            }
        }
        defer {
            self.in_error_union_func = prev_error;
            self.in_null_union_func = prev_null;
            self.null_vars.deinit(self.allocator);
            self.null_vars = prev_null_vars;
            self.rawptr_vars.deinit(self.allocator);
            self.rawptr_vars = prev_rawptr_vars;
            self.ptr_vars.deinit(self.allocator);
            self.ptr_vars = prev_ptr_vars;
            var _it = self.allocator_vars.iterator();
            while (_it.next()) |e| if (e.value_ptr.impl_name.len > 0) self.allocator.free(e.value_ptr.impl_name);
            self.allocator_vars.deinit(self.allocator);
            self.allocator_vars = prev_allocator_vars;
            var _hs_it = self.heap_single_vars.iterator();
            while (_hs_it.next()) |e| self.allocator.free(e.value_ptr.*);
            self.heap_single_vars.deinit(self.allocator);
            self.heap_single_vars = prev_heap_single_vars;
        }

        // pub modifier — always pub for main (Zig requires pub fn main for exe entry)
        if (f.is_pub or std.mem.eql(u8, f.name, "main")) try self.write("pub ");

        // compt functions become inline fn in Zig
        if (f.is_compt) {
            try self.writeFmt("inline fn {s}(", .{f.name});
        } else {
            try self.writeFmt("fn {s}(", .{f.name});
        }

        // Parameters
        for (f.params, 0..) |param, i| {
            if (i > 0) try self.write(", ");
            if (param.* == .param) {
                try self.writeFmt("{s}: {s}", .{
                    param.param.name,
                    try self.typeToZig(param.param.type_annotation),
                });
            }
        }

        try self.write(") ");

        // Return type
        try self.write(try self.typeToZig(f.return_type));
        try self.write(" ");

        // Body
        try self.generateBlock(f.body);
        try self.write("\n");
    }

    // ============================================================
    // STRUCTS
    // ============================================================

    fn generateStruct(self: *CodeGen, s: parser.StructDecl) anyerror!void {
        if (s.is_pub) try self.write("pub ");
        try self.writeFmt("const {s} = struct {{\n", .{s.name});
        self.indent += 1;

        for (s.members) |member| {
            switch (member.*) {
                .field_decl => |f| {
                    try self.writeIndent();
                    // Zig struct fields are always public — pub is only for decls.
                    // Kodr tracks field visibility for its own analysis passes.
                    try self.writeFmt("{s}: {s}", .{ f.name, try self.typeToZig(f.type_annotation) });
                    if (f.default_value) |dv| {
                        try self.write(" = ");
                        try self.generateExpr(dv);
                    }
                    try self.write(",\n");
                },
                .func_decl => |f| try self.generateFunc(f),
                .var_decl => |v| {
                    // Static var in struct
                    try self.writeIndent();
                    try self.writeFmt("var {s}", .{v.name});
                    if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                    try self.write(" = ");
                    try self.generateExpr(v.value);
                    try self.write(";\n");
                },
                .const_decl => |v| {
                    try self.writeIndent();
                    try self.writeFmt("const {s}", .{v.name});
                    if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                    try self.write(" = ");
                    try self.generateExpr(v.value);
                    try self.write(";\n");
                },
                else => {},
            }
        }

        self.indent -= 1;
        try self.write("};\n");
    }

    // ============================================================
    // ENUMS
    // ============================================================

    fn generateEnum(self: *CodeGen, e: parser.EnumDecl) anyerror!void {
        if (e.is_pub) try self.write("pub ");

        const backing = try self.typeToZig(e.backing_type);

        if (e.is_bitfield) {
            // Bitfield enum — generate as packed struct with bool fields
            try self.writeFmt("const {s} = packed struct({s}) {{\n", .{ e.name, backing });
            self.indent += 1;

            var bit: usize = 0;
            for (e.members) |member| {
                if (member.* == .enum_variant) {
                    try self.writeIndent();
                    try self.writeFmt("{s}: bool = false, // bit {d}\n", .{ member.enum_variant.name, bit });
                    bit += 1;
                }
            }

            // Pad remaining bits
            const total_bits: usize = switch (backing[0]) {
                'u' => std.fmt.parseInt(usize, backing[1..], 10) catch 32,
                else => 32,
            };
            if (bit < total_bits) {
                try self.writeIndent();
                try self.writeFmt("_padding: u{d} = 0,\n", .{total_bits - bit});
            }

            // Convenience methods
            try self.writeIndent();
            try self.writeFmt("pub fn has(self: {s}, flag: {s}) bool {{ return @field(self, @tagName(flag)); }}\n",
                .{ e.name, e.name });

            self.indent -= 1;
            try self.write("};\n");
        } else {
            // Regular enum
            try self.writeFmt("const {s} = enum({s}) {{\n", .{ e.name, backing });
            self.indent += 1;

            for (e.members) |member| {
                switch (member.*) {
                    .enum_variant => |v| {
                        try self.writeIndent();
                        if (v.fields.len > 0) {
                            // Data-carrying variant — generate as tagged union
                            try self.writeFmt("{s},\n", .{v.name});
                        } else {
                            try self.writeFmt("{s},\n", .{v.name});
                        }
                    },
                    .func_decl => |f| try self.generateFunc(f),
                    else => {},
                }
            }

            self.indent -= 1;
            try self.write("};\n");
        }
    }

    // ============================================================
    // MEMORY ALLOCATORS (std::mem)
    // ============================================================

    /// Detect if a node is a mem.GPA() / mem.Arena() / mem.Temp(n) / mem.Page() constructor call.
    fn getMemAllocKind(node: *parser.Node) ?AllocKind {
        if (node.* != .call_expr) return null;
        const c = node.call_expr;
        if (c.callee.* != .field_expr) return null;
        const fe = c.callee.field_expr;
        if (fe.object.* != .identifier) return null;
        if (!std.mem.eql(u8, fe.object.identifier, "mem")) return null;
        if (std.mem.eql(u8, fe.field, "GPA"))   return .gpa;
        if (std.mem.eql(u8, fe.field, "Arena")) return .arena;
        if (std.mem.eql(u8, fe.field, "Temp"))  return .temp;
        if (std.mem.eql(u8, fe.field, "Page"))  return .page;
        return null;
    }

    /// Generate allocator initialization statements for: var a = mem.GPA() etc.
    /// Expands to multi-line Zig — backing struct + defer deinit + allocator() call.
    /// NOTE: generateBlock already called writeIndent() before this statement, so the
    /// first line must NOT call writeIndent(); subsequent lines must.
    fn generateAllocatorInit(self: *CodeGen, name: []const u8, kind: AllocKind, args: []*parser.Node) anyerror!void {
        const impl_name = try std.fmt.allocPrint(self.allocator, "_{s}_impl", .{name});
        switch (kind) {
            .gpa => {
                try self.writeFmt("var {s} = std.heap.GeneralPurposeAllocator(.{{}}){{}};\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("defer _ = {s}.deinit();\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("const {s} = {s}.allocator();", .{name, impl_name});
            },
            .arena => {
                try self.writeFmt("var {s} = std.heap.ArenaAllocator.init(std.heap.page_allocator);\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("defer {s}.deinit();\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("const {s} = {s}.allocator();", .{name, impl_name});
            },
            .temp => {
                if (args.len < 1) {
                    try self.reporter.report(.{ .message = "mem.Temp requires a size argument" });
                    return error.CompileError;
                }
                try self.writeFmt("var _{s}_buf: [", .{name});
                try self.generateExpr(args[0]);
                try self.write("]u8 = undefined;\n");
                try self.writeIndent(); try self.writeFmt("var {s} = std.heap.FixedBufferAllocator.init(&_{s}_buf);\n", .{ impl_name, name });
                try self.writeIndent(); try self.writeFmt("const {s} = {s}.allocator();", .{name, impl_name});
            },
            .page => {
                // page_allocator is a static global — no init/deinit needed
                try self.writeFmt("const {s} = std.heap.page_allocator;", .{name});
                self.allocator.free(impl_name);
                try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = "" });
                return;
            },
        }
        try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = impl_name });
    }

    /// Generate a method call on an allocator variable: a.alloc(), a.allocOne(), a.free(), a.freeAll()
    fn generateAllocatorMethod(self: *CodeGen, alloc_name: []const u8, info: AllocInfo, method: []const u8, args: []*parser.Node) anyerror!void {
        if (std.mem.eql(u8, method, "allocOne")) {
            // a.allocOne(T, val) — single heap value, returns *T in Zig
            // Handled at var decl level via generateAllocOneDecl, not here
            try self.reporter.report(.{ .message = "allocOne must be used as a variable initializer: var x = a.allocOne(T, val)" });
            return error.CompileError;
        } else if (std.mem.eql(u8, method, "alloc")) {
            // a.alloc(T, n) — heap slice
            if (args.len < 2) {
                try self.reporter.report(.{ .message = "alloc requires two arguments: alloc(Type, count)" });
                return error.CompileError;
            }
            try self.writeFmt("{s}.alloc(", .{alloc_name});
            try self.generateExpr(args[0]);
            try self.write(", ");
            try self.generateExpr(args[1]);
            try self.write(") catch @panic(\"out of memory\")");
        } else if (std.mem.eql(u8, method, "free")) {
            // a.free(x) — free single value or slice
            if (args.len < 1) {
                try self.reporter.report(.{ .message = "free requires one argument" });
                return error.CompileError;
            }
            if (args[0].* == .identifier and self.heap_single_vars.contains(args[0].identifier)) {
                // Single value allocated with allocOne — use destroy(), pass the raw pointer
                try self.writeFmt("{s}.destroy({s})", .{ alloc_name, args[0].identifier });
            } else {
                // Slice allocated with alloc
                try self.writeFmt("{s}.free(", .{alloc_name});
                try self.generateExpr(args[0]);
                try self.write(")");
            }
        } else if (std.mem.eql(u8, method, "freeAll")) {
            // arena.freeAll() — reset arena, free all allocations at once
            if (info.kind != .arena) {
                try self.reporter.report(.{ .message = "freeAll is only available on mem.Arena()" });
                return error.CompileError;
            }
            try self.writeFmt("_ = {s}.reset(.free_all)", .{info.impl_name});
        } else {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown allocator method '{s}'", .{method});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg });
            return error.CompileError;
        }
    }

    // ============================================================
    // VARIABLE DECLARATIONS
    // ============================================================

    fn generateConst(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        // mem.GPA() / mem.Arena() / mem.Temp(n) / mem.Page() — multi-statement expansion
        if (getMemAllocKind(v.value)) |kind| {
            return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
        }
        // a.allocOne(T, val) — heap single value, expands to create + init
        if (self.getAllocOneCall(v.value)) |ac| {
            return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
        }
        if (v.is_pub) try self.write("pub ");
        try self.writeFmt("const {s}", .{v.name});
        const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
        if (v.type_annotation) |t| {
            try self.writeFmt(": {s}", .{try self.typeToZig(t)});
        }
        try self.write(" = ");
        if (is_null_union) {
            try self.null_vars.put(self.allocator, v.name, {});
            try self.generateNullWrappedExpr(v.value);
        } else {
            if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
            if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
    }

    fn generateVar(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        // mem.GPA() / mem.Arena() / mem.Temp(n) / mem.Page() — multi-statement expansion
        if (getMemAllocKind(v.value)) |kind| {
            return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
        }
        // a.allocOne(T, val) — heap single value, expands to create + init
        if (self.getAllocOneCall(v.value)) |ac| {
            return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
        }
        if (v.is_pub) try self.write("pub ");
        try self.writeFmt("var {s}", .{v.name});
        const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
        if (v.type_annotation) |t| {
            try self.writeFmt(": {s}", .{try self.typeToZig(t)});
        }
        try self.write(" = ");
        if (is_null_union) {
            try self.null_vars.put(self.allocator, v.name, {});
            try self.generateNullWrappedExpr(v.value);
        } else {
            if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
            if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
    }

    /// Info extracted from an a.allocOne(T, val) call expression
    const AllocOneCall = struct {
        alloc_name: []const u8,
        type_arg: *parser.Node,
        val_arg: *parser.Node,
    };

    /// Detect if a node is <allocator>.allocOne(T, val) where allocator is tracked.
    fn getAllocOneCall(self: *const CodeGen, node: *parser.Node) ?AllocOneCall {
        if (node.* != .call_expr) return null;
        const c = node.call_expr;
        if (c.callee.* != .field_expr) return null;
        const fe = c.callee.field_expr;
        if (!std.mem.eql(u8, fe.field, "allocOne")) return null;
        if (fe.object.* != .identifier) return null;
        if (!self.allocator_vars.contains(fe.object.identifier)) return null;
        if (c.args.len < 2) return null;
        return .{ .alloc_name = fe.object.identifier, .type_arg = c.args[0], .val_arg = c.args[1] };
    }

    /// Generate: const x = a.create(T) catch @panic("out of memory"); x.* = val;
    /// Tracks x in heap_single_vars so identifier access emits x.* and free uses destroy().
    /// NOTE: generateBlock already called writeIndent() before this, so first line must NOT.
    fn generateAllocOneDecl(self: *CodeGen, name: []const u8, alloc_name: []const u8, type_arg: *parser.Node, val_arg: *parser.Node) anyerror!void {
        try self.writeFmt("const {s} = {s}.create(", .{ name, alloc_name });
        try self.generateExpr(type_arg);
        try self.write(") catch @panic(\"out of memory\");\n");
        try self.writeIndent(); try self.writeFmt("{s}.* = ", .{name});
        try self.generateExpr(val_arg);
        try self.write(";");
        // Track so identifier access emits name.* and a.free(name) uses destroy()
        const duped = try self.allocator.dupe(u8, alloc_name);
        try self.heap_single_vars.put(self.allocator, name, duped);
    }

    fn generateCompt(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        // Top-level const is already comptime in Zig, so just emit const.
        if (v.is_pub) try self.write("pub ");
        try self.writeFmt("const {s}: {s} = ", .{
            v.name,
            try self.typeToZig(v.type_annotation orelse return),
        });
        try self.generateExpr(v.value);
        try self.write(";\n");
    }

    // ============================================================
    // TESTS
    // ============================================================

    fn generateTest(self: *CodeGen, t: parser.TestDecl) anyerror!void {
        try self.writeFmt("test {s} ", .{t.description});
        self.in_test_block = true;
        try self.generateBlock(t.body);
        self.in_test_block = false;
        try self.write("\n");
    }

    // ============================================================
    // BLOCKS AND STATEMENTS
    // ============================================================

    fn generateBlock(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* != .block) return;
        try self.write("{\n");
        self.indent += 1;

        for (node.block.statements) |stmt| {
            try self.writeIndent();
            try self.generateStatement(stmt);
            try self.write("\n");
        }

        self.indent -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    fn generateStatement(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .var_decl => |v| {
                if (getMemAllocKind(v.value)) |kind| {
                    return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
                }
                if (self.getAllocOneCall(v.value)) |ac| {
                    return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
                }
                const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
                try self.writeFmt("var {s}", .{v.name});
                if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                try self.write(" = ");
                if (is_null_union) {
                    try self.null_vars.put(self.allocator, v.name, {});
                    try self.generateNullWrappedExpr(v.value);
                } else {
                    if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
                    if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
                    try self.generateExpr(v.value);
                }
                try self.write(";");
            },
            .const_decl => |v| {
                if (getMemAllocKind(v.value)) |kind| {
                    return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
                }
                if (self.getAllocOneCall(v.value)) |ac| {
                    return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
                }
                const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
                try self.writeFmt("const {s}", .{v.name});
                if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                try self.write(" = ");
                if (is_null_union) {
                    try self.null_vars.put(self.allocator, v.name, {});
                    try self.generateNullWrappedExpr(v.value);
                } else {
                    if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
                    if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
                    try self.generateExpr(v.value);
                }
                try self.write(";");
            },
            .destruct_decl => |d| {
                // var (a, b) = expr  →  const _kodr_dN = expr; var/const a = _kodr_dN.a; ...
                const idx = self.destruct_counter;
                self.destruct_counter += 1;
                try self.writeFmt("const _kodr_d{d} = ", .{idx});
                try self.generateExpr(d.value);
                try self.write(";");
                const kw = if (d.is_const) "const" else "var";
                for (d.names) |name| {
                    try self.write("\n");
                    try self.writeIndent();
                    try self.writeFmt("{s} {s} = _kodr_d{d}.{s};", .{ kw, name, idx, name });
                }
            },
            .compt_decl => |v| {
                try self.writeFmt("const {s}: {s} = comptime ", .{
                    v.name,
                    try self.typeToZig(v.type_annotation orelse return),
                });
                try self.generateExpr(v.value);
                try self.write(";");
            },
            .return_stmt => |r| {
                try self.write("return");
                if (r.value) |v| {
                    try self.write(" ");
                    if (self.in_error_union_func) {
                        if (v.* == .error_literal) {
                            // Error("msg") in union context → .{ .err = ... }
                            try self.generateExpr(v);
                        } else if (v.* == .identifier and self.isErrorConstant(v.identifier)) {
                            // ErrDivByZero → .{ .err = ErrDivByZero }
                            try self.write(".{ .err = ");
                            try self.generateExpr(v);
                            try self.write(" }");
                        } else {
                            // Success value → .{ .ok = value }
                            try self.write(".{ .ok = ");
                            try self.generateExpr(v);
                            try self.write(" }");
                        }
                    } else if (self.in_null_union_func) {
                        if (v.* == .null_literal) {
                            try self.write(".{ .none = {} }");
                        } else {
                            try self.write(".{ .some = ");
                            try self.generateExpr(v);
                            try self.write(" }");
                        }
                    } else {
                        try self.generateExpr(v);
                    }
                }
                try self.write(";");
            },
            .if_stmt => |i| {
                try self.write("if (");
                try self.generateExpr(i.condition);
                try self.write(") ");
                try self.generateBlock(i.then_block);
                if (i.else_block) |e| {
                    try self.write(" else ");
                    try self.generateBlock(e);
                }
            },
            .while_stmt => |w| {
                try self.write("while (");
                try self.generateExpr(w.condition);
                try self.write(")");
                if (w.continue_expr) |c| {
                    try self.write(" : (");
                    try self.generateContinueExpr(c);
                    try self.write(")");
                }
                try self.write(" ");
                try self.generateBlock(w.body);
            },
            .for_stmt => |f| {
                // Kodr for(arr, 0..) |val, idx| → Zig for (arr, 0..) |val, idx|
                // compt for → inline for
                //
                // Range iterables: Zig range-for produces usize loop vars.
                // Only variables paired with a range_expr iterable need renaming
                // and i32 casting — slice/array variables are used directly.
                const needs_cast = try self.allocator.alloc(bool, f.variables.len);
                defer self.allocator.free(needs_cast);
                for (needs_cast) |*nc| nc.* = false;
                var has_cast = false;
                for (f.iterables, 0..) |it, idx| {
                    if (idx < needs_cast.len and it.* == .range_expr) {
                        needs_cast[idx] = true;
                        has_cast = true;
                    }
                }

                if (f.is_compt) try self.write("inline ");
                try self.write("for (");
                for (f.iterables, 0..) |it, i| {
                    if (i > 0) try self.write(", ");
                    if (it.* == .range_expr) {
                        try self.writeRangeExpr(it.range_expr);
                    } else {
                        try self.generateExpr(it);
                    }
                }
                try self.write(") |");
                for (f.variables, 0..) |v, vi| {
                    if (vi > 0) try self.write(", ");
                    if (vi < needs_cast.len and needs_cast[vi]) {
                        try self.writeFmt("_kodr_{s}", .{v});
                    } else {
                        try self.write(v);
                    }
                }
                if (has_cast) {
                    // Open block manually, inject i32 casts only for range vars
                    try self.write("| {\n");
                    self.indent += 1;
                    for (f.variables, 0..) |v, vi| {
                        if (vi < needs_cast.len and needs_cast[vi]) {
                            try self.writeIndent();
                            try self.writeFmt("const {s}: i32 = @intCast(_kodr_{s});\n", .{ v, v });
                        }
                    }
                    for (f.body.block.statements) |stmt| {
                        try self.writeIndent();
                        try self.generateStatement(stmt);
                        try self.write("\n");
                    }
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.write("}");
                } else {
                    try self.write("| ");
                    try self.generateBlock(f.body);
                }
            },
            .defer_stmt => |d| {
                try self.write("defer ");
                try self.generateBlock(d.body);
            },
            .match_stmt => |m| {
                try self.write("switch (");
                // self in a method is *T in Zig — must dereference for switch
                if (m.value.* == .identifier and std.mem.eql(u8, m.value.identifier, "self")) {
                    try self.write("self.*");
                } else {
                    try self.generateExpr(m.value);
                }
                try self.write(") {\n");
                self.indent += 1;
                var has_wildcard = false;
                for (m.arms) |arm| {
                    if (arm.* == .match_arm) {
                        try self.writeIndent();
                        // Check for wildcard pattern (_)
                        if (arm.match_arm.pattern.* == .identifier and
                            std.mem.eql(u8, arm.match_arm.pattern.identifier, "_"))
                        {
                            has_wildcard = true;
                            try self.write("else");
                        } else {
                            try self.generateExpr(arm.match_arm.pattern);
                        }
                        try self.write(" => ");
                        try self.generateBlock(arm.match_arm.body);
                        try self.write(",\n");
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
                        try self.writeIndent();
                        try self.write("else => {},\n");
                    }
                }
                self.indent -= 1;
                try self.writeIndent();
                try self.write("}");
            },
            .label_stmt => |name| {
                try self.writeFmt("{s}:", .{name});
            },
            .break_stmt => |label| {
                if (label) |l| try self.writeFmt("break :{s};", .{l})
                else try self.write("break;");
            },
            .continue_stmt => |label| {
                if (label) |l| try self.writeFmt("continue :{s};", .{l})
                else try self.write("continue;");
            },
            .assignment => |a| {
                if (std.mem.eql(u8, a.op, "/=")) {
                    // x /= y → x = @divTrunc(x, y)
                    try self.generateExpr(a.left);
                    try self.write(" = @divTrunc(");
                    try self.generateExpr(a.left);
                    try self.write(", ");
                    try self.generateExpr(a.right);
                    try self.write(");");
                } else if (std.mem.eql(u8, a.op, "=") and
                    a.left.* == .identifier and self.isNullVar(a.left.identifier))
                {
                    // Assignment to null union var → wrap value
                    try self.generateExpr(a.left);
                    try self.write(" = ");
                    try self.generateNullWrappedExpr(a.right);
                    try self.write(";");
                } else {
                    try self.generateExpr(a.left);
                    try self.writeFmt(" {s} ", .{a.op});
                    try self.generateExpr(a.right);
                    try self.write(";");
                }
            },
            .thread_block => |t| {
                // Thread(T) name { body } → Zig thread spawn
                try self.writeFmt("const {s}_handle = try std.Thread.spawn(.{{}}, struct {{\n", .{t.name});
                self.indent += 1;
                try self.writeIndent();
                try self.writeFmt("fn run() {s} ", .{try self.typeToZig(t.result_type)});
                try self.generateBlock(t.body);
                try self.write("\n");
                self.indent -= 1;
                try self.writeIndent();
                try self.writeFmt("}}.run, .{{}});\n", .{});
                try self.writeIndent();
                try self.writeFmt("const {s} = KodrThread({s}){{ .handle = {s}_handle }};",
                    .{ t.name, try self.typeToZig(t.result_type), t.name });
            },
            .async_block => |a| {
                // Async(T) name { body } → similar to thread but IO scheduled
                try self.writeFmt("const {s} = KodrAsync({s}).spawn(struct {{\n", .{
                    a.name, try self.typeToZig(a.result_type)
                });
                self.indent += 1;
                try self.writeIndent();
                try self.write("fn run() ");
                try self.write(try self.typeToZig(a.result_type));
                try self.write(" ");
                try self.generateBlock(a.body);
                try self.write("\n");
                self.indent -= 1;
                try self.writeIndent();
                try self.write("}.run);");
            },
            .block => try self.generateBlock(node),
            else => {
                try self.generateExpr(node);
                try self.write(";");
            },
        }
    }

    // ============================================================
    // EXPRESSIONS
    // ============================================================

    fn generateExpr(self: *CodeGen, node: *parser.Node) anyerror!void {
        switch (node.*) {
            .int_literal => |text| {
                // Remove underscore separators for Zig (Zig uses _ too, so keep them)
                try self.write(text);
            },
            .float_literal => |text| try self.write(text),
            .string_literal => |text| try self.write(text),
            .bool_literal => |b| try self.write(if (b) "true" else "false"),
            .null_literal => try self.write("null"),
            .error_literal => |msg| {
                if (self.in_error_union_func) {
                    // Inside a function returning (Error | T) → union variant
                    try self.writeFmt(".{{ .err = .{{ .message = {s} }} }}", .{msg});
                } else {
                    // Standalone Error value (const, assignment)
                    try self.writeFmt("KodrError{{ .message = {s} }}", .{msg});
                }
            },
            .identifier => |name| {
                if (self.isEnumVariant(name)) {
                    try self.writeFmt(".{s}", .{name});
                } else if (self.heap_single_vars.contains(name)) {
                    // Heap-single var: access through the implicit pointer
                    try self.writeFmt("{s}.*", .{name});
                } else {
                    try self.write(name);
                }
            },
            .borrow_expr => |inner| {
                try self.write("&");
                try self.generateExpr(inner);
            },
            .array_literal => |items| {
                try self.write(".{");
                for (items, 0..) |item, i| {
                    if (i > 0) try self.write(", ");
                    try self.generateExpr(item);
                }
                try self.write("}");
            },
            .tuple_literal => |t| {
                try self.write(".{");
                if (t.is_named) {
                    for (t.fields, 0..) |field, i| {
                        if (i > 0) try self.write(", ");
                        try self.writeFmt(".{s} = ", .{t.field_names[i]});
                        try self.generateExpr(field);
                    }
                } else {
                    for (t.fields, 0..) |field, i| {
                        if (i > 0) try self.write(", ");
                        try self.generateExpr(field);
                    }
                }
                try self.write("}");
            },
            .binary_expr => |b| {
                // @type(x) == Error → x == .err
                // @type(x) == null  → x == .none
                if (std.mem.eql(u8, b.op, "==") and
                    b.left.* == .compiler_func and
                    std.mem.eql(u8, b.left.compiler_func.name, "type") and
                    b.left.compiler_func.args.len > 0)
                {
                    // null is a keyword, parsed as .null_literal not .identifier
                    if (b.right.* == .null_literal) {
                        try self.write("(");
                        try self.generateExpr(b.left.compiler_func.args[0]);
                        try self.write(" == .none)");
                        return;
                    }
                    if (b.right.* == .identifier) {
                        const rhs = b.right.identifier;
                        if (std.mem.eql(u8, rhs, "Error")) {
                            try self.write("(");
                            try self.generateExpr(b.left.compiler_func.args[0]);
                            try self.write(" == .err)");
                            return;
                        }
                    }
                }
                // Division on signed ints → @divTrunc in Zig
                if (std.mem.eql(u8, b.op, "/")) {
                    try self.write("@divTrunc(");
                    try self.generateExpr(b.left);
                    try self.write(", ");
                    try self.generateExpr(b.right);
                    try self.write(")");
                } else if (std.mem.eql(u8, b.op, "%")) {
                    try self.write("@mod(");
                    try self.generateExpr(b.left);
                    try self.write(", ");
                    try self.generateExpr(b.right);
                    try self.write(")");
                } else {
                    const op = opToZig(b.op);
                    try self.write("(");
                    try self.generateExpr(b.left);
                    try self.writeFmt(" {s} ", .{op});
                    try self.generateExpr(b.right);
                    try self.write(")");
                }
            },
            .unary_expr => |u| {
                const op = opToZig(u.op);
                try self.writeFmt("{s}(", .{op});
                try self.generateExpr(u.operand);
                try self.write(")");
            },
            .call_expr => |c| {
                // Allocator method calls: a.alloc(), a.free(), a.freeAll()
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        if (self.allocator_vars.get(fe.object.identifier)) |info| {
                            try self.generateAllocatorMethod(fe.object.identifier, info, fe.field, c.args);
                            return;
                        }
                    }
                }
                if (c.arg_names.len > 0) {
                    // Named arguments → struct instantiation: Type{ .field = value, ... }
                    try self.generateExpr(c.callee);
                    try self.write("{ ");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        if (i < c.arg_names.len and c.arg_names[i].len > 0) {
                            try self.writeFmt(".{s} = ", .{c.arg_names[i]});
                        }
                        try self.generateExpr(arg);
                    }
                    try self.write(" }");
                } else {
                    // Positional arguments → regular function call
                    try self.generateExpr(c.callee);
                    try self.write("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.write(", ");
                        try self.generateExpr(arg);
                    }
                    try self.write(")");
                }
            },
            .field_expr => |f| {
                // ptr.value → ptr.* (safe Ptr(T) dereference)
                if (std.mem.eql(u8, f.field, "value") and
                    f.object.* == .identifier and self.isPtrVar(f.object.identifier))
                {
                    try self.generateExpr(f.object);
                    try self.write(".*");
                // raw.value → raw[0] (RawPtr/VolatilePtr dereference)
                } else if (std.mem.eql(u8, f.field, "value") and
                    f.object.* == .identifier and self.isRawPtrVar(f.object.identifier))
                {
                    try self.generateExpr(f.object);
                    try self.write("[0]");
                } else if (std.mem.eql(u8, f.field, "Error")) {
                    try self.generateExpr(f.object);
                    try self.write(".err");
                } else if (isResultValueField(f.field)) {
                    // Check if the object is a null union variable
                    if (f.object.* == .identifier and self.isNullVar(f.object.identifier)) {
                        // result.User → result.some (null union access)
                        try self.generateExpr(f.object);
                        try self.write(".some");
                    } else {
                        // result.i32 / result.User etc → result.ok (error union access)
                        try self.generateExpr(f.object);
                        try self.write(".ok");
                    }
                } else {
                    try self.generateExpr(f.object);
                    try self.writeFmt(".{s}", .{f.field});
                }
            },
            .index_expr => |i| {
                try self.generateExpr(i.object);
                try self.write("[");
                // Zig requires usize for indices — cast non-literal indices
                const index_is_literal = i.index.* == .int_literal;
                if (!index_is_literal) {
                    try self.write("@intCast(");
                    try self.generateExpr(i.index);
                    try self.write(")");
                } else {
                    try self.generateExpr(i.index);
                }
                try self.write("]");
            },
            .compiler_func => |cf| {
                try self.generateCompilerFunc(cf);
            },
            .range_expr => |r| {
                try self.generateExpr(r.left);
                try self.write("..");
                try self.generateExpr(r.right);
            },
            .ptr_expr => |p| {
                try self.generatePtrExpr(p);
            },
            else => {
                const msg = try std.fmt.allocPrint(self.allocator, "internal codegen error: unhandled expression kind '{s}'", .{@tagName(node.*)});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
                return error.CompileError;
            },
        }
    }

    // Generate a while continue expression — same as assignment but no trailing semicolon.
    fn generateContinueExpr(self: *CodeGen, node: *parser.Node) anyerror!void {
        if (node.* == .assignment) {
            const a = node.assignment;
            if (std.mem.eql(u8, a.op, "/=")) {
                try self.generateExpr(a.left);
                try self.write(" = @divTrunc(");
                try self.generateExpr(a.left);
                try self.write(", ");
                try self.generateExpr(a.right);
                try self.write(")");
            } else {
                try self.generateExpr(a.left);
                try self.writeFmt(" {s} ", .{a.op});
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
            try self.write("@intCast(");
            try self.generateExpr(r.left);
            try self.write(")");
        }
        try self.write("..");
        // Open-ended range (0..) — null_literal sentinel means no right side
        if (r.right.* == .null_literal) return;
        const right_is_literal = r.right.* == .int_literal;
        if (right_is_literal) {
            try self.generateExpr(r.right);
        } else {
            try self.write("@intCast(");
            try self.generateExpr(r.right);
            try self.write(")");
        }
    }

    fn generateCompilerFunc(self: *CodeGen, cf: parser.CompilerFunc) anyerror!void {
        // Map Kodr @functions to Zig equivalents
        if (std.mem.eql(u8, cf.name, "type")) {
            // @type(x) → @TypeOf(x)
            try self.write("@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, cf.name, "typename")) {
            // @typename(x) → @typeName(@TypeOf(x))
            try self.write("@typeName(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write("))");
        } else if (std.mem.eql(u8, cf.name, "typeid")) {
            // @typeid(x) → kodrTypeId(@TypeOf(x))
            try self.write("kodrTypeId(@TypeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write("))");
        } else if (std.mem.eql(u8, cf.name, "cast")) {
            // @cast(T, x) → Zig cast depending on target and source types:
            //   int target,   float source literal: @as(T, @intFromFloat(x))
            //   int target,   other source:          @as(T, @intCast(x))
            //   float target, float source:          @as(T, @floatCast(x))
            //   float target, other source:          @as(T, @floatFromInt(x))
            if (cf.args.len >= 2) {
                const target_type = try self.typeToZig(cf.args[0]);
                const target_is_float = target_type.len > 0 and target_type[0] == 'f';
                const source_is_float_literal = cf.args[1].* == .float_literal;
                try self.writeFmt("@as({s}, ", .{target_type});
                if (target_is_float and source_is_float_literal) {
                    // float literal to float type — direct cast
                    try self.write("@floatCast(");
                } else if (target_is_float) {
                    try self.write("@floatFromInt(");
                } else if (source_is_float_literal) {
                    try self.write("@intFromFloat(");
                } else {
                    try self.write("@intCast(");
                }
                try self.generateExpr(cf.args[1]);
                try self.write("))");
            } else if (cf.args.len == 1) {
                try self.write("@intCast(");
                try self.generateExpr(cf.args[0]);
                try self.write(")");
            }
        } else if (std.mem.eql(u8, cf.name, "size")) {
            // @size(T) → @sizeOf(T)
            try self.write("@sizeOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, cf.name, "align")) {
            // @align(T) → @alignOf(T)
            try self.write("@alignOf(");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, cf.name, "copy")) {
            // @copy(x) — for non-primitives, generate a copy
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
        } else if (std.mem.eql(u8, cf.name, "move")) {
            // @move(x) — explicit move, same as value in Zig
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
        } else if (std.mem.eql(u8, cf.name, "assert")) {
            if (self.in_test_block) {
                try self.write("try std.testing.expect(");
            } else {
                try self.write("std.debug.assert(");
            }
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, cf.name, "swap")) {
            // @swap(a, b) → std.mem.swap(@TypeOf(a), &a, &b)
            if (cf.args.len == 2) {
                try self.write("std.mem.swap(@TypeOf(");
                try self.generateExpr(cf.args[0]);
                try self.write("), &");
                try self.generateExpr(cf.args[0]);
                try self.write(", &");
                try self.generateExpr(cf.args[1]);
                try self.write(")");
            }
        } else {
            try self.writeFmt("/* unknown @{s} */", .{cf.name});
        }
    }

    fn generatePtrExpr(self: *CodeGen, p: parser.PtrExpr) anyerror!void {
        if (std.mem.eql(u8, p.kind, "Ptr")) {
            // Ptr(T, &x) → &x  (safe const pointer, ownership tracked)
            try self.generateExpr(p.addr_arg);
        } else if (std.mem.eql(u8, p.kind, "RawPtr")) {
            std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
            const zig_type = try self.typeToZig(p.type_arg);
            if (p.addr_arg.* == .borrow_expr) {
                // RawPtr(T, &x) → @as([*]T, @ptrCast(&x))
                try self.writeFmt("@as([*]{s}, @ptrCast(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.write("))");
            } else {
                // RawPtr(T, 0xB8000) → @as([*]T, @ptrFromInt(addr))
                try self.writeFmt("@as([*]{s}, @ptrFromInt(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.write("))");
            }
        } else if (std.mem.eql(u8, p.kind, "VolatilePtr")) {
            std.debug.print("WARNING: VolatilePtr used — unsafe, hardware access only\n", .{});
            const zig_type = try self.typeToZig(p.type_arg);
            if (p.addr_arg.* == .borrow_expr) {
                // VolatilePtr(T, &x) → @as(*volatile T, @ptrCast(&x))
                try self.writeFmt("@as(*volatile {s}, @ptrCast(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.write("))");
            } else {
                // VolatilePtr(T, 0xFF200000) → @as(*volatile T, @ptrFromInt(addr))
                try self.writeFmt("@as(*volatile {s}, @ptrFromInt(", .{zig_type});
                try self.generateExpr(p.addr_arg);
                try self.write("))");
            }
        }
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
                if (std.mem.eql(u8, name, "Error")) return "KodrError";
                return builtins.ZigMapping.primitiveToZig(name);
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
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, "Error")) has_error = true;
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) has_null = true;
                }
                // Find the non-Error/non-null type
                for (u) |t| {
                    if (t.* == .type_named and
                        !std.mem.eql(u8, t.type_named, "Error") and
                        !std.mem.eql(u8, t.type_named, "null"))
                    {
                        const inner = try self.typeToZig(t);
                        if (has_error) break :blk try self.allocTypeStr("KodrResult({s})", .{inner});
                        if (has_null) break :blk try self.allocTypeStr("KodrNullable({s})", .{inner});
                    }
                }
                break :blk "KodrUnion";
            },
            .type_ptr => |p| blk: {
                if (std.mem.eql(u8, p.kind, "const &")) {
                    const inner = try self.typeToZig(p.elem);
                    break :blk try self.allocTypeStr("*const {s}", .{inner});
                } else if (std.mem.eql(u8, p.kind, "var &")) {
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
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("KodrThread({s})", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Async")) {
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("KodrAsync({s})", .{inner});
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
            // @cast(i64, x) — type arg parsed as identifier by parseExpr
            .identifier => |name| builtins.ZigMapping.primitiveToZig(name),
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
fn isResultValueField(name: []const u8) bool {
    // Primitive type names
    const primitives = [_][]const u8{
        "i8", "i16", "i32", "i64", "i128",
        "u8", "u16", "u32", "u64", "u128",
        "isize", "usize",
        "f16", "bf16", "f32", "f64", "f128",
        "bool", "string", "void",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    // PascalCase user type names (first char uppercase, not a field name)
    if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') return true;
    return false;
}

/// Check if an AST node (or its children) contains an Error union type
fn nodeContainsErrorUnion(node: *parser.Node) bool {
    switch (node.*) {
        .func_decl => |f| {
            if (f.return_type.* == .type_union) {
                for (f.return_type.type_union) |t| {
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, "Error")) return true;
                }
            }
            return false;
        },
        .struct_decl => |s| {
            for (s.members) |m| {
                if (nodeContainsErrorUnion(m)) return true;
            }
            return false;
        },
        .error_literal => return true,
        .const_decl => |v| {
            if (v.type_annotation) |ta| {
                if (ta.* == .type_named and std.mem.eql(u8, ta.type_named, "Error")) return true;
            }
            return v.value.* == .error_literal;
        },
        else => return false,
    }
}

/// Check if an AST node (or its children) contains a null union type
fn nodeContainsNullUnion(node: *parser.Node) bool {
    switch (node.*) {
        .func_decl => |f| {
            if (f.return_type.* == .type_union) {
                for (f.return_type.type_union) |t| {
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) return true;
                }
            }
            return false;
        },
        .struct_decl => |s| {
            for (s.members) |m| {
                if (nodeContainsNullUnion(m)) return true;
            }
            return false;
        },
        .var_decl, .const_decl => |v| {
            if (v.type_annotation) |ta| {
                if (ta.* == .type_union) {
                    for (ta.type_union) |t| {
                        if (t.* == .type_named and std.mem.eql(u8, t.type_named, "null")) return true;
                    }
                }
            }
            return false;
        },
        else => return false,
    }
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
        .is_extern = false,
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

test "codegen - type to zig" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var str_type = parser.Node{ .type_named = "string" };
    try std.testing.expectEqualStrings("[]const u8", try gen.typeToZig(&str_type));

    var i32_type = parser.Node{ .type_named = "i32" };
    try std.testing.expectEqualStrings("i32", try gen.typeToZig(&i32_type));

    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "i32" };
    var slice_type = parser.Node{ .type_slice = elem };
    const slice_zig = try gen.typeToZig(&slice_type);
    try std.testing.expectEqualStrings("[]i32", slice_zig);
}

test "codegen - extern func emits nothing" {
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

    // empty block placeholder — extern func body is never used
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
        .is_extern = true,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "zigstd" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    try gen.generate(prog, "zigstd");
    try std.testing.expect(!reporter.hasErrors());

    // extern func should produce no function definition in output
    const output = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "fn print(") == null);
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
        .path = "zigstd",
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
    // alias defaults to module name "zigstd", not scope "std"
    try std.testing.expect(std.mem.indexOf(u8, output, "const zigstd = @import(\"zigstd.zig\")") != null);
}
