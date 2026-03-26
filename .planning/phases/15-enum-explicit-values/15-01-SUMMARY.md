---
phase: 15-enum-explicit-values
plan: 01
subsystem: compiler
tags: [peg, parser, ast, mir, codegen, enum, orhon]

# Dependency graph
requires: []
provides:
  - PEG grammar accepts A = 4 syntax in typed enum variants
  - EnumVariant AST struct carries optional value node
  - Builder extracts = int_literal from token stream into AST
  - MIR lowerer propagates explicit value via literal field
  - Codegen emits name = value, when literal present
affects: [15-02-PLAN.md, codegen, mir]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Ordered PEG choice for mutual exclusion: '=' value OR (fields), never both"
    - "Token-scan pattern for non-capture-tree tokens: loop over cap.start_pos..cap.end_pos"
    - "MirNode.literal reused as discriminant carrier for enum_variant_def"

key-files:
  created: []
  modified:
    - src/orhon.peg
    - src/parser.zig
    - src/peg/builder.zig
    - src/mir.zig
    - src/codegen.zig

key-decisions:
  - "Ordered PEG choice enforces mutual exclusion: = int_literal / (...fields) — A(f32) = 4 is a parse error by grammar"
  - "Reuse MirNode.literal for enum discriminant value — no new field needed, field was null for enum_variant_def"
  - "No value validation in compiler — Zig handles overflow and duplicate discriminants downstream"

patterns-established:
  - "Token-scan pattern for builder: loop cap.start_pos..cap.end_pos checking token kinds directly"

requirements-completed: [TAMGA-01]

# Metrics
duration: 5min
completed: 2026-03-26
---

# Phase 15 Plan 01: Enum Explicit Values — Grammar through Codegen Summary

**Full pipeline wired for `pub enum(u32) Scancode { A = 4, B = 5 }` — PEG grammar, AST, builder, MIR, and codegen all updated in 5 files, ~30 lines changed.**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-03-26T05:00:00Z
- **Completed:** 2026-03-26T05:05:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments

- PEG `enum_variant` rule extended with `'=' int_literal` as first ordered choice — mutual exclusion by grammar
- `EnumVariant` AST struct gains `value: ?*Node = null` with safe default for existing callers
- Builder scans token stream for `.assign` + `.int_literal` within each variant's token range
- MIR lowerer propagates `v.value.int_literal` to `m.literal` with `literal_kind = .int`
- Codegen emits `name = value,` when `child.literal` is set, `name,` otherwise — backward compatible

## Task Commits

1. **Task 1: Grammar rule + AST struct + Builder** - `81d59d6` (feat)
2. **Task 2: MIR lowerer + Codegen emit** - `7264158` (feat)

## Files Created/Modified

- `src/orhon.peg` - enum_variant rule: added `'=' int_literal` ordered choice alternative
- `src/parser.zig` - EnumVariant struct: added `value: ?*Node = null` field
- `src/peg/builder.zig` - buildEnumVariant: token-scan for assign + int_literal, create int_literal node
- `src/mir.zig` - enum_variant branch: propagate v.value to m.literal + m.literal_kind
- `src/codegen.zig` - enum_variant_def branch: conditional emit for `name = value,` vs `name,`

## Decisions Made

- Used ordered PEG choice (`=` value first, fields second) to enforce mutual exclusion — `A(f32) = 4` is a parse error, not a semantic error
- Reused `MirNode.literal` for the discriminant value — avoids adding new MirNode fields, field was always null for enum_variant_def nodes
- No validation of duplicate or out-of-range discriminants — delegated to Zig compiler per D-07

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Pipeline is wired end-to-end but not yet tested with real `.orh` input
- Plan 02 will add integration tests with actual `.orh` files containing `A = 4` syntax and verify generated Zig output

---
*Phase: 15-enum-explicit-values*
*Completed: 2026-03-26*
