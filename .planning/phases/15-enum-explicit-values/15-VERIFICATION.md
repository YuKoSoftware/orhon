---
phase: 15-enum-explicit-values
verified: 2026-03-26T00:00:00Z
status: passed
score: 9/9 must-haves verified
re_verification: false
---

# Phase 15: Enum Explicit Values — Verification Report

**Phase Goal:** Typed enums support explicit integer value assignments per variant (e.g., `A = 4`)
**Verified:** 2026-03-26
**Status:** PASSED
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `pub enum(u32) Foo { A = 1, B = 5 }` parses without error | VERIFIED | Grammar rule `enum_variant <- IDENTIFIER ('=' int_literal / '(' _ param_list _ ')')? TERM` exists in `src/orhon.peg:156`. Example module with Scancode enum compiles via `./testall.sh`. |
| 2 | Codegen emits `A = 1,` and `B = 5,` in generated Zig | VERIFIED | `src/codegen.zig:1114-1115` emits `{s} = {s},\n` when `child.literal` is set. `.orh-cache/generated/example.zig` contains `A = 4,` and `Space = 44,`. |
| 3 | Existing sequential enums (no explicit values) compile unchanged | VERIFIED | Backward-compatible `null` default on `value` field. `./testall.sh` passes all 242 tests including Direction enum. |
| 4 | Tagged union variants with fields still work (no regression) | VERIFIED | PEG ordered choice `'=' int_literal / '(' _ param_list _ ')'` ensures mutual exclusion. All 242 tests pass. |
| 5 | Example module with explicit-value enum compiles via `orhon build` | VERIFIED | `src/templates/example/example.orh:122-127` contains `pub enum(u32) Scancode { A = 4, B = 5, C = 6, Space = 44 }`. Compiles and generates correct Zig. |
| 6 | Generated Zig contains `variant = value` assignments from the example enum | VERIFIED | `.orh-cache/generated/example.zig:60-64` shows `pub const Scancode = enum(u32) { A = 4, ... Space = 44, }`. |
| 7 | Tagged union variant with both fields and explicit value is a parse error | VERIFIED | `test/fixtures/fail_enum_value.orh` contains `Foo(i32) = 4`. Test `neg_enum_val` in `test/11_errors.sh:453` passes — compiler rejects it. |
| 8 | LSP hover handles the new value field without crashing | VERIFIED | `src/main.zig:1651-1655` — `if (v.value) |val|` branch added, displays `= value`. All 242 tests pass. |
| 9 | Docgen handles the new value field without crashing | VERIFIED | `src/docgen.zig:297-301` — `if (v.value) |val|` branch added, appends ` = value`. All 242 tests pass. |

**Score:** 9/9 truths verified

---

### Required Artifacts

#### Plan 01 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/orhon.peg` | Updated enum_variant grammar rule with `= int_literal` alternative | VERIFIED | Line 156: `<- IDENTIFIER ('=' int_literal / '(' _ param_list _ ')')? TERM` |
| `src/parser.zig` | EnumVariant struct with `value: ?*Node = null` field | VERIFIED | Lines 226-231: field present with null default |
| `src/peg/builder.zig` | buildEnumVariant extracts value from `= int_literal` | VERIFIED | Lines 675-693: token scan for `.assign` + `.int_literal`, creates `.int_literal` node |
| `src/mir.zig` | MIR lowerer propagates value as literal text | VERIFIED | Lines 1494-1501: `if (v.value) |val|` sets `m.literal = val.int_literal` and `m.literal_kind = .int` |
| `src/codegen.zig` | Codegen conditionally emits `name = value,` | VERIFIED | Lines 1111-1118: `if (child.literal) |lit|` emits `{s} = {s},\n` |

#### Plan 02 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/templates/example/example.orh` | Explicit-value enum example (Scancode) | VERIFIED | Lines 122-127: `pub enum(u32) Scancode { A = 4, B = 5, C = 6, Space = 44 }` |
| `test/fixtures/fail_enum_value.orh` | Negative test for tagged union + explicit value | VERIFIED | Contains `Foo(i32) = 4` — confirms parse error for disallowed combination |
| `test/09_language.sh` | Codegen assertion for explicit enum values | VERIFIED | Lines 38-41: greps for `= 4` and `= 44` in generated example.zig |
| `test/11_errors.sh` | Negative test runner for fail_enum_value.orh | VERIFIED | Line 453: `run_fixture neg_enum_val fail_enum_value.orh "error"` |

---

### Key Link Verification

#### Plan 01 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/orhon.peg` | `src/peg/builder.zig` | Grammar rule parsed by engine; builder reads capture tree | WIRED | `buildEnumVariant` at line 675 is invoked for `enum_variant` rule (line 155 dispatch). Token scan correctly reads `.assign` + `.int_literal` within variant range. |
| `src/peg/builder.zig` | `src/mir.zig` | AST enum_variant node with value field flows to MIR lowerer | WIRED | `mir.zig:1494` `.enum_variant => |v|` branch reads `v.value` and sets `m.literal`. |
| `src/mir.zig` | `src/codegen.zig` | MirNode.literal carries value text to codegen | WIRED | `codegen.zig:1114` reads `child.literal` and emits `{s} = {s},\n`. |

#### Plan 02 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/templates/example/example.orh` | `test/09_language.sh` | Example module compiles; 09_language.sh greps generated Zig | WIRED | Generated `example.zig` contains `A = 4,` and `Space = 44,`. 09_language.sh grep check passes. |
| `test/fixtures/fail_enum_value.orh` | `test/11_errors.sh` | run_fixture invokes compiler on negative fixture | WIRED | `run_fixture neg_enum_val fail_enum_value.orh "error"` at line 453 passes (compiler rejects `Foo(i32) = 4`). |

---

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `src/codegen.zig` (enum_variant_def emit) | `child.literal` | `MirNode.literal` set from `v.value.int_literal` in `mir.zig:1498` | Yes — integer text from token stream (`ctx.tokens[i+1].text`) | FLOWING |
| `src/templates/example/example.orh` (Scancode enum) | `A = 4`, `Space = 44` | Token text extracted by `buildEnumVariant` | Yes — literal integer text from parsed tokens | FLOWING |

---

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| `pub enum(u32) Scancode { A = 4 }` compiles | `./testall.sh` (09_language.sh check for `= 4`) | PASS — 242/242 | PASS |
| Codegen emits `A = 4,` in generated Zig | Check `.orh-cache/generated/example.zig` | `A = 4,` present at line 61 | PASS |
| Codegen emits `Space = 44,` in generated Zig | Check `.orh-cache/generated/example.zig` | `Space = 44,` present at line 64 | PASS |
| `Foo(i32) = 4` is rejected as parse error | `test/11_errors.sh` neg_enum_val fixture | PASS — compiler rejects it | PASS |
| Existing sequential enums unchanged | `./testall.sh` full suite | PASS — all pre-existing enum tests pass | PASS |
| Full test suite passes | `./testall.sh` | 242/242 passed across all 11 stages | PASS |

---

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| TAMGA-01 | 15-01-PLAN.md, 15-02-PLAN.md | Typed enums support explicit integer value assignments per variant (e.g., `A = 4`) | SATISFIED | Full pipeline implemented: grammar (`orhon.peg`), AST (`parser.zig`), builder (`builder.zig`), MIR (`mir.zig`), codegen (`codegen.zig`). Integration test in `09_language.sh` verifies generated output. Negative test in `11_errors.sh` verifies mutual exclusion. All 242 tests pass. |

Note: TAMGA-01 is defined in `ROADMAP.md` (Phase 15 Requirements field) rather than in `REQUIREMENTS.md`. The current `REQUIREMENTS.md` covers the v0.12 milestone only; v0.13 Tamga Compatibility requirements live in the ROADMAP. No orphaned requirements found — TAMGA-01 is the only ID declared in both plans, and it is fully satisfied.

---

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | No anti-patterns found. No TODOs, stubs, placeholder returns, or empty implementations in any modified file. |

Scan covered: `src/orhon.peg`, `src/parser.zig`, `src/peg/builder.zig`, `src/mir.zig`, `src/codegen.zig`, `src/templates/example/example.orh`, `test/fixtures/fail_enum_value.orh`, `test/09_language.sh`, `test/11_errors.sh`, `src/main.zig`, `src/docgen.zig`.

---

### Human Verification Required

None. All phase success criteria are verifiable programmatically. The test suite (`./testall.sh`) covers parsing, codegen output, negative parse errors, and regression testing. The generated Zig file was inspected directly for correct output.

---

### Gaps Summary

No gaps. All 9 observable truths are verified, all 9 artifacts are substantive and wired, all 5 key links are confirmed connected, data flows end-to-end from token stream through MIR to generated Zig, and the full test suite passes at 242/242.

---

## Commits Verified

| Commit | Plan | Description |
|--------|------|-------------|
| `81d59d6` | 01 | feat(15-01): grammar + AST + builder for explicit enum values |
| `7264158` | 01 | feat(15-01): MIR + codegen emit explicit enum variant values |
| `0725a7a` | 02 | feat(15-02): add Scancode enum example, negative test, and integration assertions |
| `7713749` | 02 | feat(15-02): display explicit enum variant values in LSP hover and docgen |

All four commits exist in git history.

---

_Verified: 2026-03-26_
_Verifier: Claude (gsd-verifier)_
