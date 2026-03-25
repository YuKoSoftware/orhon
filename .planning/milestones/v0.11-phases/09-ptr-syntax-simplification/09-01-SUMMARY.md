---
phase: 09-ptr-syntax-simplification
plan: 01
subsystem: codegen
tags: [codegen, pointers, type-directed-coercion, syntax-simplification]
dependency_graph:
  requires: [08-02-SUMMARY]
  provides: [PTRS-01, PTRS-02, PTRS-03]
  affects: [src/codegen.zig, test/fixtures/tester.orh, src/templates/example/data_types.orh]
tech_stack:
  added: []
  patterns: [type-directed-coercion, blk-labeled-block-pattern]
key_files:
  created: []
  modified:
    - src/codegen.zig
    - test/fixtures/tester.orh
    - src/templates/example/data_types.orh
decisions:
  - "type-directed coercion uses blk pattern inline in each of the 4 declaration functions — avoids extra abstraction while being readable"
  - "generatePtrCoercion and generatePtrCoercionMir kept as separate helpers (not inlined) for clarity and reuse"
  - "generatePtrExpr and generatePtrExprMir left in place (not removed) — they serve old ptr_expr AST nodes still alive in Wave 1; will be removed in plan 02"
metrics:
  duration_minutes: 3
  completed_date: "2026-03-25"
  tasks_completed: 2
  files_modified: 3
---

# Phase 09 Plan 01: Type-Directed Pointer Coercion Summary

**One-liner:** Added `generatePtrCoercion` and `generatePtrCoercionMir` helpers so that `const p: Ptr(T) = &x` syntax generates correct Zig output, and updated all fixtures/examples to use the new syntax.

## What Was Built

Two new helper functions in `src/codegen.zig` implement type-directed pointer coercion at declaration sites:

- `generatePtrCoercion` (AST path) — called from `generateDecl` and `generateStmtDecl`
- `generatePtrCoercionMir` (MIR path) — called from `generateTopLevelDeclMir` and `generateStmtDeclMir`

Each hook uses a `blk` labeled block to detect when the type annotation is `Ptr`, `RawPtr`, or `VolatilePtr` and route to the coercion helper instead of the generic expression emitter.

The coercion logic mirrors the existing `generatePtrExpr`/`generatePtrExprMir` functions:
- `Ptr(T)` + `&x` → `&x`
- `RawPtr(T)` + `&x` → `@as([*]T, @ptrCast(&x))`
- `RawPtr(T)` + integer → `@as([*]T, @ptrFromInt(N))`
- `VolatilePtr(T)` + `&x` → `@as(*volatile T, @ptrCast(&x))`
- `VolatilePtr(T)` + integer → `@as(*volatile T, @ptrFromInt(N))`

## Fixtures Updated

`test/fixtures/tester.orh` — 3 lines changed from `.cast()` to type-directed syntax:
- `RawPtr(i32).cast(&x)` → `&x` (raw_ptr_read function)
- `RawPtr(i32).cast(&arr)` → `&arr` (raw_ptr_index function)
- `Ptr(i32).cast(&x)` → `&x` (safe_ptr_read function)

`src/templates/example/data_types.orh` — 3 lines changed:
- Live `read_via_ptr` function updated
- RawPtr comment block updated
- VolatilePtr comment block updated

## Verification

- `zig build test` — passes (0 errors)
- `./testall.sh` — all 239 tests pass across 11 stages
- Runtime tests `raw_ptr_read`, `raw_ptr_index`, `safe_ptr` all pass with new syntax

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — all pointer syntax is fully wired.

## Self-Check: PASSED

- [x] `src/codegen.zig` — modified with coercion helpers
- [x] `test/fixtures/tester.orh` — `.cast()` removed, new syntax verified
- [x] `src/templates/example/data_types.orh` — `.cast()` removed, new syntax verified
- [x] Commit `25713d7` — Task 1 codegen changes
- [x] Commit `ccd3759` — Task 2 fixtures and example
