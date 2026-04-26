// pipeline_context.zig — Build-wide and per-module compilation contexts.
//
// Two roles:
//   * `BuildContext` — bundle of build-wide shared state (cache, registries,
//     reporter, cli, output sinks). Lives for one `runPipeline` invocation.
//   * `ModuleCompile` — per-module lifetime container with an arena allocator.
//     One per module being compiled this build. Owned by an
//     `ArrayList(ModuleCompile)` in `runPipeline`; all arenas freed at end
//     of build.
//
// Spec: docs/superpowers/specs/2026-04-26-p1-module-compile-design.md

const std = @import("std");
const cache = @import("cache.zig");
const declarations = @import("declarations.zig");
const errors = @import("errors.zig");
const mir = @import("mir/mir.zig");
const module = @import("module.zig");
const _cli = @import("cli.zig");

/// Build-wide shared state. One instance per `runPipeline` invocation,
/// constructed on the stack in `runPipeline` and passed by pointer into
/// `compileOne`.
pub const BuildContext = struct {
    gpa: std.mem.Allocator,

    // Cross-module compilation state
    comp_cache: *cache.Cache,
    union_registry: *mir.UnionRegistry,
    all_module_decls: *std.StringHashMap(*declarations.DeclTable),
    prev_iface_hashes: *std.StringHashMap(u64),
    module_builds: *std.StringHashMapUnmanaged(module.BuildType),

    // I/O
    reporter: *errors.Reporter,
    cli: *_cli.CliArgs,

    // Cache writeback sinks. `compileOne` appends to these; `runPipeline`
    // flushes them to disk after the loop.
    all_warnings: *std.ArrayListUnmanaged(cache.CachedWarning),
    all_union_entries: *std.ArrayListUnmanaged(cache.CachedUnionEntry),
};

/// Per-module lifetime container. Owns the arena that backs all per-module
/// allocations (AST conversion, decl collector, type resolver, MIR builder,
/// codegen scratch). Lives in `runPipeline`'s outer `ArrayList(ModuleCompile)`
/// from initialization until end of build.
///
/// Lifetime contract:
///   * `arena` outlives every other field on this struct.
///   * `decl_collector` is heap-allocated *inside* the arena; the table it
///     contains is referenced by `BuildContext.all_module_decls` across
///     modules. Therefore `arena` must not be reset/deinit'd until all later
///     modules have been compiled.
///   * `mod_name` and `mod_ptr` are borrowed from `module.Resolver` (which
///     outlives `ModuleCompile`).
///
/// Future work (M4): split into `iface_arena` (whole-build, holds decl table)
/// and `body_arena` (freed at end of `compileOne`, holds AST/MIR/codegen).
/// Out of scope for P1.
pub const ModuleCompile = struct {
    arena: std.heap.ArenaAllocator,
    mod_name: []const u8,
    mod_ptr: *module.Module,
    decl_collector: *declarations.DeclCollector,

    pub fn init(
        gpa: std.mem.Allocator,
        reporter: *errors.Reporter,
        mod_name: []const u8,
        mod_ptr: *module.Module,
    ) !ModuleCompile {
        var mc: ModuleCompile = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .mod_name = mod_name,
            .mod_ptr = mod_ptr,
            .decl_collector = undefined,
        };
        errdefer mc.arena.deinit();

        const arena_alloc = mc.arena.allocator();
        const dc = try arena_alloc.create(declarations.DeclCollector);
        dc.* = declarations.DeclCollector.init(arena_alloc, reporter);
        mc.decl_collector = dc;
        return mc;
    }

    pub fn deinit(self: *ModuleCompile) void {
        // decl_collector is arena-allocated; arena.deinit() reclaims it
        // along with all of its internal structures.
        self.arena.deinit();
    }
};

// ---------- tests ----------

test "ModuleCompile.init creates arena and decl collector" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var fake_mod: module.Module = undefined;
    var mc = try ModuleCompile.init(std.testing.allocator, &reporter, "test_mod", &fake_mod);
    defer mc.deinit();

    try std.testing.expectEqualStrings("test_mod", mc.mod_name);
    try std.testing.expect(@intFromPtr(mc.decl_collector) != 0);
}

test "ModuleCompile.deinit frees arena (no leaks)" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var fake_mod: module.Module = undefined;
    var mc = try ModuleCompile.init(std.testing.allocator, &reporter, "m", &fake_mod);

    // Allocate something inside the arena to verify it's freed by deinit.
    const arena_alloc = mc.arena.allocator();
    _ = try arena_alloc.alloc(u8, 4096);

    mc.deinit();
    // If the arena leaked, std.testing.allocator would catch it at test end.
}

test "two ModuleCompiles have independent arenas" {
    var reporter = errors.Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var fake_mod: module.Module = undefined;
    var a = try ModuleCompile.init(std.testing.allocator, &reporter, "a", &fake_mod);
    var b = try ModuleCompile.init(std.testing.allocator, &reporter, "b", &fake_mod);

    const a_buf = try a.arena.allocator().alloc(u8, 8);
    @memset(a_buf, 0xAA);
    const b_buf = try b.arena.allocator().alloc(u8, 8);
    @memset(b_buf, 0xBB);

    a.deinit();

    // b's allocation must still be valid after a is freed.
    try std.testing.expectEqual(@as(u8, 0xBB), b_buf[0]);

    b.deinit();
}
