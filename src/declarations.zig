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
const cache = @import("cache.zig");
const ast_store_mod = @import("ast_store.zig");
const ast_typed = @import("ast_typed.zig");
pub const AstNodeIndex = ast_store_mod.AstNodeIndex;
const AstStore = ast_store_mod.AstStore;

/// A function signature
pub const FuncSig = struct {
    name: []const u8,
    params: []ParamSig,
    param_nodes: []*parser.Node, // original AST param nodes (for default values)
    return_type: types.ResolvedType,
    context: parser.FuncContext,
    is_pub: bool,
    is_instance: bool, // true when first param is named "self" (instance method receiver)
};

pub const ParamSig = struct {
    name: []const u8,
    type_: types.ResolvedType,
};

/// Inner map from method name to its signature, owned per struct.
pub const StructMethodMap = std.StringHashMapUnmanaged(FuncSig);

/// A struct declaration summary
pub const StructSig = struct {
    name: []const u8,
    fields: []FieldSig,
    type_params: []ParamSig = &.{}, // generic type params, e.g. (T: type, flags: any)
    conforms_to: []const []const u8 = &.{},
    is_pub: bool,
    methods: StructMethodMap = .{},
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

pub const BlueprintMethodSig = struct {
    name: []const u8,
    params: []ParamSig,
    return_type: types.ResolvedType,
};

pub const BlueprintSig = struct {
    name: []const u8,
    methods: []BlueprintMethodSig,
    is_pub: bool,
};

/// A handle declaration summary
pub const HandleSig = struct {
    name: []const u8,
    is_pub: bool,
};

/// A variable/constant declaration
pub const VarSig = struct {
    name: []const u8,
    type_: ?types.ResolvedType,
    is_const: bool,
    is_pub: bool,
};

/// Unified symbol: one entry per top-level declaration name in a module.
pub const Symbol = union(enum) {
    func:       FuncSig,
    @"struct":  StructSig,
    @"enum":    EnumSig,
    handle:     HandleSig,
    @"var":     VarSig,
    type_alias: []const u8, // target type name string
    blueprint:  BlueprintSig,

    /// True when the symbol is exported from its module.
    /// type_alias has no pub gate in the current model — always true.
    pub fn isPub(self: Symbol) bool {
        return switch (self) {
            .func      => |s| s.is_pub,
            .@"struct" => |s| s.is_pub,
            .@"enum"   => |s| s.is_pub,
            .handle    => |s| s.is_pub,
            .@"var"    => |s| s.is_pub,
            .blueprint => |s| s.is_pub,
            .type_alias => true,
        };
    }

    /// True when the symbol is usable as a type annotation.
    pub fn isType(self: Symbol) bool {
        return switch (self) {
            .@"struct", .@"enum", .handle, .type_alias => true,
            else => false,
        };
    }
};

/// The declaration table for a module
pub const DeclTable = struct {
    symbols: std.StringHashMap(Symbol),
    allocator: std.mem.Allocator,
    type_arena: std.heap.ArenaAllocator, // owns all ResolvedType inner allocations

    /// Allocator for ResolvedType inner pointers — freed when DeclTable is deinitialized
    pub fn typeAllocator(self: *DeclTable) std.mem.Allocator {
        return self.type_arena.allocator();
    }

    pub fn init(allocator: std.mem.Allocator) DeclTable {
        return .{
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .allocator = allocator,
            .type_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DeclTable) void {
        self.type_arena.deinit();
        var it = self.symbols.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .func => |sig| self.allocator.free(sig.params),
                .@"struct" => |sig| {
                    self.allocator.free(sig.fields);
                    self.allocator.free(sig.type_params);
                    var m = sig.methods;
                    var m_it = m.iterator();
                    while (m_it.next()) |method| self.allocator.free(method.value_ptr.params);
                    m.deinit(self.allocator);
                },
                .@"enum" => |sig| self.allocator.free(sig.variants),
                .blueprint => |sig| {
                    for (sig.methods) |method| self.allocator.free(method.params);
                    self.allocator.free(sig.methods);
                },
                .handle, .@"var", .type_alias => {},
            }
        }
        self.symbols.deinit();
    }

    pub fn hasDecl(self: *const DeclTable, name: []const u8) bool {
        return self.symbols.contains(name);
    }
};

/// Returns true if the type annotation is the `type` keyword — indicating a type alias declaration.
fn isTypeAlias(type_annotation: ?*parser.Node) bool {
    const ta = type_annotation orelse return false;
    return ta.* == .type_named and types.Primitive.fromName(ta.type_named) == .@"type";
}

/// The declaration collector
pub const DeclCollector = struct {
    table: DeclTable,
    reporter: *errors.Reporter,
    allocator: std.mem.Allocator,
    locs: ?*const parser.LocMap,
    file_offsets: []const module.FileOffset,
    store: *const AstStore = undefined,

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
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
    }

    pub fn deinit(self: *DeclCollector) void {
        self.table.deinit();
    }

    /// Collect all declarations from a parsed AST
    pub fn collect(
        self: *DeclCollector,
        store: *const AstStore,
        root: AstNodeIndex,
        reverse_map: *const std.AutoHashMap(AstNodeIndex, *parser.Node),
    ) !void {
        self.store = store;
        const prog = ast_typed.Program.unpack(self.store, root);
        const top_level = self.store.extra_data.items[prog.top_level_start..prog.top_level_end];
        for (top_level) |tl_u32| {
            const tl_idx: AstNodeIndex = @enumFromInt(tl_u32);
            const node = reverse_map.get(tl_idx) orelse std.debug.panic(
                "DeclCollector.collect: reverse_map missing AstNodeIndex {}",
                .{@intFromEnum(tl_idx)},
            );
            try self.collectTopLevel(node);
        }
    }

    fn collectTopLevel(self: *DeclCollector, node: *parser.Node) anyerror!void {
        const loc = self.nodeLoc(node);
        switch (node.*) {
            .func_decl => |f| try self.collectFunc(f, loc),
            .struct_decl => |s| try self.collectStruct(s, loc),
            .blueprint_decl => |b| try self.collectBlueprint(b, loc),
            .enum_decl => |e| try self.collectEnum(e, loc),
            .handle_decl => |h| try self.collectHandle(h, loc),
            .var_decl => |v| {
                if (v.mutability == .mutable) {
                    try self.reporter.reportFmt(loc, "module-level 'var' is not allowed — use 'const' for module-level declarations", .{});
                } else {
                    try self.collectVar(v, true, loc);
                }
            },
            else => {},
        }
    }

    /// Resolve function parameter types into a ParamSig slice.
    fn resolveParams(self: *DeclCollector, param_nodes: []*parser.Node) ![]ParamSig {
        var params: std.ArrayListUnmanaged(ParamSig) = .{};
        for (param_nodes) |param| {
            if (param.* == .param) {
                try params.append(self.allocator, .{
                    .name = param.param.name,
                    .type_ = try types.resolveTypeNode(self.table.typeAllocator(), param.param.type_annotation),
                });
            }
        }
        return params.toOwnedSlice(self.allocator);
    }

    fn collectFunc(self: *DeclCollector, f: parser.FuncDecl, loc: ?errors.SourceLoc) anyerror!void {
        var params: std.ArrayListUnmanaged(ParamSig) = .{};
        for (f.params) |param| {
            if (param.* == .param) {
                const param_type = types.resolveTypeNode(self.table.typeAllocator(), param.param.type_annotation) catch |err| {
                    try self.reportUnionError(err, loc, param.param.type_annotation);
                    return;
                };
                try params.append(self.allocator, .{
                    .name = param.param.name,
                    .type_ = param_type,
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
                    try self.reporter.reportFmt(loc, "parameters with defaults must come after all required parameters in '{s}'", .{f.name});
                    break;
                }
            }
        }

        const return_type = types.resolveTypeNode(self.table.typeAllocator(), f.return_type) catch |err| {
            try self.reportUnionError(err, loc, f.return_type);
            return;
        };

        const sig = FuncSig{
            .name = f.name,
            .params = try params.toOwnedSlice(self.allocator),
            .param_nodes = f.params,
            .return_type = return_type,
            .context = f.context,
            .is_pub = f.is_pub,
            .is_instance = false,
        };

        if (self.table.symbols.contains(f.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate function declaration: '{s}'", .{f.name});
            return;
        }

        try self.table.symbols.put(f.name, .{ .func = sig });
    }

    fn collectStruct(self: *DeclCollector, s: parser.StructDecl, loc: ?errors.SourceLoc) anyerror!void {
        var fields: std.ArrayListUnmanaged(FieldSig) = .{};
        for (s.members) |member| {
            // Reject mutable static variables — only const is allowed in structs
            if (member.* == .var_decl and member.var_decl.mutability == .mutable) {
                try self.reporter.reportFmt(loc, "mutable 'var' not allowed in struct '{s}' — use 'const' for static declarations", .{s.name});
            }
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
                try self.reporter.reportFmt(loc, "field name '{s}' conflicts with type name — choose a different name", .{field.name});
            }
            // Check for duplicate field names
            for (fields.items[0..i]) |prev| {
                if (std.mem.eql(u8, field.name, prev.name)) {
                    try self.reporter.reportFmt(loc, "duplicate field '{s}' in struct '{s}'", .{ field.name, s.name });
                    break;
                }
            }
        }

        // Build the per-struct methods map so it can be stored on the StructSig itself.
        var methods_map: StructMethodMap = .{};
        for (s.members) |member| {
            if (member.* == .func_decl) {
                const f = member.func_decl;
                const is_instance = f.params.len > 0 and
                    f.params[0].* == .param and
                    std.mem.eql(u8, f.params[0].param.name, "self");
                const method_sig = FuncSig{
                    .name = f.name,
                    .params = try self.resolveParams(f.params),
                    .param_nodes = f.params,
                    .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
                    .context = f.context,
                    .is_pub = f.is_pub,
                    .is_instance = is_instance,
                };
                try methods_map.put(self.allocator, f.name, method_sig);
            }
        }

        const sig = StructSig{
            .name = s.name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .type_params = try self.resolveParams(s.type_params),
            .conforms_to = s.blueprints,
            .is_pub = s.is_pub,
            .methods = methods_map,
        };

        if (self.table.symbols.contains(s.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate struct declaration: '{s}'", .{s.name});
            return;
        }

        try self.table.symbols.put(s.name, .{ .@"struct" = sig });
    }

    fn collectBlueprint(self: *DeclCollector, b: parser.BlueprintDecl, loc: ?errors.SourceLoc) anyerror!void {
        var methods: std.ArrayListUnmanaged(BlueprintMethodSig) = .{};

        for (b.methods) |member| {
            if (member.* == .func_decl) {
                const f = member.func_decl;
                try methods.append(self.allocator, .{
                    .name = f.name,
                    .params = try self.resolveParams(f.params),
                    .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
                });
            }
        }

        if (self.table.symbols.contains(b.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate blueprint declaration: '{s}'", .{b.name});
            return;
        }

        const bp_sig = BlueprintSig{
            .name = b.name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_pub = b.is_pub,
        };
        try self.table.symbols.put(b.name, .{ .blueprint = bp_sig });
    }

    /// Report a user-facing error for union type resolution failures.
    fn reportUnionError(self: *DeclCollector, err: anyerror, loc: ?errors.SourceLoc, type_node: ?*parser.Node) !void {
        switch (err) {
            error.DuplicateUnionMember => {
                // Try to find the specific duplicate type name
                if (type_node != null and type_node.?.* == .type_union) {
                    if (types.findDuplicateUnionMember(self.allocator, type_node.?.type_union)) |dup_name| {
                        try self.reporter.reportFmt(loc, "duplicate type '{s}' in union — each type may appear only once", .{dup_name});
                        return;
                    }
                }
                try self.reporter.reportFmt(loc, "duplicate type in union — each type may appear only once", .{});
            },
            else => return err,
        }
    }

    fn collectEnum(self: *DeclCollector, e: parser.EnumDecl, loc: ?errors.SourceLoc) anyerror!void {
        var variants: std.ArrayListUnmanaged([]const u8) = .{};
        for (e.members) |member| {
            if (member.* == .enum_variant) {
                // Check for duplicate variant names
                for (variants.items) |prev| {
                    if (std.mem.eql(u8, member.enum_variant.name, prev)) {
                        try self.reporter.reportFmt(loc, "duplicate variant '{s}' in enum '{s}'", .{ member.enum_variant.name, e.name });
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

        if (self.table.symbols.contains(e.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate enum declaration: '{s}'", .{e.name});
            return;
        }

        try self.table.symbols.put(e.name, .{ .@"enum" = sig });
    }

    fn collectHandle(self: *DeclCollector, h: parser.HandleDecl, loc: ?errors.SourceLoc) anyerror!void {
        if (self.table.symbols.contains(h.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate handle declaration: '{s}'", .{h.name});
            return;
        }
        try self.table.symbols.put(h.name, .{ .handle = .{ .name = h.name, .is_pub = h.is_pub } });
    }

    fn collectVar(self: *DeclCollector, v: parser.VarDecl, is_const: bool, loc: ?errors.SourceLoc) anyerror!void {
        // Type alias: const Name: type = T — register in types map, not vars
        if (is_const and isTypeAlias(v.type_annotation)) {
            try self.table.symbols.put(v.name, .{ .type_alias = v.name });
            return;
        }

        const var_type: ?types.ResolvedType = if (v.type_annotation) |t|
            (types.resolveTypeNode(self.table.typeAllocator(), t) catch |err| {
                try self.reportUnionError(err, loc, t);
                return;
            })
        else
            null;

        const sig = VarSig{
            .name = v.name,
            .type_ = var_type,
            .is_const = is_const,
            .is_pub = v.is_pub,
        };

        if (self.table.symbols.contains(v.name)) {
            // Sidecar auto-mapped declarations may duplicate user declarations — skip silently.
            // User definitions (scanned first) take precedence.
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate variable declaration: '{s}'", .{v.name});
            return;
        }

        try self.table.symbols.put(v.name, .{ .@"var" = sig });
    }

};

/// Test helper: convert prog node and run collect via the new AstStore-based API.
fn testCollect(collector: *DeclCollector, prog: *parser.Node) !void {
    const ast_conv_mod = @import("ast_conv.zig");
    var conv = ast_conv_mod.ConvContext.init(collector.allocator);
    defer conv.deinit();
    const root = try ast_conv_mod.convertNode(&conv, prog);
    try collector.collect(&conv.store, root, &conv.reverse_map);
}

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

    const empty_body = try a.create(parser.Node);
    empty_body.* = .{ .block = .{ .statements = &.{} } };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "myFunc",
        .params = &.{},
        .return_type = ret_type,
        .body = empty_body,
        .context = .normal,
        .is_pub = true,
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

    try testCollect(&collector, prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.symbols.contains("myFunc"));
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
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{
        .module = module_node,
        .metadata = &.{},
        .imports = &.{},
        .top_level = top_level,
    }};

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try testCollect(&collector, prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.symbols.contains("Point"));
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
        .context = .normal, .is_pub = false } };

    const func2 = try a.create(parser.Node);
    func2.* = .{ .func_decl = .{ .name = "foo", .params = &.{},
        .return_type = ret_type, .body = empty_block,
        .context = .normal, .is_pub = false } };

    const top_level = try a.alloc(*parser.Node, 2);
    top_level[0] = func1;
    top_level[1] = func2;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try testCollect(&collector, prog);
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
    variant.* = .{ .enum_variant = .{ .name = "Red" } };
    const members = try a.alloc(*parser.Node, 1);
    members[0] = variant;

    const backing = try a.create(parser.Node);
    backing.* = .{ .type_named = "u32" };

    const enum_node = try a.create(parser.Node);
    enum_node.* = .{ .enum_decl = .{ .name = "Color", .backing_type = backing, .members = members, .is_pub = false } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = enum_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try testCollect(&collector, prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.symbols.contains("Color"));
}

test "declaration collector - pub func is registered" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret_type = try a.create(parser.Node);
    ret_type.* = .{ .type_named = "void" };

    const empty_body = try a.create(parser.Node);
    empty_body.* = .{ .block = .{ .statements = &.{} } };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "print",
        .params = &.{},
        .return_type = ret_type,
        .body = empty_body,
        .context = .normal,
        .is_pub = true,
    }};

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = func_node;

    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };

    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node,
        .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();

    try testCollect(&collector, prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.symbols.contains("print"));
}

/// Check if a name conflicts with a primitive or builtin type name.
/// Used to prevent field names like `str`, `i32`, `File` etc.
fn isReservedTypeName(name: []const u8) bool {
    if (types.isPrimitiveName(name)) return true;
    if (types.Primitive.fromName(name) == .err) return true;
    return builtins.isBuiltinType(name);
}

test "DeclTable.symbols map initializes empty" {
    const alloc = std.testing.allocator;
    var reporter = @import("errors.zig").Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var table = DeclTable.init(alloc);
    defer table.deinit();
    try std.testing.expect(table.symbols.count() == 0);
}

test "declaration collector - blueprint" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a blueprint with one method: func equals(self: const& Eq, other: const& Eq) bool
    const self_type = try a.create(parser.Node);
    self_type.* = .{ .type_named = "Eq" };
    const self_ptr = try a.create(parser.Node);
    self_ptr.* = .{ .type_ptr = .{ .kind = .const_ref, .elem = self_type } };
    const other_type = try a.create(parser.Node);
    other_type.* = .{ .type_named = "Eq" };
    const other_ptr = try a.create(parser.Node);
    other_ptr.* = .{ .type_ptr = .{ .kind = .const_ref, .elem = other_type } };

    const p1 = try a.create(parser.Node);
    p1.* = .{ .param = .{ .name = "self", .type_annotation = self_ptr, .default_value = null } };
    const p2 = try a.create(parser.Node);
    p2.* = .{ .param = .{ .name = "other", .type_annotation = other_ptr, .default_value = null } };
    const params = try a.alloc(*parser.Node, 2);
    params[0] = p1;
    params[1] = p2;

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "bool" };
    const empty_body = try a.create(parser.Node);
    empty_body.* = .{ .block = .{ .statements = &.{} } };
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "equals",
        .params = params,
        .return_type = ret,
        .body = empty_body,
        .context = .normal,
        .is_pub = true,
    } };
    const methods = try a.alloc(*parser.Node, 1);
    methods[0] = method;

    const bp_node = try a.create(parser.Node);
    bp_node.* = .{ .blueprint_decl = .{ .name = "Eq", .methods = methods, .is_pub = true } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = bp_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.symbols.contains("Eq"));
    const bp_sig = collector.table.symbols.get("Eq").?.blueprint;
    try std.testing.expectEqual(@as(usize, 1), bp_sig.methods.len);
    try std.testing.expectEqualStrings("equals", bp_sig.methods[0].name);
    try std.testing.expectEqual(@as(usize, 2), bp_sig.methods[0].params.len);
}

test "declaration collector - type alias goes to types map" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // const Alias: type = SomeType
    const type_ann = try a.create(parser.Node);
    type_ann.* = .{ .type_named = "type" };
    const val = try a.create(parser.Node);
    val.* = .{ .identifier = "SomeType" };
    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{
        .name = "Alias",
        .type_annotation = type_ann,
        .value = val,
        .mutability = .constant,
        .is_pub = false,
    } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = var_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(!reporter.hasErrors());
    // Should be stored as type_alias, not as var
    const sym = collector.table.symbols.get("Alias").?;
    try std.testing.expect(sym == .type_alias);
}

test "declaration collector - struct methods registered" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "i32" };
    const empty_body = try a.create(parser.Node);
    empty_body.* = .{ .block = .{ .statements = &.{} } };
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "getX",
        .params = &.{},
        .return_type = ret,
        .body = empty_body,
        .context = .normal,
        .is_pub = true,
    } };

    const field_type = try a.create(parser.Node);
    field_type.* = .{ .type_named = "i32" };
    const field = try a.create(parser.Node);
    field.* = .{ .field_decl = .{
        .name = "x",
        .type_annotation = field_type,
        .default_value = null,
        .is_pub = false,
    } };

    const members = try a.alloc(*parser.Node, 2);
    members[0] = field;
    members[1] = method;

    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{
        .name = "Point",
        .type_params = &.{},
        .members = members,
        .is_pub = false,
    } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = struct_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(!reporter.hasErrors());
    const point_sym = collector.table.symbols.get("Point") orelse return error.TestExpectedSymbol;
    try std.testing.expect(point_sym.@"struct".methods.get("getX") != null);
}

test "declaration collector - field name conflicts with type" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const field_type = try a.create(parser.Node);
    field_type.* = .{ .type_named = "i32" };
    const field = try a.create(parser.Node);
    field.* = .{ .field_decl = .{
        .name = "i32", // conflicts with type name
        .type_annotation = field_type,
        .default_value = null,
        .is_pub = false,
    } };

    const members = try a.alloc(*parser.Node, 1);
    members[0] = field;
    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{
        .name = "Bad",
        .type_params = &.{},
        .members = members,
        .is_pub = false,
    } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = struct_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(reporter.hasErrors());
}

test "declaration collector - duplicate field name" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "i32" };
    const f1 = try a.create(parser.Node);
    f1.* = .{ .field_decl = .{ .name = "x", .type_annotation = t1, .default_value = null, .is_pub = false } };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "i32" };
    const f2 = try a.create(parser.Node);
    f2.* = .{ .field_decl = .{ .name = "x", .type_annotation = t2, .default_value = null, .is_pub = false } };

    const members = try a.alloc(*parser.Node, 2);
    members[0] = f1;
    members[1] = f2;
    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{
        .name = "Bad",
        .type_params = &.{},
        .members = members,
        .is_pub = false,
    } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = struct_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(reporter.hasErrors());
}

test "declaration collector - hasDecl" {
    const alloc = std.testing.allocator;
    var table = DeclTable.init(alloc);
    defer table.deinit();

    try std.testing.expect(!table.hasDecl("foo"));

    try table.symbols.put("foo", .{ .func = .{
        .name = "foo",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal,
        .is_pub = false,
        .is_instance = false,
    } });
    try std.testing.expect(table.hasDecl("foo"));
    try std.testing.expect(!table.hasDecl("bar"));
}

test "declaration collector - rejects var in struct" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // Create a var_decl member (mutable) inside a struct
    const val_node = try a.create(parser.Node);
    val_node.* = .{ .int_literal = "100" };
    const var_member = try a.create(parser.Node);
    var_member.* = .{ .var_decl = .{
        .name = "count",
        .type_annotation = null,
        .value = val_node,
        .is_pub = false,
        .mutability = .mutable,
    } };

    const members = try a.alloc(*parser.Node, 1);
    members[0] = var_member;
    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{
        .name = "Bad",
        .type_params = &.{},
        .members = members,
        .is_pub = false,
    } };

    const top_level = try a.alloc(*parser.Node, 1);
    top_level[0] = struct_node;
    const module_node = try a.create(parser.Node);
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
    const prog = try a.create(parser.Node);
    prog.* = .{ .program = .{ .module = module_node, .metadata = &.{}, .imports = &.{}, .top_level = top_level } };

    var collector = DeclCollector.init(alloc, &reporter);
    defer collector.deinit();
    try testCollect(&collector, prog);

    try std.testing.expect(reporter.hasErrors());
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

test "Symbol.isPub - each variant" {
    const pub_func = Symbol{ .func = .{
        .name = "f", .params = &.{}, .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal, .is_pub = true, .is_instance = false,
    }};
    try std.testing.expect(pub_func.isPub());
    const priv_func = Symbol{ .func = .{
        .name = "f", .params = &.{}, .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal, .is_pub = false, .is_instance = false,
    }};
    try std.testing.expect(!priv_func.isPub());
    const pub_struct = Symbol{ .@"struct" = .{ .name = "S", .fields = &.{}, .is_pub = true } };
    try std.testing.expect(pub_struct.isPub());
    const priv_struct = Symbol{ .@"struct" = .{ .name = "S", .fields = &.{}, .is_pub = false } };
    try std.testing.expect(!priv_struct.isPub());
    const alias = Symbol{ .type_alias = "i64" };
    try std.testing.expect(alias.isPub());
    const pub_var = Symbol{ .@"var" = .{ .name = "v", .type_ = null, .is_const = true, .is_pub = true } };
    try std.testing.expect(pub_var.isPub());
    const priv_var = Symbol{ .@"var" = .{ .name = "v", .type_ = null, .is_const = true, .is_pub = false } };
    try std.testing.expect(!priv_var.isPub());

    const pub_enum = Symbol{ .@"enum" = .{ .name = "E", .backing_type = .{ .primitive = .void }, .variants = &.{}, .is_pub = true } };
    try std.testing.expect(pub_enum.isPub());
    const priv_enum = Symbol{ .@"enum" = .{ .name = "E", .backing_type = .{ .primitive = .void }, .variants = &.{}, .is_pub = false } };
    try std.testing.expect(!priv_enum.isPub());

    const pub_handle = Symbol{ .handle = .{ .name = "H", .is_pub = true } };
    try std.testing.expect(pub_handle.isPub());
    const priv_handle = Symbol{ .handle = .{ .name = "H", .is_pub = false } };
    try std.testing.expect(!priv_handle.isPub());

    const pub_bp = Symbol{ .blueprint = .{ .name = "B", .methods = &.{}, .is_pub = true } };
    try std.testing.expect(pub_bp.isPub());
    const priv_bp = Symbol{ .blueprint = .{ .name = "B", .methods = &.{}, .is_pub = false } };
    try std.testing.expect(!priv_bp.isPub());
}

test "Symbol.isType - each variant" {
    try std.testing.expect((Symbol{ .@"struct" = .{ .name = "S", .fields = &.{}, .is_pub = true } }).isType());
    try std.testing.expect((Symbol{ .@"enum" = .{ .name = "E", .backing_type = .{ .primitive = .void }, .variants = &.{}, .is_pub = true } }).isType());
    try std.testing.expect((Symbol{ .handle = .{ .name = "H", .is_pub = true } }).isType());
    try std.testing.expect((Symbol{ .type_alias = "i64" }).isType());
    try std.testing.expect(!(Symbol{ .func = .{
        .name = "f", .params = &.{}, .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .context = .normal, .is_pub = true, .is_instance = false,
    } }).isType());
    try std.testing.expect(!(Symbol{ .@"var" = .{ .name = "v", .type_ = null, .is_const = true, .is_pub = true } }).isType());
    try std.testing.expect(!(Symbol{ .blueprint = .{ .name = "B", .methods = &.{}, .is_pub = true } }).isType());
}
