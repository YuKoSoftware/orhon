# Plan: For-loop tuple captures (struct field destructuring)

**Date:** 2026-04-05
**Status:** complete
**Scope:** Enable `for(slice) |field1, field2| {}` struct element destructuring in for-loops: PEG builder, resolver, MIR, codegen, tests, docs

## Context

The spec (`docs/07-control-flow.md` line 29) defines tuple capture syntax for iterating
over slices of structs: `for(map.entries()) |key, value| {}`. The PEG grammar already has
the correct rule with two alternatives (tuple vs simple), and the AST `ForStmt` has an
`is_tuple_capture` field, but the builder never sets it to true. The resolver assigns the
same type to all captures. Codegen only emits the first capture variable.

## Design Decisions

1. **No magic** — `for` takes a slice expression. The user calls `.entries()`, `.keys()`,
   or accesses `.values` explicitly. The compiler never auto-inserts method calls.

2. **No parens in captures** — the capture list uses `|...|` delimiters, so inner parens
   are redundant: `|key, value|` not `|(key, value)|`.

3. **Slice only** — `for` iterates slices. Where the data lives (stack or heap) is the
   user's business. If `.entries()` returns a view into internal storage (no allocation),
   there's nothing to free.

4. **Strict capture count** — number of captures must match the struct's field count.
   Optionally +1 for the iteration index at the end. Mismatch is a compile error.

5. **Index is always last** — `|key, value, i|` where `i` is the optional index.
   Same pattern as `|val, i|` for simple captures.

## Approach

1. Fix the PEG builder to detect multi-capture form and set `is_tuple_capture = true`.
2. Thread `is_tuple_capture` through MIR.
3. Update the resolver to type-check tuple captures against the slice element's struct fields.
4. Update codegen to emit field destructuring (iterate slice, bind struct fields to capture names).
5. Add tests and update docs/examples.

## Steps

### 1. Add `entries()` method to `Map` in std::collections
- **Files:** `src/std/collections.zig`
- **What:** Add a public `entries()` method to `Map` that returns `[]const Entry` where
  `Entry = struct { key: K, value: V }`. Follow the existing `keys()`/`values()` pattern:
  allocate a buffer, iterate the internal hash map, populate key/value from entry pointers.
  Add `Entry` as a pub const inside the Map struct.
- **Why:** Maps need a way to expose key-value pairs as a slice of structs for tuple capture
  iteration. Without this, there's nothing to destructure.
- **Difficulty:** easy
- **Isolated:** yes

### 2. Fix PEG builder to detect tuple captures
- **Files:** `src/peg/builder_stmts.zig`
- **What:** In `buildFor()`, after getting the `for_captures` child, check its `choice_index`.
  If `choice_index == 0` (the tuple alternative), collect all identifiers into `captures`
  and set `is_tuple_capture = true`. The last identifier after `)` comma (if present) becomes
  `index_var`. If `choice_index == 1` (simple form), keep current behavior.
- **Why:** The grammar already distinguishes the two forms via ordered choice, but the builder
  ignores this distinction.
- **Difficulty:** medium
- **Isolated:** yes

### 3. Thread `is_tuple_capture` through MIR
- **Files:** `src/mir/mir_node.zig`, `src/mir/mir_lowerer.zig`
- **What:** Add `is_tuple_capture: bool = false` field to `MirNode.ForData` (or equivalent).
  In `mir_lowerer.zig` at the `.for_stmt` copy, propagate `f.is_tuple_capture` to the MIR node.
- **Why:** Codegen reads MirNode, not AST directly. Without this, codegen can't know whether
  to emit tuple destructuring.
- **Difficulty:** easy
- **Isolated:** yes

### 4. Update resolver to type-check tuple captures
- **Files:** `src/resolver.zig`
- **What:** In the `.for_stmt` handler, when `is_tuple_capture` is true:
  (a) resolve the iterable expression's element type
  (b) verify it's a struct type
  (c) verify capture count matches the struct's field count (or field count + 1 for index)
  (d) define each capture variable with the corresponding struct field's type
  Report clear errors for: non-struct element type, capture count mismatch.
- **Why:** Currently the resolver assigns the same inferred type to all captures.
- **Difficulty:** medium
- **Isolated:** no (depends on step 2 for `is_tuple_capture` to be set)

### 5. Update codegen to emit struct field destructuring
- **Files:** `src/codegen/codegen_exprs.zig`
- **What:** In `generateForMir()`, add a branch for `is_tuple_capture`. When true:
  - Emit `for (iterable) |_orhon_entry| {` (single Zig capture for the struct)
  - Inside the body preamble, emit `const {capture0} = _orhon_entry.{field0};`
    and `const {capture1} = _orhon_entry.{field1};` etc.
  - If `index_var` is present, add `, 0..` counter and emit the index binding
  - Emit body statements, close with `}`
- **Why:** Zig does not support destructuring struct fields in for-loop captures.
  The generated code must bind fields manually.
- **Difficulty:** medium
- **Isolated:** no (depends on steps 2, 3)

### 6. Update ownership checker for tuple captures
- **Files:** `src/ownership_checks.zig`
- **What:** In the `.for_stmt` handler, when `is_tuple_capture` is true, define all capture
  variables in scope. Struct field copies are values — no ownership transfer from the
  iterable.
- **Why:** Without this, the ownership checker might incorrectly flag tuple capture variables.
- **Difficulty:** easy
- **Isolated:** no (depends on step 2)

### 7. Add test fixture for tuple capture iteration
- **Files:** `test/fixtures/tester/tester.orh`, `test/fixtures/tester/tester_main.orh`
- **What:** Add a test function that creates a slice of structs, iterates with
  `|field1, field2|`, and returns a computed value proving both fields were accessible.
  Also test the `|field1, field2, i|` form with index.
- **Why:** Runtime correctness test for the full pipeline.
- **Difficulty:** easy
- **Isolated:** no (depends on steps 2-5)

### 8. Add negative test for tuple capture errors
- **Files:** `test/11_errors.sh`, `test/fixtures/` (negative fixture)
- **What:** Add tests for:
  - Tuple capture on a non-struct element type (e.g., `[]i32`) — should error
  - Capture count mismatch (3 captures on a 2-field struct) — should error
- **Why:** Users should get helpful errors when misusing tuple captures.
- **Difficulty:** easy
- **Isolated:** no (depends on steps 2, 4)

### 9. Update example module with tuple capture
- **Files:** `src/templates/example/control_flow.orh`
- **What:** Add a short example showing `for(entries) |key, value| {}` with a brief comment.
  Keep it concise — 3-4 lines.
- **Why:** The example module is the living language manual and must cover every implemented feature.
- **Difficulty:** easy
- **Isolated:** no (depends on steps 2-5)

### 10. Update spec and TODO
- **Files:** `docs/07-control-flow.md`, `docs/TODO.md`
- **What:** Update the spec to show `|key, value|` syntax (no parens). Remove or mark done
  the "For-loop tuple captures" TODO item. Remove the "Blocked on std::collections" note
  (std::collections is a separate concern — tuple captures work on any slice of structs).
- **Why:** Keep docs current.
- **Difficulty:** easy
- **Isolated:** no (depends on all previous steps)

### 11. Run tests
- **Command:** `./testall.sh`
- **Expected:** All tests pass, including new tuple capture tests.

## Risks & Edge Cases

- **Generic type resolution:** The resolver may not fully resolve generic struct entry types
  today. If struct field types can't be resolved, captures get `.inferred` and type errors
  are only caught at Zig compilation. Acceptable for now.
- **Nested structs:** If the slice element is a struct containing another struct, the
  captures only destructure the top level. Deep destructuring is out of scope.
- **Single-field structs:** `for(slice_of_wrappers) |inner|` with a 1-field struct should
  work — it's just a tuple capture with 1 field. Same codegen path.

## Out of Scope

- Set iteration — Sets yield single keys, not tuples
- Deep/nested destructuring
- Multi-object for loops (iterating two slices simultaneously)
- While-loop based iteration

## Open Questions

None — all design decisions resolved.
