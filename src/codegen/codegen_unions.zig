// codegen_unions.zig — Shared _unions.zig file emitter
// Satellite of codegen.zig. Generates a single file containing all
// arbitrary union type definitions used across modules.

const std = @import("std");
const mir_registry = @import("../mir/mir_registry.zig");
const types = @import("../types.zig");

const UnionRegistry = mir_registry.UnionRegistry;
const Primitive = types.Primitive;

/// Generate the contents of `_unions.zig` from the global registry.
/// Returns owned string — caller must free.
pub fn generateUnionsFile(registry: *const UnionRegistry, allocator: std.mem.Allocator) ![]const u8 {
    if (registry.entries.items.len == 0) return error.EmptyRegistry;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Header
    try w.writeAll("// _unions.zig — Auto-generated shared union type definitions\n");
    try w.writeAll("// Do not edit — regenerated on every build.\n\n");

    // Collect all unique module imports needed for user types
    var module_imports = std.StringHashMapUnmanaged(void){};
    defer module_imports.deinit(allocator);

    for (registry.entries.items) |entry| {
        for (entry.module_types) |mt| {
            try module_imports.put(allocator, mt.module_name, {});
        }
    }

    // Emit module imports
    // Sort for deterministic output
    var import_names = std.ArrayListUnmanaged([]const u8){};
    defer import_names.deinit(allocator);
    var it = module_imports.keyIterator();
    while (it.next()) |key| {
        try import_names.append(allocator, key.*);
    }
    std.mem.sort([]const u8, import_names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (import_names.items) |mod_name| {
        try w.print("const {s} = @import(\"{s}\");\n", .{ mod_name, mod_name });
    }
    if (import_names.items.len > 0) try w.writeByte('\n');

    // Emit union type definitions
    for (registry.entries.items) |entry| {
        try w.print("pub const {s} = union(enum) {{ ", .{entry.name});

        for (entry.members) |member| {
            const tag = sanitizeTagName(member, allocator) catch continue;
            defer allocator.free(tag);
            const zig_type = try memberToZig(member, entry.module_types, allocator);
            defer allocator.free(zig_type);
            try w.print("_{s}: {s}, ", .{ tag, zig_type });
        }

        try w.writeAll("};\n");
    }

    return try allocator.dupe(u8, buf.items);
}

/// Map a union member name to its Zig type representation.
/// Primitives go through Primitive.nameToZig(), user types use module.Type format.
/// Returns an allocated string for module-qualified types — caller must free.
fn memberToZig(member: []const u8, module_types: []const mir_registry.ModuleType, allocator: std.mem.Allocator) ![]const u8 {
    // Check if it's a user type with a known module
    for (module_types) |mt| {
        if (std.mem.eql(u8, mt.type_name, member)) {
            // Qualify with module name: module.Type
            return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ mt.module_name, mt.type_name });
        }
    }
    // Primitive type — map to Zig equivalent (static string, dupe for uniform ownership)
    return try allocator.dupe(u8, Primitive.nameToZig(member));
}

/// Sanitize a type name into a valid Zig identifier for union tag names.
/// Allocates — caller must free.
fn sanitizeTagName(raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(allocator);
    var prev_underscore = true; // suppress leading underscore
    for (raw) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(allocator, c);
            prev_underscore = false;
        } else if (!prev_underscore) {
            try buf.append(allocator, '_');
            prev_underscore = true;
        }
    }
    // Trim trailing underscore
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') {
        _ = buf.pop();
    }
    return try allocator.dupe(u8, buf.items);
}

// ── Tests ───────────────────────────────────────────────────

test "generate unions file - primitives only" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    _ = try reg.canonicalize(&.{ "i32", "str" }, null);

    const output = try generateUnionsFile(&reg, alloc);
    defer alloc.free(output);

    // Should contain the union definition
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const OrhonUnion_i32_str") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "union(enum)") != null);
    // Should map str to []const u8
    try std.testing.expect(std.mem.indexOf(u8, output, "[]const u8") != null);
}

test "generate unions file - with user type" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    var ctx = std.StringHashMapUnmanaged([]const u8){};
    defer ctx.deinit(alloc);
    try ctx.put(alloc, "Point", "shapes");

    _ = try reg.canonicalize(&.{ "i32", "Point" }, &ctx);

    const output = try generateUnionsFile(&reg, alloc);
    defer alloc.free(output);

    // Should import the shapes module
    try std.testing.expect(std.mem.indexOf(u8, output, "@import(\"shapes\")") != null);
    // Should contain the union with module-qualified name
    try std.testing.expect(std.mem.indexOf(u8, output, "OrhonUnion_i32_shapes_Point") != null);
}

test "generate unions file - empty registry" {
    const alloc = std.testing.allocator;
    var reg = UnionRegistry.init(alloc);
    defer reg.deinit();

    const result = generateUnionsFile(&reg, alloc);
    try std.testing.expectError(error.EmptyRegistry, result);
}
