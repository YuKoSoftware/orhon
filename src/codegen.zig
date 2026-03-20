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
const AllocKind = enum { gpa, smp, arena, temp, page };

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
    list_vars: std.StringHashMapUnmanaged([]const u8), // variables holding List(T) → allocator name
    map_vars: std.StringHashMapUnmanaged([]const u8), // variables holding Map(K,V) → allocator name
    set_vars: std.StringHashMapUnmanaged([]const u8), // variables holding Set(T) → allocator name
    allocator_vars: std.StringHashMapUnmanaged(AllocInfo), // variables holding a mem.* allocator
    heap_single_vars: std.StringHashMapUnmanaged([]const u8), // heap singles: var → allocator name
    in_test_block: bool, // inside a test { } block — @assert uses std.testing.expect
    destruct_counter: usize, // unique index for destructuring temp vars
    warned_rawptr: bool,     // RawPtr/VolatilePtr warning printed once per module
    module_name: []const u8, // current module name — used for extern re-exports
    assigned_vars: std.StringHashMapUnmanaged(void), // vars assigned after declaration in current func
    bitfield_vars: std.StringHashMapUnmanaged([]const u8), // var name → bitfield type name
    type_ctx: ?*parser.Node, // expected type from enclosing decl (for overflow codegen)
    locs: ?*const parser.LocMap, // AST node → source location (set by main.zig)
    source_file: []const u8,     // anchor file path for location reporting

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
            .list_vars = .{},
            .map_vars = .{},
            .set_vars = .{},
            .allocator_vars = .{},
            .heap_single_vars = .{},
            .in_test_block = false,
            .destruct_counter = 0,
            .warned_rawptr = false,
            .module_name = "",
            .assigned_vars = .{},
            .bitfield_vars = .{},
            .type_ctx = null,
            .locs = null,
            .source_file = "",
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

    /// Check if a name is a declared bitfield type
    fn isBitfieldType(self: *const CodeGen, name: []const u8) bool {
        const decls = self.decls orelse return false;
        return decls.bitfields.contains(name);
    }

    pub fn deinit(self: *CodeGen) void {
        for (self.type_strings.items) |s| self.allocator.free(s);
        self.type_strings.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.null_vars.deinit(self.allocator);
        self.rawptr_vars.deinit(self.allocator);
        self.ptr_vars.deinit(self.allocator);
        { var it = self.list_vars.valueIterator(); while (it.next()) |v| self.allocator.free(v.*); }
        self.list_vars.deinit(self.allocator);
        { var it = self.map_vars.valueIterator(); while (it.next()) |v| self.allocator.free(v.*); }
        self.map_vars.deinit(self.allocator);
        { var it = self.set_vars.valueIterator(); while (it.next()) |v| self.allocator.free(v.*); }
        self.set_vars.deinit(self.allocator);
        var it = self.allocator_vars.iterator();
        while (it.next()) |e| if (e.value_ptr.impl_name.len > 0) self.allocator.free(e.value_ptr.impl_name);
        self.allocator_vars.deinit(self.allocator);
        var hs_it = self.heap_single_vars.iterator();
        while (hs_it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.heap_single_vars.deinit(self.allocator);
        self.assigned_vars.deinit(self.allocator);
        { var bv_it = self.bitfield_vars.valueIterator(); while (bv_it.next()) |v| self.allocator.free(v.*); }
        self.bitfield_vars.deinit(self.allocator);
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
        self.module_name = module_name;

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
        try self.write("fn kodrTypeId(comptime T: type) usize { return @intFromPtr(@typeName(T).ptr); }\n");

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
            if (nodeUsesOverflow(node)) return true;
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

    /// Extract the value type from a (Error | T) or (null | T) union type annotation.
    /// Returns null if not a recognized union or no non-Error/non-null type found.
    fn extractValueType(node: *parser.Node) ?*parser.Node {
        if (node.* != .type_union) return null;
        for (node.type_union) |t| {
            if (t.* == .type_named and
                (std.mem.eql(u8, t.type_named, "Error") or std.mem.eql(u8, t.type_named, "null")))
                continue;
            return t;
        }
        return null;
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

    /// Check if a value expression is a collection constructor of the given kind
    fn isCollExpr(value: *parser.Node, kind: []const u8) bool {
        return value.* == .coll_expr and std.mem.eql(u8, value.coll_expr.kind, kind);
    }

    /// True when a coll_expr owns its allocator:
    /// - no alloc_arg (default) → owned GPA
    /// - inline mem.DebugAllocator() / mem.Arena() etc. → owned
    /// - named variable → shared (not owned)
    fn isOwnedColl(c: parser.CollExpr) bool {
        const arg = c.alloc_arg orelse return true; // no arg = default owned
        return getMemAllocKind(arg) != null;
    }

    fn isListVar(self: *const CodeGen, name: []const u8) bool {
        return self.list_vars.contains(name);
    }
    fn isMapVar(self: *const CodeGen, name: []const u8) bool {
        return self.map_vars.contains(name);
    }
    fn isSetVar(self: *const CodeGen, name: []const u8) bool {
        return self.set_vars.contains(name);
    }

    /// Return the allocator expression for a collection object node (used in unmanaged API calls).
    fn getCollAllocName(self: *const CodeGen, obj: *parser.Node) []const u8 {
        if (obj.* == .identifier) {
            if (self.list_vars.get(obj.identifier)) |a| return a;
            if (self.map_vars.get(obj.identifier)) |a| return a;
            if (self.set_vars.get(obj.identifier)) |a| return a;
        }
        return "std.heap.smp_allocator";
    }

    /// Extract allocator name from a shared coll_expr (alloc_arg is a named identifier).
    fn sharedCollAllocName(c: parser.CollExpr) []const u8 {
        const arg = c.alloc_arg orelse return "std.heap.smp_allocator";
        return if (arg.* == .identifier) arg.identifier else "std.heap.smp_allocator";
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
            .bitfield_decl => |b| try self.generateBitfield(b),
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

    fn generateFunc(self: *CodeGen, f: parser.FuncDecl) anyerror!void {
        // extern func — re-export from paired sidecar file
        if (f.is_extern) {
            try self.writeLineFmt("pub const {s} = @import(\"{s}_extern.zig\").{s};", .{ f.name, self.module_name, f.name });
            return;
        }

        // Track if this function returns an error or null union
        const prev_error = self.in_error_union_func;
        const prev_null = self.in_null_union_func;
        // Clear per-function tracking maps — each function has its own scope
        const prev_null_vars = self.null_vars;
        const prev_rawptr_vars = self.rawptr_vars;
        const prev_ptr_vars = self.ptr_vars;
        const prev_list_vars = self.list_vars;
        const prev_map_vars = self.map_vars;
        const prev_set_vars = self.set_vars;
        const prev_allocator_vars = self.allocator_vars;
        const prev_heap_single_vars = self.heap_single_vars;
        const prev_assigned_vars = self.assigned_vars;
        self.null_vars = .{};
        self.rawptr_vars = .{};
        self.ptr_vars = .{};
        self.list_vars = .{};
        self.map_vars = .{};
        self.set_vars = .{};
        self.allocator_vars = .{};
        self.heap_single_vars = .{};
        self.assigned_vars = .{};
        self.in_error_union_func = false;
        self.in_null_union_func = false;
        try collectAssigned(f.body, &self.assigned_vars, self.allocator);
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
            { var _lv = self.list_vars.valueIterator(); while (_lv.next()) |v| self.allocator.free(v.*); }
            self.list_vars.deinit(self.allocator);
            self.list_vars = prev_list_vars;
            { var _mv = self.map_vars.valueIterator(); while (_mv.next()) |v| self.allocator.free(v.*); }
            self.map_vars.deinit(self.allocator);
            self.map_vars = prev_map_vars;
            { var _sv = self.set_vars.valueIterator(); while (_sv.next()) |v| self.allocator.free(v.*); }
            self.set_vars.deinit(self.allocator);
            self.set_vars = prev_set_vars;
            var _it = self.allocator_vars.iterator();
            while (_it.next()) |e| if (e.value_ptr.impl_name.len > 0) self.allocator.free(e.value_ptr.impl_name);
            self.allocator_vars.deinit(self.allocator);
            self.allocator_vars = prev_allocator_vars;
            var _hs_it = self.heap_single_vars.iterator();
            while (_hs_it.next()) |e| self.allocator.free(e.value_ptr.*);
            self.heap_single_vars.deinit(self.allocator);
            self.heap_single_vars = prev_heap_single_vars;
            self.assigned_vars.deinit(self.allocator);
            self.assigned_vars = prev_assigned_vars;
            { var _bv = self.bitfield_vars.valueIterator(); while (_bv.next()) |v| self.allocator.free(v.*); }
            self.bitfield_vars.deinit(self.allocator);
            self.bitfield_vars = .{};
        }

        // pub modifier — always pub for main (Zig requires pub fn main for exe entry)
        if (f.is_pub or std.mem.eql(u8, f.name, "main")) try self.write("pub ");

        // compt func + `type` return → generic type fn with `comptime T: type` params
        // compt func + other return  → inline fn with `anytype` params
        // regular func               → fn (anytype params handled in loop below)
        const returns_type = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, "type");
        const is_type_generic = f.is_compt and returns_type;

        if (f.is_compt and !is_type_generic) {
            try self.writeFmt("inline fn {s}(", .{f.name});
        } else {
            try self.writeFmt("fn {s}(", .{f.name});
        }

        // Parameters — track first `any` param name for return type inference
        var first_any_param: ?[]const u8 = null;
        for (f.params, 0..) |param, i| {
            if (i > 0) try self.write(", ");
            if (param.* == .param) {
                const is_any = param.param.type_annotation.* == .type_named and
                    std.mem.eql(u8, param.param.type_annotation.type_named, "any");
                if (is_any and first_any_param == null) first_any_param = param.param.name;
                if (is_type_generic and is_any) {
                    // `compt func F(T: any) type` → `fn F(comptime T: type)`
                    try self.writeFmt("comptime {s}: type", .{param.param.name});
                } else if (is_any) {
                    // generic value param → anytype
                    try self.writeFmt("{s}: anytype", .{param.param.name});
                } else {
                    try self.writeFmt("{s}: {s}", .{
                        param.param.name,
                        try self.typeToZig(param.param.type_annotation),
                    });
                }
            }
        }

        try self.write(") ");

        // Return type — `any` return becomes @TypeOf(first_any_param)
        const return_is_any = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, "any");
        if (return_is_any) {
            if (first_any_param) |pname| {
                try self.writeFmt("@TypeOf({s})", .{pname});
            } else {
                try self.write("anyopaque"); // fallback: no any param found
            }
        } else {
            try self.write(try self.typeToZig(f.return_type));
        }
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

    fn generateBitfield(self: *CodeGen, b: parser.BitfieldDecl) anyerror!void {
        if (b.is_pub) try self.write("pub ");
        const backing = try self.typeToZig(b.backing_type);

        try self.writeFmt("const {s} = struct {{\n", .{b.name});
        self.indent += 1;

        // Named flag constants — powers of 2
        for (b.members, 0..) |flag_name, i| {
            try self.writeIndent();
            try self.writeFmt("pub const {s}: {s} = {d};\n", .{ flag_name, backing, @as(u64, 1) << @intCast(i) });
        }

        // value field
        try self.writeIndent();
        try self.writeFmt("value: {s} = 0,\n", .{backing});

        // methods
        try self.writeIndent();
        try self.writeFmt("pub fn has(self: {s}, flag: {s}) bool {{ return (self.value & flag) != 0; }}\n", .{ b.name, backing });
        try self.writeIndent();
        try self.writeFmt("pub fn set(self: *{s}, flag: {s}) void {{ self.value |= flag; }}\n", .{ b.name, backing });
        try self.writeIndent();
        try self.writeFmt("pub fn clear(self: *{s}, flag: {s}) void {{ self.value &= ~flag; }}\n", .{ b.name, backing });
        try self.writeIndent();
        try self.writeFmt("pub fn toggle(self: *{s}, flag: {s}) void {{ self.value ^= flag; }}\n", .{ b.name, backing });

        self.indent -= 1;
        try self.write("};\n");
    }

    // ============================================================
    // MEMORY ALLOCATORS (std::mem)
    // ============================================================

    /// Detect if a node is a mem.DebugAllocator() / mem.Arena() / mem.Temp(n) / mem.Page() constructor call.
    fn getMemAllocKind(node: *parser.Node) ?AllocKind {
        if (node.* != .call_expr) return null;
        const c = node.call_expr;
        if (c.callee.* != .field_expr) return null;
        const fe = c.callee.field_expr;
        if (fe.object.* != .identifier) return null;
        if (!std.mem.eql(u8, fe.object.identifier, "mem")) return null;
        if (std.mem.eql(u8, fe.field, "DebugAllocator")) return .gpa;
        if (std.mem.eql(u8, fe.field, "SMP"))   return .smp;
        if (std.mem.eql(u8, fe.field, "Arena")) return .arena;
        if (std.mem.eql(u8, fe.field, "Temp"))  return .temp;
        if (std.mem.eql(u8, fe.field, "Page"))  return .page;
        return null;
    }

    /// Generate allocator initialization statements for: var a = mem.DebugAllocator() etc.
    /// Expands to multi-line Zig — backing struct + defer deinit + allocator() call.
    /// NOTE: generateBlock already called writeIndent() before this statement, so the
    /// first line must NOT call writeIndent(); subsequent lines must.
    fn generateAllocatorInit(self: *CodeGen, name: []const u8, kind: AllocKind, args: []*parser.Node) anyerror!void {
        const impl_name = try std.fmt.allocPrint(self.allocator, "_{s}_impl", .{name});
        switch (kind) {
            .gpa => {
                try self.writeFmt("var {s} = std.heap.DebugAllocator(.{{}}){{}};\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("defer _ = {s}.deinit();\n", .{impl_name});
                try self.writeIndent(); try self.writeFmt("const {s} = {s}.allocator();", .{name, impl_name});
            },
            .smp => {
                // smp_allocator is a global singleton — no init/deinit
                try self.writeFmt("const {s} = std.heap.smp_allocator;", .{name});
                self.allocator.free(impl_name);
                try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = "" });
                return;
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
        // Owned collection: List(T) / List(T, mem.DebugAllocator()) etc. — multi-statement expansion
        if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
            return self.generateOwnedCollDecl("const", v.name, v.type_annotation, v.value.coll_expr);
        // mem.DebugAllocator() / mem.Arena() / mem.Temp(n) / mem.Page() — multi-statement expansion
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
            if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (v.type_annotation) |t| {
                if (t.* == .type_named and self.isBitfieldType(t.type_named))
                    try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
            }
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
    }

    fn generateVar(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        // Owned collection: List(T) / List(T, mem.DebugAllocator()) etc. — multi-statement expansion
        if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
            return self.generateOwnedCollDecl("var", v.name, v.type_annotation, v.value.coll_expr);
        // mem.DebugAllocator() / mem.Arena() / mem.Temp(n) / mem.Page() — multi-statement expansion
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
            if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
            if (v.type_annotation) |t| {
                if (t.* == .type_named and self.isBitfieldType(t.type_named))
                    try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
            }
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
                if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
                    return self.generateOwnedCollDecl("var", v.name, v.type_annotation, v.value.coll_expr);
                if (getMemAllocKind(v.value)) |kind| {
                    return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
                }
                if (self.getAllocOneCall(v.value)) |ac| {
                    return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
                }
                const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
                const is_mutated = self.assigned_vars.contains(v.name);
                const kw: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    // User wrote `var` but never reassigns — emit a warning
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "'{s}' is declared as var but never reassigned — use const", .{v.name});
                    defer self.allocator.free(msg);
                    try self.reporter.warn(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                try self.writeFmt("{s} {s}", .{ kw, v.name });
                if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                try self.write(" = ");
                if (is_null_union) {
                    try self.null_vars.put(self.allocator, v.name, {});
                    try self.generateNullWrappedExpr(v.value);
                } else {
                    if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
                    if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
                    if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (v.type_annotation) |t| {
                        if (t.* == .type_named and self.isBitfieldType(t.type_named))
                            try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
                    }
                    const prev_ctx = self.type_ctx;
                    self.type_ctx = v.type_annotation;
                    try self.generateExpr(v.value);
                    self.type_ctx = prev_ctx;
                }
                try self.write(";");
            },
            .const_decl => |v| {
                if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
                    return self.generateOwnedCollDecl("const", v.name, v.type_annotation, v.value.coll_expr);
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
                    if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, sharedCollAllocName(v.value.coll_expr)));
                    if (v.type_annotation) |t| {
                        if (t.* == .type_named and self.isBitfieldType(t.type_named))
                            try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
                    }
                    const prev_ctx = self.type_ctx;
                    self.type_ctx = v.type_annotation;
                    try self.generateExpr(v.value);
                    self.type_ctx = prev_ctx;
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
                try self.writeFmt("const {s}: {s} = ", .{
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
                    } else if (it.* == .identifier and self.isListVar(it.identifier)) {
                        // for(list) → for(list.items)
                        try self.writeFmt("{s}.items", .{it.identifier});
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
                // String match — Zig has no string switch, desugar to if/else chain
                const is_string_match = blk: {
                    for (m.arms) |arm| {
                        if (arm.* == .match_arm and arm.match_arm.pattern.* == .string_literal)
                            break :blk true;
                    }
                    break :blk false;
                };

                // Type match — any arm is `Error` or `null` identifier
                // match result { Error => { } i32 => { } }
                // match user   { null  => { } User => { } }
                const is_type_match = blk: {
                    for (m.arms) |arm| {
                        if (arm.* != .match_arm) continue;
                        const pat = arm.match_arm.pattern;
                        if (pat.* == .null_literal) break :blk true;
                        if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "Error"))
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
                        // Check for wildcard pattern (else)
                        if (arm.match_arm.pattern.* == .identifier and
                            std.mem.eql(u8, arm.match_arm.pattern.identifier, "else"))
                        {
                            has_wildcard = true;
                            try self.write("else");
                        } else if (arm.match_arm.pattern.* == .range_expr) {
                            // Range pattern: 4..8 in Kodr → 4...8 in Zig switch (inclusive)
                            const r = arm.match_arm.pattern.range_expr;
                            try self.generateExpr(r.left);
                            try self.write("...");
                            try self.generateExpr(r.right);
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
                } // close else (non-string, non-type match)
            },
            .break_stmt => try self.write("break;"),
            .continue_stmt => try self.write("continue;"),
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
            .thread_block => {
                const msg = try std.fmt.allocPrint(self.allocator, "Thread is not yet implemented", .{});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
            },
            .async_block => {
                const msg = try std.fmt.allocPrint(self.allocator, "Async is not yet implemented", .{});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg });
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
                // `x is Error`   → x == .err    (error union tag check)
                // `x is null`    → x == .none   (null union tag check)
                // `x is T`       → @TypeOf(x) == T  (comptime type check for `any` params)
                // `x is not ...` → same but with !=
                const is_eq = std.mem.eql(u8, b.op, "==");
                const is_ne = std.mem.eql(u8, b.op, "!=");
                if ((is_eq or is_ne) and
                    b.left.* == .compiler_func and
                    std.mem.eql(u8, b.left.compiler_func.name, "type") and
                    b.left.compiler_func.args.len > 0)
                {
                    const val_node = b.left.compiler_func.args[0];
                    const cmp = if (is_eq) "==" else "!=";
                    // null is a keyword, parsed as .null_literal not .identifier
                    if (b.right.* == .null_literal) {
                        try self.write("(");
                        try self.generateExpr(val_node);
                        try self.writeFmt(" {s} .none)", .{cmp});
                        return;
                    }
                    if (b.right.* == .identifier) {
                        const rhs = b.right.identifier;
                        if (std.mem.eql(u8, rhs, "Error")) {
                            try self.write("(");
                            try self.generateExpr(val_node);
                            try self.writeFmt(" {s} .err)", .{cmp});
                            return;
                        }
                        // General type check: `val is i32` → `@TypeOf(val) == i32`
                        // Map Kodr type names to Zig (e.g. String → []const u8)
                        const zig_rhs = builtins.ZigMapping.primitiveToZig(rhs);
                        try self.write("(@TypeOf(");
                        try self.generateExpr(val_node);
                        try self.writeFmt(") {s} {s})", .{ cmp, zig_rhs });
                        return;
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
                // overflow/wrap/sat builtins
                if (c.callee.* == .identifier and c.args.len == 1) {
                    const callee_name = c.callee.identifier;
                    if (std.mem.eql(u8, callee_name, "wrap")) {
                        try self.generateWrapExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "sat")) {
                        try self.generateSatExpr(c.args[0]);
                        return;
                    } else if (std.mem.eql(u8, callee_name, "overflow")) {
                        try self.generateOverflowExpr(c.args[0]);
                        return;
                    }
                }
                // Collection method calls: list.add(), map.put(), set.add() etc.
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        const obj = fe.object.identifier;
                        if (self.isListVar(obj)) {
                            try self.generateListMethod(fe.object, fe.field, c.args);
                            return;
                        }
                        if (self.isMapVar(obj)) {
                            try self.generateMapMethod(fe.object, fe.field, c.args);
                            return;
                        }
                        if (self.isSetVar(obj)) {
                            try self.generateSetMethod(fe.object, fe.field, c.args);
                            return;
                        }
                    }
                }
                // Bitfield method calls: mode.has(Flag), mode.set(Flag), etc.
                // Flag identifiers must be qualified: Perms.Flag
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        if (self.bitfield_vars.get(fe.object.identifier)) |type_name| {
                            try self.generateExpr(fe.object);
                            try self.writeFmt(".{s}(", .{fe.field});
                            for (c.args, 0..) |arg, i| {
                                if (i > 0) try self.write(", ");
                                if (arg.* == .identifier) {
                                    try self.writeFmt("{s}.{s}", .{ type_name, arg.identifier });
                                } else {
                                    try self.generateExpr(arg);
                                }
                            }
                            try self.write(")");
                            return;
                        }
                    }
                }
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
                // Bitfield constructor: Permissions(Read, Write) → Permissions{ .value = Permissions.Read | Permissions.Write }
                if (c.callee.* == .identifier and self.isBitfieldType(c.callee.identifier)) {
                    const type_name = c.callee.identifier;
                    try self.writeFmt("{s}{{ .value = ", .{type_name});
                    if (c.args.len == 0) {
                        try self.write("0");
                    } else {
                        for (c.args, 0..) |arg, i| {
                            if (i > 0) try self.write(" | ");
                            if (arg.* == .identifier) {
                                try self.writeFmt("{s}.{s}", .{ type_name, arg.identifier });
                            } else {
                                try self.generateExpr(arg);
                            }
                        }
                    }
                    try self.write(" }");
                    return;
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
                } else if (std.mem.eql(u8, f.field, "len") and
                    f.object.* == .identifier and self.isListVar(f.object.identifier))
                {
                    // list.len → list.items.len
                    try self.generateExpr(f.object);
                    try self.write(".items.len");
                } else if (std.mem.eql(u8, f.field, "len") and
                    f.object.* == .identifier and
                    (self.isMapVar(f.object.identifier) or self.isSetVar(f.object.identifier)))
                {
                    // map.len / set.len → map.count()
                    try self.generateExpr(f.object);
                    try self.write(".count()");
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
            .slice_expr => |s| {
                try self.generateExpr(s.object);
                try self.write("[");
                const low_is_literal = s.low.* == .int_literal;
                if (!low_is_literal) {
                    try self.write("@intCast(");
                    try self.generateExpr(s.low);
                    try self.write(")");
                } else {
                    try self.generateExpr(s.low);
                }
                try self.write("..");
                const high_is_literal = s.high.* == .int_literal;
                if (!high_is_literal) {
                    try self.write("@intCast(");
                    try self.generateExpr(s.high);
                    try self.write(")");
                } else {
                    try self.generateExpr(s.high);
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
            .coll_expr => |c| {
                try self.generateCollExpr(c);
            },
            .struct_type => |fields| {
                try self.write("struct {\n");
                self.indent += 1;
                for (fields) |f| {
                    if (f.* == .field_decl) {
                        try self.writeIndent();
                        try self.writeFmt("{s}: {s},\n", .{
                            f.field_decl.name,
                            try self.typeToZig(f.field_decl.type_annotation),
                        });
                    }
                }
                self.indent -= 1;
                try self.writeIndent();
                try self.write("}");
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

    /// Desugar a type match on (Error|T) or (null|T) into a Zig switch on the tagged union.
    /// match result { Error => { } i32 => { } }
    /// → switch (result) { .err => { }, .ok => { } }
    fn generateTypeMatch(self: *CodeGen, m: parser.MatchStmt, is_null_union: bool) anyerror!void {
        try self.write("switch (");
        try self.generateExpr(m.value);
        try self.write(") {\n");
        self.indent += 1;

        for (m.arms) |arm| {
            if (arm.* != .match_arm) continue;
            const pat = arm.match_arm.pattern;
            try self.writeIndent();

            if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "Error")) {
                // Error arm → .err
                try self.write(".err");
            } else if (pat.* == .null_literal) {
                // null arm → .none
                try self.write(".none");
            } else if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                // catch-all
                try self.write("else");
            } else {
                // The value type arm → .ok (error union) or .some (null union)
                if (is_null_union) {
                    try self.write(".some");
                } else {
                    try self.write(".ok");
                }
            }

            try self.write(" => ");
            try self.generateBlock(arm.match_arm.body);
            try self.write(",\n");
        }

        self.indent -= 1;
        try self.writeIndent();
        try self.write("}");
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
                try self.write("if (std.mem.eql(u8, ");
                first = false;
            } else {
                try self.write(" else if (std.mem.eql(u8, ");
            }

            // The value being matched
            if (m.value.* == .identifier and std.mem.eql(u8, m.value.identifier, "self")) {
                try self.write("self.*");
            } else {
                try self.generateExpr(m.value);
            }
            try self.write(", ");
            try self.generateExpr(pat);
            try self.write(")) ");
            try self.generateBlock(body);
        }

        if (wildcard_body) |wb| {
            if (first) {
                // All arms were wildcards — just emit the body
                try self.generateBlock(wb);
            } else {
                try self.write(" else ");
                try self.generateBlock(wb);
            }
        } else if (!first) {
            // No wildcard — close with empty else to be safe
            try self.write(" else {}");
        }
    }

    fn generateWrapExpr(self: *CodeGen, arg: *parser.Node) anyerror!void {
        if (arg.* == .binary_expr) {
            const b = arg.binary_expr;
            const wrap_op: ?[]const u8 =
                if (std.mem.eql(u8, b.op, "+")) "+%"
                else if (std.mem.eql(u8, b.op, "-")) "-%"
                else if (std.mem.eql(u8, b.op, "*")) "*%"
                else null;
            if (wrap_op) |op| {
                try self.generateExpr(b.left);
                try self.writeFmt(" {s} ", .{op});
                try self.generateExpr(b.right);
                return;
            }
        }
        try self.generateExpr(arg);
    }

    fn generateSatExpr(self: *CodeGen, arg: *parser.Node) anyerror!void {
        if (arg.* == .binary_expr) {
            const b = arg.binary_expr;
            const sat_op: ?[]const u8 =
                if (std.mem.eql(u8, b.op, "+")) "+|"
                else if (std.mem.eql(u8, b.op, "-")) "-|"
                else if (std.mem.eql(u8, b.op, "*")) "*|"
                else null;
            if (sat_op) |op| {
                try self.generateExpr(b.left);
                try self.writeFmt(" {s} ", .{op});
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
                //   if (_ov[1] != 0) break :blk KodrResult(@TypeOf(a)){ .err = .{ .message = "overflow" } }
                //   else break :blk KodrResult(@TypeOf(a)){ .ok = _ov[0] }; })
                // When operands are literals, @TypeOf gives comptime_int which Zig rejects.
                // Use the concrete type from the enclosing decl's type_ctx if available.
                const left_is_literal = b.left.* == .int_literal or b.left.* == .float_literal;
                const type_str: ?[]const u8 = if (left_is_literal) blk: {
                    if (self.type_ctx) |ctx| {
                        if (extractValueType(ctx)) |vt| break :blk try self.typeToZig(vt);
                    }
                    break :blk null;
                } else null;

                try self.write("(blk: { const _ov = ");
                try self.writeFmt("{s}(", .{builtin});
                if (type_str) |ts| {
                    try self.writeFmt("@as({s}, ", .{ts});
                    try self.generateExpr(b.left);
                    try self.write(")");
                } else {
                    try self.generateExpr(b.left);
                }
                try self.write(", ");
                try self.generateExpr(b.right);
                if (type_str) |ts| {
                    try self.write("); if (_ov[1] != 0) break :blk KodrResult(");
                    try self.write(ts);
                    try self.write("){ .err = .{ .message = \"overflow\" } } else break :blk KodrResult(");
                    try self.write(ts);
                    try self.write("){ .ok = _ov[0] }; })");
                } else {
                    try self.write("); if (_ov[1] != 0) break :blk KodrResult(@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.write(")){ .err = .{ .message = \"overflow\" } } else break :blk KodrResult(@TypeOf(");
                    try self.generateExpr(b.left);
                    try self.write(")){ .ok = _ov[0] }; })");
                }
                return;
            }
        }
        try self.generateExpr(arg);
    }

    fn generateCompilerFunc(self: *CodeGen, cf: parser.CompilerFunc) anyerror!void {
        // Map Kodr @functions to Zig equivalents
        if (std.mem.eql(u8, cf.name, "typename")) {
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
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
                self.warned_rawptr = true;
            }
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
            if (!self.warned_rawptr) {
                std.debug.print("WARNING: VolatilePtr used — unsafe, hardware access only\n", .{});
                self.warned_rawptr = true;
            }
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

    fn generateListMethod(self: *CodeGen, obj: *parser.Node, method: []const u8, args: []*parser.Node) anyerror!void {
        const alloc = self.getCollAllocName(obj);
        if (std.mem.eql(u8, method, "add")) {
            // list.add(x) → list.append(alloc, x) catch unreachable
            try self.generateExpr(obj);
            try self.writeFmt(".append({s}, ", .{alloc});
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(") catch unreachable");
        } else if (std.mem.eql(u8, method, "get")) {
            // list.get(i) → list.items[@intCast(i)]
            try self.generateExpr(obj);
            try self.write(".items[");
            if (args.len > 0) {
                if (args[0].* == .int_literal) {
                    try self.generateExpr(args[0]);
                } else {
                    try self.write("@intCast(");
                    try self.generateExpr(args[0]);
                    try self.write(")");
                }
            }
            try self.write("]");
        } else if (std.mem.eql(u8, method, "set")) {
            // list.set(i, v) → list.items[@intCast(i)] = v
            try self.generateExpr(obj);
            try self.write(".items[");
            if (args.len > 0) {
                if (args[0].* == .int_literal) {
                    try self.generateExpr(args[0]);
                } else {
                    try self.write("@intCast(");
                    try self.generateExpr(args[0]);
                    try self.write(")");
                }
            }
            try self.write("] = ");
            if (args.len > 1) try self.generateExpr(args[1]);
        } else if (std.mem.eql(u8, method, "remove")) {
            // list.remove(i) → _ = list.orderedRemove(@intCast(i))
            try self.write("_ = ");
            try self.generateExpr(obj);
            try self.write(".orderedRemove(");
            if (args.len > 0) {
                if (args[0].* == .int_literal) {
                    try self.generateExpr(args[0]);
                } else {
                    try self.write("@intCast(");
                    try self.generateExpr(args[0]);
                    try self.write(")");
                }
            }
            try self.write(")");
        } else if (std.mem.eql(u8, method, "pop")) {
            // list.pop() → list.pop()
            try self.generateExpr(obj);
            try self.write(".pop()");
        } else if (std.mem.eql(u8, method, "clear")) {
            // list.clear() → list.clearRetainingCapacity()
            try self.generateExpr(obj);
            try self.write(".clearRetainingCapacity()");
        } else if (std.mem.eql(u8, method, "free")) {
            // list.free() → list.deinit(alloc)
            try self.generateExpr(obj);
            try self.writeFmt(".deinit({s})", .{alloc});
        } else {
            // pass through unknown methods
            try self.generateExpr(obj);
            try self.writeFmt(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try self.write(", ");
                try self.generateExpr(a);
            }
            try self.write(")");
        }
    }

    fn generateMapMethod(self: *CodeGen, obj: *parser.Node, method: []const u8, args: []*parser.Node) anyerror!void {
        const alloc = self.getCollAllocName(obj);
        if (std.mem.eql(u8, method, "put")) {
            // map.put(k, v) → map.put(alloc, k, v) catch unreachable
            try self.generateExpr(obj);
            try self.writeFmt(".put({s}", .{alloc});
            for (args) |a| {
                try self.write(", ");
                try self.generateExpr(a);
            }
            try self.write(") catch unreachable");
        } else if (std.mem.eql(u8, method, "get")) {
            // map.get(k) → map.get(k).?  (panics if missing — use has() first)
            try self.generateExpr(obj);
            try self.write(".get(");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(").?");
        } else if (std.mem.eql(u8, method, "has")) {
            // map.has(k) → map.contains(k)
            try self.generateExpr(obj);
            try self.write(".contains(");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "remove")) {
            // map.remove(k) → _ = map.remove(k)
            try self.write("_ = ");
            try self.generateExpr(obj);
            try self.write(".remove(");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "free")) {
            try self.generateExpr(obj);
            try self.writeFmt(".deinit({s})", .{alloc});
        } else {
            try self.generateExpr(obj);
            try self.writeFmt(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try self.write(", ");
                try self.generateExpr(a);
            }
            try self.write(")");
        }
    }

    fn generateSetMethod(self: *CodeGen, obj: *parser.Node, method: []const u8, args: []*parser.Node) anyerror!void {
        const alloc = self.getCollAllocName(obj);
        if (std.mem.eql(u8, method, "add")) {
            // set.add(x) → set.put(alloc, x, {}) catch unreachable
            try self.generateExpr(obj);
            try self.writeFmt(".put({s}, ", .{alloc});
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(", {}) catch unreachable");
        } else if (std.mem.eql(u8, method, "has")) {
            // set.has(x) → set.contains(x)
            try self.generateExpr(obj);
            try self.write(".contains(");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "remove")) {
            // set.remove(x) → _ = set.remove(x)
            try self.write("_ = ");
            try self.generateExpr(obj);
            try self.write(".remove(");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "free")) {
            try self.generateExpr(obj);
            try self.writeFmt(".deinit({s})", .{alloc});
        } else {
            try self.generateExpr(obj);
            try self.writeFmt(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try self.write(", ");
                try self.generateExpr(a);
            }
            try self.write(")");
        }
    }

    /// Generate a collection declaration where the collection owns its allocator.
    /// Default (no arg) and mem.SMP() → use std.heap.smp_allocator (singleton, no boilerplate).
    /// mem.DebugAllocator() / mem.Arena() / mem.Temp(n) → generate allocator boilerplate first.
    /// All collections use the unmanaged API (init = .{}, allocator passed to each method).
    fn generateOwnedCollDecl(self: *CodeGen, decl_kind: []const u8, name: []const u8, type_ann: ?*parser.Node, c: parser.CollExpr) anyerror!void {
        const kind: AllocKind = if (c.alloc_arg) |arg| getMemAllocKind(arg) orelse .smp else .smp;
        const extra_args: []*parser.Node = if (c.alloc_arg) |arg|
            if (arg.* == .call_expr) arg.call_expr.args else &[_]*parser.Node{}
        else
            &[_]*parser.Node{};

        // Determine allocator expression for method calls
        const tracked_alloc: []const u8 = switch (kind) {
            .smp  => "std.heap.smp_allocator",
            .page => "std.heap.page_allocator",
            else  => try std.fmt.allocPrint(self.allocator, "_{s}_alloc", .{name}),
        };
        defer if (kind != .smp and kind != .page) self.allocator.free(tracked_alloc);

        // Generate allocator boilerplate for stateful allocators
        switch (kind) {
            .smp, .page => {}, // global singletons — no init needed
            else => {
                try self.generateAllocatorInit(tracked_alloc, kind, extra_args);
                try self.write("\n");
                try self.writeIndent();
            },
        }

        // Emit: var/const name[: type] = .{};
        try self.writeFmt("{s} {s}", .{ decl_kind, name });
        if (type_ann) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
        try self.write(" = .{};");

        // Track variable with its allocator name
        const stored_alloc = try self.allocator.dupe(u8, tracked_alloc);
        if (std.mem.eql(u8, c.kind, "List")) {
            try self.list_vars.put(self.allocator, name, stored_alloc);
        } else if (std.mem.eql(u8, c.kind, "Map")) {
            try self.map_vars.put(self.allocator, name, stored_alloc);
        } else if (std.mem.eql(u8, c.kind, "Set")) {
            try self.set_vars.put(self.allocator, name, stored_alloc);
        } else {
            self.allocator.free(stored_alloc);
        }
    }

    /// Generate a shared-allocator collection expression (named alloc only).
    /// Unmanaged API: emit .{} — allocator is passed to each method call, not stored.
    /// Owned collections are handled at declaration level by generateOwnedCollDecl.
    fn generateCollExpr(self: *CodeGen, c: parser.CollExpr) anyerror!void {
        _ = c.alloc_arg; // allocator tracked at declaration level, not embedded in init
        // All unmanaged collections zero-initialize: the type annotation carries the type.
        try self.write(".{}");
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
                if (std.mem.eql(u8, name, "mem.Allocator")) return "std.mem.Allocator";
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
                if (std.mem.eql(u8, g.name, "Thread") or std.mem.eql(u8, g.name, "Async")) {
                    break :blk "void"; // not yet implemented — codegen emits error at thread_block/async_block
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
                } else if (std.mem.eql(u8, g.name, "List")) {
                    // List(T) → std.ArrayList(T)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("std.ArrayList({s})", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Map")) {
                    // Map(K,V) → std.StringHashMapUnmanaged(V) if K is String, else std.AutoHashMapUnmanaged(K,V)
                    if (g.args.len >= 2) {
                        const key = try self.typeToZig(g.args[0]);
                        const val = try self.typeToZig(g.args[1]);
                        if (std.mem.eql(u8, key, "[]const u8")) {
                            break :blk try self.allocTypeStr("std.StringHashMapUnmanaged({s})", .{val});
                        }
                        break :blk try self.allocTypeStr("std.AutoHashMapUnmanaged({s}, {s})", .{ key, val });
                    }
                } else if (std.mem.eql(u8, g.name, "Set")) {
                    // Set(T) → std.StringHashMapUnmanaged(void) if T is String, else std.AutoHashMapUnmanaged(T, void)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        if (std.mem.eql(u8, inner, "[]const u8")) {
                            break :blk "std.StringHashMapUnmanaged(void)";
                        }
                        break :blk try self.allocTypeStr("std.AutoHashMapUnmanaged({s}, void)", .{inner});
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
        "bool", "String", "void",
    };
    for (primitives) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    // PascalCase user type names (first char uppercase, not a field name)
    if (name.len > 0 and name[0] >= 'A' and name[0] <= 'Z') return true;
    return false;
}

/// Check if an AST node (or its descendants) contains an overflow() call
fn nodeUsesOverflow(node: *parser.Node) bool {
    return switch (node.*) {
        .call_expr => |c| blk: {
            if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "overflow")) break :blk true;
            for (c.args) |a| { if (nodeUsesOverflow(a)) break :blk true; }
            break :blk false;
        },
        .func_decl => |f| nodeUsesOverflow(f.body),
        .struct_decl => |s| blk: {
            for (s.members) |m| { if (nodeUsesOverflow(m)) break :blk true; }
            break :blk false;
        },
        .block => |b| blk: {
            for (b.statements) |s| { if (nodeUsesOverflow(s)) break :blk true; }
            break :blk false;
        },
        .var_decl, .const_decl => |v| nodeUsesOverflow(v.value),
        .return_stmt => |r| if (r.value) |v| nodeUsesOverflow(v) else false,
        .if_stmt => |i| nodeUsesOverflow(i.condition) or nodeUsesOverflow(i.then_block) or
            if (i.else_block) |eb| nodeUsesOverflow(eb) else false,
        else => false,
    };
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

test "codegen - kodrTypeId always in preamble" {
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
    try std.testing.expect(std.mem.indexOf(u8, output, "fn kodrTypeId(") != null);
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

test "codegen - extern func emits re-export" {
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

    // extern func should re-export from sidecar, not emit a function definition
    const output = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "fn print(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "console_extern.zig") != null);
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

    // Verify overflow codegen uses @addWithOverflow and KodrResult
    gen.output.clearRetainingCapacity();
    try gen.generateExpr(ov_call);
    const ov_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, ov_out, "@addWithOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, ov_out, "KodrResult") != null);
}
