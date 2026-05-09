// init.zig — Project initialization and template scaffolding

const std = @import("std");

// ============================================================
// TEMPLATE CONSTANTS
// ============================================================

// Templates are embedded from src/templates/ at compile time.
// Never put multi-line file content inline in .zig source — use @embedFile instead.
const PROJECT_ORH_TEMPLATE      = @embedFile("templates/project.orh");
const PROJECT_MANIFEST_TEMPLATE = @embedFile("templates/orhon.project.template");

// Example module — single comptime array replaces individual @embedFile consts
const example_templates = [_]struct { name: []const u8, content: []const u8 }{
    .{ .name = "example.orh",        .content = @embedFile("templates/example/example.orh") },
    .{ .name = "control_flow.orh",   .content = @embedFile("templates/example/control_flow.orh") },
    .{ .name = "error_handling.orh", .content = @embedFile("templates/example/error_handling.orh") },
    .{ .name = "data_types.orh",     .content = @embedFile("templates/example/data_types.orh") },
    .{ .name = "strings.orh",        .content = @embedFile("templates/example/strings.orh") },
    .{ .name = "advanced.orh",       .content = @embedFile("templates/example/advanced.orh") },
    .{ .name = "blueprints.orh",     .content = @embedFile("templates/example/blueprints.orh") },
    .{ .name = "handles.orh",        .content = @embedFile("templates/example/handles.orh") },
};

// ============================================================
// STAMP HELPERS
// ============================================================

const STAMP_PATH = ".orh-cache/init.stamp";

fn writeStamp(allocator: std.mem.Allocator, base: []const u8, version: []const u8) !void {
    const cache_dir = try std.fs.path.join(allocator, &.{ base, ".orh-cache" });
    defer allocator.free(cache_dir);
    try std.fs.cwd().makePath(cache_dir);
    const stamp_path = try std.fs.path.join(allocator, &.{ base, ".orh-cache", "init.stamp" });
    defer allocator.free(stamp_path);
    const file = try std.fs.cwd().createFile(stamp_path, .{});
    defer file.close();
    try file.writeAll(version);
}

// Returns null if stamp file is missing. Caller owns returned slice.
fn readStamp(allocator: std.mem.Allocator) !?[]const u8 {
    const file = std.fs.cwd().openFile(STAMP_PATH, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 64) catch |err| switch (err) {
        error.FileTooBig => return null,
        else => return err,
    };
}

// ============================================================
// UPDATE
// ============================================================

pub fn updateProject(allocator: std.mem.Allocator, version: []const u8) !void {
    std.fs.cwd().access("orhon.project", .{}) catch {
        std.debug.print("error: no orhon.project found — run orhon init -update from a project directory\n", .{});
        return error.NotAProject;
    };

    const stamp = try readStamp(allocator);
    defer if (stamp) |s| allocator.free(s);

    if (stamp != null and std.mem.eql(u8, stamp.?, version)) {
        std.debug.print("already up to date ({s})\n", .{version});
        return;
    }

    const old_version: []const u8 = stamp orelse "(none)";

    try std.fs.cwd().makePath("src/example");

    inline for (example_templates) |entry| {
        const file_path = try std.fs.path.join(allocator, &.{ "src", "example", entry.name });
        defer allocator.free(file_path);
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(entry.content);
        std.debug.print("updated  {s}\n", .{file_path});
    }

    try writeStamp(allocator, ".", version);
    std.debug.print("stamp updated: {s} → {s}\n", .{ old_version, version });
}

// ============================================================
// PROJECT INITIALIZATION
// ============================================================

pub fn initProject(allocator: std.mem.Allocator, name: []const u8, in_place: bool, version: []const u8) !void {
    // Validate project name
    if (name.len == 0) {
        std.debug.print("error: project name cannot be empty\n", .{});
        return error.InvalidName;
    }
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') {
            std.debug.print("error: project name must contain only letters, numbers, - or _\n", .{});
            return error.InvalidName;
        }
    }

    // Create project directory, src/ and src/example/ subdirectories
    const base = if (in_place) "." else name;
    const src_dir_path = try std.fs.path.join(allocator, &.{ base, "src" });
    defer allocator.free(src_dir_path);
    try std.fs.cwd().makePath(src_dir_path);

    const example_dir_path = try std.fs.path.join(allocator, &.{ base, "src", "example" });
    defer allocator.free(example_dir_path);
    try std.fs.cwd().makePath(example_dir_path);

    // Write src/{name}.orh from template (skip if exists)
    // Template contains multiple {s} placeholders for the project name.
    // Loop over all placeholders — avoids allocPrint brace escaping issues.
    const project_orh_name = try std.fmt.allocPrint(allocator, "{s}.orh", .{name});
    defer allocator.free(project_orh_name);
    const project_orh_path = try std.fs.path.join(allocator, &.{ base, "src", project_orh_name });
    defer allocator.free(project_orh_path);

    if (std.fs.cwd().access(project_orh_path, .{})) |_| {
        // project file exists — don't overwrite
    } else |_| {
        const file = try std.fs.cwd().createFile(project_orh_path, .{});
        defer file.close();

        const placeholder = "{s}";
        var remaining: []const u8 = PROJECT_ORH_TEMPLATE;
        while (std.mem.indexOf(u8, remaining, placeholder)) |pos| {
            try file.writeAll(remaining[0..pos]);
            try file.writeAll(name);
            remaining = remaining[pos + placeholder.len..];
        }
        try file.writeAll(remaining);
    }

    // Write orhon.project manifest (skip if exists)
    const manifest_path = try std.fs.path.join(allocator, &.{ base, "orhon.project" });
    defer allocator.free(manifest_path);
    if (std.fs.cwd().access(manifest_path, .{})) |_| {
        // manifest exists — don't overwrite
    } else |_| {
        const mfile = try std.fs.cwd().createFile(manifest_path, .{});
        defer mfile.close();
        const mph = "{s}";
        var mrem: []const u8 = PROJECT_MANIFEST_TEMPLATE;
        while (std.mem.indexOf(u8, mrem, mph)) |pos| {
            try mfile.writeAll(mrem[0..pos]);
            try mfile.writeAll(name);
            mrem = mrem[pos + mph.len..];
        }
        try mfile.writeAll(mrem);
    }

    // Write example module files into src/example/ (skip each if exists)
    inline for (example_templates) |entry| {
        const file_path = try std.fs.path.join(allocator, &.{ base, "src", "example", entry.name });
        defer allocator.free(file_path);

        if (std.fs.cwd().access(file_path, .{})) |_| {
            // file exists — don't overwrite
        } else |_| {
            const file = try std.fs.cwd().createFile(file_path, .{});
            defer file.close();
            try file.writeAll(entry.content);
        }
    }

    std.debug.print("Created project '{s}'\n", .{name});
    std.debug.print("  {s}/orhon.project\n", .{base});
    std.debug.print("  {s}/src/\n", .{base});
    std.debug.print("  {s}/src/{s}.orh\n", .{ base, name });
    std.debug.print("  {s}/src/example/  ({d} files — language manual)\n", .{ base, example_templates.len });
    if (!in_place) {
        std.debug.print("\nGet started:\n", .{});
        std.debug.print("  cd {s}\n", .{name});
    } else {
        std.debug.print("\nGet started:\n", .{});
    }
    std.debug.print("  orhon build\n", .{});
    std.debug.print("  orhon run\n", .{});
    writeStamp(allocator, base, version) catch {};
}
