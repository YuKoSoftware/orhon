---
phase: 08-const-auto-borrow
plan: 01
subsystem: mir
tags: [mir, const-auto-borrow, annotation, coercion]
dependency_graph:
  requires: []
  provides: [const_vars-tracking, const_ref_params-map, value_to_const_ref-annotation]
  affects: [src/mir.zig]
tech_stack:
  added: []
  patterns: [TDD, const-auto-borrow, Pitfall-3-prevention]
key_files:
  created: []
  modified:
    - src/mir.zig
decisions:
  - "Used StringHashMapUnmanaged(void) for const_vars and promoted_params — O(1) lookup, minimal overhead"
  - "Used StringHashMapUnmanaged(AutoHashMapUnmanaged(usize,void)) for const_ref_params — nested map avoids merge conflicts across call sites"
  - "Applied coercion only in the else branch of detectCoercion — prevents double-annotation when explicit const& param already triggers value_to_const_ref"
  - "Populated promoted_params at function entry from const_ref_params to prevent double-borrow (Pitfall 3)"
  - "isNonPrimitiveType helper excludes .primitive (all primitives including String) and isValueType (Vector)"
metrics:
  duration_minutes: 20
  completed_date: "2026-03-25"
  tasks_completed: 2
  files_modified: 1
---

# Phase 08 Plan 01: Const Auto-Borrow MIR Annotation Summary

One-liner: MirAnnotator tracks const variables and annotates non-primitive const args with value_to_const_ref coercion at call sites, recording (func_name, param_index) pairs for Zig signature promotion in Plan 02.

## What Was Built

Extended `MirAnnotator` in `src/mir.zig` with three new data structures and corresponding logic to implement the MIR half of const auto-borrow (CBOR-01).

### New Fields

- `const_vars: StringHashMapUnmanaged(void)` — populated when processing `const_decl` nodes; enables O(1) const-ness lookup at call sites
- `const_ref_params: StringHashMapUnmanaged(AutoHashMapUnmanaged(usize, void))` — maps function name to set of param indices that need `*const T` in the Zig output; consumed by Plan 02's codegen
- `promoted_params: StringHashMapUnmanaged(void)` — populated at function entry from `const_ref_params`; prevents double-borrow when forwarding const-ref params to other functions (Pitfall 3)

### Extended Logic

`annotateCallCoercions` now:
1. Tracks parameter index with a manual `idx` counter
2. In the `else` branch (when `detectCoercion` found no explicit coercion): checks if the arg is a const identifier, not a promoted param, and of non-primitive type
3. Applies `value_to_const_ref` coercion annotation to the arg node
4. Calls `recordConstRefParam(func_name, idx)` to record the signature promotion

### New Helpers

- `isNonPrimitiveType(t: RT) bool` — returns false for `.primitive` (all primitives including String) and value types (Vector via `builtins.isValueType`), true for named structs, generics, enums etc.
- `recordConstRefParam(func_name, param_idx)` — inserts into the nested const_ref_params map
- `isConstRefParam(func_name, param_idx) bool` — public accessor for codegen (Plan 02)

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add const_vars tracking and const_ref_params map to MirAnnotator | b50fbf9 | src/mir.zig |
| 2 | Expose const_ref_params to CodeGen | b50fbf9 | src/mir.zig |

## Deviations from Plan

None — plan executed exactly as written.

The implementation followed the TDD approach: failing tests were written first, then the implementation made them pass. Tasks 1 and 2 were committed together as the `isConstRefParam` accessor (Task 2) was a natural part of implementing the Task 1 data structures.

## Known Stubs

None — all data structures are fully wired. Plan 02 will connect `const_ref_params` to `generateFuncMir` in codegen to emit `*const T` for promoted parameters.

## Pitfall Handling

- **Pitfall 1** (Zig rejects `&val` where `T` expected): Addressed by recording `const_ref_params` so codegen can change the Zig function signature to `*const T`. Pitfall 2 (var callers of promoted functions) is Plan 02 territory.
- **Pitfall 3** (double-borrow on forwarded params): `promoted_params` is populated at function entry from `const_ref_params` — if `x` is a `*const T` param, it won't get another `&` applied when forwarded.
- **Pitfall 4** (copy() bypass): Already safe — `copy()` calls `generateExprMir` directly, ignoring coercion annotations. Verified as documented in RESEARCH.md.

## Self-Check: PASSED

Files confirmed:
- `src/mir.zig` — exists and contains all new fields
- Commit `b50fbf9` — verified in git log

Grep counts:
- `const_vars`: 12 occurrences (>= 5 required)
- `const_ref_params`: 14 occurrences (>= 5 required)
- `promoted_params`: 7 occurrences (>= 3 required)
- `isConstRefParam`: 5 occurrences
- `zig build test`: exits 0 — all 865+ tests pass
- `zig build`: exits 0 — clean build
