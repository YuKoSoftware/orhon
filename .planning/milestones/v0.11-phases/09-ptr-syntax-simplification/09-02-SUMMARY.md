---
phase: 09-ptr-syntax-simplification
plan: 02
subsystem: parser, codegen, mir, resolver
tags: [syntax-removal, dead-code, negative-test, pointers]
dependency_graph:
  requires: [09-01-SUMMARY]
  provides: [PTRS-04]
  affects: [src/orhon.peg, src/peg/builder.zig, src/parser.zig, src/mir.zig, src/resolver.zig, src/codegen.zig, test/fixtures/fail_ptr_cast.orh, test/11_errors.sh]
tech_stack:
  added: []
  patterns: [dead-code-removal, negative-test-fixture]
key_files:
  created:
    - test/fixtures/fail_ptr_cast.orh
  modified:
    - src/orhon.peg
    - src/peg/builder.zig
    - src/parser.zig
    - src/mir.zig
    - src/resolver.zig
    - src/codegen.zig
    - test/11_errors.sh
decisions:
  - "Both ptr_cast_expr and ptr_expr PEG rules removed entirely — type annotation drives coercion (from plan 01)"
  - "MirKind.ptr_expr removed alongside all AST references — no stray enum variant left"
metrics:
  duration_minutes: 7
  completed_date: "2026-03-25"
  tasks_completed: 2
  files_modified: 7
---

# Phase 09 Plan 02: Remove Old Pointer Syntax Summary

**One-liner:** Removed all `Ptr(T).cast()` and `Ptr(T, &x)` grammar rules, AST types, MIR kinds, and codegen handlers, completing the pointer syntax simplification with a negative test confirming rejection.

## What Was Built

Full removal of dead pointer construction syntax across the entire compiler stack:

**Grammar (src/orhon.peg):**
- Removed `ptr_cast_expr` rule (`Ptr(T).cast(addr)` syntax)
- Removed `ptr_expr` rule (`Ptr(T, &x)` syntax)
- Removed both alternatives from `primary_expr`

**Builder (src/peg/builder.zig):**
- Removed `buildPtrCastExpr` dispatch and function
- Removed `is_ptr` detection block in `buildGenericType` that created `ptr_expr` nodes from `Ptr(T, &x)` syntax

**Parser (src/parser.zig):**
- Removed `ptr_expr` from `NodeKind` enum
- Removed `ptr_expr: PtrExpr` from `Node` union
- Removed `PtrExpr` struct

**MIR (src/mir.zig):**
- Removed `ptr_expr` from `MirKind` enum
- Removed `.ptr_expr` arm from `annotateNode`
- Removed `.ptr_expr` arm from `lowerNode`
- Removed `.ptr_expr` arm from name extraction
- Removed `.ptr_expr => .ptr_expr` arm from `astToMirKind`

**Resolver (src/resolver.zig):**
- Removed `.ptr_expr` arm from `resolveExpr`

**Codegen (src/codegen.zig):**
- Removed `.ptr_expr` dispatch from `generateExpr` (AST path)
- Removed `.ptr_expr` dispatch from `generateExprMir` (MIR path)
- Removed `generatePtrExpr` function
- Removed `generatePtrExprMir` function

**Negative test:**
- Created `test/fixtures/fail_ptr_cast.orh` with old `Ptr(i32).cast(&x)` syntax
- Added test to `test/11_errors.sh` verifying the fixture fails to parse

## Verification

- `zig build test` — passes (0 errors)
- `./testall.sh` — all 240 tests pass across 11 stages (239 + 1 new negative test)
- `grep -r "ptr_expr" src/` — 0 matches
- `grep -r "PtrExpr" src/` — 0 matches
- `grep -r "ptr_cast_expr" src/` — 0 matches
- `grep -r "generatePtrExpr" src/` — 0 matches
- Old `Ptr(T).cast()` syntax produces a parse error

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — old syntax fully removed, new type-directed syntax wired from plan 01.

## Self-Check: PASSED

- [x] `src/orhon.peg` — ptr_cast_expr and ptr_expr rules removed
- [x] `src/peg/builder.zig` — buildPtrCastExpr and is_ptr detection removed
- [x] `src/parser.zig` — PtrExpr struct and ptr_expr NodeKind removed
- [x] `src/mir.zig` — MirKind.ptr_expr and all 4 switch arms removed
- [x] `src/resolver.zig` — ptr_expr switch arm removed
- [x] `src/codegen.zig` — generatePtrExpr, generatePtrExprMir, and dispatch arms removed
- [x] `test/fixtures/fail_ptr_cast.orh` — negative fixture created
- [x] `test/11_errors.sh` — negative test added
- [x] Commit `b4a8e4c` — Task 1: PEG/builder/parser cleanup
- [x] Commit `f27a5f7` — Task 2: switch arms, codegen functions, negative test
