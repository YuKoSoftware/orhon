---
phase: 28-cross-compile-cache-docs
plan: 01
subsystem: build
tags: [zig_runner, cross-compile, cache, build-system]

# Dependency graph
requires:
  - phase: 27-c-interop-multi-module-build
    provides: corrected build system foundations for zig_runner
provides:
  - BLD-04 fixed: target_flag string lifetime extends past runZigIn in both buildAll and buildWithType
  - BLD-05 fixed: .zig-cache cleanup after zig-out cleanup in both build functions
affects: [cross-compilation, optimized builds, cache cleanup]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Optional allocation pattern: var alloc: ?[]const u8 = null; defer if (alloc) |a| free(a);"

key-files:
  created: []
  modified:
    - src/zig_runner.zig

key-decisions:
  - "target_flag_alloc: ?[]const u8 = null pattern — defer outside the if block ensures string lives until after runZigIn returns"
  - "Clean both .zig-cache inside GENERATED_DIR and project-root zig-cache/.zig-cache after every build"

patterns-established:
  - "Optional allocation pattern for conditionally-allocated strings that must outlive the if block"

requirements-completed: [BLD-04, BLD-05]

# Metrics
duration: 3min
completed: 2026-03-28
---

# Phase 28 Plan 01: Cross-Compile & Cache Fixes Summary

**Fixed use-after-free on cross-compilation target flag and .zig-cache leak after optimized builds in zig_runner.zig**

## Performance

- **Duration:** ~3 min
- **Started:** 2026-03-28T12:27:46Z
- **Completed:** 2026-03-28T12:30:39Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- BLD-04: `target_flag` was freed inside the `if (target.len > 0)` block by `defer`, before `runZigIn` could read it. Replaced with `var target_flag_alloc: ?[]const u8 = null` pattern — defer placed outside the `if` block ensures string lifetime extends past the Zig invocation. Fixed in both `buildAll` and `buildWithType`.
- BLD-05: After `deleteTree(generated_zig_out)`, now also deletes `.zig-cache` inside `GENERATED_DIR` and `zig-cache`/`.zig-cache` from the project root. Applied to both `buildAll` and `buildWithType`.
- All 262 tests pass with no regressions.

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix cross-compilation use-after-free and -fast cache leak** - `9514e30` (fix)
2. **Task 2: Run full test suite** - `7a5aa16` (test)

**Plan metadata:** (pending final docs commit)

## Files Created/Modified

- `src/zig_runner.zig` - Fixed BLD-04 (target_flag lifetime) and BLD-05 (.zig-cache cleanup) in buildAll and buildWithType

## Decisions Made

- Used `var target_flag_alloc: ?[]const u8 = null` outside the `if` block rather than restructuring the code more invasively. This is idiomatic Zig for conditionally allocated strings that must outlive a conditional block.
- Cleaning cache directories unconditionally (not just on `-fast` flag) since leftover cache dirs are always noise in the output directory.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- BLD-04 and BLD-05 both resolved — cross-compilation and fast builds are clean
- Plan 02 of phase 28 can proceed

---
*Phase: 28-cross-compile-cache-docs*
*Completed: 2026-03-28*
