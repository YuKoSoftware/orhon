# Architecture

**Analysis Date:** 2026-03-24

## Pattern Overview

**Overall:** Linear multi-pass compilation pipeline — Orhon source (.orh) → Zig source → native binary

**Key Characteristics:**
- One file per pipeline pass — each pass is a self-contained Zig module
- Passes run sequentially; each pass only proceeds if the previous reported no errors
- Multiple errors per pass are collected before stopping (not fail-fast)
- Incremental compilation: unchanged modules skip passes 4–12 and reuse cached `.zig` files
- Codegen is a pure 1:1 translator — no library knowledge, all stdlib in bridge modules
- AST uses arena allocation — entire tree freed in one call

## Layers

**CLI + Orchestration:**
- Purpose: Parse command-line arguments, dispatch to commands, drive the pipeline
- Location: `src/main.zig`
- Contains: `Command` enum, `CliArgs` struct, `runPipeline()`, `initProject()`
- Depends on: Every pass module (lexer through zig_runner)
- Used by: OS shell invocation

**Frontend (Parsing):**
- Purpose: Turn raw source text into a typed AST
- Location: `src/lexer.zig`, `src/parser.zig`, `src/orhon.peg`, `src/peg/`
- Contains: `Lexer`, `TokenKind`, `Node`, `NodeKind`, PEG engine + grammar + builder
- Depends on: Nothing (lexer is standalone; PEG depends only on lexer)
- Used by: `module.zig` (parseModules), `lsp.zig`

**Module Resolution:**
- Purpose: Group `.orh` files by module name, build dependency graph, detect circular imports, check incremental cache
- Location: `src/module.zig`
- Contains: `Module` struct, `Resolver`, `FileOffset`, `resolveFileLoc()`
- Depends on: lexer, parser, cache
- Used by: `main.zig` (runPipeline), `lsp.zig`

**Semantic Analysis (Passes 4–9):**
- Purpose: Collect declarations, resolve types, enforce ownership, borrow, thread safety, error propagation
- Location: `src/declarations.zig`, `src/resolver.zig`, `src/sema.zig`, `src/ownership.zig`, `src/borrow.zig`, `src/thread_safety.zig`, `src/propagation.zig`
- Contains: `DeclTable`, `DeclCollector`, `TypeResolver`, `SemanticContext`, `OwnershipChecker`, `BorrowChecker`, `ThreadSafetyChecker`, `PropagationChecker`
- Depends on: parser (AST nodes), types, errors, sema (shared context)
- Used by: `main.zig` (runPipeline), `lsp.zig`

**MIR (Mid-level Intermediate Representation):**
- Purpose: Walk AST + resolver type_map to produce a typed annotation table (`NodeMap`). Codegen reads this instead of re-discovering types.
- Location: `src/mir.zig`
- Contains: `TypeClass` enum, `NodeInfo`, `NodeMap` (AST node pointer → NodeInfo), `UnionRegistry`, `MirAnnotator`, `MirLowerer`, `MirNode` tree
- Depends on: parser, declarations, types, errors
- Used by: `main.zig` (runPipeline), `codegen.zig`

**Code Generation:**
- Purpose: Pure 1:1 translation of MIR + AST to readable Zig source. One `.zig` file per Orhon module.
- Location: `src/codegen.zig`
- Contains: `CodeGen` struct — stateful generator walking the AST with MIR annotation
- Depends on: parser, mir, declarations, types, errors, builtins
- Used by: `main.zig` (runPipeline)

**Zig Backend:**
- Purpose: Invoke the Zig compiler on generated `.zig` files to produce final binary
- Location: `src/zig_runner.zig`
- Contains: `ZigRunner`, `ZigResult` — discovers Zig binary (adjacent dir or PATH)
- Depends on: errors, cache, module
- Used by: `main.zig` (runPipeline)

**Shared Infrastructure:**
- Purpose: Common utilities used across multiple passes
- Location: `src/types.zig`, `src/errors.zig`, `src/builtins.zig`, `src/constants.zig`, `src/cache.zig`
- Contains: `ResolvedType`, `Primitive`, `Reporter`, `OrhonError`, `SourceLoc`, `Cache`, language intrinsics
- Used by: all pass modules

**Standard Library Bridge System:**
- Purpose: Orhon `.orh` interface files + Zig `.zig` sidecars for stdlib modules
- Location: `src/std/`
- Contains: Paired `.orh`/`.zig` files for each stdlib module (collections, str, json, fs, etc.)
- Embedded via: `@embedFile` in `main.zig`, extracted to `.orh-cache/std/` at build time
- Used by: Orhon user code via `import std::X` or `include std::X`

**Auxiliary Tools:**
- `src/formatter.zig` — `orhon fmt` source formatter
- `src/lsp.zig` — JSON-RPC LSP server (runs passes 1–9, publishes diagnostics, hover, completion, etc.)
- `src/docgen.zig` — `orhon gendoc` doc generator from `///` comments
- `src/fuzz.zig` — standalone fuzzer binary for lexer + parser

## Data Flow

**Normal Compilation (build/run/test):**

1. `main()` in `src/main.zig` parses CLI args into `CliArgs`
2. `runPipeline()` extracts std files to `.orh-cache/std/`
3. Pass 3: `module.Resolver.scanDirectory()` finds all `.orh` files, groups by module name, builds dep graph
4. Per-module in topological order:
   a. Pass 4: `DeclCollector.collect(ast)` → `DeclTable`
   b. Pass 5: `TypeResolver.resolve(ast)` → `type_map`
   c. `SemanticContext` assembled from decls + locs
   d. Passes 6–9: ownership, borrow, thread safety, propagation checkers run on AST
   e. Pass 10a: `MirAnnotator.annotate(ast)` → `NodeMap`, `UnionRegistry`, `var_types`
   f. Pass 10b: `MirLowerer.lower(ast)` → `MirNode` tree
   g. Pass 11: `CodeGen.generate(ast, mod_name)` writes Zig source; result cached to `.orh-cache/generated/`
5. Pass 12: `ZigRunner` invokes `zig build` on all generated files → binary in `bin/`

**Incremental Compilation:**
- `cache.Cache` compares file timestamps at step 3
- Unchanged modules with unchanged deps skip passes 4–12; cached `.zig` files are reused
- Cache stored in `.orh-cache/` (timestamps, deps.graph, generated Zig, warnings)

**LSP Flow:**
- `lsp.serve()` runs a JSON-RPC loop over stdio
- On document change: runs passes 1–9 and publishes diagnostics
- Passes 10–12 are not run in LSP mode (no codegen, no Zig invocation)

**State Management:**
- No global mutable state — all state flows through explicit structs passed by pointer
- `Reporter` accumulates errors and warnings; passed through all passes
- `SemanticContext` holds shared read-only state for passes 6–9
- Arena allocators own AST memory per module; freed after codegen completes

## Key Abstractions

**Node / NodeKind:**
- Purpose: The Orhon AST node type. Tagged union with 77 variants covering all language constructs.
- Examples: `src/parser.zig` (NodeKind enum, Node union)
- Pattern: Arena-allocated; `*parser.Node` pointers are stable within a module's parse lifetime

**ResolvedType:**
- Purpose: Fully resolved Orhon type after type resolution pass
- Examples: `src/types.zig`
- Pattern: Tagged union — `.primitive(Primitive)`, `.struct_type`, `.enum_type`, `.generic`, `.ptr`, `.null_union`, `.error_union`, `.union_type`, etc.

**DeclTable:**
- Purpose: Registry of all declared functions, structs, enums, variables in a module
- Examples: `src/declarations.zig`
- Pattern: Multiple `StringHashMap` fields keyed by name; passed to all downstream passes

**SemanticContext:**
- Purpose: Read-only shared context for validation passes 6–9
- Examples: `src/sema.zig`
- Pattern: Thin struct holding `allocator`, `reporter`, `decls`, `locs`, `file_offsets`; `nodeLoc()` helper resolves combined-buffer lines to original file+line

**NodeMap (MIR):**
- Purpose: Annotation table mapping `*parser.Node → NodeInfo` (resolved type + TypeClass + optional coercion)
- Examples: `src/mir.zig`
- Pattern: `std.AutoHashMapUnmanaged`; produced by MirAnnotator, consumed read-only by CodeGen

**Reporter:**
- Purpose: Error and warning accumulator used by all passes
- Examples: `src/errors.zig`
- Pattern: `report()` appends errors (owns strings); `flush()` prints all at end; `hasErrors()` gates each pass

**Bridge Module:**
- Purpose: Orhon interface (`.orh`) + Zig implementation (`.zig` sidecar) pair
- Examples: `src/std/collections.orh` + `src/std/collections.zig`
- Pattern: Orhon `bridge` declarations; codegen re-exports from sidecar; no special-case name mapping in codegen

## Entry Points

**CLI Entry:**
- Location: `src/main.zig` → `pub fn main()`
- Triggers: User invoking the `orhon` binary
- Responsibilities: Allocator setup (DebugAllocator in debug, smp_allocator in release), CLI parse, command dispatch, error flush, process exit

**Pipeline Entry:**
- Location: `src/main.zig` → `fn runPipeline()`
- Triggers: `main()` for build/run/test/debug commands
- Responsibilities: Std file extraction, module resolution, per-module pass execution in topological order, cache update, Zig invocation

**LSP Entry:**
- Location: `src/lsp.zig` → `pub fn serve()`
- Triggers: `orhon lsp`
- Responsibilities: JSON-RPC stdio loop, incremental analysis, diagnostic publishing

**PEG Grammar Entry:**
- Location: `src/peg.zig` → `loadGrammar()`, `peg/engine.zig` → `Engine.matchRule()`
- Triggers: Module parsing, `orhon analysis` command
- Responsibilities: Parse `orhon.peg` grammar, run packrat matching on token stream, build capture tree

## Error Handling

**Strategy:** Collect-then-report. Each pass appends to `Reporter`; execution stops after each pass if `reporter.hasErrors()`. All errors flushed together at end of `main()`.

**Patterns:**
- Each pass receives `*errors.Reporter` and calls `reporter.report(.{ .message = msg, .loc = loc })`
- Error message strings are caller-allocated; `Reporter.report()` dupes and owns them — callers must `defer allocator.free(msg)` before reporting
- `SourceLoc` carries `file`, `line`, `col`; `SemanticContext.nodeLoc()` resolves combined-buffer positions to original file locations
- Zig errors (`error.ParseError`, `error.CompileError`) bubble to `main()` which checks them; other errors (`anyerror`) propagate normally

## Cross-Cutting Concerns

**Logging:** `std.debug.print` for user-facing output; no logging framework
**Validation:** Source location tracking via `parser.LocMap` (AST node → token position), `module.FileOffset` (combined buffer → original file)
**Authentication:** Not applicable
**Memory:** Arena allocator per parsed module (freed after codegen); general allocator for all other structures; `DebugAllocator` in debug mode to catch leaks

---

*Architecture analysis: 2026-03-24*
