// builtins.zig — Kodr builtin types and their Zig code generation equivalents
// The compiler knows about these types natively — no import needed in Kodr code.
// Also serves as the lookup table for stdlib symbol → Zig translation.

const std = @import("std");

/// All builtin type names known to the Kodr compiler
pub const BUILTIN_TYPES = [_][]const u8{
    "Thread",
    "Async",
    "Ptr",
    "RawPtr",
    "VolatilePtr",
    "Error",
    "Version",
    "VersionRule",
    "Dependency",
};

/// All compiler function names (prefixed with @ in Kodr source)
pub const COMPILER_FUNCS = [_][]const u8{
    "typename",
    "typeid",
    "cast",
    "copy",
    "move",
    "swap",
    "assert",
    "size",
    "align",
};

/// All builtin value keywords
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

/// Build type enum values
pub const BUILD_TYPES = [_][]const u8{
    "build.exe",
    "build.static",
    "build.dynamic",
};

/// Check if a name is a builtin type
pub fn isBuiltinType(name: []const u8) bool {
    for (BUILTIN_TYPES) |bt| {
        if (std.mem.eql(u8, name, bt)) return true;
    }
    return false;
}

/// Check if a name is a compiler function (without @ prefix)
pub fn isCompilerFunc(name: []const u8) bool {
    for (COMPILER_FUNCS) |cf| {
        if (std.mem.eql(u8, name, cf)) return true;
    }
    return false;
}

/// Check if a name is a builtin value
pub fn isBuiltinValue(name: []const u8) bool {
    for (BUILTIN_VALUES) |bv| {
        if (std.mem.eql(u8, name, bv)) return true;
    }
    return false;
}

/// Zig code generation for builtin types
/// Returns the Zig source representation for a given Kodr builtin
pub const ZigMapping = struct {
    /// Generate Zig code for Thread(T) block
    pub fn threadBlock(T: []const u8, name: []const u8, body: []const u8, writer: anytype) !void {
        try writer.print(
            \\const {s}_thread = try std.Thread.spawn(.{{}}, struct {{
            \\    fn run() {s} {{
            \\        {s}
            \\    }}
            \\}}.run, .{{}});
            \\
        , .{ name, T, body });
    }

    /// Generate Zig code for Ptr(T, &x)
    pub fn ptrType(T: []const u8, writer: anytype) !void {
        try writer.print(
            \\struct {{ address: usize, valid: bool, _type: type = {s} }}
        , .{T});
    }

    /// Generate Zig code for RawPtr(T, addr)
    pub fn rawPtrType(T: []const u8, writer: anytype) !void {
        try writer.print("[*]{s}", .{T});
    }

    /// Generate Zig code for VolatilePtr(T, addr)
    pub fn volatilePtrType(T: []const u8, writer: anytype) !void {
        try writer.print("*volatile {s}", .{T});
    }

    /// Map Kodr primitive to Zig primitive
    pub fn primitiveToZig(kodr_type: []const u8) []const u8 {
        // Most primitives map 1:1 with Zig
        const mappings = [_][2][]const u8{
            .{ "String", "[]const u8" },
            .{ "bool",   "bool" },
            .{ "i8",     "i8" },
            .{ "i16",    "i16" },
            .{ "i32",    "i32" },
            .{ "i64",    "i64" },
            .{ "i128",   "i128" },
            .{ "u8",     "u8" },
            .{ "u16",    "u16" },
            .{ "u32",    "u32" },
            .{ "u64",    "u64" },
            .{ "u128",   "u128" },
            .{ "isize",  "isize" },
            .{ "usize",  "usize" },
            .{ "f16",    "f16" },
            .{ "f32",    "f32" },
            .{ "f64",    "f64" },
            .{ "f128",   "f128" },
            // bf16 maps to f16 in Zig (closest equivalent)
            .{ "bf16",   "f16" },
        };

        for (mappings) |m| {
            if (std.mem.eql(u8, kodr_type, m[0])) return m[1];
        }
        return kodr_type; // user defined type — use as-is
    }
};

test "builtin type detection" {
    try std.testing.expect(isBuiltinType("Thread"));
    try std.testing.expect(isBuiltinType("Ptr"));
    try std.testing.expect(!isBuiltinType("Player"));
    try std.testing.expect(!isBuiltinType("i32"));
}

test "compiler func detection" {
    try std.testing.expect(isCompilerFunc("cast"));
    try std.testing.expect(!isCompilerFunc("print"));
}

test "primitive mapping" {
    try std.testing.expectEqualStrings("[]const u8", ZigMapping.primitiveToZig("String"));
    try std.testing.expectEqualStrings("i32", ZigMapping.primitiveToZig("i32"));
    try std.testing.expectEqualStrings("f16", ZigMapping.primitiveToZig("bf16"));
}
