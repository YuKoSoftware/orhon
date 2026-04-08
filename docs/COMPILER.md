# Orhon — Compiler Internals

---

## Compilation Pipeline

Each pass runs only if the previous succeeded. Multiple errors per pass are collected before stopping. See [[13-build-cli]] for how to invoke the pipeline.

```
Source (.orh)
    ↓
1.  Lexer           — raw text → tokens
    ↓
2.  PEG Parser      — tokens → AST (grammar-driven, src/peg/orhon.peg)
    ↓
3.  Module Resolution
    — group files by module name
    — build dependency graph, detect circular imports
    — check incremental cache — skip unchanged modules
    ↓
4.  Declaration Pass
    — collect all type names, function signatures, struct definitions
    — does not resolve bodies yet
    ↓
5.  Compt & Type Resolution (interleaved)
    — resolve compt functions and type check simultaneously
    — resolve all `any` to concrete types
    ↓
6.  Ownership & Move Analysis
    ↓
7.  Borrow Checking
    ↓
8.  Error Propagation Analysis
    ↓
10. MIR Annotation + Lowering — self-contained MIR tree (TypeClass, UnionRegistry, MirNode)
    ↓
11. Zig Code Generation — MIR → Zig translation (codegen reads MirNode, not AST)
    ↓
12. Zig Compiler — produce final binary
```

### Incremental compilation
Checked at step 3. Pass 4 (declaration collection) always runs so cross-module type resolution works for all modules. Unchanged modules with unchanged dependencies skip passes 5–12, reusing cached `.zig` files. Cache stored in `.orh-cache/`.

Two layers of cache invalidation:
- **Semantic hashing** — token-stream hashing skips whitespace and comments. Touching a file without changing code does not trigger recompilation.
- **Interface diffing** — public DeclTable hashing. When an upstream module's implementation changes but its public API stays the same, downstream importers skip recompilation.

---

## Backend

Zig 0.15.2 is the single backend. Generated Zig code is readable and debuggable. `compt` maps to Zig's comptime. Cross-compilation, linking, and optimization are all handled by Zig.

### Codegen philosophy (v0.4.0+)
The codegen is a **pure 1:1 translator** — it maps Orhon syntax to Zig syntax with no domain knowledge of library types or methods. All stdlib functionality (collections, strings, allocators, etc.) lives in Zig modules (`.zig` files in `src/std/`), not in the codegen. This means adding new stdlib features never requires compiler changes.

### No runtime libraries (v0.9.6+)
The compiler does **not** inject hardcoded runtime imports. All standard library functionality is accessed through the normal `import`/`use` system:
- `import std::collections` — scoped access: `collections.List(i32).new()`
- `use std::collections` — names in current scope: `List(i32).new()`

The codegen has no special-case name mapping for any library types. The only hardcoded import is Zig's own `std`. Nullable and error union types are language-level constructs handled by the codegen directly, not through runtime libraries.

### Zig discovery
1. Same directory as orhon binary (portable)
2. Global PATH (system installed)

---

## Zig-as-Module System

Orhon interacts with Zig through the zig-as-module system. Any `.zig` file placed in `src/` automatically becomes an Orhon module — the compiler auto-converts it. No special declarations or keywords needed.

### Type mapping rules
- `T` (by value) — moves across the boundary
- `const& T` — read-only borrow, both directions
- `mut& T` (mutable ref) — **not allowed** across the boundary (except `self` on struct methods)
- Default arguments on Zig module funcs are filled at the call site by the codegen

See [[14-zig-bridge]] for full documentation.

---

## Project Structure

Hub-and-spoke pattern — large passes split into hub + satellite files. Tests are Zig `test` blocks in each file.

```
src/
    main.zig                // entry point, CLI dispatch, allocator setup
    cli.zig                 // command-line argument parsing (CliArgs, Command, BuildTarget)
    pipeline.zig            // hub — compilation pipeline orchestration (runPipeline)
    pipeline_passes.zig     //   satellite — per-module pass execution (passes 5–12)
    pipeline_build.zig      //   satellite — build helpers and tests
    commands.zig            // secondary command runners (analysis, debug, gendoc, addtopath)
    init.zig                // orhon init project scaffolding
    lexer.zig               // pass 1
    parser.zig              // AST type definitions (Node, NodeKind, structs)
    peg.zig                 // public PEG API
    peg/                    // PEG engine
        orhon.peg           //   PEG grammar (formal syntax spec)
        grammar.zig         //   .peg file parser
        engine.zig          //   packrat matching engine
        capture.zig         //   capture tree builder
        builder.zig         //   hub — capture tree → AST node conversion
        builder_decls.zig   //   declaration building
        builder_exprs.zig   //   expression building
        builder_stmts.zig   //   statement building
        builder_types.zig   //   type building
        token_map.zig       //   grammar literals → TokenKind mapping
    module.zig              // hub — pass 3 (module resolution)
    module_parse.zig        //   satellite — module parsing and dependency scanning
    declarations.zig        // pass 4
    resolver.zig            // hub — pass 5 (type resolution)
    resolver_exprs.zig      //   satellite — expression type resolution
    resolver_validation.zig //   satellite — type validation and match exhaustiveness
    sema.zig                // shared — SemanticContext for passes 5–9
    ownership.zig           // hub — pass 6
    ownership_checks.zig    //   satellite — statement and expression ownership checks
    borrow.zig              // hub — pass 7
    borrow_checks.zig       //   satellite — statement and expression borrow checks
    propagation.zig         // pass 8 (error propagation)
    mir/                    // pass 10 — MIR annotation + lowering
        mir.zig             //   hub — re-exports (TypeClass, NodeMap, MirNode, etc.)
        mir_types.zig       //   type classification (TypeClass enum, Coercion)
        mir_node.zig        //   MIR tree node definitions (MirKind, MirNode)
        mir_annotator.zig   //   annotation pass (type analysis)
        mir_annotator_nodes.zig // satellite — AST annotation and coercion detection
        mir_lowerer.zig     //   lowering pass (tree construction)
        mir_registry.zig    //   union/struct registry for type tracking
    codegen/                // pass 11 — pure 1:1 translator
        codegen.zig         //   hub — main code generation (MIR → Zig)
        codegen_decls.zig   //   declaration codegen (structs, enums, functions)
        codegen_exprs.zig   //   expression codegen
        codegen_stmts.zig   //   statement codegen
        codegen_match.zig   //   match expression codegen
        codegen_unions.zig  //   shared _unions.zig file emitter
    zig_runner/             // pass 12
        zig_runner.zig      //   hub — main entry point
        zig_runner_build.zig    //   build invocation and multi-target support
        zig_runner_discovery.zig //  Zig compiler discovery (PATH lookup)
        zig_runner_multi.zig    //   multi-target build coordination
    types.zig               // shared — type system (Primitive enum, ResolvedType)
    errors.zig              // shared — error formatting
    builtins.zig            // shared — language intrinsics only
    constants.zig           // shared — constants
    cache.zig               // shared — incremental cache
    scope.zig               // shared — scope tracking for ownership/borrow passes
    zig_module.zig          // zig-as-module auto-conversion
    interface.zig           // public interface generation for library modules
    std_bundle.zig          // embedded stdlib file extraction
    formatter.zig           // orhon fmt
    docgen.zig              // orhon gendoc — project API docs from /// comments
    syntaxgen.zig           // orhon gendoc — syntax reference from embedded grammar
    zig_docgen.zig          // orhon gendoc — stdlib reference from .zig pub declarations
    fuzz.zig                // standalone fuzzer binary
    lsp/                    // language server
        lsp.zig             //   hub — JSON-RPC transport, server loop
        lsp_types.zig       //   LSP data structures
        lsp_json.zig        //   JSON serialization/deserialization
        lsp_analysis.zig    //   AST analysis for LSP features
        lsp_nav.zig         //   go-to-definition, find references
        lsp_edit.zig        //   text editing operations
        lsp_view.zig        //   document view/hover information
        lsp_semantic.zig    //   semantic highlighting
        lsp_utils.zig       //   utility functions
    std/                    // Zig implementations for stdlib modules
```

---

## Fuzz Testing

The compiler has two fuzz testing mechanisms: Zig's built-in `std.testing.fuzz` framework for the lexer and parser, run via `zig build test`, and a standalone fuzz harness (`src/fuzz.zig`) that runs 50,000 iterations with multiple input strategies via `zig build fuzz`.

### Built-in fuzz tests

These tests use Zig's `std.testing.fuzz` API and are run as part of the normal unit test suite:

- **`src/lexer.zig` — "fuzz lexer":** Feeds arbitrary byte sequences through the lexer's `next()` method one token at a time, verifying the lexer always reaches EOF without panicking regardless of input content.
- **`src/peg.zig` — "fuzz parser":** Lexes arbitrary input, then runs the PEG engine's `matchAll("program")` on the resulting token stream. Verifies the parser never panics or crashes on random or malformed token streams. A parse failure (match returning false) is expected and normal — only panics are failures.

Run with:

```
zig build test
```

### Standalone fuzz harness

Location: `src/fuzz.zig`

Runs 50,000 iterations. Each iteration generates an input buffer using one of five strategies, lexes it, and runs the PEG parser. Tracks per-outcome counts (lex-only, parse-ok, parse-err) and reports a crash count at the end.

**Input strategies:**

| Strategy | Description |
|----------|-------------|
| 0 | Pure random bytes — maximum entropy, tests lexer resilience |
| 1 | Printable ASCII and operator characters — realistic character distributions |
| 2 | Orhon token fragments assembled randomly — keyword/operator soup |
| 3 | Valid module prefix (`module test\n`) followed by random alphanumeric body |
| 4 | Semi-valid program structures (module + func/struct/enum/import templates) followed by random filler — exercises deeper parser paths |

Run with:

```
zig build fuzz
```

Output example:

```
=== Fuzz Results ===
  iterations: 50000
  passed:     50000
  lex-only:   0
  parse ok:   53
  parse err:  49947
  crashes:    0
```
