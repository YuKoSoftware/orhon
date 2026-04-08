// codegen_decls.zig — MIR-path declaration generators for the Orhon code generator
// Contains: struct, enum, var/const/compt, test, and func declaration codegen (MIR path).
// All functions receive *CodeGen as first parameter — cross-file calls route through stubs in codegen.zig.

const std = @import("std");
const codegen = @import("codegen.zig");
const parser = @import("../parser.zig");
const mir = @import("../mir/mir.zig");
const declarations = @import("../declarations.zig");
const errors = @import("../errors.zig");
const K = @import("../constants.zig");
const RT = @import("../types.zig").ResolvedType;

const CodeGen = codegen.CodeGen;

// ============================================================
// FUNCTIONS
// ============================================================

/// Emit a re-export for a zig-backed module declaration from the named zig module.
/// Zig source files are registered as named Zig modules with a `_zig` suffix in the build graph.
pub fn generateZigReExport(cg: *CodeGen, name: []const u8, is_pub: bool) anyerror!void {
    const vis = if (is_pub) "pub " else "";
    try cg.emitLineFmt("{s}const {s} = @import(\"{s}_zig\").{s};", .{ vis, name, cg.module_name, name });
}

/// MIR-path function codegen — reads all data from MirNode.
pub fn generateFuncMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const func_name = m.name orelse return;

    // zig-backed module — re-export from zig source module
    if (cg.is_zig_module) return cg.generateZigReExport(func_name, m.is_pub);

    // Body-less declaration — skip codegen.
    // Never skip main or void functions (they can legitimately have empty bodies).
    const body_m = m.body();
    const is_void_ret = if (m.return_type) |rt| rt.* == .type_named and
        std.mem.eql(u8, rt.type_named, K.Type.VOID) else false;
    if (body_m.kind == .block and body_m.children.len == 0 and
        !std.mem.eql(u8, func_name, "main") and !is_void_ret) return;

    // Track current function for MIR return type queries
    const prev_func_mir = cg.current_func_mir;
    cg.current_func_mir = m;
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMir(m.body(), &cg.reassigned_vars, cg.allocator);
    const prev_error_narrowed = cg.error_narrowed;
    cg.error_narrowed = .{};
    const prev_null_narrowed = cg.null_narrowed;
    cg.null_narrowed = .{};
    defer {
        cg.current_func_mir = prev_func_mir;
        cg.reassigned_vars.deinit(cg.allocator);
        cg.reassigned_vars = prev_reassigned_vars;
        cg.error_narrowed.deinit(cg.allocator);
        cg.error_narrowed = prev_error_narrowed;
        cg.null_narrowed.deinit(cg.allocator);
        cg.null_narrowed = prev_null_narrowed;
    }

    const ret_type = m.return_type orelse return;

    // pub modifier
    if (m.is_pub or std.mem.eql(u8, func_name, "main")) try cg.emit("pub ");

    const returns_type = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
    const is_type_generic = m.is_compt and returns_type;

    if (m.is_compt and !is_type_generic) {
        try cg.emitFmt("inline fn {s}(", .{func_name});
    } else {
        try cg.emitFmt("fn {s}(", .{func_name});
    }

    // Parameters
    var first_any_param: ?[]const u8 = null;
    for (m.params(), 0..) |param_m, i| {
        if (i > 0) try cg.emit(", ");
        const pname = param_m.name orelse continue;
        const pta = param_m.type_annotation orelse continue;
        const is_any = pta.* == .type_named and
            std.mem.eql(u8, pta.type_named, K.Type.ANY);
        const is_type_param = pta.* == .type_named and
            std.mem.eql(u8, pta.type_named, K.Type.TYPE);
        if (is_any and first_any_param == null) first_any_param = pname;
        if (is_type_param) {
            try cg.emitFmt("comptime {s}: type", .{pname});
        } else if (is_type_generic and is_any) {
            try cg.emitFmt("comptime {s}: anytype", .{pname});
        } else if (is_any) {
            try cg.emitFmt("{s}: anytype", .{pname});
        } else {
            const zig_type = try cg.typeToZig(pta);
            try cg.emitFmt("{s}: {s}", .{ pname, zig_type });
        }
    }

    try cg.emit(") ");

    // Return type
    const return_is_any = ret_type.* == .type_named and
        std.mem.eql(u8, ret_type.type_named, K.Type.ANY);
    if (return_is_any) {
        if (first_any_param) |pname| {
            try cg.emitFmt("@TypeOf({s})", .{pname});
        } else {
            try cg.emit("anyopaque");
        }
    } else {
        try cg.emit(try cg.typeToZig(ret_type));
    }
    try cg.emit(" ");

    // Body
    try cg.generateBlockMir(body_m);
    try cg.emit("\n");
}

/// MIR-path collectAssigned — traverses MirNode tree.
pub fn collectAssignedMir(m: *mir.MirNode, set: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) anyerror!void {
    switch (m.kind) {
        .assignment => {
            if (getRootIdentMir(m.lhs())) |name| try set.put(alloc, name, {});
            try collectAssignedMir(m.rhs(), set, alloc);
        },
        .call => {
            const callee_m = m.getCallee();
            if (callee_m.kind == .field_access) {
                if (callee_m.children.len > 0) {
                    if (getRootIdentMir(callee_m.children[0])) |name| {
                        try set.put(alloc, name, {});
                    }
                }
            }
            for (m.callArgs()) |arg| try collectAssignedMir(arg, set, alloc);
        },
        .block => {
            for (m.children) |child| try collectAssignedMir(child, set, alloc);
        },
        .func => {}, // nested function — own scope
        .if_stmt => {
            try collectAssignedMir(m.condition(), set, alloc);
            if (m.children.len > 1) try collectAssignedMir(m.thenBlock(), set, alloc);
            if (m.elseBlock()) |e| try collectAssignedMir(e, set, alloc);
        },
        .while_stmt => {
            try collectAssignedMir(m.condition(), set, alloc);
            try collectAssignedMir(m.children[1], set, alloc);
            if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
        },
        .for_stmt => try collectAssignedMir(m.body(), set, alloc),
        .slice => {
            if (m.children.len > 0 and m.children[0].kind == .identifier) {
                if (m.children[0].name) |name| try set.put(alloc, name, {});
            }
            if (m.children.len > 1) try collectAssignedMir(m.children[1], set, alloc);
            if (m.children.len > 2) try collectAssignedMir(m.children[2], set, alloc);
        },
        .var_decl => {
            if (m.children.len > 0) try collectAssignedMir(m.value(), set, alloc);
        },
        .match_stmt => {
            for (m.matchArms()) |arm_mir| {
                try collectAssignedMir(arm_mir.body(), set, alloc);
            }
        },
        .defer_stmt => try collectAssignedMir(m.body(), set, alloc),
        else => {
            for (m.children) |child| try collectAssignedMir(child, set, alloc);
        },
    }
}

pub fn getRootIdentMir(m: *const mir.MirNode) ?[]const u8 {
    return switch (m.kind) {
        .identifier => m.name,
        .field_access => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
        .index => if (m.children.len > 0) getRootIdentMir(m.children[0]) else null,
        else => null,
    };
}

// ============================================================
// STRUCTS
// ============================================================

/// MIR-path struct codegen — iterates MirNode children instead of AST members.
pub fn generateStructMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const struct_name = m.name orelse return;
    if (cg.is_zig_module) return cg.generateZigReExport(struct_name, m.is_pub);

    const tp = m.type_params;
    const is_generic = tp != null and tp.?.len > 0;

    const prev_in_struct = cg.in_struct;
    cg.in_struct = true;
    defer cg.in_struct = prev_in_struct;

    if (is_generic) {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("fn {s}(", .{struct_name});
        for (tp.?, 0..) |param, i| {
            if (i > 0) try cg.emit(", ");
            if (param.* == .param) {
                try cg.emitFmt("comptime {s}: type", .{param.param.name});
            }
        }
        try cg.emit(") type {\n");
        cg.indent += 1;
        try cg.emitIndent();
        try cg.emit("return struct {\n");
        cg.indent += 1;
        cg.generic_struct_name = struct_name;
    } else {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = struct {{\n", .{struct_name});
        cg.indent += 1;
    }

    try emitStructBody(cg, m.children);

    if (is_generic) {
        cg.generic_struct_name = null;
        cg.indent -= 1;
        try cg.emitIndent();
        try cg.emit("};\n");
        cg.indent -= 1;
        try cg.emit("}\n");
    } else {
        cg.indent -= 1;
        try cg.emit("};\n");
    }
}

/// Emit the body of a struct (fields, methods, constants) from MIR children.
/// Used by both named structs and anonymous struct expressions.
pub fn emitStructBody(cg: *CodeGen, children: []*mir.MirNode) anyerror!void {
    for (children) |child| {
        switch (child.kind) {
            .field_def => {
                const fname = child.name orelse continue;
                try cg.emitIndent();
                try cg.emitFmt("{s}: {s}", .{ fname, try cg.typeToZig(child.type_annotation orelse continue) });
                if (child.defaultChild()) |dv_mir| {
                    try cg.emit(" = ");
                    try cg.generateExprMir(dv_mir);
                }
                try cg.emit(",\n");
            },
            .func => {
                const prev = cg.current_func_mir;
                cg.current_func_mir = child;
                defer cg.current_func_mir = prev;
                try cg.generateFuncMir(child);
            },
            .var_decl => {
                const decl_kw: []const u8 = if (child.is_const) "const" else "var";
                const cname = child.name orelse continue;
                try cg.emitIndent();
                try cg.emitFmt("{s} {s}", .{ decl_kw, cname });
                if (child.type_annotation) |t| try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
                try cg.emit(" = ");
                try cg.generateExprMir(child.value());
                try cg.emit(";\n");
            },
            else => {},
        }
    }
}

// ============================================================
// ENUMS
// ============================================================

/// MIR-path enum codegen — iterates MirNode children instead of AST members.
pub fn generateEnumMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const enum_name = m.name orelse return;
    if (m.is_pub) try cg.emit("pub ");

    const backing = try cg.typeToZig(m.backing_type orelse return);

    try cg.emitFmt("const {s} = enum({s}) {{\n", .{ enum_name, backing });
    cg.indent += 1;

    for (m.children) |child| {
        switch (child.kind) {
            .enum_variant_def => {
                const vname = child.name orelse continue;
                try cg.emitIndent();
                if (child.literal) |lit| {
                    try cg.emitFmt("{s} = {s},\n", .{ vname, lit });
                } else {
                    try cg.emitFmt("{s},\n", .{vname});
                }
            },
            else => {},
        }
    }

    cg.indent -= 1;
    try cg.emit("};\n");
}

// ============================================================
// VARIABLE DECLARATIONS
// ============================================================

/// Returns true if the type annotation is the `type` keyword — indicating a type alias declaration.
pub fn isTypeAlias(type_annotation: ?*parser.Node) bool {
    const ta = type_annotation orelse return false;
    return ta.* == .type_named and std.mem.eql(u8, ta.type_named, K.Type.TYPE);
}

/// MIR-path top-level var/const/compt declaration.
pub fn generateTopLevelDeclMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const name = m.name orelse return;
    if (cg.is_zig_module) return cg.generateZigReExport(name, m.is_pub);

    // Type alias: const Name: type = T → const Name = ZigType;
    if (m.is_const and isTypeAlias(m.type_annotation)) {
        if (m.is_pub) try cg.emit("pub ");
        try cg.emitFmt("const {s} = ", .{name});
        try cg.emit(try cg.typeToZig(m.value().ast)); // type trees are structural — typeToZig walks AST
        try cg.emit(";\n");
        return;
    }

    const decl_keyword: []const u8 = if (m.is_const) "const" else "var";
    if (m.is_pub) try cg.emit("pub ");
    try cg.emitFmt("{s} {s}", .{ decl_keyword, name });
    if (m.type_annotation) |t| {
        try cg.emitFmt(": {s}", .{try cg.typeToZig(t)});
    }
    try cg.emit(" = ");
    if (m.type_class == .arbitrary_union) {
        try cg.generateCoercedExprMir(m.value());
    } else if (m.value().kind == .type_expr) {
        // Type in expression position = default constructor (.{})
        try cg.emit(".{}");
    } else {
        // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
        try cg.generateExprMir(m.value());
    }
    try cg.emit(";\n");
}

// ============================================================
// TESTS
// ============================================================

pub fn generateTestMir(cg: *CodeGen, m: *mir.MirNode) anyerror!void {
    const description = m.name orelse return;
    try cg.emitFmt("test {s} ", .{description});
    const prev_reassigned_vars = cg.reassigned_vars;
    cg.reassigned_vars = .{};
    try collectAssignedMir(m.body(), &cg.reassigned_vars, cg.allocator);
    cg.in_test_block = true;
    try cg.generateBlockMir(m.body());
    cg.in_test_block = false;
    cg.reassigned_vars.deinit(cg.allocator);
    cg.reassigned_vars = prev_reassigned_vars;
    try cg.emit("\n");
}
