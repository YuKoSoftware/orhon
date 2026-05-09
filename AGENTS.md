# AGENTS.md — OpenCode Agent Instructions

Orhon is a compiled, memory-safe language transpiled to Zig. The compiler is written in
Zig 0.15.2+. Source lives under `src/` (~100 files, ~40K lines).

## Quick commands

```bash
./testall.sh                # full suite (13 stages), output → test_log.txt
bash test/03_cli.sh         # run a single test stage
zig build                   # debug build
zig build -Doptimize=ReleaseFast  # release build
zig build test              # Zig unit tests only (embedded test blocks)
zig build test-diag         # negative-test fixture runner
zig build run -- <args>     # run the compiler
```

**Always read `test_log.txt`** after `./testall.sh` before claiming success — summary
counts can hide individual failures. Stages 01 (unit) and 02 (build) are critical and
cause `testall.sh` to abort early if they fail.

Stages and what they cover:

| Stage | What it tests |
|-------|---------------|
| `01_unit.sh`       | `zig build test` |
| `02_build.sh`      | compiler compiles |
| `03_cli.sh`        | CLI args, help, error exits |
| `04_init.sh`       | `orhon init` + embedded std |
| `05_compile.sh`    | build/run/test/debug, incremental cache |
| `06_library.sh`    | static + dynamic library |
| `07_multimodule.sh`| multi-module projects |
| `08_codegen.sh`    | generated Zig quality |
| `09_language.sh`   | language features (example + tester) |
| `10_runtime.sh`    | runtime correctness (binary output) |
| `11_errors.sh`     | negative tests (expected failures) |
| `12_golden.sh`     | `.ast.golden` / `.mir.golden` snapshots |
| `13_perf.sh`       | perf benchmarks (NOT in `testall.sh` — run separately) |
| `14_props.sh`      | `zig ast-check` + fmt idempotence per fixture |

Test fixtures live under `test/fixtures/`:
- `test/fixtures/golden/` — `.ast.golden` + `.mir.golden` per language feature
- `test/fixtures/parse/`, `borrow/`, `runtime/`, `codegen/` — negative tests
- `test/fixtures/runtime/` — positive runtime tests (tester.orh + tester_main.orh)

## Architecture

### Hub + satellite pattern

Every large subsystem is a hub file importing satellites (NOT the other way around):

| Hub | Satellites |
|-----|-----------|
| `src/peg/builder.zig` | `builder_decls.zig`, `builder_stmts.zig`, `builder_exprs.zig`, `builder_types.zig` |
| `src/mir_builder.zig` | `mir_builder_decls.zig`, `mir_builder_stmts.zig`, `mir_builder_exprs.zig`, `mir_builder_types.zig`, `mir_builder_members.zig` |
| `src/codegen/codegen.zig` | `codegen_decls.zig`, `codegen_stmts.zig`, `codegen_exprs.zig`, `codegen_match.zig`, `codegen_unions.zig` |
| `src/resolver.zig` | `resolver_exprs.zig`, `resolver_stmts.zig`, `resolver_validation.zig` |

**Bidirectional imports exist** — satellites `@import("builder.zig")` to call helpers
like `buildNode`. This is intentional. Do not "fix" circular imports.

### PEG grammar is the single source of truth for syntax

`src/peg/orhon.peg` defines all syntax. The capture engine (`capture.zig`) produces a
capture tree by matching the grammar against tokens. The builder (`builder.zig` +
satellites) transforms capture trees into AST nodes via a comptime dispatch table:

```zig
// src/peg/builder.zig — rule_dispatch maps rule names → builder functions
const rule_dispatch = std.StaticStringMap(BuilderFn).initComptime(.{ ... });
```

To add syntax: (1) grammar rule in `orhon.peg`, (2) builder function in the relevant
satellite, (3) entry in `rule_dispatch`. The engine handles matching automatically.
**Never invent Orhon syntax** — check `orhon.peg` for what actually exists.

### Index-based SoA storage (not pointer trees)

- **AST**: `src/ast_store.zig` + `src/ast_typed.zig` (typed wrappers per `AstKind`)
- **MIR**: `src/mir_store.zig` + `src/mir_typed.zig`
- Both use the Zig/Carbon index-based struct-of-arrays pattern
- Old pointer-based `parser.Node` still exists as a legacy type but is no longer primary

### Compilation pipeline

Three pipeline stages in `src/pipeline.zig` (lexer, parser, module resolution) followed by 7 compilation passes in `src/pipeline_passes.zig` (passes 4–10). Each runs only if the previous succeeded:

1. Lexer → tokens
2. PEG parser → capture tree → `AstStore`
3. Module resolution + dependency graph + incremental cache check
4. Declaration collection (type names, signatures — no bodies yet)
5. Compt & type resolution (interleaved, body type-checking)
6. Ownership & move analysis
7. Borrow checking (NLL-based)
8. Error propagation analysis
9. MIR builder (fused: classify → coerce → lower into `MirStore`)
10. Zig codegen (`MirStore` → Zig source text)
→ Zig compiler invocation → final binary

See `docs/COMPILER.md` for the full pipeline architecture.

## Zig coding gotchas

### Recursive functions need `anyerror!`
```zig
fn parseExpr(self: *Parser) anyerror!*Node { ... }  // CORRECT
fn parseExpr(self: *Parser) !*Node { ... }           // WRONG — compile error
```
Zig's inferred error sets fail on recursion. Use `anyerror` when a function calls itself.

### All numeric literals are `.int_literal`
Hex (`0xFF`), binary (`0b1010`), octal (`0o77`), decimal (`42`) all fold to
`.int_literal` in the lexer. No `.hex_literal` etc. exists.

### Union tag comparison in tests
```zig
try std.testing.expect(node.* == .var_decl);              // CORRECT
try std.testing.expectEqual(NodeKind.var_decl, node.*);   // WRONG
```
Use `== .variant_name` on the tagged union value directly.

### Zig multiline strings use `\\` not `\`
```zig
try file.writeAll(
    \\.gitignore
    \\zig-out/
);
```

### `@embedFile` for complete files, never inline
Never inline multi-line file content in `.zig` source. Use `@embedFile`. Paths are
relative to the source file using it.

## Conventions

### Reporter message ownership (easy to get wrong)

- **`reportFmt`/`warnFmt`/`noteFmt`** — preferred for formatted messages. Single allocation, no double-alloc.
- **`report`/`warn`/`note`** — safe for string literals and borrowed slices (dupes internally).
- **`reportOwned`** — for pre-allocated heap strings. **Never `defer free`** — the reporter takes ownership. Message must be allocated with `reporter.allocator`.

```zig
// PREFERRED: format in one step
_ = try reporter.reportFmt(.my_code, loc, "error: '{s}'", .{name});

// OK for static strings
_ = try reporter.report(.{ .code = .my_code, .message = "static error" });

// Pre-allocated message — no defer free
const msg = try std.fmt.allocPrint(reporter.allocator, "error: '{s}'", .{name});
_ = try reporter.reportOwned(.{ .code = .my_code, .message = msg });
```

### Error codes are mandatory

All diagnostics use error codes from `src/error_codes.zig` (`ErrorCode enum(u16)`).
The error code is always the **first argument** to `reportFmt`/`warnFmt`/`noteFmt`:
```zig
reporter.reportFmt(.parse_failure, loc, "message", .{});
```

### Template substitution: split-write, never allocPrint

`.orh` template files contain `{` and `}` everywhere. Never pass template content
through `allocPrint` — it interprets braces as format specifiers. Split on the
placeholder and write in parts instead.

### Builder Context ownership

`BuildContext` in `src/peg/builder.zig` has two init paths:
- `init()` — arena is owned, caller must `deinit()`
- `initWithArena()` — arena is borrowed, caller owns it

### Capture engine lifetime

`CaptureEngine.deinit()` frees the arena backing all captures. Captures are valid
only until `deinit()`. The AST builder copies what it needs into its own arena.

### String interpolation in the builder

Lexer token types for interpolated strings: `string_interp_start`, `string_part`,
`string_interp_end`. The grammar rule:
```
string_literal <- STRING_LITERAL / STRING_INTERP_START interp_segment* STRING_INTERP_END
interp_segment <- STRING_PART / expr
```
In `buildStringLiteral`, detect interpolation by checking if the first token is
`.string_interp_start`, then walk the capture tree's `interp_segment` children.
Each segment has an `expr` child (→ call `builder.buildNode` on it) or is a
`STRING_PART` literal (→ extract token text).

### Zero magic rule

No hardcoded recognition of stdlib types or functions. `std::collections.List` and a
user-defined `MyList` must go through identical resolution paths. Only
**compiler functions** (`@cast`, `@copy`, `@move`, etc.) and **language-level
constructs** (match desugaring, string interpolation, operators) get codegen awareness.

## Workflow

### Before editing

- Always read the file first — the full relevant section, not just a few lines
- Read `docs/COMPILER.md` before touching compiler pipeline code
- Read the relevant language spec doc before changing language behavior
- Never guess Zig stdlib APIs — verify the function exists in this project or
  in Zig 0.15.2 docs before using it
- Never assume a function signature — read the source file

### While editing

- Keep changes minimal — don't refactor surrounding code unless asked
- Match existing patterns: naming, error handling style, struct organization
- Never add features, abstractions, or "improvements" beyond what was requested
- When adding to codegen, follow the split-file pattern in `src/codegen/`
- Follow the hub+satellite pattern when splitting large files

### After editing

- After changes to `.zig` files: run `zig build` to check compilation
- After language feature changes: run the relevant test stage (e.g. `bash test/09_language.sh`)
- After broad changes: run `./testall.sh`
- **Always read `test_log.txt`** after `./testall.sh` before claiming success
- Never claim "this should work" — verify it

### Adding new functionality

- Tests live in the same file as the code (Zig `test` blocks), 1-2 focused tests per feature
- New example files in `src/templates/example/*.orh` need a corresponding `@embedFile`
  and write logic in `src/init.zig`
- Example module files must use `module example`, cover every implemented feature,
  and compile successfully (they're part of `orhon build`'s test suite)

### Test runner specifics

- `zig build test-diag` runs `test/runner.zig` which compiles `fail_*.orh` fixtures,
  captures JSON diagnostics, and matches `//> [Exxxx]` inline annotations
- Golden fixtures in `test/fixtures/golden/` have `.ast.golden` and `.mir.golden`
  sidecars checked by `test/12_golden.sh` — update when AST/MIR output changes
- Perf tests (`test/13_perf.sh`) are **not** in `testall.sh` — run separately

## Where to look

| Need | Read |
|------|------|
| Compiler architecture | `docs/COMPILER.md` |
| Language spec | `docs/01-basics.md` through `docs/15-testing.md` |
| Task priorities + bugs | `docs/TODO.md` |
| Future ideas | `docs/future.md` |
| PEG grammar (syntax) | `src/peg/orhon.peg` |
| Error codes | `src/error_codes.zig` |
| Build config | `build.zig`, `build.zig.zon` |
