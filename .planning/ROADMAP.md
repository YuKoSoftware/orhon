# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.9 Bug Fixes & Foundation** — Phases 1-3 (shipped 2026-03-25)
- ✅ **v0.10 Test Suite & Code Quality** — Phases 4-7 (shipped 2026-03-25)
- 🚧 **v0.11 Language Simplification** — Phases 8-11 (in progress)

## Phases

<details>
<summary>✅ v0.9 Bug Fixes & Foundation (Phases 1-3) — SHIPPED 2026-03-25</summary>

### Phase 1: Compiler Bug Fixes
**Goal**: Cross-module codegen, const semantics, and `orhon test` all work correctly
**Plans**: 2/2 complete

Plans:
- [x] 01-01-PLAN.md — Fix const struct by-value passing and cross-module const arg passing
- [x] 01-02-PLAN.md — Fix qualified generic type validation and working orhon test command

### Phase 2: Memory & Error Safety
**Goal**: String interpolation is memory-safe, OOM propagates, stdlib has no silent data loss
**Plans**: 3/3 complete

Plans:
- [x] 02-01-PLAN.md — Fix string interpolation temp buffer leak via MIR defer injection
- [x] 02-02-PLAN.md — Fix OOM error propagation in codegen and sweep stdlib catch {}
- [x] 02-03-PLAN.md — Ptr(T).cast() method-style pointer constructors

### Phase 3: LSP Hardening
**Goal**: LSP server handles large payloads and long sessions without memory growth or crashes
**Plans**: 2/2 complete

Plans:
- [x] 03-01-PLAN.md — LSP header buffer hardening (4096 bytes, truncation detection)
- [x] 03-02-PLAN.md — LSP per-request arena memory and content-length guard

</details>

<details>
<summary>✅ v0.10 Test Suite & Code Quality (Phases 4-7) — SHIPPED 2026-03-25</summary>

### Phase 4: Codegen Correctness
**Goal**: The tester module compiles and all 100 runtime tests run and pass
**Depends on**: Phase 3
**Requirements**: CGEN-01, CGEN-02, CGEN-03
**Success Criteria** (what must be TRUE):
  1. `orhon build` on the tester module produces valid Zig with no `type 'i32' has no members` or similar errors
  2. Cross-module struct methods with `const &` parameters emit `&arg` at every call site in generated Zig
  3. A reference to `math.Vec2(f64)` where `Vec2` does not exist in module `math` produces a clear Orhon-level error before codegen runs
  4. Test stages 09 (language) and 10 (runtime) both pass — 100 tests executed, 0 compilation failures
**Plans**: 2/2 complete

Plans:
- [x] 04-01-PLAN.md — Fix collection .new() constructor codegen (CGEN-01)
- [x] 04-02-PLAN.md — Fix cross-module ref-passing and qualified generic validation (CGEN-02, CGEN-03)

### Phase 5: Error Suppression Sweep
**Goal**: The compiler and stdlib have no remaining silent error suppressors
**Depends on**: Phase 4
**Requirements**: ESUP-01, ESUP-02
**Success Criteria** (what must be TRUE):
  1. Zero compiler-side `catch unreachable` in codegen.zig — 4 thread allocation sites replaced with `@panic`
  2. Zero data-loss `catch {}` in stdlib — collections.zig and stream.zig use `catch return`/`catch break`; remaining `catch {}` are fire-and-forget void I/O where error discard is intentional
  3. No test stage regresses as a result of the sweep — `./testall.sh` stages 01-10 still pass
**Plans**: 2/2 complete

Plans:
- [x] 05-01-PLAN.md — Fix 4 compiler-side catch unreachable in codegen.zig thread spawning (ESUP-01)
- [x] 05-02-PLAN.md — Fix 28 catch {} across 6 stdlib sidecar files (ESUP-02)

### Phase 6: Polish & Completeness
**Goal**: Version numbers are consistent, string interpolation does not leak, and the example module documents every implemented feature
**Depends on**: Phase 5
**Requirements**: HYGN-01, HYGN-02, DOCS-01
**Success Criteria** (what must be TRUE):
  1. `build.zig`, `build.zig.zon`, and `PROJECT.md` all report the same version string with no drift
  2. A program that uses `@{variable}` string interpolation in a loop does not grow memory unboundedly — temp buffers are freed after each interpolation
  3. The example module compiles successfully and contains working demonstrations of RawPtr/VolatilePtr, `#bitsize`, generics, `typeOf()`, and `include` vs `import`
**Plans**: 2/2 complete

Plans:
- [x] 06-01-PLAN.md — Align version to v0.10.0 and fix string interpolation memory leak (HYGN-01, HYGN-02)
- [x] 06-02-PLAN.md — Complete example module with missing feature demonstrations (DOCS-01)

### Phase 7: Full Test Suite Gate
**Goal**: Every test stage passes, confirming the v0.10 milestone is complete
**Depends on**: Phase 6
**Requirements**: GATE-01
**Success Criteria** (what must be TRUE):
  1. `./testall.sh` exits 0 with all 11 stages reported as passed
  2. No stage produces unexpected output or skipped tests — failure count is exactly 0 across all stages
**Plans**: 1/1 complete

Plans:
- [x] 07-01-PLAN.md — Fix stale null union test assertions and add PEG builder string interpolation (GATE-01)

</details>

### 🚧 v0.11 Language Simplification (In Progress)

**Milestone Goal:** Simplify language semantics with two breaking changes — const auto-borrow and Ptr syntax unification — before wider adoption.

#### Phase 8: Const Auto-Borrow
**Goal**: Const non-primitive values automatically pass as `const &` instead of silently deep-copying
**Depends on**: Phase 7
**Requirements**: CBOR-01, CBOR-02, CBOR-03
**Success Criteria** (what must be TRUE):
  1. A `const` struct value passed to a function generates `&value` at the call site in Zig — no implicit copy
  2. Calling `.copy()` on a `const` value produces an owned copy — explicit opt-in still works
  3. A `var` struct value passed by value still generates a move — `var` semantics are unchanged
  4. Programs that previously relied on implicit const copy continue compiling — the codegen change is transparent to correct code
**Plans**: 2 plans

Plans:
- [x] 08-01-PLAN.md — MIR annotator const-variable tracking and auto-borrow coercion annotation
- [x] 08-02-PLAN.md — CodeGen *const T signature emission, var caller handling, and integration tests

#### Phase 9: Ptr Syntax Simplification
**Goal**: Pointer construction uses type annotation + `&` — verbose `.cast()` syntax is removed
**Depends on**: Phase 8
**Requirements**: PTRS-01, PTRS-02, PTRS-03, PTRS-04
**Success Criteria** (what must be TRUE):
  1. `const p: Ptr(T) = &x` compiles and generates a safe pointer — type annotation drives safety level
  2. `const r: RawPtr(T) = &x` compiles and generates an unsafe pointer
  3. `const v: VolatilePtr(T) = 0xFF200000` compiles and generates a volatile pointer from an integer address
  4. `Ptr(T).cast(&x)` and `Ptr(T, &x)` produce a compile error with a clear migration message
  5. The `ptr_cast_expr` and `ptr_expr` PEG rules are removed from `orhon.peg`
**Plans**: 2 plans

Plans:
- [x] 09-01-PLAN.md — Add type-directed pointer coercion to codegen and update fixtures to new syntax
- [x] 09-02-PLAN.md — Remove old PEG rules, builder code, parser types, dead codegen, and add negative test

#### Phase 10: Compatibility Updates
**Goal**: All existing code using the new semantics compiles — Tamga, example module, tester, and docs are current
**Depends on**: Phase 9
**Requirements**: COMP-01, COMP-02, COMP-03
**Success Criteria** (what must be TRUE):
  1. Tamga companion project builds without errors under the new Ptr syntax
  2. The example module demonstrates the new `const p: Ptr(T) = &x` syntax and const auto-borrow behavior
  3. Language docs (spec files in `docs/`) reflect the removed `.cast()` syntax and new auto-borrow rule
**Plans**: 1 plan

Plans:
- [x] 10-01-PLAN.md — Update Tamga Ptr syntax and verify fixtures/docs are current

#### Phase 11: Full Test Suite Gate
**Goal**: Every test stage passes, confirming the v0.11 milestone is complete
**Depends on**: Phase 10
**Requirements**: GATE-01
**Success Criteria** (what must be TRUE):
  1. `./testall.sh` exits 0 with all 11 stages reported as passed
  2. No stage produces unexpected output or skipped tests — failure count is exactly 0 across all stages
**Plans**: TBD

## Progress

**Execution Order:**
Completed: 1 → 2 → 3 → 4 → 5 → 6 → 7
Current: 8 → 9 → 10 → 11

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Compiler Bug Fixes | v0.9 | 2/2 | Complete | 2026-03-25 |
| 2. Memory & Error Safety | v0.9 | 3/3 | Complete | 2026-03-25 |
| 3. LSP Hardening | v0.9 | 2/2 | Complete | 2026-03-25 |
| 4. Codegen Correctness | v0.10 | 2/2 | Complete | 2026-03-25 |
| 5. Error Suppression Sweep | v0.10 | 2/2 | Complete | 2026-03-25 |
| 6. Polish & Completeness | v0.10 | 2/2 | Complete | 2026-03-25 |
| 7. Full Test Suite Gate | v0.10 | 1/1 | Complete | 2026-03-25 |
| 8. Const Auto-Borrow | v0.11 | 2/2 | Complete |  |
| 9. Ptr Syntax Simplification | v0.11 | 2/2 | Complete |  |
| 10. Compatibility Updates | v0.11 | 1/1 | Complete    | 2026-03-25 |
| 11. Full Test Suite Gate | v0.11 | 0/? | Complete    | 2026-03-25 |
