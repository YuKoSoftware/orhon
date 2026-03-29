---
phase: quick
plan: 260329-ozf
subsystem: thread-safety
tags: [thread-safety, enforcement, move-tracking, borrow-freeze]
dependency_graph:
  requires: []
  provides: [thread-arg-move, thread-const-freeze, thread-mutable-reject]
  affects: [src/thread_safety.zig, test/fixtures/fail_threads.orh, test/11_errors.sh]
tech_stack:
  added: []
  patterns: [frozen_for_thread map, isThreadCall helper, unfreezeForThread on join]
key_files:
  created: []
  modified:
    - src/thread_safety.zig
    - test/fixtures/fail_threads.orh
    - test/11_errors.sh
decisions:
  - "&T is mutable borrow (var &), const &T is immutable borrow — adjusted fixture accordingly"
  - "var &T syntax rejected at parser level, so mutable borrow to thread uses &T param instead"
  - "Fixed-size array (32 slots) for unfreeze iteration instead of ArrayList (Zig 0.15 compat)"
metrics:
  duration: 13m
  completed: "2026-03-29T15:16:09Z"
  tasks: 2/2
  files: 3
  tests_added: 4 unit + 3 integration
---

# Quick Task 260329-ozf: Thread Safety Arg Enforcement Summary

Thread arg enforcement for move tracking, const borrow freeze, and mutable borrow rejection in thread_safety.zig pass 8.

## One-liner

Thread function call args now enforce: owned values move-tracked, const borrows freeze originals, mutable borrows rejected at compile time.

## What Changed

### Task 1: Thread call argument enforcement logic (f9c27d9)

Added three enforcement rules to `ThreadSafetyChecker`:

1. **`frozen_for_thread: StringHashMap([]const u8)`** -- new field tracking variables frozen by const borrow into a thread (var_name -> thread_name). Save/restore in func_decl and test_decl scope push/pop.

2. **`isThreadCall()`** -- helper that checks if a call_expr targets a thread function by looking up `ctx.decls.funcs` and checking `sig.is_thread`.

3. **`checkThreadCallArgs()`** -- iterates call args:
   - `borrow_expr` with `type_ptr.kind == K.Ptr.VAR_REF` param -> immediate error (mutable borrow to thread)
   - `borrow_expr` with const param -> freeze inner variable in `frozen_for_thread`
   - `identifier` arg -> move into `moved_to_thread`

4. **Freeze enforcement** in `.assignment` branch: rejects mutation of frozen variables.

5. **`unfreezeForThread()`** -- removes frozen entries when thread is joined via `.value` or `.wait()`.

6. **4 new unit tests**: owned arg move, const borrow freeze + mutation error, mutable borrow rejection, unfreeze after join.

### Task 2: Negative test fixtures (f40ff27)

Extended `test/fixtures/fail_threads.orh` with three new scenarios (keeping existing unjoined handle test):
- Use-after-move into thread (consumer(x) then use x)
- Mutate frozen variable (reader(const &x) then x = 20)
- Mutable borrow to thread (writer(&x) with &T mutable param)

Added 3 new entries in `test/11_errors.sh` for pattern matching.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected borrow syntax assumptions**
- **Found during:** Task 2
- **Issue:** Plan assumed `var &T` is valid Orhon parameter syntax for mutable borrows, but the parser rejects `var &T` at module resolution. In Orhon, `&T` = mutable borrow (var &), `const &T` = immutable borrow.
- **Fix:** Used `&T` for mutable borrow params and `const &T` for immutable borrow params in test fixtures. The enforcement logic was already correct.
- **Files modified:** test/fixtures/fail_threads.orh

**2. [Rule 3 - Blocking] Zig 0.15 ArrayList compatibility**
- **Found during:** Task 1
- **Issue:** `std.ArrayList([]const u8).init(allocator)` has no `init` member in Zig 0.15.
- **Fix:** Used fixed-size array `[32][]const u8` for unfreeze key collection instead of ArrayList.
- **Files modified:** src/thread_safety.zig

## Verification

- `zig build test` -- all unit tests pass (411 tests)
- `bash test/11_errors.sh` -- 55/55 error tests pass
- `./testall.sh` -- all 269 tests pass, zero regressions

## Known Stubs

None -- all enforcement logic is fully wired.

## Self-Check: PASSED
