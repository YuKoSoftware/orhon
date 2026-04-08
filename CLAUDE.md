# Orhon — Claude Project Instructions

## What This Project Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig.
Written in Zig 0.15.x. Lives entirely in `src/` (~100 files, ~40K lines).
One-sentence pitch: *"A simple yet powerful language that is safe."*

---

## Build & Test

```bash
./testall.sh             # full test suite (stages 01–11)
bash test/03_cli.sh      # run a single test stage
zig build                # debug build
zig build -Doptimize=ReleaseFast  # release build
```

Always run `./testall.sh` after changes. Test files live in `test/`, each independently
runnable. Pipeline order:

| File                     | What it tests                                     |
| ------------------------ | ------------------------------------------------- |
| `test/01_unit.sh`        | Zig unit tests (`zig build test`)                 |
| `test/02_build.sh`       | Compile the compiler (`zig build`)                |
| `test/03_cli.sh`         | CLI args, help, error exits                       |
| `test/04_init.sh`        | `orhon init` + embedded std scaffolding           |
| `test/05_compile.sh`     | `orhon build/run/test/debug`, incremental         |
| `test/06_library.sh`     | Static + dynamic library builds                   |
| `test/07_multimodule.sh` | Multi-module project builds                       |
| `test/08_codegen.sh`     | Generated Zig quality checks                      |
| `test/09_language.sh`    | Language feature codegen (example + tester)        |
| `test/10_runtime.sh`     | Runtime correctness (tester binary output)         |
| `test/11_errors.sh`      | Negative tests (expected compilation failures)     |

Test fixtures live in `test/fixtures/`.

---

## Zig Version & References

Targets **Zig 0.15.2+**. Zig is installed globally.

- https://codeberg.org/ziglang/zig (source — Zig moved to Codeberg)
- https://ziglang.org/documentation/master/
- https://zig.guide/

---

## Key Zig Gotchas

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

### Reporter owns all message strings — always `defer free` after `report()`
```zig
const msg = try std.fmt.allocPrint(self.allocator, "error: '{s}'", .{name});
defer self.allocator.free(msg);
try self.reporter.report(.{ .message = msg });
```

### PEG grammar is the source of truth for syntax
All syntax rules live in `src/peg/orhon.peg`. To add a new language feature:
1. Add the grammar rule to `orhon.peg`
2. Add the AST builder in `src/peg/builder.zig`
3. The engine (`src/peg/engine.zig`) handles matching automatically

### Zig multiline strings — `\\` not `\`
```zig
try file.writeAll(
    \\.gitignore
    \\zig-out/
);
```

### `@embedFile` for any complete file
Never inline multi-line file content in `.zig` source. Paths are relative to the
source file using it.

### Template substitution — split-write not allocPrint
Real `.orh` files have `{` and `}` everywhere. Never pass to `allocPrint`.
Split on the placeholder and write in parts.

---

## Workflow Rules

### Zero magic rule
The compiler has zero special cases for stdlib types or functions. Everything in
`std::*` must go through the normal import/use system — no hardcoded names, no
shortcut recognition. Only **compiler functions** (`@cast`, `@copy`, `@move`, etc.)
and **language-level constructs** (match desugaring, string interpolation, operators)
get codegen awareness. A user-defined `List` type must work identically to
`std::collections.List`.

### Documentation rule
Each doc file has one specific purpose — no overlap. Before creating a new doc,
check that no existing file covers the topic. README is introduction only.

### When fixing bugs
1. Read `test_log.txt` first
2. Fix all errors before packaging
3. Diff to confirm only intended lines changed

### Testing rule
New functionality should come with tests when it makes sense. Don't clutter —
one or two focused tests per feature. Tests live in the same file as the code
they test (Zig `test` blocks).

---

## Documentation

All docs live in `docs/`. Read relevant files before making decisions about
language behavior, syntax, or semantics.

- `docs/01-basics.md` through `docs/15-testing.md` — full language spec
- `docs/COMPILER.md` — compiler architecture, pipeline, project structure
- `docs/TODO.md` — bugs and polish tasks
- `docs/future.md` — future architecture ideas

---

## Example Module

The example module (`src/templates/example/*.orh`) is a living language manual
that ships with every project via `orhon init`. It must:

- Cover every implemented language feature
- Stay up to date when new features land
- Compile successfully (it's part of `orhon build`)
- Use `module example` in every file

New example files need a corresponding `@embedFile` constant and write logic
in `init.zig`.
