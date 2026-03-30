---
phase: quick-260330-e1b
plan: 01
subsystem: testing
tags: [codegen, snapshot-tests, regression, test-08]
dependency_graph:
  requires: []
  provides: [codegen-snapshot-tests]
  affects: [test/08_codegen.sh]
tech_stack:
  added: []
  patterns: [snapshot-diffing via git diff --no-index]
key_files:
  created:
    - test/snapshots/snap_basics.orh
    - test/snapshots/snap_basics_main.orh
    - test/snapshots/snap_structs.orh
    - test/snapshots/snap_structs_main.orh
    - test/snapshots/snap_control.orh
    - test/snapshots/snap_control_main.orh
    - test/snapshots/snap_errors.orh
    - test/snapshots/snap_errors_main.orh
    - test/snapshots/expected/snap_basics.zig
    - test/snapshots/expected/snap_structs.zig
    - test/snapshots/expected/snap_control.zig
    - test/snapshots/expected/snap_errors.zig
  modified:
    - test/08_codegen.sh
decisions:
  - Use git diff --no-index instead of diff command (diff binary not available in environment)
  - Use const for all module-level declarations (var is rejected at module scope)
metrics:
  duration: ~15 minutes
  completed: 2026-03-30
---

# Phase quick-260330-e1b Plan 01: Codegen Snapshot Tests Summary

**One-liner:** 4 snapshot fixture pairs + expected .zig baselines with git-diff comparison integrated into test/08_codegen.sh.

## What Was Built

Added codegen snapshot testing to the compiler test suite. Each snapshot is a minimal two-module Orhon project (feature module + main) that compiles to a known .zig output. The test rebuilds each fixture and diffs the generated .zig against the committed baseline — any codegen change that alters output causes a visible test failure.

### Fixtures created

| Fixture | Covers |
|---------|--------|
| snap_basics | consts, type alias, pub functions, compt func (inline fn) |
| snap_structs | structs with methods, default fields, enums with methods |
| snap_control | if/elif/else, match, for loop, while+break, defer |
| snap_errors | Error union, null union, throw propagation, is checks |

### Test infrastructure

`snapshot_test()` shell function in `test/08_codegen.sh`:
- Creates a temp project directory, copies fixture pair
- Runs `orhon build`
- Compares generated `.zig` with expected using `git diff --no-index`
- Reports PASS/FAIL with first 20 diff lines on failure

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Module-level var not allowed in Orhon**
- **Found during:** Task 2 (baseline generation)
- **Issue:** `snap_basics.orh` contained `var counter: i32 = 0` at module scope; compiler rejects module-level `var`
- **Fix:** Replaced with `const RETRY_COUNT: i32 = 3` — a second module-level const
- **Files modified:** `test/snapshots/snap_basics.orh`
- **Commit:** 0d5cb3c

**2. [Rule 3 - Blocking] diff command not available in environment**
- **Found during:** Task 2 (first test run)
- **Issue:** The `diff` binary is not on PATH in this environment; test/08_codegen.sh uses `diff -u`
- **Fix:** Changed to `git diff --no-index` which is always available in a git repo and produces the same unified diff output
- **Files modified:** `test/08_codegen.sh`
- **Commit:** 0d5cb3c

## Test Results

All 273 tests pass (269 pre-existing + 4 new snapshot tests):

```
── Codegen snapshots ──
  PASS  snapshot: basics
  PASS  snapshot: structs
  PASS  snapshot: control
  PASS  snapshot: errors
  13/13 passed  (test/08_codegen.sh)

════════════════════════════════════════
  All 273 tests passed
════════════════════════════════════════
```

## Known Stubs

None.

## Self-Check: PASSED
