---
phase: 30-error-quality
plan: 02
subsystem: ownership, borrow, thread_safety, test
tags: [error-quality, ownership-hints, borrow-hints, thread-safety-hints, integration-tests]
dependency_graph:
  requires: [30-01]
  provides: [ownership-fix-hints, borrow-fix-hints, thread-safety-hints, err-quality-integration-tests]
  affects: [src/ownership.zig, src/borrow.zig, src/thread_safety.zig, test/fixtures, test/11_errors.sh]
tech_stack:
  added: []
  patterns:
    - Inline hint appended to error message string via allocPrint (ownership, thread_safety)
    - Conditional hint based on is_mutable flag in addBorrow conflict message (borrow)
    - Standard negative test pattern in test/11_errors.sh (fixture + grep)
key_files:
  created:
    - test/fixtures/fail_did_you_mean.orh
    - test/fixtures/fail_type_mismatch_display.orh
  modified:
    - src/ownership.zig
    - src/borrow.zig
    - src/thread_safety.zig
    - test/fixtures/fail_borrow.orh
    - test/11_errors.sh
decisions:
  - "Borrow fixture updated to add use-while-borrowed scenario that triggers checkNotMutablyBorrowedPath hint, since existing conflict scenario only triggered mutable-new-borrow path (no hint per D-09)"
  - "addBorrow hint conditioned on !is_mutable: read-only borrow attempt against existing mutable borrow gets const & suggestion; mutable borrow attempt does not"
metrics:
  duration: "~25 minutes"
  completed: "2026-03-28"
  tasks_completed: 2
  files_changed: 6
---

# Phase 30 Plan 02: Error Quality — Ownership/Borrow/Thread Hints + Integration Tests Summary

**One-liner:** Actionable fix hints appended to move-after-use, borrow violation, and thread-safety errors, with 4 new integration tests verifying all three ERR requirements end-to-end.

## What Was Built

### Task 1: Fix hints in 3 pass files

**src/ownership.zig — 3 sites updated (D-08, ERR-03):**
- Line ~363: `"use of moved value '{s}'"` → `"use of moved value '{s}' — consider using copy()"`
- Line ~417: field move atomicity error → appended `— consider using copy()`
- Line ~424: same message for known struct without field → appended `— consider using copy()`

**src/borrow.zig — 3 sites updated (D-09, ERR-03):**
- `checkNotMutablyBorrowedPath` field path message: appended `— consider borrowing with const &`
- `checkNotMutablyBorrowedPath` bare variable message: appended `— consider borrowing with const &`
- `addBorrow` conflict message: conditionally appends `— consider borrowing with const &` only when `!is_mutable` (new borrow is read-only)

**src/thread_safety.zig — 1 site updated (D-10, ERR-03):**
- `"use of '{s}' after it was moved into thread '{s}'"` → appended `— shared mutable state requires synchronization`

### Task 2: Integration test fixtures and test cases

**test/fixtures/fail_did_you_mean.orh:** Typo `mesage` (missing 's') with `message` in scope, distance=1. Triggers "did you mean 'message'?" from Plan 01 Levenshtein infrastructure.

**test/fixtures/fail_type_mismatch_display.orh:** `if(42)` triggers "type mismatch in if condition: expected bool, got 'numeric_literal'" from Plan 01 standardized format.

**test/fixtures/fail_borrow.orh (updated):** Added `use_while_borrowed()` function where variable is mutably borrowed then used directly — triggers `checkNotMutablyBorrowedPath` hint "— consider borrowing with const &".

**test/11_errors.sh — 4 new test cases:**
1. `did you mean` grep on fail_did_you_mean.orh → passes (ERR-01)
2. `type mismatch.*expected bool` grep on fail_type_mismatch_display.orh → passes (ERR-02)
3. `consider using copy()` grep on fail_ownership.orh → passes (ERR-03)
4. `consider borrowing with const` grep on fail_borrow.orh → passes (ERR-03)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing functionality] fail_borrow.orh updated to trigger const & hint**
- **Found during:** Task 2 — testing the borrow fixture before writing the test
- **Issue:** Existing `fail_borrow.orh` only exercised the `addBorrow` mutable-new-borrow conflict path (`is_mutable=true`). Per D-09 and plan spec, the const & hint only fires when `!is_mutable`. The fixture would never produce the hint, making the integration test impossible to pass.
- **Fix:** Added `use_while_borrowed()` function to the fixture that creates a mutable borrow then reads the variable directly — triggering `checkNotMutablyBorrowedPath` which always appends the hint. The original conflict scenario was preserved.
- **Files modified:** test/fixtures/fail_borrow.orh
- **Commit:** 24bded8

## Results

- All 266 integration tests pass (`./testall.sh`) — up from 262 before Phase 30
- All unit tests pass (`zig build test`)
- ERR-03: Move-after-use errors now include "consider using copy()"
- ERR-03: Borrow violations now include "consider borrowing with const &"
- ERR-03: Thread-move errors now include "shared mutable state requires synchronization"
- Integration tests cover ERR-01, ERR-02, ERR-03 end-to-end

## Self-Check: PASSED

Files created/modified:
- src/ownership.zig — FOUND
- src/borrow.zig — FOUND
- src/thread_safety.zig — FOUND
- test/fixtures/fail_did_you_mean.orh — FOUND
- test/fixtures/fail_type_mismatch_display.orh — FOUND
- test/fixtures/fail_borrow.orh — FOUND
- test/11_errors.sh — FOUND

Commits:
- 24099bf — FOUND (Task 1: ownership/borrow/thread hints)
- 24bded8 — FOUND (Task 2: fixtures and integration tests)
