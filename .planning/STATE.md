---
gsd_state_version: 1.0
milestone: v0.17
milestone_name: Codegen Refactor & Error Quality
status: executing
stopped_at: Completed 32-02-PLAN.md
last_updated: "2026-03-29T07:17:00Z"
last_activity: 2026-03-29
progress:
  total_phases: 8
  completed_phases: 3
  total_plans: 4
  completed_plans: 6
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-28)

**Core value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.
**Current focus:** Phase 32 — lsp-split

## Current Position

Phase: 32
Plan: 2 of 2 complete
Status: Executing phase 32 — LSP split
Last activity: 2026-03-29

Progress: [█████░░░░░] 50%

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
- [Phase 32-lsp-split]: handleDocumentSymbols in lsp_view (view group per D-05), not lsp_nav
- [Phase 32-lsp-split]: extractParamLabels canonical in lsp_edit, re-exported by lsp_view for shared use
- [Phase 32-lsp-split]: Convenience aliases in lsp.zig for all moved functions to keep handler code unchanged
- [Phase 32-lsp-split]: lspLog in lsp_utils.zig to avoid circular imports between lsp.zig and lsp_analysis.zig

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
| Phase 32-lsp-split P02 | 14m | 2 tasks | 6 files |
| Phase 32-lsp-split P01 | 19m | 2 tasks | 6 files |

## Session Continuity

Last activity: 2026-03-28
Stopped at: Completed 32-02-PLAN.md
Resume file: None
