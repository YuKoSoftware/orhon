# Orhon — Compiler Internals

---

## Compilation Pipeline

Each pass runs only if the previous succeeded. Multiple errors per pass are collected before stopping.

```
Source (.orh)
    ↓
1.  Lexer           — raw text → tokens
    ↓
2.  PEG Parser      — tokens → AST (grammar-driven, src/orhon.peg)
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
8.  Thread Safety Analysis
    ↓
9.  Error Propagation Analysis
    ↓
10. MIR Annotation + Lowering — self-contained MIR tree (TypeClass, UnionRegistry, MirNode)
    ↓
11. Zig Code Generation — MIR → Zig translation (codegen reads MirNode, not AST)
    ↓
12. Zig Compiler — produce final binary
```

### Incremental compilation
Checked at step 3. Unchanged modules with unchanged dependencies skip passes 4-12, reusing cached `.zig` files. Cache stored in `.orh-cache/`.

---

## Backend

Zig 0.15.2 is the single backend. Generated Zig code is readable and debuggable. `compt` maps to Zig's comptime. Cross-compilation, linking, and optimization are all handled by Zig.

### Codegen philosophy (v0.4.0+)
The codegen is a **pure 1:1 translator** — it maps Orhon syntax to Zig syntax with no domain knowledge of library types or methods. All stdlib functionality (collections, strings, allocators, etc.) lives in bridge modules (module + `.zig` sidecar), not in the codegen. This means adding new stdlib features never requires compiler changes.

### No runtime libraries (v0.9.6+)
The compiler does **not** inject hardcoded runtime imports. All standard library functionality is accessed through the normal `import`/`include` bridge system:
- `import std::collections` — scoped access: `collections.List(i32).new()`
- `include std::collections` — names in current scope: `List(i32).new()`

The codegen has no special-case name mapping for any library types. The only hardcoded import is Zig's own `std`. Nullable and error union types are language-level constructs handled by the codegen directly, not through runtime libraries.

### Zig discovery
1. Same directory as orhon binary (portable)
2. Global PATH (system installed)

---

## Bridge System

Orhon interacts with Zig through the bridge. A module declares its interface using `bridge`, and a paired `.zig` sidecar provides the implementation. The codegen re-exports from the sidecar — no special cases.

### Bridge safety rules
- `T` (by value) — moves across the bridge
- `const &T` — read-only borrow, both directions
- `&T` (mutable ref) — **not allowed** across the bridge (except `self` on bridge struct methods)
- Default arguments on bridge funcs are filled at the call site by the codegen

See [14-zig-bridge.md](14-zig-bridge.md) for full documentation.

---

## Project Structure

One file per pipeline pass. Tests are Zig `test` blocks in each file.

```
src/
    main.zig                // entry point, CLI, orchestrator
    lexer.zig               // pass 1
    orhon.peg               // pass 2  — PEG grammar (formal syntax spec)
    parser.zig              // AST type definitions (Node, NodeKind, structs)
    peg/                    // PEG engine
        grammar.zig         //   .peg file parser
        engine.zig          //   packrat matching engine
        capture.zig         //   capture tree builder
        builder.zig         //   capture tree → AST node conversion
        token_map.zig       //   grammar literals → TokenKind mapping
    module.zig              // pass 3
    declarations.zig        // pass 4
    resolver.zig            // pass 5
    sema.zig                // shared — SemanticContext for passes 6–9
    ownership.zig           // pass 6
    borrow.zig              // pass 7
    thread_safety.zig       // pass 8
    propagation.zig         // pass 9
    mir.zig                 // pass 10 — MIR annotation + lowering (MirNode tree, TypeClass, UnionRegistry)
    codegen.zig             // pass 11 — pure 1:1 translator
    zig_runner.zig          // pass 12
    types.zig               // shared — type system (Primitive enum, ResolvedType)
    errors.zig              // shared — error formatting
    builtins.zig            // shared — language intrinsics only
    constants.zig           // shared — constants
    cache.zig               // shared — incremental cache
    formatter.zig           // orhon fmt
    lsp.zig                 // language server
    std/                    // stdlib bridge modules (module + .zig sidecar)
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
