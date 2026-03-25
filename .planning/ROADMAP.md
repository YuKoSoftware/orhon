# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- 🚧 **v0.12 Quality & Polish** - Phases 12-14 (in progress)

## Phases

<details>
<summary>✅ v0.10 Bug Fix & Cleanup (Phases 1-7) - SHIPPED 2026-03-24</summary>

### Phase 1: Cross-Module Codegen Fixes
**Goal**: Cross-module const argument passing and generic type validation work correctly
**Plans**: Complete

### Phase 2: Error Handling & Pointer Constructors
**Goal**: OOM errors propagate honestly and pointer constructors use method style
**Plans**: Complete

### Phase 3: LSP Memory & Security
**Goal**: LSP server handles memory and malformed input safely
**Plans**: Complete

### Phase 4-7: Earlier phases
**Plans**: Complete

</details>

<details>
<summary>✅ v0.11 Language Simplification (Phases 8-11) - SHIPPED 2026-03-25</summary>

### Phase 8: Const Auto-Borrow
**Goal**: Const non-primitive values auto-pass as `const &` at call sites
**Plans**: Complete

### Phase 9: Ptr Syntax Simplification
**Goal**: Type annotation + `&` replaces verbose `.cast()` syntax
**Plans**: Complete

### Phase 10: Tamga Compatibility Update
**Goal**: Tamga companion project updated for v0.11 syntax changes
**Plans**: Complete

### Phase 11: Full Test Suite Gate
**Goal**: All 240 tests pass across 11 stages
**Plans**: Complete

</details>

### 🚧 v0.12 Quality & Polish (In Progress)

**Milestone Goal:** Close all remaining bugs, add fuzz testing, eliminate the intermittent test failure — zero open issues.

## Phase Details

### Phase 12: Fuzz Testing
**Goal**: The lexer and parser are covered by fuzz targets that run without crashes on random input
**Depends on**: Phase 11
**Requirements**: FUZZ-01, FUZZ-02
**Success Criteria** (what must be TRUE):
  1. `zig build fuzz` runs a lexer fuzz target — arbitrary byte sequences don't panic or crash the lexer
  2. Parser fuzz target runs against random token streams — no panics, no crashes, all error paths return gracefully
  3. Fuzz targets integrated into the existing `src/fuzz.zig` harness and documented in COMPILER.md
**Plans**: 1 plan
Plans:
- [x] 12-01-PLAN.md — Parser fuzz test, standalone harness hardening, COMPILER.md docs

### Phase 13: Bug Fixes
**Goal**: Tester module compiles end-to-end and unit tests pass reliably on every run
**Depends on**: Phase 12
**Requirements**: TEST-01, RELY-01
**Success Criteria** (what must be TRUE):
  1. `orhon test` on the tester module produces zero cross-module codegen errors — test stages 09 and 10 fully pass
  2. `zig build test` passes on 5 consecutive runs with no intermittent failures
  3. Root cause of the intermittent unit test failure is identified and fixed at the source — no retries, no skips
**Plans**: 1 plan
Plans:
- [ ] 13-01-PLAN.md — Fix intermittent test race, verify tester module, update TODO.md

### Phase 14: Gate
**Goal**: The full test suite passes cleanly — zero failures across all 11 stages
**Depends on**: Phase 13
**Requirements**: GATE-01
**Success Criteria** (what must be TRUE):
  1. `./testall.sh` completes with 0 failures across all 11 stages
  2. No stage produces unexpected output or skipped tests
**Plans**: TBD

## Progress

**Execution Order:** Phases execute in numeric order: 12 → 13 → 14

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 8. Const Auto-Borrow | v0.11 | Complete | Complete | 2026-03-25 |
| 9. Ptr Syntax Simplification | v0.11 | Complete | Complete | 2026-03-25 |
| 10. Tamga Compatibility Update | v0.11 | Complete | Complete | 2026-03-25 |
| 11. Full Test Suite Gate | v0.11 | Complete | Complete | 2026-03-25 |
| 12. Fuzz Testing | v0.12 | 1/1 | Complete    | 2026-03-25 |
| 13. Bug Fixes | v0.12 | 0/1 | In progress | - |
| 14. Gate | v0.12 | 0/TBD | Not started | - |
