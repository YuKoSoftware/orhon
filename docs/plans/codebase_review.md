# Orhon Compiler — Full Codebase Review Plan

## Overview

- **Total files**: ~106 (`.zig` + `.peg` + `.orh`)
- **Total lines**: ~35,000
- **Review chunks**: 15
- **Ordering**: Chunks 1–10 follow compiler pipeline order; Chunks 11–15 cover tooling and support

Each chunk is self-contained and can be reviewed independently by a code-quality agent.

---

## Chunk 1: Entry Point, CLI, and Commands

**Purpose**: Program entry, argument parsing, command dispatch, project scaffolding.

**Files**:
- `src/main.zig`
- `src/cli.zig`
- `src/commands.zig`
- `src/init.zig`
- `src/constants.zig`

**Complexity**: Small

**Review focus**:
- CLI argument parsing and validation correctness
- Error handling and user-facing messages
- All commands handled

---

## Chunk 2: Lexer

**Purpose**: Tokenization of Orhon source into a token stream.

**Files**:
- `src/lexer.zig`

**Complexity**: Medium

**Review focus**:
- Token type completeness
- Edge cases in string/number/identifier lexing
- Error recovery on malformed input

---

## Chunk 3: PEG Parser Engine and Grammar

**Purpose**: PEG parsing engine, grammar definition, AST builder.

**Files**:
- `src/peg.zig` — hub
- `src/peg/engine.zig`
- `src/peg/grammar.zig`
- `src/peg/capture.zig`
- `src/peg/token_map.zig`
- `src/peg/builder.zig` — hub
- `src/peg/builder_decls.zig`
- `src/peg/builder_exprs.zig`
- `src/peg/builder_stmts.zig`
- `src/peg/builder_types.zig`
- `src/peg/orhon.peg`

**Complexity**: Large

**Review focus**:
- Grammar completeness and ambiguity
- Engine correctness: memoization, backtracking
- Builder fidelity: correct AST node shape per capture
- Consistency between grammar rules and builder dispatch

---

## Chunk 4: Parser and AST Types

**Purpose**: AST node definitions, source location tracking.

**Files**:
- `src/parser.zig`

**Complexity**: Medium

**Review focus**:
- AST node completeness (every language construct has a variant)
- Public API surface for downstream passes

---

## Chunk 5: Module Resolution and Pipeline Orchestration

**Purpose**: Multi-file module discovery, import scanning, dependency ordering, pipeline driver.

**Files**:
- `src/module.zig`
- `src/module_parse.zig`
- `src/pipeline.zig`
- `src/pipeline_passes.zig`
- `src/pipeline_build.zig`
- `src/scope.zig`

**Complexity**: Large

**Review focus**:
- Circular import detection
- Topological sort correctness
- Incremental cache integration
- Multi-file module merging (file offsets, AST concatenation)
- Scope data structures

---

## Chunk 6: Declaration Collection

**Purpose**: Pass 4 — collects top-level declarations into tables.

**Files**:
- `src/declarations.zig`
- `src/interface.zig`

**Complexity**: Medium

**Review focus**:
- All declaration kinds collected
- Cross-module declaration table population
- Name collision detection

---

## Chunk 7: Type Resolution and Semantic Analysis

**Purpose**: Pass 5 — resolves types, shared semantic context for passes 5–9.

**Files**:
- `src/sema.zig`
- `src/resolver.zig`
- `src/resolver_exprs.zig`
- `src/resolver_validation.zig`

**Complexity**: Large

**Review focus**:
- Type inference correctness (generics, optionals, error unions)
- Cross-module type resolution
- Validation completeness
- Type map population — every expression gets a resolved type

---

## Chunk 8: Ownership, Borrow Checking, and Error Propagation

**Purpose**: Passes 6–8 — memory safety analysis.

**Files**:
- `src/ownership.zig`
- `src/ownership_checks.zig`
- `src/borrow.zig`
- `src/borrow_checks.zig`
- `src/propagation.zig`

**Complexity**: Large

**Review focus**:
- Move vs copy semantics, use-after-move detection
- Borrow rules: mutual exclusion of mutable borrows
- Error propagation analysis
- False positive/negative rates

---

## Chunk 9: MIR Annotation and Lowering

**Purpose**: Pass 10 — annotates AST with type metadata, lowers to MIR tree.

**Files**:
- `src/mir/mir.zig` — hub
- `src/mir/mir_types.zig`
- `src/mir/mir_node.zig`
- `src/mir/mir_registry.zig`
- `src/mir/mir_annotator.zig`
- `src/mir/mir_annotator_nodes.zig`
- `src/mir/mir_lowerer.zig`

**Complexity**: Large

**Review focus**:
- Annotator completeness: every AST node kind annotated
- MIR node type coverage vs AST node types
- Lowering fidelity
- Union registry correctness

---

## Chunk 10: Code Generation

**Purpose**: Pass 11 — generates Zig source from MIR tree.

**Files**:
- `src/codegen/codegen.zig` — hub
- `src/codegen/codegen_decls.zig`
- `src/codegen/codegen_exprs.zig`
- `src/codegen/codegen_stmts.zig`
- `src/codegen/codegen_match.zig`

**Complexity**: Large

**Review focus**:
- Generated Zig correctness
- Match/pattern codegen (largest satellite)
- Import generation
- Memory management in generated code
- String escaping, identifier mangling

---

## Chunk 11: Zig Runner and Build System

**Purpose**: Pass 12 — invokes Zig compiler, build script generation, toolchain discovery.

**Files**:
- `src/zig_runner/zig_runner.zig` — hub
- `src/zig_runner/zig_runner_build.zig`
- `src/zig_runner/zig_runner_multi.zig`
- `src/zig_runner/zig_runner_discovery.zig`

**Complexity**: Medium

**Review focus**:
- Build script correctness
- Multi-module linking
- Zig toolchain discovery across platforms
- Error forwarding from Zig compiler

---

## Chunk 12: Zig Module Interop and Caching

**Purpose**: Discovers `.zig` files, converts public API to `.orh` declarations, manages compilation cache.

**Files**:
- `src/zig_module.zig`
- `src/cache.zig`
- `src/std_bundle.zig`

**Complexity**: Large

**Review focus**:
- Zig-to-Orhon declaration conversion accuracy
- Cache invalidation correctness
- Embedded stdlib extraction
- File I/O error handling

---

## Chunk 13: LSP Server

**Purpose**: Language Server Protocol for editor integration.

**Files**:
- `src/lsp/lsp.zig` — hub
- `src/lsp/lsp_types.zig`
- `src/lsp/lsp_json.zig`
- `src/lsp/lsp_utils.zig`
- `src/lsp/lsp_nav.zig`
- `src/lsp/lsp_view.zig`
- `src/lsp/lsp_edit.zig`
- `src/lsp/lsp_analysis.zig`
- `src/lsp/lsp_semantic.zig`

**Complexity**: Large

**Review focus**:
- LSP protocol compliance
- Feature completeness (hover, goto-def, completion, diagnostics)
- Error resilience on malformed requests
- Memory management: document lifecycle

---

## Chunk 14: Developer Tools, Generators, and Shared Infrastructure

**Purpose**: Formatter, doc generators, fuzzer, shared types/errors/builtins, templates.

**Files**:
- `src/types.zig`
- `src/builtins.zig`
- `src/errors.zig`
- `src/formatter.zig`
- `src/docgen.zig`
- `src/syntaxgen.zig`
- `src/zig_docgen.zig`
- `src/fuzz.zig`
- `src/templates/project.orh`
- `src/templates/example/*.orh` (7 files)

**Complexity**: Medium

**Review focus**:
- `types.zig` / `builtins.zig` / `errors.zig`: completeness, consistency, clear API boundaries
- Formatter idempotency
- Doc generators: output correctness for all declaration kinds
- Templates: compile correctly, cover all language features

---

## Chunk 15: Standard Library Implementations

**Purpose**: Zig implementations of Orhon's stdlib modules, embedded and extracted at build time.

**Files** (28+ `.zig` files in `src/std/`):
- `allocator.zig`, `bitfield.zig`, `collections.zig`, `compression.zig`
- `console.zig`, `crypto.zig`, `csv.zig`, `encoding.zig`
- `fs.zig`, `http.zig`, `ini.zig`, `json.zig`
- `math.zig`, `net.zig`, `ptr.zig`, `random.zig`
- `regex.zig`, `simd.zig`, `sort.zig`, `stream.zig`
- `string.zig`, `system.zig`, `testing.zig`, `thread.zig`
- `time.zig`, `toml.zig`, `tui.zig`, `xml.zig`, `yaml.zig`

**Complexity**: Large (breadth)

**Review focus**:
- API consistency across modules (naming, error handling patterns)
- Memory safety: correct allocator usage, no leaks
- Correctness of parsers (`regex`, `yaml`, `toml`, `xml`)
- Thread safety in `thread.zig`

---

## Summary

| #  | Chunk                              | Complexity | Pipeline    |
|----|------------------------------------|------------|-------------|
| 1  | Entry Point, CLI, Commands         | Small      | —           |
| 2  | Lexer                              | Medium     | Pass 1      |
| 3  | PEG Parser Engine & Grammar        | Large      | Pass 2      |
| 4  | Parser and AST Types               | Medium     | Pass 2      |
| 5  | Module Resolution & Pipeline       | Large      | Pass 3      |
| 6  | Declaration Collection             | Medium     | Pass 4      |
| 7  | Type Resolution & Sema             | Large      | Pass 5      |
| 8  | Ownership, Borrow, Propagation     | Large      | Passes 6–8  |
| 9  | MIR Annotation & Lowering          | Large      | Pass 10     |
| 10 | Code Generation                    | Large      | Pass 11     |
| 11 | Zig Runner & Build System          | Medium     | Pass 12     |
| 12 | Zig Module Interop & Caching       | Large      | Cross-cut   |
| 13 | LSP Server                         | Large      | Independent |
| 14 | Dev Tools, Generators, Templates   | Medium     | Independent |
| 15 | Standard Library Implementations   | Large      | Independent |

## Recommended Review Order

1. **Chunk 1** — fast orientation
2. **Chunks 2–4** — front-end, establishes AST shape
3. **Chunk 5** — orchestration, pass sequencing
4. **Chunks 6–10** — core compiler passes in pipeline order
5. **Chunks 11–12** — back-end and build system
6. **Chunk 13** — LSP (can run in parallel with anything)
7. **Chunks 14–15** — tools and stdlib (can run in parallel)
