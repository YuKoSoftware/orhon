// manifest.zig — orhon.project manifest parser
const std    = @import("std");
const module = @import("module.zig");
const errors = @import("errors.zig");

pub const MANIFEST_FILE = "orhon.project";

pub const ManifestTarget = struct {
    name:       []const u8,    // allocator-owned
    build_type: module.BuildType,
};

pub const ProjectManifest = struct {
    name:    []const u8,         // allocator-owned
    version: ?[3]u64,
    targets: []ManifestTarget,   // allocator-owned slice; each target.name also owned

    pub fn deinit(self: ProjectManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.targets) |t| allocator.free(t.name);
        allocator.free(self.targets);
    }
};

/// Read and parse `orhon.project` from the current working directory.
/// Returns null (with errors reported) on missing file or parse failure.
pub fn readManifest(allocator: std.mem.Allocator, reporter: *errors.Reporter) !?ProjectManifest {
    const content = std.fs.cwd().readFileAlloc(allocator, MANIFEST_FILE, 64 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            _ = try reporter.report(.{ .code = .no_project_manifest,
                .message = "no orhon.project found in project root — run `orhon init` to create one" });
            return null;
        }
        return err;
    };
    defer allocator.free(content);
    return parse(allocator, reporter, content);
}

fn parse(allocator: std.mem.Allocator, reporter: *errors.Reporter, content: []const u8) !?ProjectManifest {
    var name: ?[]const u8 = null;
    // name is freed in the fail path; on success ownership transfers to ProjectManifest
    var succeeded = false;
    defer if (!succeeded) {
        if (name) |n| allocator.free(n);
    };

    var version: ?[3]u64 = null;
    var top_build: ?module.BuildType = null;

    var targets = std.ArrayListUnmanaged(ManifestTarget){};
    var targets_owned = false; // true once toOwnedSlice called
    defer if (!targets_owned) {
        for (targets.items) |t| allocator.free(t.name);
        targets.deinit(allocator);
    };

    var current_target: ?[]const u8 = null; // slice into content — valid during parse
    var current_build:  ?module.BuildType = null;
    var had_error = false;
    var line_num: u32 = 0;

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        line_num += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;

        if (!std.mem.startsWith(u8, line, "#")) {
            _ = try reporter.reportFmt(.manifest_parse_error,
                .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                "unexpected content in orhon.project — lines must start with '#'", .{});
            had_error = true;
            continue;
        }

        const body = line[1..]; // after '#'

        // #target <name> — flush previous section, start a new one
        if (std.mem.startsWith(u8, body, "target")) {
            const rest = body["target".len..];
            if (rest.len == 0 or rest[0] == ' ' or rest[0] == '\t') {
                const tname = std.mem.trim(u8, rest, " \t");
                // flush previous target
                if (current_target) |prev| {
                    if (current_build) |bt| {
                        try targets.append(allocator, .{
                            .name       = try allocator.dupe(u8, prev),
                            .build_type = bt,
                        });
                    } else {
                        _ = try reporter.reportFmt(.manifest_parse_error,
                            .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                            "target '{s}' is missing a #build declaration", .{prev});
                        had_error = true;
                    }
                }
                if (tname.len == 0) {
                    _ = try reporter.reportFmt(.manifest_parse_error,
                        .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                        "#target requires a name (e.g. '#target mygame')", .{});
                    had_error = true;
                    current_target = null;
                    current_build  = null;
                    continue;
                }
                current_target = tname;
                current_build  = null;
                continue;
            }
        }

        // #key = value
        const eq = std.mem.indexOf(u8, body, "=") orelse {
            _ = try reporter.reportFmt(.manifest_parse_error,
                .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                "expected '=' in manifest directive '#{s}'", .{body});
            had_error = true;
            continue;
        };
        const key = std.mem.trim(u8, body[0..eq], " \t");
        const val = std.mem.trim(u8, body[eq + 1..], " \t");

        if (std.mem.eql(u8, key, "name")) {
            if (current_target != null) {
                _ = try reporter.reportFmt(.manifest_parse_error,
                    .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                    "#name must appear before any #target sections", .{});
                had_error = true;
                continue;
            }
            if (name) |old| allocator.free(old);
            name = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "version")) {
            version = parseVersion(val) orelse {
                _ = try reporter.reportFmt(.manifest_parse_error,
                    .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                    "invalid version '{s}' — expected (major, minor, patch) e.g. (1, 0, 0)", .{val});
                had_error = true;
                continue;
            };
        } else if (std.mem.eql(u8, key, "build")) {
            const bt = parseBuildType(val) orelse {
                _ = try reporter.reportFmt(.manifest_parse_error,
                    .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                    "unknown build type '{s}' — expected 'exe', 'static', or 'dynamic'", .{val});
                had_error = true;
                continue;
            };
            if (current_target != null) {
                current_build = bt;
            } else {
                top_build = bt;
            }
        } else {
            _ = try reporter.reportFmt(.manifest_parse_error,
                .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                "unknown manifest key '#{s}' — supported: #name, #version, #build, #target", .{key});
            had_error = true;
        }
    }

    // flush last target section
    if (current_target) |prev| {
        if (current_build) |bt| {
            try targets.append(allocator, .{
                .name       = try allocator.dupe(u8, prev),
                .build_type = bt,
            });
        } else {
            _ = try reporter.reportFmt(.manifest_parse_error,
                .{ .file = MANIFEST_FILE, .line = line_num, .col = 1 },
                "target '{s}' is missing a #build declaration", .{prev});
            had_error = true;
        }
    }

    if (had_error) return null;

    const proj_name = name orelse {
        _ = try reporter.report(.{ .code = .manifest_parse_error,
            .message = "orhon.project is missing required field '#name'" });
        return null;
    };

    // Resolve single-target vs multi-target
    var final_targets: []ManifestTarget = undefined;
    if (targets.items.len > 0) {
        if (top_build != null) {
            _ = try reporter.report(.{ .code = .manifest_parse_error,
                .message = "orhon.project cannot mix top-level '#build' with '#target' sections" });
            return null;
        }
        final_targets  = try targets.toOwnedSlice(allocator);
        targets_owned  = true;
    } else {
        const bt = top_build orelse {
            _ = try reporter.report(.{ .code = .manifest_parse_error,
                .message = "orhon.project is missing required field '#build'" });
            return null;
        };
        const ft = try allocator.alloc(ManifestTarget, 1);
        errdefer allocator.free(ft);
        ft[0] = .{
            .name       = try allocator.dupe(u8, proj_name),
            .build_type = bt,
        };
        final_targets = ft;
    }

    succeeded = true;
    return ProjectManifest{
        .name    = proj_name,
        .version = version,
        .targets = final_targets,
    };
}

fn parseVersion(s: []const u8) ?[3]u64 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (!std.mem.startsWith(u8, trimmed, "(") or !std.mem.endsWith(u8, trimmed, ")")) return null;
    const inner = trimmed[1 .. trimmed.len - 1];
    var parts: [3]u64 = undefined;
    var idx: usize = 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |part| : (idx += 1) {
        if (idx >= 3) return null;
        parts[idx] = std.fmt.parseInt(u64, std.mem.trim(u8, part, " \t"), 10) catch return null;
    }
    if (idx != 3) return null;
    return parts;
}

fn parseBuildType(s: []const u8) ?module.BuildType {
    const map = std.StaticStringMap(module.BuildType).initComptime(.{
        .{ "exe",     .exe     },
        .{ "static",  .static  },
        .{ "dynamic", .dynamic },
    });
    return map.get(s);
}

// ── Tests ─────────────────────────────────────────────────────

test "parseVersion: valid triples" {
    try std.testing.expectEqual([3]u64{ 1, 0, 0 }, parseVersion("(1, 0, 0)").?);
    try std.testing.expectEqual([3]u64{ 2, 3, 4 }, parseVersion("(2, 3, 4)").?);
    try std.testing.expectEqual([3]u64{ 0, 1, 0 }, parseVersion("(0, 1, 0)").?);
}

test "parseVersion: invalid returns null" {
    try std.testing.expectEqual(@as(?[3]u64, null), parseVersion("1.0.0"));
    try std.testing.expectEqual(@as(?[3]u64, null), parseVersion("(1, 0)"));
    try std.testing.expectEqual(@as(?[3]u64, null), parseVersion("(1, 0, 0, 1)"));
    try std.testing.expectEqual(@as(?[3]u64, null), parseVersion("(a, b, c)"));
}

test "manifest: single-target" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name    = mygame
        \\#version = (1, 0, 0)
        \\#build   = exe
    );
    try std.testing.expect(result != null);
    const m = result.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("mygame", m.name);
    try std.testing.expectEqual([3]u64{ 1, 0, 0 }, m.version.?);
    try std.testing.expectEqual(@as(usize, 1), m.targets.len);
    try std.testing.expectEqualStrings("mygame", m.targets[0].name);
    try std.testing.expectEqual(module.BuildType.exe, m.targets[0].build_type);
}

test "manifest: library target" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name  = mylib
        \\#build = static
    );
    try std.testing.expect(result != null);
    const m = result.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(module.BuildType.static, m.targets[0].build_type);
}

test "manifest: multi-target" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name    = mygame
        \\#version = (1, 0, 0)
        \\
        \\#target game
        \\#build = exe
        \\
        \\#target server
        \\#build = exe
    );
    try std.testing.expect(result != null);
    const m = result.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("mygame", m.name);
    try std.testing.expectEqual(@as(usize, 2), m.targets.len);
    try std.testing.expectEqualStrings("game",   m.targets[0].name);
    try std.testing.expectEqualStrings("server", m.targets[1].name);
}

test "manifest: comments and blank lines ignored" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\// project manifest
        \\
        \\#name  = proj
        \\
        \\// build type
        \\#build = exe
    );
    try std.testing.expect(result != null);
    const m = result.?;
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("proj", m.name);
}

test "manifest: missing #name gives null + error" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter, "#build = exe");
    try std.testing.expectEqual(@as(?ProjectManifest, null), result);
    try std.testing.expect(reporter.hasErrors());
}

test "manifest: missing #build gives null + error" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter, "#name = proj");
    try std.testing.expectEqual(@as(?ProjectManifest, null), result);
    try std.testing.expect(reporter.hasErrors());
}

test "manifest: unknown key gives null + error" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name     = proj
        \\#optimize = fast
        \\#build    = exe
    );
    try std.testing.expectEqual(@as(?ProjectManifest, null), result);
    try std.testing.expect(reporter.hasErrors());
}

test "manifest: bad version format gives null + error" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name    = proj
        \\#version = 1.0.0
        \\#build   = exe
    );
    try std.testing.expectEqual(@as(?ProjectManifest, null), result);
    try std.testing.expect(reporter.hasErrors());
}

test "manifest: mixing top-level #build with #target gives null + error" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();
    const result = try parse(std.testing.allocator, &reporter,
        \\#name  = proj
        \\#build = exe
        \\#target other
        \\#build = exe
    );
    try std.testing.expectEqual(@as(?ProjectManifest, null), result);
    try std.testing.expect(reporter.hasErrors());
}
