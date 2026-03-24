# Codebase Structure

**Analysis Date:** 2026-03-24

## Directory Layout

```
orhon_compiler/
├── src/                    # All compiler source (Zig)
│   ├── main.zig            # Entry point, CLI, pipeline orchestrator
│   ├── lexer.zig           # Pass 1: tokenizer
│   ├── orhon.peg           # Pass 2: PEG grammar (formal syntax spec)
│   ├── parser.zig          # AST type definitions (Node, NodeKind)
│   ├── peg.zig             # PEG public API (re-exports peg/ submodules)
│   ├── peg/                # PEG engine internals
│   │   ├── grammar.zig     # .peg file parser
│   │   ├── engine.zig      # Packrat matching engine
│   │   ├── capture.zig     # Capture tree builder
│   │   ├── builder.zig     # Capture tree → AST node conversion
│   │   └── token_map.zig   # Grammar literals → TokenKind mapping
│   ├── module.zig          # Pass 3: module resolution
│   ├── declarations.zig    # Pass 4: declaration collection
│   ├── resolver.zig        # Pass 5: type resolution
│   ├── sema.zig            # Shared SemanticContext (passes 6–9)
│   ├── ownership.zig       # Pass 6: ownership analysis
│   ├── borrow.zig          # Pass 7: borrow checking
│   ├── thread_safety.zig   # Pass 8: thread safety analysis
│   ├── propagation.zig     # Pass 9: error propagation analysis
│   ├── mir.zig             # Pass 10: MIR annotation + lowering
│   ├── codegen.zig         # Pass 11: Zig code generation
│   ├── zig_runner.zig      # Pass 12: Zig compiler invocation
│   ├── types.zig           # Shared: Primitive, ResolvedType
│   ├── errors.zig          # Shared: Reporter, OrhonError, SourceLoc
│   ├── builtins.zig        # Shared: language intrinsics
│   ├── constants.zig       # Shared: string constants
│   ├── cache.zig           # Shared: incremental compilation cache
│   ├── formatter.zig       # orhon fmt implementation
│   ├── lsp.zig             # Language Server Protocol (JSON-RPC)
│   ├── docgen.zig          # orhon gendoc doc generator
│   ├── fuzz.zig            # Standalone fuzzer for lexer+parser
│   ├── std/                # Standard library bridge modules
│   │   ├── *.orh           # Orhon interface declarations (bridge)
│   │   └── *.zig           # Zig implementation sidecars
│   └── templates/          # Project scaffolding templates
│       ├── main.orh        # Template for new project src/main.orh
│       └── example/        # Built-in language manual module
│           ├── example.orh
│           ├── control_flow.orh
│           ├── data_types.orh
│           ├── error_handling.orh
│           ├── strings.orh
│           └── advanced.orh
├── test/                   # Shell-based test suite
│   ├── 01_unit.sh          # Zig unit tests (zig build test)
│   ├── 02_build.sh         # Compiler build check
│   ├── 03_cli.sh           # CLI args, help, error exits
│   ├── 04_init.sh          # orhon init + scaffolding
│   ├── 05_compile.sh       # build/run/test/debug/incremental
│   ├── 06_library.sh       # Static + dynamic library builds
│   ├── 07_multimodule.sh   # Multi-module projects
│   ├── 08_codegen.sh       # Generated Zig quality checks
│   ├── 09_language.sh      # Language feature codegen
│   ├── 10_runtime.sh       # Runtime correctness (binary output)
│   ├── 11_errors.sh        # Negative tests (expected failures)
│   ├── helpers.sh          # Shared test utilities
│   └── fixtures/           # .orh files used by tests
│       ├── tester.orh      # Main language feature tester
│       ├── tester_main.orh # Entry point for tester binary
│       └── fail_*.orh      # Fixtures expected to fail compilation
├── docs/                   # Compiler + language documentation
├── editors/                # Editor support
│   └── vscode/             # VSCode syntax extension
├── build.zig               # Zig build script
├── build.zig.zon           # Package manifest
├── testall.sh              # Full test suite runner
├── CLAUDE.md               # Project instructions for AI assistance
└── .planning/              # AI planning documents (not committed)
    └── codebase/
```

## Directory Purposes

**`src/` (root):**
- Purpose: All compiler source; one file per pipeline pass
- Contains: 20+ Zig source files, each named after what it implements
- Key files: `main.zig` (orchestrator), `orhon.peg` (grammar spec)

**`src/peg/`:**
- Purpose: PEG parsing engine internals — separated from the rest of `src/` for clarity
- Contains: Grammar parser, packrat engine, capture tree, AST builder, token map
- Key files: `builder.zig` (largest; maps grammar rules to AST nodes), `engine.zig` (core matcher)

**`src/std/`:**
- Purpose: Orhon standard library modules, each as a `.orh`/`.zig` pair
- Contains: ~25 paired bridge modules (collections, str, json, fs, math, http, regex, tui, etc.)
- Pattern: `.orh` file declares the Orhon interface with `bridge`; `.zig` sidecar implements it
- Embedded: All files embedded in the compiler binary via `@embedFile`; extracted to `.orh-cache/std/` at runtime

**`src/templates/`:**
- Purpose: Source files written to new projects by `orhon init`
- Contains: `main.orh` (entry point template), `example/` (language manual — 6 files)
- Embedded: All embedded via `@embedFile` constants in `main.zig`

**`test/`:**
- Purpose: Shell-based integration test suite; each script independently runnable
- Contains: 11 numbered test stages + helpers
- Key files: `fixtures/tester.orh` (comprehensive language feature tests), `fixtures/fail_*.orh` (negative tests)

**`docs/`:**
- Purpose: Language specification and compiler documentation
- Key files: `COMPILER.md` (pipeline + project structure), `TODO.md` (bugs + future work)

**`.orh-cache/` (generated, not committed):**
- Purpose: Incremental compilation cache written at build time
- Contains: `timestamps`, `deps.graph`, `generated/*.zig` (compiled modules), `std/*.orh` + `*.zig` (stdlib), `warnings`

**`zig-out/` (generated, not committed):**
- Purpose: Zig build output directory
- Contains: Compiled `orhon` binary

## Key File Locations

**Entry Points:**
- `src/main.zig`: Compiler binary entry point, CLI, pipeline orchestrator
- `src/fuzz.zig`: Standalone fuzzer binary (separate executable)

**Grammar + Syntax:**
- `src/orhon.peg`: PEG grammar — the single source of truth for Orhon syntax

**AST Definitions:**
- `src/parser.zig`: `NodeKind` enum (77 variants), `Node` tagged union, `LocMap`

**Type System:**
- `src/types.zig`: `Primitive` enum, `ResolvedType` tagged union — shared across all semantic passes

**Error Infrastructure:**
- `src/errors.zig`: `Reporter`, `OrhonError`, `SourceLoc` — used by every pass

**MIR / Codegen Interface:**
- `src/mir.zig`: `NodeMap`, `TypeClass`, `UnionRegistry`, `MirNode` tree — the bridge between semantic analysis and codegen

**Cache:**
- `src/cache.zig`: Incremental cache manager; constants for cache paths (`CACHE_DIR`, `GENERATED_DIR`)

**Test Fixtures:**
- `test/fixtures/tester.orh`: Full language feature tester (~31KB)
- `test/fixtures/fail_*.orh`: One file per expected compiler error category

**Build Configuration:**
- `build.zig`: Single executable (`orhon`) + test step (all source files) + fuzz step

## Naming Conventions

**Files:**
- Pass files: named after the pass — `lexer.zig`, `module.zig`, `declarations.zig`, `resolver.zig`, etc.
- Shared utility files: descriptive noun — `types.zig`, `errors.zig`, `constants.zig`, `cache.zig`
- Test scripts: `NN_name.sh` (two-digit number + underscore + descriptive name)
- Test fixtures: `fail_<category>.orh` for negative tests; descriptive names for positive fixtures
- Std bridge pairs: `<module>.orh` + `<module>.zig` (identical base name)

**Directories:**
- All lowercase, short, descriptive: `src/`, `peg/`, `std/`, `templates/`, `test/`, `fixtures/`, `example/`

**Zig Identifiers:**
- Types/structs: `PascalCase` — `NodeKind`, `ResolvedType`, `DeclTable`, `SemanticContext`
- Functions/variables: `camelCase` — `runPipeline`, `nodeLoc`, `hasErrors`
- Constants: `SCREAMING_SNAKE_CASE` for embedded file constants — `MAIN_ORH_TEMPLATE`, `COLLECTIONS_ZIG`
- Pass checker types: `<Pass>Checker` — `OwnershipChecker`, `BorrowChecker`, `ThreadSafetyChecker`
- Pass runner types: `<Pass>Resolver` / `<Pass>Collector` — `TypeResolver`, `DeclCollector`

## Where to Add New Code

**New language feature (syntax change):**
1. Add/modify grammar rule in `src/orhon.peg`
2. Add AST builder in `src/peg/builder.zig` for new `NodeKind`
3. Add `NodeKind` variant to enum in `src/parser.zig`
4. Handle new node in semantic passes: `src/declarations.zig`, `src/resolver.zig`, validation passes as needed
5. Handle new node in `src/mir.zig` (annotation) and `src/codegen.zig` (generation)
6. Update `src/templates/example/` with a usage example

**New stdlib module:**
1. Create `src/std/<module>.orh` (Orhon interface with `bridge` declarations)
2. Create `src/std/<module>.zig` (Zig implementation)
3. Add `@embedFile` constants in `src/main.zig`
4. Add entries to the `files` array in `ensureStdFiles()` in `src/main.zig`

**New compiler pass:**
- Implementation: `src/<passname>.zig`
- Integration: Add pass call in `runPipeline()` in `src/main.zig` at correct position
- Tests: `test` blocks in the new pass file itself

**New CLI command:**
- Add variant to `Command` enum in `src/main.zig`
- Add parse branch in `parseArgs()`
- Add dispatch in `main()`

**Unit tests:**
- Live as `test` blocks in the same `.zig` file as the code under test
- New test files added to `test_files` array in `build.zig`

**Integration tests:**
- Shell scripts in `test/NN_<name>.sh`
- `.orh` fixtures in `test/fixtures/`

**Utilities:**
- Shared type helpers: `src/types.zig`
- Shared error helpers: `src/errors.zig`
- Language intrinsics only: `src/builtins.zig`
- Named constants: `src/constants.zig`

## Special Directories

**`.orh-cache/`:**
- Purpose: Incremental compilation artifacts written during `orhon build`
- Generated: Yes (at build time)
- Committed: No (in `.gitignore`)
- Subdirs: `generated/` (compiled `.zig` files), `std/` (extracted stdlib bridge files)

**`.zig-cache/`:**
- Purpose: Zig build system cache
- Generated: Yes (by `zig build`)
- Committed: No

**`zig-out/`:**
- Purpose: Zig build output (compiled `orhon` binary)
- Generated: Yes
- Committed: No

**`.planning/codebase/`:**
- Purpose: AI-generated codebase analysis documents
- Generated: Yes (by AI assistance tools)
- Committed: Depends on project preference

---

*Structure analysis: 2026-03-24*
