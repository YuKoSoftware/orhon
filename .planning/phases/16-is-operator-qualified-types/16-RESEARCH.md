# Phase 16: `is` Operator with Module-Qualified Types - Research

**Researched:** 2026-03-26
**Domain:** PEG grammar extension, AST builder token scanning, Zig codegen branch addition
**Confidence:** HIGH

## Summary

Phase 16 fixes two related bugs with the `is` operator and cross-module types. The grammar currently constrains the RHS of `is` to a single `IDENTIFIER` — extending it to `IDENTIFIER ('.' IDENTIFIER)*` is the minimal change needed to accept `ev is module.Type`. The builder then needs a new code path that scans across multiple identifier+dot tokens and assembles a left-to-right `field_expr` chain. Codegen needs a new branch for when the RHS is a `.field_expr` node rather than a plain `.identifier`.

The second bug (unqualified cross-module `ev is QuitEvent` emitting unqualified Zig) is actually already handled by the general type-check path in codegen (`@TypeOf(val) == QuitEvent`), which passes the raw identifier through. For arbitrary-union typed values, however, the `val == ._QuitEvent` path would be used — and the struct member tag name problem is distinct from the `module.Type` parsing bug. The CONTEXT.md decisions clarify that for qualified types, codegen emits the full dotted path. The planner should treat both bugs as addressed by the single grammar + codegen change.

The change is surgical: three files need edits (`orhon.peg`, `src/peg/builder.zig`, `src/codegen.zig`), no new AST node types are needed (`.field_expr` already exists with its `FieldExpr` struct), and no semantic analysis passes change. All three existing `is` codegen paths (`null`, `Error`, `identifier`) are preserved unchanged.

**Primary recommendation:** Extend the grammar rule with a dot-repeating path, build a left-to-right `field_expr` chain in `buildCompareExpr`, and add a `b.right.* == .field_expr` branch in the codegen `is` handler that emits the dotted path directly.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** The `is` RHS accepts `IDENTIFIER ('.' IDENTIFIER)*` — one or more dot-separated identifiers
- **D-02:** `is null` and `is not null` remain unchanged — `null` is a keyword, not an IDENTIFIER path
- **D-03:** `is not` continues to work with qualified types: `ev is not module.Type`
- **D-04:** For single identifiers (`ev is Foo`), builder produces `.identifier` node as before — no regression
- **D-05:** For dotted paths (`ev is module.Type`), builder produces a `.field_expr` chain — reusing the existing `field_expr` AST node type
- **D-06:** The builder scans tokens after `kw_is` (and optional `kw_not`) collecting `IDENTIFIER.IDENTIFIER...` sequences
- **D-07:** Codegen handles `.field_expr` on the RHS of `is` checks — emits the full dotted path in generated Zig
- **D-08:** For arbitrary union type checks (`val is mod.Type`), codegen emits `val == .mod_Type` or equivalent Zig discriminant comparison
- **D-09:** For general comptime type checks, codegen emits `@TypeOf(val) == mod.Type`
- **D-10:** 1:1 mapping — codegen is a pure translator, no validation of whether the module/type exists
- **D-11:** Type existence validation deferred to Zig — consistent with Phase 15 approach

### Claude's Discretion
- Exact token scanning loop for collecting dotted identifiers in the builder
- How to construct the `field_expr` chain (left-to-right nesting)
- Whether to handle the arbitrary union discriminant case with dots or defer to Zig's own dispatch
- Test fixture design

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TAMGA-02 | `is` operator works with cross-module types — `ev is module.Type` parses and codegen emits correct qualified Zig | Grammar rule extension + builder dotted-path scan + new codegen branch for `.field_expr` RHS |
</phase_requirements>

---

## Standard Stack

No new libraries. The feature uses existing compiler infrastructure only.

### Core Tools
| Tool | Version | Purpose |
|------|---------|---------|
| Zig | 0.15.2+ | Compiler implementation language |
| PEG engine | custom (`src/peg/`) | Grammar rule matching |

### Key Files — No New Files Needed
| File | Change Type | What Changes |
|------|-------------|--------------|
| `src/orhon.peg` | Grammar rule edit | `compare_expr` rule: extend `is` RHS from `(IDENTIFIER / 'null')` to `(IDENTIFIER ('.' IDENTIFIER)* / 'null')` |
| `src/peg/builder.zig` | Function edit | `buildCompareExpr` — scan multi-token dotted path after `kw_is`, build `field_expr` chain |
| `src/codegen.zig` | Codegen edit | `is` type-check block — add `b.right.* == .field_expr` branch, emit qualified type path |
| `test/fixtures/tester.orh` | Addition | Add cross-module `is` test using `module.Type` syntax |
| `test/09_language.sh` | Addition | Assert generated tester.zig contains a module-qualified type check pattern |

---

## Architecture Patterns

### `field_expr` AST Node (existing, reused)

```zig
// src/parser.zig line 325
pub const FieldExpr = struct {
    object: *Node,
    field: []const u8,
};
```

`field_expr` is already used throughout the codebase for `a.b`, `a.b.c` (as nested chains), method calls, cross-module function calls, etc. The builder always constructs chains left-to-right: `a.b.c` becomes `field_expr(field_expr(a, b), c)`.

### How the Current `is` Pipeline Works

```
Grammar:
  compare_expr
      <- bitor_expr 'is' 'not'? (IDENTIFIER / 'null')
                                 ^^^^^^^^^^^^^^^^^
                                 only single-token RHS

Builder (buildCompareExpr, line 1215):
  1. Find kw_is token in range
  2. Check for optional kw_not
  3. Scan forward: find first .identifier → make .identifier node
                   OR find .kw_null → make .null_literal node
  4. Build: binary_expr(op="==" or "!=",
               left=compiler_func("type", [expr]),
               right=identifier_or_null_node)

Codegen (line 1616+):
  if b.right.* == .null_literal  → emit `(val == null)` or `(val != null)`
  if b.right.* == .identifier
    if rhs == "Error"            → emit `(if(val)|_|false else|_|true)`
    if getTypeClass == .arbitrary_union → emit `(val == ._TypeName)`
    else                         → emit `(@TypeOf(val) == TypeName)`
  // NO BRANCH for b.right.* == .field_expr  ← the gap
```

### How It Looks After the Change

```
Grammar:
  compare_expr
      <- bitor_expr 'is' 'not'? (IDENTIFIER ('.' IDENTIFIER)* / 'null')

Builder (buildCompareExpr):
  After finding kw_is and optional kw_not, scan tokens:
  - Collect identifier tokens while next non-whitespace is '.' IDENTIFIER
  - If only 1 identifier collected → make .identifier node (D-04, no regression)
  - If 2+ identifiers collected  → build left-to-right field_expr chain (D-05)
  Example: tokens [foo, dot, Bar] →
    field_expr{ object: identifier("foo"), field: "Bar" }

Codegen (new branch after existing .identifier branch):
  if b.right.* == .field_expr
    → walk field_expr chain to emit full dotted path
    → for arbitrary_union: emit `(val == ._mod_Type)` or `(val == .mod.Type)`
    → for general:         emit `(@TypeOf(val) == mod.Type)`
```

### Builder Token Scanning Pattern (established in `buildCompareExpr`)

The existing code already scans token-by-token through `cap.start_pos..cap.end_pos`. The dotted-path scan follows the same approach: after finding the `kw_is` position and skipping optional `kw_not`, walk forward collecting `identifier` tokens separated by `dot` tokens.

```zig
// Scan for dotted identifier path: IDENTIFIER ('.' IDENTIFIER)*
var identifiers = std.ArrayListUnmanaged([]const u8){};
var k = start; // first token after is / is not
while (k < cap.end_pos) : (k += 1) {
    if (ctx.tokens[k].kind == .identifier) {
        identifiers.append(ctx.alloc(), ctx.tokens[k].text) catch {};
        // Peek: next token is '.' followed by identifier → continue
        if (k + 2 < cap.end_pos and
            ctx.tokens[k + 1].kind == .dot and
            ctx.tokens[k + 2].kind == .identifier)
        {
            k += 1; // skip the dot, loop will consume the next identifier
        } else {
            break;
        }
    } else if (ctx.tokens[k].kind == .kw_null) {
        // null keyword — existing branch handles this separately
        break;
    }
}

// Produce AST node
if (identifiers.items.len == 1) {
    rhs = try ctx.newNode(.{ .identifier = identifiers.items[0] });
} else if (identifiers.items.len > 1) {
    // Left-to-right chain: a.b.c → field_expr(field_expr(a,b),c)
    var chain = try ctx.newNode(.{ .identifier = identifiers.items[0] });
    for (identifiers.items[1..]) |name| {
        chain = try ctx.newNode(.{ .field_expr = .{ .object = chain, .field = name } });
    }
    rhs = chain;
}
```

### Codegen Pattern for `field_expr` RHS

For the new branch, codegen needs to emit the full dotted Zig path. A helper function that walks the `field_expr` chain and emits `a.b.c` is the cleanest approach. The existing `generateExpr` for `.field_expr` already handles the general case — but it applies special-case transformations (`handle.value`, `ptr.value`, `.Error` field, etc.) that are not appropriate on the RHS of a type check. A simpler direct emit is needed.

For arbitrary union types (D-08), the discriminant tag in generated Zig is `._TypeName`. For a qualified path `mod.Type`, the cross-module union struct tag in Zig is accessed as `mod.Type` directly in a comparison. D-08 says emit `val == .mod_Type` or equivalent — the "or equivalent" is important. Since Zig arbitrary unions in the Orhon sense emit tagged union structs with `._TagName` discriminants, and cross-module struct types are referenced by their qualified name, the pattern is implementation-defined. The safest approach: emit `@TypeOf(val) == mod.Type` (the D-09 general path) for `field_expr` RHS, because the arbitrary union check with discriminant tag `._X` only works for single-word type names that map to a local Zig tag. Cross-module types dispatch differently — they are union-of-struct-pointers, not primitive union values.

**Recommendation (Claude's discretion):** Always use the general type-check path (`@TypeOf(val) == mod.Type`) for `field_expr` RHS, regardless of `getTypeClass`. The Tamga use case is `ev is sdl.KeyboardEvent` where `ev` is a union-of-struct-pointers dispatched at the Zig level. The generated Zig comparison uses the qualified type name directly, not a discriminant tag. This avoids the question of what `._mod_Type` would mean in Zig and matches D-09.

### Anti-Patterns to Avoid

- **Modifying existing `.identifier` RHS path:** D-04 locks that path unchanged. New code for dotted paths is additive.
- **Using `generateExpr` for `field_expr` RHS in type checks:** `generateExpr(.field_expr)` applies thread Handle, safe Ptr, raw Ptr, and other semantic transformations that corrupt the output when the field_expr is a type name, not a runtime value.
- **Building `field_expr` right-to-left:** The established pattern in the codebase is always left-to-right (`a.b` = `field_expr(a, "b")`). See builder.zig lines 1331–1335.
- **Checking for `kw_null` as part of the dotted path scan:** `null` is a keyword (`.kw_null`), not an identifier. The existing grammar already separates `null` as an alternative (`/ 'null'`). D-02 locks this.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Type name qualification in codegen | Custom module-lookup logic | Emit path as-is — 1:1 translation (D-10) |
| Type existence validation | Resolver check for module.Type | Delegate to Zig (D-11) |
| New AST node for qualified type | New `NodeKind.qualified_type` | Reuse existing `field_expr` (D-05) |
| Dotted path emission helper | Recursive `field_expr` walker | Inline loop: `emit(f.field_expr.object)` + `emit(".")` + `emit(f.field)` — or write a small helper, but don't re-implement `generateExpr` |

---

## Common Pitfalls

### Pitfall 1: Grammar PEG Choice Order — `null` Branch Must Come After Identifier Path
**What goes wrong:** If the grammar is written as `('null' / IDENTIFIER ('.' IDENTIFIER)*)`, PEG tries `null` first. Since `null` is a keyword, not an IDENTIFIER, this is fine. But if written as `(IDENTIFIER ('.' IDENTIFIER)* / 'null')`, PEG tries the identifier path first — which is also fine because `null` is `.kw_null`, not `.identifier`. Either order is correct.
**Why it happens:** PEG ordered choice is greedy — it commits to the first alternative that matches. Since `null` is a keyword token (`.kw_null`), it will not match `IDENTIFIER`. Order does not matter here practically, but the second form `(IDENTIFIER ('.' IDENTIFIER)* / 'null')` matches D-01 grammar most directly.
**How to avoid:** Follow D-01 exactly: `IDENTIFIER ('.' IDENTIFIER)*` as the first alternative, `'null'` as the second.

### Pitfall 2: Token Kind for `.` in the Path
**What goes wrong:** The dot token between `module` and `Type` in `module.Type` might not be `.dot` — it could be `.period` or another token kind depending on the lexer.
**Why it happens:** The lexer tokenizes `.` differently in different contexts (struct field access `a.b` vs float literals `3.14` vs method calls `a.method()`).
**How to avoid:** Verify the token kind by checking how `field_access` is parsed in the current grammar and how `buildFieldExpr` (lines 1333–1335 in builder.zig) reads the dot. The pattern `tokenText(ctx, child.start_pos + 1)` for `field_access` implies the dot is at `start_pos` and the field name at `start_pos + 1`. Grep for `.dot` in the lexer to confirm the token kind name.
**Warning signs:** The builder scans for a dot token but finds none — the path never collects more than one identifier.

### Pitfall 3: `generateExpr(.field_expr)` Has Special Cases That Break Type Paths
**What goes wrong:** Calling `self.generateExpr(rhs)` when `rhs` is a `field_expr` type name (e.g., `sdl.KeyboardEvent`) will pass through the existing `field_expr` codegen at line 1860 which checks `handle.value`, `ptr.value`, `.Error` field, thread handle `.done`, etc. If none match, it falls through to a default emit — but the default may not emit a plain dotted path.
**Why it happens:** `generateExpr` is a semantic translator, not a plain printer.
**How to avoid:** Write a small recursive helper `emitTypePath(node: *Node)` that emits `.identifier` as its text and `.field_expr` as `object.field` without any special-casing. Use this helper only in the `is` type-check codegen, not in the general expression path.
**Warning signs:** `@TypeOf(val) == val.value` emitted instead of `@TypeOf(val) == sdl.KeyboardEvent`.

### Pitfall 4: Regression in the Existing `val is i32` Arbitrary Union Path
**What goes wrong:** Adding the `field_expr` branch before or mixed with the existing `.identifier` branch breaks the `arbitrary_union` type check for single-identifier types.
**Why it happens:** The existing `.identifier` branch has two sub-cases: `Error` check and `arbitrary_union` check. These must not be disturbed.
**How to avoid:** Add the `field_expr` branch as an entirely new `else if (b.right.* == .field_expr)` block after the closing brace of the existing `.identifier` block at line 1671.
**Warning signs:** `./testall.sh` stage 10 fails — `test_arb_union_return` or `test_arb_union_three` produces wrong output.

### Pitfall 5: The `is not` Case With Dotted Paths
**What goes wrong:** `ev is not module.Type` — the token scan for the dotted path must skip `kw_not` before looking for the first identifier.
**Why it happens:** The existing code already checks `negated = ctx.tokens[is_pos + 1].kind == .kw_not` and sets `j = if (negated) is_pos + 2 else is_pos + 1`. The dotted-path scan must start at the same `j`.
**How to avoid:** Reuse the same `negated` calculation and start the identifier collection at `is_pos + 2` (if negated) or `is_pos + 1` (if not negated). This matches D-03.
**Warning signs:** `ev is not module.Type` emits `==` instead of `!=` in the generated Zig.

### Pitfall 6: Dot Token Kind — Verify Against Lexer
**What goes wrong:** If the dot between module and type is not `.dot` but another token kind (e.g., `.period`), the scan never finds the continuation and always produces a single-identifier path.
**Verification:** Check `src/lexer.zig` for the token kind produced by `.`.
**How to avoid:** Run a quick grep before implementing: `grep -n "dot\|period\|\.dot" src/lexer.zig | head -10`.

---

## Code Examples

Verified from reading the actual source files.

### Current Grammar Rule (src/orhon.peg line 316)
```peg
# Before
compare_expr
    <- bitor_expr compare_op bitor_expr
     / bitor_expr 'is' 'not'? (IDENTIFIER / 'null')
     / bitor_expr
```

### Grammar After Change
```peg
# After
compare_expr
    <- bitor_expr compare_op bitor_expr
     / bitor_expr 'is' 'not'? (IDENTIFIER ('.' IDENTIFIER)* / 'null')
     / bitor_expr
```

### Builder Change (src/peg/builder.zig, extending buildCompareExpr at line 1244)
```zig
// After finding is_pos and negated, replace the single-identifier scan:

// Build dotted path: IDENTIFIER ('.' IDENTIFIER)*
var idents = std.ArrayListUnmanaged([]const u8){};
defer idents.deinit(ctx.alloc());
var k = if (negated) is_pos + 2 else is_pos + 1;
while (k < cap.end_pos) : (k += 1) {
    switch (ctx.tokens[k].kind) {
        .identifier => {
            idents.append(ctx.alloc(), ctx.tokens[k].text) catch {};
            // Peek ahead: if next is dot and after that an identifier, continue
            if (k + 2 < cap.end_pos and
                ctx.tokens[k + 1].kind == .dot and
                ctx.tokens[k + 2].kind == .identifier)
            {
                k += 1; // skip dot; loop increments to the next identifier
            } else {
                break;
            }
        },
        .kw_null => {
            rhs = try ctx.newNode(.{ .null_literal = {} });
            break;
        },
        else => {},
    }
}
if (idents.items.len == 1) {
    rhs = try ctx.newNode(.{ .identifier = idents.items[0] });
} else if (idents.items.len > 1) {
    // Left-to-right: a.b.c → field_expr(field_expr(identifier(a), "b"), "c")
    var chain: *Node = try ctx.newNode(.{ .identifier = idents.items[0] });
    for (idents.items[1..]) |name| {
        chain = try ctx.newNode(.{ .field_expr = .{ .object = chain, .field = name } });
    }
    rhs = chain;
}
```

### Codegen Change (src/codegen.zig, after the closing `}` of the `.identifier` block at line 1671)
```zig
// New branch: qualified type check — ev is module.Type
if (b.right.* == .field_expr) {
    // Emit path helper: walks field_expr chain and emits a.b.c
    try self.emit("(@TypeOf(");
    try self.generateExpr(val_node);
    try self.emit(") ");
    try self.emit(cmp);
    try self.emit(" ");
    try self.emitTypePath(b.right); // helper that prints dotted path without semantic transforms
    try self.emit(")");
    return;
}
```

### `emitTypePath` Helper (new private function in codegen.zig)
```zig
/// Emit a type-name path (a.b.c) from a field_expr chain without semantic transforms.
/// Used only for `is` type-check RHS where the node is a type name, not a runtime value.
fn emitTypePath(self: *CodeGen, node: *parser.Node) anyerror!void {
    switch (node.*) {
        .identifier => |name| try self.emit(name),
        .field_expr => |f| {
            try self.emitTypePath(f.object);
            try self.emit(".");
            try self.emit(f.field);
        },
        else => try self.generateExpr(node), // fallback
    }
}
```

### Test Fixture Pattern (cross-module struct types)
For the test to work without requiring a real multi-module project, the fixture uses two modules in the same project: `module main` imports `module helper`, and `ev is helper.SomeType` exercises the cross-module `is` path. The tester module pattern (separate `.orh` files in the same project) used by Phase 15 is the template.

---

## State of the Art

| Old Behavior | New Behavior | When Changed | Impact |
|--------------|-------------|--------------|--------|
| `is` RHS grammar: single `IDENTIFIER` only | `is` RHS: `IDENTIFIER ('.' IDENTIFIER)*` | Phase 16 | `ev is sdl.KeyboardEvent` parses |
| Builder: single-token scan for RHS | Builder: multi-token dotted-path scan with `field_expr` chain | Phase 16 | AST carries qualified type path |
| Codegen: no branch for `.field_expr` RHS | Codegen: `@TypeOf(val) == mod.Type` for qualified paths | Phase 16 | Generated Zig references fully qualified type |

---

## Open Questions

1. **What is the lexer token kind for `.` in `module.Type`?**
   - What we know: The builder uses `tokenText(ctx, child.start_pos + 1)` for `field_access`, implying the dot is at offset 0 and field name at offset 1 in the `field_access` capture. This suggests the dot is a `.dot` token.
   - What's unclear: The exact `TokenKind` enum variant name (`.dot` vs `.period` vs `.op_dot`).
   - Recommendation: Before writing the builder, grep for the dot literal in `src/lexer.zig` to confirm the enum name. This is a 30-second check that eliminates a whole class of silent bug.

2. **For `ev is module.Type` on an arbitrary-union typed variable, what Zig code is correct?**
   - What we know: For `ev is i32` (single type), codegen emits `ev == ._i32` for `arbitrary_union` class. For cross-module struct types, the union tag is the struct name, and the comparison is against a struct-typed discriminant.
   - What's unclear: Whether the Zig discriminant for a cross-module struct in a union is `.module_Type` (flattened) or `.module.Type` (qualified). This depends on how the arbitrary union type was generated — Orhon generates `union(enum) { _i32: i32, ... }`.
   - Recommendation: Use the general `@TypeOf(val) == mod.Type` path for all `field_expr` RHS (D-09 general path). This is always correct Zig for comptime type checks and avoids the tag-name ambiguity entirely. Tamga's actual use case (pointer-to-struct dispatch) is better served by this anyway.

3. **Does the `is` grammar change affect the PEG packrat cache invalidation?**
   - What we know: PEG grammar changes require re-running all parse tests. The `09_language.sh` and `10_runtime.sh` tests catch regressions.
   - What's unclear: Nothing — this is standard procedure for grammar changes in this codebase (Phase 15 demonstrated the pattern).
   - Recommendation: Run `./testall.sh` after grammar + builder + codegen changes are all in place.

---

## Environment Availability

Step 2.6: SKIPPED — this phase is purely code changes within the existing compiler. No external tools, services, or CLIs beyond the project's own build system (`zig build`, `./testall.sh`) are required.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in test blocks + bash integration tests |
| Config file | `build.zig` (for `zig build test`) |
| Quick run command | `zig build test && zig build` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TAMGA-02 | `ev is module.Type` parses without error | integration | `bash test/09_language.sh` | ❌ Wave 0 — tester fixture needs `is` qualified-type case |
| TAMGA-02 | Codegen emits `@TypeOf(val) == mod.Type` for qualified `is` | integration | `grep "@TypeOf" .orh-cache/generated/tester.zig` | ❌ Wave 0 — test check not yet in 09_language.sh |
| TAMGA-02 | `ev is not module.Type` works (negated form) | integration | `bash test/09_language.sh` | ❌ Wave 0 — fixture needs negated qualified-type case |
| TAMGA-02 | Existing `is Error`, `is null`, `is i32` unchanged | integration | `bash test/10_runtime.sh` | ✅ existing tester.orh covers these |
| TAMGA-02 | Existing arbitrary union `val is i32` path unbroken | integration | `bash test/10_runtime.sh` | ✅ test_arb_union_return in tester.orh |

### Sampling Rate
- **Per task commit:** `zig build test && zig build`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `test/fixtures/tester.orh` — add a cross-module `is` test case using qualified types (requires a helper module in the test project, or a self-contained struct type in the same module used as a multi-module test)
- [ ] `test/09_language.sh` — add grep check verifying `@TypeOf` + `.` path appears in generated Zig for the `is` qualified check

---

## Sources

### Primary (HIGH confidence)
- `src/orhon.peg` line 316 — current `compare_expr` grammar rule, read directly
- `src/peg/builder.zig` lines 1215–1257 — `buildCompareExpr` full function, read directly
- `src/parser.zig` lines 49, 113, 325–328 — `NodeKind.field_expr`, `Node.field_expr`, `FieldExpr` struct, read directly
- `src/codegen.zig` lines 68–72 — `getTypeClass` helper, read directly
- `src/codegen.zig` lines 1616–1671 — `is` type-check codegen block, read directly
- `src/codegen.zig` lines 1860–1929 — `field_expr` codegen block (general case), read directly
- `src/peg/builder.zig` lines 1327–1335 — `field_expr` builder pattern (left-to-right construction), read directly
- `/home/yunus/Projects/orhon/tamga_framework/docs/bugs.txt` lines 66–84 — bug description with exact Tamga use case
- `.planning/phases/16-is-operator-qualified-types/GOAL.md` — success criteria
- `.planning/phases/16-is-operator-qualified-types/16-CONTEXT.md` — all locked decisions D-01 through D-11

### Secondary (MEDIUM confidence)
- `test/09_language.sh` — test pattern for code-generation assertions (grep on generated Zig files)
- `test/11_errors.sh` — negative test pattern (build exit code check)
- `.planning/phases/15-enum-explicit-values/15-RESEARCH.md` — Phase 15 research as structural template; same pipeline change pattern

---

## Metadata

**Confidence breakdown:**
- Grammar change: HIGH — rule location confirmed at line 316, change is additive (one PEG quantifier added)
- Builder change: HIGH — `buildCompareExpr` at line 1215 read directly; token scan pattern established by existing code
- `field_expr` chain construction: HIGH — builder pattern at lines 1327–1335 confirms left-to-right nesting
- Codegen new branch: HIGH — existing `is` block at lines 1616–1671 read directly; new branch is additive
- `emitTypePath` helper: HIGH — pattern matches existing recursive helpers in codegen
- Dot token kind: MEDIUM — inferred from field_access builder pattern but not directly verified from lexer enum

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain — no external library changes)
