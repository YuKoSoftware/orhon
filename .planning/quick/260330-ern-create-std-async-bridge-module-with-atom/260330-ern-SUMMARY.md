---
phase: quick
plan: 260330-ern
subsystem: stdlib
tags: [std-bridge, atomic, concurrency, collections-pattern]
dependency_graph:
  requires: []
  provides: [std::async, Atomic(T)]
  affects: [src/std_bundle.zig, src/peg.zig, src/templates/example/advanced.orh]
tech_stack:
  added: [std.atomic.Value(T)]
  patterns: [bridge-module-sidecar, generic-type-function]
key_files:
  created:
    - src/std/async.orh
    - src/std/async.zig
  modified:
    - src/std_bundle.zig
    - src/peg.zig
    - src/templates/example/advanced.orh
    - docs/TODO.md
decisions:
  - "Atomic(T) wraps std.atomic.Value(T) using .seq_cst ordering for all operations — safe default"
  - "Example module shows single-threaded Atomic usage only — cross-thread passing deferred (thread safety checker rejects mutable borrow to thread)"
metrics:
  duration: ~10 minutes
  completed: 2026-03-30
---

# Quick Task 260330-ern: std::async Bridge Module with Atomic(T) Summary

**One-liner:** `std::async` bridge module providing `Atomic(T)` wrapping `std.atomic.Value(T)` for lock-free shared state.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create async.orh + async.zig + std_bundle registration | a39dbc6 | src/std/async.orh, src/std/async.zig, src/std_bundle.zig |
| 2 | PEG validation test + example module + TODO update | cb45bfe | src/peg.zig, src/templates/example/advanced.orh, docs/TODO.md |

## What Was Built

### src/std/async.orh
Bridge declaration file following the exact `collections.orh` pattern. Declares `pub bridge func Atomic(T: type) type` under `module async`.

### src/std/async.zig
Zig sidecar implementing `Atomic(T)` as a generic type function wrapping `std.atomic.Value(T)`. Methods:
- `new(initial: T) Self` — construct with initial value
- `load() T` — seq_cst load
- `store(val: T) void` — seq_cst store
- `swap(val: T) T` — seq_cst swap, returns old value
- `fetchAdd(val: T) T` — seq_cst fetch-and-add, returns old value
- `fetchSub(val: T) T` — seq_cst fetch-and-subtract, returns old value

Four Zig unit tests: basic, swap, fetchAdd, fetchSub.

### src/std_bundle.zig
Added `ASYNC_ORH` and `ASYNC_ZIG` embed constants and corresponding entries in `ensureStdFiles()` array (alphabetically first, before collections).

### src/peg.zig
Added `"peg - validate std/async.orh"` test after the time.orh validation test, following exact existing pattern.

### src/templates/example/advanced.orh
- Added `use std::async` import
- Added `// ─── Atomics ───` section with `atomic_demo()` function demonstrating `Atomic(i32).new()`, `.store()`, `.load()`
- Added `test "atomic"` asserting `atomic_demo() == 42`

### docs/TODO.md
Marked "Thread cancellation mechanism" as covered by `std::async`, documenting the `Atomic(bool)` pattern for thread cancellation flags.

## Verification

- `zig build test`: EXIT 0 — all tests pass (273 total, +4 Atomic unit tests)
- `zig build`: EXIT 0 — compiler builds cleanly
- `./testall.sh`: All 273 tests passed

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — `Atomic(T)` is fully implemented and functional.

## Self-Check: PASSED

- src/std/async.orh: FOUND
- src/std/async.zig: FOUND
- src/std_bundle.zig: updated with ASYNC_ORH and ASYNC_ZIG
- Commits a39dbc6 and cb45bfe: FOUND
