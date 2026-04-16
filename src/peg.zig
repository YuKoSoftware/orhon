// peg.zig — PEG grammar engine public API
//
// Parses the embedded orhon.peg grammar file and provides a
// token-level packrat matching engine for Orhon source files.

const std = @import("std");
const grammar_mod = @import("peg/grammar.zig");
const engine_mod = @import("peg/engine.zig");
const lexer = @import("lexer.zig");

const capture_mod = @import("peg/capture.zig");
const builder_mod = @import("peg/builder.zig");

pub const Grammar = grammar_mod.Grammar;
pub const Expr = grammar_mod.Expr;
pub const Engine = engine_mod.Engine;
pub const MatchResult = engine_mod.MatchResult;
pub const ParseError = engine_mod.ParseError;
pub const CaptureEngine = capture_mod.CaptureEngine;
pub const CaptureNode = capture_mod.CaptureNode;
pub const BuildContext = builder_mod.BuildContext;
pub const BuildResult = builder_mod.BuildResult;
pub const buildAST = builder_mod.buildAST;
pub const buildASTWithArena = builder_mod.buildASTWithArena;
pub const parseGrammar = grammar_mod.parseGrammar;

/// The embedded Orhon PEG grammar source
pub const GRAMMAR_SOURCE = @embedFile("peg/orhon.peg");

/// Load the Orhon grammar from the embedded .peg file.
pub fn loadGrammar(allocator: std.mem.Allocator) !Grammar {
    return parseGrammar(GRAMMAR_SOURCE, allocator);
}

/// Convenience: check if a token stream matches the Orhon grammar.
/// Returns true if the tokens form a valid Orhon program.
pub fn validate(tokens: []const lexer.Token, allocator: std.mem.Allocator) !bool {
    var g = try loadGrammar(allocator);
    defer g.deinit();

    var eng = Engine.init(&g, tokens, allocator);
    defer eng.deinit();

    return eng.matchAll("program");
}

// ============================================================
// TESTS
// ============================================================

test "peg - load embedded grammar" {
    const alloc = std.testing.allocator;
    var g = try loadGrammar(alloc);
    defer g.deinit();

    try std.testing.expect(g.getRule("program") != null);
    try std.testing.expect(g.getRule("func_decl") != null);
    try std.testing.expect(g.rule_names.len >= 50);
}

test "peg - validate minimal program" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init("module myapp\n");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate real program with function" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with struct" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module example
        \\
        \\pub struct Point {
        \\    pub x: f64
        \\    pub y: f64
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with imports and metadata" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\#name = "hello"
        \\#build = exe
        \\
        \\import std::console
        \\
        \\func main() void {
        \\    console.println("hello")
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with control flow" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func abs(x: i32) i32 {
        \\    if(x < 0) {
        \\        return 0 - x
        \\    }
        \\    return x
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with enum" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module example
        \\
        \\pub enum(u8) Direction {
        \\    North
        \\    South
        \\    East
        \\    West
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with while and for" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func sum(n: i32) i32 {
        \\    var total: i32 = 0
        \\    var i: i32 = 0
        \\    while(i < n) : (i += 1) {
        \\        total += i
        \\    }
        \\    return total
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with match" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func classify(n: i32) i32 {
        \\    match(n) {
        \\        0 => { return 0 }
        \\        1 => { return 10 }
        \\        else => { return 99 }
        \\    }
        \\    return 0
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with error union" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func safe_divide(a: i32, b: i32) (Error | i32) {
        \\    if(b == 0) {
        \\        return Error("division by zero")
        \\    }
        \\    return a / b
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with struct methods" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module example
        \\
        \\pub struct Counter {
        \\    pub count: i32
        \\
        \\    pub func create(start: i32) Counter {
        \\        return Counter{count: start}
        \\    }
        \\
        \\    pub func get(self: const& Counter) i32 {
        \\        return self.count
        \\    }
        \\
        \\    pub func increment(self: mut& Counter) void {
        \\        self.count = self.count + 1
        \\    }
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with test decl" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module example
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
        \\test "add works" {
        \\    assert(add(2, 3) == 5)
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with defer" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func example() i32 {
        \\    var x: i32 = 0
        \\    defer {
        \\        x = 0
        \\    }
        \\    x = 42
        \\    return x
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate program with elif" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func sign(n: i32) i32 {
        \\    if(n > 0) {
        \\        return 1
        \\    } elif(n < 0) {
        \\        return 0 - 1
        \\    } else {
        \\        return 0
        \\    }
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

// ============================================================
// FILE-BASED VALIDATION — test against real .orh files
// ============================================================

fn validateSource(source: []const u8, alloc: std.mem.Allocator) !bool {
    var lex = lexer.Lexer.init(source);
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);
    return validate(tokens.items, alloc);
}

// Template files (must all pass)
// Note: project.orh is a template with {s} placeholders — not valid Orhon source,
// so it is not validated here. It is tested via orhon init integration tests.

test "peg - validate templates/example/example.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/example.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/data_types.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/data_types.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/control_flow.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/control_flow.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/strings.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/strings.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/advanced.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/advanced.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/error_handling.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/error_handling.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate templates/example/blueprints.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/example/blueprints.orh"), alloc);
    try std.testing.expect(valid);
}

// Test fixture files — read at runtime since they're outside src/
test "peg - validate test/fixtures/tester.orh" {
    const alloc = std.testing.allocator;
    const source = std.fs.cwd().readFileAlloc(alloc, "test/fixtures/tester.orh", 1024 * 1024) catch return;
    defer alloc.free(source);
    const valid = try validateSource(source, alloc);
    try std.testing.expect(valid);
}

test "peg - validate test/fixtures/tester_main.orh" {
    const alloc = std.testing.allocator;
    const source = std.fs.cwd().readFileAlloc(alloc, "test/fixtures/tester_main.orh", 1024 * 1024) catch return;
    defer alloc.free(source);
    const valid = try validateSource(source, alloc);
    try std.testing.expect(valid);
}

// Stdlib .orh files are now auto-generated from .zig at build time —
// validated at runtime by the pipeline, not at compile time by embed tests.

// Pure Orhon stdlib files (no .zig backing)
test "peg - validate std/linear.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/linear.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - error recovery: malformed func_decl does not abort parse" {
    // CB6: first PEG mismatch should not abort the pipeline.
    // A malformed func_decl (missing comma between params) is followed by a
    // valid func_decl.  captureProgram must succeed and the second declaration
    // must appear in the resulting AST.
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module foo
        \\
        \\func bad(a: i32 b: i32) i32 {
        \\    return a
        \\}
        \\
        \\func good(x: i32) i32 {
        \\    return x
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var g = try loadGrammar(alloc);
    defer g.deinit();

    var engine = CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();

    // Must NOT return null — error recovery should kick in
    const cap = engine.captureProgram();
    try std.testing.expect(cap != null);

    // Build AST — the builder should surface a syntax error for the bad decl
    const result = try buildAST(&cap.?, tokens.items, alloc);
    var ctx = result.ctx;
    defer ctx.deinit();

    // At least one syntax error from the skipped bad declaration
    try std.testing.expect(ctx.syntax_errors.items.len >= 1);

    // The valid func_decl must still be in the AST
    const prog = result.node.program;
    var found_good = false;
    for (prog.top_level) |decl| {
        if (decl.* == .func_decl and std.mem.eql(u8, decl.func_decl.name, "good")) {
            found_good = true;
        }
    }
    try std.testing.expect(found_good);
}

test "peg - error recovery: bad statement in block does not abort parse" {
    // CB6: a malformed statement inside a func body is skipped;
    // subsequent statements in the same block are still captured.
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module foo
        \\
        \\func demo() void {
        \\    if x > 0 {
        \\        return void
        \\    }
        \\    return void
        \\}
        \\
    );
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    var g = try loadGrammar(alloc);
    defer g.deinit();

    var engine = CaptureEngine.init(&g, tokens.items, std.heap.page_allocator);
    defer engine.deinit();

    // Must NOT return null
    const cap = engine.captureProgram();
    try std.testing.expect(cap != null);

    const result = try buildAST(&cap.?, tokens.items, alloc);
    var ctx = result.ctx;
    defer ctx.deinit();

    // At least one syntax error for the bad if statement
    try std.testing.expect(ctx.syntax_errors.items.len >= 1);

    // The `return void` statement after the broken `if` must still be captured —
    // this verifies forward progress (recovery resumed parsing, not just non-abort).
    const func = result.node.program.top_level[0];
    try std.testing.expect(func.* == .func_decl);
    try std.testing.expect(func.func_decl.body.block.statements.len >= 1);
}

test "fuzz parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) !void {
            const alloc = std.testing.allocator;
            var lex = lexer.Lexer.init(input);
            var tokens = lex.tokenize(alloc) catch return;
            defer tokens.deinit(alloc);
            if (tokens.items.len == 0) return;
            var g = loadGrammar(alloc) catch return;
            defer g.deinit();
            var eng = Engine.init(&g, tokens.items, alloc);
            defer eng.deinit();
            _ = eng.matchAll("program");
        }
    }.run, .{});
}

// Re-export sub-module tests
test {
    _ = @import("peg/grammar.zig");
    _ = @import("peg/engine.zig");
    _ = @import("peg/token_map.zig");
    _ = @import("peg/capture.zig");
    _ = @import("peg/builder.zig");
}
