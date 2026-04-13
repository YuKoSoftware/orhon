// codegen_unions.zig — Shared _unions.zig file emitter.
//
// Emits N generic factory functions OrhonUnion2..OrhonUnionMax. Zero imports
// because user types are supplied at the call site by codegen.zig — comptime
// memoization in Zig gives structural type identity across modules.

const std = @import("std");
const mir_registry = @import("../mir/mir_registry.zig");

const UnionRegistry = mir_registry.UnionRegistry;

/// Generate the contents of `_unions.zig` from the global registry.
/// Returns owned string — caller must free.
pub fn generateUnionsFile(registry: *const UnionRegistry, allocator: std.mem.Allocator) ![]const u8 {
    if (registry.isEmpty()) return error.EmptyRegistry;

    const max = registry.maxArity();
    if (max < 2) return error.EmptyRegistry;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    var w = buf.writer(allocator);

    try w.writeAll("// _unions.zig — Auto-generated arbitrary-union factories.\n");
    try w.writeAll("// Do not edit — regenerated on every build.\n");
    try w.writeAll("// Zero imports: user types are supplied at the call site.\n\n");

    var arity: usize = 2;
    while (arity <= max) : (arity += 1) {
        try w.print("pub fn OrhonUnion{d}(", .{arity});
        var i: usize = 0;
        while (i < arity) : (i += 1) {
            if (i > 0) try w.writeAll(", ");
            try w.print("comptime T{d}: type", .{i});
        }
        try w.writeAll(") type {\n    return union(enum) {\n");
        i = 0;
        while (i < arity) : (i += 1) {
            try w.print("        _{d}: T{d},\n", .{ i, i });
        }
        try w.writeAll("    };\n}\n\n");
    }

    return try allocator.dupe(u8, buf.items);
}

// ── Tests ───────────────────────────────────────────────────

test "generate unions file - arity 2 only" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();
    try reg.registerArity("main", 2);

    const out = try generateUnionsFile(&reg, alloc);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn OrhonUnion2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OrhonUnion3") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@import") == null);
}

test "generate unions file - max arity emits all factories" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();
    try reg.registerArity("main", 4);

    const out = try generateUnionsFile(&reg, alloc);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "OrhonUnion2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OrhonUnion3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OrhonUnion4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OrhonUnion5") == null);
}

test "generate unions file - empty registry errors" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();
    try std.testing.expectError(error.EmptyRegistry, generateUnionsFile(&reg, alloc));
}

test "generate unions file - has positional tags" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();
    try reg.registerArity("main", 3);

    const out = try generateUnionsFile(&reg, alloc);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "_0: T0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_1: T1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "_2: T2") != null);
}
