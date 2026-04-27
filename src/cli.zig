// cli.zig — CLI argument parsing and command definitions

const std = @import("std");
const errors_mod = @import("errors.zig");

// ============================================================
// CLI TYPES
// ============================================================

pub const Command = enum {
    build,
    run,
    @"test",
    check,
    init,
    addtopath,
    debug,
    version,
    fmt,
    gendoc,
    lsp,
    which,
    analysis,
    help,
};

pub const BuildTarget = enum {
    native,
    linux_x64,
    linux_arm,
    win_x64,
    mac_x64,
    mac_arm,
    wasm,
    zig, // emit Zig source project

    pub fn toZigTriple(self: BuildTarget) []const u8 {
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

    pub fn folderName(self: BuildTarget) []const u8 {
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

pub const OptLevel = enum {
    debug,
    fast,
    small,
};

// ============================================================
// COMMAND + FLAG TABLE
// ============================================================

pub const FlagEffect = union(enum) {
    set_verbose,
    set_fast,
    set_small,
    set_werror,
    set_gen_api,
    set_gen_std,
    set_gen_syntax,
    set_init_update,   // -update flag for init command
    set_dry_run,       // -dry-run flag for addtopath
    set_diag_format,   // takes_value=true
    set_color,         // takes_value=true
    set_line_length,   // takes_value=true
    append_target: BuildTarget,
};

pub const FlagSpec = struct {
    name: []const u8,
    takes_value: bool,
    help: []const u8,
    effect: FlagEffect,
};

pub const CommandSpec = struct {
    cmd: Command,
    description: []const u8,
    positional: ?[]const u8,
    flags: []const FlagSpec,
};

// --- Shared flag constants ---
const flag_verbose     = FlagSpec{ .name = "-verbose",     .takes_value = false, .help = "Show raw Zig compiler output",            .effect = .set_verbose };
const flag_fast        = FlagSpec{ .name = "-fast",        .takes_value = false, .help = "Maximum speed optimization",              .effect = .set_fast };
const flag_small       = FlagSpec{ .name = "-small",       .takes_value = false, .help = "Minimum binary size optimization",        .effect = .set_small };
const flag_werror      = FlagSpec{ .name = "-werror",      .takes_value = false, .help = "Treat all warnings as errors",            .effect = .set_werror };
const flag_diag_format = FlagSpec{ .name = "-diag-format", .takes_value = true,  .help = "Diagnostic format: human, json, short",  .effect = .set_diag_format };
const flag_color       = FlagSpec{ .name = "-color",       .takes_value = true,  .help = "Color output: auto, always, never",      .effect = .set_color };
const flag_line_length = FlagSpec{ .name = "-line-length", .takes_value = true,  .help = "Max line length (default: 100)",         .effect = .set_line_length };
const flag_gen_api     = FlagSpec{ .name = "-api",         .takes_value = false, .help = "Generate project API docs only",         .effect = .set_gen_api };
const flag_gen_std     = FlagSpec{ .name = "-std",         .takes_value = false, .help = "Generate stdlib reference only",         .effect = .set_gen_std };
const flag_gen_syntax  = FlagSpec{ .name = "-syntax",      .takes_value = false, .help = "Generate syntax reference only",        .effect = .set_gen_syntax };
const flag_init_update = FlagSpec{ .name = "-update",      .takes_value = false, .help = "Refresh example files to the current compiler version", .effect = .set_init_update };
const flag_dry_run     = FlagSpec{ .name = "-dry-run",    .takes_value = false, .help = "Show what would change without writing",                .effect = .set_dry_run };

const flag_linux_x64 = FlagSpec{ .name = "-linux_x64", .takes_value = false, .help = "Linux x86-64",              .effect = .{ .append_target = .linux_x64 } };
const flag_linux_arm = FlagSpec{ .name = "-linux_arm", .takes_value = false, .help = "Linux ARM64",                .effect = .{ .append_target = .linux_arm } };
const flag_win_x64   = FlagSpec{ .name = "-win_x64",   .takes_value = false, .help = "Windows x86-64",             .effect = .{ .append_target = .win_x64 } };
const flag_mac_x64   = FlagSpec{ .name = "-mac_x64",   .takes_value = false, .help = "macOS x86-64",               .effect = .{ .append_target = .mac_x64 } };
const flag_mac_arm   = FlagSpec{ .name = "-mac_arm",   .takes_value = false, .help = "macOS ARM64 (Apple Silicon)", .effect = .{ .append_target = .mac_arm } };
const flag_wasm      = FlagSpec{ .name = "-wasm",      .takes_value = false, .help = "WebAssembly",                 .effect = .{ .append_target = .wasm } };
const flag_zig_emit  = FlagSpec{ .name = "-zig",       .takes_value = false, .help = "Emit Zig source project",    .effect = .{ .append_target = .zig } };

// --- Grouped flag arrays (comptime ++ concatenation) ---
const output_flags  = [_]FlagSpec{ flag_diag_format, flag_color, flag_werror };
const compile_flags = [_]FlagSpec{ flag_fast, flag_small, flag_verbose };
const target_flags  = [_]FlagSpec{ flag_linux_x64, flag_linux_arm, flag_win_x64, flag_mac_x64, flag_mac_arm, flag_wasm, flag_zig_emit };

const build_flags  = target_flags ++ compile_flags ++ output_flags;
const run_flags    = compile_flags ++ output_flags;   // reused by run, test, debug
const gendoc_flags = [_]FlagSpec{ flag_gen_api, flag_gen_std, flag_gen_syntax } ++ output_flags;
const fmt_flags    = [_]FlagSpec{ flag_line_length } ++ output_flags;
const init_flags       = [_]FlagSpec{ flag_init_update } ++ output_flags;
const addtopath_flags  = [_]FlagSpec{ flag_dry_run } ++ output_flags;

pub const command_table = [_]CommandSpec{
    .{ .cmd = .build,     .description = "Compile the project in the current directory",                    .positional = null,     .flags = &build_flags },
    .{ .cmd = .run,       .description = "Build and immediately execute the binary",                        .positional = null,     .flags = &run_flags },
    .{ .cmd = .@"test",   .description = "Run all test { } blocks in the project",                         .positional = null,     .flags = &run_flags },
    .{ .cmd = .check,     .description = "Check the project for errors without producing a binary",         .positional = null,     .flags = &output_flags },
    .{ .cmd = .init,      .description = "Create a new project (in ./<name>/ or current dir if omitted)",  .positional = "[name]", .flags = &init_flags },
    .{ .cmd = .fmt,       .description = "Format all .orh files in the project",                           .positional = null,     .flags = &fmt_flags },
    .{ .cmd = .gendoc,    .description = "Generate documentation",                                         .positional = null,     .flags = &gendoc_flags },
    .{ .cmd = .lsp,       .description = "Start the language server",                                      .positional = null,     .flags = &output_flags },
    .{ .cmd = .addtopath, .description = "Add orhon to your shell PATH",                                   .positional = null,     .flags = &addtopath_flags },
    .{ .cmd = .debug,     .description = "Show project info — modules, files, source directory",            .positional = null,     .flags = &run_flags },
    .{ .cmd = .analysis,  .description = "Run PEG grammar validation on a single .orh file",               .positional = "<file>", .flags = &output_flags },
    .{ .cmd = .version,   .description = "Print the compiler version",                                     .positional = null,     .flags = &output_flags },
    .{ .cmd = .which,     .description = "Print the path to the orhon executable",                         .positional = null,     .flags = &output_flags },
    .{ .cmd = .help,      .description = "Show this help message",                                         .positional = null,     .flags = &output_flags },
};

pub const CliArgs = struct {
    command: Command,
    targets: std.ArrayListUnmanaged(BuildTarget),
    optimize: OptLevel,
    verbose: bool,        // -verbose flag (show Zig compiler output)
    source_dir: []const u8,
    project_name: []const u8, // for init command
    init_in_place: bool, // orhon init (no name) — init in current dir
    init_update: bool, // -update flag for init command (refresh example files)
    dry_run: bool,     // -dry-run flag for addtopath (show what would change, don't write)
    gen_api: bool, // -api flag for gendoc (generate project API docs only)
    gen_std: bool, // -std flag for gendoc (generate stdlib docs only)
    gen_syntax: bool, // -syntax flag for gendoc (generate syntax reference only)
    line_length: u32, // max line length for fmt (0 = disabled)
    diag_format: errors_mod.DiagFormat = .human,
    color_mode: errors_mod.ColorMode = .auto,
    werror: bool = false,
    allocator: std.mem.Allocator, // owns duped strings

    pub fn deinit(self: *CliArgs) void {
        if (self.project_name.len > 0) self.allocator.free(self.project_name);
        if (!std.mem.eql(u8, self.source_dir, "src")) self.allocator.free(self.source_dir);
        self.targets.deinit(self.allocator);
    }
};

// ============================================================
// CLI PARSING
// ============================================================

fn applyFlag(effect: FlagEffect, value: []const u8, cli: *CliArgs, allocator: std.mem.Allocator) !void {
    switch (effect) {
        .set_verbose    => cli.verbose = true,
        .set_fast       => cli.optimize = .fast,
        .set_small      => cli.optimize = .small,
        .set_werror     => cli.werror = true,
        .set_gen_api    => cli.gen_api = true,
        .set_gen_std    => cli.gen_std = true,
        .set_gen_syntax => cli.gen_syntax = true,
        .set_init_update => cli.init_update = true,
        .set_dry_run     => cli.dry_run = true,
        .set_diag_format => {
            if (std.mem.eql(u8, value, "human"))      cli.diag_format = .human
            else if (std.mem.eql(u8, value, "json"))  cli.diag_format = .json
            else if (std.mem.eql(u8, value, "short")) cli.diag_format = .short
            else {
                std.debug.print("error: invalid value '{s}' for flag '-diag-format' (expected: human, json, short)\n", .{value});
                std.process.exit(1);
            }
        },
        .set_color => {
            if (std.mem.eql(u8, value, "auto"))        cli.color_mode = .auto
            else if (std.mem.eql(u8, value, "always")) cli.color_mode = .always
            else if (std.mem.eql(u8, value, "never"))  cli.color_mode = .never
            else {
                std.debug.print("error: invalid value '{s}' for flag '-color' (expected: auto, always, never)\n", .{value});
                std.process.exit(1);
            }
        },
        .set_line_length => {
            cli.line_length = std.fmt.parseInt(u32, value, 10) catch {
                std.debug.print("error: invalid value '{s}' for flag '-line-length' (expected: non-negative integer)\n", .{value});
                std.process.exit(1);
            };
        },
        .append_target => |target| try cli.targets.append(allocator, target),
    }
}

pub fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    // Locate command spec by matching args[1] against @tagName of each Command variant
    const spec: *const CommandSpec = blk: {
        for (&command_table) |*s| {
            if (std.mem.eql(u8, args[1], @tagName(s.cmd))) break :blk s;
        }
        std.debug.print("error: unknown command '{s}', run 'orhon help'\n", .{args[1]});
        std.process.exit(1);
    };

    // orhon <cmd> -help — per-command help (anywhere in remaining args)
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "-help")) {
            printCommandHelp(spec);
            std.process.exit(0);
        }
    }

    // orhon help <cmd> — per-command help via the help subcommand
    if (spec.cmd == .help and args.len >= 3 and !std.mem.startsWith(u8, args[2], "-")) {
        const cmd_name = args[2];
        for (&command_table) |*s| {
            if (std.mem.eql(u8, cmd_name, @tagName(s.cmd))) {
                printCommandHelp(s);
                std.process.exit(0);
            }
        }
        std.debug.print("error: unknown command '{s}', run 'orhon help'\n", .{cmd_name});
        std.process.exit(1);
    }

    var cli = CliArgs{
        .command       = spec.cmd,
        .targets       = .{},
        .optimize      = .debug,
        .verbose       = false,
        .source_dir    = "src",
        .project_name  = "",
        .init_in_place = false,
        .init_update   = false,
        .dry_run       = false,
        .gen_api       = false,
        .gen_std       = false,
        .gen_syntax    = false,
        .line_length   = 100,
        .diag_format   = .human,
        .color_mode    = .auto,
        .werror        = false,
        .allocator     = allocator,
    };

    // Consume positional argument if declared for this command
    var flags_start: usize = 2;
    if (spec.positional != null) {
        if (args.len >= 3 and !std.mem.startsWith(u8, args[2], "-")) {
            switch (spec.cmd) {
                .init     => cli.project_name = try allocator.dupe(u8, args[2]),
                .analysis => cli.source_dir   = try allocator.dupe(u8, args[2]),
                else      => {},
            }
            flags_start = 3;
        } else if (spec.cmd == .init) {
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
    }

    // Parse flags via command's flag table
    var i: usize = flags_start;
    while (i < args.len) {
        const arg = args[i];
        const flag_spec: FlagSpec = blk: {
            for (spec.flags) |f| {
                if (std.mem.eql(u8, arg, f.name)) break :blk f;
            }
            std.debug.print("error: unknown flag '{s}' for command '{s}'\n", .{ arg, @tagName(spec.cmd) });
            std.process.exit(1);
        };

        if (flag_spec.takes_value) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: flag '{s}' requires a value\n", .{arg});
                std.process.exit(1);
            }
            try applyFlag(flag_spec.effect, args[i], &cli, allocator);
        } else {
            try applyFlag(flag_spec.effect, "", &cli, allocator);
        }
        i += 1;
    }

    return cli;
}

pub fn printUsage() void {
    const usage =
        \\orhon — The Orhon compiler  (orhon help for more info)
        \\
        \\  build   run   test   check   fmt   gendoc   init   lsp   addtopath   debug   analysis   version
        \\
    ;
    std.debug.print("{s}", .{usage});
}

pub fn printHelp() void {
    const help =
        \\orhon — The Orhon programming language compiler
        \\
        \\Commands:
        \\  build               Compile the project in the current directory
        \\  run                 Build and immediately execute the binary
        \\  test                Run all test { } blocks in the project
        \\  check               Check for errors without producing a binary (fast semantic check)
        \\  init [name]         Create a new project (in ./<name>/ or current dir if no name)
        \\  fmt                 Format all .orh files in the project
        \\                        -line-length <n>  Max line length (default: 100)
        \\  gendoc              Generate all docs (api + std + syntax)
        \\                        -api     Project API docs only (docs/api/)
        \\                        -std     Stdlib reference only (docs/std/)
        \\                        -syntax  Syntax reference only (docs/syntax.md)
        \\  lsp                 Start the language server (for editor integration)
        \\  addtopath           Add orhon to your shell PATH
        \\  debug               Show project info — modules, files, source directory
        \\  analysis <file>     Run PEG grammar validation on a single .orh file
        \\  version             Print the compiler version
        \\  which               Print the path to the orhon executable
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
        \\Output flags:
        \\  -diag-format <val>  Diagnostic format: human (default), json, short
        \\  -color <val>        Color output: auto (default), always, never
        \\  -werror             Treat all warnings as errors
        \\
        \\Run 'orhon <command> -help' for command-specific help.
        \\
    ;
    std.debug.print("{s}", .{help});
}

pub fn printCommandHelp(spec: *const CommandSpec) void {
    if (spec.positional) |pos| {
        std.debug.print("Usage: orhon {s} {s} [flags]\n\n", .{ @tagName(spec.cmd), pos });
    } else if (spec.flags.len > 0) {
        std.debug.print("Usage: orhon {s} [flags]\n\n", .{@tagName(spec.cmd)});
    } else {
        std.debug.print("Usage: orhon {s}\n\n", .{@tagName(spec.cmd)});
    }
    std.debug.print("{s}\n", .{spec.description});
    if (spec.flags.len > 0) {
        std.debug.print("\nFlags:\n", .{});
        const col_width = 22; // fits "  -diag-format <val>" (20 chars) + 2 gap
        const spaces = "                        "; // 24 spaces for padding
        for (spec.flags) |f| {
            var buf: [32]u8 = undefined;
            const col: []const u8 = if (f.takes_value)
                std.fmt.bufPrint(&buf, "  {s} <val>", .{f.name}) catch unreachable
            else
                std.fmt.bufPrint(&buf, "  {s}", .{f.name}) catch unreachable;
            const pad = if (col.len < col_width) col_width - col.len else 1;
            std.debug.print("{s}{s}  {s}\n", .{ col, spaces[0..pad], f.help });
        }
    }
}

// ============================================================
// TESTS
// ============================================================

test "cli - build target names" {
    try std.testing.expectEqual(BuildTarget.native, .native);
    try std.testing.expectEqual(BuildTarget.linux_x64, .linux_x64);
    try std.testing.expectEqual(BuildTarget.win_x64, .win_x64);
    try std.testing.expectEqual(BuildTarget.wasm, .wasm);
    try std.testing.expectEqual(BuildTarget.zig, .zig);
}

test "cli - toZigTriple" {
    try std.testing.expectEqualStrings("", BuildTarget.native.toZigTriple());
    try std.testing.expectEqualStrings("x86_64-linux", BuildTarget.linux_x64.toZigTriple());
    try std.testing.expectEqualStrings("aarch64-linux", BuildTarget.linux_arm.toZigTriple());
    try std.testing.expectEqualStrings("x86_64-windows", BuildTarget.win_x64.toZigTriple());
    try std.testing.expectEqualStrings("x86_64-macos", BuildTarget.mac_x64.toZigTriple());
    try std.testing.expectEqualStrings("aarch64-macos", BuildTarget.mac_arm.toZigTriple());
    try std.testing.expectEqualStrings("wasm32-freestanding", BuildTarget.wasm.toZigTriple());
    try std.testing.expectEqualStrings("", BuildTarget.zig.toZigTriple());
}

test "cli - folderName" {
    try std.testing.expectEqualStrings("native", BuildTarget.native.folderName());
    try std.testing.expectEqualStrings("linux_x64", BuildTarget.linux_x64.folderName());
    try std.testing.expectEqualStrings("linux_arm", BuildTarget.linux_arm.folderName());
    try std.testing.expectEqualStrings("win_x64", BuildTarget.win_x64.folderName());
    try std.testing.expectEqualStrings("mac_x64", BuildTarget.mac_x64.folderName());
    try std.testing.expectEqualStrings("mac_arm", BuildTarget.mac_arm.folderName());
    try std.testing.expectEqualStrings("wasm", BuildTarget.wasm.folderName());
    try std.testing.expectEqualStrings("zig", BuildTarget.zig.folderName());
}

fn testCli() CliArgs {
    return .{
        .command       = .help,
        .targets       = .{},
        .optimize      = .debug,
        .verbose       = false,
        .source_dir    = "src",
        .project_name  = "",
        .init_in_place = false,
        .init_update   = false,
        .dry_run       = false,
        .gen_api       = false,
        .gen_std       = false,
        .gen_syntax    = false,
        .line_length   = 100,
        .diag_format   = .human,
        .color_mode    = .auto,
        .werror        = false,
        .allocator     = std.testing.allocator,
    };
}

test "applyFlag - bool effects" {
    var cli = testCli();
    defer cli.deinit();

    try applyFlag(.set_verbose, "", &cli, std.testing.allocator);
    try std.testing.expect(cli.verbose);

    try applyFlag(.set_fast, "", &cli, std.testing.allocator);
    try std.testing.expectEqual(OptLevel.fast, cli.optimize);

    try applyFlag(.set_small, "", &cli, std.testing.allocator);
    try std.testing.expectEqual(OptLevel.small, cli.optimize);

    try applyFlag(.set_werror, "", &cli, std.testing.allocator);
    try std.testing.expect(cli.werror);

    try applyFlag(.set_gen_api, "", &cli, std.testing.allocator);
    try std.testing.expect(cli.gen_api);

    try applyFlag(.set_gen_std, "", &cli, std.testing.allocator);
    try std.testing.expect(cli.gen_std);

    try applyFlag(.set_gen_syntax, "", &cli, std.testing.allocator);
    try std.testing.expect(cli.gen_syntax);
}

test "applyFlag - diag_format" {
    var cli = testCli();
    defer cli.deinit();

    try applyFlag(.set_diag_format, "json", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.DiagFormat.json, cli.diag_format);

    try applyFlag(.set_diag_format, "short", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.DiagFormat.short, cli.diag_format);

    try applyFlag(.set_diag_format, "human", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.DiagFormat.human, cli.diag_format);
}

test "applyFlag - color" {
    var cli = testCli();
    defer cli.deinit();

    try applyFlag(.set_color, "always", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.ColorMode.always, cli.color_mode);

    try applyFlag(.set_color, "never", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.ColorMode.never, cli.color_mode);

    try applyFlag(.set_color, "auto", &cli, std.testing.allocator);
    try std.testing.expectEqual(errors_mod.ColorMode.auto, cli.color_mode);
}

test "applyFlag - line_length" {
    var cli = testCli();
    defer cli.deinit();

    try applyFlag(.set_line_length, "80", &cli, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 80), cli.line_length);

    try applyFlag(.set_line_length, "0", &cli, std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), cli.line_length);
}

test "applyFlag - append_target" {
    var cli = testCli();
    defer cli.deinit();

    try applyFlag(.{ .append_target = .linux_x64 }, "", &cli, std.testing.allocator);
    try applyFlag(.{ .append_target = .wasm }, "", &cli, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), cli.targets.items.len);
    try std.testing.expectEqual(BuildTarget.linux_x64, cli.targets.items[0]);
    try std.testing.expectEqual(BuildTarget.wasm, cli.targets.items[1]);
}
