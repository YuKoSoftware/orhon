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

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    var cli = try _cli.parseArgs(allocator);
    defer cli.deinit();

    // Handle init and addtopath before setting up the full pipeline
    if (cli.command == .init) {
        _init.initProject(allocator, cli.project_name, cli.init_in_place) catch |err| {
            std.debug.print("error: failed to create project: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .addtopath) {
        _commands.addToPath(allocator) catch |err| {
            std.debug.print("error: failed to add orhon to PATH: {}\n", .{err});
            std.process.exit(1);
        };
        return;
    }

    if (cli.command == .fmt) {
        const formatter = @import("formatter.zig");
        try formatter.formatProject(allocator, cli.source_dir, cli.line_length);
        return;
    }

    if (cli.command == .gendoc) {
        try _commands.runGendoc(allocator, &cli);
        return;
    }

    if (cli.command == .lsp) {
        const lsp = @import("lsp/lsp.zig");
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

    if (cli.command == .analysis) {
        try _commands.runAnalysis(allocator, &cli);
        return;
    }

    if (cli.command == .debug) {
        try _commands.runDebug(allocator, &cli);
        return;
    }

    if (cli.command == .help) {
        _cli.printHelp();
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
