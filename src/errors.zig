// errors.zig — Orhon compiler error formatting
// Single source of truth for all error output.
// Emits full trace in debug builds, message only in release builds.

const std = @import("std");

pub const ErrorCode = @import("error_codes.zig").ErrorCode;

pub const BuildMode = enum {
    debug,
    release,
};

/// A source location in a .orh file
pub const SourceLoc = struct {
    file: []const u8,
    line: usize,
    col: usize,
};

/// A single error with optional location and trace
pub const OrhonError = struct {
    message: []const u8,
    loc: ?SourceLoc = null,
    code: ?ErrorCode = null,
};

/// The error reporter — used by every pass
pub const Reporter = struct {
    mode: BuildMode,
    errors: std.ArrayListUnmanaged(OrhonError),
    warnings: std.ArrayListUnmanaged(OrhonError),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, mode: BuildMode) Reporter {
        return .{
            .mode = mode,
            .errors = .{},
            .warnings = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Reporter) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
            if (err.loc) |loc| {
                if (loc.file.len > 0) self.allocator.free(loc.file);
            }
        }
        self.errors.deinit(self.allocator);
        for (self.warnings.items) |w| {
            self.allocator.free(w.message);
            if (w.loc) |loc| {
                if (loc.file.len > 0) self.allocator.free(loc.file);
            }
        }
        self.warnings.deinit(self.allocator);
    }

    fn storeOwned(self: *Reporter, diag: OrhonError, list: *std.ArrayListUnmanaged(OrhonError)) !void {
        const owned_msg = try self.allocator.dupe(u8, diag.message);
        const owned_loc: ?SourceLoc = if (diag.loc) |loc| .{
            .file = if (loc.file.len > 0) try self.allocator.dupe(u8, loc.file) else "",
            .line = loc.line,
            .col = loc.col,
        } else null;
        try list.append(self.allocator, .{
            .message = owned_msg,
            .loc = owned_loc,
            .code = diag.code,
        });
    }

    pub fn report(self: *Reporter, err: OrhonError) !void {
        try self.storeOwned(err, &self.errors);
    }

    /// Record a non-fatal warning. Compilation continues after warnings.
    pub fn warn(self: *Reporter, w: OrhonError) !void {
        try self.storeOwned(w, &self.warnings);
    }

    /// Format and report an error in one step.
    /// Replaces the repeated allocPrint + defer free + report pattern.
    pub fn reportFmt(self: *Reporter, code: ErrorCode, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.report(.{ .code = code, .message = msg, .loc = loc });
    }

    /// Format and record a warning in one step. Warn-side counterpart to reportFmt.
    pub fn warnFmt(self: *Reporter, code: ErrorCode, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try self.warn(.{ .code = code, .message = msg, .loc = loc });
    }

    pub fn hasErrors(self: *const Reporter) bool {
        return self.errors.items.len > 0;
    }

    pub fn hasWarnings(self: *const Reporter) bool {
        return self.warnings.items.len > 0;
    }

    /// Print all diagnostics to stderr: warnings first, then errors.
    pub fn flush(self: *const Reporter) !void {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const stderr = &w.interface;

        for (self.warnings.items) |diag| {
            try printDiagnostic(stderr, &diag, .warning, self.mode);
        }
        for (self.errors.items) |diag| {
            try printDiagnostic(stderr, &diag, .err, self.mode);
        }

        // Summary line
        const warning_count = self.warnings.items.len;
        const error_count = self.errors.items.len;
        if (warning_count > 0 or error_count > 0) {
            try stderr.print("\n", .{});
        }
        if (warning_count > 0 and error_count > 0) {
            try stderr.print("{s}{d} warning(s){s}, {s}{d} error(s){s}\n", .{ YELLOW, warning_count, RESET, RED, error_count, RESET });
        } else if (warning_count > 0) {
            try stderr.print("{s}{d} warning(s){s}\n", .{ YELLOW, warning_count, RESET });
        } else if (error_count > 0) {
            try stderr.print("{s}{d} error(s){s}\n", .{ RED, error_count, RESET });
        }

        try stderr.flush();
    }
};

// ANSI codes
const RED = "\x1b[31m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const RESET = "\x1b[0m";
const RED_BG = "\x1b[48;5;52m"; // dark red background
const YELLOW_BG = "\x1b[48;5;58m"; // dark yellow background
const WHITE = "\x1b[97m"; // bright white text

// Full-width header bar: 50 spaces to pad the label
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

fn printDiagnostic(stderr: anytype, diag: *const OrhonError, kind: DiagKind, mode: BuildMode) !void {
    const is_error = kind == .err;
    const header_bg = if (is_error) "\x1b[41m" else "\x1b[43m"; // red / yellow background
    const header_fg = if (is_error) WHITE else "\x1b[30m"; // white on red, black on yellow
    const lbl = kind.label();

    var code_buf: [8]u8 = undefined;
    const code_str: []const u8 = if (diag.code) |c| c.toCode(&code_buf) else "";
    const has_code = diag.code != null;

    if (mode != .debug) {
        if (has_code) {
            try stderr.print("{s} [{s}]: {s}\n", .{ lbl, code_str, diag.message });
        } else {
            try stderr.print("{s}: {s}\n", .{ lbl, diag.message });
        }
        return;
    }

    // Full-width colored header bar
    const full_lbl = if (has_code)
        try std.fmt.allocPrint(std.heap.page_allocator, "{s} [{s}]", .{ lbl, code_str })
    else
        lbl;
    defer if (has_code) std.heap.page_allocator.free(full_lbl);
    const pad_len = if (HEADER_PAD.len > full_lbl.len + 2) HEADER_PAD.len - full_lbl.len - 2 else 0;
    try stderr.print("\n{s}{s}{s}  {s}{s}{s}\n", .{ header_bg, BOLD, header_fg, full_lbl, HEADER_PAD[0..pad_len], RESET });

    // Message
    try stderr.print("\n  {s}{s}{s}\n", .{ BOLD, diag.message, RESET });

    if (diag.loc) |loc| {
        // Location
        if (loc.line > 0 and loc.file.len > 0) {
            try stderr.print("  {s}──▸ {s}:{d}{s}\n", .{ CYAN, loc.file, loc.line, RESET });
        } else if (loc.line > 0) {
            try stderr.print("  {s}at line {d}{s}\n", .{ CYAN, loc.line, RESET });
        }
        // Source snippet
        if (loc.file.len > 0 and loc.line > 0) {
            if (readSourceLine(loc.file, loc.line)) |line| {
                try stderr.print("{s}       │{s}\n", .{ DIM, RESET });
                try stderr.print("{s}{d: >5}{s} {s}│{s}  {s}{s}{s}\n", .{ BOLD, loc.line, RESET, DIM, RESET, BOLD, line, RESET });
                try stderr.print("{s}       │{s}\n", .{ DIM, RESET });
            }
        }
    }
}

/// Read a specific line from a source file into a static buffer, returns null on failure.
/// Uses a fixed buffer to avoid heap allocation and memory leaks during error reporting.
fn readSourceLine(file_path: []const u8, target_line: usize) ?[]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return null;
    defer std.heap.page_allocator.free(content);
    var line_num: usize = 1;
    var start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            if (line_num == target_line) {
                return copyToLineBuf(content[start..i]);
            }
            line_num += 1;
            start = i + 1;
        }
    }
    // Last line without trailing newline
    if (line_num == target_line and start < content.len) {
        return copyToLineBuf(content[start..]);
    }
    return null;
}

/// Copy a line into a static buffer so the source content can be freed.
var line_buf: [1024]u8 = undefined;
fn copyToLineBuf(line: []const u8) []const u8 {
    const len = @min(line.len, line_buf.len);
    @memcpy(line_buf[0..len], line[0..len]);
    return line_buf[0..len];
}

// Maximum identifier length considered for Levenshtein suggestions.
// Names longer than this are treated as no match to avoid pathological cases.
const MAX_NAME_LEN = 64;

/// Compute the Levenshtein edit distance between two strings.
/// Uses a stack-allocated row buffer bounded by MAX_NAME_LEN.
pub fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > MAX_NAME_LEN or b.len > MAX_NAME_LEN) return MAX_NAME_LEN;

    var row: [MAX_NAME_LEN + 1]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;

    for (a, 0..) |ca, i| {
        var prev = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const next = @min(@min(row[j + 1] + 1, prev + 1), row[j] + cost);
            row[j] = prev;
            prev = next;
        }
        row[b.len] = prev;
    }
    return row[b.len];
}

/// Find the closest name to `query` in `candidates` within `threshold` edits.
/// Returns null if no candidate is within threshold, if the query is too short
/// (len <= 2), or if the only match is an exact duplicate (d == 0).
pub fn closestMatch(query: []const u8, candidates: []const []const u8, threshold: usize) ?[]const u8 {
    if (query.len <= 2) return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = threshold + 1;
    for (candidates) |c| {
        const d = levenshtein(query, c);
        if (d > 0 and d < best_dist) {
            best_dist = d;
            best = c;
        }
    }
    return best;
}

/// Format a "did you mean?" suggestion string if a close candidate exists.
/// Threshold is adaptive: 1 for short names (len <= 4), 2 otherwise.
/// Returns an allocated string " — did you mean 'X'?" or null.
/// Caller must free the returned string when non-null.
pub fn formatSuggestion(query: []const u8, candidates: []const []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    const threshold: usize = if (query.len <= 4) 1 else 2;
    if (closestMatch(query, candidates, threshold)) |match| {
        return try std.fmt.allocPrint(allocator, " \u{2014} did you mean '{s}'?", .{match});
    }
    return null;
}

/// Simple one-shot error print — for fatal compiler errors before Reporter is set up
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const stderr = &w.interface;
    stderr.print("ERROR: " ++ fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

test "reporter collects errors" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    try reporter.report(.{ .code = .unknown_identifier, .message = "test error" });
    try std.testing.expect(reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), reporter.errors.items.len);
    try std.testing.expectEqual(ErrorCode.unknown_identifier, reporter.errors.items[0].code.?);
}

test "reporter release mode" {
    var reporter = Reporter.init(std.testing.allocator, .release);
    defer reporter.deinit();
    try std.testing.expect(!reporter.hasErrors());
}

test "reporter collects warnings" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    try reporter.warn(.{ .code = .unused_import, .message = "test warning" });
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(reporter.hasWarnings());
    try std.testing.expectEqual(@as(usize, 1), reporter.warnings.items.len);
    try std.testing.expectEqualStrings("test warning", reporter.warnings.items[0].message);
    try std.testing.expectEqual(ErrorCode.unused_import, reporter.warnings.items[0].code.?);
}

test "reporter warnings don't block compilation" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    try reporter.warn(.{ .message = "unused var" });
    try std.testing.expect(!reporter.hasErrors()); // warnings don't count as errors
}

test "levenshtein exact match" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("count", "count"));
}

test "levenshtein transposition" {
    // Adjacent transposition (coutn → count) costs 2 in standard Levenshtein:
    // one deletion + one insertion. Still caught by closestMatch with threshold=2.
    try std.testing.expectEqual(@as(usize, 2), levenshtein("coutn", "count"));
}

test "levenshtein single insertion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("cont", "count"));
}

test "levenshtein single deletion" {
    try std.testing.expectEqual(@as(usize, 1), levenshtein("countt", "count"));
}

test "levenshtein empty strings" {
    try std.testing.expectEqual(@as(usize, 5), levenshtein("", "count"));
    try std.testing.expectEqual(@as(usize, 5), levenshtein("count", ""));
}

test "closestMatch finds best" {
    const candidates = [_][]const u8{ "count", "print", "value" };
    const result = closestMatch("coutn", &candidates, 2);
    try std.testing.expectEqualStrings("count", result.?);
}

test "closestMatch returns null when nothing close" {
    const candidates = [_][]const u8{ "print", "value", "render" };
    const result = closestMatch("xyz", &candidates, 2);
    try std.testing.expect(result == null);
}

test "closestMatch no suggestion for short names" {
    const candidates = [_][]const u8{ "x", "y", "z" };
    const result = closestMatch("a", &candidates, 1);
    try std.testing.expect(result == null); // len <= 2 guard
}

test "closestMatch does not suggest exact match" {
    const candidates = [_][]const u8{ "count", "value" };
    const result = closestMatch("count", &candidates, 2);
    try std.testing.expect(result == null); // d == 0, excluded by d > 0 guard
}
