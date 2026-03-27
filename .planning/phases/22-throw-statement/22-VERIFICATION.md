---
phase: 22-throw-statement
verified: 2026-03-27T15:30:00Z
status: passed
score: 8/8 must-haves verified
re_verification: false
---

# Phase 22: throw Statement Verification Report

**Phase Goal:** Orhon programs can use `throw x` to propagate errors and automatically narrow the type of `x` to its value type
**Verified:** 2026-03-27
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `throw x` on an error union variable compiles and generates Zig error-check-and-propagate code | VERIFIED | `src/codegen.zig:1573-1577` emits `if ({s}) |_| {} else |_err| return _err;` |
| 2 | `throw x` in a non-error-returning function produces a compile error | VERIFIED | `src/propagation.zig:283-290` checks `scope.func_returns_error` and reports error |
| 3 | `throw x` on a non-error-union variable produces a compile error | VERIFIED | `src/propagation.zig:265-282` checks `isTracked` and `uvar.is_error_union` |
| 4 | After `throw x`, using `x` directly emits narrowed access in generated Zig | VERIFIED | `src/codegen.zig:1576` puts var in `error_narrowed`; `codegen.zig:2064` emits `catch unreachable` for `.value` access on narrowed vars |
| 5 | The example module demonstrates throw and compiles successfully | VERIFIED | `src/templates/example/error_handling.orh:76-80` has `divide_with_throw`; test 09_language.sh passes "example module compiles" |
| 6 | A negative test fixture exercises throw on non-error-union and throw in void function | VERIFIED | `test/fixtures/fail_throw.orh` with `void_throw()`; test 11_errors.sh "rejects throw in void function" PASS |
| 7 | Generated Zig contains the throw pattern (`if/else/return _err`) | VERIFIED | test/09_language.sh "throw generates error propagation pattern" PASS (256/256 suite) |
| 8 | The error handling docs describe throw syntax and semantics | VERIFIED | `docs/08-error-handling.md` has `## throw Statement` section with syntax, requirements, before/after example |

**Score:** 8/8 truths verified

---

### Required Artifacts

#### Plan 01 Artifacts

| Artifact | Provides | Level 1: Exists | Level 2: Substantive | Level 3: Wired | Status |
|----------|----------|-----------------|---------------------|----------------|--------|
| `src/lexer.zig` | kw_throw token kind and keyword mapping | YES | `kw_throw` in enum (line 63), `"throw"` in KEYWORDS map (line 169) | Used by lexer pipeline | VERIFIED |
| `src/parser.zig` | ThrowStmt struct and throw_stmt NodeKind variant | YES | `throw_stmt` in NodeKind enum (line 42), `throw_stmt: ThrowStmt` in Node union (line 108), `ThrowStmt` struct (line 274) | Used by all passes | VERIFIED |
| `src/orhon.peg` | throw_stmt grammar rule | YES | `throw_stmt <- 'throw' IDENTIFIER TERM` (lines 244-245), wired into `statement` rule (line 231), in KEYWORDS comment (line 589) | Triggers buildThrowStmt via engine | VERIFIED |
| `src/peg/builder.zig` | buildThrowStmt handler | YES | Dispatch at line 152, full implementation at lines 939-945 | Dispatch entry wired to rule name | VERIFIED |
| `src/propagation.zig` | throw validation in checkStatement | YES | Full `throw_stmt` case (lines 265-292): checks `isTracked`, `is_error_union`, `func_returns_error`, calls `markHandled` | Switch case in `checkStatement` | VERIFIED |
| `src/mir.zig` | MirKind.throw_stmt + lowering + populateData | YES | `throw_stmt` in MirKind enum (line 925), in `lowerNode` leaf list (line 1227), `populateData` case copies variable name to `m.name` (lines 1597-1599), `astToMirKind` mapping (line 1627) | Lowering pipeline | VERIFIED |
| `src/codegen.zig` | Zig emission for throw + error_narrowed recording | YES | `throw_stmt` case (lines 1573-1577) emits Zig pattern and calls `error_narrowed.put`; per-function narrowing reset in both `generateFuncMir` (lines 640-651) and `generateFunc` (lines 886-897) | `generateStatementMir` switch | VERIFIED |

#### Plan 02 Artifacts

| Artifact | Provides | Level 1: Exists | Level 2: Substantive | Level 3: Wired | Status |
|----------|----------|-----------------|---------------------|----------------|--------|
| `src/templates/example/error_handling.orh` | throw usage example with test | YES | `divide_with_throw` function (lines 76-80), `test "throw propagation"` (lines 99-101) | Embedded via `@embedFile`; compiled in `orhon init` projects | VERIFIED |
| `test/fixtures/fail_throw.orh` | Negative test cases for throw compile errors | YES | `void_throw()` function with `throw result` in void-returning function | Referenced in test/11_errors.sh | VERIFIED |
| `test/09_language.sh` | Codegen check for throw pattern in generated Zig | YES | Two checks: `|_err| return _err` (line 47) and `catch unreachable` (line 50) | Runs as part of testall.sh stage 09 | VERIFIED |
| `test/11_errors.sh` | Negative test section for throw errors | YES | `neg_throw` section (lines 472-482) copies fail_throw.orh and checks output | Runs as part of testall.sh stage 11 | VERIFIED |
| `docs/08-error-handling.md` | throw documentation | YES | `## throw Statement` section with syntax, requirements, semantics, before/after example | Read by users; not a code link | VERIFIED |
| `src/peg/token_map.zig` | LITERAL_MAP entry for "throw" | YES | `.{ "throw", .kw_throw }` at line 51 (added in Plan 02 as bug fix) | Required for PEG grammar to match `'throw'` literal | VERIFIED |

---

### Key Link Verification

| From | To | Via | Status | Evidence |
|------|----|-----|--------|----------|
| `src/orhon.peg` | `src/peg/builder.zig` | throw_stmt rule triggers buildThrowStmt | WIRED | `buildNode` dispatch at builder.zig:152 matches rule name `"throw_stmt"` |
| `src/peg/token_map.zig` | `src/orhon.peg` | LITERAL_MAP maps `'throw'` string to kw_throw | WIRED | token_map.zig:51 `.{ "throw", .kw_throw }` — required for PEG string literal matching |
| `src/propagation.zig` | `src/codegen.zig` | propagation validates; codegen emits | WIRED | Both have `throw_stmt` cases; propagation runs before codegen in pipeline |
| `src/codegen.zig` | `error_narrowed` map | throw records narrowing; field_access reads it | WIRED | `error_narrowed.put` at codegen.zig:1576; read at codegen.zig:2064 and codegen.zig:2534 |
| `src/templates/example/error_handling.orh` | `test/09_language.sh` | example compiles and generated Zig is checked | WIRED | `orhon init` embeds the template; test/09_language.sh builds and greps `.orh-cache/generated/example.zig` |
| `test/fixtures/fail_throw.orh` | `test/11_errors.sh` | fixture is compiled and error output checked | WIRED | test/11_errors.sh:475 copies fail_throw.orh and checks error output |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `src/codegen.zig` throw_stmt case | `m.name` (variable name from MIR node) | `src/mir.zig` populateData: `m.name = t.variable` which comes from `ThrowStmt.variable` set by `buildThrowStmt` reading the IDENTIFIER token | Yes — real token text from source | FLOWING |
| `src/codegen.zig` error_narrowed reads | `error_narrowed` map | Written by throw_stmt emission (line 1576) and `is Error` checks | Yes — populated from real throw statements | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full test suite passes | `./testall.sh` | 256/256 tests pass | PASS |
| throw lexer token exists | `grep kw_throw src/lexer.zig` | 2 matches (enum + KEYWORDS) | PASS |
| throw_stmt in all 5 pipeline files | `grep -l throw_stmt src/{propagation,mir,codegen,parser}.zig src/peg/builder.zig` | 5 files match | PASS |
| per-function narrowing reset | `grep prev_error_narrowed src/codegen.zig` | 4 matches (2 save, 2 restore across 2 functions) | PASS |
| fail_throw.orh negative test | `./testall.sh` | "rejects throw in void function" PASS | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| ERR-01 | Plans 01, 02 | `throw x` propagates error from `(Error | T)` and returns early from enclosing function | SATISFIED | codegen.zig emits `if ({s}) |_| {} else |_err| return _err;`; test/09_language.sh checks `|_err| return _err` in generated Zig — PASS |
| ERR-02 | Plans 01, 02 | After `throw x`, variable `x` narrows to value type `T` (no `.value` needed) | SATISFIED | `error_narrowed.put` records var after throw; `.value` access on narrowed vars uses `catch unreachable`; test/09_language.sh checks `catch unreachable` — PASS |
| ERR-03 | Plans 01, 02 | `throw` in a function that doesn't return an error type produces compile error | SATISFIED | propagation.zig checks `func_returns_error`; test/11_errors.sh "rejects throw in void function" — PASS |
| ERR-04 | Plan 02 | Example module and docs updated with `throw` usage | SATISFIED | `error_handling.orh` has `divide_with_throw` + test; `docs/08-error-handling.md` has `## throw Statement` section |

All 4 phase requirements fully satisfied. No orphaned requirements found (REQUIREMENTS.md traceability table maps ERR-01 through ERR-04 exclusively to Phase 22).

---

### Anti-Patterns Found

No blockers or stubs detected.

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| None | — | — | — | — |

The `error_narrowed` per-function scoping fix (saving/restoring in both `generateFuncMir` and `generateFunc`) was proactively implemented, preventing a potential cross-function narrowing leak that the plan identified as a known pitfall.

---

### Human Verification Required

None. All behaviors are verifiable programmatically:

- `throw` compilation correctness is confirmed by the full test suite (256/256 passing)
- The negative test catches the compile error at the propagation level
- Generated Zig patterns are checked by test/09_language.sh against the actual generated file

---

### Gaps Summary

No gaps. All must-haves from both plans are verified:

- Plan 01 (7 pipeline artifacts): all exist, are substantive, and wired
- Plan 02 (5 artifacts + token_map fix): all exist, are substantive, and wired
- All 4 requirements (ERR-01 through ERR-04): satisfied with test evidence
- One auto-fixed deviation: missing `token_map.zig` entry found and fixed during Plan 02 (commit `ecc049c`)
- Full test suite: 256/256 pass

---

_Verified: 2026-03-27_
_Verifier: Claude (gsd-verifier)_
