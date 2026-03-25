---
phase: 04-codegen-correctness
plan: 01
subsystem: codegen
tags: [bug-fix, codegen, collections, runtime]
dependency_graph:
  requires: []
  provides: [collection-new-codegen-fix]
  affects: [src/codegen.zig]
tech_stack:
  added: []
  patterns: [MIR-path-fix, AST-path-fix, type-expr-detection]
key_files:
  modified:
    - src/codegen.zig
decisions:
  - "Collection .new() detection via type_expr MIR kind, not .collection — because PEG builder transparency strips collection_expr to its element type"
  - "Both MIR-path and AST-path handlers updated for completeness"
  - "Guard by type_expr OR collection kind to be robust against future builder fixes"
metrics:
  duration_minutes: 35
  completed_date: "2026-03-25"
  tasks_completed: 2
  files_modified: 1
---

# Phase 04 Plan 01: Collection .new() Constructor Codegen Fix Summary

Fixed the collection constructor codegen bug that blocked all 100 runtime tests. `List(i32).new()`, `Map(K,V).new()`, and `Set(T).new()` now emit `.{}` instead of `i32.new()` (or similar invalid type-member access) in generated Zig.

## What Was Built

The fix adds collection `.new()` constructor detection in two places in `src/codegen.zig`:

1. **MIR-path** (`generateExprMir`, `.call` handler): Detects when a `.field_access` callee has method name "new", no call args, and the object MIR node has kind `.type_expr` or `.collection`. Emits `.{}` instead of falling through to general call emission.

2. **AST-path** (`generateExpr`, `.call_expr` handler): Detects when the callee is `.field_expr` with field "new", no args, and the object is `collection_expr`, `type_primitive`, `type_named`, or `type_generic`. Emits `.{}`.

## Key Discovery: PEG Builder Transparency

The critical finding that unlocked the fix: the `collection_expr` PEG builder has no explicit handler in `src/peg/builder.zig`. Due to the "transparent rules — recurse into first child" fallback (line 217), `List(i32)` in expression position is reduced to the element type node (`type_primitive(.i32)`) rather than remaining a `collection_expr` node.

This means in the MIR tree, `List(i32).new()` produces:
```
call (kind=.call)
  field_access (kind=.field_access, name="new")
    type_primitive i32 (kind=.type_expr)   ← NOT .collection as expected
```

The fix correctly targets `.type_expr` kind, which is safe because user struct `.new()` methods use `.identifier` kind for the object (struct names are identifiers, not type keywords).

## Commits

| Hash | Description |
|------|-------------|
| `fa60ead` | Initial detection attempt (incorrect .collection check) |
| `cf5fc43` | Corrected fix: detect .type_expr/.collection for builder transparency |

## Test Results

- Stage 09 (language): tester module compiles PASS, example module PASS (null union codegen failure is pre-existing)
- Stage 10 (runtime): tester ran to completion PASS, all collection tests PASS (interpolation failures are pre-existing)
- Stage 01 (unit): PASS — no regressions
- Stage 02 (build): PASS — no regressions

Collection-specific runtime tests now passing: list, list_len, map, set, map_iter, set_iter, split_at, split_list, map_get.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Incorrect MIR kind check — .collection vs .type_expr**
- **Found during:** Task 2 (verification)
- **Issue:** Plan specified `obj_mir.kind == .collection`, but actual MIR kind for the object is `.type_expr` because the PEG builder for `collection_expr` is transparent (no explicit handler) and reduces `List(i32)` to its element type `type_primitive(.i32)`
- **Fix:** Changed guard to check `obj_mir.kind == .type_expr or obj_mir.kind == .collection` in MIR path; AST path updated similarly to check `type_primitive`, `type_named`, `type_generic` in addition to `collection_expr`
- **Files modified:** src/codegen.zig
- **Commits:** cf5fc43

## Known Stubs

None — all collection constructor patterns are fully wired.

## Self-Check: PASSED
