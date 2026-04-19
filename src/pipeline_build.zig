// pipeline_build.zig — Build helpers and tests for the compilation pipeline
// Satellite of pipeline.zig.

const std = @import("std");
const lexer = @import("lexer.zig");
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
const zig_runner = @import("zig_runner/zig_runner.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");
const peg = @import("peg.zig");
const ast_conv = @import("ast_conv.zig");
const mir_store_mod = @import("mir_store.zig");
const mir_builder_mod = @import("mir_builder.zig");

/// Full pipeline test helper: source → lex → parse → declarations → resolve → MIR → codegen → Zig.
/// Returns owned output slice — caller must free.
pub fn codegenSource(alloc: std.mem.Allocator, source: []const u8, reporter: *errors.Reporter) ![]const u8 {
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    var grammar = try peg.loadGrammar(alloc);
    defer grammar.deinit();
    var cap_engine = peg.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
    defer cap_engine.deinit();
    const cap = cap_engine.captureProgram() orelse return error.ParseError;
    var build_result = try peg.buildAST(&cap, tokens.items, alloc);
    defer build_result.ctx.deinit();
    const ast = build_result.node;
    var decl_collector = declarations.DeclCollector.init(alloc, reporter);
    defer decl_collector.deinit();
    // Convert AST to AstStore for index-based passes (Phase A)
    var conv = ast_conv.ConvContext.init(alloc);
    defer conv.deinit();
    const ast_root = try ast_conv.convertNode(&conv, ast);
    try decl_collector.collect(&conv.store, ast_root, &conv.reverse_map);
    // Type resolution
    var sema_ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = reporter,
        .decls = &decl_collector.table,
        .locs = null,
        .file_offsets = &.{},
        .ast = &conv.store,
        .reverse_map = &conv.reverse_map,
    };
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();
    try type_resolver.resolve(&conv.store, ast_root);
    // MIR builder
    var union_registry = mir.UnionRegistry.init(alloc);
    defer union_registry.deinit();
    var mir_store = mir_store_mod.MirStore.init();
    defer mir_store.deinit(alloc);
    var mir_builder = mir_builder_mod.MirBuilder.init(
        alloc,
        reporter,
        &decl_collector.table,
        &type_resolver.ast_type_map,
        &conv.store,
        &mir_store,
        &union_registry,
    );
    defer mir_builder.deinit();
    mir_builder.current_module_name = "testmod";
    const mir_root_idx = try mir_builder.build(ast_root);
    // Codegen
    var cg = codegen.CodeGen.init(alloc, reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.union_registry = &union_registry;
    cg.current_module_name = "testmod";
    cg.mir_store = &mir_store;
    cg.mir_root_idx = mir_root_idx;
    cg.mir_type_store = &mir_store.types;
    cg.ast_reverse_map = &conv.reverse_map;
    try cg.generate(ast, "testmod");
    return try alloc.dupe(u8, cg.getOutput());
}

test "pipeline - imports all passes" {
    // Verify all pipeline modules are importable
    _ = lexer;
    _ = parser;
    _ = module;
    _ = declarations;
    _ = resolver;
    _ = ownership;
    _ = borrow;
    _ = propagation;
    _ = mir;
    _ = codegen;
    _ = zig_runner;
    _ = errors;
    _ = cache;
    _ = builtins;
    try std.testing.expect(true);
}

test "full pipeline - hello world" {
    const alloc = std.testing.allocator;

    const source =
        \\module testmod
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

    // Parse (PEG engine)
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();

    var grammar = try peg.loadGrammar(alloc);
    defer grammar.deinit();
    var cap_engine = peg.CaptureEngine.init(&grammar, tokens.items, std.heap.page_allocator);
    defer cap_engine.deinit();
    const cap = cap_engine.captureProgram() orelse return error.ParseError;
    var build_result = try peg.buildAST(&cap, tokens.items, alloc);
    defer build_result.ctx.deinit();
    const ast = build_result.node;
    try std.testing.expect(!reporter.hasErrors());

    // Declaration pass
    var decl_collector = declarations.DeclCollector.init(alloc, &reporter);
    defer decl_collector.deinit();
    // Convert AST to AstStore for index-based passes (Phase A)
    var conv = ast_conv.ConvContext.init(alloc);
    defer conv.deinit();
    const ast_root = try ast_conv.convertNode(&conv, ast);
    try decl_collector.collect(&conv.store, ast_root, &conv.reverse_map);
    try std.testing.expect(!reporter.hasErrors());

    // Shared context for type resolution + validation passes
    var sema_ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &decl_collector.table,
        .locs = null,
        .file_offsets = &.{},
        .ast = &conv.store,
        .reverse_map = &conv.reverse_map,
    };

    // Type resolution
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();
    try type_resolver.resolve(&conv.store, ast_root);
    try std.testing.expect(!reporter.hasErrors());

    // Ownership check
    var ownership_checker = ownership.OwnershipChecker.init(alloc, &sema_ctx);
    try ownership_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Borrow check
    var borrow_checker = borrow.BorrowChecker.init(alloc, &sema_ctx);
    defer borrow_checker.deinit();
    try borrow_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Propagation
    var prop_checker = propagation.PropagationChecker.init(alloc, &sema_ctx);
    try prop_checker.check(&conv.store, ast_root);
    try std.testing.expect(!reporter.hasErrors());

    // MIR builder
    var union_registry2 = mir.UnionRegistry.init(alloc);
    defer union_registry2.deinit();
    var mir_store2 = mir_store_mod.MirStore.init();
    defer mir_store2.deinit(alloc);
    var mir_builder2 = mir_builder_mod.MirBuilder.init(
        alloc,
        &reporter,
        &decl_collector.table,
        &type_resolver.ast_type_map,
        &conv.store,
        &mir_store2,
        &union_registry2,
    );
    defer mir_builder2.deinit();
    mir_builder2.current_module_name = "testmod";
    const mir_root_idx2 = try mir_builder2.build(ast_root);
    // Codegen
    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.union_registry = &union_registry2;
    cg.current_module_name = "testmod";
    cg.mir_store = &mir_store2;
    cg.mir_root_idx = mir_root_idx2;
    cg.mir_type_store = &mir_store2.types;
    cg.ast_reverse_map = &conv.reverse_map;
    try cg.generate(ast, "testmod");
    try std.testing.expect(!reporter.hasErrors());

    const output = cg.getOutput();
    try std.testing.expect(output.len > 0);

    // Verify the generated Zig output contains the expected structure
    try std.testing.expect(std.mem.indexOf(u8, output, "// generated from module testmod") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const std = @import(\"std\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x: i32 = 42;") != null);
}

test "codegen - var never reassigned becomes const" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const output = try codegenSource(alloc,
        \\module testmod
        \\
        \\func main() void {
        \\    var a: i32 = 1
        \\    var b: i32 = 2
        \\    b = 3
        \\}
        \\
    , &reporter);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "const a: i32 = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var b: i32 = 2;") != null);
}

test "codegen - struct declaration" {
    // Tests struct declaration codegen via MirStore path (B10).
    // Struct/enum body emission via old MirNode bridge is a pending gap;
    // only the struct header is checked here.
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\pub struct Vec2 {
        \\    pub x: f32
        \\    pub y: f32
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Vec2 = struct {") != null);
}

test "codegen - enum declaration" {
    // Tests enum declaration codegen via MirStore path (B10).
    // Enum variant emission via old MirNode bridge is a pending gap;
    // only the enum header is checked here.
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\enum(u8) Color {
        \\    Red
        \\    Green
        \\    Blue
        \\}
        \\
    , &reporter);
    defer alloc.free(out);
    try std.testing.expect(!reporter.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, out, "const Color = enum") != null);
}


