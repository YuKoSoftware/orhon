# Orhon — Claude Project Instructions

# The Orhon programming language compiler

## code 
- no workarounds
- no hacked code
- always cleanup, no lingering stale code
- clean and correct code
- always log bugs and other problems
- modular and maintainable code
- correct mechanics
- keep code well organized
- use correct type, variable, function, module and folder names
## comments 
- comments stay up to date
## project 
- don't bloat files, separate logically into files and folders
- always be clear what you want to implement
- always be clear about the changes
- keep project well organized
- only well researched changes, don't step into the dark
## documentation
- keep documentation up to date and well organized
- docs are managed with Obsidian — use `[[wikilinks]]` for cross-references between doc files
- doc files live in `docs/` — the vault root is the project root
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

| File                     | What it tests                                                        |
| ------------------------ | -------------------------------------------------------------------- |
| `test/01_unit.sh`        | Zig unit tests (`zig build test`)                                    |
| `test/02_build.sh`       | Compile the compiler (`zig build`)                                   |
| `test/03_cli.sh`         | CLI args, help, error exits                                          |
| `test/04_init.sh`        | `orhon init` + embedded std scaffolding                              |
| `test/05_compile.sh`     | `orhon build`, `orhon run`, `orhon test`, `orhon debug`, incremental |
| `test/06_library.sh`     | Static + dynamic library builds                                      |
| `test/07_multimodule.sh` | Multi-module project builds                                          |
| `test/08_codegen.sh`     | Generated Zig quality checks                                         |
| `test/09_language.sh`    | Language feature codegen (example + tester modules)                  |
| `test/10_runtime.sh`     | Runtime correctness (tester binary output)                           |
| `test/11_errors.sh`      | Negative tests (expected compilation failures)                       |

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

### `main` is a regular identifier — reserved for entry point only
`main` is not a keyword. It is a regular `.identifier` token that the compiler
reserves semantically: only valid as `func main()` in `#build = exe` module anchor files.

### Reporter owns all message strings — always `defer free` after `report()`
```zig
const msg = try std.fmt.allocPrint(self.allocator, "error: '{s}'", .{name});
defer self.allocator.free(msg);
try self.reporter.report(.{ .message = msg });
```

### PEG grammar is the source of truth for syntax
All syntax rules live in `src/orhon.peg`. To add a new language feature:
1. Add the grammar rule to `orhon.peg`
2. Add the AST builder in `src/peg/builder.zig`
3. The engine (`src/peg/engine.zig`) handles matching automatically

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

### Zero magic rule
The compiler has zero special cases for stdlib types or functions. If something needs
complex behavior (fields, methods, constructors), it gets implemented purely in std
as Orhon or Zig code. The compiler handles it through normal code paths — same as
any user code. If the compiler can't handle it, we fix the compiler, not add workarounds.

Only **compiler functions** (`@cast`, `@copy`, `@move`, `@swap`, `@typename`, `@typeid`,
`@typeOf`, `@size`, `@align`, `@assert`, `@splitAt`) and **language-level constructs**
(match desugaring, string interpolation, operators) get codegen awareness.

Everything in `std::*` (collections, string, json, fs, etc.) must go through the normal
import/use system — no hardcoded names, no shortcut recognition, no fallback lists,
no codegen rewriting for specific method names. A user-defined `List` type in their
own module must work identically to `std::collections.List`. The stdlib is just another
set of Zig modules.

**Known violations (tracked in `docs/TODO.md`):** `collection_expr` grammar rules,
`.new()` constructor rewriting, `.value` field rewriting, bitfield auto-methods,
`wrap()`/`sat()`/`overflow()` not using `@` prefix. All scheduled for removal.

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

## Tamga — Companion Project

Location: `/home/yunus/Projects/orhon/tamga/`

A game/multimedia framework written in pure Orhon that doubles as a real-world
stress test for the compiler.

Its primary value to us: bugs discovered while building the framework are logged
in `docs/bugs.md` and language design feedback in `docs/ideas.md`. Read these
files to understand what compiler issues need fixing.

## Technology Stack

## Languages
- Zig 0.15.2+ — all compiler source (`src/*.zig`, `src/peg/*.zig`, `src/std/*.zig`)
- Orhon (`.orh`) — example module (`src/templates/`), test fixtures (`test/fixtures/`)
- JavaScript — VS Code extension client (`editors/vscode/extension.js`)
- Shell (bash) — test runner scripts (`test/*.sh`, `testall.sh`)
## Runtime
- Native binary — no managed runtime; compiles to native via Zig backend
- Target platforms: linux_x64, linux_arm, win_x64, mac_x64, mac_arm, wasm32-freestanding
- Zig build system (no external package manager; `build.zig.zon` declares no dependencies)
- Lockfile: not applicable (zero external Zig dependencies)
- VS Code extension: npm (`editors/vscode/package-lock.json` present)
## Frameworks
- Zig standard library only — no third-party Zig dependencies declared in `build.zig.zon`
- PEG parsing engine — custom implementation in `src/peg/` (grammar.zig, engine.zig, capture.zig, builder.zig, token_map.zig)
- Zig built-in `test` blocks — run via `zig build test`
- Shell-based integration tests — `test/01_unit.sh` through `test/11_errors.sh`
- `zig build` — compiler and fuzz binary
- `zig build test` — all unit test blocks across all source files
- `zig build fuzz` — runs `src/fuzz.zig` random input fuzzer
- `./testall.sh` — full pipeline test suite
## Key Dependencies
- Zig 0.15.2 (system-installed or co-located binary) — the single backend; all cross-compilation, linking, and optimization is delegated to Zig. Discovered at runtime via: 1) same directory as `orhon` binary, 2) global PATH. See `src/zig_runner.zig`.
- `std.http.Client` (Zig stdlib) — HTTP GET/POST in `src/std/http.zig`
- `std.net` (Zig stdlib) — TCP client/server in `src/std/net.zig`
- `std.json` (Zig stdlib) — JSON parse/build in `src/std/json.zig`
- `std.compress.gzip` (Zig stdlib) — compression in `src/std/compression.zig`
- `std.crypto` (Zig stdlib) — SHA256/512, MD5, Blake3, HMAC, AES-GCM in `src/std/crypto.zig`
- `vscode-languageclient` ^9.0.1 — LSP client wrapper (`editors/vscode/`)
- `@vscode/vsce` ^3.0.0 (devDep) — extension packaging
## Configuration
- No `.env` files — compiler has no runtime environment variable requirements
- Version is baked in at compile time via `build.zig` `addOptions` / `build_options` import
- Version defined in `build.zig.zon` (single source of truth, read by `build.zig` at compile time)
- `build.zig` — defines `exe`, `test`, and `fuzz` steps; injects version string as comptime option
- `build.zig.zon` — package manifest; minimum Zig version `0.15.2`; zero external dependencies
- Stored in `.orh-cache/` (gitignored) — timestamps, dependency graph, generated `.zig` files
- Constants in `src/cache.zig`: `CACHE_DIR`, `GENERATED_DIR`, `TIMESTAMPS_FILE`, `DEPS_FILE`, `WARNINGS_FILE`
## Platform Requirements
- Zig 0.15.2+ installed globally
- No other toolchain dependencies for the compiler itself
- Node.js / npm required only for building the VS Code extension
- Self-contained native binary (`zig-out/bin/orhon`)
- Zig binary must be co-located with or accessible on PATH at runtime (for code generation step)
- Cross-compilation supported: linux_x64, linux_arm, win_x64, mac_x64, mac_arm, wasm

## Conventions

## Naming Patterns
- `snake_case.zig` for all source files: `codegen.zig`, `zig_runner.zig`, `thread_safety.zig`
- Subdirectories use `snake_case/` as well: `src/peg/`, `src/std/`, `src/codegen/`, `src/mir/`, `src/lsp/`, `src/zig_runner/`
- `PascalCase` for public structs and enums: `Reporter`, `CodeGen`, `MirAnnotator`, `TypeClass`, `OwnershipScope`
- `PascalCase` for type aliases: `const RT = types.ResolvedType;`
- `camelCase` for all methods and free functions: `init`, `deinit`, `hasErrors`, `typeToZig`, `classifyType`, `resolveFileLoc`
- Verb-first naming for methods: `checkNode`, `checkExpr`, `collectTopLevel`, `generateFunc`, `emitLine`
- Private helper functions use the same `camelCase`, just without `pub`
- `snake_case` for fields and local variables: `file_offsets`, `active_borrows`, `decl_table`, `is_debug`
- Boolean fields start with `is_`, `has_`: `is_pub`, `is_compt`, `is_thread`, `is_zig_module`
- `SCREAMING_SNAKE_CASE` for module-level string/array constants: `BUILTIN_TYPES`, `COMPILER_FUNCS`, `CACHE_DIR`
- Namespace constants inside structs also `SCREAMING_SNAKE_CASE`: `constants.Type.ERROR`, `constants.Ptr.VAR_REF`
- `snake_case` for enum variants: `.owned`, `.moved`, `.error_union`, `.null_union`, `.kw_func`, `.lparen`
- Exception: token kinds and node kinds use `snake_case` consistently throughout
## File Structure
- `// errors.zig — Orhon compiler error formatting`
- `// codegen.zig — Zig Code Generation pass (pass 11)`
- `// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 10)`
## Import Organization
- No path aliases used — all imports use relative paths
- `@import("../lexer.zig")` from subdirectories (e.g. `src/peg/`)
## Constructor Pattern
## Error Handling
## Memory Management
## Comments
- Public types and their fields
- Non-obvious functions
- Enum variants when the name is not self-explanatory
- Inline clarification
- Section headers
- Pass numbers: `// Ownership & Move Analysis pass (pass 6)`
## Exported vs Internal
- Types and structs intended for use across modules
- `init`, `deinit`, and primary entry-point methods
- Constants needed elsewhere
- Internal helper functions: `emit`, `emitFmt`, `emitIndent`, `checkStatement`, `lookupFieldType`
- Section-internal logic
## Module Design
- `errors.zig` → `Reporter`
- `declarations.zig` → `DeclCollector`, `DeclTable`
- `ownership.zig` → `OwnershipChecker`, `OwnershipScope`
- `codegen/codegen.zig` → `CodeGen` (hub + 4 satellites: decls, exprs, stmts, match)
- `mir/mir.zig` → `MirAnnotator`, `MirLowerer`, `UnionRegistry` (hub + 5 satellites: types, node, annotator, lowerer, registry)
- `types.zig` — `ResolvedType`, `Primitive`, `OwnershipState`
- `constants.zig` — shared string constants (`Type.*`, `Ptr.*`)
- `parser.zig` — AST node types only (no parsing logic)

## Architecture

## Pattern Overview
- Hub-and-spoke architecture — large passes split into a hub file that re-exports from satellite files (codegen/, mir/, lsp/, zig_runner/, peg/builder*)
- Passes run sequentially; each pass only proceeds if the previous reported no errors
- Multiple errors per pass are collected before stopping (not fail-fast)
- Incremental compilation: unchanged modules skip passes 4–12 and reuse cached `.zig` files
- Codegen is a pure 1:1 translator — no library knowledge, all stdlib in Zig modules
- AST uses arena allocation — entire tree freed in one call
## Layers
- Purpose: Parse command-line arguments, dispatch to commands, drive the pipeline
- Location: `src/main.zig` (entry), `src/cli.zig` (arg parsing), `src/pipeline.zig` (pipeline orchestration), `src/commands.zig` (secondary commands), `src/init.zig` (project scaffolding)
- Contains: `Command` enum, `CliArgs` struct, `runPipeline()`, `initProject()`
- Depends on: Every pass module (lexer through zig_runner)
- Used by: OS shell invocation
- Purpose: Turn raw source text into a typed AST
- Location: `src/lexer.zig`, `src/parser.zig`, `src/orhon.peg`, `src/peg.zig`, `src/peg/` (engine, grammar, capture, builder hub + 5 satellites, token_map)
- Contains: `Lexer`, `TokenKind`, `Node`, `NodeKind`, PEG engine + grammar + builder
- Depends on: Nothing (lexer is standalone; PEG depends only on lexer)
- Used by: `module.zig` (parseModules), `lsp.zig`
- Purpose: Group `.orh` files by module name, build dependency graph, detect circular imports, check incremental cache
- Location: `src/module.zig`
- Contains: `Module` struct, `Resolver`, `FileOffset`, `resolveFileLoc()`
- Depends on: lexer, parser, cache
- Used by: `main.zig` (runPipeline), `lsp.zig`
- Purpose: Collect declarations, resolve types, enforce ownership, borrow, thread safety, error propagation
- Location: `src/declarations.zig`, `src/resolver.zig`, `src/sema.zig`, `src/ownership.zig`, `src/borrow.zig`, `src/thread_safety.zig`, `src/propagation.zig`
- Contains: `DeclTable`, `DeclCollector`, `TypeResolver`, `SemanticContext`, `OwnershipChecker`, `BorrowChecker`, `ThreadSafetyChecker`, `PropagationChecker`
- Depends on: parser (AST nodes), types, errors, sema (shared context)
- Used by: `main.zig` (runPipeline), `lsp.zig`
- Purpose: Walk AST + resolver type_map to produce a typed annotation table (`NodeMap`). Codegen reads this instead of re-discovering types.
- Location: `src/mir/` (hub: `mir.zig`, satellites: `mir_types.zig`, `mir_node.zig`, `mir_annotator.zig`, `mir_lowerer.zig`, `mir_registry.zig`)
- Contains: `TypeClass` enum, `NodeInfo`, `NodeMap` (AST node pointer → NodeInfo), `UnionRegistry`, `MirAnnotator`, `MirLowerer`, `MirNode` tree
- Depends on: parser, declarations, types, errors
- Used by: `main.zig` (runPipeline), `codegen.zig`
- Purpose: Pure 1:1 translation of MIR + AST to readable Zig source. One `.zig` file per Orhon module.
- Location: `src/codegen/` (hub: `codegen.zig`, satellites: `codegen_decls.zig`, `codegen_exprs.zig`, `codegen_stmts.zig`, `codegen_match.zig`)
- Contains: `CodeGen` struct — stateful generator walking the AST with MIR annotation
- Depends on: parser, mir, declarations, types, errors, builtins
- Used by: `main.zig` (runPipeline)
- Purpose: Invoke the Zig compiler on generated `.zig` files to produce final binary
- Location: `src/zig_runner/` (hub: `zig_runner.zig`, satellites: `zig_runner_build.zig`, `zig_runner_discovery.zig`, `zig_runner_multi.zig`)
- Contains: `ZigRunner`, `ZigResult` — discovers Zig binary (adjacent dir or PATH)
- Depends on: errors, cache, module
- Used by: `main.zig` (runPipeline)
- Purpose: Common utilities used across multiple passes
- Location: `src/types.zig`, `src/errors.zig`, `src/builtins.zig`, `src/constants.zig`, `src/cache.zig`
- Contains: `ResolvedType`, `Primitive`, `Reporter`, `OrhonError`, `SourceLoc`, `Cache`, language intrinsics
- Used by: all pass modules
- Purpose: Zig implementations for stdlib modules (auto-converted to Orhon modules)
- Location: `src/std/`
- Contains: Paired `.orh`/`.zig` files for each stdlib module (collections, str, json, fs, etc.)
- Embedded via: `@embedFile` in `std_bundle.zig`, extracted to `.orh-cache/std/` at build time
- Used by: Orhon user code via `import std::X` or `use std::X`
- `src/formatter.zig` — `orhon fmt` source formatter
- `src/lsp/` — JSON-RPC LSP server (hub: `lsp.zig`, satellites: `lsp_types.zig`, `lsp_json.zig`, `lsp_analysis.zig`, `lsp_nav.zig`, `lsp_edit.zig`, `lsp_view.zig`, `lsp_semantic.zig`, `lsp_utils.zig`). Runs passes 1–9, publishes diagnostics, hover, completion, etc.
- `src/docgen.zig` — `orhon gendoc` project API docs from `///` comments
- `src/syntaxgen.zig` — `orhon gendoc` syntax reference from embedded grammar
- `src/zig_docgen.zig` — `orhon gendoc` stdlib reference from `.zig` pub declarations
- `src/fuzz.zig` — standalone fuzzer binary for lexer + parser
## Data Flow
- `cache.Cache` compares file timestamps at step 3
- Unchanged modules with unchanged deps skip passes 4–12; cached `.zig` files are reused
- Cache stored in `.orh-cache/` (timestamps, deps.graph, generated Zig, warnings)
- `lsp.serve()` runs a JSON-RPC loop over stdio
- On document change: runs passes 1–9 and publishes diagnostics
- Passes 10–12 are not run in LSP mode (no codegen, no Zig invocation)
- No global mutable state — all state flows through explicit structs passed by pointer
- `Reporter` accumulates errors and warnings; passed through all passes
- `SemanticContext` holds shared read-only state for passes 6–9
- Arena allocators own AST memory per module; freed after codegen completes
## Key Abstractions
- Purpose: The Orhon AST node type. Tagged union with 77 variants covering all language constructs.
- Examples: `src/parser.zig` (NodeKind enum, Node union)
- Pattern: Arena-allocated; `*parser.Node` pointers are stable within a module's parse lifetime
- Purpose: Fully resolved Orhon type after type resolution pass
- Examples: `src/types.zig`
- Pattern: Tagged union — `.primitive(Primitive)`, `.struct_type`, `.enum_type`, `.generic`, `.ptr`, `.null_union`, `.error_union`, `.union_type`, etc.
- Purpose: Registry of all declared functions, structs, enums, variables in a module
- Examples: `src/declarations.zig`
- Pattern: Multiple `StringHashMap` fields keyed by name; passed to all downstream passes
- Purpose: Read-only shared context for validation passes 6–9
- Examples: `src/sema.zig`
- Pattern: Thin struct holding `allocator`, `reporter`, `decls`, `locs`, `file_offsets`; `nodeLoc()` helper resolves combined-buffer lines to original file+line
- Purpose: Annotation table mapping `*parser.Node → NodeInfo` (resolved type + TypeClass + optional coercion)
- Examples: `src/mir.zig`
- Pattern: `std.AutoHashMapUnmanaged`; produced by MirAnnotator, consumed read-only by CodeGen
- Purpose: Error and warning accumulator used by all passes
- Examples: `src/errors.zig`
- Pattern: `report()` appends errors (owns strings); `flush()` prints all at end; `hasErrors()` gates each pass
- Purpose: `.zig` files auto-converted to Orhon modules; codegen emits re-exports
- Examples: `src/std/collections.zig` → auto-generated `module collections`
- Pattern: `std.zig.Ast` parses `.zig`, maps types to Orhon, generates `.orh` in cache
## Entry Points
- Location: `src/main.zig` → `pub fn main()`
- Triggers: User invoking the `orhon` binary
- Responsibilities: Allocator setup (DebugAllocator in debug, smp_allocator in release), CLI parse, command dispatch, error flush, process exit
- Location: `src/pipeline.zig` → `pub fn runPipeline()`
- Triggers: `main()` for build/run/test/debug commands
- Responsibilities: Std file extraction, module resolution, per-module pass execution in topological order, cache update, Zig invocation
- Location: `src/lsp/lsp.zig` → `pub fn serve()`
- Triggers: `orhon lsp`
- Responsibilities: JSON-RPC stdio loop, incremental analysis, diagnostic publishing
- Location: `src/peg.zig` → `loadGrammar()`, `peg/engine.zig` → `Engine.matchRule()`
- Triggers: Module parsing, `orhon analysis` command
- Responsibilities: Parse `orhon.peg` grammar, run packrat matching on token stream, build capture tree
## Error Handling
- Each pass receives `*errors.Reporter` and calls `reporter.report(.{ .message = msg, .loc = loc })`
- Error message strings are caller-allocated; `Reporter.report()` dupes and owns them — callers must `defer allocator.free(msg)` before reporting
- `SourceLoc` carries `file`, `line`, `col`; `SemanticContext.nodeLoc()` resolves combined-buffer positions to original file locations
- Zig errors (`error.ParseError`, `error.CompileError`) bubble to `main()` which checks them; other errors (`anyerror`) propagate normally
## Cross-Cutting Concerns

