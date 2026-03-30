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

    var lex = lexer.Lexer.init("module main\n");
    var tokens = try lex.tokenize(alloc);
    defer tokens.deinit(alloc);

    const valid = try validate(tokens.items, alloc);
    try std.testing.expect(valid);
}

test "peg - validate real program with function" {
    const alloc = std.testing.allocator;

    var lex = lexer.Lexer.init(
        \\module main
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
        \\module main
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
        \\module main
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
        \\module main
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
        \\module main
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
        \\module main
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
        \\        return Counter(count: start)
        \\    }
        \\
        \\    pub func get(self: const &Counter) i32 {
        \\        return self.count
        \\    }
        \\
        \\    pub func increment(self: &Counter) void {
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
        \\module main
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
        \\module main
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
test "peg - validate templates/main.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("templates/main.orh"), alloc);
    try std.testing.expect(valid);
}

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

// Stdlib bridge files (must all pass)
test "peg - validate std/console.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/console.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/collections.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/collections.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/math.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/math.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/str.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/str.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/fs.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/fs.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/json.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/json.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/system.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/system.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/time.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/time.orh"), alloc);
    try std.testing.expect(valid);
}

test "peg - validate std/async.orh" {
    const alloc = std.testing.allocator;
    const valid = try validateSource(@embedFile("std/async.orh"), alloc);
    try std.testing.expect(valid);
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
