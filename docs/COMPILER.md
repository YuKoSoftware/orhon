# Kodr — Compiler Internals

---

## 1. Compiler Architecture

### Design philosophy
Keep the compiler implementation as simple as possible. Get correctness first, optimize later. Sequential passes are easier to implement, debug, and extend than complex parallel or interleaved designs. Parallelism can be added later without changing the architecture.

### Development phases

**Phase 1 — barebones compiler:**
Get a simple `func main() void { }` compiling to a working binary as fast as possible. Everything else builds on this foundation.

Priority order:
1. Lexer — tokenize Kodr source
2. Parser — build AST
3. Module resolution — group files, detect circular imports
4. Basic type checking — validate explicit types
5. Basic codegen — emit valid Zig for simple programs
6. Zig runner — invoke Zig, capture output

At this point you have a working compiler for simple Kodr programs. Test with Zig's own `test` blocks in each `.zig` source file — no Kodr test blocks yet.

**Phase 2 — safety passes:**
7. Ownership and move analysis
8. Borrow checking
9. Thread safety analysis
10. Error propagation analysis
11. Compt and type resolution — full generic support

**Phase 3 — language features:**
12. `test` block support — `kodr test` becomes available
13. Full pointer types — `Ptr(T)`, `RawPtr(T)`, `VolatilePtr(T)`
14. Full error system — debug traces, release stripping
15. Incremental compilation — timestamp cache

**Phase 4 — stdlib:**
16. Write stdlib in Kodr — once compiler is stable enough
17. Add modules phase by phase following the planned roadmap

The `test` keyword and `assert` builtin are phase 3 features — implemented after the compiler can already compile real Kodr programs. Kodr test blocks require the full pipeline to work before they can run.

### Compilation pipeline
Each pass runs only if the previous succeeded. First error stops compilation with a clear message. Where possible, multiple errors per pass are collected before stopping — so the programmer sees several issues at once rather than fixing one at a time.

```
Source (.kodr)
    ↓
1.  Lexer
    — raw text → tokens

    ↓
2.  Parser
    — tokens → AST

    ↓
3.  Module Resolution
    — group files by module name
    — build dependency graph
    — detect circular imports — hard error
    — check incremental cache — skip unchanged modules entirely
    — check timestamp of each file against .kodr-cache

    ↓
4.  Declaration Pass
    — collect all type names, function signatures, struct definitions
    — does not resolve bodies yet
    — solves chicken-and-egg between compt and type checking
    — after this pass the compiler knows every type exists

    ↓
5.  Compt & Type Resolution  (interleaved single pass)
    — resolve compt functions and type check simultaneously
    — compt results feed back into type resolution
    — resolve all any to concrete types
    — hard error if any cannot be resolved at compile time

    ↓
6.  Ownership & Move Analysis
    — track ownership transfers
    — catch use-after-move
    — validate struct atomicity — no partial field moves

    ↓
7.  Borrow Checking
    — validate const &T and &T borrows
    — no simultaneous mutable and immutable borrows
    — lexical lifetime enforcement

    ↓
8.  Thread Safety Analysis
    — ensure values moved into threads not used after spawn
    — validate splitAt usage for shared data

    ↓
9.  Error Propagation Analysis
    — verify all (Error | T) unions are handled or propagatable
    — verify all (null | T) unions are handled before scope exit
    — verify enclosing function returns Error union when propagation needed

    ↓
10. MIR Generation
    — simple SSA-based intermediate representation

    ↓
11. Zig Code Generation
    — emit readable Zig code
    — strip trace metadata for release builds
    — keep error messages for release builds

    ↓
12. Zig Compiler
    — produce final binary
    — cross-compilation supported out of the box
```

### Incremental compilation
Checked at step 3 — Module Resolution. If a module's files are unchanged since last build AND none of its dependencies have changed, passes 4-12 are skipped entirely for that module. The dependency graph built in step 3 determines what needs recompilation. Cache stored in `.kodr-cache/`.

### Parallel compilation (future optimization)
After step 5, each module's passes 6-12 are independent and can run in parallel. Since circular imports are banned, the dependency graph is a DAG — modules with no interdependencies can compile simultaneously. Not implemented in v1 — correctness first.

### MIR instruction set
```
ALLOC, MOVE, BORROW, MUT_BORROW, DROP, CALL, LOAD, STORE
```

### Compiler implementation
The Kodr compiler is written in Zig 0.15.2. It compiles to a single static binary with no runtime dependencies. Zig's standard library provides everything needed — file IO, process spawning, string handling, allocators.

Writing the compiler in Zig specifically reduces implementation work significantly:

- `std.ArrayList` — token lists, AST nodes, MIR instructions
- `std.StringHashMap` — symbol tables, module registries, type tables
- `std.AutoHashMap` — ownership tracking, borrow state, thread safety maps
- `std.heap.ArenaAllocator` — AST allocation, allocate fast, free entire tree at once
- `std.mem.Allocator` — same allocator model as Kodr itself
- Tagged unions — natural representation for AST nodes and MIR instructions
- Zig comptime — generate repetitive compiler code, visitor patterns, type checking rules
- `std.fs` — file scanning, reading, timestamp checking — incremental cache almost free
- `std.ChildProcess` — invoke Zig compiler, capture stdout/stderr for `-verbose` flag
- `std.fmt` — Zig code generation is essentially formatted string output

### `std.zig` — reference implementation
Zig's standard library contains its own compiler frontend under `std.zig`:

- `std.zig.Tokenizer` — full tokenizer with token tags and source locations
- `std.zig.parse()` — full parser returning an `std.zig.Ast`
- `std.zig.Ast` — AST type with nodes, tokens, and extra data using `MultiArrayList` for cache friendly memory layout

**What we cannot reuse directly:**
- `std.zig.Tokenizer` — tokenizes Zig syntax. Kodr has different keywords, operators, and grammar. Must write our own.
- `std.zig.parse()` and `std.zig.Ast` — parses Zig grammar. Kodr's grammar is different. Must write our own.

**What we can reuse directly:**
- The architecture pattern — state machine tokenizer, clean and efficient
- `MultiArrayList` for cache friendly flattened AST node storage — nodes are indices into arrays, not pointers. Faster, more cache friendly, less memory overhead
- Arena allocator for entire AST — allocate fast, free the whole tree at once when done
- Per file incremental caching pattern — skip tokenization and parsing entirely for unchanged files

**The key benefit:**
The hard part of writing a tokenizer and parser is not the lines of code — it is figuring out the right architecture. `std.zig` hands that to us on a silver platter. Our lexer and parser will be shorter, faster, and more correct by following these patterns than if we designed from scratch.

Study `std.zig` before implementing `lexer.zig` and `parser.zig` — it will save significant design time and prevent architectural mistakes.

### Estimated size
Kodr is a deliberately simple language — no lifetime annotations, no trait system, no macro system, no operator overloading, no implicit conversions, no complex generics. Combined with Zig's standard library handling infrastructure and `std.zig` architecture patterns guiding the lexer and parser design, the compiler is small:

| Component | Estimated lines | Notes |
|-----------|----------------|-------|
| Lexer | 200-300 | std.zig architecture patterns |
| Parser + AST | 500-700 | MultiArrayList, arena allocator pattern |
| Module Resolution | 200-300 | std.StringHashMap, std.fs |
| Declaration Pass | 150-200 | reuses module resolution data |
| Compt & Type Resolution | 1,000-1,500 | most complex single component |
| Ownership & Move Analysis | 600-900 | simpler than Rust — no partial moves |
| Borrow Checker | 400-600 | lexical only — much simpler than Rust |
| Thread Safety Analysis | 200-300 | focused, well defined rules |
| Error Propagation Analysis | 200-300 | scope stack, simple to implement |
| MIR Generation | 400-600 | tagged unions, ArrayList |
| Zig Code Generation | 500-800 | std.fmt, string output |
| Error System & Diagnostics | 200-300 | debug vs release |
| Incremental Cache | 100-150 | std.fs, timestamps file |
| Builtins & Stdlib Bindings | 350-500 | lookup table in codegen |
| CLI | 100-150 | argument parsing |
| **Total** | **3,500-5,500** | |

For context — TinyCC is ~15,000 lines, Lua's interpreter is ~30,000 lines. Kodr's compiler is roughly a quarter of TinyCC's size.

**The reduction from std.zig patterns is not primarily in lines of code — it is in design work and architectural correctness.** The tokenizer and parser will be written faster, with fewer bugs, and with better performance by following `std.zig`'s proven approach.

**Timeline estimate:**
- Working prototype — 2-4 months for a dedicated developer
- Solid v1 — under a year

### Backend
Zig 0.15.2 is the single backend. What this saves:
- Code generation for every platform — free, Zig handles x64, ARM, WASM, RISC-V
- Cross-compilation — completely free
- Linking — Zig bundles its own linker
- Optimization — passes through to LLVM, -O2, -O3, LTO all free
- C interop — Zig handles C ABI, calling conventions, struct layouts
- Platform specific details — system calls, OS APIs, ABI differences

Generated Zig code is readable and debuggable. `compt` maps naturally to Zig's comptime. No direct LLVM complexity.

### Zig discovery
The Kodr compiler finds Zig automatically. Lookup order:

1. **Same directory as kodr binary** — portable, standalone, no installation needed
2. **Global PATH** — standard system installation

```
// lookup order
1. kodrBinaryPath/zig    // portable — place zig next to kodr
2. PATH/zig              // system installed
```

**Portable usage** — place zig binary next to kodr, no installation needed:
```
my_project/
    kodr        // kodr compiler binary
    zig         // zig binary right next to it
    main.kodr
    src/
```

**System installed** — both binaries in PATH:
```
/usr/local/bin/kodr
/usr/local/bin/zig
```

If Zig is not found in either location, a friendly actionable error is shown:
```
ERROR: zig compiler not found
  place zig binary (v0.15.2) next to kodr, or install zig globally
  download zig at: https://ziglang.org/download
```

### Debug vs release code generation
```
kodr build             // debug — full error trace metadata
kodr build -fast       // max speed — trace stripped, messages kept
kodr build -small      // min binary size — trace stripped, messages kept
kodr build -verbose    // show raw Zig compiler output — compiler dev mode only
```

### Zig output
The Zig compiler runs silently. Its output is fully captured — never shown to the user unless `-verbose` is passed. In a correctly implemented compiler, Zig errors should never reach the user since all issues are caught in passes 1-9 before code generation.

---

## 2. Compiler Project Structure

One file per pipeline pass. Related types are co-located with the pass that owns them. `main.zig` is an orchestrator only — no business logic. Tests mirror source structure.

Following `std.zig`'s patterns:
- AST types live in `parser.zig` — tightly coupled to how the parser builds them
- MIR types live in `mir.zig` — tightly coupled to generation logic
- CLI parsing lives in `main.zig` — too small to justify its own file
- Arena allocator used for AST — fast allocation, free entire tree at once

```
kodr/
    build.zig                   // Zig build file for the compiler itself
    build.zig.zon               // Zig package manifest

    src/
        main.zig                // entry point + CLI + tests
        lexer.zig               // pass 1  — tokenizer + tests
        parser.zig              // pass 2  — parser + AST types + tests
        module.zig              // pass 3  — module resolution + tests
        declarations.zig        // pass 4  — collect type names + tests
        resolver.zig            // pass 5  — compt and type resolution + tests
        ownership.zig           // pass 6  — ownership and move analysis + tests
        borrow.zig              // pass 7  — borrow checking + tests
        thread_safety.zig       // pass 8  — thread safety analysis + tests
        propagation.zig         // pass 9  — error and null propagation + tests
        mir.zig                 // pass 10 — MIR types + generation + tests
        codegen.zig             // pass 11 — Zig source generation + tests
        zig_runner.zig          // pass 12 — invoke Zig compiler + tests
        types.zig               // shared — Kodr type system + tests
        errors.zig              // shared — error formatting + tests
        builtins.zig            // shared — builtin types + tests
        cache.zig               // shared — cache management + tests
```

**17 source files — tests embedded in each file — no separate test directory**

Tests are written as Zig `test` blocks directly in the file they belong to. Zig's test runner finds and runs all test blocks automatically with `zig build test`. This is how Zig's own stdlib is structured.

```zig
// example — tests inside lexer.zig
pub fn tokenize(source: []const u8) !TokenList { ... }

test "tokenizes keywords correctly" {
    const tokens = try tokenize("func main() void {}");
    // assertions
}

test "tokenizes string literals" {
    const tokens = try tokenize(""hello world"");
    // assertions
}
```

### File responsibilities

**`main.zig`** — CLI argument parsing, calls passes in order, handles overall flow. No business logic. Entry point for `kodr build`, `kodr run`, `kodr test`.

**Pipeline passes** — each file owns exactly one pass plus its directly related types. Never imports another pass directly — only imports from shared files.

**`parser.zig`** — owns both the parser logic and AST node type definitions. Uses `std.MultiArrayList` for cache friendly flattened node storage. Uses `std.heap.ArenaAllocator` — entire AST freed in one call when done.

**`mir.zig`** — owns both MIR instruction type definitions and MIR generation logic. Tagged unions for instruction types.

**`types.zig`** — Kodr's type system representation. Shared across declarations, resolver, ownership, borrow, and codegen passes.

**`errors.zig`** — single source of truth for all error formatting. Every pass uses it. Emits full trace in debug, message only in release.

**`builtins.zig`** — compiler knowledge of all builtin types and their Zig equivalents. Used by resolver and codegen. Contains the lookup table mapping Kodr builtins to generated Zig code.

**`cache.zig`** — reads and writes `timestamps` and `deps.graph`. Uses `std.fs.File.stat()` for timestamps. Determines which modules need recompilation at pass 3.
