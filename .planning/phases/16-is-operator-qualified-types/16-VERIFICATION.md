---
phase: 16-is-operator-qualified-types
verified: 2026-03-26T05:50:49Z
status: passed
score: 5/5 must-haves verified
re_verification: true
gaps: []
---

# Phase 16: `is` Operator Qualified Types — Verification Report

**Phase Goal:** The `is` operator works with cross-module types — both `mod.Type` and unqualified forms
**Verified:** 2026-03-26T05:50:49Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #   | Truth                                                                   | Status     | Evidence                                                                                              |
| --- | ----------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------- |
| 1   | `ev is module.Type` parses without error                                | VERIFIED   | Grammar line 316: `IDENTIFIER ('.' IDENTIFIER)* / 'null'`; binary runs, produces PASS is_qualified   |
| 2   | `ev is not module.Type` parses without error                            | VERIFIED   | Same grammar rule; `iso_n is not tester.IsTestType` in tester_main.orh produces PASS is_not_qualified |
| 3   | Codegen emits `@TypeOf(val) == mod.Type` for qualified is checks        | VERIFIED   | generated main.zig line 515: `if ((@TypeOf(iso) == tester.IsTestType))`                              |
| 4   | Existing `is null`, `is Error`, `is i32` paths unchanged                | VERIFIED   | All 243 tests pass; arb_union_return, arb_union_match, arb_union_field etc. pass in stage 10          |
| 5   | Stage 10 explicitly asserts is_qualified and is_not_qualified           | FAILED     | test/10_runtime.sh loop does not include these names; binary outputs PASS but stage doesn't gate it  |

**Score:** 4/5 truths verified

### Required Artifacts

| Artifact                        | Expected                                           | Status   | Details                                                                                          |
| ------------------------------- | -------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------ |
| `src/orhon.peg`                 | Extended compare_expr grammar rule                 | VERIFIED | Line 316: `IDENTIFIER ('.' IDENTIFIER)* / 'null'` — exact expected content                     |
| `src/peg/builder.zig`           | Dotted path scanning + field_expr chain            | VERIFIED | Lines 1243-1280: ArrayListUnmanaged idents, peek-ahead dot scan, left-to-right field_expr chain |
| `src/codegen.zig`               | emitTypePath + field_expr branch in is-check       | VERIFIED | Lines 242-268: emitTypePath and emitTypeMirPath; lines 1699-1706 and 2129-2135: both branches  |
| `test/fixtures/tester.orh`      | IsTestType struct for cross-module is test          | VERIFIED | Line 1422: `pub struct IsTestType { val: i32 }`                                                 |
| `test/fixtures/tester_main.orh` | Cross-module is test cases (is_qualified etc.)     | VERIFIED | Lines 622-635: iso is tester.IsTestType and iso_n is not tester.IsTestType                     |
| `test/09_language.sh`           | Codegen assertion for @TypeOf pattern              | VERIFIED | Lines 107-108: `grep -q "@TypeOf" "$GEN_TESTER"` with pass/fail                                |

### Key Link Verification

| From                  | To                    | Via                                           | Status   | Details                                                              |
| --------------------- | --------------------- | --------------------------------------------- | -------- | -------------------------------------------------------------------- |
| `src/orhon.peg`       | `src/peg/builder.zig` | PEG grammar captures dotted tokens            | VERIFIED | Grammar allows `IDENTIFIER ('.' IDENTIFIER)*`; builder reads tokens with peek-ahead dot scan |
| `src/peg/builder.zig` | `src/codegen.zig`     | Builder produces field_expr node; codegen handles it | VERIFIED | Builder builds field_expr chain; codegen has field_expr branch in both AST-path (line 1699) and MIR-path (line 2129) |

### Data-Flow Trace (Level 4)

| Artifact                        | Data Variable  | Source                                      | Produces Real Data | Status    |
| ------------------------------- | -------------- | ------------------------------------------- | ------------------ | --------- |
| `test/fixtures/tester_main.orh` | `iso` (struct) | `tester.IsTestType(val: 42)` constructor    | Yes                | FLOWING   |
| `src/codegen.zig`               | `b.right`      | builder field_expr chain from token scan    | Yes                | FLOWING   |
| generated `main.zig`            | `@TypeOf(iso)` | Zig intrinsic on real constructed value     | Yes                | FLOWING   |

### Behavioral Spot-Checks

| Behavior                                        | Command                                                         | Result                                              | Status  |
| ----------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------- | ------- |
| `ev is module.Type` parses and runs             | Direct tester binary invocation                                 | PASS is_qualified                                   | PASS    |
| `ev is not module.Type` parses and runs         | Direct tester binary invocation                                 | PASS is_not_qualified                               | PASS    |
| Codegen emits @TypeOf for qualified is          | `grep @TypeOf generated/main.zig`                               | `if ((@TypeOf(iso) == tester.IsTestType))`          | PASS    |
| Stage 09 codegen assertion                      | `bash test/09_language.sh`                                      | PASS qualified is -> @TypeOf codegen                | PASS    |
| Full test suite                                 | `./testall.sh`                                                  | All 243 tests passed                                | PASS    |

### Requirements Coverage

| Requirement | Source Plan  | Description                                                                                 | Status       | Evidence                                                                         |
| ----------- | ------------ | ------------------------------------------------------------------------------------------- | ------------ | -------------------------------------------------------------------------------- |
| TAMGA-02    | 16-01-PLAN.md | `is` operator works with cross-module types — `ev is module.Type` parses and emits correct Zig | SATISFIED    | Grammar rule extended; emitTypePath/emitTypeMirPath implemented; @TypeOf pattern in generated Zig; 243 tests pass |

**Note on TAMGA-02 location:** This requirement is defined in the phase RESEARCH.md and ROADMAP.md (`Requirements: TAMGA-02`) but does not appear in the main `.planning/REQUIREMENTS.md`. That file covers v0.12 and v2 requirements. TAMGA-02 belongs to the v0.13 Tamga Compatibility milestone and is tracked through the ROADMAP only. No orphaned requirements detected.

### Anti-Patterns Found

| File                  | Pattern                  | Severity | Impact                                                                     |
| --------------------- | ------------------------ | -------- | -------------------------------------------------------------------------- |
| `test/10_runtime.sh`  | Missing test registrations | Warning  | is_qualified and is_not_qualified not in explicit assertion loop — runtime binary outputs them correctly but stage 10 will not fail if they regress |

No stubs, TODOs, placeholder returns, or empty implementations found in any of the six modified files.

### Human Verification Required

None. All critical behaviors are verifiable programmatically and confirmed passing.

### Gaps Summary

One gap found: the plan's acceptance criteria required `is_qualified` and `is_not_qualified` to be explicitly registered in `test/10_runtime.sh`'s test name loop. The binary does emit `PASS is_qualified` and `PASS is_not_qualified` (confirmed by direct invocation), and the "runtime correctness — all tests passed" assertion in stage 10 catches any FAIL line in the output. However, individual test-name assertions for these two cases are absent from the loop, meaning a future regression that silently drops them from the binary output would not be caught by stage 10's per-test checks.

The fix is minimal: add `is_qualified` and `is_not_qualified` to the test name list in `test/10_runtime.sh` lines 35-52.

All other must-haves are fully verified: grammar, builder, both codegen paths (AST and MIR), generated Zig correctness, stage 09 assertion, runtime correctness, and no regressions in existing `is null`, `is Error`, `is i32` paths.

---

_Verified: 2026-03-26T05:50:49Z_
_Verifier: Claude (gsd-verifier)_
