// fuzz.zig — standalone fuzz harness for lexer + parser
// Run: zig build fuzz

const std = @import("std");
const lexer = @import("lexer.zig");
const peg_mod = @import("peg.zig");
const errors = @import("errors.zig");

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rand = prng.random();

    const iterations: usize = 50_000;
    var passed: usize = 0;
    var lex_only: usize = 0;
    var parse_ok: usize = 0;
    var parse_err: usize = 0;

    var stderr_buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writer(&stderr_buf);
    const out = &w.interface;

    for (0..iterations) |i| {
        const len = rand.intRangeAtMost(usize, 0, 1024);
        const buf = try alloc.alloc(u8, len);
        defer alloc.free(buf);

        const strategy = rand.intRangeAtMost(u8, 0, 4);
        switch (strategy) {
            0 => rand.bytes(buf),
            1 => {
                const cs = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-*/%=!<>&|^~(){}[].,;:@#\"' \t\n_";
                for (buf) |*b| b.* = cs[rand.intRangeAtMost(usize, 0, cs.len - 1)];
            },
            2 => {
                const parts = [_][]const u8{
                    "module", "func", "var", "const", "return", "if", "else",
                    "while", "for", "match", "struct", "enum", "import", "pub",
                    "compt", "thread", "defer", "break", "continue", "test",
                    "true", "false", "null", "and", "or", "not", "is", "in",
                    "void", "i32", "f64", "str", "Error", "bool",
                    "(", ")", "{", "}", "[", "]", ":", "::", ",", ".",
                    "+", "-", "*", "/", "%", "++", "=", "==", "!=",
                    "<", ">", "<=", ">=", "&", "|", "^", "!", ">>", "<<",
                    "..", "=>", "->", "0", "42", "3.14", "\"hi\"", "\n", " ",
                    "/*", "*/", "//", "0x", "0b", "0o", "#", "@",
                };
                var pos: usize = 0;
                while (pos < buf.len) {
                    const part = parts[rand.intRangeAtMost(usize, 0, parts.len - 1)];
                    const n = @min(part.len, buf.len - pos);
                    @memcpy(buf[pos..][0..n], part[0..n]);
                    pos += n;
                }
            },
            3 => {
                const prefix = "module test\n";
                const n = @min(prefix.len, buf.len);
                @memcpy(buf[0..n], prefix[0..n]);
                if (buf.len > n) {
                    const cs = "abcdefghijklmnopqrstuvwxyz (){}=:+\n0123456789";
                    for (buf[n..]) |*b| b.* = cs[rand.intRangeAtMost(usize, 0, cs.len - 1)];
                }
            },
            4 => {
                // Semi-valid Orhon program structures — exercises deeper parser paths
                const templates = [_][]const u8{
                    "module fuzztest\nfunc main() void {\n",
                    "module fuzztest\npub struct Foo {\n    pub x: i32\n}\n",
                    "module fuzztest\npub enum(u8) Bar {\n    A\n    B\n}\n",
                    "module fuzztest\nconst X: i32 = 42\n",
                    "module fuzztest\nfunc add(a: i32, b: i32) i32 {\n    return a + b\n}\n",
                    "module fuzztest\nimport std::console\nfunc main() void {\n",
                    "module fuzztest\nvar x: i32 = 0\nfunc f() void {\n    if(x > 0) {\n",
                };
                const tmpl = templates[rand.intRangeAtMost(usize, 0, templates.len - 1)];
                const n = @min(tmpl.len, buf.len);
                @memcpy(buf[0..n], tmpl[0..n]);
                if (buf.len > n) {
                    const cs = "abcdefghijklmnopqrstuvwxyz (){}=:+\n0123456789.,_!<>|&";
                    for (buf[n..]) |*b| b.* = cs[rand.intRangeAtMost(usize, 0, cs.len - 1)];
                }
            },
            else => unreachable,
        }

        // Lex
        var lex = lexer.Lexer.init(buf);
        var tokens = lex.tokenize(alloc) catch {
            lex_only += 1;
            passed += 1;
            continue;
        };
        defer tokens.deinit(alloc);

        if (tokens.items.len == 0 or tokens.items[tokens.items.len - 1].kind != .eof) {
            try out.print("BUG at iteration {d}: no EOF token\n", .{i});
            return error.FuzzFailure;
        }

        // Parse (PEG engine)
        var reporter = errors.Reporter.init(alloc, .debug);
        defer reporter.deinit();

        var grammar = peg_mod.loadGrammar(alloc) catch {
            parse_err += 1;
            continue;
        };
        defer grammar.deinit();
        var engine = peg_mod.Engine.init(&grammar, tokens.items, alloc);
        defer engine.deinit();

        if (engine.matchAll("program")) {
            parse_ok += 1;
        } else {
            parse_err += 1;
        }
        passed += 1;

        if ((i + 1) % 20000 == 0) {
            std.debug.print("  [{d}/{d}] ok={d} err={d}\n", .{ i + 1, iterations, parse_ok, parse_err });
        }
    }

    std.debug.print("\n=== Fuzz Results ===\n", .{});
    std.debug.print("  iterations: {d}\n", .{iterations});
    std.debug.print("  passed:     {d}\n", .{passed});
    std.debug.print("  lex-only:   {d}\n", .{lex_only});
    std.debug.print("  parse ok:   {d}\n", .{parse_ok});
    std.debug.print("  parse err:  {d}\n", .{parse_err});
    std.debug.print("  crashes:    0\n", .{});
}
