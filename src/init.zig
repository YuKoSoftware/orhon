// init.zig — Project initialization and template scaffolding

const std = @import("std");

// ============================================================
// TEMPLATE CONSTANTS
// ============================================================

// Templates are embedded from src/templates/ at compile time.
// Never put multi-line file content inline in .zig source — use @embedFile instead.
const MAIN_ORH_TEMPLATE         = @embedFile("templates/main.orh");

// Example module — split across multiple files in templates/example/
const EXAMPLE_ORH_TEMPLATE      = @embedFile("templates/example/example.orh");
const CONTROL_FLOW_ORH_TEMPLATE = @embedFile("templates/example/control_flow.orh");
const ERROR_HANDLING_TEMPLATE   = @embedFile("templates/example/error_handling.orh");
const DATA_TYPES_TEMPLATE       = @embedFile("templates/example/data_types.orh");
const STRINGS_TEMPLATE          = @embedFile("templates/example/strings.orh");
const ADVANCED_TEMPLATE         = @embedFile("templates/example/advanced.orh");
const BLUEPRINTS_TEMPLATE       = @embedFile("templates/example/blueprints.orh");

// ============================================================
// PROJECT INITIALIZATION
// ============================================================

pub fn initProject(allocator: std.mem.Allocator, name: []const u8, in_place: bool) !void {
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

    // Write src/main.orh from template (skip if exists)
    // Template contains a single {s} placeholder for the project name.
    // Split on it and write in two parts — avoids allocPrint brace escaping issues.
    const main_orh_path = try std.fs.path.join(allocator, &.{ base, "src", "main.orh" });
    defer allocator.free(main_orh_path);

    if (std.fs.cwd().access(main_orh_path, .{})) |_| {
        // main.orh exists — don't overwrite
    } else |_| {
        const main_file = try std.fs.cwd().createFile(main_orh_path, .{});
        defer main_file.close();

        const placeholder = "{s}";
        if (std.mem.indexOf(u8, MAIN_ORH_TEMPLATE, placeholder)) |pos| {
            try main_file.writeAll(MAIN_ORH_TEMPLATE[0..pos]);
            try main_file.writeAll(name);
            try main_file.writeAll(MAIN_ORH_TEMPLATE[pos + placeholder.len..]);
        } else {
            try main_file.writeAll(MAIN_ORH_TEMPLATE);
        }
    }

    // Write example module files into src/example/ (skip each if exists)
    const example_files = .{
        .{ "example.orh",        EXAMPLE_ORH_TEMPLATE },
        .{ "control_flow.orh",   CONTROL_FLOW_ORH_TEMPLATE },
        .{ "error_handling.orh", ERROR_HANDLING_TEMPLATE },
        .{ "data_types.orh",     DATA_TYPES_TEMPLATE },
        .{ "strings.orh",        STRINGS_TEMPLATE },
        .{ "advanced.orh",       ADVANCED_TEMPLATE },
        .{ "blueprints.orh",    BLUEPRINTS_TEMPLATE },
    };

    inline for (example_files) |entry| {
        const file_path = try std.fs.path.join(allocator, &.{ base, "src", "example", entry[0] });
        defer allocator.free(file_path);

        if (std.fs.cwd().access(file_path, .{})) |_| {
            // file exists — don't overwrite
        } else |_| {
            const file = try std.fs.cwd().createFile(file_path, .{});
            defer file.close();
            try file.writeAll(entry[1]);
        }
    }

    std.debug.print("Created project '{s}'\n", .{name});
    std.debug.print("  {s}/src/\n", .{base});
    std.debug.print("  {s}/src/main.orh\n", .{base});
    std.debug.print("  {s}/src/example/  (6 files — language manual)\n", .{base});
    if (!in_place) {
        std.debug.print("\nGet started:\n", .{});
        std.debug.print("  cd {s}\n", .{name});
    } else {
        std.debug.print("\nGet started:\n", .{});
    }
    std.debug.print("  orhon build\n", .{});
    std.debug.print("  orhon run\n", .{});
}
