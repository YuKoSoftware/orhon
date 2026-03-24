---
phase: 01-compiler-bug-fixes
verified: 2026-03-24T17:00:00Z
status: passed
score: 4/4 success criteria verified
re_verification: null
gaps: []
human_verification: []
---

# Phase 1: Compiler Bug Fixes — Verification Report

**Phase Goal:** The compiler produces correct output for every known failing case
**Verified:** 2026-03-24T17:00:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Cross-module struct method calls emit `const &` argument passing, not by-value copies | VERIFIED | `value_to_const_ref` coercion enum variant added to `src/mir.zig:60`, detected in `detectCoercion` at line 536, emitted as `&` prefix in `src/codegen.zig:2426`. `mir_annotator.all_decls = &all_module_decls` wired in `src/main.zig:1090`. |
| 2 | Qualified generic types like `math.Vec2(f64)` fail with a clear error when the target type does not exist in the referenced module | VERIFIED | `all_decls` field added to `TypeResolver` in `src/resolver.zig:65`. Qualified name short-circuit (`is_known = is_qualified or`) removed — confirmed by grep returning 0 matches. Cross-module DeclTable lookup in `validateType` at line 853. `type_resolver.all_decls = &all_module_decls` wired in `src/main.zig:1051`. `bash test/11_errors.sh` passes 43/43. |
| 3 | Passing a const struct to a function by value does not trigger a spurious ownership-move error | VERIFIED | `is_const: bool` field added to `VarState` in `src/ownership.zig:19`. Guard in `checkExpr` at line 368: `!state.is_primitive and !state.is_const`. `checkStatement` sets `is_const = true` for `const_decl` and `compt_decl` nodes. 2 unit tests: "ownership - const value reuse allowed" (line 995) and "ownership - var value still moves" (line 1022). |
| 4 | `orhon test` actually runs test blocks and reports the correct passed/failed count | VERIFIED | `writeTestOutput` extracted as a free function in `src/zig_runner.zig:376` accepting a generic writer. `formatTestOutput` delegates to it. Output string "all tests passed" at line 414. 2 unit tests for `formatTestOutput` at lines 910 and 922. `bash test/05_compile.sh` passes all 3 orhon-test checks: "all tests pass", "no failures reported", "detects failure". |

**Score:** 4/4 success criteria verified

### Required Artifacts

#### Plan 01-01 Artifacts (BUG-03, BUG-04)

| Artifact | Required Pattern | Status | Evidence |
|----------|-----------------|--------|----------|
| `src/ownership.zig` | `is_const` | VERIFIED | 7 matches: field def (line 19), `define()` init (line 46), `defineTyped()` param (line 51), stored in VarState (line 56), `checkStatement` assignment (line 223), passed to `defineTyped` (line 224), guard in `checkExpr` (line 368) |
| `src/zig_runner.zig` | `formatTestOutput` / `writeTestOutput` | VERIFIED | `formatTestOutput` at line 273 delegates to extracted `writeTestOutput` at line 376; 2 unit tests confirmed at lines 910 and 922 |

#### Plan 01-02 Artifacts (BUG-01, BUG-02)

| Artifact | Required Pattern | Status | Evidence |
|----------|-----------------|--------|----------|
| `src/mir.zig` | `value_to_const_ref` | VERIFIED | 3 matches: enum variant (line 60), detected in `detectCoercion` (line 536), unit test (line 1690). `all_decls` field at line 166, cross-module logic in `resolveCallSig` at lines 569 and 579. |
| `src/codegen.zig` | `value_to_const_ref` | VERIFIED | 2 matches: `generateCoercedExprMir` switch case (line 2426), `return_stmt` switch case (line 1348) |
| `src/resolver.zig` | `all_decls` | VERIFIED | 8 matches: field definition (line 65), `validateType` usage (line 853), 2 unit tests each setting up `all_decls` (lines 1587-1631) |
| `src/main.zig` | `all_module_decls` | VERIFIED | Populated at line 991, accumulated per module at line 1044, wired into `type_resolver` (line 1051), `mir_annotator` (line 1090), and `cg` (line 1124) |

### Key Link Verification

| From | To | Via | Status | Evidence |
|------|----|-----|--------|----------|
| `src/main.zig` | `src/mir.zig` | `mir_annotator.all_decls = &all_module_decls` | WIRED | `main.zig:1090` confirmed by grep |
| `src/mir.zig` | `src/codegen.zig` | `value_to_const_ref` coercion annotation read by codegen | WIRED | `codegen.zig:2426` — switch case emits `&` prefix |
| `src/main.zig` | `src/resolver.zig` | `type_resolver.all_decls = &all_module_decls` | WIRED | `main.zig:1051` confirmed by grep |
| `src/ownership.zig` | `checkExpr` identifier branch | `is_const` check before marking moved | WIRED | `ownership.zig:368` — `!state.is_const` guard present |
| `src/zig_runner.zig` | `zig build test` invocation | `formatTestOutput` wraps `writeTestOutput` | WIRED | `zig_runner.zig:273-278` delegates and flushes |

### Data-Flow Trace (Level 4)

Not applicable — these are compiler pipeline fixes, not UI/rendering components. Data flows through internal Zig struct fields and function call chains verified at Level 3 above.

### Behavioral Spot-Checks

| Behavior | Check | Result | Status |
|----------|-------|--------|--------|
| `orhon test` runs test blocks and reports results | `bash test/05_compile.sh` orhon test section | 3/3 checks pass: "all tests pass", "no failures reported", "detects failure" | PASS |
| Ownership checker allows const struct reuse | `zig build test` ownership unit tests | 697/697 tests pass including "ownership - const value reuse allowed" | PASS |
| Codegen emits `&` for `value_to_const_ref` coercion | `zig build test` mir unit tests | `detectCoercion - value to const ref` and related tests pass | PASS |
| Resolver rejects unknown qualified generics | `bash test/11_errors.sh` | 43/43 error fixture tests pass | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| BUG-01 | 01-02-PLAN.md | Cross-module struct method calls emit by-value instead of `const &` | SATISFIED | `value_to_const_ref` coercion in mir+codegen, `all_decls` wired from main.zig; commits `cb6127a` |
| BUG-02 | 01-02-PLAN.md | Qualified generic types pass validation without checking target module | SATISFIED | `is_known = is_qualified or` short-circuit removed; cross-module DeclTable validation in resolver; commits `c18ed13` |
| BUG-03 | 01-01-PLAN.md | Const struct values incorrectly treated as moved on by-value pass | SATISFIED | `is_const` field in VarState, guard in checkExpr; commits `c35c3ac` |
| BUG-04 | 01-01-PLAN.md | `orhon test` reports 0/0 instead of actual test results | SATISFIED | `writeTestOutput` extracted, stdlib auto-imports added, fixture syntax fixed; commits `b99c538` |

No orphaned requirements — all BUG-01 through BUG-04 are claimed by plans and verified in code.

### Anti-Patterns Found

| File | Pattern | Severity | Notes |
|------|---------|----------|-------|
| `src/zig_runner.zig` | `std.fs.File.stderr().writer(&buf)` (line 275) | Info | Plan acceptance criterion expected `getStdErr` or `io.bufferedWriter`, but implementation uses a valid alternative Zig 0.15 API. Tests pass — behavior correct. |

No blockers or warnings found in the modified files. The zig_runner.zig note is informational only — the observable behavior (`orhon test` works) is fully verified by `test/05_compile.sh`.

### Pre-Existing Test Failures (Not Regressions)

The following test failures exist in the current state but were confirmed pre-existing before any phase commits:

- **`test/09_language.sh` "tester module compiles"** — `i32.new()` collection constructors generate invalid Zig (`type 'i32' has no members`) and `[*]i32` array init syntax error. Pre-existing in b189474 and cb6127a. Logged to `docs/TODO.md`.
- **`test/09_language.sh` "null union codegen"** — Pre-existing since at least b189474. Confirmed in baseline check.
- **`test/10_runtime.sh` (all 98 runtime tests)** — Downstream failures from tester module not compiling. Pre-existing.

These failures are outside phase 1's scope (BUG-01 through BUG-04). They are not regressions introduced by this phase.

### Unit Test Counts

- `zig build test --summary all`: **697/697 passed** (41/41 build steps succeeded)
- `bash test/05_compile.sh`: **17/17 passed** (includes all 3 `orhon test` checks)
- `bash test/11_errors.sh`: **43/43 passed**

### Human Verification Required

None. All four success criteria are verifiable programmatically and confirmed passing.

### Summary

All four success criteria for Phase 1 are achieved. Every required artifact exists, contains substantive implementation (not stubs), is wired into the compiler pipeline, and is covered by unit and integration tests. The four commits (`cb6127a`, `c35c3ac`, `b99c538`, `c18ed13`) correspond exactly to the four bugs. The `zig build test` suite passes 697/697 with no new failures introduced.

The remaining test failures in `test/09_language.sh` and `test/10_runtime.sh` were present before phase 1 began and are documented as deferred issues in `docs/TODO.md`. They do not affect the phase goal: "The compiler produces correct output for every known failing case" — where "known failing cases" refers specifically to BUG-01 through BUG-04.

---

_Verified: 2026-03-24T17:00:00Z_
_Verifier: Claude (gsd-verifier)_
