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
const thread_safety = @import("thread_safety.zig");
const propagation = @import("propagation.zig");
const sema = @import("sema.zig");
const mir = @import("mir/mir.zig");
const codegen = @import("codegen/codegen.zig");
const zig_runner = @import("zig_runner/zig_runner.zig");
const errors = @import("errors.zig");
const cache = @import("cache.zig");
const builtins = @import("builtins.zig");
const peg = @import("peg.zig");

/// Split a #cimport `name` field value on commas, trim whitespace from each segment,
/// and append non-empty segments to `out`. Supports both single and multi-library names.
/// Segments are slices into `name` — no allocation is performed.
/// Example: "vulkan, SDL3" → ["vulkan", "SDL3"]
pub fn splitCimportLibNames(
    allocator: std.mem.Allocator,
    name: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var it = std.mem.splitScalar(u8, name, ',');
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t");
        if (trimmed.len > 0) try out.append(allocator, trimmed);
    }
}

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
    try decl_collector.collect(ast);
    // Type resolution
    const sema_ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = reporter,
        .decls = &decl_collector.table,
        .locs = null,
        .file_offsets = &.{},
    };
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);
    // Codegen with full MIR context
    var cg = codegen.CodeGen.init(alloc, reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
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
    try decl_collector.collect(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Shared context for type resolution + validation passes
    const sema_ctx = sema.SemanticContext{
        .allocator = alloc,
        .reporter = &reporter,
        .decls = &decl_collector.table,
        .locs = null,
        .file_offsets = &.{},
    };

    // Type resolution
    var type_resolver = resolver.TypeResolver.init(&sema_ctx);
    defer type_resolver.deinit();
    try type_resolver.resolve(ast);
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

    // Thread safety
    var thread_checker = thread_safety.ThreadSafetyChecker.init(alloc, &sema_ctx);
    defer thread_checker.deinit();
    try thread_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // Propagation
    var prop_checker = propagation.PropagationChecker.init(alloc, &sema_ctx);
    try prop_checker.check(ast);
    try std.testing.expect(!reporter.hasErrors());

    // MIR annotation + lowering
    var mir_annotator = mir.MirAnnotator.init(alloc, &reporter, &decl_collector.table, &type_resolver.type_map);
    defer mir_annotator.deinit();
    try mir_annotator.annotate(ast);
    try std.testing.expect(!reporter.hasErrors());
    var mir_lowerer = mir.MirLowerer.init(alloc, &mir_annotator.node_map, &mir_annotator.union_registry, &decl_collector.table, &mir_annotator.var_types);
    defer mir_lowerer.deinit();
    const mir_root = try mir_lowerer.lower(ast);

    // Codegen
    var cg = codegen.CodeGen.init(alloc, &reporter, true);
    defer cg.deinit();
    cg.decls = &decl_collector.table;
    cg.node_map = &mir_annotator.node_map;
    cg.union_registry = &mir_annotator.union_registry;
    cg.var_types = &mir_annotator.var_types;
    cg.mir_root = mir_root;
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

test "codegen - struct with method" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
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
        \\module testmod
        \\enum(u8) Color {
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

test "codegen - bitfield declaration" {
    const alloc = std.testing.allocator;
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    const out = try codegenSource(alloc,
        \\module testmod
        \\bitfield(u8) Perms {
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

test "splitCimportLibNames - single name" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "SDL3", &result);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("SDL3", result.items[0]);
}

test "splitCimportLibNames - two names with space" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "vulkan, SDL3", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - two names no spaces" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "vulkan,SDL3", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - extra whitespace" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, " vulkan , SDL3 ", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("vulkan", result.items[0]);
    try std.testing.expectEqualStrings("SDL3", result.items[1]);
}

test "splitCimportLibNames - empty segments skipped" {
    const alloc = std.testing.allocator;
    var result = std.ArrayListUnmanaged([]const u8){};
    defer result.deinit(alloc);
    try splitCimportLibNames(alloc, "a,,b", &result);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("a", result.items[0]);
    try std.testing.expectEqualStrings("b", result.items[1]);
}
