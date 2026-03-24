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
10. MIR Annotation — typed annotation pass (TypeClass, UnionRegistry, NodeMap)
    ↓
11. Zig Code Generation — pure 1:1 AST → Zig translation
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
    ownership.zig           // pass 6
    borrow.zig              // pass 7
    thread_safety.zig       // pass 8
    propagation.zig         // pass 9
    mir.zig                 // pass 10 — typed annotation pass (TypeClass, NodeMap, UnionRegistry)
    codegen.zig             // pass 11 — pure 1:1 translator
    zig_runner.zig          // pass 12
    types.zig               // shared — type system
    errors.zig              // shared — error formatting
    builtins.zig            // shared — language intrinsics only
    constants.zig           // shared — constants
    cache.zig               // shared — incremental cache
    formatter.zig           // orhon fmt
    lsp.zig                 // language server
    std/                    // stdlib bridge modules (module + .zig sidecar)
```
