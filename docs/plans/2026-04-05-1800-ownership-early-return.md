# Plan: Ownership checker — recognize early returns in branches

**Date:** 2026-04-05
**Status:** done
**Scope:** Stop false "use of moved value" errors when a branch that moves a variable also exits the function

## Context

The ownership checker (pass 6) uses a snapshot/restore/merge strategy for `if` branches.
After processing both branches, `mergeMovedStates` marks a variable as moved if it was
moved in *either* branch. This is correct when both branches fall through — but when a
branch contains a `return`, `break`, or `continue`, execution never reaches the code after
the `if`. Moves inside an early-exit branch should not pollute the post-`if` scope.

This pattern is common in error propagation: `if(result is Error) { return result }` followed
by `result.i32`. The checker currently flags this as use-after-move.

## Approach

Add a `blockHasEarlyExit` check (reusing the pattern already in `propagation.zig` lines
402-424). When merging branch states after an `if`:

- If the **then-block** has an early exit, discard its moved states entirely (use else/fallthrough state only).
- If the **else-block** has an early exit, discard its moved states entirely (use then state only).
- If **both** have early exits, all moves are discarded (no code after the `if` is reachable — though other passes may catch unreachable code).
- If **neither** has an early exit, keep the current conservative merge (moved in either = moved).

Apply the same logic to `match_stmt` arms: arms with early exits should be excluded from
the conservative merge.

## Steps

### 1. Add `blockHasEarlyExit` helper to `ownership_checks.zig`

- **Files:** `src/ownership_checks.zig`
- **What:** Add a private `blockHasEarlyExit(node: *parser.Node) bool` function. Reuse the
  same logic as `propagation.zig` lines 402-424 (`nodeIsEarlyExit` + `blockHasEarlyExit`).
  This handles `return_stmt`, `break_stmt`, `continue_stmt`, nested blocks, and
  `if_stmt` where both branches exit.
- **Why:** The ownership checker needs to know whether a branch exits early to decide
  whether its moves should propagate to the post-branch scope.

### 2. Update `if_stmt` handler to skip early-exit branch moves

- **Files:** `src/ownership_checks.zig`, function `checkStatement`, lines 73-92
- **What:** After checking `then_block` and `else_block`, call `blockHasEarlyExit` on each.
  Adjust the merge logic:
  ```
  const then_exits = blockHasEarlyExit(i.then_block);
  const else_exits = if (i.else_block) |e| blockHasEarlyExit(e) else false;
  ```
  - If `then_exits` and `else_exits`: restore pre-branch snapshot (no reachable code, but safe).
  - If `then_exits` only: keep post-else state as-is; do NOT merge `after_then` moves.
  - If `else_exits` only: restore to `after_then` state; discard post-else moves.
  - If neither exits: use existing `mergeMovedStates` (conservative merge, unchanged behavior).
- **Why:** This is the core fix. The current code unconditionally merges moved states from
  both branches, which produces false positives when one branch returns.

Current code (lines 73-92):
```zig
.if_stmt => |i| {
    try checkExpr(self, i.condition, scope, true);
    const snapshot = try self.snapshotScope(scope);
    defer self.allocator.free(snapshot);
    try self.checkNode(i.then_block, scope);
    const after_then = try self.snapshotScope(scope);
    defer self.allocator.free(after_then);
    self.restoreScope(scope, snapshot);
    if (i.else_block) |e| try self.checkNode(e, scope);
    self.mergeMovedStates(scope, after_then);
},
```

New code (pseudocode):
```zig
.if_stmt => |i| {
    try checkExpr(self, i.condition, scope, true);
    const snapshot = try self.snapshotScope(scope);
    defer self.allocator.free(snapshot);

    try self.checkNode(i.then_block, scope);
    const after_then = try self.snapshotScope(scope);
    defer self.allocator.free(after_then);
    const then_exits = blockHasEarlyExit(i.then_block);

    self.restoreScope(scope, snapshot);

    if (i.else_block) |e| try self.checkNode(e, scope);
    const else_exits = if (i.else_block) |e| blockHasEarlyExit(e) else false;

    // Merge based on early-exit analysis
    if (then_exits and else_exits) {
        // Both branches exit — restore pre-branch state (unreachable code after if)
        self.restoreScope(scope, snapshot);
    } else if (then_exits) {
        // Then-branch exits — only else-branch state matters (already in scope)
        // Do NOT merge after_then moves
    } else if (else_exits) {
        // Else-branch exits — only then-branch state matters
        self.restoreScope(scope, after_then);
    } else {
        // Neither exits — conservative merge (existing behavior)
        self.mergeMovedStates(scope, after_then);
    }
},
```

### 3. Update `match_stmt` handler to skip early-exit arm moves

- **Files:** `src/ownership_checks.zig`, function `checkStatement`, lines 112-139
- **What:** When collecting arm snapshots for merge, tag each with whether the arm
  has an early exit. During the final merge loop, skip snapshots from early-exit arms.
  If ALL arms exit early, restore pre-match snapshot.
- **Why:** Same logic applies: `match(x) { Error => return x, i32 => ... }` should not
  consider the Error arm's move of `x` when analyzing code after the match.

### 4. Add unit tests

- **Files:** `src/ownership.zig` (test blocks at the bottom)
- **What:** Add these test cases:
  1. **`if` with return in then-block** — variable moved in then, used after if. Should NOT error.
     Build AST: `if(flag) { return data }` then use `data` — verify no error.
  2. **`if/else` with return in else-block** — variable moved in else, used after if. Should NOT error.
  3. **`if/else` both return** — variable moved in both, code after if is unreachable. Should NOT error for post-if usage (unreachable).
  4. **`if` without return (regression)** — existing conservative behavior preserved. Variable moved in then, no return — should still be marked moved after if.
  5. **Nested `if` with return** — `if(a) { if(b) { return x } }` — inner return only exits inner if, outer then-block does NOT unconditionally exit. Variable should be conservatively moved.
  6. **`if/else` where both nested ifs return** — `if(a) { return x } else { return x }` — both exit, moves discarded.

### 5. Add integration test fixture

- **Files:** `test/fixtures/` — new `.orh` file for this pattern
- **What:** Add a test fixture that exercises the `if(result is Error) { return result }` / `result.i32` pattern. Verify it compiles without false positives. This will be caught by `test/11_errors.sh` or `test/09_language.sh` depending on whether it's a positive or negative test.
- **Why:** End-to-end validation that the fix works through the full pipeline.

### 6. Run full test suite

- **What:** Run `./testall.sh` and verify all 313+ tests pass with no regressions.

## Risks & Edge Cases

### Nested ifs with partial early exits
`if(a) { if(b) { return x } }` — the inner `return` only makes the inner if's then-block
an early exit. The outer then-block does NOT unconditionally exit (only when `b` is true).
`blockHasEarlyExit` from propagation.zig handles this correctly: it checks if the block
itself contains a top-level early exit statement, and for nested `if_stmt` it requires BOTH
branches to exit. So outer then-block = no early exit = conservative merge. Correct.

### `break` and `continue` in loops
`break` inside a loop's `if` branch exits the loop iteration, not the function. The
ownership checker should treat `break`/`continue` as early exits for the purpose of
branch merge — the code after the `if` within the loop body is not reached on that
iteration. This matches the existing `blockHasEarlyExit` behavior.

### `elif` chains
`elif` is syntactically nested `if_stmt` in the else branch. The recursive nature of
the fix handles this automatically: each level's else-block is another `if_stmt` that
gets the same early-exit analysis.

### Match with wildcard/default arm
If the default arm has an early exit but named arms don't, only the default arm's moves
are excluded. The named arms' moves are still merged conservatively. Correct.

### Snapshot only captures current scope level
`snapshotScope` only captures `scope.base.vars` (the current scope frame), not parent
scopes. Since `setState` walks the parent chain via `lookupPtr`, moves in a branch can
affect parent scope variables. The snapshot/restore already handles this correctly because
`restoreScope` also calls `setState` which walks parents. No change needed here.

**Correction on snapshot scope:** Looking more carefully, `snapshotScope` iterates
`scope.base.vars` which is only the current frame's hashmap. If a variable is defined
in a parent scope and moved in a branch, the snapshot won't capture it. However, the
existing code has this same limitation — and it hasn't been a problem because the `if_stmt`
handler processes the branches using the same `scope` pointer (which has parent chain
access). The snapshot only needs to capture variables that could be modified, which are
the ones visible in the current scope level. Variables in parent scopes are modified
in-place through `lookupPtr` parent chain walking, and the snapshot/restore handles the
current level. **This is an existing design constraint, not introduced by this change.**
If it becomes a problem, it's a separate issue.

## Out of Scope

- **Non-lexical lifetimes (NLL) for ownership** — the borrow checker already has NLL
  (borrows end at last use). The ownership checker could benefit from similar analysis
  but that's a larger refactor.
- **Unreachable code detection** — if both branches return, code after the `if` is
  unreachable. Detecting and warning about this is a separate feature.
- **Loop-aware ownership** — `while` loops with `break` that moves a value need similar
  analysis. Current behavior is already conservative (moved in loop body = moved after loop).
  A separate issue.

## Open Questions

1. **Should `blockHasEarlyExit` be extracted to a shared utility?** It's now duplicated in
   `propagation.zig`, `mir/mir_lowerer.zig`, and will be in `ownership_checks.zig`. Consider
   moving it to a shared location (e.g., `parser.zig` or a new `ast_utils.zig`). This can
   be done as a follow-up cleanup.
