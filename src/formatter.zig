// formatter.zig — Orhon source code formatter
// One canonical style, no configuration.
//
// Rules:
//   - 4 spaces indentation, no tabs
//   - Max 1 consecutive blank line anywhere
//   - 1 blank line after module declaration
//   - 1 blank line after imports block
//   - 1 blank line between top-level declarations
//   - 1 blank line between comment and code below it
//   - No trailing whitespace
//   - Single newline at end of file
//   - Collapse multiple blank lines into 1

const std = @import("std");

pub const LineWarning = struct {
    line: usize,
    length: usize,
};

pub const FormatResult = struct {
    text: []u8,
    warnings: []LineWarning,
};

/// Format all .orh files in a project directory (recursive).
pub fn formatProject(allocator: std.mem.Allocator, source_dir: []const u8, max_line_length: u32) !void {
    var dir = std.fs.cwd().openDir(source_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("error: could not open '{s}': {}\n", .{ source_dir, err });
        return;
    };
    defer dir.close();

    try formatDirRecursive(allocator, &dir, source_dir, max_line_length);
}

fn formatDirRecursive(allocator: std.mem.Allocator, dir: *std.fs.Dir, dir_path: []const u8, max_line_length: u32) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(sub_path);
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();
            try formatDirRecursive(allocator, &sub_dir, sub_path, max_line_length);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".orh")) {
            const file_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            defer allocator.free(file_path);
            try formatFile(allocator, file_path, max_line_length);
        }
    }
}

/// Format a single .orh file in place.
fn formatFile(allocator: std.mem.Allocator, path: []const u8, max_line_length: u32) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        std.debug.print("  skip {s}: {}\n", .{ path, err });
        return;
    };
    defer allocator.free(content);

    const result = try format(allocator, content, max_line_length);
    defer allocator.free(result.text);
    defer allocator.free(result.warnings);

    if (!std.mem.eql(u8, content, result.text)) {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(result.text);
        std.debug.print("  formatted {s}\n", .{path});
    }

    for (result.warnings) |w| {
        std.debug.print("    warning: line {d} exceeds {d} columns ({d})\n", .{ w.line, max_line_length, w.length });
    }
}

/// Format Orhon source code according to the canonical style.
pub fn format(allocator: std.mem.Allocator, source: []const u8, max_line_length: u32) !FormatResult {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);
    var warnings = std.ArrayListUnmanaged(LineWarning){};
    errdefer warnings.deinit(allocator);

    var lines = std.mem.splitSequence(u8, source, "\n");
    var line_number: usize = 0;
    var prev_was_blank = false;
    var prev_was_comment = false;
    var prev_was_module = false;
    var prev_was_import = false;
    var is_first_line = true;

    while (lines.next()) |raw_line| {
        // Trim trailing whitespace
        const line = std.mem.trimRight(u8, raw_line, " \t\r");

        const is_blank = line.len == 0;
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const is_comment = std.mem.startsWith(u8, trimmed, "//");
        const is_module_decl = std.mem.startsWith(u8, trimmed, "module ");
        const is_import = std.mem.startsWith(u8, trimmed, "import ") or std.mem.startsWith(u8, trimmed, "use ");

        // Replace tabs with 4 spaces in indentation
        const indent_end = blk: {
            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            break :blk i;
        };

        // Collapse multiple blank lines into 1
        if (is_blank) {
            if (!prev_was_blank and !is_first_line) {
                try output.appendSlice(allocator, "\n");
            }
            prev_was_blank = true;
            prev_was_comment = false;
            prev_was_module = false;
            // Keep prev_was_import through blank lines so the transition fires correctly
            is_first_line = false;
            line_number += 1;
            continue;
        }

        // Ensure blank line after module declaration
        if (prev_was_module and !is_blank and !prev_was_blank) {
            try output.appendSlice(allocator, "\n");
        }

        // Ensure blank line after imports block (transition from import to non-import)
        if (prev_was_import and !is_import and !is_blank and !prev_was_blank) {
            try output.appendSlice(allocator, "\n");
        }

        // Ensure blank line before top-level comments (not inside blocks)
        if (is_comment and !prev_was_blank and !prev_was_comment and !is_first_line and indent_end == 0) {
            try output.appendSlice(allocator, "\n");
        }

        // Write the line with tabs replaced by spaces
        var col: usize = 0;
        for (line[0..indent_end]) |ch| {
            if (ch == '\t') {
                const spaces = 4 - (col % 4);
                var s: usize = 0;
                while (s < spaces) : (s += 1) {
                    try output.append(allocator, ' ');
                }
                col += spaces;
            } else {
                try output.append(allocator, ch);
                col += 1;
            }
        }
        // Write the rest of the line as-is
        try output.appendSlice(allocator, line[indent_end..]);
        try output.appendSlice(allocator, "\n");

        if (max_line_length > 0) {
            const line_len = col + (line.len - indent_end);
            if (line_len > max_line_length) {
                try warnings.append(allocator, .{ .line = line_number, .length = line_len });
            }
        }
        line_number += 1;

        prev_was_blank = false;
        prev_was_comment = is_comment;
        prev_was_module = is_module_decl;
        prev_was_import = is_import;
        is_first_line = false;
    }

    // Ensure single trailing newline
    while (output.items.len > 1 and output.items[output.items.len - 1] == '\n' and output.items[output.items.len - 2] == '\n') {
        _ = output.pop();
    }
    if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
        try output.append(allocator, '\n');
    }

    return .{
        .text = try output.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
    };
}

test "format - collapse multiple blank lines" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n\n\n\nfunc foo() void {\n}\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    // Should have at most 1 blank line
    try std.testing.expect(std.mem.indexOf(u8, result, "\n\n\n") == null);
}

test "format - trailing whitespace removed" {
    const alloc = std.testing.allocator;
    const input = "module myapp   \nfunc foo() void {  \n}\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expect(std.mem.indexOf(u8, result, "   \n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "  \n") == null);
}

test "format - tabs to spaces" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n\tfunc foo() void {\n\t\treturn\n\t}\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expect(std.mem.indexOf(u8, result, "\t") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "    func") != null);
}

test "format - single trailing newline" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n\n\n\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[result.len - 1] == '\n');
    // No double newline at end
    if (result.len > 1) {
        try std.testing.expect(!(result[result.len - 1] == '\n' and result[result.len - 2] == '\n'));
    }
}

test "format - blank line after module" {
    const alloc = std.testing.allocator;
    const input = "module myapp\nimport std::console\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expect(std.mem.indexOf(u8, result, "module myapp\n\nimport") != null);
}

test "format - empty input" {
    const alloc = std.testing.allocator;
    const r = try format(alloc, "", 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expectEqualStrings("", result);
}

test "format - no trailing newline added" {
    const alloc = std.testing.allocator;
    const input = "module myapp";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[result.len - 1] == '\n');
}

test "format - blank line after imports block" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n\nimport std::console\nfunc main() void {\n}\n";
    const r = try format(alloc, input, 0);
    const result = r.text;
    defer alloc.free(result);
    defer alloc.free(r.warnings);
    // Should have blank line between import and func
    try std.testing.expect(std.mem.indexOf(u8, result, "console\n\nfunc") != null);
}

test "format - idempotent" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n\nimport std::console\n\nfunc main() void {\n    console.println(\"hello\")\n}\n";
    const r1 = try format(alloc, input, 0);
    const first = r1.text;
    defer alloc.free(first);
    defer alloc.free(r1.warnings);
    const r2 = try format(alloc, first, 0);
    const second = r2.text;
    defer alloc.free(second);
    defer alloc.free(r2.warnings);
    try std.testing.expectEqualStrings(first, second);
}

test "format - line length warning" {
    const alloc = std.testing.allocator;
    const input = "module " ++ "a" ** 103 ++ "\n";
    const r = try format(alloc, input, 100);
    defer alloc.free(r.text);
    defer alloc.free(r.warnings);
    try std.testing.expectEqual(@as(usize, 1), r.warnings.len);
    try std.testing.expectEqual(@as(usize, 0), r.warnings[0].line);
    try std.testing.expectEqual(@as(usize, 110), r.warnings[0].length);
}

test "format - line length disabled" {
    const alloc = std.testing.allocator;
    const input = "module " ++ "a" ** 103 ++ "\n";
    const r = try format(alloc, input, 0);
    defer alloc.free(r.text);
    defer alloc.free(r.warnings);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}

test "format - line length under limit" {
    const alloc = std.testing.allocator;
    const input = "module myapp\n";
    const r = try format(alloc, input, 100);
    defer alloc.free(r.text);
    defer alloc.free(r.warnings);
    try std.testing.expectEqual(@as(usize, 0), r.warnings.len);
}
