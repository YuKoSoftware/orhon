# Roadmap: Orhon Compiler — Test Suite & Code Quality

## Overview

Four phases to complete the v0.10 milestone. Phase 4 fixes the codegen bugs responsible for 100 failing test cases. Phase 5 sweeps the remaining silent error suppressors that contradict the compiler's safety contract. Phase 6 closes the polish gaps: version drift, memory leak, and example module holes. Phase 7 is a verification gate — `./testall.sh` must pass all 11 stages cleanly before the milestone closes.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Completed in v0.9 milestone
- Integer phases (4, 5, 6, 7): This milestone (v0.10)
- Decimal phases (N.1, N.2): Urgent insertions if needed (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 4: Codegen Correctness** - Fix the tester module codegen failures that block 100 runtime tests (completed 2026-03-25)
- [ ] **Phase 5: Error Suppression Sweep** - Replace all remaining silent `catch unreachable` and `catch {}` with proper error propagation
- [ ] **Phase 6: Polish & Completeness** - Align version numbers, fix string interpolation leak, complete example module coverage
- [ ] **Phase 7: Full Test Suite Gate** - Verify all 11 test stages pass with zero failures

## Phase Details

### Phase 4: Codegen Correctness
**Goal**: The tester module compiles and all 100 runtime tests run and pass
**Depends on**: Phase 3 (LSP Hardening — v0.9 milestone)
**Requirements**: CGEN-01, CGEN-02, CGEN-03
**Success Criteria** (what must be TRUE):
  1. `orhon build` on the tester module produces valid Zig with no `type 'i32' has no members` or similar errors
  2. Cross-module struct methods with `const &` parameters emit `&arg` at every call site in generated Zig
  3. A reference to `math.Vec2(f64)` where `Vec2` does not exist in module `math` produces a clear Orhon-level error before codegen runs
  4. Test stages 09 (language) and 10 (runtime) both pass — 100 tests executed, 0 compilation failures
**Plans:** 2/2 plans complete

Plans:
- [x] 04-01-PLAN.md — Fix collection .new() constructor codegen (CGEN-01)
- [x] 04-02-PLAN.md — Fix cross-module ref-passing and qualified generic validation (CGEN-02, CGEN-03)

### Phase 5: Error Suppression Sweep
**Goal**: The compiler and stdlib have no remaining silent error suppressors
**Depends on**: Phase 4
**Requirements**: ESUP-01, ESUP-02
**Success Criteria** (what must be TRUE):
  1. Zero compiler-side `catch unreachable` in codegen.zig — 4 thread allocation sites replaced with `@panic` (generated-code emit instances are correct and remain)
  2. Zero data-loss `catch {}` in stdlib — collections.zig and stream.zig use `catch return`/`catch break`. Remaining `catch {}` are fire-and-forget void I/O (console, tui, fs, system) where error discard is intentional
  3. No test stage regresses as a result of the sweep — `./testall.sh` stages 01-10 still pass
**Plans:** 1/2 plans executed

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
  3. The example module compiles successfully and contains working demonstrations of RawPtr/VolatilePtr, `#bitsize`, any generics, `typeOf()`, and `include` vs `import`
**Plans:** 2 plans

Plans:
- [ ] 06-01-PLAN.md — Align version to v0.10.0 and fix string interpolation memory leak (HYGN-01, HYGN-02)
- [ ] 06-02-PLAN.md — Complete example module with missing feature demonstrations (DOCS-01)

### Phase 7: Full Test Suite Gate
**Goal**: Every test stage passes, confirming the milestone is complete
**Depends on**: Phase 6
**Requirements**: GATE-01
**Success Criteria** (what must be TRUE):
  1. `./testall.sh` exits 0 with all 11 stages reported as passed
  2. No stage produces unexpected output or skipped tests — failure count is exactly 0 across all stages
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 4 → 5 → 6 → 7

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 4. Codegen Correctness | 2/2 | Complete   | 2026-03-25 |
| 5. Error Suppression Sweep | 1/2 | In Progress|  |
| 6. Polish & Completeness | 0/2 | Not started | - |
| 7. Full Test Suite Gate | 0/? | Not started | - |
