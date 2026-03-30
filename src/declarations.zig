// declarations.zig — Declaration pass (pass 4)
// Collects all type names, function signatures, struct definitions
// before resolving bodies. Solves chicken-and-egg with compt/type resolution.

const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");
const module = @import("module.zig");
const builtins = @import("builtins.zig");
const types = @import("types.zig");
const K = @import("constants.zig");

/// A function signature
pub const FuncSig = struct {
    name: []const u8,
    params: []ParamSig,
    param_nodes: []*parser.Node, // original AST param nodes (for default values)
    return_type: types.ResolvedType,
    return_type_node: *parser.Node, // original AST node (used by codegen)
    is_compt: bool,
    is_pub: bool,
    is_thread: bool,
    /// True for bridge declarations — implementation lives in paired .zig sidecar.
    /// Bridge function calls must not receive const auto-borrow promotion because
    /// the Orhon compiler does not control the sidecar's parameter types.
    is_bridge: bool = false,
};

pub const ParamSig = struct {
    name: []const u8,
    type_: types.ResolvedType,
};

/// A struct declaration summary
pub const StructSig = struct {
    name: []const u8,
    fields: []FieldSig,
    is_pub: bool,
};

pub const FieldSig = struct {
    name: []const u8,
    type_: types.ResolvedType,
    has_default: bool,
    is_pub: bool,
};

/// An enum declaration summary
pub const EnumSig = struct {
    name: []const u8,
    backing_type: types.ResolvedType,
    variants: [][]const u8,
    is_pub: bool,
};

/// A bitfield declaration summary
pub const BitfieldSig = struct {
    name: []const u8,
    backing_type: types.ResolvedType,
    flags: [][]const u8,
    is_pub: bool,
};

/// A variable/constant declaration
pub const VarSig = struct {
    name: []const u8,
    type_: ?types.ResolvedType,
    is_const: bool,
    is_compt: bool,
    is_pub: bool,
};

/// The declaration table for a module
pub const DeclTable = struct {
    funcs: std.StringHashMap(FuncSig),
    structs: std.StringHashMap(StructSig),
    enums: std.StringHashMap(EnumSig),
    bitfields: std.StringHashMap(BitfieldSig),
    vars: std.StringHashMap(VarSig),
    types: std.StringHashMap([]const u8), // type aliases and compt types
    /// Bridge struct method signatures keyed by "StructName.method".
    /// Used by MIR annotator to detect const & param coercions for cross-module calls.
    struct_methods: std.StringHashMapUnmanaged(FuncSig),
    allocator: std.mem.Allocator,
    type_arena: std.heap.ArenaAllocator, // owns all ResolvedType inner allocations

    /// Allocator for ResolvedType inner pointers — freed when DeclTable is deinitialized
    pub fn typeAllocator(self: *DeclTable) std.mem.Allocator {
        return self.type_arena.allocator();
    }

    pub fn init(allocator: std.mem.Allocator) DeclTable {
        return .{
            .funcs = std.StringHashMap(FuncSig).init(allocator),
            .structs = std.StringHashMap(StructSig).init(allocator),
            .enums = std.StringHashMap(EnumSig).init(allocator),
            .bitfields = std.StringHashMap(BitfieldSig).init(allocator),
            .vars = std.StringHashMap(VarSig).init(allocator),
            .types = std.StringHashMap([]const u8).init(allocator),
            .struct_methods = .{},
            .allocator = allocator,
            .type_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DeclTable) void {
        // Free the type arena (all ResolvedType inner pointers)
        self.type_arena.deinit();
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
        // Free owned slices stored in BitfieldSig values
        var bitfield_it = self.bitfields.iterator();
        while (bitfield_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.flags);
        }
        self.bitfields.deinit();
        self.vars.deinit();
        self.types.deinit();
        // Free struct_methods: keys are allocPrint strings, values have owned param slices
        var sm_it = self.struct_methods.iterator();
        while (sm_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.params);
        }
        self.struct_methods.deinit(self.allocator);
    }

    pub fn hasDecl(self: *const DeclTable, name: []const u8) bool {
        return self.funcs.contains(name) or
               self.structs.contains(name) or
               self.enums.contains(name) or
               self.bitfields.contains(name) or
               self.vars.contains(name) or
               self.types.contains(name);
    }
};

/// Returns true if the type annotation is the `type` keyword — indicating a type alias declaration.
fn isTypeAlias(type_annotation: ?*parser.Node) bool {
    const ta = type_annotation orelse return false;
    return ta.* == .type_named and std.mem.eql(u8, ta.type_named, K.Type.TYPE);
}

/// The declaration collector
pub const DeclCollector = struct {
    table: DeclTable,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    locs: ?*const parser.LocMap,
    file_offsets: []const module.FileOffset,

    pub fn init(allocator: std.mem.Allocator, reporter: *errors.Reporter) DeclCollector {
        return .{
            .table = DeclTable.init(allocator),
            .reporter = reporter,
            .allocator = allocator,
            .locs = null,
            .file_offsets = &.{},
        };
    }

    fn nodeLoc(self: *const DeclCollector, node: *parser.Node) ?errors.SourceLoc {
        if (self.locs) |l| {
            if (l.get(node)) |loc| {
                const resolved = module.resolveFileLoc(self.file_offsets, loc.line);
                return .{ .file = resolved.file, .line = resolved.line, .col = loc.col };
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

        // Validate: #cimport is only allowed in modules that have bridge declarations.
        var cimport_node: ?*parser.Node = null;
        for (ast.program.metadata) |meta| {
            if (std.mem.eql(u8, meta.metadata.field, "cimport")) {
                cimport_node = meta;
                break;
            }
        }
        if (cimport_node != null) {
            var has_bridge = false;
            for (ast.program.top_level) |node| {
                switch (node.*) {
                    .func_decl => |f| if (f.is_bridge) { has_bridge = true; break; },
                    .struct_decl => |s| if (s.is_bridge) { has_bridge = true; break; },
                    .const_decl => |v| if (v.is_bridge) { has_bridge = true; break; },
                    else => {},
                }
            }
            if (!has_bridge) {
                try self.reporter.report(.{
                    .message = "#cimport is only allowed in modules with bridge declarations",
                    .loc = self.nodeLoc(cimport_node.?),
                });
                return;
            }
        }

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
            .bitfield_decl => |b| try self.collectBitfield(b, loc),
            .const_decl => |v| try self.collectVar(v, true, false, loc),
            .var_decl => {
                const msg = try std.fmt.allocPrint(self.allocator, "module-level 'var' is not allowed — use 'const' for module-level declarations", .{});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            },
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
                    .type_ = try types.resolveTypeNode(self.table.typeAllocator(), param.param.type_annotation),
                });
            }
        }

        // Validate: required params must precede default params
        var seen_default = false;
        for (f.params) |param_node| {
            if (param_node.* == .param) {
                if (param_node.param.default_value != null) {
                    seen_default = true;
                } else if (seen_default) {
                    const msg = try std.fmt.allocPrint(self.allocator, "parameters with defaults must come after all required parameters in '{s}'", .{f.name});
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = loc });
                    break;
                }
            }
        }

        const sig = FuncSig{
            .name = f.name,
            .params = try params.toOwnedSlice(self.allocator),
            .param_nodes = f.params,
            .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
            .return_type_node = f.return_type,
            .is_compt = f.is_compt,
            .is_pub = f.is_pub,
            .is_thread = f.is_thread,
            .is_bridge = f.is_bridge,
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
                    .type_ = try types.resolveTypeNode(self.table.typeAllocator(), f.type_annotation),
                    .has_default = f.default_value != null,
                    .is_pub = f.is_pub,
                });
            }
        }

        // Validate field names don't conflict with type names and no duplicates
        for (fields.items, 0..) |field, i| {
            if (isReservedTypeName(field.name)) {
                const msg = try std.fmt.allocPrint(self.allocator,
                    "field name '{s}' conflicts with type name — choose a different name", .{field.name});
                defer self.allocator.free(msg);
                try self.reporter.report(.{ .message = msg, .loc = loc });
            }
            // Check for duplicate field names
            for (fields.items[0..i]) |prev| {
                if (std.mem.eql(u8, field.name, prev.name)) {
                    const msg = try std.fmt.allocPrint(self.allocator,
                        "duplicate field '{s}' in struct '{s}'", .{ field.name, s.name });
                    defer self.allocator.free(msg);
                    try self.reporter.report(.{ .message = msg, .loc = loc });
                    break;
                }
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

        // Register struct methods into struct_methods so borrow checker and MIR can
        // detect self parameter mutability. All structs, not just bridge structs.
        // Key: "StructName.method" to avoid collisions with same-named methods on other structs.
        {
            for (s.members) |member| {
                if (member.* == .func_decl) {
                    const f = member.func_decl;
                    var params: std.ArrayListUnmanaged(ParamSig) = .{};
                    for (f.params) |param| {
                        if (param.* == .param) {
                            try params.append(self.allocator, .{
                                .name = param.param.name,
                                .type_ = try types.resolveTypeNode(self.table.typeAllocator(), param.param.type_annotation),
                            });
                        }
                    }
                    const method_sig = FuncSig{
                        .name = f.name,
                        .params = try params.toOwnedSlice(self.allocator),
                        .param_nodes = f.params,
                        .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
                        .return_type_node = f.return_type,
                        .is_compt = f.is_compt,
                        .is_pub = f.is_pub,
                        .is_thread = f.is_thread,
                        .is_bridge = s.is_bridge,
                    };
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ s.name, f.name });
                    try self.table.struct_methods.put(self.allocator, key, method_sig);
                }
            }
        }
    }

    fn collectEnum(self: *DeclCollector, e: parser.EnumDecl, loc: ?errors.SourceLoc) anyerror!void {
        var variants: std.ArrayListUnmanaged([]const u8) = .{};
        for (e.members) |member| {
            if (member.* == .enum_variant) {
                // Check for duplicate variant names
                for (variants.items) |prev| {
                    if (std.mem.eql(u8, member.enum_variant.name, prev)) {
                        const msg = try std.fmt.allocPrint(self.allocator,
                            "duplicate variant '{s}' in enum '{s}'", .{ member.enum_variant.name, e.name });
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = loc });
                        break;
                    }
                }
                try variants.append(self.allocator, member.enum_variant.name);
            }
        }

        const sig = EnumSig{
            .name = e.name,
            .backing_type = try types.resolveTypeNode(self.table.typeAllocator(), e.backing_type),
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

    fn collectBitfield(self: *DeclCollector, b: parser.BitfieldDecl, loc: ?errors.SourceLoc) anyerror!void {
        _ = loc;
        var flags: std.ArrayListUnmanaged([]const u8) = .{};
        for (b.members) |flag_name| {
            try flags.append(self.allocator, flag_name);
        }
        const sig = BitfieldSig{
            .name = b.name,
            .backing_type = try types.resolveTypeNode(self.table.typeAllocator(), b.backing_type),
            .flags = try flags.toOwnedSlice(self.allocator),
            .is_pub = b.is_pub,
        };
        try self.table.bitfields.put(b.name, sig);
    }

    fn collectVar(self: *DeclCollector, v: parser.VarDecl, is_const: bool, is_compt: bool, loc: ?errors.SourceLoc) anyerror!void {
        // Type alias: const Name: type = T — register in types map, not vars
        if (is_const and isTypeAlias(v.type_annotation)) {
            try self.table.types.put(v.name, v.name);
            return;
        }

        const sig = VarSig{
            .name = v.name,
            .type_ = if (v.type_annotation) |t| try types.resolveTypeNode(self.table.typeAllocator(), t) else null,
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
        .is_bridge = false,
        .is_thread = false,
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
        .type_params = &.{},
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
        .is_compt = false, .is_pub = false, .is_bridge = false, .is_thread = false } };

    const func2 = try a.create(parser.Node);
    func2.* = .{ .func_decl = .{ .name = "foo", .params = &.{},
        .return_type = ret_type, .body = empty_block,
        .is_compt = false, .is_pub = false, .is_bridge = false, .is_thread = false } };

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

test "declaration collector - enum" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const variant = try a.create(parser.Node);
    variant.* = .{ .enum_variant = .{ .name = "Red", .fields = &.{} } };
    const members = try a.alloc(*parser.Node, 1);
    members[0] = variant;

    const backing = try a.create(parser.Node);
    backing.* = .{ .type_named = "u32" };

    const enum_node = try a.create(parser.Node);
    enum_node.* = .{ .enum_decl = .{ .name = "Color", .backing_type = backing, .members = members, .is_pub = false } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = enum_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.enums.contains("Color"));
}

test "declaration collector - bridge func is registered" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };

    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "print",
        .params = &.{},
        .return_type = ret_type,
        .body = undefined,
        .is_compt = false,
        .is_pub = true,
        .is_bridge = true,
        .is_thread = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "main" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.funcs.contains("print"));
}

test "declaration collector - #cimport without bridge is an error" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // A normal (non-bridge) func
    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "foo",
        .params = &.{},
        .return_type = ret_type,
        .body = undefined,
        .is_compt = false,
        .is_pub = true,
        .is_bridge = false,
        .is_thread = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    // #cimport metadata node
    const lib_name = try a.create(parser.Node);
    lib_name.* = .{ .string_literal = "\"SDL3\"" };
    const link_meta = try a.create(parser.Node);
    link_meta.* = .{ .metadata = .{ .field = "cimport", .value = lib_name, .cimport_include = "SDL3/SDL.h" } };
    const metadata = try a.alloc(*parser.Node, 1);
    metadata[0] = link_meta;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "bad" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = metadata, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    try std.testing.expect(reporter.hasErrors());
}

test "declaration collector - #cimport with bridge is allowed" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "init",
        .params = &.{},
        .return_type = ret_type,
        .body = undefined,
        .is_compt = false,
        .is_pub = true,
        .is_bridge = true,
        .is_thread = false,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const lib_name = try a.create(parser.Node);
    lib_name.* = .{ .string_literal = "\"SDL3\"" };
    const link_meta = try a.create(parser.Node);
    link_meta.* = .{ .metadata = .{ .field = "cimport", .value = lib_name, .cimport_include = "SDL3/SDL.h" } };
    const metadata = try a.alloc(*parser.Node, 1);
    metadata[0] = link_meta;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "sdl" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = metadata, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
}

/// Check if a name conflicts with a primitive or builtin type name.
/// Used to prevent field names like `String`, `i32`, `File` etc.
fn isReservedTypeName(name: []const u8) bool {
    if (types.isPrimitiveName(name)) return true;
    if (std.mem.eql(u8, name, "Error")) return true;
    return builtins.isBuiltinType(name);
}

test "isTypeAlias - detects type keyword annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Test 1: type annotation "type" → is type alias
    const type_node = try a.create(parser.Node);
    type_node.* = .{ .type_named = "type" };
    try std.testing.expect(isTypeAlias(type_node));

    // Test 2: no type annotation → not a type alias
    try std.testing.expect(!isTypeAlias(null));

    // Test 3: type annotation "i32" → not a type alias
    const i32_node = try a.create(parser.Node);
    i32_node.* = .{ .type_named = "i32" };
    try std.testing.expect(!isTypeAlias(i32_node));
}
