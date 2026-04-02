// pipeline_passes.zig — Per-module compilation passes 4–11
// Satellite of pipeline.zig. Runs declaration collection through codegen
// for a single module.

const std = @import("std");
const parser = @import("parser.zig");
const module = @import("module.zig");
const declarations = @import("declarations.zig");
const resolver = @import("resolver.zig");
const ownership = @import("ownership.zig");
const borrow = @import("borrow.zig");
const thread_safety = @import("thread_safety.zig");
const propagation = @import("propagation.zig");
const sema = @import("sema.zig");
const mir = @import("mir/mir.zig");
const codegen = @import("codegen/codegen.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const constants = @import("constants.zig");
const _cli = @import("cli.zig");

/// Result of compiling a single module through passes 4–11.
pub const CompileResult = struct {
    /// Whether a fatal error was encountered.
    had_error: bool = false,
    /// The declaration collector (owned by caller via decl_collector_ptrs).
    decl_collector: *declarations.DeclCollector,
};

/// Validate 'main' as reserved name in a module's top-level declarations.
pub fn validateMainReserved(
    ast: *parser.Node,
    mod_ptr: *module.Module,
    locs_ptr: ?*const parser.LocMap,
    file_offsets: []module.FileOffset,
    reporter: *errors.Reporter,
) !bool {
    const is_exe = mod_ptr.build_type == .exe;
    var has_func_main = false;

    for (ast.program.top_level) |node| {
        switch (node.*) {
            .var_decl => |v| {
                if (std.mem.eql(u8, v.name, "main")) {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            },
            .struct_decl => |s| {
                if (std.mem.eql(u8, s.name, "main")) {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            },
            .enum_decl => |e| {
                if (std.mem.eql(u8, e.name, "main")) {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            },
            .blueprint_decl => |b| {
                if (std.mem.eql(u8, b.name, "main")) {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            },
            .bitfield_decl => |bf| {
                if (std.mem.eql(u8, bf.name, "main")) {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            },
            .func_decl => |f| {
                if (std.mem.eql(u8, f.name, "main")) {
                    if (!is_exe) {
                        try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), "func main() is only allowed in executable modules", .{});
                    } else {
                        has_func_main = true;
                    }
                }
            },
            else => {},
        }
    }

    // Exe modules must have func main() in the anchor file
    if (is_exe and !has_func_main) {
        try reporter.reportFmt(null, "executable module '{s}' requires func main() in anchor file", .{mod_ptr.name});
    }

    return reporter.hasErrors();
}

/// Copy bridge sidecar to generated dir, fixing up `export fn` visibility.
pub fn copySidecar(
    allocator: std.mem.Allocator,
    mod_name: []const u8,
    mod_ptr: *module.Module,
    cli: *_cli.CliArgs,
    reporter: *errors.Reporter,
    sidecar_copied: *std.StringHashMapUnmanaged([]const u8),
) !bool {
    if (!mod_ptr.has_bridges) return false;
    const sidecar_src = mod_ptr.sidecar_path orelse return false;

    try cache.ensureGeneratedDir();
    const sidecar_dst = try std.fmt.allocPrint(allocator, "{s}/{s}_bridge.zig", .{ cache.GENERATED_DIR, mod_name });
    defer allocator.free(sidecar_dst);

    // Read sidecar content
    const content = try std.fs.cwd().readFileAlloc(allocator, sidecar_src, 1024 * 1024);
    defer allocator.free(content);

    // Ensure all `export fn` have pub visibility
    var result = std.ArrayListUnmanaged(u8){};
    defer result.deinit(allocator);
    var pos: usize = 0;
    const needle = "export fn";
    while (std.mem.indexOfPos(u8, content, pos, needle)) |idx| {
        const already_pub = idx >= 4 and std.mem.eql(u8, content[idx - 4 .. idx], "pub ");
        try result.appendSlice(allocator, content[pos..idx]);
        if (!already_pub) {
            try result.appendSlice(allocator, "pub ");
        }
        try result.appendSlice(allocator, needle);
        pos = idx + needle.len;
    }
    try result.appendSlice(allocator, content[pos..]);

    // Write modified sidecar
    const dst_file = try std.fs.cwd().createFile(sidecar_dst, .{});
    defer dst_file.close();
    try dst_file.writeAll(result.items);

    // Copy any additional .zig files imported by the sidecar
    try cache.copySidecarImports(allocator, sidecar_src, cli.source_dir, mod_name, reporter, sidecar_copied);

    return reporter.hasErrors();
}

/// Run semantic passes 5–9 and codegen passes 10–11 for a single module.
/// Returns the generated Zig output string slice (owned by cg).
pub fn runSemanticAndCodegen(
    allocator: std.mem.Allocator,
    ast: *parser.Node,
    mod_name: []const u8,
    decl_collector: *declarations.DeclCollector,
    all_module_decls: *std.StringHashMap(*declarations.DeclTable),
    locs_ptr: ?*const parser.LocMap,
    file_offsets: []module.FileOffset,
    module_builds: *std.StringHashMapUnmanaged(module.BuildType),
    reporter: *errors.Reporter,
    cli: *_cli.CliArgs,
) !?[]const u8 {
    // ── Shared context for type resolution + validation passes 5–9 ──
    const sema_ctx = sema.SemanticContext{
        .allocator = allocator,
        .reporter = reporter,
        .decls = &decl_collector.table,
        .locs = locs_ptr,
        .file_offsets = file_offsets,
        .all_decls = all_module_decls,
    };

    // ── Pass 5: Type Resolution ────────────────────────────
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();

    try type_resolver.resolve(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 6: Ownership Analysis ─────────────────────────
    var ownership_checker = ownership.OwnershipChecker.init(allocator, &sema_ctx);
    try ownership_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 7: Borrow Checking ────────────────────────────
    var borrow_checker = borrow.BorrowChecker.init(allocator, &sema_ctx);
    defer borrow_checker.deinit();
    try borrow_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 8: Thread Safety ──────────────────────────────
    var thread_checker = thread_safety.ThreadSafetyChecker.init(allocator, &sema_ctx);
    defer thread_checker.deinit();
    try thread_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 9: Error Propagation ──────────────────────────
    var prop_checker = propagation.PropagationChecker.init(allocator, &sema_ctx);
    try prop_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 10: MIR Annotation ─────────────────────────────
    var mir_annotator = mir.MirAnnotator.init(allocator, reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    mir_annotator.all_decls = all_module_decls;

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

    // ── Pass 11: Zig Code Generation ───────────────────────
    const is_debug = cli.optimize == .debug;
    var cg = codegen.CodeGen.init(allocator, reporter, is_debug);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.all_decls = all_module_decls;
    cg.locs = locs_ptr;
    cg.file_offsets = file_offsets;
    cg.module_builds = module_builds;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.const_ref_params = &mir_annotator.const_ref_params;
    cg.mir_root = mir_root;

    try cg.generate(ast, mod_name);
    if (reporter.hasErrors()) return null;

    // Write generated .zig file to cache
    try cache.writeGeneratedZig(mod_name, cg.getOutput(), allocator);

    return cg.getOutput();
}
