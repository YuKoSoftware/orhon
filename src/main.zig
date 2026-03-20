// main.zig — Kodr compiler entry point
// CLI argument parsing and pipeline orchestration.
// No business logic here — delegates to each pass.

const std = @import("std");
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
    initstd,
    debug,
    version,
    help,
};

const BuildTarget = enum {
    native,
    x64,
    arm,
    wasm,
};

const OptLevel = enum {
    debug,
    release,
    fast,
};

const CliArgs = struct {
    command: Command,
    target: BuildTarget,
    optimize: OptLevel,
    show_zig: bool,       // -zig flag
    source_dir: []const u8,
    project_name: []const u8, // for init command
    allocator: std.mem.Allocator, // owns duped strings

    pub fn deinit(self: *const CliArgs) void {
        // Free duped strings (default values are string literals — only free if non-empty)
        if (self.project_name.len > 0) self.allocator.free(self.project_name);
        if (!std.mem.eql(u8, self.source_dir, "src")) self.allocator.free(self.source_dir);
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
        .target = .native,
        .optimize = .debug,
        .show_zig = false,
        .source_dir = "src",
        .project_name = "",
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
        if (args.len < 3) {
            std.debug.print("usage: kodr init <project_name>\n", .{});
            std.process.exit(1);
        }
        cli.project_name = try allocator.dupe(u8, args[2]);
    } else if (std.mem.eql(u8, cmd_str, "initstd")) {
        cli.command = .initstd;
    } else if (std.mem.eql(u8, cmd_str, "debug")) {
        cli.command = .debug;
    } else if (std.mem.eql(u8, cmd_str, "addtopath") or std.mem.eql(u8, cmd_str, "-addtopath")) {
        cli.command = .addtopath;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version")) {
        cli.command = .version;
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
        if (std.mem.eql(u8, arg, "-x64")) {
            cli.target = .x64;
        } else if (std.mem.eql(u8, arg, "-arm")) {
            cli.target = .arm;
        } else if (std.mem.eql(u8, arg, "-wasm")) {
            cli.target = .wasm;
        } else if (std.mem.eql(u8, arg, "-release")) {
            cli.optimize = .release;
        } else if (std.mem.eql(u8, arg, "-fast")) {
            cli.optimize = .fast;
        } else if (std.mem.eql(u8, arg, "-zig")) {
            cli.show_zig = true;
        } else {
            // Treat as source directory
            cli.source_dir = try allocator.dupe(u8, arg);
        }
    }

    return cli;
}

fn printUsage() void {
    const usage =
        \\kodr — The Kodr compiler  (kodr help for more info)
        \\
        \\  build   run   test   init   initstd   addtopath   debug   version
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printHelp() void {
    const help =
        \\kodr — The Kodr programming language compiler
        \\
        \\Commands:
        \\  build               Compile the project in the current directory
        \\  run                 Build and immediately execute the binary
        \\  test                Run all test { } blocks in the project
        \\  init <name>         Create a new project in ./<name>/
        \\  initstd             Install the standard library next to the kodr binary
        \\  addtopath           Add kodr to your shell PATH
        \\  debug               Show project info — modules, files, source directory
        \\  version             Print the compiler version
        \\
        \\Build flags (for build and run):
        \\  -x64                Target x86-64 Linux
        \\  -arm                Target ARM64 Linux
        \\  -wasm               Target WebAssembly
        \\  -release            Optimized build with safety checks
        \\  -fast               Maximum optimization, no safety checks
        \\  -zig                Show raw Zig compiler output (for debugging the compiler)
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
const MAIN_KODR_TEMPLATE         = @embedFile("templates/main.kodr");
const EXAMPLE_KODR_TEMPLATE      = @embedFile("templates/example.kodr");
const CONTROL_FLOW_KODR_TEMPLATE = @embedFile("templates/control_flow.kodr");


fn initProject(allocator: std.mem.Allocator, name: []const u8) !void {
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

    // Create <name>/ and <name>/src/
    // Create project directory and src/ subdirectory
    const src_dir_path = try std.fs.path.join(allocator, &.{ name, "src" });
    defer allocator.free(src_dir_path);
    try std.fs.cwd().makePath(src_dir_path);

    // Write src/main.kodr from template
    // Template contains a single {s} placeholder for the project name.
    // Split on it and write in two parts — avoids allocPrint brace escaping issues.
    const main_kodr_path = try std.fs.path.join(allocator, &.{ name, "src", "main.kodr" });
    defer allocator.free(main_kodr_path);

    const main_file = try std.fs.cwd().createFile(main_kodr_path, .{});
    defer main_file.close();

    const placeholder = "{s}";
    if (std.mem.indexOf(u8, MAIN_KODR_TEMPLATE, placeholder)) |pos| {
        try main_file.writeAll(MAIN_KODR_TEMPLATE[0..pos]);
        try main_file.writeAll(name);
        try main_file.writeAll(MAIN_KODR_TEMPLATE[pos + placeholder.len..]);
    } else {
        try main_file.writeAll(MAIN_KODR_TEMPLATE);
    }

    // Write src/example.kodr from template
    const example_kodr_path = try std.fs.path.join(allocator, &.{ name, "src", "example.kodr" });
    defer allocator.free(example_kodr_path);

    const example_file = try std.fs.cwd().createFile(example_kodr_path, .{});
    defer example_file.close();
    try example_file.writeAll(EXAMPLE_KODR_TEMPLATE);

    // Write src/control_flow.kodr from template
    const control_flow_path = try std.fs.path.join(allocator, &.{ name, "src", "control_flow.kodr" });
    defer allocator.free(control_flow_path);

    const control_flow_file = try std.fs.cwd().createFile(control_flow_path, .{});
    defer control_flow_file.close();
    try control_flow_file.writeAll(CONTROL_FLOW_KODR_TEMPLATE);

    std.debug.print("Created project '{s}'\n", .{name});
    std.debug.print("  {s}/\n", .{name});
    std.debug.print("  {s}/src/\n", .{name});
    std.debug.print("  {s}/src/main.kodr\n", .{name});
    std.debug.print("  {s}/src/example.kodr\n", .{name});
    std.debug.print("  {s}/src/control_flow.kodr\n", .{name});
    std.debug.print("\nGet started:\n", .{});
    std.debug.print("  cd {s}\n", .{name});
    std.debug.print("  kodr build\n", .{});
    std.debug.print("  kodr run\n", .{});
}

// ============================================================
// STD INIT
// ============================================================

const CONSOLE_KODR = @embedFile("std/console.kodr");
const CONSOLE_ZIG  = @embedFile("std/console.zig");
const FS_KODR      = @embedFile("std/fs.kodr");
const FS_ZIG       = @embedFile("std/fs.zig");
const MATH_KODR    = @embedFile("std/math.kodr");
const MATH_ZIG     = @embedFile("std/math.zig");
const MEM_KODR     = @embedFile("std/mem.kodr");
const MEM_ZIG      = @embedFile("std/mem.zig");

fn initStd(allocator: std.mem.Allocator) !void {
    // Find directory containing the kodr binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    // Create std/ next to binary
    const std_dir = try std.fs.path.join(allocator, &.{ exe_dir, "std" });
    defer allocator.free(std_dir);
    try std.fs.cwd().makePath(std_dir);

    // Write console.kodr into std/
    const console_kodr_path = try std.fs.path.join(allocator, &.{ std_dir, "console.kodr" });
    defer allocator.free(console_kodr_path);
    const console_kodr_file = try std.fs.cwd().createFile(console_kodr_path, .{});
    defer console_kodr_file.close();
    try console_kodr_file.writeAll(CONSOLE_KODR);

    // Write console.zig into std/ — paired implementation file
    const console_zig_path = try std.fs.path.join(allocator, &.{ std_dir, "console.zig" });
    defer allocator.free(console_zig_path);
    const console_zig_file = try std.fs.cwd().createFile(console_zig_path, .{});
    defer console_zig_file.close();
    try console_zig_file.writeAll(CONSOLE_ZIG);

    // Write fs.kodr into std/
    const fs_kodr_path = try std.fs.path.join(allocator, &.{ std_dir, "fs.kodr" });
    defer allocator.free(fs_kodr_path);
    const fs_kodr_file = try std.fs.cwd().createFile(fs_kodr_path, .{});
    defer fs_kodr_file.close();
    try fs_kodr_file.writeAll(FS_KODR);

    // Write fs.zig into std/ — paired implementation file
    const fs_zig_path = try std.fs.path.join(allocator, &.{ std_dir, "fs.zig" });
    defer allocator.free(fs_zig_path);
    const fs_zig_file = try std.fs.cwd().createFile(fs_zig_path, .{});
    defer fs_zig_file.close();
    try fs_zig_file.writeAll(FS_ZIG);

    // Write math.kodr into std/
    const math_kodr_path = try std.fs.path.join(allocator, &.{ std_dir, "math.kodr" });
    defer allocator.free(math_kodr_path);
    const math_kodr_file = try std.fs.cwd().createFile(math_kodr_path, .{});
    defer math_kodr_file.close();
    try math_kodr_file.writeAll(MATH_KODR);

    // Write math.zig into std/ — paired implementation file
    const math_zig_path = try std.fs.path.join(allocator, &.{ std_dir, "math.zig" });
    defer allocator.free(math_zig_path);
    const math_zig_file = try std.fs.cwd().createFile(math_zig_path, .{});
    defer math_zig_file.close();
    try math_zig_file.writeAll(MATH_ZIG);

    // Write mem.kodr into std/
    const mem_kodr_path = try std.fs.path.join(allocator, &.{ std_dir, "mem.kodr" });
    defer allocator.free(mem_kodr_path);
    const mem_kodr_file = try std.fs.cwd().createFile(mem_kodr_path, .{});
    defer mem_kodr_file.close();
    try mem_kodr_file.writeAll(MEM_KODR);

    // Write mem.zig into std/ — allocator wrapper implementations
    const mem_zig_path = try std.fs.path.join(allocator, &.{ std_dir, "mem.zig" });
    defer allocator.free(mem_zig_path);
    const mem_zig_file = try std.fs.cwd().createFile(mem_zig_path, .{});
    defer mem_zig_file.close();
    try mem_zig_file.writeAll(MEM_ZIG);

    // Create global/ next to binary (empty — user fills this)
    const global_dir = try std.fs.path.join(allocator, &.{ exe_dir, "global" });
    defer allocator.free(global_dir);
    try std.fs.cwd().makePath(global_dir);

    std.debug.print("Initialized kodr stdlib:\n", .{});
    std.debug.print("  {s}/std/\n", .{exe_dir});
    std.debug.print("  {s}/std/console.kodr\n", .{exe_dir});
    std.debug.print("  {s}/std/console.zig\n", .{exe_dir});
    std.debug.print("  {s}/std/fs.kodr\n", .{exe_dir});
    std.debug.print("  {s}/std/fs.zig\n", .{exe_dir});
    std.debug.print("  {s}/std/math.kodr\n", .{exe_dir});
    std.debug.print("  {s}/std/math.zig\n", .{exe_dir});
    std.debug.print("  {s}/std/mem.kodr\n", .{exe_dir});
    std.debug.print("  {s}/global/\n", .{exe_dir});
    std.debug.print("\nAdd your shared modules to {s}/global/\n", .{exe_dir});
}

// ============================================================
// PATH INSTALLATION
// ============================================================

fn addToPath(allocator: std.mem.Allocator) !void {
    // Get the directory containing the kodr binary
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    // Check if already in PATH
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch "";
    defer if (path_env.len > 0) allocator.free(path_env);

    if (std.mem.indexOf(u8, path_env, exe_dir) != null) {
        std.debug.print("kodr is already in PATH ({s})\n", .{exe_dir});
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
        "\n# kodr compiler\nexport PATH=\"$PATH:{s}\"\n",
        .{exe_dir});
    defer allocator.free(export_line);

    // Fish uses a different syntax
    const fish_line = try std.fmt.allocPrint(allocator,
        "\n# kodr compiler\nfish_add_path {s}\n",
        .{exe_dir});
    defer allocator.free(fish_line);

    const line_to_write = if (std.mem.endsWith(u8, shell, "fish"))
        fish_line
    else
        export_line;

    // Append to profile — create it if it doesn't exist yet
    // For fish, ensure the config directory exists first
    if (std.mem.endsWith(u8, shell, "fish")) {
        const fish_config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "fish" });
        defer allocator.free(fish_config_dir);
        try std.fs.cwd().makePath(fish_config_dir);
    }

    const file = try std.fs.cwd().createFile(profile_path, .{ .truncate = false, .exclusive = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line_to_write);

    std.debug.print("Added kodr to PATH in {s}\n", .{profile_path});
    std.debug.print("Run: source {s}\n", .{profile_path});
    std.debug.print("  or open a new terminal\n", .{});
}

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    const cli = try parseArgs(allocator);
    defer cli.deinit();

    // Handle init and addtopath before setting up the full pipeline
    if (cli.command == .init) {
        initProject(allocator, cli.project_name) catch |err| {
            std.debug.print("error: failed to create project: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .addtopath) {
        addToPath(allocator) catch |err| {
            std.debug.print("error: failed to add kodr to PATH: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .initstd) {
        try initStd(allocator);
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
        std.debug.print("kodr 0.2.1\n", .{});
        return;
    }

    const mode: errors.BuildMode = if (cli.optimize == .release or cli.optimize == .fast)
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

    // kodr run — execute the built binary
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

    std.debug.print("=== kodr debug ===\n", .{});
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
        std.debug.print("  Run `kodr build` from inside a kodr project directory.\n", .{});
        return;
    }

    // Scan and report every .kodr file found
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
        std.debug.print("  (no .kodr files found in '{s}')\n", .{cli.source_dir});
    }

    std.debug.print("\n", .{});
}

fn runPipeline(allocator: std.mem.Allocator, cli: *const CliArgs, reporter: *errors.Reporter) !?[]const u8 {

    // ── Pass 3: Module Resolution ──────────────────────────────
    var mod_resolver = module.Resolver.init(allocator, reporter);
    defer mod_resolver.deinit();

    // Check source dir exists before scanning — give a clear error if not
    std.fs.cwd().access(cli.source_dir, .{}) catch {
        std.debug.print("error: source directory '{s}' not found\n", .{cli.source_dir});
        std.debug.print("  run `kodr build` from inside a kodr project directory\n", .{});
        std.debug.print("  expected: {s}/main.kodr\n", .{cli.source_dir});
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

    // Parse all modules
    try mod_resolver.parseModules(allocator);
    if (reporter.hasErrors()) return null;

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

    // Process each module in dependency order
    for (order) |mod_name| {
        const mod_ptr = mod_resolver.modules.getPtr(mod_name) orelse continue;
        const ast = mod_ptr.ast orelse continue;

        // Check if module needs recompilation
        const needs_recompile = try comp_cache.moduleNeedsRecompile(mod_name, mod_ptr.files);
        if (!needs_recompile) {
            // Skip — use cached .zig file
            continue;
        }

        // Get source location map and file path for error reporting
        const locs_ptr: ?*const parser.LocMap = if (mod_ptr.locs) |*l| l else null;
        const source_file: []const u8 = if (mod_ptr.files.len > 0) mod_ptr.files[0] else "";

        // ── Pass 4: Declaration Collection ────────────────────
        var decl_collector = declarations.DeclCollector.init(allocator, reporter);
        defer decl_collector.deinit();
        decl_collector.locs = locs_ptr;
        decl_collector.source_file = source_file;

        try decl_collector.collect(ast);
        if (reporter.hasErrors()) return null;

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
        var prop_checker = propagation.PropChecker.init(allocator, reporter, &decl_collector.table);
        prop_checker.locs = locs_ptr;
        prop_checker.source_file = source_file;
        try prop_checker.check(ast);
        if (reporter.hasErrors()) return null;

        // ── Pass 10: MIR Generation ────────────────────────────
        var mir_gen = mir.MirGen.init(mod_name, allocator, reporter);
        defer mir_gen.deinit();

        try mir_gen.generate(ast);
        if (reporter.hasErrors()) return null;

        // ── Extern Sidecar Validation ──────────────────────────
        // If the module has extern func declarations, a paired .zig sidecar
        // must exist next to the anchor .kodr file.
        if (collectExternFuncNames(ast, allocator)) |extern_names| {
            defer {
                for (extern_names) |n| allocator.free(n);
                allocator.free(extern_names);
            }
            if (extern_names.len > 0) {
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
                    const first_name = extern_names[0];
                    const msg = try std.fmt.allocPrint(allocator,
                        "extern func '{s}': missing sidecar file '{s}'",
                        .{ first_name, sidecar_src });
                    defer allocator.free(msg);
                    try reporter.report(.{ .message = msg });
                };
                if (!reporter.hasErrors()) {
                    // Sidecar exists — copy as <mod>_extern.zig so generated <mod>.zig can @import it
                    try cache.ensureGeneratedDir();
                    const sidecar_dst = try std.fmt.allocPrint(allocator, "{s}/{s}_extern.zig", .{ cache.GENERATED_DIR, mod_name });
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
        cg.locs = locs_ptr;
        cg.source_file = source_file;
        cg.module_builds = &module_builds;

        try cg.generate(ast, mod_name);
        if (reporter.hasErrors()) return null;

        // Write generated .zig file to cache
        try cache.writeGeneratedZig(mod_name, cg.getOutput(), allocator);

        // If module uses File/Dir types, copy fs.zig to generated dir
        if (cg.uses_fs) {
            try cache.writeGeneratedZig("fs_rt", FS_ZIG, allocator);
        }
        // If module uses allocator wrappers, copy mem.zig to generated dir
        if (cg.uses_mem) {
            try cache.writeGeneratedZig("mem_rt", MEM_ZIG, allocator);
        }

        // Update timestamp cache
        for (mod_ptr.files) |file| {
            try comp_cache.updateTimestamp(file);
        }
    }

    // Save updated cache
    try comp_cache.saveTimestamps();
    try comp_cache.saveDeps();

    if (cli.command == .@"test") {
        var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.show_zig) catch |err| {
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
    var runner = zig_runner.ZigRunner.init(allocator, reporter, cli.show_zig) catch |err| {
        if (err == error.ZigNotFound) return null;
        return err;
    };
    defer runner.deinit();

    const target_str: []const u8 = switch (cli.target) {
        .x64 => "x86_64-linux",
        .arm => "aarch64-linux",
        .wasm => "wasm32-freestanding",
        .native => "",
    };

    const opt_str: []const u8 = switch (cli.optimize) {
        .release => "release",
        .fast => "fast",
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

    var exe_binary_name: ?[]const u8 = null; // tracked for `kodr run`

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
            });
        }

        const built = try runner.buildAll(target_str, opt_str, multi_targets.items);
        if (!built) return null;

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
                }
            }

            const binary_name = if (project_name.len > 0) project_name else mod.name;

            try runner.generateBuildZig(mod.name, build_type, binary_name);

            const built = if (std.mem.eql(u8, build_type, "exe"))
                try runner.build(target_str, opt_str, mod.name, binary_name)
            else
                try runner.buildLib(target_str, opt_str, mod.name, binary_name, build_type);
            if (!built) return null;

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

    // Return exe name for `kodr run`; empty string signals lib-only success
    return exe_binary_name orelse try allocator.dupe(u8, "");
}

/// Collect the names of all extern func declarations in an AST.
/// Returns an allocated slice of duped name strings, or an error.
/// Caller must free each name and the slice itself.
fn collectExternFuncNames(ast: *parser.Node, allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    if (ast.* != .program) return names.toOwnedSlice(allocator);
    for (ast.program.top_level) |node| {
        switch (node.*) {
            .func_decl => |f| {
                if (f.is_extern) try names.append(allocator, try allocator.dupe(u8, f.name));
            },
            .struct_decl => |s| {
                for (s.members) |m| {
                    if (m.* == .func_decl and m.func_decl.is_extern)
                        try names.append(allocator, try allocator.dupe(u8, m.func_decl.name));
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
// `.kodr` file into bin/ so consumers can type-check against the API.
// The interface file is valid Kodr — it has the module declaration,
// version, and all pub signatures, but no bodies or private members.

/// Write a type node as Kodr source syntax into a buffer
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
                    .var_decl => |v| {
                        if (!v.is_pub) continue;
                        try buf.appendSlice(alloc, "    pub var ");
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

/// Generate a pub-only interface `.kodr` file into `bin/<binary_name>.kodr`.
/// Called after a successful static or dynamic library build.
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
    try buf.appendSlice(alloc, "// Kodr interface file — generated by kodr, do not edit\n\n");
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

    // Write to bin/<binary_name>.kodr
    try std.fs.cwd().makePath("bin");
    const path = try std.fmt.allocPrint(alloc, "bin/{s}.kodr", .{binary_name});
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
    try std.testing.expectEqual(BuildTarget.x64, .x64);
    try std.testing.expectEqual(BuildTarget.wasm, .wasm);
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
    var prop_checker = propagation.PropChecker.init(alloc, &reporter, null);
    try prop_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // MIR
    var mir_gen = mir.MirGen.init("main", alloc, &reporter);
    defer mir_gen.deinit();
    try mir_gen.generate(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Codegen
    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
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

    // 'a' is never reassigned — should become const
    // 'b' is reassigned — should stay var
    const source =
        \\module main
        \\
        \\func main() void {
        \\    var a: i32 = 1
        \\    var b: i32 = 2
        \\    b = 3
        \\}
        \\
    ;

    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var p = parser.Parser.init(tokens.items, alloc, &reporter);
    defer p.deinit();
    const ast = try p.parseProgram();

    var decl_collector = declarations.DeclCollector.init(alloc, &reporter);
    defer decl_collector.deinit();
    try decl_collector.collect(ast);

    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
    try cg.generate(ast, "main");

    const output = cg.getOutput();
    try std.testing.expect(std.mem.indexOf(u8, output, "const a: i32 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var b: i32 = 2;") != null);
}

/// Parse source and run codegen only (no analysis passes).
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
    var cg = codegen.CodeGen.init(alloc, reporter, true);
    defer cg.deinit();
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
        \\enum Color(u8) {
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

test "codegen - List(T) declaration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module main
        \\func main() void {
        \\    var alloc = mem.SMP()
        \\    var items: List(i32) = List(i32).init(alloc)
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "ArrayList(i32)") != null);
}

test "codegen - bitfield declaration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module main
        \\bitfield Perms(u8) {
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
