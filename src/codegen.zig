// codegen.zig — Zig Code Generation pass (pass 11)
// Translates MIR and AST to readable Zig source files.
// One .zig file per Kodr module. Uses std.fmt for output.

const std = @import("std");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const builtins = @import("builtins.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const K = @import("constants.zig");
const module = @import("module.zig");

/// Built-in allocator kinds from std::mem
const AllocKind = enum { gpa, smp, arena, stack, page, pool };

/// Info tracked per allocator variable
const AllocInfo = struct {
    kind: AllocKind,
    impl_name: []const u8, // backing Zig var name, e.g. "_a_impl"
};

/// Info tracked per Format variable
const FormatInfo = struct {
    alloc_expr: []const u8, // allocator expression for allocPrint
    type_specs: []const u8, // Zig format specifiers derived from tuple types
};

/// Info tracked per Thread variable
const ThreadInfo = struct {
    result_type: []const u8, // Zig type string for the result
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
    in_arb_union_func: bool, // current function returns an arbitrary union like (i32 | String)
    arb_union_return_type: ?*parser.Node, // return type node for arbitrary union wrapping
    null_vars: std.StringHashMapUnmanaged(void),       // variables with (null | T) type
    arb_union_vars: std.StringHashMapUnmanaged(*parser.Node),  // variables with arbitrary union type → type node
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
    string_vars: std.StringHashMapUnmanaged(void),        // variables holding String values
    format_vars: std.StringHashMapUnmanaged(FormatInfo),  // variables holding Format instances
    thread_vars: std.StringHashMapUnmanaged(ThreadInfo),  // variables holding Thread instances
    type_ctx: ?*parser.Node, // expected type from enclosing decl (for overflow codegen)
    locs: ?*const parser.LocMap, // AST node → source location (set by main.zig)
    source_file: []const u8,     // anchor file path for location reporting
    uses_fs: bool,               // module uses File or Dir types
    uses_mem: bool,              // module uses allocator wrappers (Debug/Arena/Stack)
    uses_string_alloc: bool,     // module uses allocating string methods (repeat)
    in_thread_block: bool,       // inside a Thread body — return → result assignment
    current_thread_name: []const u8, // name of the thread being generated
    thread_capture_renames: std.StringHashMapUnmanaged([]const u8), // original name → _cap_name
    module_builds: ?*const std.StringHashMapUnmanaged(module.BuildType), // imported module → build type

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
            .in_arb_union_func = false,
            .arb_union_return_type = null,
            .null_vars = .{},
            .arb_union_vars = .{},
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
            .string_vars = .{},
            .format_vars = .{},
            .thread_vars = .{},
            .type_ctx = null,
            .locs = null,
            .source_file = "",
            .uses_fs = false,
            .uses_mem = false,
            .uses_string_alloc = false,
            .in_thread_block = false,
            .current_thread_name = "",
            .thread_capture_renames = .{},
            .module_builds = null,
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
        self.arb_union_vars.deinit(self.allocator);
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
        self.string_vars.deinit(self.allocator);
        {
            var fi = self.format_vars.valueIterator();
            while (fi.next()) |v| {
                self.allocator.free(v.alloc_expr);
                self.allocator.free(v.type_specs);
            }
        }
        self.format_vars.deinit(self.allocator);
        {
            var ti = self.thread_vars.valueIterator();
            while (ti.next()) |v| self.allocator.free(v.result_type);
        }
        self.thread_vars.deinit(self.allocator);
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
        // Always emit KodrNullable — used by null unions and string indexOf/lastIndexOf
        try self.write("fn KodrNullable(comptime T: type) type { return union(enum) { some: T, none: void }; }\n");
        try self.write("fn kodrTypeId(comptime T: type) usize { return @intFromPtr(@typeName(T).ptr); }\n");

        // Allocator wrappers — import if module uses Debug/Arena/Stack allocators
        if (moduleUsesAllocWrappers(ast)) {
            self.uses_mem = true;
            try self.write("const KodrMem = @import(\"mem_rt.zig\");\n");
        }

        // File/Dir runtime — import if module uses these types
        if (moduleUsesFileOrDir(ast)) {
            self.uses_fs = true;
            try self.write("const KodrFs = @import(\"fs_rt.zig\");\n");
        }

        // String repeat helper
        try self.write("fn kodrStringRepeat(alloc: std.mem.Allocator, s: []const u8, n: usize) ![]const u8 { const buf = try alloc.alloc(u8, s.len * n); for (0..n) |i| { @memcpy(buf[i * s.len ..][0..s.len], s); } return buf; }\n");
        // Ring buffer — panics when full
        try self.write("fn KodrRing(comptime T: type, comptime cap: usize) type { return struct { buf: [cap]T = undefined, head: usize = 0, len: usize = 0, const Self = @This(); fn push(self: *Self, val: T) void { if (self.len >= cap) @panic(\"ring buffer full\"); self.buf[(self.head + self.len) % cap] = val; self.len += 1; } fn pop(self: *Self) ?T { if (self.len == 0) return null; const val = self.buf[self.head]; self.head = (self.head + 1) % cap; self.len -= 1; return val; } fn isFull(self: *const Self) bool { return self.len >= cap; } fn isEmpty(self: *const Self) bool { return self.len == 0; } fn count(self: *const Self) usize { return self.len; } }; }\n");
        // ORing buffer — overwrites oldest when full
        try self.write("fn KodrORing(comptime T: type, comptime cap: usize) type { return struct { buf: [cap]T = undefined, head: usize = 0, len: usize = 0, const Self = @This(); fn push(self: *Self, val: T) void { if (self.len >= cap) { self.buf[self.head] = val; self.head = (self.head + 1) % cap; } else { self.buf[(self.head + self.len) % cap] = val; self.len += 1; } } fn pop(self: *Self) ?T { if (self.len == 0) return null; const val = self.buf[self.head]; self.head = (self.head + 1) % cap; self.len -= 1; return val; } fn isFull(self: *const Self) bool { return self.len >= cap; } fn isEmpty(self: *const Self) bool { return self.len == 0; } fn count(self: *const Self) usize { return self.len; } }; }\n");

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
                (std.mem.eql(u8, t.type_named, K.Type.ERROR) or std.mem.eql(u8, t.type_named, K.Type.NULL)))
                continue;
            return t;
        }
        return null;
    }

    /// Check if a type annotation AST node is a (null | T) union
    fn isNullUnionType(node: *parser.Node) bool {
        if (node.* == .type_union) {
            for (node.type_union) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) return true;
            }
        }
        return false;
    }

    /// Check if a type_union is an arbitrary union (not Error|T or null|T)
    fn isArbitraryUnion(node: *parser.Node) bool {
        if (node.* != .type_union) return false;
        for (node.type_union) |t| {
            if (t.* == .type_named and
                (std.mem.eql(u8, t.type_named, K.Type.ERROR) or
                std.mem.eql(u8, t.type_named, K.Type.NULL))) return false;
        }
        return node.type_union.len >= 2;
    }

    /// Generate a Zig union tag name from a Kodr type name: i32 → _i32
    fn unionTagName(self: *CodeGen, kodr_name: []const u8) ![]const u8 {
        return try self.allocTypeStr("_{s}", .{kodr_name});
    }

    /// Check if a variable name is a tracked null union variable
    fn isNullVar(self: *const CodeGen, name: []const u8) bool {
        return self.null_vars.contains(name);
    }

    /// Check if a variable name is a tracked arbitrary union variable
    fn isArbUnionVar(self: *const CodeGen, name: []const u8) bool {
        return self.arb_union_vars.contains(name);
    }

    /// Look up a call expression's return type node via the declaration table.
    /// Returns the return_type_node if the callee is a known function returning an arbitrary union.
    fn callReturnsArbUnion(self: *const CodeGen, value: *parser.Node) ?*parser.Node {
        if (value.* != .call_expr) return null;
        const c = value.call_expr;
        const name = switch (c.callee.*) {
            .identifier => |n| n,
            else => return null,
        };
        if (self.decls) |d| {
            if (d.funcs.get(name)) |fsig| {
                if (isArbitraryUnion(fsig.return_type_node)) return fsig.return_type_node;
            }
        }
        return null;
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
    /// - no alloc_arg (default) → SMP global singleton
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
    fn isThreadVar(self: *const CodeGen, name: []const u8) bool {
        return self.thread_vars.contains(name);
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
    /// For wrapper allocators (Debug/Arena/Stack), appends .allocator() for the unmanaged API.
    fn resolveCollAllocName(self: *const CodeGen, c: parser.CollExpr) ![]const u8 {
        const arg = c.alloc_arg orelse return try self.allocator.dupe(u8, "std.heap.smp_allocator");
        if (arg.* == .identifier) {
            const name = arg.identifier;
            if (self.allocator_vars.get(name)) |info| {
                if (info.kind != .smp and info.kind != .page) {
                    return try std.fmt.allocPrint(self.allocator, "{s}.allocator()", .{name});
                }
            }
            return try self.allocator.dupe(u8, name);
        }
        return try self.allocator.dupe(u8, "std.heap.smp_allocator");
    }

    /// Check if a variable holds a safe Ptr(T)
    fn isPtrVar(self: *const CodeGen, name: []const u8) bool {
        return self.ptr_vars.contains(name);
    }

    /// Derive Zig format specifier for a Kodr type name.
    /// Returns "d" for integers, "d" for floats, "s" for String, "any" otherwise.
    fn typeToFmtSpec(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, K.Type.STRING)) return "s";
        const int_types = [_][]const u8{
            "i8", "i16", "i32", "i64", "i128",
            "u8", "u16", "u32", "u64", "u128",
            "isize", "usize",
        };
        for (int_types) |t| {
            if (std.mem.eql(u8, name, t)) return "d";
        }
        const float_types = [_][]const u8{ "f16", "f32", "f64", "f128" };
        for (float_types) |t| {
            if (std.mem.eql(u8, name, t)) return "d";
        }
        if (std.mem.eql(u8, name, "bool")) return "any";
        return "any";
    }

    /// Build Zig format specifiers string from Format constructor args.
    /// Format(i32, String) → "ds" (d for i32, s for String)
    fn buildFormatSpecs(self: *CodeGen, args: []*parser.Node) ![]const u8 {
        var specs = std.ArrayListUnmanaged(u8){};
        for (args) |arg| {
            if (arg.* == .type_named or arg.* == .identifier) {
                const name = if (arg.* == .type_named) arg.type_named else arg.identifier;
                const spec = typeToFmtSpec(name);
                try specs.appendSlice(self.allocator, spec);
            } else {
                try specs.appendSlice(self.allocator, "any");
            }
        }
        return specs.toOwnedSlice(self.allocator);
    }

    /// Detect and track Format constructor: const fmt = Format(i32, String, optionalAlloc)
    /// Type args are identifiers/type_named nodes. Last arg may be an allocator.
    /// Returns non-null if this was a Format declaration (tracked, no Zig output needed).
    fn tryTrackFormat(self: *CodeGen, v: parser.VarDecl) ?void {
        if (v.value.* != .call_expr) return null;
        const c = v.value.call_expr;
        if (c.callee.* != .identifier) return null;
        if (!std.mem.eql(u8, c.callee.identifier, "Format")) return null;
        if (c.args.len < 1) return null;

        // Check if last arg is an allocator (named variable in allocator_vars)
        var type_arg_count = c.args.len;
        var alloc_expr: []const u8 = self.allocator.dupe(u8, "std.heap.smp_allocator") catch return null;
        if (c.args.len > 0) {
            const last = c.args[c.args.len - 1];
            if (last.* == .identifier and self.allocator_vars.contains(last.identifier)) {
                type_arg_count -= 1;
                self.allocator.free(alloc_expr);
                const info = self.allocator_vars.get(last.identifier).?;
                alloc_expr = if (info.kind != .smp and info.kind != .page)
                    std.fmt.allocPrint(self.allocator, "{s}.allocator()", .{last.identifier}) catch return null
                else
                    self.allocator.dupe(u8, last.identifier) catch return null;
            }
        }

        // All args up to type_arg_count are type names
        const specs = self.buildFormatSpecs(c.args[0..type_arg_count]) catch {
            self.allocator.free(alloc_expr);
            return null;
        };

        self.format_vars.put(self.allocator, v.name, .{
            .alloc_expr = alloc_expr,
            .type_specs = specs,
        }) catch {
            self.allocator.free(alloc_expr);
            self.allocator.free(specs);
            return null;
        };

        return {};
    }

    /// Check if a variable holds a String value
    fn isStringVar(self: *const CodeGen, name: []const u8) bool {
        return self.string_vars.contains(name);
    }

    /// Check if a type annotation is String
    fn isStringType(type_ann: ?*parser.Node) bool {
        const t = type_ann orelse return false;
        return t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.STRING);
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

    /// Wrap a value for an arbitrary union: 42 → .{ ._i32 = 42 }
    /// Infers the tag from the value's literal type or from the union member types.
    fn generateArbUnionWrappedExpr(self: *CodeGen, value: *parser.Node, type_ann: *parser.Node) anyerror!void {
        // Determine which union member this value matches
        const tag = self.inferArbUnionTag(value, type_ann);
        if (tag) |t| {
            try self.writeFmt(".{{ ._{s} = ", .{t});
            try self.generateExpr(value);
            try self.write(" }");
        } else {
            // Can't infer tag — emit raw value, let Zig figure it out
            try self.generateExpr(value);
        }
    }

    /// Infer which union tag a value belongs to based on its literal type.
    /// Uses the union's type annotation to find the actual member name instead of
    /// hardcoding defaults (e.g. int_literal in `(i64 | String)` → "i64", not "i32").
    fn inferArbUnionTag(_: *const CodeGen, value: *parser.Node, type_ann: *parser.Node) ?[]const u8 {
        if (type_ann.* != .type_union) return null;
        const members = type_ann.type_union;

        return switch (value.*) {
            .int_literal => findMemberByKind(members, .int) orelse "i32",
            .float_literal => findMemberByKind(members, .float) orelse "f32",
            .string_literal => findMemberByKind(members, .string) orelse "String",
            .bool_literal => findMemberByKind(members, .bool_) orelse "bool",
            else => null,
        };
    }

    const TypeKind = enum { int, float, string, bool_ };

    /// Search union members for a type matching the given kind.
    fn findMemberByKind(members: []*parser.Node, kind: TypeKind) ?[]const u8 {
        for (members) |m| {
            if (m.* != .type_named) continue;
            const name = m.type_named;
            switch (kind) {
                .int => {
                    if (std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or
                        std.mem.eql(u8, name, "i32") or std.mem.eql(u8, name, "i64") or
                        std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "u16") or
                        std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or
                        std.mem.eql(u8, name, "usize")) return name;
                },
                .float => {
                    if (std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64")) return name;
                },
                .string => {
                    if (std.mem.eql(u8, name, "String")) return name;
                },
                .bool_ => {
                    if (std.mem.eql(u8, name, "bool")) return name;
                },
            }
        }
        return null;
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

        // std::mem is a built-in compiler module — no Zig import needed,
        // allocator types map directly to std.heap.* which is always available.
        if (imp.scope) |sc| {
            if (std.mem.eql(u8, sc, "std") and std.mem.eql(u8, imp.path, K.Module.MEM)) return;
        }

        // Alias defaults to the module name (last segment of path)
        const alias = imp.alias orelse imp.path;

        if (imp.is_c_header) {
            try self.writeLineFmt("// WARNING: C header import\nconst {s} = @cImport(@cInclude({s}));", .{ alias, imp.path });
        } else {
            // Check if the imported module is a lib target — if so, use build-system
            // module name (no .zig extension) since it's provided via addImport in build.zig
            const is_lib = if (self.module_builds) |mb| blk: {
                const bt = mb.get(imp.path) orelse break :blk false;
                break :blk bt == .static or bt == .dynamic;
            } else false;

            if (is_lib) {
                try self.writeLineFmt("const {s} = @import(\"{s}\");", .{ alias, imp.path });
            } else {
                try self.writeLineFmt("const {s} = @import(\"{s}.zig\");", .{ alias, imp.path });
            }
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
            .thread_block => |t| try collectAssigned(t.body, set, alloc),
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

    /// Emit a re-export for an extern declaration from the paired sidecar .zig file.
    fn generateExternReExport(self: *CodeGen, name: []const u8) anyerror!void {
        try self.writeLineFmt("pub const {s} = @import(\"{s}_extern.zig\").{s};", .{ name, self.module_name, name });
    }

    fn generateFunc(self: *CodeGen, f: parser.FuncDecl) anyerror!void {
        // extern func — re-export from paired sidecar file
        if (f.is_extern) return self.generateExternReExport(f.name);

        // Track if this function returns an error, null, or arbitrary union
        const prev_error = self.in_error_union_func;
        const prev_null = self.in_null_union_func;
        const prev_arb = self.in_arb_union_func;
        const prev_arb_return = self.arb_union_return_type;
        // Clear per-function tracking maps — each function has its own scope
        const prev_null_vars = self.null_vars;
        const prev_arb_union_vars = self.arb_union_vars;
        const prev_rawptr_vars = self.rawptr_vars;
        const prev_ptr_vars = self.ptr_vars;
        const prev_list_vars = self.list_vars;
        const prev_map_vars = self.map_vars;
        const prev_set_vars = self.set_vars;
        const prev_allocator_vars = self.allocator_vars;
        const prev_heap_single_vars = self.heap_single_vars;
        const prev_assigned_vars = self.assigned_vars;
        const prev_string_vars = self.string_vars;
        const prev_format_vars = self.format_vars;
        const prev_thread_vars = self.thread_vars;
        self.null_vars = .{};
        self.arb_union_vars = .{};
        self.rawptr_vars = .{};
        self.ptr_vars = .{};
        self.list_vars = .{};
        self.map_vars = .{};
        self.set_vars = .{};
        self.allocator_vars = .{};
        self.heap_single_vars = .{};
        self.assigned_vars = .{};
        self.string_vars = .{};
        self.format_vars = .{};
        self.thread_vars = .{};
        self.in_error_union_func = false;
        self.in_null_union_func = false;
        self.in_arb_union_func = false;
        self.arb_union_return_type = null;
        try collectAssigned(f.body, &self.assigned_vars, self.allocator);
        if (f.return_type.* == .type_union) {
            for (f.return_type.type_union) |t| {
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) self.in_error_union_func = true;
                if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) self.in_null_union_func = true;
            }
            if (isArbitraryUnion(f.return_type)) {
                self.in_arb_union_func = true;
                self.arb_union_return_type = f.return_type;
            }
        }
        defer {
            self.in_error_union_func = prev_error;
            self.in_null_union_func = prev_null;
            self.in_arb_union_func = prev_arb;
            self.arb_union_return_type = prev_arb_return;
            self.null_vars.deinit(self.allocator);
            self.null_vars = prev_null_vars;
            self.arb_union_vars.deinit(self.allocator);
            self.arb_union_vars = prev_arb_union_vars;
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
            self.string_vars.deinit(self.allocator);
            self.string_vars = prev_string_vars;
            {
                var _fi = self.format_vars.valueIterator();
                while (_fi.next()) |v| { self.allocator.free(v.alloc_expr); self.allocator.free(v.type_specs); }
            }
            self.format_vars.deinit(self.allocator);
            self.format_vars = prev_format_vars;
            { var _ti = self.thread_vars.valueIterator(); while (_ti.next()) |v| self.allocator.free(v.result_type); }
            self.thread_vars.deinit(self.allocator);
            self.thread_vars = prev_thread_vars;
        }

        // pub modifier — always pub for main (Zig requires pub fn main for exe entry)
        if (f.is_pub or std.mem.eql(u8, f.name, "main")) try self.write("pub ");

        // compt func + `type` return → generic type fn with `comptime T: type` params
        // compt func + other return  → inline fn with `anytype` params
        // regular func               → fn (anytype params handled in loop below)
        const returns_type = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, K.Type.TYPE);
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
                    std.mem.eql(u8, param.param.type_annotation.type_named, K.Type.ANY);
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
                    // Default params handled at call site, not in Zig signature
                }
            }
        }

        // Track String parameters so string methods work on them
        for (f.params) |param| {
            if (param.* == .param and isStringType(param.param.type_annotation))
                try self.string_vars.put(self.allocator, param.param.name, {});
        }

        try self.write(") ");

        // Return type — `any` return becomes @TypeOf(first_any_param)
        const return_is_any = f.return_type.* == .type_named and
            std.mem.eql(u8, f.return_type.type_named, K.Type.ANY);
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
        if (s.is_extern) return self.generateExternReExport(s.name);
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

    /// Detect if a node is a mem.DebugAllocator() / mem.Arena() / mem.Stack(n) / mem.Page() constructor call.
    fn getMemAllocKind(node: *parser.Node) ?AllocKind {
        if (node.* != .call_expr) return null;
        const c = node.call_expr;
        if (c.callee.* != .field_expr) return null;
        const fe = c.callee.field_expr;
        if (fe.object.* != .identifier) return null;
        if (!std.mem.eql(u8, fe.object.identifier, K.Module.MEM)) return null;
        if (std.mem.eql(u8, fe.field, "DebugAllocator")) return .gpa;
        if (std.mem.eql(u8, fe.field, "SMP"))   return .smp;
        if (std.mem.eql(u8, fe.field, "Arena")) return .arena;
        if (std.mem.eql(u8, fe.field, "Stack"))  return .stack;
        if (std.mem.eql(u8, fe.field, "Page"))  return .page;
        if (std.mem.eql(u8, fe.field, "Pool"))  return .pool;
        return null;
    }

    /// Generate allocator initialization statements for: var a = mem.DebugAllocator() etc.
    /// SMP/Page → global singletons (no wrapper).
    /// Debug/Arena/Stack → KodrMem wrapper types (methods pass through to Zig).
    /// NOTE: generateBlock already called writeIndent() before this statement, so the
    /// first line must NOT call writeIndent(); subsequent lines must.
    fn generateAllocatorInit(self: *CodeGen, name: []const u8, kind: AllocKind, args: []*parser.Node) anyerror!void {
        switch (kind) {
            .smp => {
                try self.writeFmt("const {s} = std.heap.smp_allocator;", .{name});
                try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = "" });
                return;
            },
            .page => {
                try self.writeFmt("const {s} = std.heap.page_allocator;", .{name});
                try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = "" });
                return;
            },
            .gpa => {
                self.uses_mem = true;
                try self.writeFmt("var {s} = KodrMem.DebugAlloc.init();\n", .{name});
                try self.writeIndent(); try self.writeFmt("defer {s}.deinit();", .{name});
            },
            .arena => {
                self.uses_mem = true;
                try self.writeFmt("var {s} = KodrMem.ArenaAlloc.init();\n", .{name});
                try self.writeIndent(); try self.writeFmt("defer {s}.deinit();", .{name});
            },
            .stack => {
                self.uses_mem = true;
                if (args.len < 1) {
                    try self.reporter.report(.{ .message = "mem.Stack requires a size argument" });
                    return error.CompileError;
                }
                try self.writeFmt("var _{s}_buf: [", .{name});
                try self.generateExpr(args[0]);
                try self.write("]u8 = undefined;\n");
                try self.writeIndent(); try self.writeFmt("var {s} = KodrMem.StackAlloc.init(&_{s}_buf);", .{ name, name });
            },
            .pool => {
                // Pool uses std.heap.MemoryPool directly — no KodrMem wrapper needed
                if (args.len < 1) {
                    try self.reporter.report(.{ .message = "mem.Pool requires a type argument" });
                    return error.CompileError;
                }
                // mem.Pool(T) → std.heap.MemoryPoolAligned(T, null)
                try self.writeFmt("var {s} = std.heap.MemoryPool(", .{name});
                try self.generateExpr(args[0]);
                try self.write(").init(std.heap.smp_allocator);\n");
                try self.writeIndent(); try self.writeFmt("defer {s}.deinit();", .{name});
            },
        }
        try self.allocator_vars.put(self.allocator, name, .{ .kind = kind, .impl_name = try self.allocator.dupe(u8, name) });
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
        } else if (std.mem.eql(u8, method, "create")) {
            // pool.create() — get an object from the pool
            if (info.kind != .pool) {
                try self.reporter.report(.{ .message = "create is only available on mem.Pool(T)" });
                return error.CompileError;
            }
            try self.writeFmt("{s}.create() catch @panic(\"pool exhausted\")", .{alloc_name});
        } else if (std.mem.eql(u8, method, "destroy")) {
            // pool.destroy(ptr) — return an object to the pool
            if (info.kind != .pool) {
                try self.reporter.report(.{ .message = "destroy is only available on mem.Pool(T)" });
                return error.CompileError;
            }
            if (args.len < 1) {
                try self.reporter.report(.{ .message = "destroy requires one argument" });
                return error.CompileError;
            }
            try self.writeFmt("{s}.destroy(", .{alloc_name});
            try self.generateExpr(args[0]);
            try self.write(")");
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
        if (v.is_extern) return self.generateExternReExport(v.name);
        return self.generateDecl(v, "const");
    }

    fn generateVar(self: *CodeGen, v: parser.VarDecl) anyerror!void {
        if (v.is_extern) return self.generateExternReExport(v.name);
        return self.generateDecl(v, "var");
    }

    /// Shared codegen for var and const declarations
    fn generateDecl(self: *CodeGen, v: parser.VarDecl, kw: []const u8) anyerror!void {
        // Format constructor: const fmt = Format((i32, String)) → tracked, no Zig output
        if (self.tryTrackFormat(v)) |_| {
            try self.write("// format instance");
            return;
        }
        // Owned collection: List(T) / List(T, mem.DebugAllocator()) etc. — multi-statement expansion
        if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
            return self.generateOwnedCollDecl(kw, v.name, v.type_annotation, v.value.coll_expr);
        // mem.DebugAllocator() / mem.Arena() / mem.Stack(n) / mem.Page() — multi-statement expansion
        if (getMemAllocKind(v.value)) |kind| {
            return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
        }
        // a.allocOne(T, val) — heap single value, expands to create + init
        if (self.getAllocOneCall(v.value)) |ac| {
            return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
        }
        if (v.is_pub) try self.write("pub ");
        try self.writeFmt("{s} {s}", .{ kw, v.name });
        const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
        const is_arb_union = if (v.type_annotation) |t| isArbitraryUnion(t) else false;
        if (v.type_annotation) |t| {
            try self.writeFmt(": {s}", .{try self.typeToZig(t)});
        }
        try self.write(" = ");
        if (is_null_union) {
            try self.null_vars.put(self.allocator, v.name, {});
            try self.generateNullWrappedExpr(v.value);
        } else if (is_arb_union) {
            try self.arb_union_vars.put(self.allocator, v.name, v.type_annotation.?);
            try self.generateArbUnionWrappedExpr(v.value, v.type_annotation.?);
        } else {
            if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
            if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
            if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (v.type_annotation) |t| {
                if (t.* == .type_named and self.isBitfieldType(t.type_named))
                    try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
            }
            if (isStringType(v.type_annotation) or v.value.* == .string_literal)
                try self.string_vars.put(self.allocator, v.name, {});
            // Infer arb union from function call return type (no explicit annotation)
            if (v.type_annotation == null) {
                if (self.callReturnsArbUnion(v.value)) |rt|
                    try self.arb_union_vars.put(self.allocator, v.name, rt);
            }
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
    }

    /// Shared codegen for var/const declarations inside function blocks.
    /// Handles type tracking, null unions, and type_ctx for overflow codegen.
    fn generateStmtDecl(self: *CodeGen, v: parser.VarDecl, kw: []const u8) anyerror!void {
        // Format constructor: const fmt = Format((i32, String)) → tracked, no Zig output
        if (self.tryTrackFormat(v)) |_| {
            try self.write("// format instance");
            return;
        }
        const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
        const is_arb_union = if (v.type_annotation) |t| isArbitraryUnion(t) else false;
        try self.writeFmt("{s} {s}", .{ kw, v.name });
        if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
        try self.write(" = ");
        if (is_null_union) {
            try self.null_vars.put(self.allocator, v.name, {});
            try self.generateNullWrappedExpr(v.value);
        } else if (is_arb_union) {
            try self.arb_union_vars.put(self.allocator, v.name, v.type_annotation.?);
            try self.generateArbUnionWrappedExpr(v.value, v.type_annotation.?);
        } else {
            if (isPtrExpr(v.value)) try self.rawptr_vars.put(self.allocator, v.name, {});
            if (isSafePtrExpr(v.value)) try self.ptr_vars.put(self.allocator, v.name, {});
            if (isCollExpr(v.value, "List")) try self.list_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (isCollExpr(v.value, "Map")) try self.map_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (isCollExpr(v.value, "Set")) try self.set_vars.put(self.allocator, v.name, try self.resolveCollAllocName(v.value.coll_expr));
            if (v.type_annotation) |t| {
                if (t.* == .type_named and self.isBitfieldType(t.type_named))
                    try self.bitfield_vars.put(self.allocator, v.name, try self.allocator.dupe(u8, t.type_named));
            }
            if (isStringType(v.type_annotation) or v.value.* == .string_literal)
                try self.string_vars.put(self.allocator, v.name, {});
            // Infer arb union from function call return type (no explicit annotation)
            if (v.type_annotation == null) {
                if (self.callReturnsArbUnion(v.value)) |rt|
                    try self.arb_union_vars.put(self.allocator, v.name, rt);
            }
            const prev_ctx = self.type_ctx;
            self.type_ctx = v.type_annotation;
            try self.generateExpr(v.value);
            self.type_ctx = prev_ctx;
        }
        try self.write(";");
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

    /// Generate: const x = a.allocOne(T, val);
    /// For wrapper allocators, the method handles create+init.
    /// For raw allocators (SMP/Page), uses create + manual init.
    /// Tracks x in heap_single_vars so identifier access emits x.* and free uses destroy().
    fn generateAllocOneDecl(self: *CodeGen, name: []const u8, alloc_name: []const u8, type_arg: *parser.Node, val_arg: *parser.Node) anyerror!void {
        const is_wrapper = if (self.allocator_vars.get(alloc_name)) |info|
            info.kind != .smp and info.kind != .page
        else
            false;
        if (is_wrapper) {
            // Wrapper type — call allocOne method directly
            try self.writeFmt("const {s} = {s}.allocOne(", .{ name, alloc_name });
            try self.generateExpr(type_arg);
            try self.write(", ");
            try self.generateExpr(val_arg);
            try self.write(");");
        } else {
            // Raw std.mem.Allocator — manual create + init
            try self.writeFmt("const {s} = {s}.create(", .{ name, alloc_name });
            try self.generateExpr(type_arg);
            try self.write(") catch @panic(\"out of memory\");\n");
            try self.writeIndent(); try self.writeFmt("{s}.* = ", .{name});
            try self.generateExpr(val_arg);
            try self.write(";");
        }
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
                if (getMemAllocKind(v.value)) |kind|
                    return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
                if (self.getAllocOneCall(v.value)) |ac|
                    return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
                // var → const promotion: warn if never reassigned
                const is_mutated = self.assigned_vars.contains(v.name);
                const kw: []const u8 = if (is_mutated) "var" else "const";
                if (!is_mutated) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "'{s}' is declared as var but never reassigned — use const", .{v.name});
                    defer self.allocator.free(msg);
                    try self.reporter.warn(.{ .message = msg, .loc = self.nodeLoc(node) });
                }
                try self.generateStmtDecl(v, kw);
            },
            .const_decl => |v| {
                if (v.value.* == .coll_expr and isOwnedColl(v.value.coll_expr))
                    return self.generateOwnedCollDecl("const", v.name, v.type_annotation, v.value.coll_expr);
                if (getMemAllocKind(v.value)) |kind|
                    return self.generateAllocatorInit(v.name, kind, v.value.call_expr.args);
                if (self.getAllocOneCall(v.value)) |ac|
                    return self.generateAllocOneDecl(v.name, ac.alloc_name, ac.type_arg, ac.val_arg);
                try self.generateStmtDecl(v, "const");
            },
            .destruct_decl => |d| {
                // String split destructuring:
                // var before, after = s.split(",")
                if (d.names.len == 2 and d.value.* == .call_expr) {
                    const c = d.value.call_expr;
                    if (c.callee.* == .field_expr) {
                        const fe = c.callee.field_expr;
                        if (std.mem.eql(u8, fe.field, "split") and
                            fe.object.* == .identifier and self.isStringVar(fe.object.identifier))
                        {
                            const si = self.destruct_counter;
                            self.destruct_counter += 1;
                            const kw = if (d.is_const) "const" else "var";
                            // const _kodr_sp0_delim = <arg>;
                            try self.writeFmt("const _kodr_sp{d}_delim = ", .{si});
                            if (c.args.len > 0) try self.generateExpr(c.args[0]);
                            try self.write(";\n");
                            try self.writeIndent();
                            // const _kodr_sp0_pos = std.mem.indexOf(u8, s, delim);
                            try self.writeFmt("const _kodr_sp{d}_pos = std.mem.indexOf(u8, ", .{si});
                            try self.generateExpr(fe.object);
                            try self.writeFmt(", _kodr_sp{d}_delim);\n", .{si});
                            try self.writeIndent();
                            // const before = if (pos) |_idx| s[0.._idx] else s;
                            try self.writeFmt("{s} {s} = if (_kodr_sp{d}_pos) |_idx| ", .{ kw, d.names[0], si });
                            try self.generateExpr(fe.object);
                            try self.write("[0.._idx] else ");
                            try self.generateExpr(fe.object);
                            try self.write(";\n");
                            try self.writeIndent();
                            // const after = if (pos) |_idx| s[_idx + delim.len..] else "";
                            try self.writeFmt("{s} {s} = if (_kodr_sp{d}_pos) |_idx| ", .{ kw, d.names[1], si });
                            try self.generateExpr(fe.object);
                            try self.writeFmt("[_idx + _kodr_sp{d}_delim.len..] else \"\";", .{si});
                            // Track result vars as strings
                            try self.string_vars.put(self.allocator, d.names[0], {});
                            try self.string_vars.put(self.allocator, d.names[1], {});
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
                            const kw = if (d.is_const) "const" else "var";
                            const si = self.destruct_counter;
                            self.destruct_counter += 1;
                            // Force runtime index so Zig returns a slice, not a pointer-to-array
                            try self.writeFmt("var _kodr_s{d}: usize = @intCast(", .{si});
                            try self.generateExpr(c.args[0]);
                            try self.write(");\n");
                            try self.writeIndent();
                            try self.writeFmt("_ = &_kodr_s{d};\n", .{si});
                            try self.writeIndent();
                            try self.writeFmt("{s} {s} = ", .{ kw, d.names[0] });
                            if (fe.object.* == .identifier and self.isListVar(fe.object.identifier)) {
                                try self.generateExpr(fe.object);
                                try self.write(".items");
                            } else {
                                try self.generateExpr(fe.object);
                            }
                            try self.writeFmt("[0.._kodr_s{d}];\n", .{si});
                            try self.writeIndent();
                            try self.writeFmt("{s} {s} = ", .{ kw, d.names[1] });
                            if (fe.object.* == .identifier and self.isListVar(fe.object.identifier)) {
                                try self.generateExpr(fe.object);
                                try self.write(".items");
                            } else {
                                try self.generateExpr(fe.object);
                            }
                            try self.writeFmt("[_kodr_s{d}..];", .{si});
                            return;
                        }
                    }
                }
                // Normal tuple destructuring:
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
                if (self.in_thread_block) {
                    // Thread body: return expr → _kodr_rp.* = expr; return;
                    if (r.value) |v| {
                        try self.write("_kodr_rp.* = ");
                        try self.generateExpr(v);
                        try self.write("; return;");
                    } else {
                        try self.write("return;");
                    }
                } else {
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
                    } else if (self.in_arb_union_func) {
                        if (self.arb_union_return_type) |rt| {
                            try self.generateArbUnionWrappedExpr(v, rt);
                        } else {
                            try self.generateExpr(v);
                        }
                    } else {
                        try self.generateExpr(v);
                    }
                }
                try self.write(";");
                } // end else (not in_thread_block)
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
                const is_range = f.iterable.* == .range_expr;
                const iter_name = if (f.iterable.* == .identifier) f.iterable.identifier else null;
                const is_map = if (iter_name) |n| self.isMapVar(n) else false;
                const is_set = if (iter_name) |n| self.isSetVar(n) else false;
                const is_list = if (iter_name) |n| self.isListVar(n) else false;

                if (is_map or is_set) {
                    // Map/Set → Zig iterator while-loop
                    try self.generateMapSetFor(f, iter_name.?, is_map);
                } else {
                    // Array, slice, list, or range → Zig for
                    const needs_cast = is_range or f.index_var != null;
                    if (f.is_compt) try self.write("inline ");
                    try self.write("for (");
                    if (is_range) {
                        try self.writeRangeExpr(f.iterable.range_expr);
                    } else if (is_list) {
                        try self.writeFmt("{s}.items", .{iter_name.?});
                    } else {
                        try self.generateExpr(f.iterable);
                    }
                    // Inject 0.. counter when index variable is requested
                    if (f.index_var != null) try self.write(", 0..");
                    try self.write(") |");
                    if (is_range) {
                        // Range produces usize — rename and cast to i32
                        try self.writeFmt("_kodr_{s}", .{f.captures[0]});
                    } else {
                        try self.write(f.captures[0]);
                    }
                    if (f.index_var) |idx| {
                        // Index from 0.. is usize — rename and cast to i32
                        try self.writeFmt(", _kodr_{s}", .{idx});
                    }
                    if (needs_cast) {
                        try self.write("| {\n");
                        self.indent += 1;
                        if (is_range) {
                            try self.writeIndent();
                            try self.writeFmt("const {s}: i32 = @intCast(_kodr_{s});\n", .{ f.captures[0], f.captures[0] });
                        }
                        if (f.index_var) |idx| {
                            try self.writeIndent();
                            try self.writeFmt("const {s}: i32 = @intCast(_kodr_{s});\n", .{ idx, idx });
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

                // Type match — any arm is `Error`, `null`, or value is an arbitrary union
                // match result { Error => { } i32 => { } }
                // match user   { null  => { } User => { } }
                // match val    { i32   => { } f32  => { } }
                const is_type_match = blk: {
                    // Check if the match value is an arbitrary union variable
                    if (m.value.* == .identifier and self.isArbUnionVar(m.value.identifier))
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
                } else if (std.mem.eql(u8, a.op, "=") and
                    a.left.* == .identifier and self.arb_union_vars.get(a.left.identifier) != null)
                {
                    // Assignment to arb union var → wrap value
                    const type_node = self.arb_union_vars.get(a.left.identifier).?;
                    try self.generateExpr(a.left);
                    try self.write(" = ");
                    try self.generateArbUnionWrappedExpr(a.right, type_node);
                    try self.write(";");
                } else {
                    try self.generateExpr(a.left);
                    try self.writeFmt(" {s} ", .{a.op});
                    try self.generateExpr(a.right);
                    try self.write(";");
                }
            },
            .thread_block => |t| {
                try self.generateThreadBlock(t);
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
                if (self.in_thread_block) {
                    if (self.thread_capture_renames.get(name)) |renamed| {
                        try self.write(renamed);
                        return;
                    }
                }
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
                    std.mem.eql(u8, b.left.compiler_func.name, K.Type.TYPE) and
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
                        if (std.mem.eql(u8, rhs, K.Type.ERROR)) {
                            try self.write("(");
                            try self.generateExpr(val_node);
                            try self.writeFmt(" {s} .err)", .{cmp});
                            return;
                        }
                        // Arbitrary union type check: `val is i32` → `val == ._i32`
                        if (val_node.* == .identifier and self.isArbUnionVar(val_node.identifier)) {
                            try self.write("(");
                            try self.generateExpr(val_node);
                            try self.writeFmt(" {s} ._{s})", .{ cmp, rhs });
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
                        if (self.isThreadVar(obj)) {
                            try self.generateThreadMethod(obj, fe.field);
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
                // Allocator method calls: wrapper methods pass through to Zig.
                // SMP/Page (std.mem.Allocator) still need explicit dispatch.
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .identifier) {
                        if (self.allocator_vars.get(fe.object.identifier)) |info| {
                            // SMP/Page are raw std.mem.Allocator — need manual dispatch
                            if (info.kind == .smp or info.kind == .page) {
                                try self.generateAllocatorMethod(fe.object.identifier, info, fe.field, c.args);
                                return;
                            }
                            // Wrapper types (Debug/Arena/Stack) — methods mostly pass through.
                            // Exception: free() with heap single vars needs raw pointer (no auto-deref).
                            if (std.mem.eql(u8, fe.field, "free") and c.args.len > 0 and
                                c.args[0].* == .identifier and self.heap_single_vars.contains(c.args[0].identifier))
                            {
                                try self.writeFmt("{s}.free({s})", .{ fe.object.identifier, c.args[0].identifier });
                                return;
                            }
                            // (fall through to generic call handler for other methods)
                        }
                    }
                }
                // String method calls: s.contains(), s.trim(), s.indexOf() etc.
                // Works on tracked string variables AND string literals directly
                if (c.callee.* == .field_expr) {
                    const fe = c.callee.field_expr;
                    if (fe.object.* == .string_literal or
                        (fe.object.* == .identifier and self.isStringVar(fe.object.identifier)))
                    {
                        try self.generateStringMethod(fe.object, fe.field, c.args);
                        return;
                    }
                }
                // Format call: fmt("template {}", args) → std.fmt.allocPrint(alloc, "template {d}", .{args})
                if (c.callee.* == .identifier and self.format_vars.contains(c.callee.identifier)) {
                    const info = self.format_vars.get(c.callee.identifier).?;
                    try self.writeFmt("std.fmt.allocPrint({s}, ", .{info.alloc_expr});
                    // First arg is the template — replace {} with type-specific specifiers
                    if (c.args.len > 0 and c.args[0].* == .string_literal) {
                        const raw = c.args[0].string_literal;
                        try self.write("\"");
                        var spec_idx: usize = 0;
                        var i: usize = 1; // skip opening quote
                        while (i < raw.len - 1) : (i += 1) { // skip closing quote
                            if (i + 1 < raw.len - 1 and raw[i] == '{' and raw[i + 1] == '}') {
                                // Replace {} with the correct specifier
                                if (spec_idx < info.type_specs.len) {
                                    const end = spec_idx + 1;
                                    // Specifiers can be multi-char (e.g. "any")
                                    var spec_end = spec_idx;
                                    // Single char specs: d, s. Multi-char: any
                                    if (spec_idx < info.type_specs.len and info.type_specs[spec_idx] == 'a') {
                                        // "any" specifier
                                        try self.write("{any}");
                                        spec_end = spec_idx + 3; // skip "any"
                                    } else {
                                        try self.write("{");
                                        try self.write(info.type_specs[spec_idx..end]);
                                        try self.write("}");
                                        spec_end = end;
                                    }
                                    spec_idx = spec_end;
                                } else {
                                    try self.write("{any}");
                                }
                                i += 1; // skip the }
                            } else {
                                try self.output.append(self.allocator, raw[i]);
                            }
                        }
                        try self.write("\"");
                    } else if (c.args.len > 0) {
                        try self.generateExpr(c.args[0]);
                    }
                    // Pack remaining args into a Zig tuple
                    try self.write(", .{");
                    var ai: usize = 1;
                    while (ai < c.args.len) : (ai += 1) {
                        if (ai > 1) try self.write(", ");
                        try self.generateExpr(c.args[ai]);
                    }
                    try self.write("}) catch \"\"");
                    return;
                }
                // Format constructor: Format((i32, String)) → tracked, no Zig output
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "Format")) {
                    // Handled at declaration level — emit a no-op
                    try self.write("{}");
                    return;
                }
                // File/Dir constructor: File("path") → KodrFs.File{ .path = "path", .alloc = smp }
                if (c.callee.* == .identifier and
                    (std.mem.eql(u8, c.callee.identifier, K.Type.FILE) or std.mem.eql(u8, c.callee.identifier, K.Type.DIR)))
                {
                    self.uses_fs = true;
                    const zig_type = if (std.mem.eql(u8, c.callee.identifier, K.Type.FILE)) "KodrFs.File" else "KodrFs.Dir";
                    try self.writeFmt("{s}{{ .path = ", .{zig_type});
                    if (c.args.len > 0) try self.generateExpr(c.args[0]);
                    try self.write(", .alloc = ");
                    if (c.args.len > 1) {
                        // Shared allocator: File("path", myAlloc)
                        try self.generateExpr(c.args[1]);
                    } else {
                        // Default allocator
                        try self.write("std.heap.smp_allocator");
                    }
                    try self.write(" }");
                    return;
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
                    // Fill in default args if caller passed fewer than the function expects
                    try self.fillDefaultArgs(c);
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
                } else if (std.mem.eql(u8, f.field, K.Type.ERROR)) {
                    try self.generateExpr(f.object);
                    try self.write(".err");
                } else if (f.object.* == .identifier and self.isArbUnionVar(f.object.identifier) and
                    isResultValueField(f.field, self.decls))
                {
                    // Arbitrary union field access: result.i32 → result._i32
                    try self.generateExpr(f.object);
                    try self.writeFmt("._{s}", .{f.field});
                } else if (isResultValueField(f.field, self.decls)) {
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
                } else if (f.object.* == .identifier and self.isThreadVar(f.object.identifier)) {
                    // Thread field access
                    const tname = f.object.identifier;
                    if (std.mem.eql(u8, f.field, "value")) {
                        // worker.value → join + unwrap result (generates a block expression)
                        try self.writeFmt("blk: {{ _kodr_{s}_handle.join(); break :blk _kodr_{s}_result.?; }}", .{ tname, tname });
                    } else if (std.mem.eql(u8, f.field, "finished")) {
                        // worker.finished → result != null
                        try self.writeFmt("(_kodr_{s}_result != null)", .{tname});
                    } else {
                        try self.generateExpr(f.object);
                        try self.writeFmt(".{s}", .{f.field});
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
        const right_is_literal = r.right.* == .int_literal;
        if (right_is_literal) {
            try self.generateExpr(r.right);
        } else {
            try self.write("@intCast(");
            try self.generateExpr(r.right);
            try self.write(")");
        }
    }

    /// Generate a while-loop for Map/Set iteration.
    /// Map: for(m) |(key, value)| → var _it = m.iterator(); while (_it.next()) |entry| { const key = entry.key_ptr.*; ... }
    /// Set: for(s) |key| → var _it = s.iterator(); while (_it.next()) |entry| { const key = entry.key_ptr.*; ... }
    fn generateMapSetFor(self: *CodeGen, f: parser.ForStmt, name: []const u8, is_map: bool) anyerror!void {
        // var _kodr_it = name.iterator();
        try self.write("{\n");
        self.indent += 1;
        try self.writeIndent();
        try self.writeFmt("var _kodr_it = {s}.iterator();\n", .{name});
        // Optional index counter
        if (f.index_var) |_| {
            try self.writeIndent();
            try self.write("var _kodr_idx: usize = 0;\n");
        }
        try self.writeIndent();
        try self.write("while (_kodr_it.next()) |_kodr_entry| {\n");
        self.indent += 1;
        // Extract key
        try self.writeIndent();
        try self.writeFmt("const {s} = _kodr_entry.key_ptr.*;\n", .{f.captures[0]});
        // Extract value for Map
        if (is_map and f.captures.len > 1) {
            try self.writeIndent();
            try self.writeFmt("const {s} = _kodr_entry.value_ptr.*;\n", .{f.captures[1]});
        }
        // Extract index
        if (f.index_var) |idx| {
            try self.writeIndent();
            try self.writeFmt("const {s}: i32 = @intCast(_kodr_idx);\n", .{idx});
        }
        // Body statements
        for (f.body.block.statements) |stmt| {
            try self.writeIndent();
            try self.generateStatement(stmt);
            try self.write("\n");
        }
        // Increment index counter
        if (f.index_var) |_| {
            try self.writeIndent();
            try self.write("_kodr_idx += 1;\n");
        }
        self.indent -= 1;
        try self.writeIndent();
        try self.write("}\n");
        self.indent -= 1;
        try self.writeIndent();
        try self.write("}");
    }

    /// Generate Zig code for Thread(T) name { body }
    /// Emits: result var, cancel flag, std.Thread.spawn with captures
    fn generateThreadBlock(self: *CodeGen, t: parser.ConcurrencyBlock) anyerror!void {
        const name = t.name;
        const result_type = try self.typeToZig(t.result_type);
        const result_type_dupe = try self.allocator.dupe(u8, result_type);

        // Track this thread variable
        try self.thread_vars.put(self.allocator, name, .{ .result_type = result_type_dupe });

        // Collect captured variables from body
        var captures = std.StringHashMap(void).init(self.allocator);
        defer captures.deinit();
        try collectCapturedVars(t.body, &captures);

        // Remove locally declared variables — they are not captures
        var local_decls = std.StringHashMap(void).init(self.allocator);
        defer local_decls.deinit();
        try collectLocalDecls(t.body, &local_decls);
        var decl_it = local_decls.iterator();
        while (decl_it.next()) |entry| _ = captures.remove(entry.key_ptr.*);

        // Collect capture names into a sorted slice for deterministic output
        var cap_names = std.ArrayListUnmanaged([]const u8){};
        defer cap_names.deinit(self.allocator);
        var cap_it = captures.iterator();
        while (cap_it.next()) |entry| try cap_names.append(self.allocator, entry.key_ptr.*);
        std.mem.sort([]const u8, cap_names.items, {}, struct {
            fn cmp(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.cmp);

        // var _kodr_<name>_result: ?<T> = null;
        try self.writeFmt("var _kodr_{s}_result: ?{s} = null;\n", .{ name, result_type });
        try self.writeIndent();

        // var _kodr_<name>_cancel = std.atomic.Value(bool).init(false);
        try self.writeFmt("var _kodr_{s}_cancel = std.atomic.Value(bool).init(false);\n", .{name});
        try self.writeIndent();

        // const _kodr_<name>_handle = std.Thread.spawn(.{}, struct { fn run(...) void { ... } }.run, .{...}) catch unreachable;
        try self.writeFmt("const _kodr_{s}_handle = std.Thread.spawn(.{{}}, struct {{\n", .{name});
        self.indent += 1;
        try self.writeIndent();

        // fn run(result_ptr: *?T, _cancel: *std.atomic.Value(bool), _cap_x: @TypeOf(x), ...) void {
        try self.writeFmt("fn run(_kodr_rp: *?{s}, _kodr_cancel: *std.atomic.Value(bool)", .{result_type});
        for (cap_names.items) |cap| {
            try self.writeFmt(", _cap_{s}: @TypeOf({s})", .{ cap, cap });
        }
        try self.write(") void {\n");
        self.indent += 1;

        // _ = _kodr_cancel; (suppress unused warning — available for cooperative cancellation)
        try self.writeIndent();
        try self.write("_ = _kodr_cancel;\n");

        // Generate body statements — transform return into result assignment
        // Set up capture renames so identifiers emit as _cap_name
        const prev_in_thread = self.in_thread_block;
        const prev_thread_name = self.current_thread_name;
        const prev_renames = self.thread_capture_renames;
        self.in_thread_block = true;
        self.current_thread_name = name;
        self.thread_capture_renames = .{};
        for (cap_names.items) |cap| {
            const renamed = try std.fmt.allocPrint(self.allocator, "_cap_{s}", .{cap});
            try self.thread_capture_renames.put(self.allocator, cap, renamed);
        }
        defer {
            var ri = self.thread_capture_renames.valueIterator();
            while (ri.next()) |v| self.allocator.free(v.*);
            self.thread_capture_renames.deinit(self.allocator);
            self.in_thread_block = prev_in_thread;
            self.current_thread_name = prev_thread_name;
            self.thread_capture_renames = prev_renames;
        }

        for (t.body.block.statements) |stmt| {
            try self.writeIndent();
            try self.generateStatement(stmt);
            try self.write("\n");
        }

        self.indent -= 1;
        try self.writeIndent();
        try self.write("}\n");
        self.indent -= 1;
        try self.writeIndent();

        // }.run, .{ &result, &cancel, cap1, cap2, ... }) catch unreachable;
        try self.writeFmt("}}.run, .{{ &_kodr_{s}_result, &_kodr_{s}_cancel", .{ name, name });
        for (cap_names.items) |cap| {
            try self.writeFmt(", {s}", .{cap});
        }
        try self.write(" }) catch unreachable;");
    }

    /// Generate Zig code for thread method calls: worker.wait(), worker.cancel()
    fn generateThreadMethod(self: *CodeGen, name: []const u8, method: []const u8) anyerror!void {
        if (std.mem.eql(u8, method, "wait")) {
            try self.writeFmt("_kodr_{s}_handle.join()", .{name});
        } else if (std.mem.eql(u8, method, "cancel")) {
            try self.writeFmt("_kodr_{s}_cancel.store(true, .seq_cst)", .{name});
        }
    }

    /// Collect all identifiers referenced in a node tree
    fn collectCapturedVars(node: *parser.Node, vars: *std.StringHashMap(void)) anyerror!void {
        switch (node.*) {
            .identifier => |name| try vars.put(name, {}),
            .block => |b| {
                for (b.statements) |stmt| try collectCapturedVars(stmt, vars);
            },
            .binary_expr => |b| {
                try collectCapturedVars(b.left, vars);
                try collectCapturedVars(b.right, vars);
            },
            .call_expr => |c| {
                // Only capture callee if it's a method call (field_expr), not a plain function name
                if (c.callee.* == .field_expr) try collectCapturedVars(c.callee, vars);
                for (c.args) |arg| try collectCapturedVars(arg, vars);
            },
            .return_stmt => |r| {
                if (r.value) |v| try collectCapturedVars(v, vars);
            },
            .var_decl => |v| try collectCapturedVars(v.value, vars),
            .field_expr => |f| try collectCapturedVars(f.object, vars),
            .assignment => |a| {
                try collectCapturedVars(a.left, vars);
                try collectCapturedVars(a.right, vars);
            },
            .if_stmt => |i| {
                try collectCapturedVars(i.condition, vars);
                try collectCapturedVars(i.then_block, vars);
                if (i.else_block) |e| try collectCapturedVars(e, vars);
            },
            .while_stmt => |w| {
                try collectCapturedVars(w.condition, vars);
                try collectCapturedVars(w.body, vars);
            },
            .for_stmt => |f| {
                try collectCapturedVars(f.iterable, vars);
                try collectCapturedVars(f.body, vars);
            },
            .index_expr => |i| {
                try collectCapturedVars(i.object, vars);
                try collectCapturedVars(i.index, vars);
            },
            .unary_expr => |u| try collectCapturedVars(u.operand, vars),
            else => {},
        }
    }

    /// Collect locally declared variable names in a body
    fn collectLocalDecls(node: *parser.Node, decls: *std.StringHashMap(void)) anyerror!void {
        switch (node.*) {
            .block => |b| {
                for (b.statements) |stmt| try collectLocalDecls(stmt, decls);
            },
            .var_decl => |v| try decls.put(v.name, {}),
            .if_stmt => |i| {
                try collectLocalDecls(i.then_block, decls);
                if (i.else_block) |e| try collectLocalDecls(e, decls);
            },
            .while_stmt => |w| try collectLocalDecls(w.body, decls),
            .for_stmt => |f| {
                for (f.captures) |cap| try decls.put(cap, {});
                if (f.index_var) |idx| try decls.put(idx, {});
                try collectLocalDecls(f.body, decls);
            },
            else => {},
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

        try self.write("switch (");
        try self.generateExpr(m.value);
        try self.write(") {\n");
        self.indent += 1;

        for (m.arms) |arm| {
            if (arm.* != .match_arm) continue;
            const pat = arm.match_arm.pattern;
            try self.writeIndent();

            if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, K.Type.ERROR)) {
                // Error arm → .err
                try self.write(".err");
            } else if (pat.* == .null_literal) {
                // null arm → .none
                try self.write(".none");
            } else if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                // catch-all
                try self.write("else");
            } else if (is_arbitrary and pat.* == .identifier) {
                // Arbitrary union arm: i32 → ._i32
                try self.writeFmt("._{s}", .{pat.identifier});
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

    /// Generate string method calls — non-allocating operations on []const u8
    fn generateStringMethod(self: *CodeGen, obj: *parser.Node, method: []const u8, args: []*parser.Node) anyerror!void {
        if (std.mem.eql(u8, method, "contains")) {
            // s.contains(substr) → (std.mem.indexOf(u8, s, substr) != null)
            try self.write("(std.mem.indexOf(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(") != null)");
        } else if (std.mem.eql(u8, method, "startsWith")) {
            try self.write("std.mem.startsWith(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "endsWith")) {
            try self.write("std.mem.endsWith(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");
        } else if (std.mem.eql(u8, method, "trim")) {
            try self.write("std.mem.trim(u8, ");
            try self.generateExpr(obj);
            try self.write(", \" \\t\\n\\r\")");
        } else if (std.mem.eql(u8, method, "trimLeft")) {
            try self.write("std.mem.trimLeft(u8, ");
            try self.generateExpr(obj);
            try self.write(", \" \\t\\n\\r\")");
        } else if (std.mem.eql(u8, method, "trimRight")) {
            try self.write("std.mem.trimRight(u8, ");
            try self.generateExpr(obj);
            try self.write(", \" \\t\\n\\r\")");
        } else if (std.mem.eql(u8, method, "indexOf")) {
            // s.indexOf(substr) → KodrNullable(usize) wrapping
            try self.write("if (std.mem.indexOf(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")) |_v| KodrNullable(usize){ .some = _v } else KodrNullable(usize){ .none = {} }");
        } else if (std.mem.eql(u8, method, "lastIndexOf")) {
            try self.write("if (std.mem.lastIndexOf(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")) |_v| KodrNullable(usize){ .some = _v } else KodrNullable(usize){ .none = {} }");
        } else if (std.mem.eql(u8, method, "count")) {
            try self.write("std.mem.count(u8, ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(")");

        // ── Allocating string methods ────────────────────────────

        } else if (std.mem.eql(u8, method, "toUpper")) {
            // s.toUpper() → std.ascii.allocUpperString(alloc, s) catch ""
            try self.write("(std.ascii.allocUpperString(");
            try self.writeStringAllocArg(args);
            try self.write(", ");
            try self.generateExpr(obj);
            try self.write(") catch \"\")");
        } else if (std.mem.eql(u8, method, "toLower")) {
            // s.toLower() → std.ascii.allocLowerString(alloc, s) catch ""
            try self.write("(std.ascii.allocLowerString(");
            try self.writeStringAllocArg(args);
            try self.write(", ");
            try self.generateExpr(obj);
            try self.write(") catch \"\")");
        } else if (std.mem.eql(u8, method, "replace")) {
            // s.replace(old, new) → std.mem.replaceOwned(u8, alloc, s, old, new) catch ""
            try self.write("(std.mem.replaceOwned(u8, ");
            try self.writeStringAllocArg(args);
            try self.write(", ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(", ");
            if (args.len > 1) try self.generateExpr(args[1]);
            try self.write(") catch \"\")");
        } else if (std.mem.eql(u8, method, "repeat")) {
            // s.repeat(n) → kodrStringRepeat(alloc, s, n) catch ""
            try self.write("(kodrStringRepeat(");
            try self.writeStringAllocArg(args);
            try self.write(", ");
            try self.generateExpr(obj);
            try self.write(", ");
            if (args.len > 0) try self.generateExpr(args[0]);
            try self.write(") catch \"\")");

        } else if (std.mem.eql(u8, method, "parseInt")) {
            // s.parseInt() → std.fmt.parseInt(i32, s, 10)
            try self.write("std.fmt.parseInt(i32, ");
            try self.generateExpr(obj);
            try self.write(", 10) catch 0");
        } else if (std.mem.eql(u8, method, "parseFloat")) {
            // s.parseFloat() → std.fmt.parseFloat(f64, s)
            try self.write("std.fmt.parseFloat(f64, ");
            try self.generateExpr(obj);
            try self.write(") catch 0.0");
        } else {
            // Unknown string method — pass through
            try self.generateExpr(obj);
            try self.writeFmt(".{s}(", .{method});
            for (args, 0..) |a, i| {
                if (i > 0) try self.write(", ");
                try self.generateExpr(a);
            }
            try self.write(")");
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
        const d = self.decls orelse return;
        const fsig = d.funcs.get(func_name) orelse return;
        if (c.args.len >= fsig.param_nodes.len) return;
        var wrote_any = c.args.len > 0;
        for (fsig.param_nodes[c.args.len..]) |p| {
            if (p.* == .param) {
                if (p.param.default_value) |dv| {
                    if (wrote_any) try self.write(", ");
                    try self.generateExpr(dv);
                    wrote_any = true;
                }
            }
        }
    }

    fn writeStringAllocArg(self: *CodeGen, args: []*parser.Node) anyerror!void {
        // Check if the last argument is an allocator (mem.X() or a tracked allocator var)
        if (args.len > 0) {
            const last = args[args.len - 1];
            if (getMemAllocKind(last) != null) {
                // Inline allocator: s.toUpper(mem.Arena()) — but for string methods,
                // the user should pass a named allocator, not inline.
                // For simplicity, we accept named allocator vars only.
            }
            if (last.* == .identifier and self.allocator_vars.contains(last.identifier)) {
                const info = self.allocator_vars.get(last.identifier).?;
                switch (info.kind) {
                    .smp, .page => try self.generateExpr(last),
                    else => {
                        try self.generateExpr(last);
                        try self.write(".allocator()");
                    },
                }
                return;
            }
        }
        // Default: SMP allocator
        try self.write("std.heap.smp_allocator");
    }

    /// Generate a collection declaration where the collection owns its allocator.
    /// Default (no arg) and mem.SMP() → use std.heap.smp_allocator (singleton, no boilerplate).
    /// mem.DebugAllocator() / mem.Arena() / mem.Stack(n) → generate allocator boilerplate first.
    /// All collections use the unmanaged API (init = .{}, allocator passed to each method).
    fn generateOwnedCollDecl(self: *CodeGen, decl_kind: []const u8, name: []const u8, type_ann: ?*parser.Node, c: parser.CollExpr) anyerror!void {
        // Ring/ORing — fixed-size, no allocator
        if (std.mem.eql(u8, c.kind, "Ring") or std.mem.eql(u8, c.kind, "ORing")) {
            const zig_type = if (std.mem.eql(u8, c.kind, "Ring")) "KodrRing" else "KodrORing";
            try self.writeFmt("{s} {s}", .{ decl_kind, name });
            if (type_ann) |t| {
                try self.writeFmt(": {s}", .{try self.typeToZig(t)});
            } else if (c.type_args.len > 0 and c.size_arg != null) {
                try self.writeFmt(": {s}(", .{zig_type});
                try self.generateExpr(c.type_args[0]);
                try self.write(", ");
                try self.generateExpr(c.size_arg.?);
                try self.write(")");
            }
            try self.write(" = .{};");
            return;
        }

        const kind: AllocKind = if (c.alloc_arg) |arg| getMemAllocKind(arg) orelse .smp else .smp;
        const extra_args: []*parser.Node = if (c.alloc_arg) |arg|
            if (arg.* == .call_expr) arg.call_expr.args else &[_]*parser.Node{}
        else
            &[_]*parser.Node{};

        // Determine allocator expression for method calls
        const alloc_var = try std.fmt.allocPrint(self.allocator, "_{s}_alloc", .{name});
        defer self.allocator.free(alloc_var);

        // For wrapper types: tracked alloc is "_{name}_alloc.allocator()"
        // For singletons: tracked alloc is the global allocator directly
        const tracked_alloc: []const u8 = switch (kind) {
            .smp  => "std.heap.smp_allocator",
            .page => "std.heap.page_allocator",
            else  => try std.fmt.allocPrint(self.allocator, "{s}.allocator()", .{alloc_var}),
        };
        defer if (kind != .smp and kind != .page) self.allocator.free(tracked_alloc);

        // Generate allocator boilerplate for stateful allocators
        switch (kind) {
            .smp, .page => {}, // global singletons — no init needed
            else => {
                try self.generateAllocatorInit(alloc_var, kind, extra_args);
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
        if (std.mem.eql(u8, c.kind, K.Coll.LIST)) {
            try self.list_vars.put(self.allocator, name, stored_alloc);
        } else if (std.mem.eql(u8, c.kind, K.Coll.MAP)) {
            try self.map_vars.put(self.allocator, name, stored_alloc);
        } else if (std.mem.eql(u8, c.kind, K.Coll.SET)) {
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
                if (std.mem.eql(u8, name, K.Type.ERROR)) return "KodrError";
                if (std.mem.eql(u8, name, "mem.Allocator")) return "std.mem.Allocator";
                if (std.mem.eql(u8, name, K.Type.FILE)) return "KodrFs.File";
                if (std.mem.eql(u8, name, K.Type.DIR)) return "KodrFs.Dir";
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
                            if (has_error) break :blk try self.allocTypeStr("KodrResult({s})", .{inner});
                            if (has_null) break :blk try self.allocTypeStr("KodrNullable({s})", .{inner});
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
                } else if (std.mem.eql(u8, g.name, K.Coll.LIST)) {
                    // List(T) → std.ArrayList(T)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("std.ArrayList({s})", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, K.Coll.MAP)) {
                    // Map(K,V) → std.StringHashMapUnmanaged(V) if K is String, else std.AutoHashMapUnmanaged(K,V)
                    if (g.args.len >= 2) {
                        const key = try self.typeToZig(g.args[0]);
                        const val = try self.typeToZig(g.args[1]);
                        if (std.mem.eql(u8, key, "[]const u8")) {
                            break :blk try self.allocTypeStr("std.StringHashMapUnmanaged({s})", .{val});
                        }
                        break :blk try self.allocTypeStr("std.AutoHashMapUnmanaged({s}, {s})", .{ key, val });
                    }
                } else if (std.mem.eql(u8, g.name, K.Coll.SET)) {
                    // Set(T) → std.StringHashMapUnmanaged(void) if T is String, else std.AutoHashMapUnmanaged(T, void)
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        if (std.mem.eql(u8, inner, "[]const u8")) {
                            break :blk "std.StringHashMapUnmanaged(void)";
                        }
                        break :blk try self.allocTypeStr("std.AutoHashMapUnmanaged({s}, void)", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, "Ring")) {
                    if (g.args.len >= 2) {
                        const inner = try self.typeToZig(g.args[0]);
                        const size_str = if (g.args[1].* == .int_literal) g.args[1].int_literal else "0";
                        break :blk try self.allocTypeStr("KodrRing({s}, {s})", .{ inner, size_str });
                    }
                } else if (std.mem.eql(u8, g.name, "ORing")) {
                    if (g.args.len >= 2) {
                        const inner = try self.typeToZig(g.args[0]);
                        const size_str = if (g.args[1].* == .int_literal) g.args[1].int_literal else "0";
                        break :blk try self.allocTypeStr("KodrORing({s}, {s})", .{ inner, size_str });
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
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.ERROR)) return true;
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
                if (ta.* == .type_named and std.mem.eql(u8, ta.type_named, K.Type.ERROR)) return true;
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
                    if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) return true;
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
                        if (t.* == .type_named and std.mem.eql(u8, t.type_named, K.Type.NULL)) return true;
                    }
                }
            }
            return false;
        },
        else => return false,
    }
}

/// Check if a module uses wrapper allocators (Debug/Arena/Stack) for preamble import
fn moduleUsesAllocWrappers(ast: *parser.Node) bool {
    if (ast.* != .program) return false;
    for (ast.program.top_level) |node| {
        if (nodeRefsAllocWrapper(node)) return true;
    }
    return false;
}

fn nodeRefsAllocWrapper(node: *parser.Node) bool {
    switch (node.*) {
        .call_expr => |c| {
            // Check for mem.DebugAllocator(), mem.Arena(), mem.Stack()
            if (c.callee.* == .field_expr) {
                const fe = c.callee.field_expr;
                if (fe.object.* == .identifier and std.mem.eql(u8, fe.object.identifier, K.Module.MEM)) {
                    if (std.mem.eql(u8, fe.field, "DebugAllocator") or
                        std.mem.eql(u8, fe.field, "Arena") or
                        std.mem.eql(u8, fe.field, "Stack")) return true;
                }
            }
            for (c.args) |arg| if (nodeRefsAllocWrapper(arg)) return true;
            return false;
        },
        .func_decl => |f| return nodeRefsAllocWrapper(f.body),
        .block => |b| {
            for (b.statements) |s| if (nodeRefsAllocWrapper(s)) return true;
            return false;
        },
        .var_decl, .const_decl => |v| return nodeRefsAllocWrapper(v.value),
        .struct_decl => |s| {
            for (s.members) |m| if (nodeRefsAllocWrapper(m)) return true;
            return false;
        },
        .coll_expr => |c| {
            if (c.alloc_arg) |arg| return nodeRefsAllocWrapper(arg);
            return false;
        },
        else => return false,
    }
}

/// Check if a module uses File or Dir types (for preamble import)
fn moduleUsesFileOrDir(ast: *parser.Node) bool {
    if (ast.* != .program) return false;
    for (ast.program.top_level) |node| {
        if (nodeRefsFileOrDir(node)) return true;
    }
    return false;
}

fn nodeRefsFileOrDir(node: *parser.Node) bool {
    switch (node.*) {
        .identifier => |name| return std.mem.eql(u8, name, K.Type.FILE) or std.mem.eql(u8, name, K.Type.DIR),
        .type_named => |name| return std.mem.eql(u8, name, K.Type.FILE) or std.mem.eql(u8, name, K.Type.DIR),
        .call_expr => |c| {
            if (nodeRefsFileOrDir(c.callee)) return true;
            for (c.args) |arg| if (nodeRefsFileOrDir(arg)) return true;
            return false;
        },
        .func_decl => |f| {
            if (nodeRefsFileOrDir(f.return_type)) return true;
            return nodeRefsFileOrDir(f.body);
        },
        .block => |b| {
            for (b.statements) |s| if (nodeRefsFileOrDir(s)) return true;
            return false;
        },
        .var_decl, .const_decl => |v| {
            if (v.type_annotation) |t| if (nodeRefsFileOrDir(t)) return true;
            return nodeRefsFileOrDir(v.value);
        },
        .struct_decl => |s| {
            for (s.members) |m| if (nodeRefsFileOrDir(m)) return true;
            return false;
        },
        .return_stmt => |r| {
            if (r.value) |v| return nodeRefsFileOrDir(v);
            return false;
        },
        .if_stmt => |i| {
            if (nodeRefsFileOrDir(i.then_block)) return true;
            if (i.else_block) |eb| return nodeRefsFileOrDir(eb);
            return false;
        },
        .field_expr => |f| return nodeRefsFileOrDir(f.object),
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

test "codegen - string methods" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var gen = CodeGen.init(alloc, &reporter, true);
    defer gen.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Register "s" as a string variable
    try gen.string_vars.put(gen.allocator, "s", {});

    // Build: s.contains("world")
    const obj = try a.create(parser.Node);
    obj.* = .{ .identifier = "s" };
    const substr = try a.create(parser.Node);
    substr.* = .{ .string_literal = "\"world\"" };

    // Test contains
    const field_contains = try a.create(parser.Node);
    field_contains.* = .{ .field_expr = .{ .object = obj, .field = "contains" } };
    const args1 = try a.alloc(*parser.Node, 1);
    args1[0] = substr;
    const call_contains = try a.create(parser.Node);
    call_contains.* = .{ .call_expr = .{ .callee = field_contains, .args = args1, .arg_names = &.{} } };

    try gen.generateExpr(call_contains);
    const contains_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, contains_out, "std.mem.indexOf(u8, s, \"world\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, contains_out, "!= null") != null);

    // Test trim
    gen.output.clearRetainingCapacity();
    const field_trim = try a.create(parser.Node);
    field_trim.* = .{ .field_expr = .{ .object = obj, .field = "trim" } };
    const call_trim = try a.create(parser.Node);
    call_trim.* = .{ .call_expr = .{ .callee = field_trim, .args = &.{}, .arg_names = &.{} } };

    try gen.generateExpr(call_trim);
    const trim_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, trim_out, "std.mem.trim(u8, s,") != null);

    // Test startsWith
    gen.output.clearRetainingCapacity();
    const field_sw = try a.create(parser.Node);
    field_sw.* = .{ .field_expr = .{ .object = obj, .field = "startsWith" } };
    const prefix = try a.create(parser.Node);
    prefix.* = .{ .string_literal = "\"he\"" };
    const args2 = try a.alloc(*parser.Node, 1);
    args2[0] = prefix;
    const call_sw = try a.create(parser.Node);
    call_sw.* = .{ .call_expr = .{ .callee = field_sw, .args = args2, .arg_names = &.{} } };

    try gen.generateExpr(call_sw);
    const sw_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, sw_out, "std.mem.startsWith(u8, s, \"he\")") != null);

    // Test indexOf — should emit KodrNullable wrapping
    gen.output.clearRetainingCapacity();
    const field_io = try a.create(parser.Node);
    field_io.* = .{ .field_expr = .{ .object = obj, .field = "indexOf" } };
    const needle = try a.create(parser.Node);
    needle.* = .{ .string_literal = "\"x\"" };
    const args3 = try a.alloc(*parser.Node, 1);
    args3[0] = needle;
    const call_io = try a.create(parser.Node);
    call_io.* = .{ .call_expr = .{ .callee = field_io, .args = args3, .arg_names = &.{} } };

    try gen.generateExpr(call_io);
    const io_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, io_out, "std.mem.indexOf(u8, s, \"x\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, io_out, "KodrNullable(usize)") != null);

    // Test count
    gen.output.clearRetainingCapacity();
    const field_ct = try a.create(parser.Node);
    field_ct.* = .{ .field_expr = .{ .object = obj, .field = "count" } };
    const char = try a.create(parser.Node);
    char.* = .{ .string_literal = "\"o\"" };
    const args4 = try a.alloc(*parser.Node, 1);
    args4[0] = char;
    const call_ct = try a.create(parser.Node);
    call_ct.* = .{ .call_expr = .{ .callee = field_ct, .args = args4, .arg_names = &.{} } };

    try gen.generateExpr(call_ct);
    const ct_out = gen.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, ct_out, "std.mem.count(u8, s, \"o\")") != null);
}
