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

/// A function signature
pub const FuncSig = struct {
    name: []const u8,
    params: []ParamSig,
    param_nodes: []*parser.Node, // original AST param nodes (for default values)
    return_type: types.ResolvedType,
    return_type_node: *parser.Node, // original AST node (used by codegen)
    context: parser.FuncContext,
    is_pub: bool,
    is_instance: bool, // true when first param is named "self" (instance method receiver)
};

pub const ParamSig = struct {
    name: []const u8,
    type_: types.ResolvedType,
};

/// A struct declaration summary
pub const StructSig = struct {
    name: []const u8,
    fields: []FieldSig,
    conforms_to: []const []const u8 = &.{},
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

/// The declaration table for a module
pub const DeclTable = struct {
    funcs: std.StringHashMap(FuncSig),
    structs: std.StringHashMap(StructSig),
    enums: std.StringHashMap(EnumSig),
    handles: std.StringHashMap(HandleSig),
    vars: std.StringHashMap(VarSig),
    types: std.StringHashMap([]const u8), // type aliases and compt types
    blueprints: std.StringHashMap(BlueprintSig),
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
            .handles = std.StringHashMap(HandleSig).init(allocator),
            .vars = std.StringHashMap(VarSig).init(allocator),
            .types = std.StringHashMap([]const u8).init(allocator),
            .blueprints = std.StringHashMap(BlueprintSig).init(allocator),
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
        self.handles.deinit();
        self.vars.deinit();
        self.types.deinit();
        // Free owned slices stored in BlueprintSig values
        {
            var it = self.blueprints.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.methods) |method| {
                    self.allocator.free(method.params);
                }
                self.allocator.free(entry.value_ptr.methods);
            }
            self.blueprints.deinit();
        }
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
               self.handles.contains(name) or
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
        return module.resolveNodeLoc(self.locs, self.file_offsets, node);
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
            .return_type_node = f.return_type,
            .context = f.context,
            .is_pub = f.is_pub,
            .is_instance = false,
        };

        if (self.table.funcs.contains(f.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate function declaration: '{s}'", .{f.name});
            return;
        }

        try self.table.funcs.put(f.name, sig);
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

        const sig = StructSig{
            .name = s.name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .conforms_to = s.blueprints,
            .is_pub = s.is_pub,
        };

        if (self.table.structs.contains(s.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate struct declaration: '{s}'", .{s.name});
            return;
        }

        try self.table.structs.put(s.name, sig);

        // Register struct methods into struct_methods so borrow checker and MIR can
        // detect self parameter mutability for all structs.
        // Key: "StructName.method" to avoid collisions with same-named methods on other structs.
        {
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
                        .return_type_node = f.return_type,
                        .context = f.context,
                        .is_pub = f.is_pub,
                        .is_instance = is_instance,
                    };
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ s.name, f.name });
                    try self.table.struct_methods.put(self.allocator, key, method_sig);
                }
            }
        }
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

        if (self.table.blueprints.contains(b.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate blueprint declaration: '{s}'", .{b.name});
            return;
        }

        try self.table.blueprints.put(b.name, .{
            .name = b.name,
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_pub = b.is_pub,
        });
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

        if (self.table.enums.contains(e.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate enum declaration: '{s}'", .{e.name});
            return;
        }

        try self.table.enums.put(e.name, sig);
    }

    fn collectHandle(self: *DeclCollector, h: parser.HandleDecl, loc: ?errors.SourceLoc) anyerror!void {
        if (self.table.handles.contains(h.name)) {
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate handle declaration: '{s}'", .{h.name});
            return;
        }
        try self.table.handles.put(h.name, .{
            .name = h.name,
            .is_pub = h.is_pub,
        });
    }

    fn collectVar(self: *DeclCollector, v: parser.VarDecl, is_const: bool, loc: ?errors.SourceLoc) anyerror!void {
        // Type alias: const Name: type = T — register in types map, not vars
        if (is_const and isTypeAlias(v.type_annotation)) {
            try self.table.types.put(v.name, v.name);
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

        if (self.table.vars.contains(v.name)) {
            // Sidecar auto-mapped declarations may duplicate user declarations — skip silently.
            // User definitions (scanned first) take precedence.
            if (loc) |l| {
                if (std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)) return;
            }
            try self.reporter.reportFmt(loc, "duplicate variable declaration: '{s}'", .{v.name});
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

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.enums.contains("Color"));
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

    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "print",
        .params = &.{},
        .return_type = ret_type,
        .body = undefined,
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

    try collector.collect(prog);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.funcs.contains("print"));
}

/// Check if a name conflicts with a primitive or builtin type name.
/// Used to prevent field names like `str`, `i32`, `File` etc.
fn isReservedTypeName(name: []const u8) bool {
    if (types.isPrimitiveName(name)) return true;
    if (std.mem.eql(u8, name, K.Type.ERROR)) return true;
    return builtins.isBuiltinType(name);
}

test "DeclTable.blueprints map initializes empty" {
    const alloc = std.testing.allocator;
    var reporter = @import("errors.zig").Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var table = DeclTable.init(alloc);
    defer table.deinit();
    try std.testing.expect(table.blueprints.count() == 0);
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
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "equals",
        .params = params,
        .return_type = ret,
        .body = undefined,
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
    try collector.collect(prog);

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.blueprints.contains("Eq"));
    const bp_sig = collector.table.blueprints.get("Eq").?;
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
    try collector.collect(prog);

    try std.testing.expect(!reporter.hasErrors());
    // Should be in types map, NOT vars map
    try std.testing.expect(collector.table.types.contains("Alias"));
    try std.testing.expect(!collector.table.vars.contains("Alias"));
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
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "getX",
        .params = &.{},
        .return_type = ret,
        .body = undefined,
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
    try collector.collect(prog);

    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(collector.table.struct_methods.get("Point.getX") != null);
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
    try collector.collect(prog);

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
    try collector.collect(prog);

    try std.testing.expect(reporter.hasErrors());
}

test "declaration collector - hasDecl" {
    const alloc = std.testing.allocator;
    var table = DeclTable.init(alloc);
    defer table.deinit();

    try std.testing.expect(!table.hasDecl("foo"));

    const ret_node = try alloc.create(parser.Node);
    defer alloc.destroy(ret_node);
    ret_node.* = .{ .type_named = "void" };
    try table.funcs.put("foo", .{
        .name = "foo",
        .params = &.{},
        .param_nodes = &.{},
        .return_type = .{ .primitive = .void },
        .return_type_node = ret_node,
        .context = .normal,
        .is_pub = false,
        .is_instance = false,
    });
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
    try collector.collect(prog);

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
