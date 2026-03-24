# Codebase Concerns

**Analysis Date:** 2026-03-24

---

## Tech Debt

**Codegen monolith — no Zig IR layer:**
- Issue: `src/codegen.zig` (3720 lines) is a direct MIR → Zig text printer. No intermediate Zig IR exists. All pretty-printing, coercion logic, and structural concerns are entangled in one pass.
- Files: `src/codegen.zig`
- Impact: Adding new output targets, testing output structure, or modifying coercions requires surgery on a large, fragile file. Unit test coverage is a single test (`test "codegen - type to zig"`).
- Fix approach: Split into three layers as planned in `docs/TODO.md` — Zig IR structs (~15-20 node types), a lowering pass (MIR → Zig IR), and a printer (Zig IR → text).

**LSP server — no per-request arena:**
- Issue: `src/lsp.zig` (3243 lines) uses a single long-lived allocator for all requests. Each `runAnalysis()` call allocates passes 1–9 worth of data. Allocations from prior analyses are freed only if the caller explicitly frees the result. The `doc_store`, `open_docs`, and cached symbols all accumulate indefinitely.
- Files: `src/lsp.zig:1241`, `src/lsp.zig:443`
- Impact: LSP process grows in memory over a long editing session. In environments with many open files or frequent saves this will become visible.
- Fix approach: Wrap each `runAnalysis()` call in an `ArenaAllocator` and reset it after publishing diagnostics. Only the final `AnalysisResult` needs to be duped to the outer allocator.

**LSP header line buffer too small:**
- Issue: `readMessage()` uses a fixed `[1024]u8` stack buffer for HTTP-style header lines. If a header line (e.g., a `Content-Type` with a very long value) exceeds 1024 bytes, the byte is silently dropped and parsing continues with a truncated line.
- Files: `src/lsp.zig:36`
- Impact: Malformed parse of LSP headers from a future or non-standard client.
- Fix approach: Replace fixed buffer with `allocator.alloc` and dynamic append, or raise limit with a compile-time constant that documents the choice.

**LSP content-length with no upper bound:**
- Issue: `readMessage()` passes `content_length` (a `usize` parsed from a client-supplied header) directly to `reader.readAlloc()` with no maximum. A client sending a synthetic `Content-Length: 4294967295` header will cause the allocator to attempt a 4 GB allocation.
- Files: `src/lsp.zig:54-59`
- Impact: OOM crash or severe resource exhaustion if the LSP is exposed to untrusted input.
- Fix approach: Cap `content_length` at a reasonable maximum (e.g., 16 MB) and return `error.MessageTooLarge` if exceeded.

**Residual `m.ast` back-pointer accesses in codegen:**
- Issue: Six remaining `m.ast` accesses in `src/codegen.zig` (lines 564, 651, 1315, 2061, 2381, 2382, 2987, 3002, 3029) read through the AST back-pointer instead of self-contained MirNode fields. These were preserved for source-location queries, `type_expr`, and `passthrough` node types.
- Files: `src/codegen.zig`
- Impact: The MIR self-containment migration (`docs/TODO.md` Architecture section) is incomplete. If the AST is freed before codegen these will crash. They also complicate the planned codegen split.
- Fix approach: Add `source_loc` and structural type fields to `MirNode` and remove the remaining `m.ast` reads.

---

## Known Bugs

**Codegen — cross-module struct const-ref argument passing:**
- Symptoms: When calling a method on an imported module's struct where a non-`self` parameter is declared `const &T`, codegen emits the argument by value. Zig errors with `expected type '*const T', found 'T'`.
- Files: `src/codegen.zig` (call argument generation, around lines 3430–3460)
- Trigger: Any cross-module struct method call with `const &` non-self parameters.
- Workaround: Use by-value parameters for cross-module struct methods.

**Resolver — qualified generic types not validated:**
- Symptoms: `math.Nonexistent(f64)` passes resolver validation silently. The error is deferred to Zig compile time, producing a Zig error instead of an Orhon error.
- Files: `src/resolver.zig:840-845` — qualified names (`is_qualified`) bypass existence checks.
- Trigger: Any `module.Type(params)` expression where `Type` does not exist in the named module.
- Workaround: None at the Orhon level — Zig will error, but with a confusing message.

**Ownership checker — const values treated as moved on by-value pass:**
- Symptoms: Passing the same `const` struct value to two separate function calls errors with "use of moved value". Const values are immutable and should be implicitly copyable.
- Files: `src/ownership.zig:211-220` — `const_decl` and `var_decl` go through the same `is_prim` inference; `const` immutability is not used to mark the value as always-copy.
- Trigger: `const a: Vec2(f64) = ...; const b = a.add(a)` — second use of `a` errors.
- Workaround: Manually annotate type as a primitive, or restructure to avoid reuse.

**`orhon test` — output format mismatch:**
- Symptoms: `orhon test` reports `0 passed, 0 failed` when Zig generates no test output matching the expected format. The `formatTestOutput()` parser expects `N/M passed` on a single line but Zig 0.15's output format differs.
- Files: `src/zig_runner.zig:272-322`
- Trigger: `orhon test` on any project. Visible in `test/05_compile.sh`.
- Workaround: Pass `--verbose` (`orhon test -v`) to see raw Zig output.

**Stdlib — string interpolation leaks memory:**
- Symptoms: Every `@{variable}` interpolation allocates a buffer via `std.fmt.allocPrint(std.heap.page_allocator, ...)` with no matching `free`. The allocation is never freed.
- Files: `src/codegen.zig:2526`, `src/codegen.zig:2929`
- Trigger: Any Orhon source using `@{expr}` string interpolation.
- Workaround: None. Known issue per `docs/TODO.md`.

---

## Security Considerations

**LSP — unbounded allocation from client-controlled input:**
- Risk: A client (or MitM attacker on the LSP pipe) that sends an arbitrarily large `Content-Length` header can exhaust memory.
- Files: `src/lsp.zig:54-59`
- Current mitigation: None.
- Recommendations: Add a `MAX_MESSAGE_SIZE` constant (e.g., `16 * 1024 * 1024`) and return an error before calling `readAlloc`.

**LSP — CWD change without async safety:**
- Risk: `runAnalysis()` calls `proj_dir.setAsCwd()` to switch the process working directory to the project root. If two LSP requests were ever processed concurrently (e.g., a future async rewrite), the CWD change would be a race condition.
- Files: `src/lsp.zig:452-456`
- Current mitigation: LSP is single-threaded today, so this is safe.
- Recommendations: Pass an explicit `Dir` handle to all file-path operations rather than changing the process CWD.

---

## Performance Bottlenecks

**Sequential module compilation:**
- Problem: All modules are compiled one at a time in topological order. Independent modules with satisfied dependencies are never processed in parallel.
- Files: `src/main.zig:1003` — `for (order) |mod_name|` loop.
- Cause: No thread pool, no per-module arena, `Reporter` is not thread-safe.
- Improvement path: Described in `docs/TODO.md` — thread-safe Reporter, work-stealing queue. Groundwork is already laid (SemanticContext per module).

**Hardcoded `page_allocator` for generated string interpolation:**
- Problem: Every interpolated string in compiled Orhon programs allocates and never frees via `page_allocator`. This is O(n) leaked memory for programs doing string formatting in loops.
- Files: `src/codegen.zig:2526`, `src/codegen.zig:2929`
- Cause: No allocator strategy for generated temporary strings.
- Improvement path: Emit a `defer allocator.free(...)` for each interpolation result. Requires deciding on the allocator strategy first.

**Hardcoded `page_allocator` in many stdlib sidecars:**
- Problem: Every stdlib module uses a process-global `page_allocator`. Collections, regex, CSV, YAML, TOML, JSON, TUI, net, crypto, ini, encoding all allocate through `page_allocator` with no caller-provided allocator.
- Files: `src/std/collections.zig:7`, `src/std/regex.zig:6`, `src/std/yaml.zig:9`, `src/std/toml.zig:7`, `src/std/csv.zig:6`, `src/std/json.zig:6`, `src/std/tui.zig:7`, `src/std/net.zig:6`, `src/std/crypto.zig:6`, `src/std/ini.zig:6`, `src/std/encoding.zig:6`
- Cause: Stdlib was written without caller-configurable allocators.
- Improvement path: Add an allocator parameter to stdlib bridge functions, or introduce a module-level allocator setter.

---

## Fragile Areas

**`src/codegen.zig` — single test, 3720 lines:**
- Files: `src/codegen.zig`
- Why fragile: The entire code generation pass has one unit test (`test "codegen - type to zig"`). All other coverage comes from integration tests in `test/08_codegen.sh`, `test/09_language.sh`, and `test/10_runtime.sh`. Internal logic like union wrapping, coercion chains, MIR path vs AST path, and cross-module default arg injection has no direct unit tests.
- Safe modification: Always run `./testall.sh` and manually test the specific construct being changed against `test/fixtures/`. Add a new unit test when touching type coercion or MIR codegen paths.
- Test coverage: One unit test. Integration tests cover happy paths but not edge cases in coercions.

**Codegen — dual code paths (MIR path and AST path):**
- Files: `src/codegen.zig` — `generateExprMir()` vs `generateExpr()`
- Why fragile: Two parallel expression generators exist. `generateExprMir()` is the target state; `generateExpr()` is the legacy AST path still used for `type_expr` and `passthrough` nodes. New nodes must be wired to both or the wrong path may be taken silently.
- Safe modification: Check `m.ast` residuals before adding new expression types; prefer `generateExprMir()` for all new work.

**Ownership checker — type inference heuristics:**
- Files: `src/ownership.zig:209-220`, `src/ownership.zig:526-530`
- Why fragile: Whether a variable is treated as "primitive" (copy) or "non-primitive" (move) is inferred from the type annotation string via `types.isPrimitiveName()` and `builtins.isValueType()`. If a struct is not in either list and has no annotation, `inferPrimitiveFromValue()` falls back to a heuristic on the value expression. New types or imported structs can silently get the wrong classification.
- Safe modification: Extend `isPrimitiveName()` and `isValueType()` when adding new stdlib types. Always test ownership behavior for new bridge struct types.

**Thread-safety analysis — skipped in test mode:**
- Files: `src/main.zig:1806` — `_ = thread_safety;`
- Why fragile: The unit test path in `main.zig` explicitly discards `thread_safety`. If the thread checker has a bug that only manifests in certain program shapes, the test pipeline will not catch it.
- Safe modification: Remove the `_ = thread_safety` discard and enable thread checking in unit test builds.

---

## Stdlib Concerns

**103 silent `catch {}` instances across 15 stdlib sidecar files:**
- What fails silently: Allocation failures and I/O errors in collections, JSON, XML, YAML, CSV, TOML, INI, HTTP, filesystem, system, console, stream, regex, str, and TUI operations.
- Files: `src/std/toml.zig`, `src/std/yaml.zig`, `src/std/csv.zig`, `src/std/console.zig`, and 11 others.
- Risk: An OOM or I/O failure in a stdlib call returns a zero-value result (empty list, empty string) with no indication of failure. Programs silently produce wrong output.
- Priority: High for any production use of the stdlib.

**`src/std/testing.zig` uses `@panic` instead of error returns:**
- Files: `src/std/testing.zig:9-39`
- Risk: Any test assertion failure aborts the entire process instead of returning a test failure. Multiple assertion failures cannot be collected.
- Priority: Medium.

---

## Test Coverage Gaps

**`src/codegen.zig` — one unit test for 3720 lines:**
- What's not tested: Union wrapping, coercion chains, MIR-path codegen, cross-module import deduplication, default arg injection, interpolated string generation, thread/handle emission.
- Files: `src/codegen.zig`
- Risk: Regressions in any of these areas will only be caught by integration tests if a corresponding `.orh` fixture exercises the exact code path.
- Priority: High.

**`src/main.zig` — no unit tests for pipeline orchestration:**
- What's not tested: Module ordering, incremental cache hit/miss logic, multi-root compilation, cross-module DeclTable accumulation.
- Files: `src/main.zig`
- Risk: Changes to compilation order or caching logic have no unit-level safety net.
- Priority: Medium.

**`src/module.zig` — 7 tests for 1016 lines:**
- What's not tested: `scanAndParseDeps()`, `validateImports()`, file offset mapping, sidecar resolution.
- Files: `src/module.zig`
- Risk: Module resolution edge cases (missing sidecar, dep cycle in `#dep`, overlapping module names) can break the entire pipeline without being caught until integration tests.
- Priority: Medium.

---

*Concerns audit: 2026-03-24*
