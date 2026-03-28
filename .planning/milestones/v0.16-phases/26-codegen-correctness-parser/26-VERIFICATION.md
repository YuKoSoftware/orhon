---
phase: 26-codegen-correctness-parser
verified: 2026-03-28T10:00:00Z
status: passed
score: 4/4 must-haves verified
---

# Phase 26: Codegen Correctness & Parser Verification Report

**Phase Goal:** Cross-module type checks emit correct Zig, `Async(T)` is rejected at compile time, and negative literals parse as arguments
**Verified:** 2026-03-28T10:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Negative literals like -0.5 and -1 are accepted as function call arguments | VERIFIED | `'-' unary_expr` at line 366 of `src/orhon.peg`; `.minus` branch at lines 1481-1484 of `src/peg/builder.zig`; test fixture `test_negative_args()` calls `negate_helper(-0.5, -1.0)` |
| 2 | Cross-module `is` operator emits tagged union comparison, not `@TypeOf` | VERIFIED | AST path at `codegen.zig:1773` checks `getTypeClass(val_node) == .arbitrary_union` and emits `val == ._TypeName`; MIR path at `codegen.zig:2231-2232` checks `lhs_mir.type_class == .arbitrary_union or val_mir.type_class == .arbitrary_union` |
| 3 | `Async(T)` in a type annotation produces a compile error | VERIFIED | `codegen.zig:4179-4183` — `reporter.report()` called with message "Async(T) is not yet implemented — cannot use as a type"; fallback to `"void"` to continue collecting errors |
| 4 | All 260 existing tests continue to pass | VERIFIED | `./testall.sh` output: "All 260 tests passed" — exit 0 |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/orhon.peg` | Unary negation in grammar | VERIFIED | `'-' unary_expr` present at line 366, correctly placed after `!` and before `&` |
| `src/peg/builder.zig` | Unary negation AST builder | VERIFIED | `.minus` branch at lines 1481-1484 inside `buildUnaryExpr`, creates `.unary_expr{ .op = "-", .operand = operand }` |
| `src/codegen.zig` | Fixed cross-module is operator and Async(T) error | VERIFIED | Both AST path (line 1773) and MIR path (lines 2231-2232) guard `@TypeOf` fallback with `arbitrary_union` check; Async(T) at lines 4179-4183 calls `reporter.report()` |
| `test/fixtures/tester.orh` | Negative literal argument test fixture | VERIFIED | `negate_helper(-0.5, -1.0)`, `test_negative_args()`, and `test "negative literal args"` block present |
| `test/fixtures/tester_main.orh` | Runtime test call | VERIFIED | `tester.test_negative_args()` check with PASS/FAIL print at lines 697-702 |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/orhon.peg` | `src/peg/builder.zig` | unary_expr rule triggers buildUnaryExpr | WIRED | Grammar rule `'-' unary_expr` at line 366; builder handles `.minus` token at line 1481 |
| `src/codegen.zig` | `src/errors.zig` | Async(T) reports compile error through reporter | WIRED | `reporter.report(.{ .message = err_msg })` at line 4182; `err_msg` is `allocPrint`-allocated with `defer free` |

### Data-Flow Trace (Level 4)

Not applicable — modified files are compiler passes (parser, codegen), not components that render dynamic runtime data. The data flow is compile-time transformation of AST to Zig source text.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Unary negation parses as function argument | `./testall.sh` — runtime test `test_negative_args` | PASS: negative literal args printed in tester output | PASS |
| Cross-module is operator and Async(T) | `./testall.sh` — all 260 tests | All 260 tests passed | PASS |
| Compiler builds without errors | `zig build` (run as part of testall.sh stage 02) | Build stage passed | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| CGN-04 | 26-01-PLAN.md | Cross-module `is` operator emits tagged union check instead of `@TypeOf` comparison | SATISFIED | AST path `codegen.zig:1773`; MIR path `codegen.zig:2231`; non-union fallback to `@TypeOf` preserved |
| CGN-05 | 26-01-PLAN.md | `Async(T)` reports compile error instead of silently mapping to `void` | SATISFIED | `codegen.zig:4179-4183`; `reporter.report()` called with descriptive message |
| PRS-01 | 26-01-PLAN.md | Negative float/int literals accepted as function call arguments (`-0.5`, `-1`) | SATISFIED | Grammar rule at `orhon.peg:366`; builder at `builder.zig:1481`; end-to-end test in tester fixtures |

No orphaned requirements — all three requirements claimed in the plan frontmatter (`requirements: [PRS-01, CGN-04, CGN-05]`) are accounted for and satisfied.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `src/codegen.zig` | 4183 | `break :blk "void"; // fallback after error` | Info | Intentional fallback — error has been reported via `reporter.report()`, void is used only to allow the pass to continue collecting further errors. Not a stub. |

No blocker or warning anti-patterns found. The single info item is deliberate design (continue-on-error pattern documented in comments).

### Human Verification Required

None. All success criteria are mechanically verifiable and confirmed:

1. Grammar change is textual and confirmed by grep.
2. Builder change is textual and confirmed by grep.
3. Codegen changes are textual and confirmed by grep.
4. Test fixture exercises the parser fix end-to-end.
5. Full test suite (260 tests) passes with exit 0.

### Gaps Summary

No gaps. All four truths verified, all five artifacts substantive and wired, all three requirements satisfied, all 260 tests pass.

---

_Verified: 2026-03-28T10:00:00Z_
_Verifier: Claude (gsd-verifier)_
