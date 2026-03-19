// zigstd.zig — Zig stdlib bridge for Kodr
// Hand-written implementation. Paired with zigstd.kodr.
// Do not edit the generated zigstd.zig in .kodr-cache/generated/ —
// edit this source file and run kodr initstd to update.

const std = @import("std");

pub fn print(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}
