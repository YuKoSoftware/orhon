---
phase: 08-const-auto-borrow
plan: 02
subsystem: codegen
tags: [codegen, mir, const-auto-borrow, zig-signatures]

# Dependency graph
requires:
  - phase: 08-01
    provides: const_ref_params map in MirAnnotator, value_to_const_ref annotation at call sites
provides:
  - CodeGen reads const_ref_params and emits *const T in function signatures
  - All callers (const and var) emit &arg for promoted params
  - copy() unaffected — CBOR-02 safe
  - Test fixtures exercising const auto-borrow with runtime verification
affects: [phase-09-ptr-simplification]

# Tech tracking
tech-stack:
  added: []
  patterns: [const-auto-borrow, same-module-only promotion, var-caller-&-emission]

key-files:
  created: []
  modified:
    - src/codegen.zig
    - src/main.zig
    - src/mir.zig
    - test/fixtures/tester.orh
    - test/fixtures/tester_main.orh
    - test/10_runtime.sh

key-decisions:
  - "Limited const auto-borrow to same-module direct calls (c.callee is identifier) — cross-module calls skipped to avoid signature mismatch (Pitfall 5)"
  - "Excluded enums and bitfields from const auto-borrow — they are small value types that should be copied, not borrowed"
  - "Used isPromotedParam() helper for O(1) lookup of const_ref_params in codegen"
  - "Var callers of promoted functions emit &arg via arg.coercion==null check — *T coerces to *const T in Zig"

requirements-completed: [CBOR-01, CBOR-02, CBOR-03]

# Metrics
duration: 35min
completed: 2026-03-25
---

# Phase 08 Plan 02: Const Auto-Borrow Codegen Wiring Summary

**CodeGen now emits *const T Zig signatures and &arg call sites for const non-primitive struct params, with var callers handled transparently and copy() bypassing auto-borrow correctly**

## Performance

- **Duration:** 35 min
- **Started:** 2026-03-25T11:31:00Z
- **Completed:** 2026-03-25T11:54:49Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- `src/codegen.zig`: Added `const_ref_params` field, `isPromotedParam()` helper, and `*const T` emission for promoted params in `generateFuncMir`
- `src/codegen.zig`: Var callers of promoted functions emit `&arg` (because `arg.coercion == null and isPromotedParam(...)` → true)
- `src/main.zig`: Wired `const_ref_params` from MirAnnotator to CodeGen alongside other MIR fields
- `src/mir.zig`: Fixed two correctness issues found during testing — enum/bitfield exclusion and cross-module call skip
- Test fixtures: `Point2D` struct, `sum_point`/`mul_point` helpers, `test_const_auto_borrow`, `test_var_caller_promoted`, `test_const_copy` — all pass at runtime
- All 239 tests pass (102 runtime, 21 language, full 11-stage suite)

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire const_ref_params to CodeGen and emit *const T signatures** - `3ff9e82` (feat)
2. **Task 2: Add test fixtures and run full test suite** - `965d6e2` (feat)

## Files Created/Modified

- `src/codegen.zig` — Added `const_ref_params` field, `isPromotedParam()` helper, `*const T` emission in param loop, var-caller `&` emission in call arg loop
- `src/main.zig` — Wired `cg.const_ref_params = &mir_annotator.const_ref_params;` in pass 11 setup
- `src/mir.zig` — Enum/bitfield exclusion from const auto-borrow; same-module-only restriction via `is_direct_call` flag
- `test/fixtures/tester.orh` — Point2D struct, helper functions, and self-contained test functions
- `test/fixtures/tester_main.orh` — Runtime calls to test_const_auto_borrow, test_var_caller_promoted, test_const_copy
- `test/10_runtime.sh` — Added const_auto_borrow, var_caller_promoted, const_copy to expected runtime tests

## Decisions Made

- **Cross-module calls excluded**: Only direct identifier callee calls (same module) trigger const auto-borrow. `tester.func(arg)` style cross-module calls skip it to avoid function signature mismatch between modules. This is Pitfall 5 from the research.
- **Enums and bitfields excluded**: Named types that are enums or bitfields are excluded from promotion — they're small value types (like primitives) that should be copied, not borrowed via `*const T`.
- **Var callers handled via `isPromotedParam`**: When a function param is promoted to `*const T`, all var callers also need `&arg`. Codegen checks `arg.coercion == null and isPromotedParam(callee_name, i)` to emit `&` for var callers. Const callers use the existing `value_to_const_ref` path.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Enums promoted to *const T causing Zig type error**
- **Found during:** Task 2 (testing tester.orh compilation)
- **Issue:** `isNonPrimitiveType` treated named types (enums, bitfields) as non-primitive, causing `color_to_int(c: Color)` to become `color_to_int(c: *const Color)`. Zig's match statement on `*const Color` then required an else arm.
- **Fix:** Added `is_enum_or_bitfield` check in `annotateCallCoercions` — looks up `self.decls.enums` and `self.decls.bitfields` for named types.
- **Files modified:** `src/mir.zig`
- **Verification:** `color_to_int` remains `fn color_to_int(c: Color)` in generated Zig
- **Committed in:** `965d6e2` (Task 2 commit)

**2. [Rule 1 - Bug] Cross-module calls emitting &arg for non-promoted target functions**
- **Found during:** Task 2 (testing tester_main.orh compilation)
- **Issue:** `tester.sum_fixed_array(arr)` in main.orh: main module annotated `arr` with `value_to_const_ref` and recorded `sum_fixed_array` in main's `const_ref_params`. Codegen emitted `&arr` in main.zig. But tester.zig's `sum_fixed_array` was NOT promoted (its test block used `assert()` which is a compiler_func, not processed by `annotateCallCoercions`). Result: type mismatch `expected '[3]i32', found pointer`.
- **Fix:** Added `is_direct_call` flag: const auto-borrow only applies when `c.callee.* == .identifier` (same-module direct call). Cross-module field_expr callees are skipped.
- **Files modified:** `src/mir.zig`
- **Verification:** `sum_fixed_array` retains `fn sum_fixed_array(arr: [3]i32)` in tester.zig; no `&arr` in main.zig for that call
- **Committed in:** `965d6e2` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (Rule 1 - Bug)
**Impact on plan:** Both fixes essential for correctness. The cross-module limitation is documented behavior for Phase 8. No scope creep.

## Issues Encountered

- The `const_vars` map is module-level flat (accumulates across all functions). A `var pt` in one function gets treated as const-eligible if a `const pt` exists elsewhere in the module. This causes over-eager promotion for `mul_point` when `test_var_caller_promoted` has `var pt` but `test_const_auto_borrow` has `const pt`. The end result is still correct (the Zig type system accepts it), but it's worth noting as a scoping limitation to address in a future cleanup.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Const auto-borrow feature (CBOR-01, CBOR-02, CBOR-03) is complete and tested
- Phase 09 (Ptr Syntax Simplification) can begin — it depends on Phase 08 being stable
- Potential future improvement: scope `const_vars` per function to avoid cross-function const name collisions

## Known Stubs

None — all implemented features are fully wired and produce correct runtime output.

## Self-Check: PASSED

Files confirmed present:
- `src/codegen.zig` — contains `const_ref_params`, `isPromotedParam`, `*const {s}` emission
- `src/main.zig` — contains `cg.const_ref_params = &mir_annotator.const_ref_params;`
- `src/mir.zig` — contains `is_enum_or_bitfield`, `is_direct_call` checks
- `test/fixtures/tester.orh` — contains `Point2D`, `test_const_auto_borrow`
- `test/fixtures/tester_main.orh` — contains `const_auto_borrow` test calls
- `test/10_runtime.sh` — contains `const_auto_borrow var_caller_promoted const_copy`

Commits verified:
- `3ff9e82` — feat(08-02): wire const_ref_params
- `965d6e2` — feat(08-02): add test fixtures and fix cross-module

Test results: All 239 tests pass.

---
*Phase: 08-const-auto-borrow*
*Completed: 2026-03-25*
