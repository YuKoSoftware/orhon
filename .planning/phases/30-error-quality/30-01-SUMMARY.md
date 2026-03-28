---
phase: 30-error-quality
plan: 01
subsystem: errors, resolver, lsp
tags: [error-quality, levenshtein, type-mismatch, did-you-mean]
dependency_graph:
  requires: []
  provides: [levenshtein-infrastructure, identifier-suggestions, type-suggestions, standardized-mismatch]
  affects: [resolver.zig, errors.zig, lsp.zig, test/11_errors.sh]
tech_stack:
  added: []
  patterns:
    - Levenshtein DP with stack-allocated row buffer (MAX_NAME_LEN=64)
    - ArrayListUnmanaged for candidate collection (Zig 0.15 pattern)
    - Adaptive suggestion threshold (1 for len<=4, 2 otherwise)
    - Guard checks for non-expression identifier contexts (match patterns, module names, intrinsics)
key_files:
  created: []
  modified:
    - src/errors.zig
    - src/resolver.zig
    - src/lsp.zig
    - test/11_errors.sh
decisions:
  - "Use adaptive Levenshtein threshold (1 for short names, 2 for longer) to reduce false positives"
  - "Guard identifier errors against 12 special cases: primitive names, compiler funcs, arithmetic modes, module names, enum variants, bitfield flags, else pattern, match guard bound vars"
  - "Fix match guard body scope: resolve arm body with guard_scope so bound variables are accessible"
  - "Fix lsp.zig memory leaks (full_path and diags ArrayList) exposed by new error paths"
metrics:
  duration: "~45 minutes"
  completed: "2026-03-28"
  tasks_completed: 2
  files_changed: 4
---

# Phase 30 Plan 01: Error Quality — Levenshtein + Type Mismatch Summary

**One-liner:** Levenshtein distance infrastructure in errors.zig with "did you mean?" wired into resolver identifier/type lookup failures, plus standardized "type mismatch in {if|while} condition" format.

## What Was Built

### Task 1: Levenshtein infrastructure (errors.zig)

Three public functions added to `src/errors.zig`:

- `levenshtein(a, b)` — standard O(mn) DP with stack-allocated `[MAX_NAME_LEN+1]usize` row buffer. Guards against zero-length strings and names over 64 chars.
- `closestMatch(query, candidates, threshold)` — iterates candidates, returns best match with `d > 0 && d < threshold`. Guards against queries of len <= 2.
- `formatSuggestion(query, candidates, allocator)` — adaptive threshold (1 for len<=4, 2 otherwise), returns ` — did you mean 'X'?` as allocated string or null.

9 unit tests added covering exact match, transposition (2 edits), insertion, deletion, empty strings, and all closestMatch edge cases.

### Task 2: Resolver wiring (resolver.zig)

**A. Unknown identifier suggestions (ERR-01):**
- `.identifier` arm now builds candidate list from scope chain + `decls.{funcs,structs,enums,vars}`, calls `formatSuggestion`, and reports `"unknown identifier 'X' — did you mean 'Y'?"` instead of silently returning RT.unknown.
- 12 guards prevent false errors: primitive type names, compiler funcs (`cast`, `copy`, etc.), arithmetic modes (`wrap`, `sat`, `overflow`), known module names (via `all_decls`), enum variants, bitfield flags, `else` pattern keyword.
- Match arm patterns: `resolveExpr` is now skipped for identifier patterns (they're enum variants, guard-bound vars, or `else`) — only called for non-identifier patterns.

**B. Unknown type suggestions (ERR-01):**
- `validateType` for `.type_named` now builds candidate list from `decls.{structs,enums,bitfields,types}` + `PRIMITIVE_NAMES` constant, calls `formatSuggestion`, and reports `"unknown type 'X' — did you mean 'Y'?"`.

**C. Standardized type mismatch messages (ERR-02):**
- `"if condition must be bool, got 'X'"` → `"type mismatch in if condition: expected bool, got 'X'"`
- `"while condition must be bool, got 'X'"` → `"type mismatch in while condition: expected bool, got 'X'"`
- Existing `"return type mismatch: expected 'X', got 'Y'"` and `"type mismatch: expected 'X', got 'Y'"` left as-is (already correct format).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Levenshtein test expected wrong value for transposition**
- **Found during:** Task 1 RED phase
- **Issue:** Plan behavior spec said `levenshtein("coutn", "count") == 1` but standard Levenshtein gives 2 (adjacent transposition requires delete+insert). The comment in the plan acknowledged "~ 2 edits or substitution" but the assertion was 1.
- **Fix:** Updated test to expect 2 and renamed to "levenshtein transposition". The algorithm is correct — `closestMatch` with threshold=2 still finds "count" for "coutn" (d=2 < threshold+1=3).
- **Files modified:** src/errors.zig
- **Commit:** bf141b1

**2. [Rule 1 - Bug] Match arm body not resolving with guard scope**
- **Found during:** Task 2 integration testing
- **Issue:** Guard-bound variable `x` in `(x if x > 0) => { return x }` was accessible in the guard expression but NOT in the arm body, because `resolveNode(ma.body, scope)` used the outer scope. Before my changes this silently returned RT.unknown for `x`; after, it emitted "unknown identifier 'x'".
- **Fix:** When a guard is present, resolve the arm body with `guard_scope` (which contains the bound variable). Non-guarded arms still resolve with the outer scope.
- **Files modified:** src/resolver.zig
- **Commit:** ae1f40c

**3. [Rule 1 - Bug] lsp.zig memory leaks in makeDiag and toDiagnostics**
- **Found during:** Task 2 — `zig build test` showed 2 leaked allocations in LSP arena tests
- **Issue:** `makeDiag` allocated `full_path` via `allocPrint` but never freed it before returning. `toDiagnostics` built a `diags` ArrayListUnmanaged but never called `deinit` before returning the duped slice. These were pre-existing bugs that only manifested in tests after my changes made the resolver emit more errors, triggering the LSP diagnostic conversion code path more often.
- **Fix:** Added `defer allocator.free(full_path)` in `makeDiag`; added `defer diags.deinit(allocator)` in `toDiagnostics`.
- **Files modified:** src/lsp.zig
- **Commit:** ae1f40c

**4. [Rule 2 - Missing functionality] Guards for special identifier contexts**
- **Found during:** Task 2 integration testing — `./testall.sh` showed 173 failures from `i64`, `f32`, `allocator`, `wrap`, `sat`, `overflow`, enum variants, and `else` being flagged as unknown identifiers.
- **Issue:** The resolver's `.identifier` arm returns RT.unknown legitimately for many non-error contexts. These needed explicit guards before the error path.
- **Fix:** Added 12 guard checks covering all legitimate silent-return cases.
- **Files modified:** src/resolver.zig
- **Commit:** ae1f40c

**5. [Rule 2 - Missing functionality] Update 11_errors.sh tests for new message format**
- **Found during:** Task 2 — 3 tests in `test/11_errors.sh` matched old message format.
- **Fix:** Updated 3 grep patterns from `"condition must be bool"` to `"type mismatch.*condition"`.
- **Files modified:** test/11_errors.sh
- **Commit:** ae1f40c

## Results

- All 262 integration tests pass (`./testall.sh`)
- All unit tests pass (`zig build test`)
- ERR-01: Unknown identifiers and unknown types produce "did you mean 'X'?" when a close match exists
- ERR-02: if/while condition errors use "type mismatch in ... condition: expected bool, got 'X'" format
- Pre-existing LSP memory leaks fixed

## Self-Check: PASSED

Files created/modified:
- src/errors.zig — FOUND
- src/resolver.zig — FOUND
- src/lsp.zig — FOUND
- test/11_errors.sh — FOUND
- .planning/phases/30-error-quality/30-01-SUMMARY.md — FOUND

Commits:
- bf141b1 — FOUND (Task 1: Levenshtein infrastructure)
- ae1f40c — FOUND (Task 2: resolver wiring, lsp fixes, test updates)
