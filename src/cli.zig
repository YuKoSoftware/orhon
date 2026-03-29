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
    allocator: std.mem.Allocator, // owns duped strings

    pub fn deinit(self: *const CliArgs) void {
        if (self.project_name.len > 0) self.allocator.free(self.project_name);
        if (!std.mem.eql(u8, self.source_dir, "src")) self.allocator.free(self.source_dir);
        @constCast(&self.targets).deinit(self.allocator);
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
    } else if (std.mem.eql(u8, cmd_str, "analysis")) {
        cli.command = .analysis;
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
        \\  gendoc              Generate Markdown docs from /// comments (pub items)
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
