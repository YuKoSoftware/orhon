---
gsd_state_version: 1.0
milestone: v0.11
milestone_name: language-simplification
status: Defining requirements
stopped_at: null
last_updated: "2026-03-25T12:00:00.000Z"
progress:
  total_phases: 0
  completed_phases: 0
  total_plans: 0
  completed_plans: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-25)

**Core value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.
**Current focus:** Defining requirements for v0.11

## Current Position

Phase: Not started (defining requirements)
Plan: —
Status: Defining requirements
Last activity: 2026-03-25 — Milestone v0.11 started

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: -
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 4. Codegen Correctness | TBD | - | - |
| 5. Error Suppression Sweep | TBD | - | - |
| 6. Polish & Completeness | TBD | - | - |
| 7. Full Test Suite Gate | TBD | - | - |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 01-compiler-bug-fixes P02 | 25 | 2 tasks | 4 files |
| Phase 01 P01 | 40 | 2 tasks | 5 files |
| Phase 02 P03 | 18 | 2 tasks | 4 files |
| Phase 02-memory-error-safety P02 | 908 | 2 tasks | 15 files |
| Phase 03-lsp-hardening P01 | 8 | 2 tasks | 1 files |
| Phase 03-lsp-hardening P02 | 18 | 2 tasks | 1 files |
| Phase 04 P02 | 12 | 2 tasks | 1 files |
| Phase 04 P01 | 35 | 2 tasks | 1 files |
| Phase 05-error-suppression-sweep P02 | 12 | 2 tasks | 2 files |
| Phase 05-error-suppression-sweep P01 | 45 | 2 tasks | 1 files |
| Phase 06-polish-completeness P02 | 2 | 2 tasks | 2 files |
| Phase 06-polish-completeness P01 | 15 | 2 tasks | 4 files |
| Phase 07-full-test-suite-gate P01 | 13 | 2 tasks | 4 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Milestone scope: Fix bugs before architecture work — correctness before performance/elegance
- Milestone scope: Scope to TODO.md bugs only — clear boundary, avoid scope creep
- Stdlib policy: Clean up 103 catch {} — safety hazard for a "safe" language compiler
- [Phase 01-compiler-bug-fixes]: value_to_const_ref coercion mirrors array_to_slice in codegen — both prepend & for parameter passing
- [Phase 01-compiler-bug-fixes]: Qualified generic validation falls back to trusting when all_decls is null or module not yet processed — avoids false positives in dependency order
- [Phase 01]: Const values are implicitly copyable — is_const field added to VarState for clean const-vs-var ownership tracking
- [Phase 01]: Auto-inject stdlib imports in codegen — str and collections always auto-imported in generated Zig files for ergonomic string/collection usage
- [Phase 02-memory-error-safety]: Fixed both interpolation codegen paths proactively even though they are currently dormant — when PEG builder gains interpolation support, OOM will propagate correctly
- [Phase 02-memory-error-safety]: Codegen regression tests check source patterns directly via grep on src/codegen.zig when code paths are not yet reachable from user programs
- [Phase 02-memory-error-safety]: Dedicated ptr_cast_expr grammar rule instead of extending method_call — cast is a reserved keyword, specific rule is cleaner
- [Phase 02-memory-error-safety]: Category A I/O catch sites documented with fire-and-forget comments; Category B data builders fixed with catch continue or catch return safe defaults
- [Phase 03-lsp-hardening]: MAX_HEADER_LINE = 4096 chosen to cover all realistic LSP header values; enlarging from 1024 is the primary fix for LSP-02
- [Phase 03-lsp-hardening]: MAX_CONTENT_LENGTH = 64 MiB chosen as practical upper bound preventing OOM from malicious payloads (LSP-03)
- [Phase 03-lsp-hardening]: Pass objects use scratch arena; toDiagnostics and extractSymbols use long-lived allocator for returned results
- [Phase 03-lsp-hardening]: all_symbols ArrayList backing buffer must be deinited after dupe — not freed by arena since it was allocated via long-lived allocator
- [Phase 04-02]: Instance method cross-module lookup uses struct name from resolved type to find owning module (no false positives)
- [Phase 04-02]: CGEN-03 qualified generic validation already correct in resolver.zig — no code change needed, two unit tests confirm coverage
- [Phase 04]: Collection .new() detection via type_expr MIR kind — PEG builder transparency strips collection_expr to element type, so .type_expr is the correct check
- [Phase 05-error-suppression-sweep]: catch |_| {} is invalid Zig 0.15 syntax — catch {} is the only valid error discard; fire-and-forget I/O sites keep catch {} with comments
- [Phase 05-error-suppression-sweep]: ESUP-02: OOM data-loss fixed in collections (catch return/break) and stream (catch return/catch block); grep=0 unachievable for fire-and-forget sites by design
- [Phase 05-error-suppression-sweep]: @panic used for thread spawn failures in generated Zig — generated return type is _OrhonHandle(T) not anyerror!, making error propagation incompatible; @panic avoids UB and gives actionable error messages
- [Phase 06-polish-completeness]: VolatilePtr and #bitsize demonstrated as comment-only blocks in example module — hardware register usage and anchor-file metadata cannot run in standard programs
- [Phase 06-polish-completeness]: include vs import shown as comment-only alongside live import to avoid symbol conflicts in example module
- [Phase 06-polish-completeness]: Version unified to v0.10.0 across build.zig, build.zig.zon, and PROJECT.md
- [Phase 06-polish-completeness]: Interpolation codegen uses pre-statement hoisting buffer (pre_stmts) to pair allocPrint with defer free — separate inline variant for MIR temp_var path to avoid double-hoisting
- [Phase 07-full-test-suite-gate]: Interpolation at builder level not grammar level — lexer correctly captures @{expr} as part of STRING_LITERAL token text
- [Phase 07-full-test-suite-gate]: catch unreachable vs catch |err| return err — conditioned on funcReturnTypeClass() for interpolation OOM handling
- [Phase 07-full-test-suite-gate]: markInterpolationReplacement sets injected_name on .interpolation MirNode — codegen checks injected_name first to avoid double-allocation

### Pending Todos

None yet.

### Blockers/Concerns

None yet.

## Session Continuity

Last session: 2026-03-25T08:58:17.983Z
Stopped at: Completed 07-01-PLAN.md — all 11 test stages pass, 236 tests, 0 failures
Resume file: None
