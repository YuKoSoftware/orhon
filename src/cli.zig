// cli.zig — CLI argument parsing and command definitions

const std = @import("std");

// ============================================================
// CLI TYPES
// ============================================================

pub const Command = enum {
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

pub const CliArgs = struct {
    command: Command,
    targets: std.ArrayListUnmanaged(BuildTarget),
    optimize: OptLevel,
    verbose: bool,        // -verbose flag (show Zig compiler output)
    source_dir: []const u8,
    project_name: []const u8, // for init command
    init_in_place: bool, // orhon init (no name) — init in current dir
    gen_api: bool, // -api flag for gendoc (generate project API docs only)
    gen_std: bool, // -std flag for gendoc (generate stdlib docs only)
    gen_syntax: bool, // -syntax flag for gendoc (generate syntax reference only)
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

pub fn parseArgs(allocator: std.mem.Allocator) !CliArgs {
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
        .gen_api = false,
        .gen_std = false,
        .gen_syntax = false,
        .allocator = allocator,
    };

    // Parse command
    const cmd_map = std.StaticStringMap(Command).initComptime(.{
        .{ "build", .build },
        .{ "run", .run },
        .{ "test", .@"test" },
        .{ "init", .init },
        .{ "debug", .debug },
        .{ "fmt", .fmt },
        .{ "gendoc", .gendoc },
        .{ "addtopath", .addtopath },
        .{ "-addtopath", .addtopath },
        .{ "version", .version },
        .{ "--version", .version },
        .{ "lsp", .lsp },
        .{ "which", .which },
        .{ "analysis", .analysis },
        .{ "help", .help },
        .{ "--help", .help },
    });

    const cmd_str = args[1];
    if (cmd_map.get(cmd_str)) |cmd| {
        cli.command = cmd;
    } else {
        printUsage();
        std.process.exit(1);
    }

    // Handle init's project name argument
    if (cli.command == .init) {
        if (args.len >= 3) {
            cli.project_name = try allocator.dupe(u8, args[2]);
        } else {
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

    // Parse flags
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const target_map = std.StaticStringMap(BuildTarget).initComptime(.{
            .{ "-linux_x64", .linux_x64 },
            .{ "-linux_arm", .linux_arm },
            .{ "-win_x64", .win_x64 },
            .{ "-mac_x64", .mac_x64 },
            .{ "-mac_arm", .mac_arm },
            .{ "-wasm", .wasm },
            .{ "-zig", .zig },
        });

        if (target_map.get(arg)) |target| {
            if (cli.command != .build) {
                std.debug.print("warning: target flag '{s}' ignored (only valid with 'build')\n", .{arg});
                continue;
            }
            try cli.targets.append(allocator, target);
        } else if (std.mem.eql(u8, arg, "-fast")) {
            cli.optimize = .fast;
        } else if (std.mem.eql(u8, arg, "-small")) {
            cli.optimize = .small;
        } else if (std.mem.eql(u8, arg, "-verbose")) {
            cli.verbose = true;
        } else if (std.mem.eql(u8, arg, "-api")) {
            cli.gen_api = true;
        } else if (std.mem.eql(u8, arg, "-std")) {
            cli.gen_std = true;
        } else if (std.mem.eql(u8, arg, "-syntax")) {
            cli.gen_syntax = true;
        } else {
            // Treat as source directory
            cli.source_dir = try allocator.dupe(u8, arg);
        }
    }

    return cli;
}

pub fn printUsage() void {
    const usage =
        \\orhon — The Orhon compiler  (orhon help for more info)
        \\
        \\  build   run   test   fmt   gendoc   init   lsp   addtopath   debug   analysis   version
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
        \\  init [name]         Create a new project (in ./<name>/ or current dir if no name)
        \\  fmt                 Format all .orh files in the project
        \\  gendoc              Generate all docs (api + std + syntax)
        \\                        -api     Project API docs only (docs/api/)
        \\                        -std     Stdlib reference only (docs/std/)
        \\                        -syntax  Syntax reference only (docs/syntax.md)
        \\  lsp                 Start the language server (for editor integration)
        \\  addtopath           Add orhon to your shell PATH
        \\  debug               Show project info — modules, files, source directory
        \\  analysis <file>     Run PEG grammar validation on a single .orh file
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
// TESTS
// ============================================================

test "cli - build target names" {
    try std.testing.expectEqual(BuildTarget.native, .native);
    try std.testing.expectEqual(BuildTarget.linux_x64, .linux_x64);
    try std.testing.expectEqual(BuildTarget.win_x64, .win_x64);
    try std.testing.expectEqual(BuildTarget.wasm, .wasm);
    try std.testing.expectEqual(BuildTarget.zig, .zig);
}
