// errors.zig — Kodr compiler error formatting
// Single source of truth for all error output.
// Emits full trace in debug builds, message only in release builds.

const std = @import("std");

pub const BuildMode = enum {
    debug,
    release,
};

/// A source location in a .kodr file
pub const SourceLoc = struct {
    file: []const u8,
    line: usize,
    col: usize,
};

/// A single error with optional location and trace
pub const KodrError = struct {
    message: []const u8,
    loc: ?SourceLoc = null,
    notes: []const []const u8 = &.{},
};

/// The error reporter — used by every pass
pub const Reporter = struct {
    mode: BuildMode,
    errors: std.ArrayListUnmanaged(KodrError),
    warnings: std.ArrayListUnmanaged(KodrError),
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

    fn storeOwned(self: *Reporter, diag: KodrError, list: *std.ArrayListUnmanaged(KodrError)) !void {
        const owned_msg = try self.allocator.dupe(u8, diag.message);
        const owned_loc: ?SourceLoc = if (diag.loc) |loc| .{
            .file = if (loc.file.len > 0) (self.allocator.dupe(u8, loc.file) catch "") else "",
            .line = loc.line,
            .col = loc.col,
        } else null;
        try list.append(self.allocator, .{
            .message = owned_msg,
            .loc = owned_loc,
            .notes = diag.notes,
        });
    }

    pub fn report(self: *Reporter, err: KodrError) !void {
        try self.storeOwned(err, &self.errors);
    }

    /// Record a non-fatal warning. Compilation continues after warnings.
    pub fn warn(self: *Reporter, w: KodrError) !void {
        try self.storeOwned(w, &self.warnings);
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
            try printDiagnostic(stderr, &diag, "WARNING", self.mode);
        }
        for (self.errors.items) |diag| {
            try printDiagnostic(stderr, &diag, "ERROR", self.mode);
        }

        // Summary line when there are both warnings and errors, or multiple of either
        const wc = self.warnings.items.len;
        const ec = self.errors.items.len;
        if (wc > 0 and ec > 0) {
            try stderr.print("{d} warning(s), {d} error(s)\n", .{ wc, ec });
        } else if (wc > 1) {
            try stderr.print("{d} warning(s)\n", .{wc});
        } else if (ec > 1) {
            try stderr.print("{d} error(s)\n", .{ec});
        }

        try stderr.flush();
    }
};

fn printDiagnostic(stderr: anytype, diag: *const KodrError, label: []const u8, mode: BuildMode) !void {
    if (diag.loc) |loc| {
        if (mode == .debug) {
            try stderr.print("{s}: {s}\n", .{ label, diag.message });
            if (loc.line > 0 and loc.file.len > 0) {
                try stderr.print("  --> {s}:{d}:{d}\n", .{ loc.file, loc.line, loc.col });
            } else if (loc.line > 0) {
                try stderr.print("  at line {d}:{d}\n", .{ loc.line, loc.col });
            }
            if (loc.file.len > 0 and loc.line > 0) {
                if (readSourceLine(loc.file, loc.line)) |line| {
                    try stderr.print("   |\n", .{});
                    try stderr.print("{d: >3}|  {s}\n", .{ loc.line, line });
                    try stderr.print("   |  ", .{});
                    var c: usize = 1;
                    while (c < loc.col) : (c += 1) {
                        try stderr.print(" ", .{});
                    }
                    try stderr.print("^\n", .{});
                }
            }
            for (diag.notes) |note| {
                try stderr.print("  note: {s}\n", .{note});
            }
        } else {
            try stderr.print("{s}: {s}\n", .{ label, diag.message });
        }
    } else {
        try stderr.print("{s}: {s}\n", .{ label, diag.message });
    }
}

/// Read a specific line from a source file, returns null on failure
fn readSourceLine(file_path: []const u8, target_line: usize) ?[]const u8 {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return null;
    // Don't defer free — the slice is valid for the duration of flush()
    // This is a small leak per error but errors are fatal anyway
    var line_num: usize = 1;
    var start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            if (line_num == target_line) {
                return content[start..i];
            }
            line_num += 1;
            start = i + 1;
        }
    }
    // Last line without trailing newline
    if (line_num == target_line and start < content.len) {
        return content[start..];
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

    try reporter.report(.{ .message = "test error" });
    try std.testing.expect(reporter.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), reporter.errors.items.len);
}

test "reporter release mode" {
    var reporter = Reporter.init(std.testing.allocator, .release);
    defer reporter.deinit();
    try std.testing.expect(!reporter.hasErrors());
}

test "reporter collects warnings" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    try reporter.warn(.{ .message = "test warning" });
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(reporter.hasWarnings());
    try std.testing.expectEqual(@as(usize, 1), reporter.warnings.items.len);
    try std.testing.expectEqualStrings("test warning", reporter.warnings.items[0].message);
}

test "reporter warnings don't block compilation" {
    var reporter = Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    try reporter.warn(.{ .message = "unused var" });
    try std.testing.expect(!reporter.hasErrors()); // warnings don't count as errors
}
