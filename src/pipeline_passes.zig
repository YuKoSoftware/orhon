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
const propagation = @import("propagation.zig");
const sema = @import("sema.zig");
const mir = @import("mir/mir.zig");
const codegen = @import("codegen/codegen.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const constants = @import("constants.zig");
const _cli = @import("cli.zig");
const ast_conv = @import("ast_conv.zig");
const ast_store_mod = @import("ast_store.zig");
const mir_store_mod = @import("mir_store.zig");
const mir_builder_mod = @import("mir_builder.zig");

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
        const name: ?[]const u8 = switch (node.*) {
            .var_decl => |v| v.name,
            .struct_decl => |s| s.name,
            .enum_decl => |e| e.name,
            .handle_decl => |h| h.name,
            .blueprint_decl => |b| b.name,
            .func_decl => |f| f.name,
            else => null,
        };
        if (name) |n| {
            if (std.mem.eql(u8, n, "main")) {
                if (node.* == .func_decl) {
                    if (!is_exe) {
                        try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), "func main() is only allowed in executable modules", .{});
                    } else {
                        has_func_main = true;
                    }
                } else {
                    try reporter.reportFmt(module.resolveNodeLoc(locs_ptr, file_offsets, node), constants.Err.MAIN_RESERVED, .{});
                }
            }
        }
    }

    // Exe modules must have func main() in the anchor file
    if (is_exe and !has_func_main) {
        try reporter.reportFmt(null, "executable module '{s}' requires func main() in anchor file", .{mod_ptr.name});
    }

    return reporter.hasErrors();
}

/// Check for unused imports and emit warnings.
/// Scans module source files for "importname." qualifier patterns.
/// `use` (include) imports are always considered used since they merge symbols.
/// Library root modules (#build = static/dynamic) are skipped — they import
/// modules to expose them, not necessarily to use them directly.
pub fn checkUnusedImports(
    allocator: std.mem.Allocator,
    ast: *parser.Node,
    mod_ptr: *module.Module,
    locs_ptr: ?*const parser.LocMap,
    file_offsets: []module.FileOffset,
    reporter: *errors.Reporter,
) !void {
    // Skip library root modules — they import to expose, not to use
    if (mod_ptr.build_type == .static or mod_ptr.build_type == .dynamic) return;

    // Skip std modules — they live in .orh-cache/std/ and have internal imports
    if (mod_ptr.is_zig_module) return;
    for (mod_ptr.files) |file| {
        if (std.mem.indexOf(u8, file, ".orh-cache/std/") != null) return;
    }

    // Read all source files for this module into one buffer
    var source_parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (source_parts.items) |s| allocator.free(s);
        source_parts.deinit(allocator);
    }
    for (mod_ptr.files) |file| {
        const content = std.fs.cwd().readFileAlloc(allocator, file, 10 * 1024 * 1024) catch continue;
        source_parts.append(allocator, content) catch {
            allocator.free(content);
            continue;
        };
    }

    for (ast.program.imports) |imp_node| {
        if (imp_node.* != .import_decl) continue;
        const imp = imp_node.import_decl;

        // `use` imports merge symbols — always considered used
        if (imp.is_include) continue;

        // Skip std imports — may be needed transitively by other std modules
        if (imp.scope != null and std.mem.eql(u8, imp.scope.?, "std")) continue;

        const ref_name = imp.alias orelse imp.path;
        const prefix = try std.fmt.allocPrint(allocator, "{s}.", .{ref_name});
        defer allocator.free(prefix);

        // Search source text for "modname." qualifier pattern
        var used = false;
        for (source_parts.items) |source| {
            if (std.mem.indexOf(u8, source, prefix) != null) {
                used = true;
                break;
            }
        }

        if (!used) {
            const loc = module.resolveNodeLoc(locs_ptr, file_offsets, imp_node);
            try reporter.warnFmt(loc, "unused import: '{s}'", .{ref_name});
        }
    }
}

/// Run semantic passes 5–8 and codegen passes 10–11 for a single module.
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
    is_zig_module: bool,
    has_zig_sidecar: bool,
    union_registry: *mir.UnionRegistry,
) !?[]const u8 {
    // ── Convert AST to AstStore for index-based traversal (Phase A) ──
    var conv = ast_conv.ConvContext.init(allocator);
    defer conv.deinit();
    const ast_root = ast_conv.convertNode(&conv, ast) catch {
        try reporter.report(.{ .message = "internal: AST conversion failed" });
        return null;
    };

    // ── Shared context for type resolution + validation passes 5–9 ──
    var sema_ctx = sema.SemanticContext{
        .allocator = allocator,
        .reporter = reporter,
        .decls = &decl_collector.table,
        .locs = locs_ptr,
        .file_offsets = file_offsets,
        .all_decls = all_module_decls,
        .ast = &conv.store,
        .reverse_map = &conv.reverse_map,
    };

    // ── Pass 5: Type Resolution ────────────────────────────
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();
    // reverse_map is read from sema_ctx.reverse_map inside TypeResolver.reverseNode();

    try type_resolver.resolve(&conv.store, ast_root);
    if (reporter.hasErrors()) return null;

    // Expose the resolver's type_map so downstream passes (borrow, propagation)
    // can look up receiver types and other node-level type info. CB1: borrow
    // checker method resolution needs this to pick the correct `self` mutability.
    sema_ctx.type_map = &type_resolver.type_map;

    // ── Pass 6: Ownership Analysis ─────────────────────────
    var ownership_checker = ownership.OwnershipChecker.init(allocator, &sema_ctx);
    try ownership_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 7: Borrow Checking ────────────────────────────
    var borrow_checker = borrow.BorrowChecker.init(allocator, &sema_ctx);
    defer borrow_checker.deinit();
    try borrow_checker.check(ast);
    if (reporter.hasErrors()) return null;

    // ── Pass 8: Error Propagation ──────────────────────────
    var prop_checker = propagation.PropagationChecker.init(allocator, &sema_ctx);
    try prop_checker.check(&conv.store, ast_root);
    if (reporter.hasErrors()) return null;

    // ── Pass 9 (new): MIR Builder — fused annotation + lowering into MirStore ──
    // MirBuilder is now the authoritative MIR producer (B9). The old
    // MirAnnotator + MirLowerer below remain as codegen compatibility shims
    // until Phase C migrates codegen to read MirStore directly (B10).
    var mir_store = mir_store_mod.MirStore.init();
    defer mir_store.deinit(allocator);
    var mir_builder = mir_builder_mod.MirBuilder.init(
        allocator,
        reporter,
        &decl_collector.table,
        &type_resolver.ast_type_map,
        &conv.store,
        &mir_store,
        union_registry,
    );
    defer mir_builder.deinit();
    mir_builder.current_module_name = mod_name;
    const mir_root_idx_val = try mir_builder.build(ast_root);
    if (reporter.hasErrors()) return null;

    // ── Pass 10 (compat): Zig Code Generation ─────────────────
    const is_debug = cli.optimize == .debug;
    var cg = codegen.CodeGen.init(allocator, reporter, is_debug);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.all_decls = all_module_decls;
    cg.locs = locs_ptr;
    cg.file_offsets = file_offsets;
    cg.module_builds = module_builds;
    cg.union_registry = union_registry;
    cg.current_module_name = mod_name;
    cg.is_zig_module = is_zig_module;
    cg.has_zig_sidecar = has_zig_sidecar;
    cg.mir_store = &mir_store;
    cg.mir_root_idx = mir_root_idx_val;
    cg.mir_type_store = &mir_store.types;
    cg.ast_reverse_map = &conv.reverse_map;

    try cg.generate(ast, mod_name);
    if (reporter.hasErrors()) return null;

    // Write generated .zig file to cache
    try cache.writeGeneratedZig(mod_name, cg.getOutput(), allocator);

    return cg.getOutput();
}
