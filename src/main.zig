// main.zig — Orhon compiler entry point
// Allocator setup, command dispatch. All logic delegated to split files.

const std = @import("std");
const build_options = @import("build_options");
const errors = @import("errors.zig");
const _cli = @import("cli.zig");
const _pipeline = @import("pipeline.zig");
const _init = @import("init.zig");
const _commands = @import("commands.zig");

// Re-export CLI types for any downstream that imports main.zig
pub const CliArgs = _cli.CliArgs;
pub const Command = _cli.Command;
pub const BuildTarget = _cli.BuildTarget;

/// Pre-pipeline command handler signature. Handlers for commands that return
/// without invoking the compile pipeline (init, fmt, lsp, help, ...) all match
/// this shape so the dispatch table below can be a plain data array.
const PreHandler = *const fn (allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void;

fn handleInit(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _init.initProject(allocator, cli.project_name, cli.init_in_place) catch |err| {
        std.debug.print("error: failed to create project: {}\n", .{err});
        std.process.exit(1);
    };
}

fn handleAddToPath(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _ = cli;
    _commands.addToPath(allocator) catch |err| {
        std.debug.print("error: failed to add orhon to PATH: {}\n", .{err});
        std.process.exit(1);
    };
}

fn handleFmt(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    const formatter = @import("formatter.zig");
    try formatter.formatProject(allocator, cli.source_dir, cli.line_length);
}

fn handleGendoc(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    try _commands.runGendoc(allocator, cli);
}

fn handleLsp(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _ = cli;
    const lsp = @import("lsp/lsp.zig");
    try lsp.serve(allocator);
}

fn handleWhich(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _ = allocator;
    _ = cli;
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
}

fn handleAnalysis(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    try _commands.runAnalysis(allocator, cli);
}

fn handleDebug(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    try _commands.runDebug(allocator, cli);
}

fn handleHelp(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _ = allocator;
    _ = cli;
    _cli.printHelp();
}

fn handleVersion(allocator: std.mem.Allocator, cli: *_cli.CliArgs) anyerror!void {
    _ = allocator;
    _ = cli;
    std.debug.print("orhon {s}\n", .{build_options.version});
}

/// Pre-pipeline dispatch table. Commands listed here return before the compile
/// pipeline runs. Adding a new pre-pipeline command is a one-line data change.
/// Commands NOT in this table (`build`, `run`, `test`) fall through to the
/// pipeline below.
const pre_pipeline_dispatch = [_]struct { cmd: Command, handler: PreHandler }{
    .{ .cmd = .init, .handler = handleInit },
    .{ .cmd = .addtopath, .handler = handleAddToPath },
    .{ .cmd = .fmt, .handler = handleFmt },
    .{ .cmd = .gendoc, .handler = handleGendoc },
    .{ .cmd = .lsp, .handler = handleLsp },
    .{ .cmd = .which, .handler = handleWhich },
    .{ .cmd = .analysis, .handler = handleAnalysis },
    .{ .cmd = .debug, .handler = handleDebug },
    .{ .cmd = .help, .handler = handleHelp },
    .{ .cmd = .version, .handler = handleVersion },
};

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    var cli = try _cli.parseArgs(allocator);
    defer cli.deinit();

    for (pre_pipeline_dispatch) |entry| {
        if (entry.cmd == cli.command) {
            try entry.handler(allocator, &cli);
            return;
        }
    }

    const mode: errors.BuildMode = if (cli.optimize == .fast or cli.optimize == .small)
        .release
    else
        .debug;

    var reporter = errors.Reporter.init(allocator, mode);
    defer reporter.deinit();

    // Run the pipeline
    const binary_name = _pipeline.runPipeline(allocator, &cli, &reporter) catch |err| blk: {
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
