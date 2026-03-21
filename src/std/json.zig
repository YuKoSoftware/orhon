// json.zig — sidecar for std::json module

const std = @import("std");

const alloc = std.heap.smp_allocator;

const JsonError = struct { message: []const u8 };
fn JsonResult(comptime T: type) type {
    return union(enum) { ok: T, err: JsonError };
}
fn KodrNullable(comptime T: type) type {
    return union(enum) { some: T, none: void };
}

pub fn parse(text: []const u8) JsonResult([]const u8) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
        return .{ .err = .{ .message = "invalid JSON" } };
    defer parsed.deinit();

    var buf = std.ArrayListUnmanaged(u8){};
    std.json.stringify(parsed.value, .{ .whitespace = .indent_2 }, buf.writer(alloc)) catch
        return .{ .err = .{ .message = "stringify failed" } };
    return .{ .ok = buf.toOwnedSlice(alloc) catch return .{ .err = .{ .message = "out of memory" } } };
}

pub fn stringify(text: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
        return text;
    defer parsed.deinit();

    var buf = std.ArrayListUnmanaged(u8){};
    std.json.stringify(parsed.value, .{ .whitespace = .minified }, buf.writer(alloc)) catch
        return text;
    return buf.toOwnedSlice(alloc) catch text;
}

pub fn get(json_text: []const u8, key: []const u8) KodrNullable([]const u8) {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
        return .{ .none = {} };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{ .none = {} },
    };

    const val = obj.get(key) orelse return .{ .none = {} };
    const str = switch (val) {
        .string => |s| s,
        else => {
            // For non-string values, serialize them
            var buf = std.ArrayListUnmanaged(u8){};
            std.json.stringify(val, .{ .whitespace = .minified }, buf.writer(alloc)) catch
                return .{ .none = {} };
            return .{ .some = buf.toOwnedSlice(alloc) catch return .{ .none = {} } };
        },
    };

    return .{ .some = alloc.dupe(u8, str) catch return .{ .none = {} } };
}

pub fn isValid(text: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch
        return false;
    parsed.deinit();
    return true;
}
