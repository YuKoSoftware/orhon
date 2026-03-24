# Roadmap: Orhon Compiler — Bug Fixes & Cleanup

## Overview

Three focused phases to clear the correctness debt accumulated through rapid v0.9.x development. Phase 1 fixes the compiler bugs that produce wrong or crashing output. Phase 2 eliminates the memory and error handling hazards that contradict the compiler's safety contract. Phase 3 hardens the LSP so it can run reliably during long editing sessions. After all three phases, `./testall.sh` passes cleanly and the codebase has no known correctness holes.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Compiler Bug Fixes** - Fix the four codegen/analysis bugs that produce wrong or crashing output (completed 2026-03-24)
- [ ] **Phase 2: Memory & Error Safety** - Eliminate memory leaks and silent error suppression throughout the compiler and stdlib
- [ ] **Phase 3: LSP Hardening** - Make the language server memory-safe and robust against large or malicious requests

## Phase Details

### Phase 1: Compiler Bug Fixes
**Goal**: The compiler produces correct output for every known failing case
**Depends on**: Nothing (first phase)
**Requirements**: BUG-01, BUG-02, BUG-03, BUG-04
**Success Criteria** (what must be TRUE):
  1. Cross-module struct method calls emit `const &` argument passing, not by-value copies
  2. Qualified generic types like `math.Vec2(f64)` fail with a clear error when the target type does not exist in the referenced module
  3. Passing a const struct to a function by value does not trigger a spurious ownership-move error
  4. `orhon test` actually runs test blocks and reports the correct passed/failed count
**Plans**: 2 plans

Plans:
- [x] 01-01-PLAN.md — Fix ownership const-as-copy (BUG-03) and orhon test output (BUG-04)
- [x] 01-02-PLAN.md — Fix cross-module const & passing (BUG-01) and qualified generic validation (BUG-02)

### Phase 2: Memory & Error Safety
**Goal**: The compiler and stdlib have no silent error suppression or unrecovered memory leaks
**Depends on**: Phase 1
**Requirements**: MEM-01, MEM-02, MEM-03, MEM-04
**Success Criteria** (what must be TRUE):
  1. String interpolation `@{variable}` expressions do not leak temp buffers — cleanup happens at each call site or via a documented arena strategy
  2. Codegen never panics with `catch unreachable` on OOM — all three sites propagate errors through the Zig error system
  3. All 103 `catch {}` instances across the 15 stdlib bridge files are replaced with explicit propagation or a documented, consistent strategy
  4. Tester module pointer and collection constructors use `.new()`/`.cast()` method-style — no bare type-as-value construction remains
**Plans**: 3 plans

Plans:
- [x] 02-01-PLAN.md — Fix interpolation catch unreachable in codegen (MEM-01, MEM-02)
- [x] 02-02-PLAN.md — Stdlib catch {} sweep across 15 bridge files (MEM-03)
- [x] 02-03-PLAN.md — Add Ptr .cast() constructor and migrate tester/example (MEM-04)

### Phase 3: LSP Hardening
**Goal**: The language server runs without unbounded memory growth and rejects oversized input safely
**Depends on**: Phase 2
**Requirements**: LSP-01, LSP-02, LSP-03
**Success Criteria** (what must be TRUE):
  1. A long editing session does not cause unbounded LSP memory growth — `runAnalysis()` uses a per-request arena that is freed after each request
  2. Header lines longer than the previous fixed 1024-byte buffer are handled without truncation or buffer overrun
  3. A content-length header claiming an oversized payload is rejected with an error rather than triggering an OOM allocation
**Plans**: 2 plans

Plans:
- [ ] 03-01-PLAN.md — Harden readMessage with larger header buffer and content-length guard (LSP-02, LSP-03)
- [ ] 03-02-PLAN.md — Per-request ArenaAllocator in runAnalysis (LSP-01)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Compiler Bug Fixes | 2/2 | Complete   | 2026-03-24 |
| 2. Memory & Error Safety | 1/3 | In Progress|  |
| 3. LSP Hardening | 0/2 | Not started | - |
