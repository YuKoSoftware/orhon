# Phase 23: Pattern Guards - Research

**Researched:** 2026-03-27
**Domain:** Orhon compiler — PEG grammar, AST, resolver, MIR, codegen for match pattern guards
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- Match test goes inside `()` followed by `=>` and then a block `{}`
- `else` does NOT need parentheses — stays bare
- Single literals (`42`, `"hello"`) and single identifiers (`North`, `Error`, `i32`) can omit parentheses
- Ranges MUST use parentheses: `(1..10) => { ... }`
- Bindings with guards MUST use parentheses: `(x if x > 0) => { ... }`
- Any compound pattern requires parentheses
- Guard syntax: `(binding if guard_expr)` — `if` keyword separates binding from guard expression
- Guard expression can reference the bound variable and variables from the enclosing scope
- Guards are optional — arm can be bare value, parenthesized pattern, or pattern with guard
- Guarded and unguarded arms can coexist freely in the same match block
- All match types (value, range, string, type, enum) can be mixed with guarded arms
- When guards are present, the compiler should require an `else` arm (guards don't guarantee coverage)
- Existing bare range patterns (`1..3 =>`) become `(1..3) =>` — 4 lines across 2 files

### Claude's Discretion

- Internal AST representation for guard nodes
- PEG grammar rule structure for parenthesized patterns
- MIR annotation approach for guard expressions
- Codegen strategy (likely desugar to nested if inside switch arm)

### Deferred Ideas (OUT OF SCOPE)

None — phase scope is well-defined.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| GUARD-01 | Match arms accept `case x if expr` guard syntax — arm only matches when guard is true | Grammar change to `match_pattern`, new `match_arm_guard` AST node, codegen desugars to nested if |
| GUARD-02 | Guard expression can reference the bound variable and outer scope | Resolver must walk guard_expr in same scope as arm body; bound variable injected into scope |
| GUARD-03 | Example module and docs updated with pattern guard usage | `control_flow.orh` gets a guarded match example; `docs/07-control-flow.md` updated |
</phase_requirements>

---

## Summary

Phase 23 adds pattern guard syntax to Orhon's `match` statement. The change touches five layers in a predictable order: PEG grammar, AST builder, type resolver, MIR lowerer, and codegen. The grammar change is small and additive — a new `parenthesized_pattern` rule wraps ranges and guard-bearing bindings in `()`. Bare single-token patterns stay unchanged. The `else` arm is always bare.

The guard expression is desugared at codegen time. A guarded switch arm `(x if x > 0) => { body }` emits as a Zig `inline` arm that immediately checks the condition before executing the body. For a regular `switch`, this means emitting a nested `if` inside the arm. For string-match (if/else chain) and type-match strategies, the condition folds naturally into the existing `if` condition using `and`.

The migration concern is small: four lines in two `.orh` files (`test/fixtures/tester.orh` and `src/templates/example/control_flow.orh`) must change bare range patterns to parenthesized ones.

**Primary recommendation:** Extend `MatchArm` with an optional `guard` field (`?*Node`). Keep the pattern node unchanged — the parenthesized form is syntactic sugar that the PEG grammar unwraps. Pass the guard to MIR as a third child of `match_arm`, and dereference it in codegen to emit a conditional.

---

## Standard Stack

This phase requires no new libraries. All implementation is within the existing Zig 0.15.2 compiler codebase.

| File | Role in this phase |
|------|-------------------|
| `src/orhon.peg` | Grammar: add `parenthesized_pattern` rule, update `match_pattern` |
| `src/peg/builder.zig` | AST builder: update `buildMatchArm` to extract guard node |
| `src/parser.zig` | AST types: add `guard: ?*Node` field to `MatchArm` |
| `src/resolver.zig` | Type checking: resolve guard expression, enforce `else` when guards present |
| `src/mir.zig` | MIR lowerer: pass guard as third child of `match_arm` MIR node |
| `src/codegen.zig` | Code generation: desugar guard into nested if inside arm |
| `src/templates/example/control_flow.orh` | Example module: add guarded match demo |
| `test/fixtures/tester.orh` | Runtime test: add guarded match tests |
| `docs/07-control-flow.md` | Docs: update pattern matching section |

**Installation:** No new packages.

---

## Architecture Patterns

### Recommended Project Structure

No structural changes. All changes are in-place edits to existing files.

### Pattern 1: Grammar — parenthesized_pattern rule

**What:** A new `parenthesized_pattern` rule wraps compound match patterns in `()`. A separate `guarded_pattern` rule handles `(IDENTIFIER if expr)`. The `match_pattern` rule is updated to try these before falling back to plain `expr`.

**PEG grammar changes (src/orhon.peg):**

```peg
match_pattern
    <- 'else'
     / parenthesized_pattern               # (range) or (binding if guard)
     / expr                                # bare: literal, identifier

parenthesized_pattern
    <- '(' _ IDENTIFIER _ 'if' _ expr _ ')'   # guarded binding: (x if x > 0)
     / '(' _ expr _ ')'                        # parenthesized range or value: (1..10)
```

**Key insight:** The `'if'` inside `()` is unambiguous in match context. An `IDENTIFIER` followed by `if` is unambiguously a guarded binding. A plain `( expr )` could be a range or a grouped value — both are legitimate. The parser builds these as distinct capture nodes.

**The `if` keyword is already in `token_map.zig` as `.kw_if`** — no new token needed. The PEG grammar uses `'if'` and the engine resolves it via `LITERAL_MAP`.

### Pattern 2: AST — extend MatchArm with guard field

**What:** `MatchArm` gains an optional `guard` field. The pattern field stays the same (binding identifier or expression); the guard is extracted separately.

**Change to `src/parser.zig`:**

```zig
pub const MatchArm = struct {
    pattern: *Node,
    guard: ?*Node,    // null if no guard expression
    body: *Node,
};
```

**Why:** Keeping guard separate from pattern makes every downstream consumer simple. The resolver resolves it, MIR annotates it, codegen emits it — each in one place.

### Pattern 3: Builder — buildMatchArm reads guard from capture

**What:** `buildMatchArm` in `src/peg/builder.zig` checks whether the match_pattern capture contains a `guarded_pattern` child. If so, it extracts the binding identifier as `pattern` and the inner `expr` as `guard`.

**Current code:**
```zig
fn buildMatchArm(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const pattern = if (cap.findChild("match_pattern")) |mp| try buildNode(ctx, mp) else return error.NoPattern;
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .body = body } });
}
```

**Updated logic (conceptual):**
```zig
fn buildMatchArm(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const mp_cap = cap.findChild("match_pattern") orelse return error.NoPattern;
    var guard: ?*Node = null;
    var pattern: *Node = undefined;

    if (mp_cap.findChild("guarded_pattern")) |gp| {
        // (identifier if expr)
        pattern = ...build identifier from gp...;
        guard = ...build expr from gp...;
    } else {
        pattern = try buildNode(ctx, mp_cap);
    }

    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;
    return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } });
}
```

**Note:** The `parenthesized_pattern` case for plain `(expr)` (ranges) does NOT produce a guard. Its inner expr is built normally as the pattern — a `range_expr` node, same as before.

### Pattern 4: Resolver — resolve guard in arm scope, enforce else

**What:** In `resolver.zig`'s `match_stmt` handler, after resolving each arm's pattern, if `arm.match_arm.guard` is non-null, resolve the guard expression in the same scope as the arm body. The resolver also enforces the `else` requirement: if any arm has a guard, `has_else` must be true.

**Scope access for bound variable:** The bound variable in a guarded pattern is the pattern identifier itself (e.g., `x` in `(x if x > 0)`). In the current design, `x` is bound to the matched value — the same value being matched. To make `x` available in the guard expression, the resolver should inject `x` into a child scope for that arm. The resolved type of `x` is the match value's type.

**Exhaustiveness rule:** When `has_guard` is true for any arm, the resolver must check `has_else` and report an error if it is false: `"match with guards requires an 'else' arm"`.

### Pattern 5: MIR — guard as third child of match_arm MirNode

**What:** The MIR lowerer for `match_arm` currently produces two children: `[pattern, body]`. With guards, it produces three: `[pattern, guard_or_nil, body]`.

**Current MIR child layout:**
```
match_arm children[0] = pattern
match_arm children[1] = body  (= last child, body() accessor works)
```

**Problem:** The existing `body()` accessor returns `self.children[self.children.len - 1]`. If we add a guard as `children[1]` with body at `children[2]`, the `body()` accessor still works correctly. The `pattern()` accessor returns `children[0]`, also correct.

**New accessor needed:**
```zig
/// children[1] — guard expression for match_arm, null-sentinel MirNode if no guard.
pub fn guard(self: *const MirNode) ?*MirNode { ... }
```

**Alternative (simpler):** Store guard as a field on `MirNode` rather than a child. The current `MirNode` structure should be checked — if it has a `name` or `extra` slot available for this purpose, that avoids changing child indexing. Inspect `mir.zig` MirNode struct to decide.

**Recommendation:** Check if `MirNode` has an unused nullable field (e.g., `extra_node: ?*MirNode`). If not, add guard as `children[1]` with body at `children[2]` and update the `body()` accessor for `match_arm` specifically.

### Pattern 6: Codegen — desugar guard to nested if

**What:** In `generateMatchMir`, each arm that has a guard emits the arm body wrapped in an `if` check. The strategy differs by match type:

**Regular switch (value match):**
```zig
// Input: (x if x > 0) => { return x }
// Output Zig:
pattern => {
    const x = pattern_value;
    if (x > 0) {
        return x;
    }
},
```

But in practice, Zig's `switch` captures are handled differently. The actual output for a guarded integer match should use an `else` wildcard that performs the conditional, to avoid Zig "unreachable pattern" errors from the switch. The correct Zig pattern is:

```zig
// For: match(n) { (x if x > 0) => { return x } else => { return 0 } }
switch (n) {
    else => |x| {
        if (x > 0) { return x; }
        // fall through to else arm
    },
    // ...
}
```

Actually the cleanest approach is: a guarded arm forces the entire `match` to generate as an if/else chain (similar to the string-match strategy), not a Zig `switch`. This avoids all Zig switch-capture complexity.

**Recommended codegen strategy for guarded arms:** If any arm has a guard, `generateMatchMir` switches from `switch` output to a sequential `if/else if/else` chain. Each arm becomes:

```zig
if (_match_val == pattern && guard_expr) { body }
else if (_match_val == pattern2) { body2 }
else { else_body }
```

For range patterns with a guard (unusual but possible per spec):

```zig
if (_match_val >= low && _match_val <= high && guard_expr) { body }
```

**For string match:** Already uses if/else chain — guard folds in naturally with `and`.

**For type match (union/null):** Type match uses `if (...) |x|` Zig patterns. A guard on a binding like `(Circle if Circle.radius > 5)` can check the condition inside the if-unwrap block.

### Anti-Patterns to Avoid

- **Embedding guard inside pattern node:** Putting the guard inside the pattern's AST node (e.g., as a field of `range_expr`) would scatter guard logic across all pattern types. Keep guard at `MatchArm` level.
- **Emitting Zig switch with captured bindings:** Zig's `switch` `|capture|` syntax is only for tagged unions and optionals. For integer/value switches, use if/else chain when guards are present.
- **Resolving guard in wrong scope:** Guard must see the bound variable. If guard is resolved in the outer scope only, it won't find `x`. Always push a child scope for the arm that includes the binding.
- **Forgetting the `else` enforcement:** The resolver must check `has_else` when any arm has a guard. Missing this creates silent non-exhaustive matches at runtime.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Keyword detection in PEG | Custom token scanner | PEG `'if'` literal — resolves via existing `LITERAL_MAP[kw_if]` |
| Guard expression type inference | Custom inference | Call existing `self.resolveExpr(guard, scope)` in resolver |
| Scope injection for bound variable | New scope mechanism | Use existing `scope.define(name, match_value_type)` |

---

## Common Pitfalls

### Pitfall 1: PEG grammar ambiguity — `(x if x > 0)` vs `grouped_expr`

**What goes wrong:** The existing `grouped_expr` rule is `'(' _ expr _ ')'`. A `(x if x > 0)` parses as a grouped expr containing an `if`... but `if` is not a valid expression position token in Orhon's grammar. The PEG engine will fail to match `grouped_expr` for this input, which is correct — but only if `parenthesized_pattern` is tried BEFORE the `expr` fallback in `match_pattern`.

**Why it happens:** PEG ordered choice — the first match wins. `match_pattern` must try `parenthesized_pattern` before `expr`.

**How to avoid:** `match_pattern` rule order must be:
```peg
match_pattern
    <- 'else'
     / parenthesized_pattern
     / expr
```

**Warning signs:** If `(x if x > 0)` produces a parse error instead of a `guarded_pattern`, check the rule ordering.

### Pitfall 2: `kw_if` inside match context triggers if_stmt parser

**What goes wrong:** The PEG grammar for `statement` includes `if_stmt`. If the grammar is ambiguous, the parser could try to parse `(x if x > 0)` as a grouped expression starting a statement.

**Why it happens:** Match arms are parsed inside the `match_stmt` rule using `match_arm*`. Since `match_arm` is a dedicated rule (not `statement`), the `if_stmt` rule is never tried there. The guard `if` is scoped entirely within `parenthesized_pattern`.

**How to avoid:** No action needed — match arms bypass the statement dispatcher entirely.

### Pitfall 3: `MatchArm.guard` breaks existing exhaustiveness checker

**What goes wrong:** The existing exhaustiveness check in `resolver.zig` iterates `m.arms` and checks `arm.match_arm.pattern`. If guard-bearing arms are always considered as non-exhaustive (which they are), the check must also enforce `has_else = true` when any guard is present — not just for union types.

**How to avoid:** Add a `has_guard` flag in the `match_stmt` resolver block. Set it true if any arm has a non-null guard. After iterating arms, if `has_guard && !has_else`, report error.

### Pitfall 4: MirNode child index shift for `match_arm` body accessor

**What goes wrong:** Current `body()` on `MirNode` returns `self.children[self.children.len - 1]`. Adding guard as a child keeps this working (body stays last). But `pattern()` returns `children[0]` — that also stays correct. The risk is any code that uses raw index `children[1]` for body — there is none currently, but adding a guard child at `[1]` shifts body to `[2]`.

**How to avoid:** Keep `body()` and `pattern()` accessors as-is (they use `last` and `first` semantics). Add a `guardNode()` accessor that returns `children[1]` when `children.len == 3`, or returns `null`. Never access `match_arm` children by raw index outside accessor methods.

### Pitfall 5: Range migration — `1..3 =>` becomes `(1..3) =>`

**What goes wrong:** Range patterns without parentheses will fail to parse once the grammar requires them. The test suite will catch this if migration is missed, but it will break `test/10_runtime.sh` and `test/09_language.sh`.

**Files to update:**
- `test/fixtures/tester.orh` — lines 760, 763 (two range arms in `match_range`)
- `src/templates/example/control_flow.orh` — lines 94, 95 (two range arms in `match_range`)

**How to avoid:** Update these four lines in the same wave as the grammar change. Do NOT ship the grammar change without migrating them simultaneously.

### Pitfall 6: Bound variable scope in guard for type-match arms

**What goes wrong:** A type-match arm like `(Circle if Circle.radius > 5)` binds `Circle` as the variant name. In the current type-match codegen, the matched value is accessed via `_match_val.tag == .Circle`. The guard expression `Circle.radius > 5` needs to be emitted as `_match_val.Circle.radius > 5` in the Zig output.

**How to avoid:** In codegen, when emitting the guard expression for a type-match arm, substitute the bound variable name with the appropriate Zig payload access expression. This is the same substitution already done for arm bodies in type-match (`val.Circle.radius` etc.).

---

## Code Examples

### Grammar change (src/orhon.peg)

```peg
# Source: orhon.peg analysis — match_pattern extension

match_pattern
    <- 'else'
     / parenthesized_pattern
     / expr

parenthesized_pattern
    <- '(' _ IDENTIFIER _ 'if' _ expr _ ')'   # guarded binding: (x if x > 0)
     / '(' _ expr _ ')'                        # parenthesized pattern: (1..10)
```

### AST extension (src/parser.zig)

```zig
// Source: parser.zig MatchArm struct — add guard field
pub const MatchArm = struct {
    pattern: *Node,
    guard: ?*Node,    // null if no guard
    body: *Node,
};
```

### Builder update (src/peg/builder.zig)

```zig
// Source: builder.zig buildMatchArm — detect guarded_pattern capture
fn buildMatchArm(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const mp_cap = cap.findChild("match_pattern") orelse return error.NoPattern;
    const body = if (cap.findChild("block")) |b| try buildNode(ctx, b) else return error.NoBlock;

    // Check if match_pattern contains a guarded_pattern child
    if (mp_cap.findChild("guarded_pattern")) |gp| {
        // guarded_pattern: '(' IDENTIFIER 'if' expr ')'
        // children[0] = identifier, children[1] = guard expr (approximately)
        const pattern = try buildIdentifierFromCapture(ctx, gp);
        const guard = try buildGuardExprFromCapture(ctx, gp);
        return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } });
    }

    // Plain pattern (bare or parenthesized range)
    const pattern = try buildNode(ctx, mp_cap);
    return ctx.newNode(.{ .match_arm = .{ .pattern = pattern, .guard = null, .body = body } });
}
```

### Resolver enforcement (src/resolver.zig)

```zig
// Source: resolver.zig match_stmt handler — guard resolution + else enforcement
.match_stmt => |m| {
    const match_type = try self.resolveExpr(m.value, scope);
    var has_else = false;
    var has_guard = false;
    for (m.arms) |arm| {
        if (arm.* == .match_arm) {
            const ma = arm.match_arm;
            const pat = ma.pattern;
            if (pat.* == .identifier and std.mem.eql(u8, pat.identifier, "else")) {
                has_else = true;
            }
            if (pat.* == .identifier and !std.mem.eql(u8, pat.identifier, "else")) {
                try self.validateMatchArm(pat.identifier, match_type, arm);
            }
            _ = try self.resolveExpr(pat, scope);
            // Resolve guard in a child scope that includes the bound variable
            if (ma.guard) |g| {
                has_guard = true;
                var guard_scope = try scope.child();
                defer guard_scope.deinit();
                // Inject bound variable into guard scope
                try guard_scope.define(pat.identifier, match_type);
                _ = try self.resolveExpr(g, &guard_scope);
            }
            try self.resolveNode(ma.body, scope);
        }
    }
    // Guards require else arm
    if (has_guard and !has_else) {
        try self.reporter.report(.{
            .message = "match with guards requires an 'else' arm",
            .loc = self.nodeLoc(node),
        });
    }
    if (!has_else) {
        try self.checkMatchExhaustiveness(match_type, m.arms, node);
    }
},
```

### Codegen desugaring (src/codegen.zig)

```zig
// For guarded arms in value match — emit as if/else chain
// Input: match(n) { (x if x > 0) => { return x } else => { return 0 } }
// Output:
//   const _m = n;
//   if (true) {
//       const x = _m;
//       if (x > 0) { return x; }
//   }
//   { return 0; }  // else arm
```

### Example fixture addition (test/fixtures/tester.orh)

```orh
// ─── Match — guards ──────────────────────────────────────────

pub func match_guard(n: i32) i32 {
    match(n) {
        (x if x > 0)  => { return 1 }
        (x if x < 0)  => { return 0 - 1 }
        else          => { return 0 }
    }
}

test "match_guard" {
    assert(match_guard(5) == 1)
    assert(match_guard(0 - 3) == 0 - 1)
    assert(match_guard(0) == 0)
}
```

---

## Runtime State Inventory

Step 2.5: SKIPPED — this is a greenfield language feature, not a rename/refactor/migration phase. No stored data, live service config, OS-registered state, secrets, or build artifacts reference the strings being changed.

---

## Environment Availability

Step 2.6: SKIPPED — no external dependencies beyond the existing Zig 0.15.2 toolchain, which is already confirmed installed and working from Phase 22.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell integration tests |
| Config file | none — `zig build test` discovers all test blocks |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| GUARD-01 | `(x if x > 0) => { ... }` arm only fires when guard is true | runtime | `./testall.sh` (test/10_runtime.sh: match_guard) | ❌ Wave 0 — add to tester.orh |
| GUARD-02 | Guard references bound variable and outer scope | runtime | `./testall.sh` (test/10_runtime.sh: match_guard_scope) | ❌ Wave 0 — add to tester.orh |
| GUARD-03 | Example module compiles with guard syntax | integration | `./testall.sh` (test/09_language.sh) | ❌ Wave 0 — add to control_flow.orh |

Additionally, the range parentheses migration must not regress existing tests:

| Existing Test | Behavior | Status |
|---------------|----------|--------|
| `match_range` (runtime) | `(1..3) =>` and `(4..6) =>` work | Breaks if migration missed |
| `match_range` (example) | `control_flow.orh` uses parenthesized ranges | Breaks if migration missed |

### Sampling Rate

- **Per task commit:** `zig build test` (unit tests only, fast)
- **Per wave merge:** `./testall.sh` (full 11-stage suite)
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `test/fixtures/tester.orh` — add `match_guard` and `match_guard_scope` test functions and `test` blocks
- [ ] `test/10_runtime.sh` — add `match_guard` and `match_guard_scope` to the expected test list
- [ ] `src/templates/example/control_flow.orh` — add guarded match example function

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Bare range `1..3 =>` | Parenthesized `(1..3) =>` | Phase 23 | 4 lines to migrate |
| No guard expression | `(binding if expr) =>` | Phase 23 | New capability |

---

## Open Questions

1. **Scope definition for bound variable in guard**
   - What we know: The bound variable `x` in `(x if x > 0)` should have the same type as the matched value.
   - What's unclear: The resolver's `Scope` type — does `scope.child()` exist, or is it `Scope.init(allocator, parent_scope)`? Must verify the exact scope API in `resolver.zig` before implementing.
   - Recommendation: Read `src/resolver.zig` Scope struct definition before implementing the guard scope injection.

2. **MirNode guard storage — child vs field**
   - What we know: `MirNode` uses a `children` slice. Adding guard as `children[1]` keeps body at last (accessor safe). Alternatively, MirNode may have a nullable field.
   - What's unclear: Whether `MirNode` has any unused nullable fields suitable for a guard pointer, or whether adding a child is cleaner.
   - Recommendation: Inspect `MirNode` struct fields in `mir.zig` at planning time and choose the simpler option. If no free field exists, use `children[1]` for guard and update `body()` accessor for `match_arm` to use `children[2]`.

3. **Codegen strategy for mixed guarded/unguarded arms**
   - What we know: If any arm has a guard, the match cannot use a pure Zig `switch` (guards don't map to Zig switch semantics directly).
   - What's unclear: Whether to convert the entire match to if/else when any guard is present, or to handle guarded arms specially within a switch using `else => |val| { if (guard) ... }`.
   - Recommendation: Convert entire match to if/else chain when any arm has a guard. This is the cleanest approach and consistent with the string-match strategy already in the codebase. Complexity: lower than mixing switch/if strategies.

---

## Project Constraints (from CLAUDE.md)

All of the following apply to this phase:

- **Zig 0.15.2+** — compiler code targets this version
- **Recursive parser functions must use `anyerror!`** — `buildMatchArm` and any new builder helpers must use `anyerror!*Node`
- **PEG grammar is source of truth** — changes start in `src/orhon.peg`, then `builder.zig`, never the reverse
- **No hacky workarounds** — guard codegen must be clean, not a special-case patch
- **`./testall.sh` is the gate** — all 11 stages must pass before phase is complete
- **Reporter owns message strings** — always `defer allocator.free(msg)` after allocPrint in resolver error reporting
- **Example module must compile** — `control_flow.orh` with guards must be valid Orhon
- **Comments kept up to date** — update builder/resolver/codegen comments when changing those functions
- **`token_map.zig` LITERAL_MAP** — `'if'` is already present as `.kw_if`, no new entry needed for this phase

---

## Sources

### Primary (HIGH confidence)

- Direct inspection of `src/orhon.peg` — current `match_pattern`, `match_arm`, `match_stmt` rules
- Direct inspection of `src/parser.zig` — `MatchArm`, `NodeKind` union
- Direct inspection of `src/peg/builder.zig` — `buildMatchArm`, `buildMatch`, dispatch table
- Direct inspection of `src/resolver.zig` — `match_stmt` handler, `checkMatchExhaustiveness`, `validateMatchArm`
- Direct inspection of `src/mir.zig` — `match_arm` lowering, `pattern()`, `body()`, `matchArms()` accessors
- Direct inspection of `src/codegen.zig` — `generateMatchMir`, `generateStringMatchMir`, `generateTypeMatchMir`
- Direct inspection of `src/peg/token_map.zig` — confirms `kw_if` already in `LITERAL_MAP`
- Direct inspection of `test/fixtures/tester.orh` — existing range pattern lines (760, 763)
- Direct inspection of `src/templates/example/control_flow.orh` — existing range pattern lines (94, 95)
- Direct inspection of `.planning/phases/23-pattern-guards/23-CONTEXT.md` — locked decisions

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies, all changes in well-understood existing files
- Architecture: HIGH — five-layer pipeline (grammar → builder → resolver → MIR → codegen) is established pattern in this codebase; same pattern used for `throw` in Phase 22
- Pitfalls: HIGH — PEG ordering, scope injection, and child index shift are verified against actual source code

**Research date:** 2026-03-27
**Valid until:** Indefinite — this is a static compiler codebase with no external dependencies; findings don't expire
