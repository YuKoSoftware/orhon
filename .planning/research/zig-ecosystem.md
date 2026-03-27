# Zig Ecosystem Research for Orhon Compiler

**Researched:** 2026-03-27
**Overall confidence:** MEDIUM (limited to codebase analysis + training data; WebSearch/WebFetch unavailable)

---

## 1. Zig as a Compilation Target — Languages That Transpile to Zig

### Known Projects (as of training data, May 2025)

The "transpile to Zig" space is extremely small compared to "compile to C", "compile to LLVM IR", or "compile to JavaScript". Zig is a niche target because it has its own rich type system, ownership semantics, and comptime — making it both powerful and constraining.

**Known projects:**

| Project | Approach | Status | Notes |
|---------|----------|--------|-------|
| **Aro** | C compiler written in Zig | Active | Not a transpiler — compiles C to Zig's IR. Included in Zig's build system. Shows how a compiler can integrate with Zig's toolchain. |
| **Buzz** | Bytecode-compiled language | Active | Uses Zig as implementation language, not target. Shows Zig for compiler internals. |
| **C2Zig** / `zig translate-c` | C-to-Zig translator | Built-in | Zig's own `translate-c` is the canonical example of generating Zig source. Produces readable (if verbose) Zig. |
| **Orhon** | Transpiler to Zig | Active | This project. The most complete "language-to-Zig-source" transpiler I'm aware of. |
| **Various hobby projects** | Lisps, custom DSLs | Mostly abandoned | GitHub has scattered repos attempting to compile custom languages to Zig source. None have reached maturity. |

**Confidence: LOW** — I cannot verify current status without web access. The list may be incomplete.

### Patterns Used by Transpilers Targeting Zig

From studying `translate-c` and Orhon's own codebase:

**Error union mapping:** Transpilers map their error model to Zig's `anyerror!T`. Orhon does this well — `(Error | T)` maps directly to `anyerror!T`, `Error("msg")` to `error.msg_sanitized`. This is the cleanest approach because it leverages Zig's error handling natively rather than fighting it.

**Optional mapping:** `(null | T)` to `?T` is the right call. Any other approach (tagged unions, sentinel values) fights Zig's type system.

**Comptime mapping:** Orhon's `compt` to Zig's `comptime` is a natural 1:1 mapping. This is the single biggest advantage of targeting Zig over C — compile-time evaluation without preprocessor hacks.

**Allocator passing:** The generated code needs to know which allocator to use. Orhon solved this with `.new(alloc)` defaulting to SMP. This matches Zig community conventions — explicit allocator passing, no hidden globals.

**Key insight:** Orhon appears to be pioneering territory here. There is no established "best practice" for transpiling to Zig because almost nobody else does it at this scale.

### Handling Zig-Specific Features

| Zig Feature | Orhon Approach | Assessment |
|-------------|----------------|------------|
| `comptime` | `compt` keyword | Correct — direct mapping |
| Error unions | `(Error \| T)` -> `anyerror!T` | Correct — native Zig errors |
| Optionals | `(null \| T)` -> `?T` | Correct — native Zig optionals |
| Allocators | `.new(alloc)` pattern | Correct — explicit, SMP default |
| Slices | Direct mapping | Good — Zig slices are the right abstraction |
| Packed structs | Not yet exposed | Future opportunity |
| `@cImport` | Not yet exposed | Would need bridge sidecar pattern |
| Inline asm | Not exposed | Low priority for a safe language |

---

## 2. Zig Build System Integration

### Current State in Orhon

Orhon generates `build.zig` programmatically via `zig_runner.zig`. The generation handles:
- Single-target exe/static/dynamic builds (`buildZigContent`)
- Multi-target builds with topological sorting (`buildZigContentMulti`)
- Named Zig modules for bridges, shared modules, and libraries
- `linkSystemLibrary` / `linkLibC` on Step.Compile artifacts
- Version embedding via `.version` field

This is already quite sophisticated. The generated `build.zig` follows current Zig 0.15 conventions with `b.createModule()` + `addImport()`.

### Best Practices for Programmatic build.zig Generation

**What Orhon does right:**
1. **Named modules instead of file paths** — prevents "file exists in two modules" errors. This is the correct Zig 0.15+ pattern.
2. **Topological sort for library dependencies** — ensures libs are emitted in dependency order.
3. **Single `zig build` invocation** — the multi-target builder generates one unified build.zig and runs `zig build` once, not per-target.
4. **`b.standardTargetOptions()` + `b.standardOptimizeOption()`** — follows standard Zig build conventions.

**What could be improved:**

1. **C/C++ source compilation** (listed in TODO.md): The generated build.zig currently has no mechanism for `.c`/`.cpp` files. In Zig 0.15, the pattern is:
   ```zig
   exe.root_module.addCSourceFiles(.{
       .files = &.{"vma_impl.cpp"},
       .flags = &.{"-std=c++17"},
   });
   exe.root_module.linkSystemLibrary("vulkan");
   ```
   This would require Orhon to accept a build configuration (e.g., `#linkC "lib"` already exists, but `#cSources "file.c"` is needed).

2. **Build.zig.zon generation**: Currently no `build.zig.zon` is generated for user projects. For dependency management (when Zig's package manager matures), this will matter.

3. **Test step generation**: The generated build.zig includes a run step but no test step. For `orhon test`, a dedicated `b.step("test", ...)` with `b.addTest()` would be cleaner than the current approach.

4. **Conditional compilation**: No mechanism to pass build options through to generated Zig. Could be useful for feature flags.

### Zig 0.15 Build System API

Key API changes in Zig 0.14/0.15 that affect build.zig generation:
- `b.createModule()` replaces the old `b.addModule()` pattern
- `root_module` is a field on `addExecutable` / `addLibrary`, not a separate call
- `addLibrary` takes a `.linkage` field (`.static` / `.dynamic`) instead of separate functions
- `addImport()` on `Build.Module` for named dependencies — this is the canonical way to wire modules
- `Build.Module` has `linkSystemLibrary()` but NOT `linkLibC()` — must use `Step.Compile` for `linkLibC()`

**Confidence: HIGH** — verified directly from the working Orhon codebase on Zig 0.15.2.

---

## 3. Zig 0.14/0.15 New Features

### Changes Confirmed in Orhon's Codebase (Zig 0.15.2)

| Feature | Status | Orhon Usage |
|---------|--------|-------------|
| `std.heap.smp_allocator` | Available | Used as default allocator in release mode (`main.zig:603`) |
| `std.heap.DebugAllocator` | Available | Used in debug mode for leak detection (`main.zig:601`) |
| `std.process.Child` | New API | Used in `zig_runner.zig` (replaces old `ChildProcess`) |
| `b.createModule()` | New API | Used in build.zig and generated build files |
| `addLibrary` with `.linkage` | New API | Used in generated build.zig for static/dynamic libs |
| `std.testing.fuzz` | Available | Used in lexer.zig and peg.zig fuzz tests |
| `std.fs.File.writer()` with buffer | New API | Used throughout (`writer(&buf)` pattern) |
| `.Exited => \|code\| code` | Payload captures on switch | Used in zig_runner.zig |

### Features Orhon Could Leverage

**1. `std.testing.fuzz` for deeper fuzzing:**
Orhon already uses this for lexer/parser fuzzing. Could extend to:
- Fuzz the full pipeline (passes 1-11) with valid-structure inputs
- Fuzz the codegen specifically with crafted ASTs
- Use corpus-guided fuzzing with `.orh` test files as seeds

**2. SMP Allocator as production default:**
Already done. `smp_allocator` replaced `page_allocator` as the default. This is the correct choice for general-purpose allocation — it provides thread-safe, low-fragmentation allocation with pool-based small allocation optimization.

**3. DebugAllocator for development:**
Already done. `DebugAllocator` in debug mode catches leaks, double-frees, and use-after-free. The pattern in `main.zig` is exemplary:
```zig
var da = std.heap.DebugAllocator(.{}){};
const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;
```

**4. Comptime improvements:**
Zig 0.14+ improved comptime evaluation speed and capabilities. Orhon could:
- Generate more `comptime` annotations in output where type information is statically known
- Use comptime for generic instantiation validation at compile time
- Potentially emit `comptime { ... }` blocks for static assertions

**5. Build system `addOptions`:**
Orhon's own build.zig uses this for version injection. Could expose this to generated build files for user-defined compile-time options.

**6. `std.process.Child` improvements:**
The new `Child` API (replacing `ChildProcess`) with `.Pipe` behaviors is cleaner. Orhon already uses it correctly.

### API Changes to Watch (LOW confidence — training data only)

- Zig 0.14 introduced `addLibrary` unifying static/dynamic — **confirmed used in codebase**
- Zig 0.14 changed error handling in some stdlib functions — **need to verify per-function**
- Zig 0.15 may have further breaking changes to build system — **cannot verify without docs**

---

## 4. Debug Info and Source Maps for Transpilers

### The Problem

When a user debugs an Orhon program, they currently see generated `.zig` source in the debugger, not the original `.orh` source. The TODO.md explicitly lists "Debugger integration" as a want: "Debug symbol generation, GDB/LLDB line mapping from generated Zig back to `.orh` source."

### How Other Transpilers Handle This

**TypeScript -> JavaScript (Source Maps):**
- Emits a `.map` file (JSON) mapping generated JS lines/columns to TS lines/columns
- Debuggers (Chrome DevTools, VS Code) consume source maps natively
- Well-established standard (Source Map v3)
- **Not applicable to Zig** — native debuggers (GDB/LLDB) don't understand JS source maps

**Nim -> C:**
- Generates `#line` directives in C output pointing back to `.nim` source
- GDB shows Nim source directly because DWARF debug info contains Nim filenames/lines
- **This is the closest model to what Orhon needs**

**Cython -> C:**
- Same `#line` directive approach as Nim
- Also generates `.pxd` debug helper files

**Haxe -> Various targets:**
- When targeting C++, uses `#line` directives
- When targeting JS, uses source maps

### What Orhon Can Do

**Approach 1: Line-comment annotations (simplest, no tooling required)**
Emit comments in generated Zig mapping back to source:
```zig
// orh:src/main.orh:42
const x: i32 = 5;
```
This is documentation-only — debuggers ignore comments. But it helps when reading generated code with `-zig` flag.

**Approach 2: Zig source location tracking (medium effort)**
Zig doesn't have `#line` directives. However, DWARF debug info is generated by the Zig compiler based on the `.zig` source file paths. If we could:
1. Track `.orh` line -> generated `.zig` line mappings during codegen
2. Write a mapping file (`.orh.map`)
3. Build a debugger adapter (DAP plugin) that translates breakpoints/locations

This is the approach that would actually work. A VS Code Debug Adapter Protocol extension could:
- Accept breakpoints on `.orh` files
- Translate to `.zig` line numbers using the map
- Launch GDB/LLDB on the binary
- Translate stack frames back to `.orh` locations

**Approach 3: DWARF manipulation (hardest, most complete)**
After Zig compiles the binary, post-process the DWARF debug info to replace `.zig` file references with `.orh` file references and remap line numbers. Tools:
- `libdwarf` / `pyelftools` / `gimli` (Rust) for DWARF parsing
- Write a post-link pass that rewrites DI_compile_unit entries
- Would make GDB/LLDB show `.orh` source natively

**Recommendation:** Start with Approach 2 (source map + DAP adapter). It is achievable without binary manipulation and integrates with VS Code where Orhon already has an extension.

**Confidence: MEDIUM** — the general approaches are well-established, but the specifics of Zig's DWARF output and whether it can be post-processed cleanly need investigation.

### Current State in Orhon

Orhon already has `LocMap` (AST node -> source location) and `file_offsets` (combined-buffer lines -> original file+line). The codegen has access to source location data. The infrastructure for emitting a line mapping file during codegen is almost there — it would require:
1. During codegen, tracking which `.zig` output line corresponds to which `.orh` input line
2. Writing the mapping to a JSON/binary file in `.orh-cache/`
3. A DAP adapter that reads this mapping

---

## 5. Testing Strategies for Compilers

### What Orhon Currently Has

| Category | Implementation | Coverage |
|----------|---------------|----------|
| Unit tests | Zig `test` blocks in every source file | All passes |
| Build tests | `test/02_build.sh` | Compiler builds |
| CLI tests | `test/03_cli.sh` | Args, help, errors |
| Integration tests | `test/05_compile.sh` through `test/10_runtime.sh` | Full pipeline |
| Negative tests | `test/11_errors.sh` | Expected failures |
| Fuzzing | `std.testing.fuzz` + standalone `fuzz.zig` | Lexer + parser |
| Codegen quality | `test/08_codegen.sh` | Generated Zig checks |

This is already a strong test suite. Here's what's missing and what modern compiler projects use:

### Property-Based Testing

**What it is:** Generate random valid programs, compile them, run them, check properties hold (e.g., "program either compiles or produces a well-formed error"). Unlike fuzzing (which aims to crash), property testing checks semantic correctness.

**How to apply to Orhon:**
1. **Round-trip property:** Parse -> codegen -> re-parse generated Zig should produce equivalent semantics
2. **Type safety property:** Any program that passes ownership/borrow checking should never produce a Zig compile error
3. **Idempotency:** Formatting a file twice should produce the same output
4. **Error completeness:** Every rejected program should have at least one error message

**Implementation:** Zig's `std.testing.fuzz` can serve as the random generation engine. Write "oracle" functions that verify properties:
```zig
test "fuzz full pipeline" {
    // Generate random valid Orhon programs
    // Run full pipeline
    // Assert: either compiles to valid Zig OR produces error messages
    // Assert: never panics
}
```

### Mutation Testing

**What it is:** Deliberately introduce bugs (mutations) into the compiler, run the test suite, check if tests catch the mutation. If tests pass with a mutation, there's a coverage gap.

**Tools:** No Zig-specific mutation testing tool exists. Options:
- Manual mutation: change operators, swap branches, delete error checks
- Script-based: automatically edit source, run tests, revert
- This is labor-intensive for a Zig codebase but high-value for critical paths

**Priority targets for mutation testing:**
- `ownership.zig` — ownership tracking is safety-critical
- `borrow.zig` — borrow checking is safety-critical
- `codegen.zig` — incorrect codegen can produce unsafe Zig

### Differential Testing

**What it is:** Compare output of two implementations. For compilers, compare against a reference or against the target language directly.

**For Orhon:**
- Write equivalent programs in Orhon and Zig
- Run both, compare output
- Automated: compile Orhon program, extract generated Zig, compile and run both
- This is essentially what `test/10_runtime.sh` does

### Codegen Snapshot Testing

**What it is:** Save expected generated Zig output, compare against actual output on each test run. Catches unintended codegen changes.

**For Orhon:**
- Each fixture `.orh` file gets a corresponding `.zig.expected` file
- Test compares generated Zig against expected
- `test/08_codegen.sh` may already do some of this

**Recommendation:** Orhon's testing is already strong. The biggest gaps are:
1. **Property-based testing for the full pipeline** — extend fuzz testing from "doesn't crash" to "produces correct results"
2. **Codegen snapshot tests** — catch unintended codegen regressions
3. **Cross-module integration tests** — the Tamga project serves as an informal version of this, but automated multi-module test cases would be valuable

---

## 6. Zig Allocator Patterns

### Allocators in Zig 0.15

| Allocator | Use Case | Thread-Safe | Orhon Usage |
|-----------|----------|-------------|-------------|
| `std.heap.smp_allocator` | General-purpose, production | Yes | Default for release builds, user code default |
| `std.heap.DebugAllocator` | Development, leak detection | Yes | Debug builds of the compiler itself |
| `std.heap.ArenaAllocator` | Batch allocation, bulk free | No (single-threaded) | AST nodes, PEG grammar, captures, test helpers |
| `std.heap.page_allocator` | Large allocations, OS pages | Yes | Previously default, replaced by SMP |
| `std.testing.allocator` | Tests (leak-checking) | No | Should be used in test blocks |

### Orhon's Current Allocator Strategy

**Compiler internals:**
- Debug: `DebugAllocator` wrapping default — catches leaks during development
- Release: `smp_allocator` — fast, thread-safe, low fragmentation
- AST: `ArenaAllocator` per module — entire AST freed in one call via `ast_arena`
- PEG: `ArenaAllocator` for grammar rules and capture nodes

**Generated code (user programs):**
- Default: `smp_allocator` via collections bridge
- Optional: user-passed allocator via `.new(alloc)`
- String interpolation: `smp_allocator` for temp buffers

### Best Practices for Compiler-Internal Memory Management

**1. Arena for parse trees (already done correctly):**
ASTs are allocated, processed through all passes, then freed in bulk. Arena allocation is perfect — no individual `free()` calls needed, entire module parse tree freed in one operation.

**2. SMP for long-lived structures:**
The `DeclTable`, `Reporter`, and other structures that persist across module processing use the general allocator. This is correct.

**3. Consider arena for per-pass temporaries:**
Each pass creates temporary data structures (hash maps for tracking, arrays for collecting). These could use a per-pass arena that's freed after the pass completes, reducing individual allocation overhead:
```zig
var pass_arena = std.heap.ArenaAllocator.init(backing_allocator);
defer pass_arena.deinit();
// All pass temporaries use pass_arena.allocator()
```

**4. DebugAllocator configuration:**
The current `DebugAllocator(.{})` uses default settings. For more aggressive checking:
```zig
var da = std.heap.DebugAllocator(.{
    .safety = true,           // default: true
    .thread_safety = true,    // default: true
    // .stack_trace_frames = 8, // increase for deeper traces
}){};
```

**5. Allocator for generated code:**
The choice of SMP as default for user programs is correct. `page_allocator` wastes memory for small allocations (minimum OS page size). `GeneralPurposeAllocator` is the user-configurable version — but SMP is the right default because it just works.

### Memory Management Improvements for Orhon

**Opportunity 1: Per-module arena for semantic passes**
Currently, passes 4-9 allocate into the main allocator. A per-module arena for all semantic analysis temporaries would:
- Reduce individual free() calls
- Improve cache locality
- Make cleanup after each module trivial

**Opportunity 2: String interning**
The compiler allocates many duplicate strings (type names, module names, function names). A string interner (deduplicated string pool) would reduce memory usage and speed up string comparisons (pointer equality instead of content comparison).

**Opportunity 3: Allocation counting in debug mode**
Track allocation counts per pass to identify which passes are allocation-heavy. The `DebugAllocator` provides this automatically — just need to read its stats.

---

## 7. Additional Findings

### Zig Community Patterns Relevant to Orhon

**Zig module system evolution:**
Zig 0.14+ moved from file-path imports to named modules for package dependencies. Orhon correctly adopted this with `b.createModule()` + `addImport()`. The pattern is:
- Internal files: `@import("file.zig")` (file-path, within same module)
- Cross-module: `@import("module_name")` (named, registered via build.zig)

This matches Orhon's bridge module architecture exactly.

**Error handling conventions:**
The Zig community convention is to use `anyerror` for interfaces and concrete error sets for implementations. Orhon uses `anyerror!T` for error unions which is correct for generated code — the Zig compiler infers concrete error sets automatically.

**Testing conventions:**
Zig projects typically:
- Use `test` blocks in each file (Orhon does this)
- Use `std.testing.expect` over `expectEqual` for complex types (Orhon does this)
- Use `std.testing.allocator` in tests for leak detection
- Use `std.testing.fuzz` for fuzz testing (Orhon does this)

### Cross-Compilation

Orhon already supports cross-compilation via Zig's `-Dtarget` flag. The `BuildTarget` enum covers the major targets. For WASM, the `wasm32-freestanding` target is correct but limits stdlib availability — WASM support may need special handling for allocators and I/O.

### Zig's `translate-c` as Reference

Zig's built-in C-to-Zig translator (`zig translate-c`) is the canonical example of generating Zig source. Orhon's codegen follows similar principles:
- Emit readable, formatted Zig
- Use Zig's native type system (no wrappers)
- Handle edge cases in the translator, not in generated runtime code

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Zig as target — other projects | LOW | Cannot verify current landscape without web access |
| Build system patterns | HIGH | Verified from working codebase on Zig 0.15.2 |
| Zig 0.14/0.15 features | MEDIUM | Confirmed features used in codebase; may miss features not yet adopted |
| Debug info / source maps | MEDIUM | General approaches well-established; Zig-specific DWARF details unverified |
| Testing strategies | MEDIUM | General compiler testing knowledge; Zig-specific tooling gaps unverified |
| Allocator patterns | HIGH | Verified from codebase + Zig stdlib knowledge |

## Gaps to Address

1. **Cannot verify other transpile-to-Zig projects** — web search needed to confirm current landscape
2. **Zig 0.15 release notes not reviewed** — may be features not yet adopted in codebase
3. **DWARF debug info specifics** — need to inspect actual debug output from Zig compiler to validate source mapping approach
4. **Zig package manager maturity** — `build.zig.zon` may have new capabilities for dependency management
5. **Community forum discussions** — Ziggit posts about build patterns, allocator best practices could inform decisions

## Recommendations for Orhon's Next Steps

### Immediate (high impact, low effort)
1. **Add C/C++ source compilation to build.zig generation** — unblocks Tamga and any project wrapping C libraries
2. **Codegen snapshot tests** — save expected `.zig` output for each fixture, catch regressions
3. **Property-based pipeline testing** — extend fuzzing from "no crash" to "correct output"

### Medium-term (high impact, medium effort)
4. **Source map file generation** — emit `.orh.map` during codegen tracking orh-line -> zig-line
5. **VS Code DAP adapter** — use source maps for debugging `.orh` files through GDB/LLDB
6. **Per-pass arena allocators** — reduce allocation overhead in semantic passes
7. **String interning** — deduplicate repeated type/module/function names

### Long-term (transformative, high effort)
8. **Zig IR layer in codegen** — the 3-layer split described in TODO.md (Zig IR + Lowering + Printer)
9. **SSA construction** — enables optimization passes (inlining, DCE, constant folding)
10. **Parallel module compilation** — leverage per-module arenas + thread pool
