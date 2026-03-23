const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 4, .patch = 9 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version string for runtime use
    const version_str = std.fmt.comptimePrint("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });

    // Main orhon compiler executable
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", blk: {
        const opts = b.addOptions();
        opts.addOption([]const u8, "version", version_str);
        break :blk opts;
    });
    const exe = b.addExecutable(.{
        .name = "orhon",
        .root_module = root_module,
        .version = version,
    });

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the orhon compiler");
    run_step.dependOn(&run_cmd.step);

    // Test step — runs all embedded tests across all source files
    const test_files = [_][]const u8{
        "src/main.zig",
        "src/lexer.zig",
        "src/parser.zig",
        "src/module.zig",
        "src/declarations.zig",
        "src/resolver.zig",
        "src/ownership.zig",
        "src/borrow.zig",
        "src/thread_safety.zig",
        "src/propagation.zig",
        "src/mir.zig",
        "src/codegen.zig",
        "src/zig_runner.zig",
        "src/types.zig",
        "src/errors.zig",
        "src/builtins.zig",
        "src/cache.zig",
        "src/formatter.zig",
        "src/lsp.zig",
    };

    const test_step = b.step("test", "Run all compiler tests");

    for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // Fuzz step — runs random inputs through lexer + parser
    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    const fuzz_step = b.step("fuzz", "Fuzz test the lexer and parser");
    fuzz_step.dependOn(&run_fuzz.step);
}
