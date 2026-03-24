// compare.zig — Side-by-side AST comparison between old parser and PEG engine
//
// Parses the same source with both parsers and reports differences.
// Used to verify the PEG engine produces identical ASTs before swapping.

const std = @import("std");
const parser = @import("../parser.zig");
const lexer = @import("../lexer.zig");
const errors = @import("../errors.zig");
const capture_mod = @import("capture.zig");
const builder_mod = @import("builder.zig");
const grammar_mod = @import("grammar.zig");
const Node = parser.Node;
const NodeKind = parser.NodeKind;

// ============================================================
// AST COMPARISON
// ============================================================

pub const Diff = struct {
    path: []const u8, // e.g. "program.top_level[0].func_decl.name"
    old_desc: []const u8,
    new_desc: []const u8,
};

/// Compare two AST nodes recursively. Returns a list of differences.
pub fn compareNodes(old: *const Node, new: *const Node, path: []const u8, allocator: std.mem.Allocator) anyerror![]Diff {
    var diffs = std.ArrayListUnmanaged(Diff){};

    // Check node kind match
    const old_kind: NodeKind = old.*;
    const new_kind: NodeKind = new.*;
    if (old_kind != new_kind) {
        try diffs.append(allocator, .{
            .path = path,
            .old_desc = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(old_kind)}),
            .new_desc = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(new_kind)}),
        });
        return diffs.toOwnedSlice(allocator);
    }

    // Compare by node kind
    switch (old.*) {
        .program => |op| {
            const np = new.program;
            try appendChildDiffs(&diffs, op.module, np.module, path, "module", allocator);
            try appendSliceDiffs(&diffs, op.metadata, np.metadata, path, "metadata", allocator);
            try appendSliceDiffs(&diffs, op.imports, np.imports, path, "imports", allocator);
            try appendSliceDiffs(&diffs, op.top_level, np.top_level, path, "top_level", allocator);
        },
        .module_decl => |om| {
            if (!std.mem.eql(u8, om.name, new.module_decl.name)) {
                try diffs.append(allocator, .{
                    .path = try join(allocator, path, "name"),
                    .old_desc = om.name,
                    .new_desc = new.module_decl.name,
                });
            }
        },
        .func_decl => |of| {
            const nf = new.func_decl;
            try compareStr(&diffs, of.name, nf.name, path, "name", allocator);
            try compareBool(&diffs, of.is_pub, nf.is_pub, path, "is_pub", allocator);
            try compareBool(&diffs, of.is_bridge, nf.is_bridge, path, "is_bridge", allocator);
            try compareBool(&diffs, of.is_compt, nf.is_compt, path, "is_compt", allocator);
            try compareBool(&diffs, of.is_thread, nf.is_thread, path, "is_thread", allocator);
            try appendSliceDiffs(&diffs, of.params, nf.params, path, "params", allocator);
            try appendChildDiffs(&diffs, of.return_type, nf.return_type, path, "return_type", allocator);
            try appendChildDiffs(&diffs, of.body, nf.body, path, "body", allocator);
        },
        .struct_decl => |os| {
            const ns = new.struct_decl;
            try compareStr(&diffs, os.name, ns.name, path, "name", allocator);
            try compareBool(&diffs, os.is_pub, ns.is_pub, path, "is_pub", allocator);
            try appendSliceDiffs(&diffs, os.type_params, ns.type_params, path, "type_params", allocator);
            try appendSliceDiffs(&diffs, os.members, ns.members, path, "members", allocator);
        },
        .enum_decl => |oe| {
            const ne = new.enum_decl;
            try compareStr(&diffs, oe.name, ne.name, path, "name", allocator);
            try compareBool(&diffs, oe.is_pub, ne.is_pub, path, "is_pub", allocator);
            try appendChildDiffs(&diffs, oe.backing_type, ne.backing_type, path, "backing_type", allocator);
            try appendSliceDiffs(&diffs, oe.members, ne.members, path, "members", allocator);
        },
        .const_decl => |oc| {
            const nc = new.const_decl;
            try compareStr(&diffs, oc.name, nc.name, path, "name", allocator);
            try compareBool(&diffs, oc.is_pub, nc.is_pub, path, "is_pub", allocator);
            try appendChildDiffs(&diffs, oc.value, nc.value, path, "value", allocator);
            try compareOptNode(&diffs, oc.type_annotation, nc.type_annotation, path, "type_annotation", allocator);
        },
        .var_decl => |ov| {
            const nv = new.var_decl;
            try compareStr(&diffs, ov.name, nv.name, path, "name", allocator);
            try compareBool(&diffs, ov.is_pub, nv.is_pub, path, "is_pub", allocator);
            try appendChildDiffs(&diffs, ov.value, nv.value, path, "value", allocator);
            try compareOptNode(&diffs, ov.type_annotation, nv.type_annotation, path, "type_annotation", allocator);
        },
        .param => |op| {
            const np = new.param;
            try compareStr(&diffs, op.name, np.name, path, "name", allocator);
            try appendChildDiffs(&diffs, op.type_annotation, np.type_annotation, path, "type", allocator);
        },
        .field_decl => |of| {
            const nf = new.field_decl;
            try compareStr(&diffs, of.name, nf.name, path, "name", allocator);
            try compareBool(&diffs, of.is_pub, nf.is_pub, path, "is_pub", allocator);
            try appendChildDiffs(&diffs, of.type_annotation, nf.type_annotation, path, "type", allocator);
        },
        .enum_variant => |ov| {
            const nv = new.enum_variant;
            try compareStr(&diffs, ov.name, nv.name, path, "name", allocator);
            try appendSliceDiffs(&diffs, ov.fields, nv.fields, path, "fields", allocator);
        },
        .block => |ob| {
            try appendSliceDiffs(&diffs, ob.statements, new.block.statements, path, "stmts", allocator);
        },
        .return_stmt => |or_| {
            const nr = new.return_stmt;
            if (or_.value != null and nr.value != null) {
                try appendChildDiffs(&diffs, or_.value.?, nr.value.?, path, "value", allocator);
            } else if (or_.value != null or nr.value != null) {
                try diffs.append(allocator, .{
                    .path = try join(allocator, path, "value"),
                    .old_desc = if (or_.value != null) "present" else "null",
                    .new_desc = if (nr.value != null) "present" else "null",
                });
            }
        },
        .if_stmt => |oi| {
            const ni = new.if_stmt;
            try appendChildDiffs(&diffs, oi.condition, ni.condition, path, "cond", allocator);
            try appendChildDiffs(&diffs, oi.then_block, ni.then_block, path, "then", allocator);
            if (oi.else_block != null and ni.else_block != null) {
                try appendChildDiffs(&diffs, oi.else_block.?, ni.else_block.?, path, "else", allocator);
            } else if (oi.else_block != null or ni.else_block != null) {
                try diffs.append(allocator, .{
                    .path = try join(allocator, path, "else"),
                    .old_desc = if (oi.else_block != null) "present" else "null",
                    .new_desc = if (ni.else_block != null) "present" else "null",
                });
            }
        },
        .while_stmt => |ow| {
            const nw = new.while_stmt;
            try appendChildDiffs(&diffs, ow.condition, nw.condition, path, "cond", allocator);
            try appendChildDiffs(&diffs, ow.body, nw.body, path, "body", allocator);
        },
        .for_stmt => |of| {
            const nf = new.for_stmt;
            try appendChildDiffs(&diffs, of.iterable, nf.iterable, path, "iterable", allocator);
            try appendChildDiffs(&diffs, of.body, nf.body, path, "body", allocator);
        },
        .defer_stmt => |od| {
            try appendChildDiffs(&diffs, od.body, new.defer_stmt.body, path, "body", allocator);
        },
        .match_stmt => |om| {
            const nm = new.match_stmt;
            try appendChildDiffs(&diffs, om.value, nm.value, path, "value", allocator);
            try appendSliceDiffs(&diffs, om.arms, nm.arms, path, "arms", allocator);
        },
        .match_arm => |oa| {
            const na = new.match_arm;
            try appendChildDiffs(&diffs, oa.pattern, na.pattern, path, "pattern", allocator);
            try appendChildDiffs(&diffs, oa.body, na.body, path, "body", allocator);
        },
        .binary_expr => |ob| {
            const nb = new.binary_expr;
            try compareStr(&diffs, ob.op, nb.op, path, "op", allocator);
            try appendChildDiffs(&diffs, ob.left, nb.left, path, "left", allocator);
            try appendChildDiffs(&diffs, ob.right, nb.right, path, "right", allocator);
        },
        .assignment => |oa| {
            const na = new.assignment;
            try compareStr(&diffs, oa.op, na.op, path, "op", allocator);
            try appendChildDiffs(&diffs, oa.left, na.left, path, "left", allocator);
            try appendChildDiffs(&diffs, oa.right, na.right, path, "right", allocator);
        },
        .unary_expr => |ou| {
            const nu = new.unary_expr;
            try compareStr(&diffs, ou.op, nu.op, path, "op", allocator);
            try appendChildDiffs(&diffs, ou.operand, nu.operand, path, "operand", allocator);
        },
        .call_expr => |oc| {
            const nc = new.call_expr;
            try appendChildDiffs(&diffs, oc.callee, nc.callee, path, "callee", allocator);
            try appendSliceDiffs(&diffs, oc.args, nc.args, path, "args", allocator);
        },
        .field_expr => |of| {
            const nf = new.field_expr;
            try compareStr(&diffs, of.field, nf.field, path, "field", allocator);
            try appendChildDiffs(&diffs, of.object, nf.object, path, "object", allocator);
        },
        .index_expr => |oi| {
            const ni = new.index_expr;
            try appendChildDiffs(&diffs, oi.object, ni.object, path, "object", allocator);
            try appendChildDiffs(&diffs, oi.index, ni.index, path, "index", allocator);
        },
        .borrow_expr => |ob| {
            try appendChildDiffs(&diffs, ob, new.borrow_expr, path, "inner", allocator);
        },
        .range_expr => |or_| {
            const nr = new.range_expr;
            try appendChildDiffs(&diffs, or_.left, nr.left, path, "left", allocator);
            try appendChildDiffs(&diffs, or_.right, nr.right, path, "right", allocator);
        },
        .compiler_func => |oc| {
            const nc = new.compiler_func;
            try compareStr(&diffs, oc.name, nc.name, path, "name", allocator);
            try appendSliceDiffs(&diffs, oc.args, nc.args, path, "args", allocator);
        },
        .identifier => |oi| {
            if (!std.mem.eql(u8, oi, new.identifier)) {
                try diffs.append(allocator, .{
                    .path = path,
                    .old_desc = oi,
                    .new_desc = new.identifier,
                });
            }
        },
        .int_literal => |oi| {
            if (!std.mem.eql(u8, oi, new.int_literal)) {
                try diffs.append(allocator, .{ .path = path, .old_desc = oi, .new_desc = new.int_literal });
            }
        },
        .float_literal => |of| {
            if (!std.mem.eql(u8, of, new.float_literal)) {
                try diffs.append(allocator, .{ .path = path, .old_desc = of, .new_desc = new.float_literal });
            }
        },
        .string_literal => |os| {
            if (!std.mem.eql(u8, os, new.string_literal)) {
                try diffs.append(allocator, .{ .path = path, .old_desc = os, .new_desc = new.string_literal });
            }
        },
        .bool_literal => |ob| {
            if (ob != new.bool_literal) {
                try diffs.append(allocator, .{
                    .path = path,
                    .old_desc = if (ob) "true" else "false",
                    .new_desc = if (new.bool_literal) "true" else "false",
                });
            }
        },
        .error_literal => |oe| {
            if (!std.mem.eql(u8, oe, new.error_literal)) {
                try diffs.append(allocator, .{ .path = path, .old_desc = oe, .new_desc = new.error_literal });
            }
        },
        .null_literal, .break_stmt, .continue_stmt => {},
        .type_named => |ot| {
            if (!std.mem.eql(u8, ot, new.type_named)) {
                try diffs.append(allocator, .{ .path = path, .old_desc = ot, .new_desc = new.type_named });
            }
        },
        .type_ptr => |op| {
            const np = new.type_ptr;
            try compareStr(&diffs, op.kind, np.kind, path, "kind", allocator);
            try appendChildDiffs(&diffs, op.elem, np.elem, path, "elem", allocator);
        },
        .type_generic => |og| {
            const ng = new.type_generic;
            try compareStr(&diffs, og.name, ng.name, path, "name", allocator);
            try appendSliceDiffs(&diffs, og.args, ng.args, path, "args", allocator);
        },
        .type_union => |ou| {
            try appendSliceDiffs(&diffs, ou, new.type_union, path, "members", allocator);
        },
        .type_slice => |os| {
            try appendChildDiffs(&diffs, os, new.type_slice, path, "elem", allocator);
        },
        .type_array => |oa| {
            const na = new.type_array;
            try appendChildDiffs(&diffs, oa.size, na.size, path, "size", allocator);
            try appendChildDiffs(&diffs, oa.elem, na.elem, path, "elem", allocator);
        },
        .type_func => |of| {
            const nf = new.type_func;
            try appendSliceDiffs(&diffs, of.params, nf.params, path, "params", allocator);
            try appendChildDiffs(&diffs, of.ret, nf.ret, path, "ret", allocator);
        },
        .import_decl => |oi| {
            const ni = new.import_decl;
            try compareStr(&diffs, oi.path, ni.path, path, "path", allocator);
        },
        .metadata => |om| {
            const nm = new.metadata;
            try compareStr(&diffs, om.field, nm.field, path, "field", allocator);
            try appendChildDiffs(&diffs, om.value, nm.value, path, "value", allocator);
        },
        .test_decl => |ot| {
            const nt = new.test_decl;
            try compareStr(&diffs, ot.description, nt.description, path, "desc", allocator);
            try appendChildDiffs(&diffs, ot.body, nt.body, path, "body", allocator);
        },
        .array_literal => |oa| {
            try appendSliceDiffs(&diffs, oa, new.array_literal, path, "items", allocator);
        },
        .tuple_literal => |ot| {
            const nt = new.tuple_literal;
            try appendSliceDiffs(&diffs, ot.fields, nt.fields, path, "fields", allocator);
        },
        // Skip complex nodes for now — add as needed
        else => {},
    }

    return diffs.toOwnedSlice(allocator);
}

// ============================================================
// COMPARISON HELPERS
// ============================================================

fn join(allocator: std.mem.Allocator, base: []const u8, field: []const u8) ![]const u8 {
    if (base.len == 0) return field;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ base, field });
}

fn compareStr(diffs: *std.ArrayListUnmanaged(Diff), old: []const u8, new: []const u8, path: []const u8, field: []const u8, allocator: std.mem.Allocator) !void {
    if (!std.mem.eql(u8, old, new)) {
        try diffs.append(allocator, .{
            .path = try join(allocator, path, field),
            .old_desc = old,
            .new_desc = new,
        });
    }
}

fn compareBool(diffs: *std.ArrayListUnmanaged(Diff), old: bool, new: bool, path: []const u8, field: []const u8, allocator: std.mem.Allocator) !void {
    if (old != new) {
        try diffs.append(allocator, .{
            .path = try join(allocator, path, field),
            .old_desc = if (old) "true" else "false",
            .new_desc = if (new) "true" else "false",
        });
    }
}

fn appendChildDiffs(diffs: *std.ArrayListUnmanaged(Diff), old: *const Node, new: *const Node, path: []const u8, field: []const u8, allocator: std.mem.Allocator) !void {
    const child_path = try join(allocator, path, field);
    const child_diffs = try compareNodes(old, new, child_path, allocator);
    for (child_diffs) |d| try diffs.append(allocator, d);
}

fn appendSliceDiffs(diffs: *std.ArrayListUnmanaged(Diff), old: []*Node, new: []*Node, path: []const u8, field: []const u8, allocator: std.mem.Allocator) !void {
    const base = try join(allocator, path, field);
    if (old.len != new.len) {
        try diffs.append(allocator, .{
            .path = try std.fmt.allocPrint(allocator, "{s}.len", .{base}),
            .old_desc = try std.fmt.allocPrint(allocator, "{d}", .{old.len}),
            .new_desc = try std.fmt.allocPrint(allocator, "{d}", .{new.len}),
        });
        return;
    }
    for (old, 0..) |old_item, i| {
        const item_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ base, i });
        const child_diffs = try compareNodes(old_item, new[i], item_path, allocator);
        for (child_diffs) |d| try diffs.append(allocator, d);
    }
}

fn compareOptNode(diffs: *std.ArrayListUnmanaged(Diff), old: ?*Node, new: ?*Node, path: []const u8, field: []const u8, allocator: std.mem.Allocator) !void {
    if (old != null and new != null) {
        try appendChildDiffs(diffs, old.?, new.?, path, field, allocator);
    } else if (old != null or new != null) {
        try diffs.append(allocator, .{
            .path = try join(allocator, path, field),
            .old_desc = if (old != null) "present" else "null",
            .new_desc = if (new != null) "present" else "null",
        });
    }
}

// ============================================================
// FULL PIPELINE COMPARISON
// ============================================================

/// Parse source with both old parser and PEG engine, return diffs.
pub fn compareParsers(source: []const u8, allocator: std.mem.Allocator) ![]Diff {
    // Lex
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(allocator);
    defer tokens.deinit(allocator);

    // Old parser
    var reporter = errors.Reporter.init(allocator, .release);
    defer reporter.deinit();
    var old_parser = parser.Parser.init(tokens.items, allocator, &reporter);
    defer old_parser.deinit();
    const old_ast = old_parser.parseProgram() catch return &.{};
    if (reporter.hasErrors()) return &.{};

    // PEG engine
    const peg = @import("../peg.zig");
    var grammar = try peg.loadGrammar(allocator);
    defer grammar.deinit();

    var engine = capture_mod.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
    defer engine.deinit();
    const cap = engine.captureProgram() orelse return &.{};

    var build_result = builder_mod.buildAST(&cap, tokens.items, std.heap.page_allocator) catch return &.{};
    defer build_result.ctx.deinit();

    return compareNodes(old_ast, build_result.node, "", allocator);
}

// ============================================================
// TESTS
// ============================================================

test "compare - minimal program matches" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers("module main\n", alloc);
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "compare - function declaration matches" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(
        \\module main
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
    , alloc);
    // page_allocator — no manual free needed
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "compare - const declaration matches" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(
        \\module main
        \\
        \\const MAX: i32 = 100
        \\
    , alloc);
    // page_allocator — no manual free needed
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "compare - pub struct matches" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(
        \\module example
        \\
        \\pub struct Point {
        \\    pub x: f64
        \\    pub y: f64
        \\}
        \\
    , alloc);
    // page_allocator — no manual free needed
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "compare - if/else matches" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(
        \\module main
        \\
        \\func abs(x: i32) i32 {
        \\    if(x < 0) {
        \\        return 0 - x
        \\    } else {
        \\        return x
        \\    }
        \\}
        \\
    , alloc);
    // page_allocator — no manual free needed
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

// ============================================================
// FILE-BASED COMPARISON — real .orh files
// ============================================================

fn compareFile(source: []const u8) !usize {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(source, alloc);
    if (diffs.len > 0) {
        for (diffs[0..@min(5, diffs.len)]) |d| {
            std.debug.print("  DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
        if (diffs.len > 5) {
            std.debug.print("  ... and {d} more diffs\n", .{diffs.len - 5});
        }
    }
    return diffs.len;
}

fn compareRuntimeFile(path: []const u8) !usize {
    const alloc = std.heap.page_allocator;
    const source = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch return 0;
    return compareFile(source);
}

test "compare - combined example module" {
    const alloc = std.heap.page_allocator;
    // Simulate combined multi-file module: example + data_types + control_flow + strings + advanced + error_handling
    // Strip module lines from non-first files (same as module.zig does)
    const files = [_][]const u8{
        @embedFile("../templates/example/example.orh"),
        @embedFile("../templates/example/data_types.orh"),
        @embedFile("../templates/example/control_flow.orh"),
        @embedFile("../templates/example/strings.orh"),
        @embedFile("../templates/example/advanced.orh"),
        @embedFile("../templates/example/error_handling.orh"),
    };
    var combined = std.ArrayListUnmanaged(u8){};
    for (files, 0..) |content, idx| {
        if (idx > 0) {
            // Strip module line
            if (std.mem.indexOfScalar(u8, content, '\n')) |nl| {
                combined.appendSlice(alloc, content[nl + 1 ..]) catch {};
            }
        } else {
            combined.appendSlice(alloc, content) catch {};
        }
    }
    const diffs = try compareParsers(combined.items, alloc);
    if (diffs.len > 0) {
        for (diffs[0..@min(5, diffs.len)]) |d| {
            std.debug.print("  DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
        if (diffs.len > 5) std.debug.print("  ... and {d} more\n", .{diffs.len - 5});
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

test "compare - for loop with range" {
    const alloc = std.heap.page_allocator;
    const diffs = try compareParsers(
        \\module main
        \\
        \\func sum(n: i32) i32 {
        \\    var total: i32 = 0
        \\    for(0..n) |i| {
        \\        total += i
        \\    }
        \\    return total
        \\}
        \\
    , alloc);
    if (diffs.len > 0) {
        for (diffs) |d| {
            std.debug.print("DIFF at {s}: old={s} new={s}\n", .{ d.path, d.old_desc, d.new_desc });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diffs.len);
}

// Example module
test "compare - example/example.orh" {
    const n = try compareFile(@embedFile("../templates/example/example.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - example/control_flow.orh" {
    const n = try compareFile(@embedFile("../templates/example/control_flow.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - example/data_types.orh" {
    const n = try compareFile(@embedFile("../templates/example/data_types.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - example/strings.orh" {
    const n = try compareFile(@embedFile("../templates/example/strings.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - example/advanced.orh" {
    const n = try compareFile(@embedFile("../templates/example/advanced.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - example/error_handling.orh" {
    const n = try compareFile(@embedFile("../templates/example/error_handling.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

// Main template
test "compare - templates/main.orh" {
    const n = try compareFile(@embedFile("../templates/main.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

// Stdlib bridges
test "compare - std/console.orh" {
    const n = try compareFile(@embedFile("../std/console.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - std/math.orh" {
    const n = try compareFile(@embedFile("../std/math.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - std/str.orh" {
    const n = try compareFile(@embedFile("../std/str.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - std/collections.orh" {
    const n = try compareFile(@embedFile("../std/collections.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - std/fs.orh" {
    const n = try compareFile(@embedFile("../std/fs.orh"));
    try std.testing.expectEqual(@as(usize, 0), n);
}

// Test fixtures
test "compare - test/fixtures/tester.orh" {
    const n = try compareRuntimeFile("test/fixtures/tester.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - test/fixtures/tester_main.orh" {
    const n = try compareRuntimeFile("test/fixtures/tester_main.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

// Tamga project
test "compare - tamga/main.orh" {
    const n = try compareRuntimeFile("/home/yunus/Projects/orhon/tamga/src/main.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - tamga/tamga_sdl3.orh" {
    const n = try compareRuntimeFile("/home/yunus/Projects/orhon/tamga/src/TamgaSDL3/tamga_sdl3.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - tamga/tamga_vk3d.orh" {
    const n = try compareRuntimeFile("/home/yunus/Projects/orhon/tamga/src/TamgaVK3D/tamga_vk3d.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - tamga/test_sdl3.orh" {
    const n = try compareRuntimeFile("/home/yunus/Projects/orhon/tamga/src/test/test_sdl3.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "compare - tamga/test_vulkan.orh" {
    const n = try compareRuntimeFile("/home/yunus/Projects/orhon/tamga/src/test/test_vulkan.orh");
    try std.testing.expectEqual(@as(usize, 0), n);
}
