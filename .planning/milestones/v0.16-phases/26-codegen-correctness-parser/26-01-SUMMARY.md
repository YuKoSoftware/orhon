---
phase: 26-codegen-correctness-parser
plan: 01
subsystem: compiler
tags: [peg-grammar, codegen, parser, bug-fix, union, unary]

# Dependency graph
requires: []
provides:
  - Unary negation '-' in PEG grammar and builder
  - Cross-module is operator emits tagged union comparison for arbitrary_union types
  - Async(T) reports compile error instead of silently mapping to void
  - Test fixture for negative literal function arguments
affects: [codegen, peg-grammar, builder, test-fixtures]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Unary prefix operators added to PEG grammar before address-of (&)"
    - "Tagged union is-check: check getTypeClass before emitting @TypeOf path"

key-files:
  created:
    - .planning/phases/26-codegen-correctness-parser/26-01-SUMMARY.md
  modified:
    - src/orhon.peg
    - src/peg/builder.zig
    - src/codegen.zig
    - test/fixtures/tester.orh
    - test/fixtures/tester_main.orh

key-decisions:
  - "Unary '-' placed after '!' and before '&' in unary_expr PEG rule to avoid ambiguity with binary subtraction"
  - "Cross-module is operator for tagged unions uses fe.field (not fe.name) — FieldExpr struct uses .field"
  - "Async(T) reports error via reporter.report() then falls back to void — keeps compilation continuing to collect further errors"

patterns-established:
  - "PEG unary_expr rule: add new prefix operators before '&' (address-of)"
  - "Is-operator tagged union detection: check getTypeClass/type_class == .arbitrary_union before @TypeOf fallback"

requirements-completed: [PRS-01, CGN-04, CGN-05]

# Metrics
duration: 10min
completed: 2026-03-28
---

# Phase 26 Plan 01: Codegen Correctness & Parser Summary

**Three compiler bugs fixed: unary negation in PEG grammar, cross-module `is` union tag comparison, and Async(T) compile error — all 260 tests passing.**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-03-28T09:34:00Z
- **Completed:** 2026-03-28T09:44:34Z
- **Tasks:** 3
- **Files modified:** 5

## Accomplishments
- Added unary `-` prefix operator to PEG grammar and builder, enabling `-0.5`, `-1` as function arguments
- Fixed cross-module `is` operator on tagged unions to emit `val == ._TypeName` instead of `@TypeOf(val) == module.Type`
- Replaced silent `Async(T) -> void` mapping with `reporter.report()` compile error
- Added `test_negative_args` fixture and runtime test, confirmed passing in full suite

## Task Commits

1. **Task 1: Add unary negation to PEG grammar and builder** - `81999f4` (feat)
2. **Task 2: Fix cross-module is operator and Async(T) error** - `a4fa132` (fix)
3. **Task 3: Add test fixtures and run full test suite** - `1d23c96` (test)

## Files Created/Modified
- `src/orhon.peg` - Added `'-' unary_expr` alternative in unary_expr rule
- `src/peg/builder.zig` - Added `.minus` token handling in buildUnaryExpr
- `src/codegen.zig` - Fixed qualified type check for arbitrary_union (AST+MIR paths); Async(T) error report
- `test/fixtures/tester.orh` - Added negate_helper, test_negative_args, test block
- `test/fixtures/tester_main.orh` - Added PASS/FAIL check for negative_literal_args

## Decisions Made
- Unary `-` placed after `!` and before `&` in PEG rule so it doesn't interfere with binary subtraction (which is handled at the `add_expr` level) or address-of
- For `field_expr` in the AST path, used `fe.field` (not `fe.name`) because `FieldExpr` struct uses the field named `.field`
- Async(T) falls back to `"void"` after reporting error so compilation can continue collecting further errors in the same pass

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Used correct field name `fe.field` instead of `fe.name` in AST qualified-type-check**
- **Found during:** Task 2 (cross-module is operator fix)
- **Issue:** Plan's code sample used `fe.name` but `FieldExpr` struct has field named `.field`, not `.name`
- **Fix:** Used `fe.field` in the AST path qualified type check
- **Files modified:** src/codegen.zig
- **Verification:** zig build passes
- **Committed in:** a4fa132 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 bug in plan's code sample)
**Impact on plan:** Minor field name correction. No scope creep.

## Issues Encountered
None.

## Next Phase Readiness
- All three targeted bugs resolved: PRS-01, CGN-04, CGN-05
- Full test suite at 260 tests, all passing
- Phase 26 complete

---
*Phase: 26-codegen-correctness-parser*
*Completed: 2026-03-28*
