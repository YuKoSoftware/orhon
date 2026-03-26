---
phase: quick
plan: 260326-izf
subsystem: resolver, types, fixtures, templates, docs
tags: [language-simplification, type-system, cleanup]
dependency_graph:
  requires: []
  provides: [no-bitsize-compiler]
  affects: [resolver, types, all-fixtures, all-templates, test-scripts, docs]
tech_stack:
  added: []
  patterns: [explicit-type-annotations-always-required]
key_files:
  modified:
    - src/resolver.zig
    - src/types.zig
    - src/templates/main.orh
    - src/templates/example/example.orh
    - src/templates/example/data_types.orh
    - test/fixtures/tester_main.orh
    - test/fixtures/fail_syntax.orh
    - test/fixtures/fail_threads.orh
    - test/fixtures/fail_ownership.orh
    - test/fixtures/fail_functions.orh
    - test/fixtures/fail_enums.orh
    - test/fixtures/fail_propagation.orh
    - test/fixtures/fail_structs.orh
    - test/fixtures/fail_borrow.orh
    - test/fixtures/fail_scope.orh
    - test/fixtures/fail_match.orh
    - test/fixtures/fail_types.orh
    - test/05_compile.sh
    - test/06_library.sh
    - test/08_codegen.sh
    - test/11_errors.sh
    - docs/02-types.md
    - docs/03-variables.md
    - docs/11-modules.md
decisions:
  - Bare numeric literals always require explicit type — no default inference, no bitsize shorthand
  - Updated array literal test to expect numeric_literal (not i32) since int literals are unresolved without explicit type
metrics:
  duration: ~12 minutes
  completed: 2026-03-26
---

# Quick Task 260326-izf: Remove #bitsize Metadata and Mechanic — Summary

**One-liner:** Removed `#bitsize` mechanic from resolver, types, all fixtures, templates, test scripts, and docs — numeric literals now always require explicit type annotations.

## Objective

Simplify the language by removing the `#bitsize` configuration footgun. Bare numeric literals now require explicit type annotations unconditionally. The only change visible to users is the error message, which changes from "numeric literal requires explicit type or #bitsize" to "numeric literal requires explicit type".

## Tasks Completed

### Task 1: Remove bitsize from resolver, update error message

- Removed `bitsize: ?u16 = null` field from `TypeResolver` struct
- Removed `#bitsize` metadata extraction loop (16 lines) from `resolve()`
- Simplified `resolveExprInner`: `.int_literal` always returns `RT{ .primitive = .numeric_literal }`, `.float_literal` always returns `RT{ .primitive = .float_literal }` — no conditional branching
- Updated error message in `var_decl` and `const_decl` check blocks (both occurrences)
- Removed "bitsize resolves numeric literals" unit test entirely
- Renamed "no bitsize errors on untyped literal" to "untyped numeric literal requires explicit type", removed the `type_resolver.bitsize == null` assertion
- Removed `resolver.bitsize = 32` from "explicit type annotation preferred" test
- Updated "array literal infers element type" test: removed `resolver.bitsize = 32`, updated expected result from `"i32"` to `"numeric_literal"`

**Commit:** f364007

### Task 2: Remove #bitsize from fixtures, templates, test scripts, docs

- Removed `#bitsize = 32` from all 12 test fixture `.orh` files (all at line 6)
- Removed `#bitsize = 32` from `src/templates/main.orh` (new project template)
- Removed `#bitsize` comment line from `example.orh` metadata documentation section
- Removed entire `#bitsize` section (5 lines) from `data_types.orh` example module
- Removed `#bitsize = 32` from heredocs in 4 test scripts (1 in 05_compile.sh, 2 in 06_library.sh, 1 in 08_codegen.sh, 4 in 11_errors.sh)
- Updated `docs/02-types.md`: replaced bitsize-based paragraph and code block with explicit-type-required rule
- Updated `docs/03-variables.md`: replaced bitsize-inferred examples with explicit-type examples, updated "The rule" paragraph
- Updated `docs/11-modules.md`: removed `#bitsize` from metadata directive list and removed `#bitsize = 32` from example code block
- Updated `src/types.zig` comments on `numeric_literal` and `float_literal` variants

**Commit:** 0ee05e5

## Verification

All 248 tests pass after changes.

## Deviations from Plan

**1. [Rule 2 - Missing] Updated types.zig comment**
- Found during Task 2 sweep
- `src/types.zig` had comments saying "resolved to concrete type by bitsize" on the `numeric_literal` and `float_literal` variants
- Updated to "requires explicit type annotation" to match new behavior
- The plan listed `src/types.zig` in `files_modified` implicitly; the sweep caught it

None of the plan's existing fixtures required explicit type additions — all numeric literals in the fixture files were either already explicitly typed, used in function arguments (not var_decl), or in comparison expressions, so no `.orh` content changes beyond removing the `#bitsize = 32` line were needed.

## Known Stubs

None.

## Self-Check: PASSED

- `src/resolver.zig` modified: FOUND
- `src/types.zig` modified: FOUND
- `src/templates/main.orh` modified: FOUND
- All 12 fixture files modified: FOUND
- Commits f364007 and 0ee05e5: FOUND
- All 248 tests pass: VERIFIED
