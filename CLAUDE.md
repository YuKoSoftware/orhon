# Orhon — Claude Project Instructions

## What This Project Is
Orhon is a compiled, memory-safe programming language that transpiles to Zig.
Written in Zig 0.15.x. Lives entirely in `src/`.
One-sentence pitch: *"A simple yet powerful language that is safe."*

**Full language spec:** `docs/` folder — read relevant files before making any decisions about
language behavior, syntax, or semantics. Do not rely on memory or assumptions — check the spec.

**Other docs:** `docs/COMPILER.md` — compiler architecture + project structure. `docs/TODO.md` — bugs, polish tasks, future architecture.

---

## Build & Test

```bash
./testall.sh             # full test suite: all test stages in pipeline order
bash test/03_cli.sh      # run a single test stage independently
zig build                # debug build
zig build -Doptimize=ReleaseFast  # release build
```

Always run `./testall.sh` after changes. Test files live in `test/`, each independently
runnable. Pipeline order:

| File | What it tests |
|------|---------------|
| `test/01_unit.sh` | Zig unit tests (`zig build test`) |
| `test/02_build.sh` | Compile the compiler (`zig build`) |
| `test/03_cli.sh` | CLI args, help, error exits |
| `test/04_init.sh` | `orhon init` + embedded std scaffolding |
| `test/05_compile.sh` | `orhon build`, `orhon run`, `orhon test`, `orhon debug`, incremental |
| `test/06_library.sh` | Static + dynamic library builds |
| `test/07_multimodule.sh` | Multi-module project builds |
| `test/08_codegen.sh` | Generated Zig quality checks |
| `test/09_language.sh` | Language feature codegen (example + tester modules) |
| `test/10_runtime.sh` | Runtime correctness (tester binary output) |
| `test/11_errors.sh` | Negative tests (expected compilation failures) |

Test fixtures (`.orh` files used by tests) live in `test/fixtures/`.

---

## Zig Version & References

Targets **Zig 0.15.2+**. Zig is installed globally — do not bundle a binary.

Zig has moved to Codeberg — not GitHub. Always use Codeberg for source and stdlib:
- https://codeberg.org/ziglang/zig
- https://ziglang.org/documentation/master/
- https://zig.guide/ — up-to-date guides and API reference

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
Real `.orh` files have `{` and `}` everywhere. Never pass to `allocPrint`.
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

The `example` module (`src/templates/example*.orh`) serves as a **living language
manual** that ships with every new project via `orhon init`. It must:

- **Cover every implemented language feature** — if it compiles, it should be in the manual
- **Stay up to date** — when a new feature lands, add it to the example module
- **Use short descriptive comments** with 1 blank line between comment and code
- **Stay readable** — split across multiple files in the same `module example` when
  a single file gets too long. Files can be named anything (e.g., `types_guide.orh`,
  `loops.orh`) as long as they declare `module example` — the compiler only cares
  about the module tag, not file names. `example.orh` must exist as the anchor file.
- **Compile successfully** — the example module is part of `orhon build`, so it must
  always be valid Orhon code. This also makes it a built-in integration test.

Each file in the example module starts with `module example` and is embedded via
`@embedFile` in `main.zig`. When adding new files, add the corresponding
`@embedFile` constant and write logic in `initProject()`.

---

## Workflow Rules

### Cleanliness
Keep the project structure clean and organized. Remove unnecessary files, stale
logs, and unused artifacts. No orphan files lingering in the root. If something
is no longer used, delete it — don't leave it around "just in case."

### Code quality
- Write clean, structured code — no hacky code or workarounds
- No messy code — if a solution feels fragile or unclear, rethink it
- Keep comments up to date — when code changes, update or remove nearby comments
  so they always reflect what the code actually does

### Documentation rule
Each doc file has one specific purpose — no overlap between files. If information
belongs in an existing file, update it there instead of writing it somewhere else.
Before creating a new doc, check that no existing file already covers the topic.
README is an introduction only — no syntax, no feature lists, no details that go stale.

### When fixing bugs
1. Read `test_log.txt` first
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


