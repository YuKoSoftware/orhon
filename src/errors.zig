// errors.zig — Orhon compiler error reporter and diagnostics types.
// Rendering lives in diag_format.zig.

const std = @import("std");

pub const ErrorCode = @import("error_codes.zig").ErrorCode;

pub const Severity = enum { err, warning, note, hint };

/// A single diagnostic with optional location and severity.
/// severity defaults to .err so existing struct literals .{ .message = ... } compile unchanged.
pub const OrhonDiag = struct {
    severity: Severity = .err,
    message:  []const u8,
    loc:      ?SourceLoc = null,
    code:     ?ErrorCode = null,
    parent:   ?u32 = null,
};

/// Backward-compat alias — all existing code using OrhonError continues to compile.
pub const OrhonError = OrhonDiag;

const diag_fmt = @import("diag_format.zig");
pub const DiagFormat = diag_fmt.DiagFormat;

pub const BuildMode = enum {
    debug,
    release,
};

pub const ColorMode = enum { auto, always, never };

/// Resolve color mode to a concrete bool: check NO_COLOR env var and isatty on .auto.
pub fn detectColor(mode: ColorMode) bool {
    return switch (mode) {
        .always => true,
        .never => false,
        .auto => blk: {
            if (std.posix.getenv("NO_COLOR") != null) break :blk false;
            break :blk std.posix.isatty(std.fs.File.stderr().handle);
        },
    };
}

/// A source location in a .orh file
pub const SourceLoc = struct {
    file: []const u8,
    line: usize,
    col: usize,
};

/// The error reporter — used by every pass
pub const Reporter = struct {
    mode:        BuildMode,
    diagnostics: std.ArrayListUnmanaged(OrhonDiag),
    allocator:   std.mem.Allocator,
    diag_format: DiagFormat = .human,
    use_color:   bool = false,
    werror:      bool = false,

    pub fn init(allocator: std.mem.Allocator, mode: BuildMode) Reporter {
        return .{
            .mode        = mode,
            .diagnostics = .{},
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *Reporter) void {
        for (self.diagnostics.items) |diag| {
            self.allocator.free(diag.message);
            if (diag.loc) |loc| {
                if (loc.file.len > 0) self.allocator.free(loc.file);
            }
        }
        self.diagnostics.deinit(self.allocator);
    }

    // storeDiag dupes diag.message — safe for string literals and borrowed slices.
    fn storeDiag(self: *Reporter, diag: OrhonDiag) !u32 {
        const owned_msg = try self.allocator.dupe(u8, diag.message);
        errdefer self.allocator.free(owned_msg);
        const owned_loc: ?SourceLoc = if (diag.loc) |loc| blk: {
            const f = if (loc.file.len > 0) try self.allocator.dupe(u8, loc.file) else "";
            errdefer if (loc.file.len > 0) self.allocator.free(f);
            break :blk SourceLoc{ .file = f, .line = loc.line, .col = loc.col };
        } else null;
        const idx: u32 = @intCast(self.diagnostics.items.len);
        try self.diagnostics.append(self.allocator, .{
            .severity = diag.severity,
            .message  = owned_msg,
            .loc      = owned_loc,
            .code     = diag.code,
            .parent   = diag.parent,
        });
        return idx;
    }

    // storeDiagOwned takes ownership of diag.message — caller must allocate with self.allocator.
    // Use for pre-allocated messages to avoid double-allocation.
    fn storeDiagOwned(self: *Reporter, diag: OrhonDiag) !u32 {
        errdefer self.allocator.free(diag.message);
        const owned_loc: ?SourceLoc = if (diag.loc) |loc| blk: {
            const f = if (loc.file.len > 0) try self.allocator.dupe(u8, loc.file) else "";
            errdefer if (loc.file.len > 0) self.allocator.free(f);
            break :blk SourceLoc{ .file = f, .line = loc.line, .col = loc.col };
        } else null;
        const idx: u32 = @intCast(self.diagnostics.items.len);
        try self.diagnostics.append(self.allocator, .{
            .severity = diag.severity,
            .message  = diag.message,
            .loc      = owned_loc,
            .code     = diag.code,
            .parent   = diag.parent,
        });
        return idx;
    }

    /// Record an error. Safe for string literals and borrowed slices (dupes internally).
    pub fn report(self: *Reporter, diag: OrhonDiag) !u32 {
        var d = diag;
        d.severity = .err;
        d.parent   = null;
        return self.storeDiag(d);
    }

    /// Record an error, taking ownership of diag.message.
    /// diag.message must be allocated with self.allocator. Avoids double-allocation
    /// when the caller already holds an allocated string.
    pub fn reportOwned(self: *Reporter, diag: OrhonDiag) !u32 {
        var d = diag;
        d.severity = .err;
        d.parent   = null;
        return self.storeDiagOwned(d);
    }

    /// Record a non-fatal warning. Compilation continues after warnings.
    pub fn warn(self: *Reporter, diag: OrhonDiag) !u32 {
        var d = diag;
        d.severity = .warning;
        d.parent   = null;
        return self.storeDiag(d);
    }

    /// Format and report an error in one step. Allocates the message once (no double-allocation).
    pub fn reportFmt(self: *Reporter, code: ErrorCode, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) !u32 {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        return self.storeDiagOwned(.{ .code = code, .message = msg, .loc = loc, .severity = .err });
    }

    /// Format and record a warning in one step. Warn-side counterpart to reportFmt.
    pub fn warnFmt(self: *Reporter, code: ErrorCode, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) !u32 {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        return self.storeDiagOwned(.{ .code = code, .message = msg, .loc = loc, .severity = .warning });
    }

    pub fn note(self: *Reporter, parent: u32, diag: OrhonDiag) !void {
        var d = diag;
        d.severity = .note;
        d.parent   = parent;
        _ = try self.storeDiag(d);
    }

    pub fn noteFmt(self: *Reporter, parent: u32, code: ErrorCode, loc: ?SourceLoc, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        _ = try self.storeDiagOwned(.{ .code = code, .message = msg, .loc = loc, .severity = .note, .parent = parent });
    }

    pub fn hasErrors(self: *const Reporter) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .err) return true;
            if (d.severity == .warning and self.werror) return true;
        }
        return false;
    }

    pub fn hasWarnings(self: *const Reporter) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .warning) return true;
        }
        return false;
    }

    /// Emit all diagnostics in self.diag_format to stderr.
    pub fn flush(self: *const Reporter) !void {
        var buf: [4096]u8 = undefined;
        var w = std.fs.File.stderr().writer(&buf);
        const stderr = &w.interface;
        switch (self.diag_format) {
            .human => try diag_fmt.flushHuman(self, self.mode, stderr, self.use_color),
            .json  => try diag_fmt.flushJson(self, stderr),
            .short => try diag_fmt.flushShort(self, stderr),
        }
        try stderr.flush();
    }
};

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

    _ = try reporter.report(.{ .code = .unknown_identifier, .message = "test error" });
    try std.testing.expect(reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
    try std.testing.expectEqual(Severity.err, reporter.diagnostics.items[0].severity);
    try std.testing.expectEqual(ErrorCode.unknown_identifier, reporter.diagnostics.items[0].code.?);
}

test "reporter release mode" {
    var reporter = Reporter.init(std.testing.allocator, .release);
    defer reporter.deinit();
    try std.testing.expect(!reporter.hasErrors());
}

test "reporter collects warnings" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    _ = try reporter.warn(.{ .code = .unused_import, .message = "test warning" });
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(reporter.hasWarnings());
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
    try std.testing.expectEqual(Severity.warning, reporter.diagnostics.items[0].severity);
    try std.testing.expectEqualStrings("test warning", reporter.diagnostics.items[0].message);
    try std.testing.expectEqual(ErrorCode.unused_import, reporter.diagnostics.items[0].code.?);
}

test "detectColor .always returns true" {
    try std.testing.expect(detectColor(.always));
}

test "detectColor .never returns false" {
    try std.testing.expect(!detectColor(.never));
}

test "reporter warnings don't block compilation" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    _ = try reporter.warn(.{ .message = "unused var" });
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

test "OrhonDiag has severity and parent with defaults" {
    const d = OrhonDiag{ .message = "test" };
    try std.testing.expectEqual(Severity.err, d.severity);
    try std.testing.expect(d.parent == null);
    try std.testing.expect(d.loc == null);
    try std.testing.expect(d.code == null);
}

test "report returns index; note chains to parent" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    const idx = try reporter.report(.{ .code = .unknown_identifier, .message = "unknown 'x'" });
    try std.testing.expectEqual(@as(u32, 0), idx);
    const idx2 = try reporter.report(.{ .message = "second error" });
    try std.testing.expectEqual(@as(u32, 1), idx2);

    try reporter.note(idx, .{ .message = "defined here" });
    try std.testing.expectEqual(@as(usize, 3), reporter.diagnostics.items.len);
    try std.testing.expectEqual(Severity.note, reporter.diagnostics.items[2].severity);
    try std.testing.expectEqual(@as(u32, 0), reporter.diagnostics.items[2].parent.?);
}

test "hasErrors respects werror flag" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    reporter.werror = true;

    _ = try reporter.warn(.{ .message = "unused var" });
    try std.testing.expect(reporter.hasErrors());
}

test "hasErrors false when werror=false and only warnings" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    _ = try reporter.warn(.{ .message = "unused var" });
    try std.testing.expect(!reporter.hasErrors());
}

test "reportOwned takes ownership; deinit frees without double-free" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    const msg = try std.testing.allocator.dupe(u8, "owned message");
    const idx = try reporter.reportOwned(.{ .code = .unknown_identifier, .message = msg });
    try std.testing.expectEqual(@as(u32, 0), idx);
    try std.testing.expectEqualStrings("owned message", reporter.diagnostics.items[0].message);
    try std.testing.expect(reporter.hasErrors());
}

