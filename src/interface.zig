// interface.zig — Public interface file generation for library modules
//
// When a module is compiled as static or dynamic, emit a pub-only
// `.orh` file into bin/ so consumers can type-check against the API.
// The interface file is valid Orhon — it has the module declaration,
// version, and all pub signatures, but no bodies or private members.

const std = @import("std");
const parser = @import("parser.zig");

// ============================================================
// INTERFACE FILE GENERATION
// ============================================================

/// Write a type node as Orhon source syntax into a buffer
fn formatType(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .type_primitive => |s| try buf.appendSlice(alloc, s),
        .type_named     => |s| try buf.appendSlice(alloc, s),
        .type_slice     => |elem| {
            try buf.appendSlice(alloc, "[]");
            try formatType(elem, buf, alloc);
        },
        .type_array     => |a| {
            try buf.append(alloc, '[');
            try formatExprSimple(a.size, buf, alloc);
            try buf.append(alloc, ']');
            try formatType(a.elem, buf, alloc);
        },
        .type_ptr       => |p| {
            try buf.appendSlice(alloc, if (p.kind == .mut_ref) "mut&" else "const&");
            try formatType(p.elem, buf, alloc);
        },
        .type_union     => |arms| {
            try buf.append(alloc, '(');
            for (arms, 0..) |arm, i| {
                if (i > 0) try buf.appendSlice(alloc, " | ");
                try formatType(arm, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_func      => |f| {
            try buf.appendSlice(alloc, "func(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.appendSlice(alloc, ") ");
            try formatType(f.ret, buf, alloc);
        },
        .type_generic   => |g| {
            try buf.appendSlice(alloc, g.name);
            try buf.append(alloc, '(');
            for (g.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_named => |fields| {
            try buf.append(alloc, '(');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try buf.appendSlice(alloc, f.name);
                try buf.appendSlice(alloc, ": ");
                try formatType(f.type_node, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_anon => |parts| {
            try buf.append(alloc, '(');
            for (parts, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => try buf.appendSlice(alloc, "any"),
    }
}

/// Write simple expressions that appear in type contexts (array sizes, version numbers)
fn formatExprSimple(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .int_literal   => |s| try buf.appendSlice(alloc, s),
        .float_literal => |s| try buf.appendSlice(alloc, s),
        .identifier    => |s| try buf.appendSlice(alloc, s),
        .tuple_literal  => |t| {
            try buf.append(alloc, '(');
            for (t.fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatExprSimple(f, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .call_expr     => |c| {
            if (c.callee.* == .identifier) try buf.appendSlice(alloc, c.callee.identifier);
            try buf.append(alloc, '(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatExprSimple(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => {},
    }
}

/// Write a function signature (no body) into a buffer
fn emitFuncSig(f: parser.FuncDecl, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, indent: []const u8) anyerror!void {
    try buf.appendSlice(alloc, indent);
    if (f.is_pub) try buf.appendSlice(alloc, "pub ");
    if (f.context == .compt) try buf.appendSlice(alloc, "compt ");
    try buf.appendSlice(alloc, "func ");
    try buf.appendSlice(alloc, f.name);
    try buf.append(alloc, '(');
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        const param = p.param;
        try buf.appendSlice(alloc, param.name);
        try buf.appendSlice(alloc, ": ");
        try formatType(param.type_annotation, buf, alloc);
    }
    try buf.appendSlice(alloc, ") ");
    try formatType(f.return_type, buf, alloc);
    try buf.append(alloc, '\n');
}

/// Emit one top-level pub declaration into a buffer (skip private)
fn emitInterfaceDecl(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .func_decl => |f| {
            if (!f.is_pub) return;
            try emitFuncSig(f, buf, alloc, "");
            try buf.append(alloc, '\n');
        },
        .struct_decl => |s| {
            if (!s.is_pub) return;
            try buf.appendSlice(alloc, "pub struct ");
            try buf.appendSlice(alloc, s.name);
            try buf.appendSlice(alloc, " {\n");
            for (s.members) |m| {
                switch (m.*) {
                    .field_decl => |fd| {
                        if (!fd.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub ");
                        try buf.appendSlice(alloc, fd.name);
                        try buf.appendSlice(alloc, ": ");
                        try formatType(fd.type_annotation, buf, alloc);
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    .var_decl => |v| {
                        if (!v.is_pub) continue;
                        const kw = if (v.mutability == .constant) "const " else "var ";
                        try buf.appendSlice(alloc, "    pub ");
                        try buf.appendSlice(alloc, kw);
                        try buf.appendSlice(alloc, v.name);
                        if (v.type_annotation) |t| {
                            try buf.appendSlice(alloc, ": ");
                            try formatType(t, buf, alloc);
                        }
                        try buf.append(alloc, '\n');
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .enum_decl => |e| {
            if (!e.is_pub) return;
            try buf.appendSlice(alloc, "pub enum ");
            try buf.appendSlice(alloc, e.name);
            try buf.append(alloc, '(');
            try formatType(e.backing_type, buf, alloc);
            try buf.appendSlice(alloc, ") {\n");
            for (e.members) |m| {
                switch (m.*) {
                    .enum_variant => |v| {
                        try buf.appendSlice(alloc, "    ");
                        try buf.appendSlice(alloc, v.name);
                        if (v.value) |val| {
                            try buf.appendSlice(alloc, " = ");
                            if (val.* == .int_literal) {
                                try buf.appendSlice(alloc, val.int_literal);
                            }
                        }
                        if (v.fields.len > 0) {
                            try buf.append(alloc, '(');
                            for (v.fields, 0..) |f, i| {
                                if (i > 0) try buf.appendSlice(alloc, ", ");
                                const p = f.param;
                                try buf.appendSlice(alloc, p.name);
                                try buf.appendSlice(alloc, ": ");
                                try formatType(p.type_annotation, buf, alloc);
                            }
                            try buf.append(alloc, ')');
                        }
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .var_decl => |v| {
            if (!v.is_pub) return;
            const kw = if (v.mutability == .constant) "const " else "var ";
            try buf.appendSlice(alloc, "pub ");
            try buf.appendSlice(alloc, kw);
            try buf.appendSlice(alloc, v.name);
            if (v.type_annotation) |t| {
                try buf.appendSlice(alloc, ": ");
                try formatType(t, buf, alloc);
            }
            try buf.appendSlice(alloc, " = ");
            try formatExprSimple(v.value, buf, alloc);
            try buf.append(alloc, '\n');
            try buf.append(alloc, '\n');
        },
        else => {},
    }
}

// ============================================================
// TESTS
// ============================================================

fn testFormatType(alloc: std.mem.Allocator, node: *parser.Node) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    try formatType(node, &buf, alloc);
    return buf.toOwnedSlice(alloc);
}

test "formatType - primitive" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const node = try a.create(parser.Node);
    node.* = .{ .type_primitive = "i32" };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("i32", result);
}

test "formatType - named" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const node = try a.create(parser.Node);
    node.* = .{ .type_named = "Point" };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("Point", result);
}

test "formatType - slice" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "u8" };
    const node = try a.create(parser.Node);
    node.* = .{ .type_slice = elem };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[]u8", result);
}

test "formatType - array" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "f32" };
    const size = try a.create(parser.Node);
    size.* = .{ .int_literal = "3" };
    const node = try a.create(parser.Node);
    node.* = .{ .type_array = .{ .size = size, .elem = elem } };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("[3]f32", result);
}

test "formatType - ptr const ref" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "Point" };
    const node = try a.create(parser.Node);
    node.* = .{ .type_ptr = .{ .kind = .const_ref, .elem = elem } };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("const&Point", result);
}

test "formatType - ptr mut ref" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const elem = try a.create(parser.Node);
    elem.* = .{ .type_named = "Point" };
    const node = try a.create(parser.Node);
    node.* = .{ .type_ptr = .{ .kind = .mut_ref, .elem = elem } };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("mut&Point", result);
}

test "formatType - union" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "Error" };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "i32" };
    const arms = try a.alloc(*parser.Node, 2);
    arms[0] = t1;
    arms[1] = t2;
    const node = try a.create(parser.Node);
    node.* = .{ .type_union = arms };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("(Error | i32)", result);
}

test "formatType - generic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const arg = try a.create(parser.Node);
    arg.* = .{ .type_named = "i32" };
    const args = try a.alloc(*parser.Node, 1);
    args[0] = arg;
    const node = try a.create(parser.Node);
    node.* = .{ .type_generic = .{ .name = "List", .args = args } };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("List(i32)", result);
}

test "formatType - func type" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const p1 = try a.create(parser.Node);
    p1.* = .{ .type_named = "i32" };
    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "bool" };
    const params = try a.alloc(*parser.Node, 1);
    params[0] = p1;
    const node = try a.create(parser.Node);
    node.* = .{ .type_func = .{ .params = params, .ret = ret } };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("func(i32) bool", result);
}

test "formatType - tuple named" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "i32" };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "str" };
    const fields = try a.alloc(parser.NamedTypeField, 2);
    fields[0] = .{ .name = "x", .type_node = t1, .default = null };
    fields[1] = .{ .name = "y", .type_node = t2, .default = null };
    const node = try a.create(parser.Node);
    node.* = .{ .type_tuple_named = fields };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("(x: i32, y: str)", result);
}

test "formatType - tuple anon" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const t1 = try a.create(parser.Node);
    t1.* = .{ .type_named = "i32" };
    const t2 = try a.create(parser.Node);
    t2.* = .{ .type_named = "str" };
    const parts = try a.alloc(*parser.Node, 2);
    parts[0] = t1;
    parts[1] = t2;
    const node = try a.create(parser.Node);
    node.* = .{ .type_tuple_anon = parts };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("(i32, str)", result);
}

test "formatType - unknown node falls back to any" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const node = try a.create(parser.Node);
    node.* = .{ .identifier = "x" };
    const result = try testFormatType(alloc, node);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("any", result);
}

test "emitInterfaceDecl - pub func" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "void" };
    const pt = try a.create(parser.Node);
    pt.* = .{ .type_named = "i32" };
    const param = try a.create(parser.Node);
    param.* = .{ .param = .{ .name = "x", .type_annotation = pt, .default_value = null } };
    const params = try a.alloc(*parser.Node, 1);
    params[0] = param;

    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "doStuff",
        .params = params,
        .return_type = ret,
        .body = undefined,
        .context = .normal,
        .is_pub = true,
    } };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try emitInterfaceDecl(func_node, &buf, alloc);
    try std.testing.expectEqualStrings("pub func doStuff(x: i32) void\n\n", buf.items);
}

test "emitInterfaceDecl - private func skipped" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "void" };
    const func_node = try a.create(parser.Node);
    func_node.* = .{ .func_decl = .{
        .name = "helper",
        .params = &.{},
        .return_type = ret,
        .body = undefined,
        .context = .normal,
        .is_pub = false,
    } };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try emitInterfaceDecl(func_node, &buf, alloc);
    try std.testing.expectEqualStrings("", buf.items);
}

test "emitInterfaceDecl - pub struct with pub field and method" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const field_type = try a.create(parser.Node);
    field_type.* = .{ .type_named = "f64" };
    const field = try a.create(parser.Node);
    field.* = .{ .field_decl = .{
        .name = "x",
        .type_annotation = field_type,
        .default_value = null,
        .is_pub = true,
    } };

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "f64" };
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "getX",
        .params = &.{},
        .return_type = ret,
        .body = undefined,
        .context = .normal,
        .is_pub = true,
    } };

    const members = try a.alloc(*parser.Node, 2);
    members[0] = field;
    members[1] = method;

    const struct_node = try a.create(parser.Node);
    struct_node.* = .{ .struct_decl = .{
        .name = "Point",
        .type_params = &.{},
        .members = members,
        .is_pub = true,
    } };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try emitInterfaceDecl(struct_node, &buf, alloc);

    const expected =
        \\pub struct Point {
        \\    pub x: f64
        \\    pub func getX() f64
        \\}
        \\
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "emitInterfaceDecl - pub enum with variants and method" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const v1 = try a.create(parser.Node);
    v1.* = .{ .enum_variant = .{ .name = "Red", .fields = &.{} } };
    const val = try a.create(parser.Node);
    val.* = .{ .int_literal = "2" };
    const v2 = try a.create(parser.Node);
    v2.* = .{ .enum_variant = .{ .name = "Blue", .value = val, .fields = &.{} } };

    const ret = try a.create(parser.Node);
    ret.* = .{ .type_named = "str" };
    const method = try a.create(parser.Node);
    method.* = .{ .func_decl = .{
        .name = "name",
        .params = &.{},
        .return_type = ret,
        .body = undefined,
        .context = .normal,
        .is_pub = true,
    } };

    const backing = try a.create(parser.Node);
    backing.* = .{ .type_named = "u8" };
    const members = try a.alloc(*parser.Node, 3);
    members[0] = v1;
    members[1] = v2;
    members[2] = method;

    const enum_node = try a.create(parser.Node);
    enum_node.* = .{ .enum_decl = .{
        .name = "Color",
        .backing_type = backing,
        .members = members,
        .is_pub = true,
    } };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try emitInterfaceDecl(enum_node, &buf, alloc);

    const expected =
        \\pub enum Color(u8) {
        \\    Red
        \\    Blue = 2
        \\    pub func name() str
        \\}
        \\
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "emitInterfaceDecl - pub var" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const type_ann = try a.create(parser.Node);
    type_ann.* = .{ .type_named = "i32" };
    const val = try a.create(parser.Node);
    val.* = .{ .int_literal = "42" };

    const var_node = try a.create(parser.Node);
    var_node.* = .{ .var_decl = .{
        .name = "MAX",
        .type_annotation = type_ann,
        .value = val,
        .is_pub = true,
        .mutability = .constant,
    } };

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try emitInterfaceDecl(var_node, &buf, alloc);
    try std.testing.expectEqualStrings("pub const MAX: i32 = 42\n\n", buf.items);
}

/// Generate a pub-only interface `.orh` file into `bin/<binary_name>.orh`.
/// Called after a successful static or dynamic library build.
pub fn generateInterface(
    alloc: std.mem.Allocator,
    mod_name: []const u8,
    binary_name: []const u8,
    ast: *parser.Node,
) !void {
    if (ast.* != .program) return;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    // Header comment + module declaration
    try buf.appendSlice(alloc, "// Orhon interface file — generated by orhon, do not edit\n\n");
    try buf.appendSlice(alloc, "module ");
    try buf.appendSlice(alloc, mod_name);
    try buf.appendSlice(alloc, "\n\n");

    // Version from metadata
    for (ast.program.metadata) |meta| {
        if (meta.metadata.field == .version) {
            try buf.appendSlice(alloc, "#version = ");
            try formatExprSimple(meta.metadata.value, &buf, alloc);
            try buf.appendSlice(alloc, "\n\n");
            break;
        }
    }

    // Public declarations
    for (ast.program.top_level) |node| {
        try emitInterfaceDecl(node, &buf, alloc);
    }

    // Write to bin/<binary_name>.orh
    try std.fs.cwd().makePath("bin");
    const path = try std.fmt.allocPrint(alloc, "bin/{s}.orh", .{binary_name});
    defer alloc.free(path);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}
