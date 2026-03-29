---
gsd_state_version: 1.0
milestone: v0.17
milestone_name: Codegen Refactor & Error Quality
status: verifying
stopped_at: Completed 35-01-PLAN.md
last_updated: "2026-03-29T12:06:33.401Z"
last_activity: 2026-03-29
progress:
  total_phases: 8
  completed_phases: 7
  total_plans: 11
  completed_plans: 11
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-28)

**Core value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.
**Current focus:** Phase 35 — zig-runner-split

## Current Position

Phase: 36
Plan: Not started
Status: Phase complete — ready for verification
Last activity: 2026-03-29

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Cumulative:**

- 7 milestones shipped (v0.10-v0.16)
- 28 phases, 38 plans total

**v0.17 so far:**

- Plans completed: 0
- Average duration: N/A

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.

- [Phase 29]: Split codegen_exprs.zig further into codegen_match.zig because MIR expressions section was 1895 lines vs estimated 1180
- [Phase 29]: Made all CodeGen struct methods pub to allow helper files to call via cg.method()
- [Phase 29]: File-scope pub forwarders in codegen.zig for static functions (opToZig, mirIsString, isTypeAlias, extractValueType) called by helpers
- [Phase 30-error-quality]: Adaptive Levenshtein threshold: 1 for names len<=4, 2 for longer — reduces false positives on short identifiers
- [Phase 30-error-quality]: 12 guards before identifier error: primitive names, compiler funcs, arithmetic modes (wrap/sat/overflow), module names, enum variants, bitfield flags, else pattern, match guard bound vars
- [Phase 30-error-quality]: Fix match guard body scope: guarded arm body resolves with guard_scope so bound variable x is accessible in arm body
- [Phase 30-error-quality]: Borrow fixture updated to add use-while-borrowed scenario: existing conflict only triggered mutable-new-borrow path (no hint), new scenario triggers checkNotMutablyBorrowedPath which always shows const & hint
- [Phase 31-peg-error-messages]: Use two fixed arrays instead of BoundedArray for PEG error accumulation — Zig 0.15 has no std.BoundedArray
- [Phase 31-peg-error-messages]: Dedup-on-read for PEG expected set: accumulate raw during parsing, deduplicate only in getError() once on failure
- [Phase 33-mir-split]: Underscore-prefixed module import names (_mir_types, _mir_registry, _mir_node) to avoid Zig shadowing conflicts with local variables
- [Phase 33-mir-split]: pub const re-exports in mir.zig for all 9 moved types — zero downstream changes required
- [Phase 33-mir-split]: mir.zig reduced to 15-line re-export facade — all 6 mir_*.zig files contain implementations
- [Phase 34-main-split]: pipeline.zig calls _commands directly for emitZigProject/moveArtifactsToSubfolder — avoids main.zig routing
- [Phase 35-zig-runner-split]: anytype for generateSharedCImportFiles targets param — avoids circular import between zig_runner_build and zig_runner_multi

### Pending Todos

None.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|

### Blockers/Concerns

None.
| Phase 29 P01 | 126 | 1 tasks | 7 files |
| Phase 30-error-quality P01 | 45m | 2 tasks | 4 files |
| Phase 30-error-quality P02 | 25m | 2 tasks | 6 files |
| Phase 31-peg-error-messages P01 | 22 | 3 tasks | 3 files |
| Phase 33-mir-split P01 | 10 | 1 tasks | 5 files |
| Phase 33-mir-split P02 | 15m | 1 tasks | 4 files |
| Phase 34-main-split P02 | 15 | 2 tasks | 4 files |
| Phase 35-zig-runner-split P01 | 10m | 2 tasks | 5 files |

## Session Continuity

Last activity: 2026-03-28
Stopped at: Completed 35-01-PLAN.md
Resume file: None
