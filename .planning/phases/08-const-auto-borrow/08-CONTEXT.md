# Phase 8: Const Auto-Borrow - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Change `const` non-primitive values from implicit copy to auto-borrow as `const &` when passed to functions. `copy()` remains available for explicit copies. `var` semantics unchanged.

</domain>

<decisions>
## Implementation Decisions

### Ownership checker changes
- **D-01:** Keep the `is_const` flag on `VarState` but change its meaning: const values are never marked `.moved` (same as before) AND trigger `value_to_const_ref` coercion at call sites
- **D-02:** Line 368 in ownership.zig — the `!state.is_const` skip stays. The ownership checker already doesn't move const values. The real change is in MIR/codegen.
- **D-03:** `copy()` on a const value should still work — it explicitly creates an owned copy, bypassing the auto-borrow

### MIR annotator changes
- **D-04:** In `annotateCallCoercions` (mir.zig), when an argument is a const non-primitive identifier being passed to a by-value parameter, annotate with `value_to_const_ref` coercion
- **D-05:** The MIR annotator needs to know which arguments are `const` — this requires checking the variable's declaration (const_decl vs var_decl) or the ownership checker's `is_const` flag
- **D-06:** This should ONLY apply at function call sites. Assignment (`var b = const_a`) should still be a move/copy as before.

### Codegen changes
- **D-07:** `generateCoercedExprMir` already handles `value_to_const_ref` by emitting `&expr`. No codegen changes expected — the MIR annotation does all the work.
- **D-08:** If a function parameter is already `const &T`, the MIR annotator already adds `value_to_const_ref`. The new behavior extends this to ALL non-primitive const arguments, even when the parameter type is `T` (by-value).

### Edge cases
- **D-09:** Primitives are unaffected — they always copy regardless of const/var
- **D-10:** `String` is a primitive (cheap 16-byte copy) — no auto-borrow needed
- **D-11:** `copy(const_val)` must still produce an owned value, not a borrow

### Claude's Discretion
- How to propagate const-ness from ownership checker to MIR annotator (shared data structure or re-derive from AST)
- Whether to add a unit test for const auto-borrow in MIR or ownership
- Exact implementation of the "is this argument a const identifier" check in MIR

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Ownership
- `src/ownership.zig` lines 14-21 — VarState struct with `is_const` field
- `src/ownership.zig` line 368 — the `!state.is_const` skip in move logic
- `src/ownership.zig` lines 1006-1040 — existing unit tests for const behavior

### MIR coercion
- `src/mir.zig` line 60 — `value_to_const_ref` coercion kind
- `src/mir.zig` line 536 — where value_to_const_ref is currently applied (explicit const & params)
- `src/mir.zig` lines 1717-1720 — unit test for value_to_const_ref

### Codegen
- `src/codegen.zig` lines 2455-2490 — `generateCoercedExprMir` handles value_to_const_ref
- `src/codegen.zig` line 2481 — emits `&` prefix for value_to_const_ref

### Language spec
- `docs/09-memory.md` — already updated with const auto-borrow description and examples

### Design decision
- Memory file: `project_const_auto_borrow.md` — full rationale for the change

</canonical_refs>

<code_context>
## Existing Code Insights

### value_to_const_ref Already Works
The entire pipeline from MIR annotation → codegen emission is implemented and tested. The coercion kind `.value_to_const_ref` exists, `generateCoercedExprMir` handles it by emitting `&`, and unit tests confirm it works for explicit `const &` parameters. The change is extending WHEN this coercion is applied.

### Key Integration Point
The MIR annotator's `annotateCallCoercions` function currently applies `value_to_const_ref` only when the function parameter is declared `const &T` and the argument is a plain value. The change: also apply it when the argument is a `const` identifier passing to any non-primitive parameter.

### What Needs to Flow
The MIR annotator needs to know "is this argument a const variable?" This information exists in the ownership checker's scope but isn't currently passed to MIR. Options: (a) re-derive from AST node type (const_decl), (b) add a const flag to the decl table, (c) look up in the resolver's scope.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — the design decision is clear from the earlier discussion.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 08-const-auto-borrow*
*Context gathered: 2026-03-25*
