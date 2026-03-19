// declarations.zig — Declaration pass (pass 4)
// Collects all type names, function signatures, struct definitions
// before resolving bodies. Solves chicken-and-egg with compt/type resolution.

const std = @import("std");
const parser = @import("parser.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

/// A function signature
pub const FuncSig = struct {
    name: []const u8,
    params: []ParamSig,
    return_type: []const u8, // simplified type string
    is_compt: bool,
    is_pub: bool,
};

pub const ParamSig = struct {
    name: []const u8,
    type_str: []const u8,
};

/// A struct declaration summary
pub const StructSig = struct {
    name: []const u8,
    fields: []FieldSig,
    is_pub: bool,
};

pub const FieldSig = struct {
    name: []const u8,
    type_str: []const u8,
    has_default: bool,
    is_pub: bool,
};

/// An enum declaration summary
pub const EnumSig = struct {
    name: []const u8,
    backing_type: []const u8,
    is_bitfield: bool,
    variants: [][]const u8,
    is_pub: bool,
};

/// A variable/constant declaration
pub const VarSig = struct {
    name: []const u8,
    type_str: ?[]const u8,
    is_const: bool,
    is_compt: bool,
    is_pub: bool,
};

/// The declaration table for a module
pub const DeclTable = struct {
    funcs: std.StringHashMap(FuncSig),
    structs: std.StringHashMap(StructSig),
    enums: std.StringHashMap(EnumSig),
    vars: std.StringHashMap(VarSig),
    types: std.StringHashMap([]const u8), // type aliases and compt types
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DeclTable {
        return .{
            .funcs = std.StringHashMap(FuncSig).init(allocator),
            .structs = std.StringHashMap(StructSig).init(allocator),
            .enums = std.StringHashMap(EnumSig).init(allocator),
            .vars = std.StringHashMap(VarSig).init(allocator),
            .types = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DeclTable) void {
        // Free owned slices stored in FuncSig values
        var func_it = self.funcs.iterator();
        while (func_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.params);
        }
        self.funcs.deinit();
        // Free owned slices stored in StructSig values
        var struct_it = self.structs.iterator();
        while (struct_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.fields);
        }
        self.structs.deinit();
        // Free owned slices stored in EnumSig values
        var enum_it = self.enums.iterator();
        while (enum_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.variants);
        }
        self.enums.deinit();
        self.vars.deinit();
        self.types.deinit();
    }

    pub fn hasDecl(self: *const DeclTable, name: []const u8) bool {
        return self.funcs.contains(name) or
               self.structs.contains(name) or
               self.enums.contains(name) or
               self.vars.contains(name) or
               self.types.contains(name);
    }
};

/// The declaration collector
pub const DeclCollector = struct {
    table: DeclTable,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    locs: ?*const parser.LocMap,
    source_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) DeclCollector {
        return .{
            .table = DeclTable.init(allocator),
            .reporter = reporter,
            .allocator = allocator,
            .locs = null,
            .source_file = "",
        };
    }

    fn nodeLoc(self: *const DeclCollector, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                return .{ .file = self.source_file, .line = loc.line, .col = loc.col };
            }
        }
        return null;
    }

    pub fn deinit(self: *DeclCollector) void {
        self.table.deinit();
    }

    /// Collect all declarations from a parsed AST
    pub fn collect(self: *DeclCollector, ast: *parser.Node) !void {
        if (ast.* != .program) return;
        for (ast.program.top_level) |node| {
            try self.collectTopLevel(node);
        }
    }

    fn collectTopLevel(self: *DeclCollector, node: *parser.Node) anyerror!void {
        const loc = self.nodeLoc(node);
        switch (node.*) {
            .func_decl => |f| try self.collectFunc(f, loc),
            .struct_decl => |s| try self.collectStruct(s, loc),
            .enum_decl => |e| try self.collectEnum(e, loc),
            .const_decl => |v| try self.collectVar(v, true, false, loc),
            .var_decl => |v| try self.collectVar(v, false, false, loc),
            .compt_decl => |v| try self.collectVar(v, true, true, loc),
            else => {},
        }
    }

    fn collectFunc(self: *DeclCollector, f: parser.FuncDecl, loc: ?errors.SourceLoc) anyerror!void {
        var params: std.ArrayListUnmanaged(ParamSig) = .{};
        for (f.params) |param| {
            if (param.* == .param) {
                try params.append(self.allocator, .{
                    .name = param.param.name,
                    .type_str = self.typeNodeToStr(param.param.type_annotation),
                });
            }
        }

        const sig = FuncSig{
            .name = f.name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = self.typeNodeToStr(f.return_type),
            .is_compt = f.is_compt,
            .is_pub = f.is_pub,
        };

        if (self.table.funcs.contains(f.name)) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "duplicate function declaration: '{s}'", .{f.name});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg, .loc = loc });
            return;
        }

        try self.table.funcs.put(f.name, sig);
    }

    fn collectStruct(self: *DeclCollector, s: parser.StructDecl, loc: ?errors.SourceLoc) anyerror!void {
        var fields: std.ArrayListUnmanaged(FieldSig) = .{};
        for (s.members) |member| {
            if (member.* == .field_decl) {
                const f = member.field_decl;
                try fields.append(self.allocator, .{
                    .name = f.name,
                    .type_str = self.typeNodeToStr(f.type_annotation),
                    .has_default = f.default_value != null,
                    .is_pub = f.is_pub,
                });
            }
        }

        const sig = StructSig{
            .name = s.name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .is_pub = s.is_pub,
        };

        if (self.table.structs.contains(s.name)) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "duplicate struct declaration: '{s}'", .{s.name});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg, .loc = loc });
            return;
        }

        try self.table.structs.put(s.name, sig);
    }

    fn collectEnum(self: *DeclCollector, e: parser.EnumDecl, loc: ?errors.SourceLoc) anyerror!void {
        var variants: std.ArrayListUnmanaged([]const u8) = .{};
        for (e.members) |member| {
            if (member.* == .enum_variant) {
                try variants.append(self.allocator, member.enum_variant.name);
            }
        }

        const sig = EnumSig{
            .name = e.name,
            .backing_type = self.typeNodeToStr(e.backing_type),
            .is_bitfield = e.is_bitfield,
            .variants = try variants.toOwnedSlice(self.allocator),
            .is_pub = e.is_pub,
        };

        if (self.table.enums.contains(e.name)) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "duplicate enum declaration: '{s}'", .{e.name});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg, .loc = loc });
            return;
        }

        try self.table.enums.put(e.name, sig);
    }

    fn collectVar(self: *DeclCollector, v: parser.VarDecl, is_const: bool, is_compt: bool, loc: ?errors.SourceLoc) anyerror!void {
        const sig = VarSig{
            .name = v.name,
            .type_str = if (v.type_annotation) |t| self.typeNodeToStr(t) else null,
            .is_const = is_const,
            .is_compt = is_compt,
            .is_pub = v.is_pub,
        };

        if (self.table.vars.contains(v.name)) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "duplicate variable declaration: '{s}'", .{v.name});
            defer self.allocator.free(msg);
            try self.reporter.report(.{ .message = msg, .loc = loc });
            return;
        }

        try self.table.vars.put(v.name, sig);
    }

    /// Convert a type AST node to a string representation
    fn typeNodeToStr(self: *DeclCollector, node: *parser.Node) []const u8 {
        return switch (node.*) {
            .type_named => |n| n,
            .type_primitive => |p| p,
            .type_slice => "[]T",
            .type_array => "[n]T",
            .type_union => "(union)",
            .type_func => "func",
            .type_generic => |g| g.name,
            .type_ptr => |p| p.kind,
            else => std.fmt.allocPrint(self.allocator, "{s}", .{@tagName(node.*)}) catch "unknown",
        };
    }
};

test "declaration collector - func" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    // Build a minimal AST manually
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };

    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "myFunc",
        .params = &.{},
        .return_type = ret_type,
        .body = undefined,
        .is_compt = false,
        .is_pub = true,
        .is_extern = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "test" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.funcs.contains("myFunc"));
}

test "declaration collector - struct" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const field = try a.create(parser.Node);
    field.* = .{ .field_decl = .{
        .name = "x",
        .type_annotation = try a.create(parser.Node),
        .default_value = null,
        .is_pub = false,
    }};
    field.field_decl.type_annotation.* = .{ .type_named = "f64" };

    const struct_node = try a.create(parser.Node);
    const fields = try a.alloc(*parser.Node, 1);
    fields[0] = field;
    struct_node.* = .{ .struct_decl = .{
        .name = "Point",
        .members = fields,
        .is_pub = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = struct_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.structs.contains("Point"));
}

test "declaration collector - duplicate func error" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const empty_block = try a.create(parser.Node);
    empty_block.* = .{ .block = .{ .statements = &.{} } };

    const func1 = try a.create(parser.Node);
    func1.* = .{ .func_decl = .{ .name = "foo", .params = &.{},
        .return_type = ret_type, .body = empty_block,
        .is_compt = false, .is_pub = false, .is_extern = false } };

    const func2 = try a.create(parser.Node);
    func2.* = .{ .func_decl = .{ .name = "foo", .params = &.{},
        .return_type = ret_type, .body = empty_block,
        .is_compt = false, .is_pub = false, .is_extern = false } };

    const top_level = try a.alloc(*parser.Node, 2);
    top_level[0] = func1;
    top_level[1] = func2;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    // second "foo" should trigger a duplicate error
    try std.testing.expect(reporter.hasErrors());
}
