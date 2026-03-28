# Milestones

## v0.16 Bug Fixes (Shipped: 2026-03-28)

**Phases completed:** 4 phases, 5 plans, 11 tasks

**Key accomplishments:**

- Added is_bridge to FuncSig to prevent incorrect const auto-borrow on bridge calls, and fixed sidecar pub visibility so @import resolves all bridge symbols
- Three compiler bugs fixed: unary negation in PEG grammar, cross-module `is` union tag comparison, and Async(T) compile error — all 260 tests passing.
- Fixed three build system bugs: infinite-loop pub-fixup scanner (BLD-01), missing addIncludePath for cimport headers (BLD-02), suppressed linkSystemLibrary when source: present (BLD-03); 262 tests pass
- Fixed use-after-free on cross-compilation target flag and .zig-cache leak after optimized builds in zig_runner.zig
- Dead Async(T) codegen branch removed from typeToZig; TODO.md updated with all v0.16 fix status and phase accomplishments.

---

## v0.15 Language Ergonomics (Shipped: 2026-03-27)

**Phases completed:** 3 phases, 6 plans, 12 tasks

**Key accomplishments:**

- `throw x` keyword implemented across all 7 compiler passes: lexer token, PEG grammar, AST builder, propagation validation, MIR lowering, and Zig codegen with error narrowing.
- throw feature verified end-to-end: example module compiles, codegen pattern checked, negative tests catch invalid usage, docs document the syntax and semantics.
- Guard syntax `(x if x > 0) => { ... }` implemented across all six compiler passes: PEG grammar, AST builder, resolver (child scope + else enforcement), MIR annotator/lowerer, and codegen (if/else chain desugaring); existing bare range patterns migrated to parenthesized form.
- Control flow spec updated with Pattern Guards subsection, parenthesized pattern reference table, and else-requirement documentation matching the implemented guard syntax from Plan 01.
- Unified C library import directive: `#cimport "lib" { include: "h" }` replaces four old directives across grammar, parser, builder, declarations, main.zig collection, and zig_runner build generation
- Tamga's three bridge modules migrated to #cimport = { name: "lib", include: "h" } syntax; example module and docs updated — zero legacy directives remain in any project file

---

## v0.14 Build System (Shipped: 2026-03-27)

**Phases completed:** 17 phases, 27 plans, 38 tasks

**Key accomplishments:**

- Commit:
- Cross-module struct method calls with const & parameters now emit &arg in generated Zig, and qualified generic types like math.Vec2(f64) are validated against the referenced module's DeclTable at Orhon compile time.
- Replaced `catch unreachable` with `catch |err| return err` in both interpolation codegen functions, preventing OOM panics, with a source-level regression test.
- Files:
- ptr_cast_expr grammar rule added — Ptr(T).cast(addr) and RawPtr(T).cast(addr) produce ptr_expr AST nodes; tester and example module migrated to new syntax
- readMessage hardened with 4096-byte header buffer, HeaderTooLong truncation detection, and 64 MiB content-length cap preventing OOM from malicious payloads
- Per-request ArenaAllocator in runAnalysis bulk-frees all intermediate pass objects after each analysis cycle, plus unit tests that caught and fixed an ArrayList backing buffer leak
- 1. [Rule 1 - Bug] Incorrect MIR kind check — .collection vs .type_expr
- One-liner:
- 1. [Rule 1 - Bug] `catch return error.OutOfMemory` incompatible with generated return type
- Data-loss OOM sites in collections.zig and stream.zig replaced with explicit catch return/break patterns; fire-and-forget I/O sites retain catch {} (the only valid Zig 0.15 error discard syntax)
- 1. [Rule 1 - Bug] Separate inline variant required for temp_var path
- RawPtr/VolatilePtr demos, typeOf() function, #bitsize docs, and include vs import added to example module — covering all previously missing language features
- PEG builder string interpolation wired end-to-end: @{expr} in .orh strings now produces interpolated_string AST nodes, MIR hoists allocPrint temp vars, codegen emits correct Zig — ./testall.sh 236/236 pass
- Parser fuzz test using std.testing.fuzz added to src/peg.zig; standalone harness extended to 5 strategies; COMPILER.md documents complete fuzz infrastructure
- Eliminated intermittent test race via std.testing.tmpDir, removed dead ziglib testbed, confirmed 5/5 clean runs and 123/123 test passes
- Full pipeline wired for `pub enum(u32) Scancode { A = 4, B = 5 }` — PEG grammar, AST, builder, MIR, and codegen all updated in 5 files, ~30 lines changed.
- Grammar, builder, and codegen changes enabling `ev is module.Type` cross-module type checks, emitting `@TypeOf(val) == mod.Type` Zig via new emitTypePath/emitTypeMirPath helpers; all 243 tests pass.
- End-to-end runtime test coverage for `(Error | void)` — codegen correctly emits `anyerror!void`, bare return produces void success, error path produces error; example module updated as living language manual
- 1. [Rule 1 - Bug] Return type mismatch for variables typed with module-level aliases
- Bridge .zig sidecar files registered as named Zig modules via createModule/addImport, eliminating file-path imports and cross-module duplicate module errors
- One-liner:
- Shared @cImport wrapper module generation (#cInclude) and C/C++ source compilation (#csource) added to the Orhon build system for Tamga's Vulkan/VMA modules
- All 9 Tamga workarounds removed and Tamga framework builds clean end-to-end with zero errors — Phase 20 complete
- Task 1:
- Task 1:

---

## v0.13 Tamga Compatibility (Shipped: 2026-03-26)

**Phases completed:** 7 phases, 7 plans, 12 tasks

**Key accomplishments:**

- Parser fuzz test using std.testing.fuzz added to src/peg.zig; standalone harness extended to 5 strategies; COMPILER.md documents complete fuzz infrastructure
- Eliminated intermittent test race via std.testing.tmpDir, removed dead ziglib testbed, confirmed 5/5 clean runs and 123/123 test passes
- Full pipeline wired for `pub enum(u32) Scancode { A = 4, B = 5 }` — PEG grammar, AST, builder, MIR, and codegen all updated in 5 files, ~30 lines changed.
- Grammar, builder, and codegen changes enabling `ev is module.Type` cross-module type checks, emitting `@TypeOf(val) == mod.Type` Zig via new emitTypePath/emitTypeMirPath helpers; all 243 tests pass.
- End-to-end runtime test coverage for `(Error | void)` — codegen correctly emits `anyerror!void`, bare return produces void success, error path produces error; example module updated as living language manual
- 1. [Rule 1 - Bug] Return type mismatch for variables typed with module-level aliases

---

## v0.11 Language Simplification (Shipped: 2026-03-25)

**Phases completed:** 4 phases, 5 plans, 5 tasks

**Key accomplishments:**

- Const auto-borrow: `const` non-primitive values auto-pass as `const &` at call sites — no more silent deep copies
- Ptr syntax simplified: `const p: Ptr(T) = &x` replaces verbose `.cast()` — type annotation drives pointer safety level
- Old `Ptr(T).cast(&x)` and `Ptr(T, &x)` syntax removed — compile error with clear message
- Tamga companion project and all fixtures updated for new semantics
- `.Error` fallback codegen fixed: correct Zig `if/else` pattern instead of `catch`
- 240/240 tests pass across all 11 stages

**Stats:** 35 files changed, 2812 insertions, 256 deletions
**Git range:** 51aceec..ffb8c0e (2026-03-25)

---
