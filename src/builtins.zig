// builtins.zig — Orhon builtin types and compiler intrinsics
// Only language-level types that the compiler needs to understand natively.
// Everything else (collections, strings, etc.) goes through the bridge.

const std = @import("std");

/// Builtin type names — language intrinsics the compiler knows about
pub const BUILTIN_TYPES = [_][]const u8{
    "Ptr",
    "RawPtr",
    "VolatilePtr",
    "Handle",
    "Error",
    "Version",
    "VersionRule",
    "Dependency",
    "List",
    "Map",
    "Set",
    "Vector",
};

/// Compiler function names (called as keywords, no prefix)
pub const COMPILER_FUNCS = [_][]const u8{
    "typename",
    "typeid",
    "typeOf",
    "cast",
    "copy",
    "move",
    "swap",
    "assert",
    "size",
    "align",
};

/// Builtin value keywords
pub const BUILTIN_VALUES = [_][]const u8{
    "null",
    "true",
    "false",
    "void",
};

/// Build metadata field names — valid only in root module file
pub const BUILD_FIELDS = [_][]const u8{
    "name",
    "version",
    "build",
    "description",
    "icon",
    "deps",
    "allocator",
    "gpu",
};

/// Build type values for #build metadata
pub const BUILD_TYPES = [_][]const u8{
    "exe",
    "static",
    "dynamic",
};

/// Value types — fixed-size types that always copy, never move.
/// Distinct from primitives (i32, f32) but share copy semantics.
pub fn isValueType(name: []const u8) bool {
    const value_types = [_][]const u8{"Vector"};
    for (value_types) |vt| {
        if (std.mem.eql(u8, name, vt)) return true;
    }
    return false;
}

pub fn isBuiltinType(name: []const u8) bool {
    for (BUILTIN_TYPES) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

pub fn isCompilerFunc(name: []const u8) bool {
    for (COMPILER_FUNCS) |cf| {
        if (std.mem.eql(u8, name, cf)) return true;
    }
    return false;
}

pub fn isBuiltinValue(name: []const u8) bool {
    for (BUILTIN_VALUES) |bv| {
        if (std.mem.eql(u8, name, bv)) return true;
    }
    return false;
}

/// Map Orhon primitive type name to Zig equivalent
pub fn primitiveToZig(orhon_type: []const u8) []const u8 {
    const mappings = [_][2][]const u8{
        .{ "String", "[]const u8" },
        .{ "bool", "bool" },
        .{ "i8", "i8" },
        .{ "i16", "i16" },
        .{ "i32", "i32" },
        .{ "i64", "i64" },
        .{ "i128", "i128" },
        .{ "u8", "u8" },
        .{ "u16", "u16" },
        .{ "u32", "u32" },
        .{ "u64", "u64" },
        .{ "u128", "u128" },
        .{ "isize", "isize" },
        .{ "usize", "usize" },
        .{ "f16", "f16" },
        .{ "f32", "f32" },
        .{ "f64", "f64" },
        .{ "f128", "f128" },
        .{ "bf16", "f16" },
    };
    for (mappings) |m| {
        if (std.mem.eql(u8, orhon_type, m[0])) return m[1];
    }
    return orhon_type;
}

test "builtin type detection" {
    try std.testing.expect(isBuiltinType("Ptr"));
    try std.testing.expect(isBuiltinType("Error"));
    try std.testing.expect(!isBuiltinType("Player"));
    try std.testing.expect(!isBuiltinType("i32"));
    try std.testing.expect(isBuiltinType("List"));
    try std.testing.expect(isBuiltinType("Map"));
    try std.testing.expect(isBuiltinType("Set"));
    try std.testing.expect(isBuiltinType("Vector"));
}

test "compiler func detection" {
    try std.testing.expect(isCompilerFunc("cast"));
    try std.testing.expect(isCompilerFunc("typeOf"));
    try std.testing.expect(!isCompilerFunc("print"));
}

test "value type detection" {
    try std.testing.expect(isValueType("Vector"));
    try std.testing.expect(!isValueType("List"));
    try std.testing.expect(!isValueType("i32"));
}

test "primitive mapping" {
    try std.testing.expectEqualStrings("[]const u8", primitiveToZig("String"));
    try std.testing.expectEqualStrings("i32", primitiveToZig("i32"));
    try std.testing.expectEqualStrings("f16", primitiveToZig("bf16"));
}
