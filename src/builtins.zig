// builtins.zig — Orhon builtin types and compiler intrinsics
// Only language-level types that the compiler needs to understand natively.
// Everything else (collections, strings, etc.) goes through the stdlib import system.

const std = @import("std");

const K = @import("constants.zig");

/// Builtin type names — language intrinsics the compiler knows about
pub const BUILTIN_TYPES = [_][]const u8{
    K.Type.ERROR,
    K.Type.VECTOR,
};

/// Typed enum for compiler functions — use `fromName()` to convert AST string names.
/// Eliminates if-else chains on string literals in codegen and analysis passes.
pub const CompilerFunc = enum {
    typename,
    typeid,
    typeOf,
    cast,
    copy,
    move,
    swap,
    assert,
    size,
    @"align", // "align" is a Zig keyword
    hasField,
    hasDecl,
    fieldType,
    fieldNames,
    splitAt,
    wrap,
    sat,
    overflow,
    @"type", // internal: desugared from `x is T` — not user-facing

    pub fn fromName(name: []const u8) ?CompilerFunc {
        const map = std.StaticStringMap(CompilerFunc).initComptime(.{
            .{ "typename", .typename },
            .{ "typeid", .typeid },
            .{ "typeOf", .typeOf },
            .{ "cast", .cast },
            .{ "copy", .copy },
            .{ "move", .move },
            .{ "swap", .swap },
            .{ "assert", .assert },
            .{ "size", .size },
            .{ "align", .@"align" },
            .{ "hasField", .hasField },
            .{ "hasDecl", .hasDecl },
            .{ "fieldType", .fieldType },
            .{ "fieldNames", .fieldNames },
            .{ "splitAt", .splitAt },
            .{ "wrap", .wrap },
            .{ "sat", .sat },
            .{ "overflow", .overflow },
            .{ "type", .@"type" },
        });
        return map.get(name);
    }
};

/// Builtin value keywords
pub const BUILTIN_VALUES = [_][]const u8{
    "null",
    "true",
    "false",
    "void",
};

/// Value types — fixed-size types that always copy, never move.
/// Distinct from primitives (i32, f32) but share copy semantics.
pub fn isValueType(name: []const u8) bool {
    return std.mem.eql(u8, name, K.Type.VECTOR);
}

pub fn isBuiltinType(name: []const u8) bool {
    for (BUILTIN_TYPES) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

pub fn isBuiltinValue(name: []const u8) bool {
    for (BUILTIN_VALUES) |bv| {
        if (std.mem.eql(u8, name, bv)) return true;
    }
    return false;
}


test "builtin type detection" {
    try std.testing.expect(isBuiltinType("Error"));
    try std.testing.expect(!isBuiltinType("Player"));
    try std.testing.expect(!isBuiltinType("i32"));
    try std.testing.expect(!isBuiltinType("List"));
    try std.testing.expect(!isBuiltinType("Map"));
    try std.testing.expect(!isBuiltinType("Set"));
    try std.testing.expect(!isBuiltinType("Version"));
    try std.testing.expect(!isBuiltinType("Dependency"));
    try std.testing.expect(isBuiltinType("Vector"));
    try std.testing.expect(!isBuiltinType("Handle"));
}

test "compiler func detection via fromName" {
    try std.testing.expect(CompilerFunc.fromName("cast") != null);
    try std.testing.expect(CompilerFunc.fromName("typeOf") != null);
    try std.testing.expect(CompilerFunc.fromName("print") == null);
    try std.testing.expect(CompilerFunc.fromName("hasField") != null);
    try std.testing.expect(CompilerFunc.fromName("hasDecl") != null);
    try std.testing.expect(CompilerFunc.fromName("fieldType") != null);
    try std.testing.expect(CompilerFunc.fromName("fieldNames") != null);
}

test "value type detection" {
    try std.testing.expect(isValueType("Vector"));
    try std.testing.expect(!isValueType("List"));
    try std.testing.expect(!isValueType("i32"));
}

test "CompilerFunc.fromName" {
    try std.testing.expect(CompilerFunc.fromName("cast") == .cast);
    try std.testing.expect(CompilerFunc.fromName("typename") == .typename);
    try std.testing.expect(CompilerFunc.fromName("align") == .@"align");
    try std.testing.expect(CompilerFunc.fromName("move") == .move);
    try std.testing.expect(CompilerFunc.fromName("assert") == .assert);
    try std.testing.expect(CompilerFunc.fromName("unknown") == null);
    try std.testing.expect(CompilerFunc.fromName("") == null);
}

