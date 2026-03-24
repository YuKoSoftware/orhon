---
phase: 03-lsp-hardening
plan: 02
subsystem: lsp
tags: [arena-allocator, memory-management, lsp, zig]

# Dependency graph
requires: []
provides:
  - Per-request ArenaAllocator in runAnalysis — intermediate pass objects bulk-freed after each analysis cycle
  - Unit tests verifying arena cleanup does not corrupt diagnostics/symbols
  - Fixed all_symbols ArrayList backing buffer leak
affects: [lsp, memory-safety]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Scratch arena pattern: var scratch = std.heap.ArenaAllocator.init(allocator); defer scratch.deinit(); const a = scratch.allocator()"
    - "Long-lived vs scratch allocator split: pass objects use 'a', returned data uses 'allocator'"
    - "ArrayList deinit after dupe: deinit the temporary collection after copying items into the returned slice"

key-files:
  created: []
  modified:
    - src/lsp.zig

key-decisions:
  - "Pass objects (reporter, mod_resolver, declarations, type resolver, checkers) use scratch arena — they are intermediate and don't need to outlive the analysis cycle"
  - "toDiagnostics and extractSymbols continue using long-lived allocator — their results are returned to the caller and freed via freeDiagnostics/freeSymbols"
  - "all_symbols ArrayList backing buffer must be explicitly deinited after dupe — the arena only frees arena allocations, not allocations made via the long-lived allocator through ArrayList.append"

patterns-established:
  - "Scratch arena split: always pass 'a' to pass objects and 'allocator' to result builders"
  - "ArrayList lifetime: deinit temporary ArrayLists after duping items into the returned slice"

requirements-completed: [LSP-01]

# Metrics
duration: 18min
completed: 2026-03-24
---

# Phase 03 Plan 02: LSP Arena Allocator Summary

**Per-request ArenaAllocator in runAnalysis bulk-frees all intermediate pass objects after each analysis cycle, plus unit tests that caught and fixed an ArrayList backing buffer leak**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-03-24T17:41:00Z
- **Completed:** 2026-03-24T17:59:22Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Introduced `var scratch = std.heap.ArenaAllocator.init(allocator)` in `runAnalysis` — all 8 pass objects (reporter, mod_resolver, declarations, type resolver, ownership, borrow, thread safety, propagation checkers) now use `a` (scratch arena) instead of the long-lived allocator
- Removed individual `defer deinit()` calls for all pass objects — the arena bulk-frees them all on function exit
- Preserved long-lived allocator for `toDiagnostics` and `extractSymbols` calls so diagnostics and symbol strings survive arena deinitialization
- Added two unit tests using `std.testing.allocator` (GPA in debug mode) that detect use-after-free and leaks
- Tests revealed and fixed a pre-existing leak: `all_symbols` ArrayList backing buffer was never freed after duping items into the returned slice

## Task Commits

1. **Task 1: Add per-request ArenaAllocator to runAnalysis** - `fc3176d` (feat)
2. **Task 2: Unit tests + all_symbols leak fix** - `b12f11b` (test)

**Plan metadata:** _(committed as part of final docs commit)_

## Files Created/Modified

- `src/lsp.zig` - Added scratch arena to runAnalysis, removed deferred deinits for pass objects, fixed all_symbols ArrayList leak, added 2 unit tests

## Decisions Made

- Pass objects use scratch arena `a` — they are intermediate analysis state, not results
- `toDiagnostics` and `extractSymbols` keep the long-lived `allocator` — their output is returned to the caller and freed by `freeDiagnostics`/`freeSymbols`
- `all_symbols.deinit(allocator)` called after `allocator.dupe(SymbolInfo, all_symbols.items)` — the ArrayList capacity is temporary, only the duped slice is returned

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed all_symbols ArrayList backing buffer leak**
- **Found during:** Task 2 (unit test writing — TDD RED/GREEN)
- **Issue:** `all_symbols` ArrayList was appended to via `allocator` (long-lived), but `all_symbols.deinit(allocator)` was never called after the items were duped into the returned slice. The backing buffer leaked on every call to `runAnalysis`.
- **Fix:** Added `all_symbols.deinit(allocator)` after the dupe in a `blk` expression so the capacity is freed while the duped items slice is returned
- **Files modified:** `src/lsp.zig`
- **Verification:** `zig build test` with `std.testing.allocator` shows 0 leaked, 194 tests passed
- **Committed in:** `b12f11b` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug)
**Impact on plan:** Auto-fix necessary for correctness — the plan's goal is preventing memory growth, so fixing this leak is squarely in scope. No scope creep.

## Issues Encountered

- Edit tool reported success on first attempt but file was not modified (stale cache). Subsequent re-read and re-edit succeeded. No impact on output.

## Next Phase Readiness

- LSP memory hardening (Plan 02) complete — per-request arena bulk-frees pass allocations
- Combined with Plan 01 (readMessage bounds enforcement), the LSP server now has both bounded input handling and bounded memory growth per request
- No known LSP memory issues remaining in current phase scope

---
*Phase: 03-lsp-hardening*
*Completed: 2026-03-24*
