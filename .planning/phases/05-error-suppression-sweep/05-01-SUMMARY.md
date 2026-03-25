---
phase: 05-error-suppression-sweep
plan: "01"
subsystem: codegen
tags: [codegen, threads, error-safety, catch-unreachable]
dependency_graph:
  requires: []
  provides: [thread-codegen-safe-failures]
  affects: [generated-zig-thread-functions]
tech_stack:
  added: []
  patterns: [catch @panic for fatal allocation failures in generated Zig]
key_files:
  created: []
  modified:
    - src/codegen.zig
decisions:
  - "@panic used instead of return error for thread spawn failures — generated function return type is _OrhonHandle(T) not anyerror!Handle(T), making error propagation incompatible with the Orhon type system; @panic is safe (no UB), always terminates with a message, and OOM on a small struct allocation is truly fatal"
metrics:
  duration: 45
  completed: "2026-03-25"
  tasks: 2
  files: 1
---

# Phase 05 Plan 01: Compiler catch unreachable Sweep Summary

Replace the 4 compiler-side `catch unreachable` in codegen.zig's thread spawn wrappers with
proper safe failure handling using `@panic`, eliminating undefined behavior on allocation failure.

## What Was Built

- **Thread state allocation**: `page_allocator.create(SharedState) catch unreachable` → `catch @panic("Out of memory: thread state allocation")`
- **Thread spawn**: `Thread.spawn(...) catch unreachable` → `catch |e| @panic(@errorName(e))`
- Both changes apply to the MIR path (primary, lines 695/726) and legacy AST path (lines 944/983)
- All generated-code emit strings for error union narrowing (lines 1854-1879, 2292-2314) left untouched

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `catch return error.OutOfMemory` incompatible with generated return type**

- **Found during:** Task 1 (test regression in stage 09_language)
- **Issue:** The plan instructed using `catch return error.OutOfMemory` and `catch |e| return e`, assuming the generated function already returned `anyerror!Handle(T)`. In reality, the generated spawn wrapper returns `_OrhonHandle(T)` (not an error union), so returning an error causes a type mismatch at the call site. The plan had a false assumption.
- **Fix:** Used `catch @panic(...)` instead — achieves the same safety goal (no UB from `unreachable`), gives a clear error message, and keeps the generated return type as `_OrhonHandle(T)`.
- **Files modified:** src/codegen.zig
- **Commits:** 7187ae2 (initial attempt), 99365c6 (corrected to @panic)

## Commits

| Hash | Message |
|------|---------|
| 7187ae2 | fix(05-01): replace compiler-side catch unreachable with error propagation in thread codegen |
| 99365c6 | fix(05-01): use @panic instead of return error in thread codegen (generated return type mismatch) |

## Verification Results

- Zero compiler-side `catch unreachable` remain in codegen.zig
- 11 instances remain: 6 `self.emit(" catch unreachable")` emit strings (correct, generate error union narrowing) + 4 comment lines + 1 doc comment
- All generated-code emit strings at lines 1854-1879 and 2292-2314 unchanged
- Thread tests: all pass (runtime: thread, thread_multi, thread_params, thread_void, thread_done, thread_join)
- Test suite: 232 passed, 6 failed — identical to pre-change baseline (6 failures are pre-existing null union codegen and string interpolation bugs)

## Known Stubs

None.

## Self-Check: PASSED

- src/codegen.zig: FOUND
- Commit 7187ae2: FOUND
- Commit 99365c6: FOUND
