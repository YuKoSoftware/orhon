// bitfield.zig — Comptime bitfield type generator for Orhon std::bitfield
//
// Generates a struct with named flag constants and bitwise methods.
//
// Usage:
//   const Perms = Bitfield(u32, .{ "Read", "Write", "Execute" });
//   var p: Perms = .{};
//   p.set(Perms.get("Read"));
//   p.has(Perms.get("Read")); // true
//
// Flag access is via `get()` which resolves at comptime:
//   Perms.get("Read")    → 1
//   Perms.get("Write")   → 2
//   Perms.get("Execute") → 4

const std = @import("std");

/// Generates a bitfield struct type from a backing integer type and a tuple of flag names.
///
/// Each flag is assigned a power-of-two value in declaration order:
/// flag 0 → 1, flag 1 → 2, flag 2 → 4, etc.
///
/// The returned struct has:
/// - `value: BackingType` field (default 0)
/// - `get(comptime name) BackingType` — comptime flag lookup by name
/// - `has(flag) bool` — test if flag is set
/// - `set(flag) void` — set a flag
/// - `clear(flag) void` — clear a flag
/// - `toggle(flag) void` — toggle a flag
pub fn Bitfield(comptime BackingType: type, comptime flags: anytype) type {
    // Validate that BackingType is an unsigned integer
    const type_info = @typeInfo(BackingType);
    if (type_info != .int or type_info.int.signedness != .unsigned) {
        @compileError("Bitfield backing type must be an unsigned integer");
    }

    const tuple_fields = @typeInfo(@TypeOf(flags)).@"struct".fields;

    // Validate flag count fits in the backing type
    if (tuple_fields.len > type_info.int.bits) {
        @compileError("too many flags for backing type");
    }

    // Build a reified struct with comptime fields for flag name → value mapping.
    // Zig 0.15 @Type reification does not support adding declarations (methods),
    // so we use a comptime instance of this inner type as a lookup table.
    var inner_fields: [tuple_fields.len]std.builtin.Type.StructField = undefined;
    inline for (tuple_fields, 0..) |_, i| {
        const flag_name: [:0]const u8 = flags[i];
        const val: BackingType = @as(BackingType, 1) << @intCast(i);
        inner_fields[i] = .{
            .name = flag_name,
            .type = BackingType,
            .default_value_ptr = &val,
            .is_comptime = true,
            .alignment = @alignOf(BackingType),
        };
    }

    const FlagTable = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &inner_fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    return struct {
        value: BackingType = 0,

        const Self = @This();
        const _flags = FlagTable{};

        /// Returns the comptime flag value for the given name.
        pub fn get(comptime name: []const u8) BackingType {
            return @field(_flags, name);
        }

        /// Returns true if the given flag is set.
        pub fn has(self: Self, f: BackingType) bool {
            return (self.value & f) != 0;
        }

        /// Sets the given flag.
        pub fn set(self: *Self, f: BackingType) void {
            self.value |= f;
        }

        /// Clears the given flag.
        pub fn clear(self: *Self, f: BackingType) void {
            self.value &= ~f;
        }

        /// Toggles the given flag.
        pub fn toggle(self: *Self, f: BackingType) void {
            self.value ^= f;
        }
    };
}

test "bitfield basic" {
    const Perms = Bitfield(u32, .{ "Read", "Write", "Execute" });
    var p: Perms = .{};
    try std.testing.expect(!p.has(Perms.get("Read")));
    p.set(Perms.get("Read"));
    try std.testing.expect(p.has(Perms.get("Read")));
    p.clear(Perms.get("Read"));
    try std.testing.expect(!p.has(Perms.get("Read")));
    p.toggle(Perms.get("Write"));
    try std.testing.expect(p.has(Perms.get("Write")));
}

test "bitfield combined" {
    const Perms = Bitfield(u32, .{ "Read", "Write", "Execute" });
    var p: Perms = .{ .value = Perms.get("Read") | Perms.get("Write") };
    try std.testing.expect(p.has(Perms.get("Read")));
    try std.testing.expect(p.has(Perms.get("Write")));
    try std.testing.expect(!p.has(Perms.get("Execute")));
    _ = &p;
}

test "bitfield flag values are powers of two" {
    const Flags = Bitfield(u8, .{ "A", "B", "C", "D" });
    try std.testing.expectEqual(@as(u8, 1), Flags.get("A"));
    try std.testing.expectEqual(@as(u8, 2), Flags.get("B"));
    try std.testing.expectEqual(@as(u8, 4), Flags.get("C"));
    try std.testing.expectEqual(@as(u8, 8), Flags.get("D"));
}

test "bitfield toggle is reversible" {
    const Perms = Bitfield(u32, .{ "Read", "Write", "Execute" });
    var p: Perms = .{};
    p.toggle(Perms.get("Read"));
    try std.testing.expect(p.has(Perms.get("Read")));
    p.toggle(Perms.get("Read"));
    try std.testing.expect(!p.has(Perms.get("Read")));
}

test "bitfield default value is zero" {
    const Perms = Bitfield(u32, .{ "Read", "Write", "Execute" });
    const p: Perms = .{};
    try std.testing.expectEqual(@as(u32, 0), p.value);
}
