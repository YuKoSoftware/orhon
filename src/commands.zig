// commands.zig — Secondary command runners (analysis, debug, gendoc, path, project emit)

const std = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const module = @import("module.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const peg = @import("peg.zig");
const _cli = @import("cli.zig");
const _std_bundle = @import("std_bundle.zig");

pub fn runAnalysis(allocator: std.mem.Allocator, cli: *const _cli.CliArgs) !void {
    const file_path = cli.source_dir;
    if (std.mem.eql(u8, file_path, "src")) {
        std.debug.print("usage: orhon analysis <file.orh>\n", .{});
        std.process.exit(1);
    }

    // Read the source file
    const source = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("error: could not read '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Lex
    var lex = lexer.Lexer.init(source);
    var tokens = lex.tokenize(allocator) catch |err| {
        std.debug.print("error: lexer failed on '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer tokens.deinit(allocator);

    std.debug.print("=== orhon analysis ===\n", .{});
    std.debug.print("file: {s}\n", .{file_path});
    std.debug.print("tokens: {d}\n", .{tokens.items.len});

    // Load PEG grammar
    var grammar = peg.loadGrammar(allocator) catch |err| {
        std.debug.print("error: could not load PEG grammar: {}\n", .{err});
        std.process.exit(1);
    };
    defer grammar.deinit();

    // Run PEG validation
    var engine = peg.Engine.init(&grammar, tokens.items, allocator);
    defer engine.deinit();

    const result = engine.matchRule("program", 0);
    if (result) |r| {
        const consumed_all = r.end_pos >= tokens.items.len or
            tokens.items[r.end_pos].kind == .eof;
        if (consumed_all) {
            std.debug.print("result: PASS — grammar validated successfully\n", .{});
        } else {
            const tok = tokens.items[r.end_pos];
            std.debug.print("result: PARTIAL — matched {d}/{d} tokens\n", .{
                r.end_pos, tokens.items.len,
            });
            std.debug.print("stuck at line {d}:{d} — unexpected '{s}' ({s})\n", .{
                tok.line, tok.col, tok.text, @tagName(tok.kind),
            });
            std.process.exit(1);
        }
    } else {
        const err = engine.getError();
        std.debug.print("result: FAIL\n", .{});
        if (err.expected_set.count() > 1) {
            const engine_mod2 = @import("peg/engine.zig");
            const total = err.expected_set.count();
            std.debug.print("error at line {d}:{d} — expected ", .{ err.line, err.col });
            var it = err.expected_set.iterator();
            var i: usize = 0;
            while (it.next()) |kind| {
                if (i > 0 and i < total - 1) std.debug.print(", ", .{});
                if (i > 0 and i == total - 1) {
                    if (total > 2) std.debug.print(", or ", .{}) else std.debug.print(" or ", .{});
                }
                std.debug.print("'{s}'", .{engine_mod2.kindDisplayName(kind)});
                i += 1;
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("error at line {d}:{d} — unexpected '{s}' ({s})\n", .{
                err.line, err.col, err.found, @tagName(err.found_kind),
            });
        }
        if (err.expected_rule.len > 0) {
            std.debug.print("while parsing: {s}\n", .{err.expected_rule});
        }
        std.process.exit(1);
    }
}

pub fn runDebug(allocator: std.mem.Allocator, cli: *const _cli.CliArgs) !void {
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
    reporter.diag_format = cli.diag_format;
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

pub fn runGendoc(allocator: std.mem.Allocator, cli: *const _cli.CliArgs) !void {
    // No flags = generate all; flags = generate only selected
    const gen_all = !cli.gen_api and !cli.gen_std and !cli.gen_syntax;

    // Ensure std files are available (parsing may discover std imports)
    try _std_bundle.ensureStdFiles(allocator);

    // Syntax reference
    if (gen_all or cli.gen_syntax) {
        const syntaxgen = @import("syntaxgen.zig");
        try syntaxgen.generateSyntaxDoc(allocator, "docs/syntax.md");
    }

    // Stdlib reference
    if (gen_all or cli.gen_std) {
        const zig_docgen = @import("zig_docgen.zig");
        try zig_docgen.generateStdDocs(allocator, cache.CACHE_DIR ++ "/std", "docs/std");
    }

    // Project API docs
    if (gen_all or cli.gen_api) {
        const docgen = @import("docgen.zig");

        std.fs.cwd().access(cli.source_dir, .{}) catch {
            if (!gen_all) std.debug.print("error: source directory '{s}' not found\n", .{cli.source_dir});
            return;
        };

        var reporter = errors.Reporter.init(allocator, .debug);
        reporter.diag_format = cli.diag_format;
        defer reporter.deinit();

        var mod_resolver = module.Resolver.init(allocator, &reporter);
        defer mod_resolver.deinit();

        try mod_resolver.scanDirectory(cli.source_dir);

        if (reporter.hasErrors()) {
            try reporter.flush();
            return;
        }

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

        try docgen.generateDocs(allocator, &mod_resolver, "docs/api");
    }
}

pub fn addToPath(allocator: std.mem.Allocator) !void {
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

/// Copy the generated Zig project from .orh-cache/generated/ to bin/zig/
pub fn emitZigProject(allocator: std.mem.Allocator) !void {
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
pub fn moveArtifactsToSubfolder(allocator: std.mem.Allocator, subfolder: []const u8) !void {
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
