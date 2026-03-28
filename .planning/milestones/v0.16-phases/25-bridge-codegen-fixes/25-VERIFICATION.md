---
phase: 25-bridge-codegen-fixes
verified: 2026-03-28T00:00:00Z
status: passed
score: 4/4 must-haves verified
gaps: []
---

# Phase 25: Bridge Codegen Fixes Verification Report

**Phase Goal:** Bridge function codegen emits correct Zig for all three known pointer/visibility bugs
**Verified:** 2026-03-28
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A `const &BridgeStruct` parameter generates `&arg` at the call site | VERIFIED | `detectCoercion` returns `value_to_const_ref` for `const &` param types; path in `annotateCallCoercions` (mir.zig:496) is unaffected by the `!sig.is_bridge` guard since `detectCoercion` runs before the auto-borrow block |
| 2 | A bridge struct value parameter inside an error-union function stays by-value | VERIFIED | `annotateCallCoercions` (mir.zig:510) guards the const auto-borrow block with `!sig.is_bridge` — bridge calls skip promotion entirely |
| 3 | A sidecar `export fn` generates `pub export fn` so `@import` sees the symbol | VERIFIED | main.zig:1102-1131 replaces `copyFile` with read-modify-write that prepends `pub ` to any `export fn` not already prefixed |
| 4 | All 260 existing tests continue to pass | VERIFIED | `./testall.sh` output: "All 260 tests passed"; `zig build test` exits 0 |

**Score:** 4/4 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/declarations.zig` | `is_bridge: bool` field on `FuncSig` | VERIFIED | Line 26: `is_bridge: bool = false` with doc comment explaining bridge exclusion rationale |
| `src/declarations.zig` | `collectFunc` sets `.is_bridge = f.is_bridge` | VERIFIED | Line 281: `.is_bridge = f.is_bridge` |
| `src/declarations.zig` | Bridge struct methods set `is_bridge = true` | VERIFIED | Line 369: `is_bridge = true, // methods on bridge structs are always bridge` |
| `src/mir.zig` | `!sig.is_bridge` guard in `annotateCallCoercions` | VERIFIED | Line 510: `if (is_direct_call and arg.* == .identifier and !sig.is_bridge)` |
| `src/codegen.zig` | `isPromotedParam` helper used at call site | VERIFIED | Lines 84-88, 688, 2451 — helper checks `const_ref_params` map |
| `src/main.zig` | Sidecar copy with `pub export fn` fixup | VERIFIED | Lines 1102-1131: read-modify-write loop using `indexOfPos` for `"export fn"`, prepends `"pub "` when `already_pub` is false |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/mir.zig` | `src/codegen.zig` | `const_ref_params` map | WIRED | `mir_annotator.const_ref_params` assigned to `cg.const_ref_params` at main.zig:1148 before `cg.generate()` |
| `src/main.zig` | `.orh-cache/generated/*_bridge.zig` | sidecar copy + pub fixup | WIRED | `indexOfPos` scan loop writes modified content via `createFile` + `writeAll` at lines 1118-1131 |

### Data-Flow Trace (Level 4)

Not applicable — this phase modifies compiler passes (codegen, MIR annotation, sidecar copy), not components that render dynamic user data. Data flow is internal to the compilation pipeline and verified by the full test suite.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Unit tests pass | `zig build test` | Exit 0 | PASS |
| Full suite (260 tests) | `./testall.sh` | "All 260 tests passed" | PASS |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CGN-01 | 25-01-PLAN.md | `const &BridgeStruct` parameter emits pointer pass (`&arg`) instead of by-value | SATISFIED | `detectCoercion` produces `value_to_const_ref` for `const &` param types; this path is type-driven and unaffected by the bridge guard |
| CGN-02 | 25-01-PLAN.md | Bridge struct value params in error-union functions stay by-value (no silent `*const` promotion) | SATISFIED | `!sig.is_bridge` guard at mir.zig:510 prevents const auto-borrow for all bridge calls |
| CGN-03 | 25-01-PLAN.md | Sidecar `export fn` generates `pub export fn` so bridge functions are accessible | SATISFIED | main.zig sidecar copy section (lines 1102-1131) rewrites `export fn` to `pub export fn` |

No orphaned requirements — REQUIREMENTS.md traceability table marks CGN-01, CGN-02, CGN-03 as Complete for Phase 25.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | — | — | None found |

No TODOs, no stubs, no hardcoded empty returns in the modified code paths.

### Human Verification Required

None. All three bug fixes are verifiable programmatically:

- CGN-01 and CGN-02: verified by reading the `!sig.is_bridge` guard at mir.zig:510 and confirming the `detectCoercion` path at mir.zig:496 is not affected.
- CGN-03: verified by reading the read-modify-write loop at main.zig:1118-1131.
- Regression safety: verified by `./testall.sh` returning "All 260 tests passed".

### Gaps Summary

No gaps. All four must-have truths are verified, both task commits exist in git history (`02815b6` and `969d077`), all three requirement IDs are satisfied, and the full test suite passes.

---

_Verified: 2026-03-28_
_Verifier: Claude (gsd-verifier)_
