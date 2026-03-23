// main.zig — Orhon compiler entry point
// CLI argument parsing and pipeline orchestration.
// No business logic here — delegates to each pass.

const std = @import("std");
const build_options = @import("build_options");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const module = @import("module.zig");
const declarations = @import("declarations.zig");
const resolver = @import("resolver.zig");
const ownership = @import("ownership.zig");
const borrow = @import("borrow.zig");
const thread_safety = @import("thread_safety.zig");
const propagation = @import("propagation.zig");
const mir = @import("mir.zig");
const codegen = @import("codegen.zig");
const zig_runner = @import("zig_runner.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");

// ============================================================
// CLI
// ============================================================

const Command = enum {
    build,
    run,
    @"test",
    init,
    addtopath,
    debug,
    version,
    fmt,
    gendoc,
    lsp,
    which,
    help,
};

const BuildTarget = enum {
    native,
    linux_x64,
    linux_arm,
    win_x64,
    mac_x64,
    mac_arm,
    wasm,
    zig, // emit Zig source project

    fn toZigTriple(self: BuildTarget) []const u8 {
        return switch (self) {
            .native => "",
            .linux_x64 => "x86_64-linux",
            .linux_arm => "aarch64-linux",
            .win_x64 => "x86_64-windows",
            .mac_x64 => "x86_64-macos",
            .mac_arm => "aarch64-macos",
            .wasm => "wasm32-freestanding",
            .zig => "",
        };
    }

    fn folderName(self: BuildTarget) []const u8 {
        return switch (self) {
            .native => "native",
            .linux_x64 => "linux_x64",
            .linux_arm => "linux_arm",
            .win_x64 => "win_x64",
            .mac_x64 => "mac_x64",
            .mac_arm => "mac_arm",
            .wasm => "wasm",
            .zig => "zig",
        };
    }
};

const OptLevel = enum {
    debug,
    fast,
    small,
};

const CliArgs = struct {
    command: Command,
    targets: std.ArrayListUnmanaged(BuildTarget),
    optimize: OptLevel,
    verbose: bool,        // -verbose flag (show Zig compiler output)
    source_dir: []const u8,
    project_name: []const u8, // for init command
    init_in_place: bool, // orhon init (no name) — init in current dir
    allocator: std.mem.Allocator, // owns duped strings

    pub fn deinit(self: *const CliArgs) void {
        if (self.project_name.len > 0) self.allocator.free(self.project_name);
        if (!std.mem.eql(u8, self.source_dir, "src")) self.allocator.free(self.source_dir);
        @constCast(&self.targets).deinit(self.allocator);
    }
};

fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    var cli = CliArgs{
        .command = .help,
        .targets = .{},
        .optimize = .debug,
        .verbose = false,
        .source_dir = "src",
        .project_name = "",
        .init_in_place = false,
        .allocator = allocator,
    };

    // Parse command
    const cmd_str = args[1];
    if (std.mem.eql(u8, cmd_str, "build")) {
        cli.command = .build;
    } else if (std.mem.eql(u8, cmd_str, "run")) {
        cli.command = .run;
    } else if (std.mem.eql(u8, cmd_str, "test")) {
        cli.command = .@"test";
    } else if (std.mem.eql(u8, cmd_str, "init")) {
        cli.command = .init;
        if (args.len >= 3) {
            cli.project_name = try allocator.dupe(u8, args[2]);
        } else {
            // No name given — init in current directory, use dir name as project name
            cli.init_in_place = true;
            const cwd_path = try std.process.getCwdAlloc(allocator);
            defer allocator.free(cwd_path);
            const dir_name = std.fs.path.basename(cwd_path);
            if (dir_name.len == 0) {
                std.debug.print("error: could not determine project name from current directory\n", .{});
                std.process.exit(1);
            }
            cli.project_name = try allocator.dupe(u8, dir_name);
        }
    } else if (std.mem.eql(u8, cmd_str, "debug")) {
        cli.command = .debug;
    } else if (std.mem.eql(u8, cmd_str, "fmt")) {
        cli.command = .fmt;
    } else if (std.mem.eql(u8, cmd_str, "gendoc")) {
        cli.command = .gendoc;
    } else if (std.mem.eql(u8, cmd_str, "addtopath") or std.mem.eql(u8, cmd_str, "-addtopath")) {
        cli.command = .addtopath;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version")) {
        cli.command = .version;
    } else if (std.mem.eql(u8, cmd_str, "lsp")) {
        cli.command = .lsp;
    } else if (std.mem.eql(u8, cmd_str, "which")) {
        cli.command = .which;
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help")) {
        cli.command = .help;
    } else {
        printUsage();
        std.process.exit(1);
    }

    // Parse flags
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-linux_x64")) {
            try cli.targets.append(allocator, .linux_x64);
        } else if (std.mem.eql(u8, arg, "-linux_arm")) {
            try cli.targets.append(allocator, .linux_arm);
        } else if (std.mem.eql(u8, arg, "-win_x64")) {
            try cli.targets.append(allocator, .win_x64);
        } else if (std.mem.eql(u8, arg, "-mac_x64")) {
            try cli.targets.append(allocator, .mac_x64);
        } else if (std.mem.eql(u8, arg, "-mac_arm")) {
            try cli.targets.append(allocator, .mac_arm);
        } else if (std.mem.eql(u8, arg, "-wasm")) {
            try cli.targets.append(allocator, .wasm);
        } else if (std.mem.eql(u8, arg, "-zig")) {
            try cli.targets.append(allocator, .zig);
        } else if (std.mem.eql(u8, arg, "-fast")) {
            cli.optimize = .fast;
        } else if (std.mem.eql(u8, arg, "-small")) {
            cli.optimize = .small;
        } else if (std.mem.eql(u8, arg, "-verbose")) {
            cli.verbose = true;
        } else {
            // Treat as source directory
            cli.source_dir = try allocator.dupe(u8, arg);
        }
    }

    return cli;
}

fn printUsage() void {
    const usage =
        \\orhon — The Orhon compiler  (orhon help for more info)
        \\
        \\  build   run   test   fmt   gendoc   init   lsp   addtopath   debug   version
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printHelp() void {
    const help =
        \\orhon — The Orhon programming language compiler
        \\
        \\Commands:
        \\  build               Compile the project in the current directory
        \\  run                 Build and immediately execute the binary
        \\  test                Run all test { } blocks in the project
        \\  init [name]         Create a new project (in ./<name>/ or current dir if no name)
        \\  fmt                 Format all .orh files in the project
        \\  gendoc              Generate Markdown docs from /// comments (pub items)
        \\  lsp                 Start the language server (for editor integration)
        \\  addtopath           Add orhon to your shell PATH
        \\  debug               Show project info — modules, files, source directory
        \\  version             Print the compiler version
        \\
        \\Targets (combinable — e.g. orhon build -linux_x64 -win_x64):
        \\  -linux_x64          Linux x86-64
        \\  -linux_arm          Linux ARM64
        \\  -win_x64            Windows x86-64
        \\  -mac_x64            macOS x86-64
        \\  -mac_arm            macOS ARM64 (Apple Silicon)
        \\  -wasm               WebAssembly
        \\  -zig                Emit Zig source project (no binary)
        \\
        \\Build flags:
        \\  -fast               Maximum speed optimization
        \\  -small              Minimum binary size optimization
        \\  -verbose            Show raw Zig compiler output
        \\
    ;
    std.debug.print("{s}", .{help});
}

// ============================================================
// PIPELINE
// ============================================================



// ============================================================
// PROJECT INIT
// ============================================================

// Templates are embedded from src/templates/ at compile time.
// Never put multi-line file content inline in .zig source — use @embedFile instead.
const MAIN_ORH_TEMPLATE         = @embedFile("templates/main.orh");

// Example module — split across multiple files in templates/example/
const EXAMPLE_ORH_TEMPLATE      = @embedFile("templates/example/example.orh");
const CONTROL_FLOW_ORH_TEMPLATE = @embedFile("templates/example/control_flow.orh");
const ERROR_HANDLING_TEMPLATE   = @embedFile("templates/example/error_handling.orh");
const DATA_TYPES_TEMPLATE       = @embedFile("templates/example/data_types.orh");


fn initProject(allocator: std.mem.Allocator, name: []const u8, in_place: bool) !void {
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
    std.debug.print("  {s}/src/example/  (4 files — language manual)\n", .{base});
    if (!in_place) {
        std.debug.print("\nGet started:\n", .{});
        std.debug.print("  cd {s}\n", .{name});
    } else {
        std.debug.print("\nGet started:\n", .{});
    }
    std.debug.print("  orhon build\n", .{});
    std.debug.print("  orhon run\n", .{});
}

// ============================================================
// STD INIT
// ============================================================

const RT_ORH = @embedFile("std/_rt.orh");
const RT_ZIG = @embedFile("std/_rt.zig");
const COLLECTIONS_ORH = @embedFile("std/collections.orh");
const COLLECTIONS_ZIG = @embedFile("std/collections.zig");
const ALLOCATOR_ORH = @embedFile("std/allocator.orh");
const ALLOCATOR_ZIG = @embedFile("std/allocator.zig");
const CONSOLE_ORH = @embedFile("std/console.orh");
const CONSOLE_ZIG = @embedFile("std/console.zig");
const FS_ORH      = @embedFile("std/fs.orh");
const FS_ZIG      = @embedFile("std/fs.zig");
const MATH_ORH    = @embedFile("std/math.orh");
const MATH_ZIG    = @embedFile("std/math.zig");
const STR_ORH     = @embedFile("std/str.orh");
const STR_ZIG     = @embedFile("std/str.zig");
const SYSTEM_ORH  = @embedFile("std/system.orh");
const SYSTEM_ZIG  = @embedFile("std/system.zig");
const TIME_ORH    = @embedFile("std/time.orh");
const TIME_ZIG    = @embedFile("std/time.zig");
const JSON_ORH    = @embedFile("std/json.orh");
const JSON_ZIG    = @embedFile("std/json.zig");
const SORT_ORH    = @embedFile("std/sort.orh");
const SORT_ZIG    = @embedFile("std/sort.zig");
const RANDOM_ORH  = @embedFile("std/random.orh");
const RANDOM_ZIG  = @embedFile("std/random.zig");
const ZIGLIB_ORH  = @embedFile("std/ziglib.orh");
const ZIGLIB_ZIG  = @embedFile("std/ziglib.zig");
const ENCODING_ORH = @embedFile("std/encoding.orh");
const ENCODING_ZIG = @embedFile("std/encoding.zig");
const STREAM_ORH   = @embedFile("std/stream.orh");
const STREAM_ZIG   = @embedFile("std/stream.zig");
const CRYPTO_ORH   = @embedFile("std/crypto.orh");
const CRYPTO_ZIG   = @embedFile("std/crypto.zig");
const COMPRESS_ORH = @embedFile("std/compression.orh");
const COMPRESS_ZIG = @embedFile("std/compression.zig");
const XML_ORH      = @embedFile("std/xml.orh");
const XML_ZIG      = @embedFile("std/xml.zig");
const CSV_ORH      = @embedFile("std/csv.orh");
const CSV_ZIG      = @embedFile("std/csv.zig");
const TESTING_ORH  = @embedFile("std/testing.orh");
const TESTING_ZIG  = @embedFile("std/testing.zig");
const NET_ORH      = @embedFile("std/net.orh");
const NET_ZIG      = @embedFile("std/net.zig");
const HTTP_ORH     = @embedFile("std/http.orh");
const HTTP_ZIG     = @embedFile("std/http.zig");
const REGEX_ORH    = @embedFile("std/regex.orh");
const REGEX_ZIG    = @embedFile("std/regex.zig");
const INI_ORH      = @embedFile("std/ini.orh");
const INI_ZIG      = @embedFile("std/ini.zig");
const TOML_ORH     = @embedFile("std/toml.orh");
const TOML_ZIG     = @embedFile("std/toml.zig");
const SIMD_ORH     = @embedFile("std/simd.orh");
const SIMD_ZIG     = @embedFile("std/simd.zig");
const TUI_ORH      = @embedFile("std/tui.orh");
const TUI_ZIG      = @embedFile("std/tui.zig");
const YAML_ORH     = @embedFile("std/yaml.orh");
const YAML_ZIG     = @embedFile("std/yaml.zig");
const LINEAR_ORH   = @embedFile("std/linear.orh");

/// Write an embedded file to .orh-cache/std/ if it doesn't already exist
fn writeStdFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    };
}

/// Ensure all embedded std files exist in .orh-cache/std/
fn ensureStdFiles(allocator: std.mem.Allocator) !void {
    const std_dir = cache.CACHE_DIR ++ "/std";
    try std.fs.cwd().makePath(std_dir);

    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "_rt.orh",       .content = RT_ORH },
        .{ .name = "_rt.zig",       .content = RT_ZIG },
        .{ .name = "collections.orh", .content = COLLECTIONS_ORH },
        .{ .name = "collections.zig", .content = COLLECTIONS_ZIG },
        .{ .name = "allocator.orh", .content = ALLOCATOR_ORH },
        .{ .name = "allocator.zig", .content = ALLOCATOR_ZIG },
        .{ .name = "console.orh", .content = CONSOLE_ORH },
        .{ .name = "console.zig", .content = CONSOLE_ZIG },
        .{ .name = "fs.orh",      .content = FS_ORH },
        .{ .name = "fs.zig",      .content = FS_ZIG },
        .{ .name = "math.orh",    .content = MATH_ORH },
        .{ .name = "math.zig",    .content = MATH_ZIG },
        .{ .name = "str.orh",     .content = STR_ORH },
        .{ .name = "str.zig",     .content = STR_ZIG },
        .{ .name = "system.orh",  .content = SYSTEM_ORH },
        .{ .name = "system.zig",  .content = SYSTEM_ZIG },
        .{ .name = "time.orh",    .content = TIME_ORH },
        .{ .name = "time.zig",    .content = TIME_ZIG },
        .{ .name = "json.orh",    .content = JSON_ORH },
        .{ .name = "json.zig",    .content = JSON_ZIG },
        .{ .name = "sort.orh",    .content = SORT_ORH },
        .{ .name = "sort.zig",    .content = SORT_ZIG },
        .{ .name = "random.orh",  .content = RANDOM_ORH },
        .{ .name = "random.zig",  .content = RANDOM_ZIG },
        .{ .name = "ziglib.orh",  .content = ZIGLIB_ORH },
        .{ .name = "ziglib.zig",  .content = ZIGLIB_ZIG },
        .{ .name = "encoding.orh", .content = ENCODING_ORH },
        .{ .name = "encoding.zig", .content = ENCODING_ZIG },
        .{ .name = "stream.orh",   .content = STREAM_ORH },
        .{ .name = "stream.zig",   .content = STREAM_ZIG },
        .{ .name = "crypto.orh",   .content = CRYPTO_ORH },
        .{ .name = "crypto.zig",   .content = CRYPTO_ZIG },
        .{ .name = "compression.orh", .content = COMPRESS_ORH },
        .{ .name = "compression.zig", .content = COMPRESS_ZIG },
        .{ .name = "xml.orh",         .content = XML_ORH },
        .{ .name = "xml.zig",         .content = XML_ZIG },
        .{ .name = "csv.orh",         .content = CSV_ORH },
        .{ .name = "csv.zig",         .content = CSV_ZIG },
        .{ .name = "testing.orh",     .content = TESTING_ORH },
        .{ .name = "testing.zig",     .content = TESTING_ZIG },
        .{ .name = "net.orh",         .content = NET_ORH },
        .{ .name = "net.zig",         .content = NET_ZIG },
        .{ .name = "http.orh",        .content = HTTP_ORH },
        .{ .name = "http.zig",        .content = HTTP_ZIG },
        .{ .name = "regex.orh",       .content = REGEX_ORH },
        .{ .name = "regex.zig",       .content = REGEX_ZIG },
        .{ .name = "ini.orh",         .content = INI_ORH },
        .{ .name = "ini.zig",         .content = INI_ZIG },
        .{ .name = "toml.orh",        .content = TOML_ORH },
        .{ .name = "toml.zig",        .content = TOML_ZIG },
        .{ .name = "simd.orh",        .content = SIMD_ORH },
        .{ .name = "simd.zig",        .content = SIMD_ZIG },
        .{ .name = "tui.orh",         .content = TUI_ORH },
        .{ .name = "tui.zig",         .content = TUI_ZIG },
        .{ .name = "yaml.orh",        .content = YAML_ORH },
        .{ .name = "yaml.zig",        .content = YAML_ZIG },
        .{ .name = "linear.orh",      .content = LINEAR_ORH },
    };

    for (files) |f| {
        try writeStdFile(std_dir, f.name, f.content, allocator);
    }
}



// ============================================================
// PATH INSTALLATION
// ============================================================

fn addToPath(allocator: std.mem.Allocator) !void {
    // Get the directory containing the orhon binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    // Check if already in PATH
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch "";
    defer if (path_env.len > 0) allocator.free(path_env);

    if (std.mem.indexOf(u8, path_env, exe_dir) != null) {
        std.debug.print("orhon is already in PATH ({s})\n", .{exe_dir});
        return;
    }

    // Find the right shell profile to update
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("error: $HOME not set\n", .{});
        return error.NoHome;
    };
    defer allocator.free(home);

    // Determine shell and profile file
    const shell = std.process.getEnvVarOwned(allocator, "SHELL") catch "";
    defer if (shell.len > 0) allocator.free(shell);

    const profile_name: []const u8 = blk: {
        if (std.mem.endsWith(u8, shell, "zsh"))  break :blk ".zshrc";
        if (std.mem.endsWith(u8, shell, "fish")) break :blk ".config/fish/config.fish";
        break :blk ".bashrc"; // default to bash
    };

    const profile_path = try std.fs.path.join(allocator, &.{ home, profile_name });
    defer allocator.free(profile_path);

    // The line to append
    const export_line = try std.fmt.allocPrint(allocator,
        "\n# orhon compiler\nexport PATH=\"$PATH:{s}\"\n",
        .{exe_dir});
    defer allocator.free(export_line);

    // Fish uses a different syntax
    const fish_line = try std.fmt.allocPrint(allocator,
        "\n# orhon compiler\nfish_add_path {s}\n",
        .{exe_dir});
    defer allocator.free(fish_line);

    const line_to_write = if (std.mem.endsWith(u8, shell, "fish"))
        fish_line
    else
        export_line;

    // For fish, ensure the config directory exists first
    if (std.mem.endsWith(u8, shell, "fish")) {
        const fish_config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "fish" });
        defer allocator.free(fish_config_dir);
        try std.fs.cwd().makePath(fish_config_dir);
    }

    // Read existing profile to check for a previous orhon entry
    const existing = std.fs.cwd().readFileAlloc(allocator, profile_path, 1024 * 1024) catch "";
    defer if (existing.len > 0) allocator.free(existing);

    const marker = "# orhon compiler";

    if (std.mem.indexOf(u8, existing, marker)) |start| {
        // Find the end of the orhon block (marker line + export/path line)
        // Look for the next newline after the export line
        const after_marker = start + marker.len;
        // Skip the marker line's newline
        const after_first_nl = if (after_marker < existing.len and existing[after_marker] == '\n')
            after_marker + 1
        else
            after_marker;
        // Find end of the export/path line
        const end = if (std.mem.indexOfPos(u8, existing, after_first_nl, "\n")) |nl|
            nl + 1
        else
            existing.len;

        // Also trim a leading newline before the marker if present
        const real_start = if (start > 0 and existing[start - 1] == '\n') start - 1 else start;

        // Rewrite the file with the old entry replaced
        const file = try std.fs.cwd().createFile(profile_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(existing[0..real_start]);
        try file.writeAll(line_to_write);
        try file.writeAll(existing[end..]);

        std.debug.print("Updated orhon PATH in {s} (replaced old entry)\n", .{profile_path});
    } else {
        // No existing entry — append
        const file = try std.fs.cwd().createFile(profile_path, .{ .truncate = false, .exclusive = false });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line_to_write);

        std.debug.print("Added orhon to PATH in {s}\n", .{profile_path});
    }
    std.debug.print("Run: source {s}\n", .{profile_path});
    std.debug.print("  or open a new terminal\n", .{});
}

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    var cli = try parseArgs(allocator);
    defer cli.deinit();

    // Handle init and addtopath before setting up the full pipeline
    if (cli.command == .init) {
        initProject(allocator, cli.project_name, cli.init_in_place) catch |err| {
            std.debug.print("error: failed to create project: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .addtopath) {
        addToPath(allocator) catch |err| {
            std.debug.print("error: failed to add orhon to PATH: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .fmt) {
        const formatter = @import("formatter.zig");
        try formatter.formatProject(allocator, cli.source_dir);
        return;
    }

    if (cli.command == .gendoc) {
        try runGendoc(allocator, &cli);
        return;
    }

    if (cli.command == .lsp) {
        const lsp = @import("lsp.zig");
        try lsp.serve(allocator);
        return;
    }

    if (cli.command == .which) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fs.selfExePath(&buf) catch {
            std.debug.print("error: could not resolve executable path\n", .{});
            std.process.exit(1);
        };
        const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        var buf2: [4096]u8 = undefined;
        var w = stdout_file.writer(&buf2);
        const writer = &w.interface;
        writer.writeAll(path) catch {};
        writer.writeAll("\n") catch {};
        writer.flush() catch {};
        return;
    }

    if (cli.command == .debug) {
        try runDebug(allocator, &cli);
        return;
    }

    if (cli.command == .help) {
        printHelp();
        return;
    }

    if (cli.command == .version) {
        std.debug.print("orhon {s}\n", .{build_options.version});
        return;
    }

    const mode: errors.BuildMode = if (cli.optimize == .fast or cli.optimize == .small)
        .release
    else
        .debug;

    var reporter = errors.Reporter.init(allocator, mode);
    defer reporter.deinit();

    // Run the pipeline
    const binary_name = runPipeline(allocator, &cli, &reporter) catch |err| blk: {
        switch (err) {
            error.ParseError, error.CompileError => {},
            else => return err,
        }
        break :blk null;
    };

    // Flush all errors
    try reporter.flush();

    if (binary_name == null or reporter.hasErrors()) {
        std.process.exit(1);
    }
    defer allocator.free(binary_name.?);

    // orhon run — execute the built binary
    if (cli.command == .run) {
        const bin_path = try std.fmt.allocPrint(allocator, "bin/{s}", .{binary_name.?});
        defer allocator.free(bin_path);

        var child = std.process.Child.init(&.{bin_path}, allocator);
        _ = child.spawnAndWait() catch |err| {
            std.debug.print("error: failed to run bin/{s}: {}\n", .{ binary_name.?, err });
            std.process.exit(1);
        };
    }
}

fn runDebug(allocator: std.mem.Allocator, cli: *const CliArgs) !void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExePath(&exe_buf) catch "<unknown>";

    std.debug.print("=== orhon debug ===\n", .{});
    std.debug.print("  binary:     {s}\n", .{exe_path});
    std.debug.print("  source_dir: {s}\n", .{cli.source_dir});

    // Check if source_dir exists
    const dir_exists = blk: {
        std.fs.cwd().access(cli.source_dir, .{}) catch break :blk false;
        break :blk true;
    };
    std.debug.print("  dir exists: {}\n\n", .{dir_exists});

    if (!dir_exists) {
        std.debug.print("ERROR: source directory '{s}' not found.\n", .{cli.source_dir});
        std.debug.print("  Run `orhon build` from inside an orhon project directory.\n", .{});
        return;
    }

    // Scan and report every .orh file found
    var reporter = errors.Reporter.init(allocator, .debug);
    defer reporter.deinit();

    var mod_resolver = module.Resolver.init(allocator, &reporter);
    defer mod_resolver.deinit();

    try mod_resolver.scanDirectory(cli.source_dir);

    std.debug.print("modules found: {d}\n", .{mod_resolver.modules.count()});

    var it = mod_resolver.modules.iterator();
    while (it.next()) |entry| {
        const mod = entry.value_ptr;
        std.debug.print("\n  module '{s}'\n", .{mod.name});
        std.debug.print("    files ({d}):\n", .{mod.files.len});
        for (mod.files) |file| {
            std.debug.print("      {s}\n", .{file});
        }
    }

    if (mod_resolver.modules.count() == 0) {
        std.debug.print("  (no .orh files found in '{s}')\n", .{cli.source_dir});
    }

    std.debug.print("\n", .{});
}

fn runGendoc(allocator: std.mem.Allocator, cli: *const CliArgs) !void {
    const docgen = @import("docgen.zig");

    // Ensure std files are available (parsing may discover std imports)
    try ensureStdFiles(allocator);

    // Check source dir exists
    std.fs.cwd().access(cli.source_dir, .{}) catch {
        std.debug.print("error: source directory '{s}' not found\n", .{cli.source_dir});
        return;
    };

    var reporter = errors.Reporter.init(allocator, .debug);
    defer reporter.deinit();

    var mod_resolver = module.Resolver.init(allocator, &reporter);
    defer mod_resolver.deinit();

    try mod_resolver.scanDirectory(cli.source_dir);

    if (reporter.hasErrors()) {
        try reporter.flush();
        return;
    }

    // Parse all modules (two passes for std imports)
    try mod_resolver.parseModules(allocator);
    if (reporter.hasErrors()) {
        try reporter.flush();
        return;
    }
    // Second pass: parse any newly discovered std modules
    {
        var has_unparsed = false;
        var check_it = mod_resolver.modules.iterator();
        while (check_it.next()) |entry| {
            if (entry.value_ptr.ast == null) { has_unparsed = true; break; }
        }
        if (has_unparsed) {
            try mod_resolver.parseModules(allocator);
        }
    }

    if (reporter.hasErrors()) {
        try reporter.flush();
        return;
    }

    // Output to docs/api/{source_dir_name}/
    const dir_name = std.fs.path.basename(cli.source_dir);
    const output_dir = try std.fmt.allocPrint(allocator, "docs/api/{s}", .{dir_name});
    defer allocator.free(output_dir);
    try docgen.generateDocs(allocator, &mod_resolver, output_dir);
}

fn runPipeline(allocator: std.mem.Allocator, cli: *CliArgs, reporter: *errors.Reporter) !?[]const u8 {

    // Ensure embedded std files exist in .orh-cache/std/
    try ensureStdFiles(allocator);

    // Copy internal bridges to generated dir — always available for all modules
    try cache.ensureGeneratedDir();
    {
        const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_rt.zig", .{});
        defer file.close();
        try file.writeAll(RT_ZIG);
    }
    {
        const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_str.zig", .{});
        defer file.close();
        try file.writeAll(STR_ZIG);
    }
    {
        const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_collections.zig", .{});
        defer file.close();
        try file.writeAll(COLLECTIONS_ZIG);
    }

    // ── Pass 3: Module Resolution ──────────────────────────────
    var mod_resolver = module.Resolver.init(allocator, reporter);
    defer mod_resolver.deinit();

    // Check source dir exists before scanning — give a clear error if not
    std.fs.cwd().access(cli.source_dir, .{}) catch {
        std.debug.print("error: source directory '{s}' not found\n", .{cli.source_dir});
        std.debug.print("  run `orhon build` from inside an orhon project directory\n", .{});
        std.debug.print("  expected: {s}/main.orh\n", .{cli.source_dir});
        return null;
    };

    try mod_resolver.scanDirectory(cli.source_dir);

    if (reporter.hasErrors()) return null;

    // Check circular imports
    try mod_resolver.checkCircularImports();
    if (reporter.hasErrors()) return null;

    // Load incremental cache
    var comp_cache = cache.Cache.init(allocator);
    defer comp_cache.deinit();
    try comp_cache.loadTimestamps();
    try comp_cache.loadDeps();

    // Parse all modules — two passes to catch std imports discovered during parsing.
    // First pass parses project modules and discovers std imports (adds them to map).
    // Second pass parses the newly discovered std modules.
    try mod_resolver.parseModules(allocator);
    if (reporter.hasErrors()) return null;
    // Second pass: only if new modules were added (std imports)
    {
        var has_unparsed = false;
        var check_it = mod_resolver.modules.iterator();
        while (check_it.next()) |entry| {
            if (entry.value_ptr.ast == null) { has_unparsed = true; break; }
        }
        if (has_unparsed) {
            try mod_resolver.parseModules(allocator);
            if (reporter.hasErrors()) return null;
        }
    }

    // Scan and parse any #dep directories declared in the root module
    try mod_resolver.scanAndParseDeps(allocator, cli.source_dir);
    if (reporter.hasErrors()) return null;

    // Validate all imports — report any modules that were imported but not found
    try mod_resolver.validateImports(reporter);
    if (reporter.hasErrors()) return null;

    // Get compilation order
    const order = try mod_resolver.topologicalOrder(allocator);
    defer allocator.free(order);

    // Build module build-type map for codegen — lets import generation
    // distinguish lib targets (linked via build system) from source modules
    var module_builds = std.StringHashMapUnmanaged(module.BuildType){};
    defer module_builds.deinit(allocator);
    {
        var mbi = mod_resolver.modules.iterator();
        while (mbi.next()) |entry| {
            const bt = entry.value_ptr.build_type;
            if (bt != .none) {
                try module_builds.put(allocator, entry.key_ptr.*, bt);
            }
        }
    }

    // Load cached warnings for incremental builds
    var cached_warnings = try cache.loadWarnings(allocator);
    defer {
        for (cached_warnings.items) |w| {
            allocator.free(w.module);
            allocator.free(w.file);
            allocator.free(w.message);
        }
        cached_warnings.deinit(allocator);
    }

    // Track all warnings for saving at end
    var all_warnings: std.ArrayListUnmanaged(cache.CachedWarning) = .{};
    defer {
        for (all_warnings.items) |w| {
            allocator.free(w.module);
            allocator.free(w.file);
            allocator.free(w.message);
        }
        all_warnings.deinit(allocator);
    }

    // Accumulate declaration tables across modules for cross-module default arg resolution
    var all_module_decls = std.StringHashMap(*declarations.DeclTable).init(allocator);
    defer all_module_decls.deinit();
    var decl_collector_ptrs = std.ArrayListUnmanaged(*declarations.DeclCollector){};
    defer {
        for (decl_collector_ptrs.items) |dc| {
            dc.deinit();
            allocator.destroy(dc);
        }
        decl_collector_ptrs.deinit(allocator);
    }

    // Process each module in dependency order
    for (order) |mod_name| {
        const mod_ptr = mod_resolver.modules.getPtr(mod_name) orelse continue;
        const ast = mod_ptr.ast orelse continue;

        // Check if module needs recompilation
        const needs_recompile = try comp_cache.moduleNeedsRecompile(mod_name, mod_ptr.files);
        if (!needs_recompile) {
            // Replay cached warnings for this module
            for (cached_warnings.items) |w| {
                if (std.mem.eql(u8, w.module, mod_name)) {
                    try reporter.warn(.{
                        .message = w.message,
                        .loc = .{ .file = w.file, .line = w.line, .col = 0 },
                    });
                    try all_warnings.append(allocator, .{
                        .module = try allocator.dupe(u8, w.module),
                        .file = try allocator.dupe(u8, w.file),
                        .line = w.line,
                        .message = try allocator.dupe(u8, w.message),
                    });
                }
            }
            continue;
        }

        // Get source location map and file path for error reporting
        const locs_ptr: ?*const parser.LocMap = if (mod_ptr.locs) |*l| l else null;
        const source_file: []const u8 = if (mod_ptr.files.len > 0) mod_ptr.files[0] else "";

        // Snapshot warning count to capture new warnings from this module
        const warn_start = reporter.warnings.items.len;

        // ── Pass 4: Declaration Collection ────────────────────
        const decl_collector = try allocator.create(declarations.DeclCollector);
        decl_collector.* = declarations.DeclCollector.init(allocator, reporter);
        try decl_collector_ptrs.append(allocator, decl_collector);
        decl_collector.locs = locs_ptr;
        decl_collector.source_file = source_file;

        try decl_collector.collect(ast);
        if (reporter.hasErrors()) return null;
        try all_module_decls.put(mod_name, &decl_collector.table);

        // ── Pass 5: Type Resolution ────────────────────────────
        var type_resolver = resolver.TypeResolver.init(allocator, &decl_collector.table, reporter);
        defer type_resolver.deinit();
        type_resolver.locs = locs_ptr;
        type_resolver.source_file = source_file;

        try type_resolver.resolve(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 6: Ownership Analysis ─────────────────────────
        var ownership_checker = ownership.OwnershipChecker.init(allocator, reporter);
        ownership_checker.locs = locs_ptr;
        ownership_checker.source_file = source_file;
        ownership_checker.decls = &decl_collector.table;
        try ownership_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 7: Borrow Checking ────────────────────────────
        var borrow_checker = borrow.BorrowChecker.init(allocator, reporter);
        defer borrow_checker.deinit();
        borrow_checker.locs = locs_ptr;
        borrow_checker.source_file = source_file;
        borrow_checker.decls = &decl_collector.table;

        try borrow_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 8: Thread Safety ──────────────────────────────
        var thread_checker = thread_safety.ThreadSafetyChecker.init(allocator, reporter);
        defer thread_checker.deinit();
        thread_checker.locs = locs_ptr;
        thread_checker.source_file = source_file;

        try thread_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 9: Error Propagation ──────────────────────────
        var prop_checker = propagation.PropagationChecker.init(allocator, reporter, &decl_collector.table);
        prop_checker.locs = locs_ptr;
        prop_checker.source_file = source_file;
        try prop_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 10: MIR Annotation ─────────────────────────────
        var mir_annotator = mir.MirAnnotator.init(allocator, reporter, &decl_collector.table, &type_resolver.type_map);
        defer mir_annotator.deinit();

        try mir_annotator.annotate(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 10b: MIR Tree Lowering ───────────────────────
        var mir_lowerer = mir.MirLowerer.init(
            allocator,
            &mir_annotator.node_map,
            &mir_annotator.union_registry,
            &decl_collector.table,
            &mir_annotator.var_types,
        );
        defer mir_lowerer.deinit();
        const mir_root = try mir_lowerer.lower(ast);

        // ── Extern Sidecar Validation ──────────────────────────
        // If the module has bridge declarations, a paired .zig sidecar
        // must exist next to the anchor .orh file.
        if (collectBridgeNames(ast, allocator)) |bridge_names| {
            defer {
                for (bridge_names) |n| allocator.free(n);
                allocator.free(bridge_names);
            }
            if (bridge_names.len > 0) {
                // Find the anchor file — the one whose stem matches the module name
                var anchor_dir: ?[]const u8 = null;
                for (mod_ptr.files) |file| {
                    const stem = std.fs.path.stem(file);
                    if (std.mem.eql(u8, stem, mod_name)) {
                        anchor_dir = std.fs.path.dirname(file) orelse ".";
                        break;
                    }
                }
                const dir = anchor_dir orelse (if (mod_ptr.files.len > 0) std.fs.path.dirname(mod_ptr.files[0]) orelse "." else ".");
                const sidecar_src = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ dir, mod_name });
                defer allocator.free(sidecar_src);
                std.fs.cwd().access(sidecar_src, .{}) catch {
                    const first_name = bridge_names[0];
                    const msg = try std.fmt.allocPrint(allocator,
                        "bridge '{s}': missing sidecar file '{s}'",
                        .{ first_name, sidecar_src });
                    defer allocator.free(msg);
                    try reporter.report(.{ .message = msg });
                };
                if (!reporter.hasErrors()) {
                    // Sidecar exists — copy as <mod>_bridge.zig so generated <mod>.zig can @import it
                    try cache.ensureGeneratedDir();
                    const sidecar_dst = try std.fmt.allocPrint(allocator, "{s}/{s}_bridge.zig", .{ cache.GENERATED_DIR, mod_name });
                    defer allocator.free(sidecar_dst);
                    try std.fs.cwd().copyFile(sidecar_src, std.fs.cwd(), sidecar_dst, .{});
                }
            }
        } else |_| {}
        if (reporter.hasErrors()) return null;

        // ── Pass 11: Zig Code Generation ───────────────────────
        const is_debug = cli.optimize == .debug;
        var cg = codegen.CodeGen.init(allocator, reporter, is_debug);
        defer cg.deinit();
        cg.decls = &decl_collector.table;
        cg.all_decls = &all_module_decls;
        cg.locs = locs_ptr;
        cg.source_file = source_file;
        cg.module_builds = &module_builds;
        cg.node_map = &mir_annotator.node_map;
        cg.union_registry = &mir_annotator.union_registry;
        cg.var_types = &mir_annotator.var_types;
        cg.mir_root = mir_root;

        try cg.generate(ast, mod_name);
        if (reporter.hasErrors()) return null;

        // Write generated .zig file to cache
        try cache.writeGeneratedZig(mod_name, cg.getOutput(), allocator);

        // Capture new warnings from this module for caching
        for (reporter.warnings.items[warn_start..]) |w| {
            try all_warnings.append(allocator, .{
                .module = try allocator.dupe(u8, mod_name),
                .file = if (w.loc) |loc| try allocator.dupe(u8, loc.file) else try allocator.dupe(u8, ""),
                .line = if (w.loc) |loc| loc.line else 0,
                .message = try allocator.dupe(u8, w.message),
            });
        }

        // Update timestamp cache
        for (mod_ptr.files) |file| {
            try comp_cache.updateTimestamp(file);
        }
    }

    // Save updated cache
    try comp_cache.saveTimestamps();
    try comp_cache.saveDeps();
    try cache.saveWarnings(all_warnings.items);

    if (cli.command == .@"test") {
        var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.verbose) catch |err| {
            if (err == error.ZigNotFound) return null;
            return err;
        };
        defer runner.deinit();

        var last_binary_name: []const u8 = "main";
        var any_failed = false;
        var mod_it2 = mod_resolver.modules.iterator();
        while (mod_it2.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;
            var project_name: []const u8 = "";
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                }
            }
            const binary_name2 = if (project_name.len > 0) project_name else mod.name;
            last_binary_name = binary_name2;
            const passed = try runner.runTests(mod.name, binary_name2);
            if (!passed) any_failed = true;
        }
        return if (!any_failed) try allocator.dupe(u8, last_binary_name) else null;
    }

    // ── Pass 12: Zig Compiler ──────────────────────────────────
    var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.verbose) catch |err| {
        if (err == error.ZigNotFound) return null;
        return err;
    };
    defer runner.deinit();

    // Default to native if no targets specified
    if (cli.targets.items.len == 0)
        try cli.targets.append(allocator, .native);

    const opt_str: []const u8 = switch (cli.optimize) {
        .fast => "fast",
        .small => "small",
        .debug => "",
    };

    // Build every root module (all those with a #build declaration).
    // A project can have multiple build targets — e.g. an exe + a dynamic lib.

    // Count root modules and collect target descriptors
    var root_count: usize = 0;
    var multi_targets = std.ArrayListUnmanaged(zig_runner.MultiTarget){};
    defer multi_targets.deinit(allocator);
    // Temporary storage for lib_imports slices
    var lib_import_lists = std.ArrayListUnmanaged([]const []const u8){};
    defer {
        for (lib_import_lists.items) |li| allocator.free(li);
        lib_import_lists.deinit(allocator);
    }

    var exe_binary_name: ?[]const u8 = null; // tracked for `orhon run`

    {
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;
            root_count += 1;
        }
    }

    if (root_count > 1) {
        // Multi-target build: collect all targets, build once
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;

            var build_type: []const u8 = "exe";
            var project_name: []const u8 = "";
            var mt_version: ?[3]u64 = null;
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (std.mem.eql(u8, meta.metadata.field, "build")) {
                        if (meta.metadata.value.* == .identifier) {
                            build_type = meta.metadata.value.identifier;
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "version")) {
                        mt_version = module.extractVersion(meta.metadata.value);
                    }
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            if (std.mem.eql(u8, build_type, "exe")) {
                if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            }

            // Find which of this module's imports are lib targets
            var lib_imports = std.ArrayListUnmanaged([]const u8){};
            defer lib_imports.deinit(allocator);
            for (mod.imports) |imp_name| {
                if (module_builds.get(imp_name)) |bt| {
                    if (bt == .static or bt == .dynamic) {
                        try lib_imports.append(allocator, imp_name);
                    }
                }
            }
            const lib_slice = try allocator.dupe([]const u8, lib_imports.items);
            try lib_import_lists.append(allocator, lib_slice);

            try multi_targets.append(allocator, .{
                .module_name = mod.name,
                .project_name = binary_name,
                .build_type = build_type,
                .lib_imports = lib_slice,
                .version = mt_version,
            });
        }

        for (cli.targets.items) |build_target| {
            const target_str = build_target.toZigTriple();

            // -zig target: copy generated Zig source to bin/zig/
            if (build_target == .zig) {
                try emitZigProject(allocator);
                continue;
            }

            const use_subfolder = cli.targets.items.len > 1;
            const built = try runner.buildAll(target_str, opt_str, multi_targets.items);
            if (!built) return null;

            // Move artifacts to target subfolder if multi-target
            if (use_subfolder) {
                try moveArtifactsToSubfolder(allocator, build_target.folderName());
            }
        }

        // Generate interface files for lib targets
        for (multi_targets.items) |t| {
            if (!std.mem.eql(u8, t.build_type, "exe")) {
                const mod = mod_resolver.modules.get(t.module_name) orelse continue;
                if (mod.ast) |ast| {
                    try generateInterface(allocator, t.module_name, t.project_name, ast);
                }
            }
        }
    } else {
        // Single-target build: use existing path (no behavior change)
        var mod_it = mod_resolver.modules.iterator();
        while (mod_it.next()) |entry| {
            const mod = entry.value_ptr;
            if (!mod.is_root) continue;

            var build_type: []const u8 = "exe";
            var project_name: []const u8 = "";
            var project_version: ?[3]u64 = null;
            if (mod.ast) |ast| {
                for (ast.program.metadata) |meta| {
                    if (std.mem.eql(u8, meta.metadata.field, "build")) {
                        if (meta.metadata.value.* == .identifier) {
                            build_type = meta.metadata.value.identifier;
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "name")) {
                        if (meta.metadata.value.* == .string_literal) {
                            const raw = meta.metadata.value.string_literal;
                            if (raw.len >= 2 and raw[0] == '"') {
                                project_name = raw[1 .. raw.len - 1];
                            } else {
                                project_name = raw;
                            }
                        }
                    }
                    if (std.mem.eql(u8, meta.metadata.field, "version")) {
                        project_version = module.extractVersion(meta.metadata.value);
                    }
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            try runner.generateBuildZig(mod.name, build_type, binary_name, project_version);

            for (cli.targets.items) |build_target| {
                const target_str = build_target.toZigTriple();

                if (build_target == .zig) {
                    try emitZigProject(allocator);
                    continue;
                }

                const use_subfolder = cli.targets.items.len > 1;
                const built = if (std.mem.eql(u8, build_type, "exe"))
                    try runner.build(target_str, opt_str, mod.name, binary_name)
                else
                    try runner.buildLib(target_str, opt_str, mod.name, binary_name, build_type);
                if (!built) return null;

                if (use_subfolder) {
                    try moveArtifactsToSubfolder(allocator, build_target.folderName());
                }
            }

            if (std.mem.eql(u8, build_type, "exe")) {
                if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            } else {
                if (mod.ast) |ast| {
                    try generateInterface(allocator, mod.name, binary_name, ast);
                }
            }
        }
    }

    // Return exe name for `orhon run`; empty string signals lib-only success
    return exe_binary_name orelse try allocator.dupe(u8, "");
}

/// Collect the names of all bridge declarations in an AST.
/// Returns an allocated slice of duped name strings, or an error.
/// Caller must free each name and the slice itself.
fn collectBridgeNames(ast: *parser.Node, allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    if (ast.* != .program) return names.toOwnedSlice(allocator);
    for (ast.program.top_level) |node| {
        switch (node.*) {
            .func_decl => |f| {
                if (f.is_bridge) try names.append(allocator, try allocator.dupe(u8, f.name));
            },
            .const_decl => |v| {
                if (v.is_bridge) try names.append(allocator, try allocator.dupe(u8, v.name));
            },
            .var_decl => |v| {
                if (v.is_bridge) try names.append(allocator, try allocator.dupe(u8, v.name));
            },
            .struct_decl => |s| {
                if (s.is_bridge) {
                    try names.append(allocator, try allocator.dupe(u8, s.name));
                } else {
                    for (s.members) |m| {
                        if (m.* == .func_decl and m.func_decl.is_bridge)
                            try names.append(allocator, try allocator.dupe(u8, m.func_decl.name));
                    }
                }
            },
            else => {},
        }
    }
    return names.toOwnedSlice(allocator);
}

// ============================================================
// INTERFACE FILE GENERATION
// ============================================================
//
// When a module is compiled as static or dynamic, emit a pub-only
// `.orh` file into bin/ so consumers can type-check against the API.
// The interface file is valid Orhon — it has the module declaration,
// version, and all pub signatures, but no bodies or private members.

/// Write a type node as Orhon source syntax into a buffer
fn formatType(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .type_primitive => |s| try buf.appendSlice(alloc, s),
        .type_named     => |s| try buf.appendSlice(alloc, s),
        .type_slice     => |elem| {
            try buf.appendSlice(alloc, "[]");
            try formatType(elem, buf, alloc);
        },
        .type_array     => |a| {
            try buf.append(alloc, '[');
            try formatExprSimple(a.size, buf, alloc);
            try buf.append(alloc, ']');
            try formatType(a.elem, buf, alloc);
        },
        .type_ptr       => |p| {
            try buf.appendSlice(alloc, p.kind);
            try formatType(p.elem, buf, alloc);
        },
        .type_union     => |arms| {
            try buf.append(alloc, '(');
            for (arms, 0..) |arm, i| {
                if (i > 0) try buf.appendSlice(alloc, " | ");
                try formatType(arm, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_func      => |f| {
            try buf.appendSlice(alloc, "func(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.appendSlice(alloc, ") ");
            try formatType(f.ret, buf, alloc);
        },
        .type_generic   => |g| {
            try buf.appendSlice(alloc, g.name);
            try buf.append(alloc, '(');
            for (g.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_named => |fields| {
            try buf.append(alloc, '(');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try buf.appendSlice(alloc, f.name);
                try buf.appendSlice(alloc, ": ");
                try formatType(f.type_node, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        .type_tuple_anon => |parts| {
            try buf.append(alloc, '(');
            for (parts, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatType(p, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => try buf.appendSlice(alloc, "any"),
    }
}

/// Write simple expressions that appear in type contexts (array sizes, version numbers)
fn formatExprSimple(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .int_literal   => |s| try buf.appendSlice(alloc, s),
        .float_literal => |s| try buf.appendSlice(alloc, s),
        .identifier    => |s| try buf.appendSlice(alloc, s),
        .call_expr     => |c| {
            // Version(1, 2, 3) etc.
            if (c.callee.* == .identifier) try buf.appendSlice(alloc, c.callee.identifier);
            try buf.append(alloc, '(');
            for (c.args, 0..) |a, i| {
                if (i > 0) try buf.appendSlice(alloc, ", ");
                try formatExprSimple(a, buf, alloc);
            }
            try buf.append(alloc, ')');
        },
        else => {},
    }
}

/// Write a function signature (no body) into a buffer
fn emitFuncSig(f: parser.FuncDecl, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, indent: []const u8) anyerror!void {
    try buf.appendSlice(alloc, indent);
    if (f.is_pub) try buf.appendSlice(alloc, "pub ");
    if (f.is_compt) try buf.appendSlice(alloc, "compt ");
    try buf.appendSlice(alloc, "func ");
    try buf.appendSlice(alloc, f.name);
    try buf.append(alloc, '(');
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(alloc, ", ");
        const param = p.param;
        try buf.appendSlice(alloc, param.name);
        try buf.appendSlice(alloc, ": ");
        try formatType(param.type_annotation, buf, alloc);
    }
    try buf.appendSlice(alloc, ") ");
    try formatType(f.return_type, buf, alloc);
    try buf.append(alloc, '\n');
}

/// Emit one top-level pub declaration into a buffer (skip private)
fn emitInterfaceDecl(node: *parser.Node, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) anyerror!void {
    switch (node.*) {
        .func_decl => |f| {
            if (!f.is_pub) return;
            try emitFuncSig(f, buf, alloc, "");
            try buf.append(alloc, '\n');
        },
        .struct_decl => |s| {
            if (!s.is_pub) return;
            try buf.appendSlice(alloc, "pub struct ");
            try buf.appendSlice(alloc, s.name);
            try buf.appendSlice(alloc, " {\n");
            for (s.members) |m| {
                switch (m.*) {
                    .field_decl => |fd| {
                        if (!fd.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub ");
                        try buf.appendSlice(alloc, fd.name);
                        try buf.appendSlice(alloc, ": ");
                        try formatType(fd.type_annotation, buf, alloc);
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    .const_decl => |v| {
                        if (!v.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub const ");
                        try buf.appendSlice(alloc, v.name);
                        if (v.type_annotation) |t| {
                            try buf.appendSlice(alloc, ": ");
                            try formatType(t, buf, alloc);
                        }
                        try buf.append(alloc, '\n');
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .enum_decl => |e| {
            if (!e.is_pub) return;
            try buf.appendSlice(alloc, "pub enum ");
            try buf.appendSlice(alloc, e.name);
            try buf.append(alloc, '(');
            try formatType(e.backing_type, buf, alloc);
            try buf.appendSlice(alloc, ") {\n");
            for (e.members) |m| {
                switch (m.*) {
                    .enum_variant => |v| {
                        try buf.appendSlice(alloc, "    ");
                        try buf.appendSlice(alloc, v.name);
                        if (v.fields.len > 0) {
                            try buf.append(alloc, '(');
                            for (v.fields, 0..) |f, i| {
                                if (i > 0) try buf.appendSlice(alloc, ", ");
                                const p = f.param;
                                try buf.appendSlice(alloc, p.name);
                                try buf.appendSlice(alloc, ": ");
                                try formatType(p.type_annotation, buf, alloc);
                            }
                            try buf.append(alloc, ')');
                        }
                        try buf.append(alloc, '\n');
                    },
                    .func_decl => |f| {
                        if (!f.is_pub) continue;
                        try emitFuncSig(f, buf, alloc, "    ");
                    },
                    else => {},
                }
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .bitfield_decl => |b| {
            if (!b.is_pub) return;
            try buf.appendSlice(alloc, "pub bitfield ");
            try buf.appendSlice(alloc, b.name);
            try buf.append(alloc, '(');
            try formatType(b.backing_type, buf, alloc);
            try buf.appendSlice(alloc, ") {\n");
            for (b.members) |flag| {
                try buf.appendSlice(alloc, "    ");
                try buf.appendSlice(alloc, flag);
                try buf.append(alloc, '\n');
            }
            try buf.appendSlice(alloc, "}\n\n");
        },
        .const_decl => |v| {
            if (!v.is_pub) return;
            try buf.appendSlice(alloc, "pub const ");
            try buf.appendSlice(alloc, v.name);
            if (v.type_annotation) |t| {
                try buf.appendSlice(alloc, ": ");
                try formatType(t, buf, alloc);
            }
            try buf.appendSlice(alloc, " = ");
            try formatExprSimple(v.value, buf, alloc);
            try buf.append(alloc, '\n');
            try buf.append(alloc, '\n');
        },
        else => {},
    }
}

/// Generate a pub-only interface `.orh` file into `bin/<binary_name>.orh`.
/// Called after a successful static or dynamic library build.
/// Copy the generated Zig project from .orh-cache/generated/ to bin/zig/
fn emitZigProject(allocator: std.mem.Allocator) !void {
    const dst_dir = "bin/zig";
    try std.fs.cwd().makePath(dst_dir);

    var src_dir = try std.fs.cwd().openDir(cache.GENERATED_DIR, .{ .iterate = true });
    defer src_dir.close();

    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const dst_path = try std.fs.path.join(allocator, &.{ dst_dir, entry.name });
        defer allocator.free(dst_path);
        const src_path = try std.fs.path.join(allocator, &.{ cache.GENERATED_DIR, entry.name });
        defer allocator.free(src_path);
        try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{});
    }
    std.debug.print("Emitted Zig project: {s}/\n", .{dst_dir});
}

/// Move all artifacts from bin/ to bin/<subfolder>/
fn moveArtifactsToSubfolder(allocator: std.mem.Allocator, subfolder: []const u8) !void {
    const dst = try std.fs.path.join(allocator, &.{ "bin", subfolder });
    defer allocator.free(dst);
    try std.fs.cwd().makePath(dst);

    var bin_dir = std.fs.cwd().openDir("bin", .{ .iterate = true }) catch return;
    defer bin_dir.close();

    var it = bin_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const src_path = try std.fs.path.join(allocator, &.{ "bin", entry.name });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_path);
        std.fs.cwd().rename(src_path, dst_path) catch {
            // Fallback: copy + delete
            std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch continue;
            std.fs.cwd().deleteFile(src_path) catch {};
        };
    }
}

fn generateInterface(
    alloc: std.mem.Allocator,
    mod_name: []const u8,
    binary_name: []const u8,
    ast: *parser.Node,
) !void {
    if (ast.* != .program) return;

    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    // Header comment + module declaration
    try buf.appendSlice(alloc, "// Orhon interface file — generated by orhon, do not edit\n\n");
    try buf.appendSlice(alloc, "module ");
    try buf.appendSlice(alloc, mod_name);
    try buf.appendSlice(alloc, "\n\n");

    // Version from metadata
    for (ast.program.metadata) |meta| {
        if (std.mem.eql(u8, meta.metadata.field, "version")) {
            try buf.appendSlice(alloc, "#version = ");
            try formatExprSimple(meta.metadata.value, &buf, alloc);
            try buf.appendSlice(alloc, "\n\n");
            break;
        }
    }

    // Public declarations
    for (ast.program.top_level) |node| {
        try emitInterfaceDecl(node, &buf, alloc);
    }

    // Write to bin/<binary_name>.orh
    try std.fs.cwd().makePath("bin");
    const path = try std.fmt.allocPrint(alloc, "bin/{s}.orh", .{binary_name});
    defer alloc.free(path);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ============================================================
// TESTS — embedded in main.zig to verify pipeline integration
// ============================================================

test "pipeline - imports all passes" {
    // Verify all pipeline modules are importable
    _ = lexer;
    _ = parser;
    _ = module;
    _ = declarations;
    _ = resolver;
    _ = ownership;
    _ = borrow;
    _ = thread_safety;
    _ = propagation;
    _ = mir;
    _ = codegen;
    _ = zig_runner;
    _ = errors;
    _ = cache;
    _ = builtins;
    try std.testing.expect(true);
}

test "cli - build target names" {
    try std.testing.expectEqual(BuildTarget.native, .native);
    try std.testing.expectEqual(BuildTarget.linux_x64, .linux_x64);
    try std.testing.expectEqual(BuildTarget.win_x64, .win_x64);
    try std.testing.expectEqual(BuildTarget.wasm, .wasm);
    try std.testing.expectEqual(BuildTarget.zig, .zig);
}

test "full pipeline - hello world" {
    const alloc = std.testing.allocator;

    const source =
        \\module main
        \\
        \\func main() void {
        \\    var x: i32 = 42
        \\}
        \\
    ;

    // Lex
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    // Parse
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = parser.Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();

    const ast = try p.parseProgram();
    try std.testing.expect(!reporter.hasErrors());

    // Declaration pass
    var decl_collector = declarations.DeclCollector.init(alloc, &reporter);
    defer decl_collector.deinit();
    try decl_collector.collect(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Type resolution
    var type_resolver = resolver.TypeResolver.init(alloc, &decl_collector.table, &reporter);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Ownership check
    var ownership_checker = ownership.OwnershipChecker.init(alloc, &reporter);
    try ownership_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Borrow check
    var borrow_checker = borrow.BorrowChecker.init(alloc, &reporter);
    defer borrow_checker.deinit();
    try borrow_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Thread safety
    var thread_checker = thread_safety.ThreadSafetyChecker.init(alloc, &reporter);
    defer thread_checker.deinit();
    try thread_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Propagation
    var prop_checker = propagation.PropagationChecker.init(alloc, &reporter, null);
    try prop_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, &reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    try std.testing.expect(!reporter.hasErrors());
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);

    // Codegen
    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
    try cg.generate(ast, "main");
    try std.testing.expect(!reporter.hasErrors());

    const output = cg.getOutput();
    try std.testing.expect(output.len > 0);

    // Verify the generated Zig output contains the expected structure
    try std.testing.expect(std.mem.indexOf(u8, output, "// generated from module main") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x: i32 = 42;") != null);
}

test "codegen - var never reassigned becomes const" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const output = try codegenSource(alloc,
        \\module main
        \\
        \\func main() void {
        \\    var a: i32 = 1
        \\    var b: i32 = 2
        \\    b = 3
        \\}
        \\
    , &reporter);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "const a: i32 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var b: i32 = 2;") != null);
}

/// Full pipeline test helper: source → lex → parse → declarations → resolve → MIR → codegen → Zig.
/// Returns owned output slice — caller must free.
fn codegenSource(alloc: std.mem.Allocator, source: []const u8, reporter: *errors.Reporter) ![]const u8 {
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var p = parser.Parser.init(tokens.items, alloc, reporter);
    defer p.deinit();
    const ast = try p.parseProgram();
    var decl_collector = declarations.DeclCollector.init(alloc, reporter);
    defer decl_collector.deinit();
    try decl_collector.collect(ast);
    // Type resolution
    var type_resolver = resolver.TypeResolver.init(alloc, &decl_collector.table, reporter);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);
    // Codegen with full MIR context
    var cg = codegen.CodeGen.init(alloc, reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
    try cg.generate(ast, "main");
    return try alloc.dupe(u8, cg.getOutput());
}

test "codegen - struct with method" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module main
        \\pub struct Vec2 {
        \\    pub x: f32
        \\    pub y: f32
        \\    pub func new(x: f32, y: f32) Vec2 {
        \\        return Vec2(x, y)
        \\    }
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Vec2 = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "y: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fn new(") != null);
}

test "codegen - enum with match" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module main
        \\enum(u8) Color {
        \\    Red
        \\    Green
        \\    Blue
        \\}
        \\func describe(c: Color) void {
        \\    match c {
        \\        Red => {}
        \\        else => {}
        \\    }
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Color = enum") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "switch") != null);
}

test "codegen - bitfield declaration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module main
        \\bitfield(u8) Perms {
        \\    Read
        \\    Write
        \\    Execute
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Write") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Execute") != null);
}
