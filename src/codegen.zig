// codegen.zig — Zig Code Generation pass (pass 11)
// Translates MIR and AST to readable Zig source files.
// One .zig file per Kodr module. Uses std.fmt for output.

const std = @import("std");
const parser = @import("parser.zig");
const mir = @import("mir.zig");
const builtins = @import("builtins.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");

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
    null_vars: std.StringHashMapUnmanaged(void), // variables with (null | T) type

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
        // Clear null vars per function scope (each function tracks its own)
        const prev_null_vars = self.null_vars;
        self.null_vars = .{};
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
    // VARIABLE DECLARATIONS
    // ============================================================

    fn generateConst(self: *CodeGen, v: parser.VarDecl) anyerror!void {
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
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
    }

    fn generateVar(self: *CodeGen, v: parser.VarDecl) anyerror!void {
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
            try self.generateExpr(v.value);
        }
        try self.write(";\n");
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
        try self.generateBlock(t.body);
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
                const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
                try self.writeFmt("var {s}", .{v.name});
                if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                try self.write(" = ");
                if (is_null_union) {
                    try self.null_vars.put(self.allocator, v.name, {});
                    try self.generateNullWrappedExpr(v.value);
                } else {
                    try self.generateExpr(v.value);
                }
                try self.write(";");
            },
            .const_decl => |v| {
                const is_null_union = if (v.type_annotation) |t| isNullUnionType(t) else false;
                try self.writeFmt("const {s}", .{v.name});
                if (v.type_annotation) |t| try self.writeFmt(": {s}", .{try self.typeToZig(t)});
                try self.write(" = ");
                if (is_null_union) {
                    try self.null_vars.put(self.allocator, v.name, {});
                    try self.generateNullWrappedExpr(v.value);
                } else {
                    try self.generateExpr(v.value);
                }
                try self.write(";");
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
                    try self.generateExpr(c);
                    try self.write(")");
                }
                try self.write(" ");
                try self.generateBlock(w.body);
            },
            .for_stmt => |f| {
                // Kodr for(arr, 0..) |val, idx| → Zig for (arr, 0..) |val, idx|
                // compt for → inline for
                if (f.is_compt) try self.write("inline ");
                try self.write("for (");
                for (f.iterables, 0..) |it, i| {
                    if (i > 0) try self.write(", ");
                    try self.generateExpr(it);
                }
                try self.write(") |");
                for (f.variables, 0..) |v, i| {
                    if (i > 0) try self.write(", ");
                    try self.write(v);
                }
                try self.write("| ");
                try self.generateBlock(f.body);
            },
            .defer_stmt => |d| {
                try self.write("defer ");
                try self.generateBlock(d.body);
            },
            .match_stmt => |m| {
                try self.write("switch (");
                try self.generateExpr(m.value);
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
                // result.Error → result.err (Error union access)
                if (std.mem.eql(u8, f.field, "Error")) {
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
                try self.generateExpr(i.index);
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
            else => try self.write("/* unsupported expr */"),
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
            // @cast(x) — target type from context, use @as in Zig
            try self.write("@as(/* target_type */, ");
            if (cf.args.len > 0) try self.generateExpr(cf.args[0]);
            try self.write(")");
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
            // @assert(x) → std.debug.assert(x) or try std.testing.expect(x) in tests
            try self.write("std.debug.assert(");
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
            // Ptr(T, &x) → KodrPtr(T){ .address = @intFromPtr(&x), .valid = true }
            try self.writeFmt("KodrPtr({s}){{ .address = @intFromPtr(", .{try self.typeToZig(p.type_arg)});
            try self.generateExpr(p.addr_arg);
            try self.write("), .valid = true }");
        } else if (std.mem.eql(u8, p.kind, "RawPtr")) {
            // RawPtr(T, addr) → @ptrFromInt(addr) — always warns in Kodr, direct in Zig
            try self.writeFmt("@as([*]{s}, @ptrFromInt(", .{try self.typeToZig(p.type_arg)});
            try self.generateExpr(p.addr_arg);
            try self.write("))");
        } else if (std.mem.eql(u8, p.kind, "VolatilePtr")) {
            // VolatilePtr(T, addr) → @as(*volatile T, @ptrFromInt(addr))
            try self.writeFmt("@as(*volatile {s}, @ptrFromInt(", .{try self.typeToZig(p.type_arg)});
            try self.generateExpr(p.addr_arg);
            try self.write("))");
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
                // Size expression — simplified to use the expr text
                break :blk try self.allocTypeStr("[TODO]{s}", .{inner});
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
                break :blk try self.allocTypeStr("fn ({s}) {s}",
                    .{ params_str.items, ret });
            },
            .type_generic => |g| blk: {
                // Thread(T) → KodrThread(T), Async(T) → KodrAsync(T), Ptr(T) → KodrPtr(T)
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
                }
                break :blk g.name;
            },
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
