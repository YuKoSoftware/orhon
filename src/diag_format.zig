// diag_format.zig — Diagnostic output rendering (human, JSON, short)
const std = @import("std");
const errors = @import("errors.zig");

pub const DiagFormat = enum { human, json, short };

// ── Human format ────────────────────────────────────────────────────────────

const RED       = "\x1b[31m";
const YELLOW    = "\x1b[33m";
const CYAN      = "\x1b[36m";
const DIM       = "\x1b[2m";
const BOLD      = "\x1b[1m";
const RESET     = "\x1b[0m";
const WHITE     = "\x1b[97m";
const HEADER_PAD = "                                                  ";

const DiagKind = enum {
    err,
    warning,

    fn label(self: DiagKind) []const u8 {
        return switch (self) {
            .err => "ERROR",
            .warning => "WARNING",
        };
    }
};

pub fn flushHuman(reporter: *const errors.Reporter, mode: errors.BuildMode, writer: anytype) !void {
    for (reporter.warnings.items) |diag| {
        try printDiagnostic(writer, &diag, .warning, mode);
    }
    for (reporter.errors.items) |diag| {
        try printDiagnostic(writer, &diag, .err, mode);
    }
    const warning_count = reporter.warnings.items.len;
    const error_count = reporter.errors.items.len;
    if (warning_count > 0 or error_count > 0) try writer.print("\n", .{});
    if (warning_count > 0 and error_count > 0) {
        try writer.print("{s}{d} warning(s){s}, {s}{d} error(s){s}\n", .{ YELLOW, warning_count, RESET, RED, error_count, RESET });
    } else if (warning_count > 0) {
        try writer.print("{s}{d} warning(s){s}\n", .{ YELLOW, warning_count, RESET });
    } else if (error_count > 0) {
        try writer.print("{s}{d} error(s){s}\n", .{ RED, error_count, RESET });
    }
}

fn printDiagnostic(writer: anytype, diag: *const errors.OrhonError, kind: DiagKind, mode: errors.BuildMode) !void {
    const is_error = kind == .err;
    const header_bg = if (is_error) "\x1b[41m" else "\x1b[43m";
    const header_fg = if (is_error) WHITE else "\x1b[30m";
    const lbl = kind.label();

    var code_buf: [8]u8 = undefined;
    const code_str: []const u8 = if (diag.code) |c| c.toCode(&code_buf) else "";
    const has_code = diag.code != null;

    if (mode != .debug) {
        if (has_code) {
            try writer.print("{s} [{s}]: {s}\n", .{ lbl, code_str, diag.message });
        } else {
            try writer.print("{s}: {s}\n", .{ lbl, diag.message });
        }
        return;
    }

    const full_lbl = if (has_code)
        try std.fmt.allocPrint(std.heap.page_allocator, "{s} [{s}]", .{ lbl, code_str })
    else
        lbl;
    defer if (has_code) std.heap.page_allocator.free(full_lbl);
    const pad_len = if (HEADER_PAD.len > full_lbl.len + 2) HEADER_PAD.len - full_lbl.len - 2 else 0;
    try writer.print("\n{s}{s}{s}  {s}{s}{s}\n", .{ header_bg, BOLD, header_fg, full_lbl, HEADER_PAD[0..pad_len], RESET });

    try writer.print("\n  {s}{s}{s}\n", .{ BOLD, diag.message, RESET });

    if (diag.loc) |loc| {
        if (loc.line > 0 and loc.file.len > 0) {
            try writer.print("  {s}──▸ {s}:{d}{s}\n", .{ CYAN, loc.file, loc.line, RESET });
        } else if (loc.line > 0) {
            try writer.print("  {s}at line {d}{s}\n", .{ CYAN, loc.line, RESET });
        }
        if (loc.file.len > 0 and loc.line > 0) {
            if (readSourceLine(loc.file, loc.line)) |line| {
                try writer.print("{s}       │{s}\n", .{ DIM, RESET });
                try writer.print("{s}{d: >5}{s} {s}│{s}  {s}{s}{s}\n", .{ BOLD, loc.line, RESET, DIM, RESET, BOLD, line, RESET });
                try writer.print("{s}       │{s}\n", .{ DIM, RESET });
            }
        }
    }
}

var line_buf: [1024]u8 = undefined;

fn readSourceLine(file_path: []const u8, target_line: usize) ?[]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return null;
    defer std.heap.page_allocator.free(content);
    var line_num: usize = 1;
    var start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            if (line_num == target_line) return copyToLineBuf(content[start..i]);
            line_num += 1;
            start = i + 1;
        }
    }
    if (line_num == target_line and start < content.len) return copyToLineBuf(content[start..]);
    return null;
}

fn copyToLineBuf(line: []const u8) []const u8 {
    const len = @min(line.len, line_buf.len);
    @memcpy(line_buf[0..len], line[0..len]);
    return line_buf[0..len];
}

// ── JSON format ───────────────────────────────────────────────────────────────

pub fn flushJson(reporter: *const errors.Reporter, writer: anytype) !void {
    try writer.writeAll("{\"version\":1,\"diagnostics\":[");
    var first = true;
    for (reporter.warnings.items) |diag| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writeDiagJson(&diag, "warning", writer);
    }
    for (reporter.errors.items) |diag| {
        if (!first) try writer.writeAll(",");
        first = false;
        try writeDiagJson(&diag, "error", writer);
    }
    try writer.writeAll("]}\n");
}

fn writeDiagJson(diag: *const errors.OrhonError, severity: []const u8, writer: anytype) !void {
    try writer.print("{{\"severity\":\"{s}\"", .{severity});
    if (diag.code) |code| {
        var buf: [8]u8 = undefined;
        const code_str = code.toCode(&buf);
        try writer.print(",\"code\":\"{s}\"", .{code_str});
    }
    try writer.writeAll(",\"message\":");
    try writeJsonString(diag.message, writer);
    if (diag.loc) |loc| {
        if (loc.file.len > 0) {
            try writer.writeAll(",\"file\":");
            try writeJsonString(loc.file, writer);
        }
        if (loc.line > 0) {
            try writer.print(",\"line\":{d}", .{loc.line});
        }
        if (loc.col > 0) {
            try writer.print(",\"col\":{d}", .{loc.col});
        }
    }
    try writer.writeAll("}");
}

fn writeJsonString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"'  => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ── Short format ──────────────────────────────────────────────────────────────

pub fn flushShort(reporter: *const errors.Reporter, writer: anytype) !void {
    for (reporter.warnings.items) |diag| {
        try writeDiagShort(&diag, "warning", writer);
    }
    for (reporter.errors.items) |diag| {
        try writeDiagShort(&diag, "error", writer);
    }
}

fn writeDiagShort(diag: *const errors.OrhonError, severity: []const u8, writer: anytype) !void {
    var code_buf: [8]u8 = undefined;
    if (diag.loc) |loc| {
        if (loc.file.len > 0 and loc.line > 0) {
            if (loc.col > 0) {
                try writer.print("{s}:{d}:{d}: ", .{ loc.file, loc.line, loc.col });
            } else {
                try writer.print("{s}:{d}: ", .{ loc.file, loc.line });
            }
        }
    }
    if (diag.code) |code| {
        const code_str = code.toCode(&code_buf);
        try writer.print("{s}[{s}]: {s}\n", .{ severity, code_str, diag.message });
    } else {
        try writer.print("{s}: {s}\n", .{ severity, diag.message });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "flushJson produces wrapped JSON object" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    try reporter.report(.{
        .code = .unknown_identifier,
        .message = "unknown identifier 'foo'",
        .loc = .{ .file = "src/main.orh", .line = 10, .col = 5 },
    });
    try reporter.warn(.{
        .message = "unused import",
    });
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.testing.allocator);
    try flushJson(&reporter, out.writer(std.testing.allocator));
    const expected =
        \\{"version":1,"diagnostics":[{"severity":"warning","message":"unused import"},{"severity":"error","code":"E2040","message":"unknown identifier 'foo'","file":"src/main.orh","line":10,"col":5}]}
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.items);
}

test "flushShort with loc and code" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    try reporter.report(.{
        .code = .unknown_identifier,
        .message = "unknown identifier 'foo'",
        .loc = .{ .file = "src/main.orh", .line = 10, .col = 5 },
    });
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.testing.allocator);
    try flushShort(&reporter, out.writer(std.testing.allocator));
    try std.testing.expectEqualStrings(
        "src/main.orh:10:5: error[E2040]: unknown identifier 'foo'\n",
        out.items,
    );
}

test "flushShort without loc" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    try reporter.report(.{ .message = "internal error" });
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.testing.allocator);
    try flushShort(&reporter, out.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("error: internal error\n", out.items);
}

test "flushShort loc with zero col omits col" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    try reporter.report(.{
        .message = "type mismatch",
        .loc = .{ .file = "src/foo.orh", .line = 3, .col = 0 },
    });
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.testing.allocator);
    try flushShort(&reporter, out.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("src/foo.orh:3: error: type mismatch\n", out.items);
}
