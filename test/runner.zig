// test/runner.zig — Orhon diagnostic fixture test runner
const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────────────

const Annotation = struct { line: u32, code: []const u8 };
const Diag       = struct { code: []const u8, line: u32 };

const Mismatch = union(enum) {
    missing:    Annotation,
    unexpected: Diag,
};

const TestResult = union(enum) {
    pass,
    skip,
    fail:        []const u8,  // formatted failure message, caller must free
    setup_error: []const u8,  // caller must free
};

// ── Pure functions ─────────────────────────────────────────────────────────────

/// Scan a fixture's source for //> [Exxxx] annotations.
/// Returns (line_number, code) pairs — line numbers are 1-based.
fn scanAnnotationsFromContent(content: []const u8, allocator: std.mem.Allocator) ![]Annotation {
    var list = std.ArrayList(Annotation){};
    errdefer {
        for (list.items) |a| allocator.free(a.code);
        list.deinit(allocator);
    }
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        const marker_pos = std.mem.indexOf(u8, line, "//>") orelse continue;
        var rest = line[marker_pos + 3..];
        while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
            rest = rest[open + 1..];
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
            const raw = rest[0..close];
            rest = rest[close + 1..];
            if (raw.len < 2 or raw[0] != 'E') continue;
            const digits_ok = for (raw[1..]) |c| {
                if (c < '0' or c > '9') break false;
            } else true;
            if (!digits_ok) continue;
            const code = try allocator.dupe(u8, raw);
            errdefer allocator.free(code);
            try list.append(allocator, .{ .line = line_num, .code = code });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Extract the module name from the first `module <name>` line in a fixture.
fn extractModuleNameFromContent(content: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "module ")) continue;
        const after = std.mem.trimLeft(u8, trimmed[7..], " \t");
        const end = std.mem.indexOfAny(u8, after, " \t\r\n") orelse after.len;
        if (end == 0) continue;
        return allocator.dupe(u8, after[0..end]);
    }
    return error.ModuleNotFound;
}

/// Compare expected annotations against actual diagnostics.
/// Missing = annotation with no matching actual diag.
/// Unexpected = actual diag with no matching annotation.
fn compareResults(
    expected: []const Annotation,
    actual:   []const Diag,
    allocator: std.mem.Allocator,
) ![]Mismatch {
    var list = std.ArrayList(Mismatch){};
    errdefer list.deinit(allocator);
    var matched = try allocator.alloc(bool, actual.len);
    defer allocator.free(matched);
    @memset(matched, false);

    for (expected) |ann| {
        var found = false;
        for (actual, 0..) |diag, i| {
            if (matched[i]) continue;
            if (diag.line == ann.line and std.mem.eql(u8, diag.code, ann.code)) {
                matched[i] = true;
                found = true;
                break;
            }
        }
        if (!found) try list.append(allocator, .{ .missing = ann });
    }
    for (actual, 0..) |diag, i| {
        if (!matched[i]) try list.append(allocator, .{ .unexpected = diag });
    }
    return list.toOwnedSlice(allocator);
}

/// Parse orhon's --diag-format=json output into a flat list of error-severity diagnostics.
/// Non-error severities (warning, note, hint) are skipped.
/// Returns empty slice if the output is not valid JSON or has no diagnostics array.
fn parseJsonDiagnostics(json: []const u8, allocator: std.mem.Allocator) ![]Diag {
    var list = std.ArrayList(Diag){};
    errdefer {
        for (list.items) |d| allocator.free(d.code);
        list.deinit(allocator);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return list.toOwnedSlice(allocator);
    defer parsed.deinit();

    const diags_val = switch (parsed.value) {
        .object => |o| o.get("diagnostics") orelse return list.toOwnedSlice(allocator),
        else    => return list.toOwnedSlice(allocator),
    };
    const diags_arr = switch (diags_val) {
        .array => |a| a,
        else   => return list.toOwnedSlice(allocator),
    };

    for (diags_arr.items) |item| {
        const obj = switch (item) { .object => |o| o, else => continue };

        const sev = switch (obj.get("severity") orelse continue) {
            .string => |s| s,
            else    => continue,
        };
        if (!std.mem.eql(u8, sev, "error")) continue;

        const code_str = switch (obj.get("code") orelse continue) {
            .string => |s| s,
            else    => continue,
        };
        const line_val = switch (obj.get("line") orelse continue) {
            .integer => |n| n,
            else     => continue,
        };
        if (line_val < 1) continue;

        const code = try allocator.dupe(u8, code_str);
        errdefer allocator.free(code);
        try list.append(allocator, .{
            .code = code,
            .line = @intCast(line_val),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Run a single fixture: setup temp project, invoke orhon, compare diagnostics.
/// Uses an arena for all intermediate allocations; failure message is duped into `gpa`.
fn runFixture(orhon_path: []const u8, fixture_path: []const u8, gpa: std.mem.Allocator) !TestResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const content = try std.fs.cwd().readFileAlloc(alloc, fixture_path, 512 * 1024);

    const annotations = try scanAnnotationsFromContent(content, alloc);
    if (annotations.len == 0) return .skip;

    const module_name = extractModuleNameFromContent(content, alloc) catch
        return TestResult{ .setup_error = try gpa.dupe(u8, "missing module declaration") };

    // Build temp project path: /tmp/orhon-test-<ms>-<module>/
    const tmp_root = try std.fmt.allocPrint(alloc, "/tmp/orhon-test-{d}-{s}",
        .{ std.time.milliTimestamp(), module_name });
    const project_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tmp_root, module_name });
    const src_path     = try std.fmt.allocPrint(alloc, "{s}/src", .{project_path});
    const dest_file    = try std.fmt.allocPrint(alloc, "{s}/{s}.orh", .{ src_path, module_name });

    try std.fs.makeDirAbsolute(tmp_root);
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};
    try std.fs.makeDirAbsolute(project_path);
    try std.fs.makeDirAbsolute(src_path);

    const dest = try std.fs.createFileAbsolute(dest_file, .{});
    defer dest.close();
    try dest.writeAll(content);

    // Spawn orhon build --diag-format=json
    const child_args = &[_][]const u8{ orhon_path, "build", "--diag-format=json" };
    var child = std.process.Child.init(child_args, alloc);
    child.cwd             = project_path;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stderr_out = try child.stderr.?.readToEndAlloc(alloc, 512 * 1024);
    _ = try child.wait();

    // Diagnostics are written to stderr
    const actual = try parseJsonDiagnostics(stderr_out, alloc);
    const mismatches = try compareResults(annotations, actual, alloc);

    if (mismatches.len == 0) return .pass;

    // Format mismatch details into a GPA-owned string (arena freed after this fn)
    var msg = std.ArrayList(u8){};
    for (mismatches) |m| {
        switch (m) {
            .missing    => |ann|  try msg.writer(gpa).print("        missing:    [{s}] at line {d}\n", .{ ann.code,  ann.line }),
            .unexpected => |diag| try msg.writer(gpa).print("        unexpected: [{s}] at line {d}\n", .{ diag.code, diag.line }),
        }
    }
    return TestResult{ .fail = try msg.toOwnedSlice(gpa) };
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const raw_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, raw_args);

    if (raw_args.len < 3) {
        std.debug.print("usage: orhon-test-runner <orhon-path> <fixtures-dir>\n", .{});
        std.process.exit(1);
    }
    const orhon_path   = try std.fs.realpathAlloc(gpa, raw_args[1]);
    defer gpa.free(orhon_path);
    const fixtures_dir = try std.fs.realpathAlloc(gpa, raw_args[2]);
    defer gpa.free(fixtures_dir);

    var dir = try std.fs.openDirAbsolute(fixtures_dir, .{ .iterate = true });
    defer dir.close();

    var stdout_buf: [65536]u8 = undefined;
    var w = std.fs.File.stdout().writer(&stdout_buf);
    const out = &w.interface;

    var passed:  u32 = 0;
    var failed:  u32 = 0;
    var skipped: u32 = 0;

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".orh")) continue;

        // entry.path is invalidated on the next walker.next() call — dupe it now
        const rel_path = try gpa.dupe(u8, entry.path);
        defer gpa.free(rel_path);

        const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ fixtures_dir, rel_path });
        defer gpa.free(fixture_path);

        const result = try runFixture(orhon_path, fixture_path, gpa);

        switch (result) {
            .pass => {
                passed += 1;
                try out.print("  \x1b[32mPASS\x1b[0m  {s}\n", .{rel_path});
            },
            .skip => skipped += 1,
            .fail => |msg| {
                failed += 1;
                try out.print("  \x1b[31mFAIL\x1b[0m  {s}\n{s}", .{ rel_path, msg });
                gpa.free(msg);
            },
            .setup_error => |msg| {
                failed += 1;
                try out.print("  \x1b[31mERROR\x1b[0m {s}: {s}\n", .{ rel_path, msg });
                gpa.free(msg);
            },
        }
    }

    try out.print("\n{d}/{d} passed", .{ passed, passed + failed });
    if (skipped > 0) try out.print(" ({d} unenrolled skipped)", .{skipped});
    try out.print("\n", .{});
    try out.flush();

    if (failed > 0) std.process.exit(1);
}

// ── Unit tests ────────────────────────────────────────────────────────────────

test "scanAnnotations: no annotations returns empty" {
    const alloc = std.testing.allocator;
    const src = "module foo\nfunc main() void {}\n";
    const anns = try scanAnnotationsFromContent(src, alloc);
    defer { for (anns) |a| alloc.free(a.code); alloc.free(anns); }
    try std.testing.expectEqual(@as(usize, 0), anns.len);
}

test "scanAnnotations: single annotation" {
    const alloc = std.testing.allocator;
    const src = "module foo\n    var x: i32 = 0  //> [E2005]\n";
    const anns = try scanAnnotationsFromContent(src, alloc);
    defer { for (anns) |a| alloc.free(a.code); alloc.free(anns); }
    try std.testing.expectEqual(@as(usize, 1), anns.len);
    try std.testing.expectEqual(@as(u32, 2), anns[0].line);
    try std.testing.expectEqualStrings("E2005", anns[0].code);
}

test "scanAnnotations: multiple on one line" {
    const alloc = std.testing.allocator;
    const src = "func foo(a: i32 = 5, b: i32) void {}  //> [E2002] [E2028]\n";
    const anns = try scanAnnotationsFromContent(src, alloc);
    defer { for (anns) |a| alloc.free(a.code); alloc.free(anns); }
    try std.testing.expectEqual(@as(usize, 2), anns.len);
    try std.testing.expectEqualStrings("E2002", anns[0].code);
    try std.testing.expectEqualStrings("E2028", anns[1].code);
}

test "extractModuleName: basic" {
    const alloc = std.testing.allocator;
    const name = try extractModuleNameFromContent("module my_mod\nfunc f() void {}\n", alloc);
    defer alloc.free(name);
    try std.testing.expectEqualStrings("my_mod", name);
}

test "extractModuleName: missing returns error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.ModuleNotFound,
        extractModuleNameFromContent("func main() void {}\n", alloc));
}

test "compareResults: exact match is empty mismatches" {
    const alloc = std.testing.allocator;
    const expected = [_]Annotation{.{ .line = 5, .code = "E2005" }};
    const actual   = [_]Diag{      .{ .line = 5, .code = "E2005" }};
    const mm = try compareResults(&expected, &actual, alloc);
    defer alloc.free(mm);
    try std.testing.expectEqual(@as(usize, 0), mm.len);
}

test "compareResults: missing annotation" {
    const alloc = std.testing.allocator;
    const expected = [_]Annotation{.{ .line = 5, .code = "E2005" }};
    const mm = try compareResults(&expected, &[_]Diag{}, alloc);
    defer alloc.free(mm);
    try std.testing.expectEqual(@as(usize, 1), mm.len);
    try std.testing.expect(mm[0] == .missing);
}

test "compareResults: unexpected diagnostic" {
    const alloc = std.testing.allocator;
    const actual = [_]Diag{.{ .line = 3, .code = "E2013" }};
    const mm = try compareResults(&[_]Annotation{}, &actual, alloc);
    defer alloc.free(mm);
    try std.testing.expectEqual(@as(usize, 1), mm.len);
    try std.testing.expect(mm[0] == .unexpected);
}

test "parseJsonDiagnostics: single error" {
    const alloc = std.testing.allocator;
    const json =
        \\{"version":1,"diagnostics":[{"severity":"error","code":"E2005","message":"bad","file":"src/x.orh","line":5,"col":1}]}
    ;
    const diags = try parseJsonDiagnostics(json, alloc);
    defer { for (diags) |d| alloc.free(d.code); alloc.free(diags); }
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("E2005", diags[0].code);
    try std.testing.expectEqual(@as(u32, 5), diags[0].line);
}

test "parseJsonDiagnostics: skips warnings and notes" {
    const alloc = std.testing.allocator;
    const json =
        \\{"version":1,"diagnostics":[{"severity":"warning","code":"E2038","message":"w","line":3},{"severity":"note","message":"n","line":4}]}
    ;
    const diags = try parseJsonDiagnostics(json, alloc);
    defer alloc.free(diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "parseJsonDiagnostics: empty output returns empty slice" {
    const alloc = std.testing.allocator;
    const diags = try parseJsonDiagnostics("", alloc);
    defer alloc.free(diags);
    try std.testing.expectEqual(@as(usize, 0), diags.len);
}

test "parseJsonDiagnostics: multiple errors" {
    const alloc = std.testing.allocator;
    const json =
        \\{"version":1,"diagnostics":[{"severity":"error","code":"E0101","message":"a","line":9},{"severity":"error","code":"E0101","message":"b","line":12}]}
    ;
    const diags = try parseJsonDiagnostics(json, alloc);
    defer { for (diags) |d| alloc.free(d.code); alloc.free(diags); }
    try std.testing.expectEqual(@as(usize, 2), diags.len);
    try std.testing.expectEqual(@as(u32, 9),  diags[0].line);
    try std.testing.expectEqual(@as(u32, 12), diags[1].line);
}
