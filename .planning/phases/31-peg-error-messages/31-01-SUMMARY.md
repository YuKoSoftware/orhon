---
phase: 31-peg-error-messages
plan: 01
subsystem: parser
tags: [peg, engine, error-messages, diagnostics]

# Dependency graph
requires:
  - phase: 30-error-quality
    provides: error reporting infrastructure used throughout the compiler
provides:
  - PEG engine accumulates all expected tokens at furthest failure position
  - ParseError.expected_set field with deduplicated []const TokenKind
  - kindDisplayName() helper for human-readable token names
  - Multi-token expected set formatting in module.zig and main.zig consumers

affects: [lsp, any code that reads ParseError]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Fixed-size accumulator buffers (two 64-slot arrays) instead of heap allocation for error tracking
    - Dedup-on-read pattern: accumulate raw during parsing, deduplicate only in getError()

key-files:
  created: []
  modified:
    - src/peg/engine.zig
    - src/module.zig
    - src/main.zig

key-decisions:
  - "Use two fixed arrays (furthest_expected_buf + expected_set_buf) instead of BoundedArray — Zig 0.15 has no std.BoundedArray"
  - "Dedup-on-read: accumulate raw tokens during parsing, deduplicate only in getError() to avoid dedup cost in hot path"
  - "formatExpectedSet uses ArrayListUnmanaged (not ArrayList.init) matching codebase convention in Zig 0.15"

patterns-established:
  - "kindDisplayName: strips kw_ prefix from keywords, explicit cases for eof/newline/literals"
  - "Multi-token error format: 2 items = 'X or Y', 3+ = 'X, Y, or Z' (Oxford comma)"

requirements-completed: [PEG-01]

# Metrics
duration: 22min
completed: 2026-03-28
---

# Phase 31 Plan 01: PEG Error Messages Summary

**PEG engine now accumulates all expected tokens at the furthest failure position and formats multi-token expected sets as "expected 'func', 'struct', or 'enum'" in parse errors**

## Performance

- **Duration:** 22 min
- **Started:** 2026-03-28T21:04:00Z
- **Completed:** 2026-03-28T21:26:01Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments

- PEG engine tracks all expected token kinds at the furthest failure position using a fixed-size accumulator, resets on advance, accumulates on tie
- getError() deduplicates the accumulated set and returns it as `expected_set: []const TokenKind` in ParseError
- kindDisplayName() provides human-readable token names (strips kw_ prefix, handles eof/newline/literals)
- module.zig parse error consumer shows "expected 'X', 'Y', or 'Z'" for multi-token failures, keeps "unexpected 'foo'" for single-token
- main.zig analysis output has same multi/single-token branching
- All 266 tests pass including 4 new engine unit tests

## Task Commits

1. **Task 1: Extend Engine with expected-set accumulation and dedup** - `6fae816` (feat, TDD)
2. **Task 2: Update consumer call sites to format multi-token expected sets** - `a450bdb` (feat)
3. **Task 3: Full test suite validation** - no separate commit (validation only)

## Files Created/Modified

- `src/peg/engine.zig` - Added kindDisplayName(), expected_set field in ParseError, fixed-size accumulator in Engine, rewrote trackFailure, updated getError, 4 new unit tests
- `src/module.zig` - Added formatExpectedSet() helper, updated parse error consumer to branch on expected_set.len
- `src/main.zig` - Updated analysis error output to show multi-token expected set

## Decisions Made

- Used two fixed arrays (`furthest_expected_buf[64]` + `expected_set_buf[64]`) instead of `std.BoundedArray` — Zig 0.15.2 does not have `std.BoundedArray` in std namespace
- Dedup-on-read: accumulate raw tokens during parsing (hot path stays cheap), deduplicate only in getError() which is called once on failure
- `formatExpectedSet` uses `std.ArrayListUnmanaged` with explicit allocator args matching the existing pattern in module.zig (Zig 0.15 ArrayList doesn't have `.init()`)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] std.BoundedArray does not exist in Zig 0.15**
- **Found during:** Task 1 (Engine implementation)
- **Issue:** Plan specified `std.BoundedArray(TokenKind, 64)` but this type doesn't exist in Zig 0.15.2
- **Fix:** Replaced with two plain fixed arrays: `furthest_expected_buf: [64]TokenKind` + `furthest_expected_len: u8` for accumulation, same pattern for dedup output
- **Files modified:** src/peg/engine.zig
- **Verification:** zig build test passes
- **Committed in:** 6fae816 (Task 1 commit)

**2. [Rule 1 - Bug] char_literal token kind does not exist in TokenKind enum**
- **Found during:** Task 1 (kindDisplayName implementation)
- **Issue:** Plan included `.char_literal => "character literal"` in kindDisplayName switch but TokenKind has no char_literal variant
- **Fix:** Removed that case from the switch statement
- **Files modified:** src/peg/engine.zig
- **Verification:** zig build test passes
- **Committed in:** 6fae816 (Task 1 commit)

**3. [Rule 1 - Bug] std.ArrayList(u8).init() doesn't exist in Zig 0.15**
- **Found during:** Task 2 (formatExpectedSet in module.zig)
- **Issue:** Plan specified `std.ArrayList(u8).init(alloc)` but in Zig 0.15, std.ArrayList returns an Aligned struct without an `.init()` method
- **Fix:** Used `std.ArrayListUnmanaged(u8){}` with explicit allocator args matching the existing codebase convention
- **Files modified:** src/module.zig
- **Verification:** zig build test + bash test/11_errors.sh all pass
- **Committed in:** a450bdb (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (all Rule 1 bugs — Zig 0.15 API mismatches in plan)
**Impact on plan:** All three were API version issues, not design issues. The implemented behavior matches the plan exactly — only the Zig syntax changed.

## Issues Encountered

None beyond the three auto-fixed Zig 0.15 API mismatches.

## Next Phase Readiness

- PEG error messages are now improved — choice-point failures show all alternatives
- No known blockers for next phase
- All 266 tests green

---
*Phase: 31-peg-error-messages*
*Completed: 2026-03-28*
