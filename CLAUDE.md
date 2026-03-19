# Kodr — Claude Project Instructions

## What This Project Is
Kodr is a compiled, memory-safe programming language that transpiles to Zig.
Written in Zig 0.15.x. Lives entirely in `src/`.
One-sentence pitch: *"A simple yet powerful language that is safe."*

**Full language spec:** `README.md` — read it before making
any decisions about language behavior, syntax, or semantics. Do not rely on memory
or assumptions — check the blueprint.

---

## Project Structure

```
kodr/
    build.zig
    build.zig.zon
    kodr_technical_blueprint_025.md   — full language spec
    kodr_grammar.peg                  — formal grammar
    src/
        main.zig            — CLI + pipeline orchestration
        lexer.zig           — pass 1:  tokenizer
        parser.zig          — pass 2:  parser + AST types
        module.zig          — pass 3:  module resolution
        declarations.zig    — pass 4:  collect type names + signatures
        resolver.zig        — pass 5:  compt + type resolution
        ownership.zig       — pass 6:  ownership + move analysis
        borrow.zig          — pass 7:  borrow checking
        thread_safety.zig   — pass 8:  thread safety analysis
        propagation.zig     — pass 9:  error + null propagation
        mir.zig             — pass 10: MIR types + generation
        codegen.zig         — pass 11: Zig source generation
        zig_runner.zig      — pass 12: invoke Zig compiler
        types.zig           — shared: Kodr type system
        errors.zig          — shared: error formatting
        builtins.zig        — shared: builtin types + Zig equivalents
        cache.zig           — shared: incremental cache
        templates/
            main.kodr       — @embedFile, written by kodr init
            example.kodr    — @embedFile, language manual anchor (see below)
            *.kodr          — @embedFile, additional manual files (module example)
        std/
            alpha.kodr      — @embedFile, extracted by kodr initstd
```

---

## Compiler Pipeline (12 passes)

```
Source (.kodr)
    ↓  1. Lexer           — raw text → tokens
    ↓  2. Parser          — tokens → AST
    ↓  3. Module Res.     — group files, detect circular imports, check cache
    ↓  4. Declarations    — collect all type names + function signatures
    ↓  5. Type Resolution — resolve compt + generics (any → concrete types)
    ↓  6. Ownership       — track moves, catch use-after-move
    ↓  7. Borrow Check    — validate &T borrows, lexical lifetimes
    ↓  8. Thread Safety   — values moved into threads not used after spawn
    ↓  9. Propagation     — (Error|T) and (null|T) unions handled or propagated
    ↓ 10. MIR             — SSA-based intermediate representation
    ↓ 11. Codegen         — emit readable Zig source to .kodr-cache/generated/
    ↓ 12. Zig Compiler    — produce final binary to bin/<project_name>
```

Each pass runs only if the previous succeeded. First error stops compilation.
Passes 6–7 have basic implementations. Pass 8 is a stub. Pass 9 has DeclTable-backed
union detection. Pass 10 (MIR) is a skeleton stub.

---

## Compt (compile-time)

`compt` is the only compile-time keyword. It goes in front of declarations and
statements — never inline on arbitrary expressions. No `inline` keyword exists.

- `compt X: i32 = 1024` — compile-time variable
- `compt func hash() u64 { ... }` — compile-time function (entire body is comptime)
- `compt for(items) |item| { ... }` — compile-time loop unrolling

That's it. If you need a compile-time value inside a runtime function, extract it
into a `compt func` and call it. No sprinkling `compt` on random expressions.

---

## Module System Rules

- The compiler groups files by their `module` declaration, not by file name or folder
- Every module needs an **anchor file** — one file whose name matches the module
  (e.g., `math.kodr` for `module math`). Other files in the module can be named anything.
- Only the anchor file can contain build metadata (`main.build`, `main.name`,
  `main.version`, `main.bitsize`, etc.)
- Module names are globally unique within a project
- Modules without a `build` declaration are regular modules — compiled into whatever
  imports them. Modules that are never imported are dead code and skipped entirely.

### Build types
Every project root is `main.kodr` / `module main`. The build type is set via `main.build`:
- `build.exe` — executable (requires `func main()`)
- `build.static` — static library
- `build.dynamic` — dynamic/shared library

Metadata prefix = module name. `main.*` for the root, `math.*` for `module math`, etc.
Only the anchor file of each module can declare metadata.

### Multiple modules in one project
A project can contain additional library modules alongside the root module.
These are only built if they are actually imported (dead code elimination).
Folder structure is for the developer's convenience — the compiler only sees modules:
```
src/
    main.kodr              ← module main, build.exe (root)
    math/math.kodr         ← module math, build.static (anchor)
    math/vectors.kodr      ← module math (additional file)
    network/network.kodr   ← module network, build.dynamic (anchor)
```

---

## Build & Test

```bash
./test.sh               # full test suite: unit tests + build + integration tests
./build.sh              # debug build
./build.sh -release     # release build
./build.sh -x64         # cross-compile for x64
./build.sh -wasm        # WebAssembly
```

Always run `./test.sh` after changes. It runs: `zig build test` → `zig build` →
CLI tests → init/build/run tests → error handling → multi-module → generated Zig
quality → language feature verification via example module.

---

## Zig Version & References

Targets **Zig 0.15.2+**. Zig is installed globally — do not bundle a binary.

Zig has moved to Codeberg — not GitHub. Always use Codeberg for source and stdlib:
- https://codeberg.org/ziglang/zig
- https://ziglang.org/documentation/master/

---

## Key Zig Gotchas in This Codebase

### Recursive functions need `anyerror!`
```zig
fn parseExpr(self: *Parser) anyerror!*Node { ... }  // CORRECT
fn parseExpr(self: *Parser) !*Node { ... }           // WRONG
```

### All numeric literals are `.int_literal`
Hex, binary, octal, decimal all fold to `.int_literal`. No `.hex_literal` etc.

### Union tag comparison in tests
```zig
try std.testing.expect(node.* == .var_decl);         // CORRECT
try std.testing.expectEqual(NodeKind.var_decl, node.*); // WRONG
```

### `main` is a keyword — `kw_main` not `.identifier`
Any parser code accepting a name must handle `kw_main` alongside `.identifier`.

### Reporter owns all message strings — always `defer free` after `report()`
```zig
const msg = try std.fmt.allocPrint(self.allocator, "error: '{s}'", .{name});
defer self.allocator.free(msg);
try self.reporter.report(.{ .message = msg });
```

### Parser invariants
- `advance()` always skips newlines first — never add manual `skipNewlines()` before it
- `check()` is pure — no side effects, never advances position
- `check(.newline)` can never return true
- `eat(kind)` — consume if matches. Use instead of `check()` + `advance()`

### Zig multiline strings — `\\` not `\`
```zig
try file.writeAll(
    \\.gitignore    // CORRECT
    \\zig-out/
);
```

### `@embedFile` for any complete file
Never inline multi-line file content in `.zig` source. Use `@embedFile`.
Paths are relative to the source file using it.

### Template substitution — split-write not allocPrint
Real `.kodr` files have `{` and `}` everywhere. Never pass to `allocPrint`.
Split on the placeholder and write in parts:
```zig
if (std.mem.indexOf(u8, TEMPLATE, "{s}")) |pos| {
    try file.writeAll(TEMPLATE[0..pos]);
    try file.writeAll(name);
    try file.writeAll(TEMPLATE[pos + 3..]);
}
```

---

## Example Module — Built-in Language Manual

The `example` module (`src/templates/example*.kodr`) serves as a **living language
manual** that ships with every new project via `kodr init`. It must:

- **Cover every implemented language feature** — if it compiles, it should be in the manual
- **Stay up to date** — when a new feature lands, add it to the example module
- **Use short descriptive comments** with 1 blank line between comment and code
- **Stay readable** — split across multiple files in the same `module example` when
  a single file gets too long. Files can be named anything (e.g., `types_guide.kodr`,
  `loops.kodr`) as long as they declare `module example` — the compiler only cares
  about the module tag, not file names. `example.kodr` must exist as the anchor file.
- **Compile successfully** — the example module is part of `kodr build`, so it must
  always be valid Kodr code. This also makes it a built-in integration test.

Each file in the example module starts with `module example` and is embedded via
`@embedFile` in `main.zig`. When adding new files, add the corresponding
`@embedFile` constant and write logic in `initProject()`.

---

## Workflow Rules

### Cleanliness
Keep the project structure clean and organized. Remove unnecessary files, stale
logs, and unused artifacts. No orphan files lingering in the root. If something
is no longer used, delete it — don't leave it around "just in case."

### When fixing bugs
1. Read `test_log.txt` or `build_log.txt` first
2. Fix all errors before packaging
3. Diff to confirm only intended lines changed

### Testing rule
New functionality should come with tests when it makes sense. Don't clutter —
one or two focused tests per feature is enough. Prefer testing the new code path
directly rather than through a long integration chain.

Ask before adding tests: "if this breaks, will a test catch it?" If yes, add one.
If the feature is a stub or placeholder, skip the test until it's real.

Untested existing functionality should be tested opportunistically — when touching
a file, check if nearby code lacks coverage and add a test if it's quick and clear.

Tests live in the same file as the code they test (Zig `test` blocks).

---

## Current Status

**Phase 2** — full pipeline working end-to-end.

**Working:**
- `kodr init <n>` — creates project with `main.kodr`, `example.kodr`, `control_flow.kodr`
- `kodr build` — compiles to `bin/<project_name>`
- `kodr run` — builds and executes the binary
- `kodr initstd` — installs `std/` and `global/` next to the binary
- `kodr addtopath`, `kodr debug`
- Import system with `::` scope operator
- Missing module errors reported cleanly
- `extern func` — declares Kodr interface for paired `.zig` implementation
- `import std::zigstd` — Zig stdlib bridge, `kodr initstd` installs it
- Sidecar `.zig` files auto-copied to generated dir during compilation
- `++` concatenation operator (strings and arrays)
- `main.bitsize` — resolver applies default types to untyped numeric literals
- Struct instantiation with named fields — `Player(name: "hero", health: 100.0)`
- Struct methods — static, immutable (`const &`), mutable (`var &`)
- Default field values — omit fields with defaults, Zig fills them in
- Enum instantiation — `var d: Direction = North` → `.North` in Zig
- Enum matching — match arms with enum variants, exhaustive switch detection
- Error type codegen — `Error("msg")`, `(Error | i32)`, `@type(result) == Error`
- Error location in messages — file:line:col with source line preview and caret
- Pass 6 field type awareness — DeclTable lookup for primitive vs non-primitive fields
- Pass 9 propagation — DeclTable-backed `(Error|T)` and `(null|T)` detection
- 86-test suite — unit + build + integration + runtime + negative tests

**Next:**
- Null handling codegen — `(null | T)` unions
- `for` with range — `for(0..10) |i| { }`
- `while` with continue expression — `while(i < 10) : (i += 1) { }`
- `@cast` codegen
- Pass 8 (thread safety) — sendability checks

**Priority rule:** Focus on getting the core language working. Don't flesh out std,
don't add new language features, don't chase edge cases in analysis passes.
Implement the common/core paths first. Stdlib and full blueprint come later.
