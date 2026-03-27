---
phase: 22-throw-statement
plan: 01
subsystem: compiler
tags: [lexer, parser, peg, mir, codegen, propagation, error-handling]

# Dependency graph
requires:
  - phase: 21-flexible-allocators
    provides: SMP allocator system the codegen references for string interpolation
provides:
  - throw keyword: kw_throw token, throw_stmt AST node, ThrowStmt struct, throw_stmt PEG rule
  - throw validation: PropagationChecker validates error union and error-returning function constraints
  - throw MIR lowering: MirKind.throw_stmt, astToMirKind mapping, populateData, lowerNode leaf
  - throw codegen: generates `if (x) |_| {} else |_err| return _err;` with error_narrowed recording
  - narrowing fix: error_narrowed and null_narrowed properly scoped per-function in both MIR and AST paths
affects: [23-pattern-guards, 24-cimport]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "throw statement: keyword + IDENTIFIER TERM grammar rule mapped to single-field struct"
    - "narrowing map reset: save/restore pattern identical to reassigned_vars for per-function scoping"

key-files:
  created: []
  modified:
    - src/lexer.zig
    - src/parser.zig
    - src/orhon.peg
    - src/peg/builder.zig
    - src/propagation.zig
    - src/mir.zig
    - src/codegen.zig

key-decisions:
  - "throw operates on named variables only (IDENTIFIER), not expressions — simpler grammar and clear semantics"
  - "throw generates if (x) |_| {} else |_err| return _err; — idiomatic Zig error propagation"
  - "error_narrowed and null_narrowed reset per-function alongside reassigned_vars — prevents cross-function narrowing leaks"

patterns-established:
  - "New statement keyword: lexer token -> PEG rule -> AST struct -> builder -> propagation validation -> MirKind -> codegen emission"

requirements-completed: [ERR-01, ERR-02, ERR-03]

# Metrics
duration: 15min
completed: 2026-03-27
---

# Phase 22 Plan 01: throw Statement Full Pipeline Summary

**`throw x` keyword implemented across all 7 compiler passes: lexer token, PEG grammar, AST builder, propagation validation, MIR lowering, and Zig codegen with error narrowing.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-03-27T14:30:00Z
- **Completed:** 2026-03-27T14:45:00Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- `throw x` is a recognized keyword that compiles through the full 12-pass pipeline
- Propagation checker validates: (1) variable must be an error union, (2) enclosing function must return error union
- Codegen emits `if (x) |_| {} else |_err| return _err;` and records the variable in `error_narrowed` for type narrowing
- Fixed per-function scoping of `error_narrowed` and `null_narrowed` maps — previously leaked across functions

## Task Commits

Each task was committed atomically:

1. **Task 1: Add throw keyword and AST plumbing (lexer, parser, PEG, builder)** - `b130c63` (feat)
2. **Task 2: Add throw validation, MIR lowering, and codegen emission** - `eb5341d` (feat)

## Files Created/Modified

- `src/lexer.zig` - Added kw_throw TokenKind and "throw" KEYWORDS mapping
- `src/parser.zig` - Added throw_stmt NodeKind, Node arm, and ThrowStmt struct
- `src/orhon.peg` - Added throw_stmt grammar rule, wired into statement alternatives, updated KEYWORDS comment
- `src/peg/builder.zig` - Added buildThrowStmt dispatch and builder function
- `src/propagation.zig` - Added throw_stmt case to checkStatement: validates error union and error-returning function, calls markHandled
- `src/mir.zig` - Added throw_stmt to MirKind enum, astToMirKind, populateData (stores variable name in m.name), lowerNode leaf
- `src/codegen.zig` - Added throw_stmt emission in generateStatementMir; fixed per-function narrowing reset in both generateFuncMir and generateFunc

## Decisions Made

- `throw` operates on named variables only (IDENTIFIER), not expressions — matches plan design decision D-01
- Zig emission pattern `if (x) |_| {} else |_err| return _err;` — standard error propagation via Zig capture syntax
- Per-function `error_narrowed`/`null_narrowed` reset follows the same save/restore pattern as `reassigned_vars`

## Deviations from Plan

None - plan executed exactly as written.

Note: Task 1 and Task 2 could not be committed independently mid-execution because adding `throw_stmt` to the parser Node union required mir.zig's `lowerNode` switch to also handle it (Zig exhaustive switch). Both tasks were completed before the first commit, but were split into two separate commits with the correct logical boundaries.

## Issues Encountered

None.

## Known Stubs

None — `throw` is fully wired through all passes. No placeholder values or hardcoded stubs.

## Next Phase Readiness

- `throw` statement is complete and usable in Orhon programs
- The example module could be updated to demonstrate `throw` usage (optional, separate task)
- Ready for Phase 22 Plan 02 if applicable, or next phase

---
*Phase: 22-throw-statement*
*Completed: 2026-03-27*
