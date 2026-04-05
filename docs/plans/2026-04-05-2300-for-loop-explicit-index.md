# Plan: Migrate For-Loop to Zig-Style Explicit Index with `0..`

**Date:** 2026-04-05
**Status:** complete
**Scope:** Replace implicit last-capture index convention with explicit `0..` iterable in for-loop header; remove `is_tuple_capture` and `index_var` fields; simplify capture grammar to flat comma-separated identifiers.

## Context

Orhon's for-loop index capture is currently an implicit convention: the last capture in `|val, i|` is the index. This creates ambiguity with tuple captures (`|a, b|` could be "value + index" or "2-field destructure"). The research report at `docs/research/2026-04-05-2130-paren-free-tuple-captures.md` (Open Question 3) identifies Zig-style explicit `0..` as the cleanest long-term path.

By adopting Zig's multi-object for syntax (`for(arr, 0..) |val, i|`), every capture maps positionally to an iterable in the header. Struct destructuring remains parenthesized (`|(k, v)|`) for parse-time disambiguation -- this plan does NOT remove parens from tuple captures. The only change is: index capture moves from implicit convention to explicit `0..` in the header.

## Approach

Change the grammar to accept multiple comma-separated expressions in the for-header. Each capture maps 1:1 to an iterable (except tuple captures, which expand one iterable to multiple captures). Remove `index_var` from the AST -- the index is just another capture whose corresponding iterable is a `0..` range. Remove implicit index detection from the builder. Codegen emits Zig's native multi-object for syntax directly.

The `is_tuple_capture` field stays for now -- it still provides parse-time disambiguation for struct destructuring. Removing it is a separate future effort (the paren-free TODO).

## Steps

### 1. Update the PEG grammar
- **Files:** `src/peg/orhon.peg`
- **What:** Change `for_stmt` to accept multiple comma-separated expressions in the header:
  ```
  for_stmt
      <- 'for' '(' expr (',' expr)* ')' '|' for_captures '|' block
  ```
  The `for_captures` rule stays the same (it already handles both tuple and simple forms). The key change is that the header now accepts N expressions, not just one.
- **Why:** Enables `for(arr, 0..) |val, i|` syntax where `0..` is just another expression in the header.
- **Difficulty:** easy
- **Isolated:** yes

### 2. Update the AST `ForStmt` struct
- **Files:** `src/parser.zig`
- **What:** Change `ForStmt` to:
  - Replace `iterable: *Node` with `iterables: []*Node` (array of expression nodes)
  - Remove `index_var: ?[]const u8` field entirely
  - Keep `captures`, `body`, `is_compt`, `is_tuple_capture` unchanged
- **Why:** Multiple iterables map positionally to captures. Index is no longer a special field -- it is a regular capture whose corresponding iterable is a `0..` range.
- **Difficulty:** easy
- **Isolated:** yes

### 3. Update the PEG builder
- **Files:** `src/peg/builder_stmts.zig`
- **What:** In `buildFor()`:
  - Collect ALL `expr` children from the capture (not just the first) into the `iterables` array
  - For the simple (non-tuple) capture path: collect ALL identifiers as captures, no longer pop the last one as `index_var`
  - For the tuple capture path: collect tuple identifiers as captures, and any identifiers after `)` also go into captures (not into `index_var`)
  - Remove `index_var` from the node construction
  - Set `iterables` instead of `iterable`
- **Why:** The builder must emit the new AST shape. The implicit "last capture = index" logic is removed entirely.
- **Difficulty:** medium
- **Isolated:** no (depends on step 2)

### 4. Update the resolver
- **Files:** `src/resolver.zig`
- **What:**
  - Change `.for_stmt` handler to iterate over `f.iterables` instead of single `f.iterable`
  - Resolve each iterable expression's type
  - For non-tuple captures: each capture maps 1:1 to an iterable. Infer each capture's type from its corresponding iterable (`inferCaptureType` for slices/arrays, `usize` for ranges)
  - For tuple captures: the first iterable provides the struct element type for tuple field captures; additional iterables map to remaining captures after the tuple fields
  - Validate that total capture count matches: for non-tuple, `captures.len == iterables.len`; for tuple, `captures.len == struct_field_count + (iterables.len - 1)`
  - Remove the `if (f.index_var)` line that defines the index as usize -- it is now a regular capture
  - Add error: "capture count does not match iterable count" when they disagree
- **Why:** The resolver must validate the new positional mapping and assign correct types to each capture.
- **Difficulty:** medium
- **Isolated:** no (depends on steps 2-3)

### 5. Update the MIR lowerer and MirNode
- **Files:** `src/mir/mir_lowerer.zig`, `src/mir/mir_node.zig`
- **What:**
  - In `mir_node.zig`: remove `index_var` field from MirNode. The `iterable()` helper becomes `iterables()` or children stores multiple iterable children followed by the body as the last child.
  - In `mir_lowerer.zig`: in the `.for_stmt` arm, lower all iterables (not just one) into children. Remove `m.index_var = f.index_var` line.
  - Keep `is_tuple_capture` and `captures` fields as-is.
  - Convention: children = [iterable_0, iterable_1, ..., iterable_N, body]. The body is always the last child.
- **Why:** MIR must carry the multi-iterable structure for codegen.
- **Difficulty:** medium
- **Isolated:** no (depends on steps 2-4)

### 6. Update the MIR annotator
- **Files:** `src/mir/mir_annotator_nodes.zig`
- **What:** In the `.for_stmt` arm, annotate all iterable children (not just `fs.iterable`). Since iterables are now `children[0..N]` and body is `children[N]`, iterate accordingly.
- **Why:** All iterables need type annotation for codegen.
- **Difficulty:** easy
- **Isolated:** no (depends on step 5)

### 7. Update codegen
- **Files:** `src/codegen/codegen_exprs.zig`
- **What:**
  - In `generateForMir()`: emit Zig's multi-object for syntax directly.
  - For non-tuple: `for (iter0, iter1, ...) |cap0, cap1, ...|`
  - For tuple: `for (iter0, iter1, ...) |_orhon_entry, cap_extra, ...| { const k = _orhon_entry.field; ... }`
  - Remove all `if (idx_var != null) try cg.emit(", 0..")` logic -- the `0..` is now an actual iterable child in the MIR tree, emitted by `generateExprMir`
  - Remove `idx_var` references entirely
  - The range `intCast` logic for index variables should still apply: if an iterable is a range expression, its corresponding capture gets the `_orhon_` prefix + `@intCast` wrapper (same as current range iteration)
  - Remove `resolveStructFieldNames` usage only if the tuple capture logic changes; otherwise keep it for struct destructuring
- **Why:** Codegen now maps 1:1 to Zig's native multi-object for, which is cleaner and more correct.
- **Difficulty:** hard
- **Isolated:** no (depends on steps 5-6)

### 8. Update ownership checker
- **Files:** `src/ownership_checks.zig`
- **What:**
  - In `.for_stmt` arm: iterate over all iterables for `checkExpr` (not just one)
  - Remove `if (f.index_var)` line
  - For non-tuple: infer primitiveness per-capture from corresponding iterable
  - For tuple: keep current logic (tuple captures are always primitive)
- **Why:** Ownership must check all iterables and define all captures correctly.
- **Difficulty:** easy
- **Isolated:** no (depends on step 2)

### 9. Update borrow checker and propagation checker
- **Files:** `src/borrow.zig`, `src/borrow_checks.zig`, `src/propagation.zig`
- **What:**
  - `borrow.zig` (line 275-277): change `f.iterable` to iterate over `f.iterables`
  - `borrow_checks.zig` (line 49-51): change `f.iterable` to iterate over `f.iterables`
  - `propagation.zig` (line 236-238): no iterable access, only checks body -- likely no change needed, but verify field access compiles
- **Why:** These checkers walk the AST and must access the new field name.
- **Difficulty:** easy
- **Isolated:** no (depends on step 2)

### 10. Update LSP analysis
- **Files:** `src/lsp/lsp_analysis.zig`
- **What:** Line 480 accesses `fs.body` which is unchanged. Verify it compiles with the new struct shape. No functional change expected.
- **Why:** Compilation check -- the field access patterns may need updating if `for_stmt` payload shape changes.
- **Difficulty:** easy
- **Isolated:** no (depends on step 2)

### 11. Update codegen decls (collectAssignedMir)
- **Files:** `src/codegen/codegen_decls.zig`
- **What:** Line 157 calls `collectAssignedMir(m.body(), ...)`. Verify `m.body()` still works with the new children layout (body is now the last child instead of always children[1]).
- **Why:** The `body()` helper in MirNode may need updating per step 5.
- **Difficulty:** easy
- **Isolated:** no (depends on step 5)

### 12. Update all `.orh` files -- index capture syntax
- **Files:**
  - `src/templates/example/control_flow.orh` (line 134)
  - `test/fixtures/tester.orh` (line 297)
- **What:**
  - `for(arr) |val, i|` becomes `for(arr, 0..) |val, i|`
  - These are the only two locations with simple `|val, i|` index captures
- **Why:** The old implicit index syntax no longer works.
- **Difficulty:** easy
- **Isolated:** no (depends on steps 1-7 being done so the new syntax works)

### 13. Update all `.orh` files -- tuple capture with index syntax
- **Files:**
  - `test/fixtures/tester.orh` (line 1661)
- **What:**
  - `for(pairs) |(x, y), i|` becomes `for(pairs, 0..) |(x, y), i|`
  - This is the only location with tuple + index
- **Why:** Index must be explicit in the header.
- **Difficulty:** easy
- **Isolated:** no (depends on steps 1-7)

### 14. Update the spec
- **Files:** `docs/07-control-flow.md`
- **What:** Update the for-loop section to show the new syntax:
  ```
  for(my_array) |value| { }                    // value only
  for(my_array, 0..) |value, index| { }        // value and explicit index
  for(0..10) |i| { }                           // range
  for(entries) |(key, value)| { }              // tuple capture
  for(entries, 0..) |(key, value), index| { }  // tuple capture with index
  ```
  Remove the old `for(my_array) |value, index| { }` form (implicit index).
- **Why:** Spec must match the implementation.
- **Difficulty:** easy
- **Isolated:** yes

### 15. Update TODO.md
- **Files:** `docs/TODO.md`
- **What:**
  - Update the "Remove parens from tuple capture syntax" item: note that the index ambiguity is now resolved (index requires explicit `0..`), but parens still provide parse-time disambiguation for struct destructuring vs multi-iterable captures. The item's scope narrows to just removing parens, which is now simpler since `|a, b|` on a single-iterable for is always a destructure.
  - Update the "Mixed numeric type checking and for-loop index type" item: note that index type is determined by the `0..` range iterable (currently `usize`, cast to `i32` in codegen).
- **Why:** Keep TODO accurate.
- **Difficulty:** easy
- **Isolated:** yes

### 16. Update the research report
- **Files:** `docs/research/2026-04-05-2130-paren-free-tuple-captures.md`
- **What:** Add a note at the top that Open Question 3 was adopted -- the `0..` explicit index syntax was implemented. The remaining paren question is now simpler because `|a, b|` on a single-iterable for would always be destructuring (no index ambiguity).
- **Why:** Keep research docs current.
- **Difficulty:** easy
- **Isolated:** yes

### 17. Run tests
- **Command:** `./testall.sh`
- **Expected:** All tests pass. The for-loop tests in `tester.orh` should produce the same runtime results with the new syntax.

## Risks & Edge Cases

- **`compt for` interaction:** `ForStmt.is_compt` exists but is always false (builder hardcodes it). The multi-iterable change must not break this field. When `compt for` is eventually implemented, it will use the same multi-iterable structure.
- **MirNode `body()` helper:** Currently returns `children[1]` for for_stmt. With multiple iterables, body moves to `children[N]` (last child). The helper must be updated, and all callers verified. This is the highest-risk mechanical change.
- **MirNode `iterable()` helper:** Currently returns `children[0]`. Needs to become a different access pattern (e.g., `iterables()` returning `children[0..children.len-1]`, or individual indexed access). All callers must be updated.
- **Range detection in codegen:** Current codegen checks `iter_m.kind == .binary and op == .range` to decide on `intCast` wrapping. With multiple iterables, this check must apply per-iterable, not globally.
- **Single-iterable backward compatibility:** `for(arr) |val|` must still work identically -- single iterable, single capture, no index.
- **Error messages:** The resolver should produce clear errors when capture count mismatches iterable count, e.g., "for loop has 2 iterables but 3 captures".

## Out of Scope

- Removing parentheses from tuple captures (`|(k, v)|` to `|k, v|`) -- that is a separate TODO item, now simpler thanks to this change but not part of this plan.
- Changing the index type from `usize` (cast to `i32`) -- that is the "Mixed numeric type checking" TODO item.
- `compt for` implementation -- separate TODO item.
- Multi-iterable for with non-index second iterables (e.g., `for(arr1, arr2) |a, b|` for parallel iteration) -- this naturally falls out of the implementation since Zig supports it, but no tests or docs are needed for it yet.

## Open Questions

None — all resolved:
- **Multi-iterable:** full Zig-style. `for(arr1, arr2) |a, b|` supported and specced.
- **Mismatch:** iterable count must match capture count (with struct destructure expanding). Mismatch is a compile error.
