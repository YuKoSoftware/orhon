# Phase 22: `throw` Statement - Research

**Researched:** 2026-03-27
**Domain:** Orhon compiler — lexer, PEG grammar, AST, propagation pass, MIR, codegen
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** `throw` operates on named variables only, not arbitrary expressions. `throw x` is valid; `throw divide(10,0)` is not. Rationale: type narrowing requires a variable to narrow — expressions have no binding to narrow.
- **D-02:** `throw x` where `x: (Error | T)` emits early return of the error and narrows `x` to `T`. The enclosing function must return an error type.
- **D-03:** `throw` is a statement keyword, not an expression. It appears on its own line: `throw result` — not inside an expression.
- **D-04:** After `throw x`, `x` is narrowed to its value type `T` for the rest of the function (not just the current block). The throw guarantees the error case is gone — no need to re-check.
- **D-05:** Multiple `throw` statements are allowed — each narrows one variable. `throw a; throw b;` is valid when both `a` and `b` are error unions.
- **D-06:** `throw result` generates: `if (result) |_| {} else |err| return err;` in Zig. Subsequent uses of `result` emit the unwrapped payload access.
- **D-07:** The `throw` keyword maps to Zig's error check + early return pattern, NOT Zig's `try` (which is an expression). This is intentional — Orhon's `throw` is a statement.
- **D-08:** `throw` in a function that doesn't return `(Error | T)` produces a compile error. Wording at Claude's discretion.
- **D-09:** `throw` on a non-error-union variable produces a compile error.

### Claude's Discretion

- Exact error message wording for compile errors
- Whether the propagation checker (pass 9) or a new pass handles throw validation
- Internal representation of throw in MIR (annotation approach)

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ERR-01 | `throw x` propagates error from `(Error | T)` and returns early from enclosing function | D-02/D-06: propagation check in pass 9, codegen emits `if (x) |_| {} else |err| return err;` |
| ERR-02 | After `throw x`, variable `x` narrows to value type `T` (no `.value` needed) | D-04: MIR `error_narrowed` map + `narrowed_to` stamp pattern already used for `is` checks |
| ERR-03 | `throw` in a function that doesn't return an error type produces compile error | D-08/D-09: propagation pass already tracks `func_returns_error` flag; extend `checkStatement` |
| ERR-04 | Example module and docs updated with `throw` usage | `src/templates/example/error_handling.orh` + `docs/08-error-handling.md` |
</phase_requirements>

---

## Summary

Phase 22 adds `throw` as a first-class statement keyword to Orhon. The feature spans the full compiler pipeline: lexer (new token), PEG grammar (new rule), AST builder (new node handler), propagation pass (validation), MIR lowerer (new kind + narrowing), and codegen (Zig emission).

The implementation follows a well-worn pattern already used by `return`, `break`, `continue`, and `defer`. Every step has a clear, small, mechanical counterpart in the existing infrastructure. The only genuinely new logic is (1) the throw-specific compile error checks in propagation, and (2) the `if (x) |_| {} else |err| return err;` emission in codegen combined with narrowing propagation.

The key insight for narrowing: the codegen already maintains `error_narrowed` and `null_narrowed` maps (type `std.StringHashMapUnmanaged(void)`) that record which variables have been narrowed via `is Error` checks. `throw x` achieves the same narrowing guarantee — after throw, `x` is guaranteed to be its value type. Reusing the same `error_narrowed` map from `throw x` makes `.value`-free access work automatically in the existing field-access codegen without any new dispatch logic.

**Primary recommendation:** Handle throw validation inside `PropagationChecker.checkStatement` (pass 9) — the `func_returns_error` flag and `UnionVar` tracking infrastructure is already there. Add `throw_stmt` to `MirKind` and lower it in `MirLowerer.lowerNode`. In codegen, add a `throw_stmt` case to `generateStatementMir` that emits the Zig pattern and records the variable in `error_narrowed`.

---

## Standard Stack

### Core (all pre-existing in project)

| Component | File | Current State | Change Required |
|-----------|------|---------------|-----------------|
| Lexer | `src/lexer.zig` | `TokenKind` enum + `KEYWORDS` map | Add `.kw_throw` to enum; add `"throw" → .kw_throw` to map |
| PEG grammar | `src/orhon.peg` | `statement` rule lists all statement kinds | Add `throw_stmt` to `statement` alternatives; define `throw_stmt <- 'throw' IDENTIFIER TERM` |
| AST builder | `src/peg/builder.zig` | `buildNode` dispatch table (string → fn) | Add `if (std.mem.eql(u8, rule, "throw_stmt")) return buildThrowStmt(ctx, cap);` entry |
| AST node types | `src/parser.zig` | `NodeKind` enum + `Node` union | Add `.throw_stmt` to `NodeKind`; add `throw_stmt: ThrowStmt` to `Node` union |
| Propagation | `src/propagation.zig` | `checkStatement` switch | Add `.throw_stmt` arm: validate `is_error_union`, validate `func_returns_error`, call `scope.markHandled` |
| MIR | `src/mir.zig` | `MirKind` enum + `MirLowerer.lowerNode` + `astToMirKind` | Add `.throw_stmt` to `MirKind`; lower as single-child (identifier); map in `astToMirKind` |
| Codegen | `src/codegen.zig` | `generateStatementMir` switch | Add `.throw_stmt` case: emit `if (x) |_| {} else |err| return err;` and insert `x` into `error_narrowed` |

### No New Dependencies

This phase has zero new library or package dependencies. The entire implementation is inside the existing source files.

---

## Architecture Patterns

### Recommended Project Structure

No new files required. All changes are additions to existing files.

```
src/
├── lexer.zig          — +1 enum variant, +1 keyword map entry
├── orhon.peg          — +1 rule, +1 alternative in statement rule
├── peg/
│   └── builder.zig    — +1 dispatch entry, +1 builder function (~10 lines)
├── parser.zig         — +1 NodeKind variant, +1 Node union arm, +1 struct
├── propagation.zig    — +1 case in checkStatement (~15 lines)
├── mir.zig            — +1 MirKind variant, +1 lowerNode case, +1 astToMirKind mapping
└── codegen.zig        — +1 case in generateStatementMir (~5 lines)
```

### Pattern 1: Adding a New Keyword (established pattern)

Every keyword in Orhon follows this exact sequence:

1. `src/lexer.zig` — Add to `TokenKind` enum:
```zig
// Source: src/lexer.zig:8 (TokenKind enum)
kw_throw,
```

2. `src/lexer.zig` — Add to `KEYWORDS` map (line 122):
```zig
.{ "throw", .kw_throw },
```

3. `src/orhon.peg` — Add grammar rule and wire into `statement`:
```
throw_stmt
    <- 'throw' IDENTIFIER TERM

statement
    <- _ (var_decl
        / const_decl
        / ...
        / throw_stmt          # add here, before expr_or_assignment
        / expr_or_assignment) _
```
Also add `'throw'` to the KEYWORDS comment block at the bottom of the PEG file.

4. `src/parser.zig` — Add `NodeKind` and `Node` variants:
```zig
// NodeKind enum
throw_stmt,

// Node union
throw_stmt: ThrowStmt,

// New struct
pub const ThrowStmt = struct {
    variable: []const u8,
};
```

5. `src/peg/builder.zig` — Add dispatch entry and builder function:
```zig
// In buildNode dispatch:
if (std.mem.eql(u8, rule, "throw_stmt")) return buildThrowStmt(ctx, cap);

// Builder function:
fn buildThrowStmt(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // Grammar: 'throw' IDENTIFIER TERM
    // The IDENTIFIER is the variable name — find its token text
    var i = cap.start_pos;
    while (i < cap.end_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .identifier) {
            return ctx.newNodeAt(.{ .throw_stmt = .{ .variable = ctx.tokens[i].text } }, i);
        }
    }
    return error.InvalidCapture;
}
```

### Pattern 2: Propagation Check (extending existing pass 9)

The `PropagationChecker.checkStatement` switch already handles `return_stmt`, `if_stmt`, `match_stmt`, etc. Add a `.throw_stmt` case:

```zig
// Source: src/propagation.zig — checkStatement
.throw_stmt => |t| {
    // Validate: variable must be a tracked error union
    if (scope.isTracked(t.variable)) |uvar| {
        if (!uvar.is_error_union) {
            const msg = try std.fmt.allocPrint(self.allocator,
                "'throw' requires an error union variable — '{s}' is a null union",
                .{t.variable});
            defer self.allocator.free(msg);
            try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(node) });
            return;
        }
    } else {
        // Variable not tracked as a union at all
        const msg = try std.fmt.allocPrint(self.allocator,
            "'throw' requires an error union variable — '{s}' is not an error union",
            .{t.variable});
        defer self.allocator.free(msg);
        try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(node) });
        return;
    }
    // Validate: enclosing function must return an error type
    if (!scope.func_returns_error) {
        const msg = try std.fmt.allocPrint(self.allocator,
            "'throw' used in function that does not return an error union",
            .{});
        defer self.allocator.free(msg);
        try self.ctx.reporter.report(.{ .message = msg, .loc = self.ctx.nodeLoc(node) });
        return;
    }
    // Mark the variable as handled — error case is propagated
    scope.markHandled(t.variable);
},
```

**Critical:** `scope.markHandled` is the right call here — it sets `handled = true` on the `UnionVar`, which prevents the scope-exit check from emitting a "unhandled union" error. This is exactly what `match_stmt` and `return_stmt` do.

### Pattern 3: MIR Lowering (new kind)

Add `.throw_stmt` to `MirKind` and handle in `lowerNode` and `astToMirKind`:

```zig
// src/mir.zig — MirKind enum (in Statements section)
throw_stmt,

// src/mir.zig — astToMirKind
.throw_stmt => .throw_stmt,

// src/mir.zig — MirLowerer.lowerNode (in switch)
.throw_stmt => {
    // Single child: identifier node (the variable)
    // MIR needs the variable name to emit the check pattern
    // The variable name is stored on mir_node.name (populated by populateData)
    // No children needed — name is self-contained in the ThrowStmt struct
},
```

The `populateData` function at the bottom of `mir.zig` reads self-contained data from AST nodes onto `MirNode` fields. `throw_stmt` needs `mir_node.name = t.variable` set there:

```zig
// src/mir.zig — populateData
.throw_stmt => |t| {
    m.name = t.variable;
},
```

### Pattern 4: Codegen Emission (new case in generateStatementMir)

```zig
// src/codegen.zig — generateStatementMir switch
.throw_stmt => {
    const var_name = m.name orelse return;
    // Emit: if (result) |_| {} else |err| return err;
    try self.emitFmt("if ({s}) |_| {{}} else |_err| return _err;", .{var_name});
    // Record narrowing so subsequent .value access emits `result catch unreachable`
    try self.error_narrowed.put(self.allocator, var_name, {});
},
```

**Note on `_err` name:** Using `_err` rather than `err` avoids collisions with user variables named `err` in the same scope. The Zig generated code is inside the same function body.

**Note on `{}`:** In Zig, `{}` is a valid void expression in capture payloads. `if (x) |_| {} else |_err| return _err;` is valid Zig.

### Pattern 5: Type Narrowing After `throw`

After emitting the throw statement, the variable is recorded in `error_narrowed`. All subsequent uses of `result` in the function that hit the `.value` field path in `generateExprMir` will then use the narrowing branch:

```zig
// Existing code in codegen.zig — field_access case, MIR path (line ~2492)
} else if (obj_tc == .error_union) {
    // (Error | T) → anyerror!T: result.value → result catch unreachable
    try self.generateExprMir(obj_mir);
    try self.emit(" catch unreachable");
}
```

And the fallback path (line ~2513) for `error_narrowed` also catches it. No additional code is needed for narrowing once `error_narrowed` is populated by the throw emission.

### Anti-Patterns to Avoid

- **Don't emit Zig's `try`:** Decision D-07 is explicit. `try x` is a Zig expression, not a statement. The target output is `if (x) |_| {} else |err| return err;`.
- **Don't add a separate "throw checker" pass:** `PropagationChecker` already has the `func_returns_error` flag and `UnionVar` tracking. Extending `checkStatement` is the right place. No new pass needed.
- **Don't validate throw in MIR or codegen:** Validation belongs in pass 9 (propagation). MIR and codegen assume the AST is valid by pass 10+.
- **Don't clear `error_narrowed` at block boundaries:** The narrowing from `throw` applies function-wide (D-04). The `error_narrowed` map is per-function scoped already (cleared on function entry, which is correct behavior). Verify this is already the case in the existing `CodeGen.generateFuncMir` or equivalent reset logic.
- **Don't try to throw on expression results:** Grammar rule uses `IDENTIFIER` terminal only, enforcing D-01 at parse time.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Variable narrowing tracking | Custom narrowing map | `CodeGen.error_narrowed` (already exists) | Already used for `is Error` check narrowing; same semantics |
| Scope-aware union tracking | New scope structure | `PropagationScope` + `markHandled` | Already handles match, return, if+early-exit |
| Error message allocation | Custom string builder | `std.fmt.allocPrint` + `defer self.allocator.free(msg)` | Established pattern, reporter owns duped string |
| Token extraction in builder | Custom token walker | `findTokenInRange` or simple loop over `cap.start_pos..cap.end_pos` | Existing helper pattern |

---

## Common Pitfalls

### Pitfall 1: Forgetting `error_narrowed` is per-function

**What goes wrong:** If `error_narrowed` is NOT cleared between functions, variables from one function leak into the next, causing spurious `catch unreachable` emissions.

**Why it happens:** `CodeGen` is a stateful struct; if `error_narrowed` accumulates across functions without being cleared, later functions see stale entries.

**How to avoid:** Verify that `error_narrowed` is cleared at function-start. Search `codegen.zig` for where `reassigned_vars` is cleared (the same per-function reset point) and ensure `error_narrowed` is reset there too. If it is not currently reset, add it to that reset point.

**Warning signs:** Test where two consecutive functions both use a variable named `result` — second function incorrectly emits `catch unreachable` on `result.value` without a throw.

### Pitfall 2: `TERM` handling in PEG builder

**What goes wrong:** The `throw_stmt` capture includes the terminal `TERM` token (newline or `}`-lookahead). The builder must skip the `kw_throw` token and find the `IDENTIFIER` token, not accidentally capture the TERM position.

**Why it happens:** The builder iterates over token positions in the capture range. TERM is a synthetic token concept — the actual token is `newline` kind. If the builder doesn't filter to `.identifier` kind, it may pick up a newline token text.

**How to avoid:** Loop from `cap.start_pos` to `cap.end_pos`, check `ctx.tokens[i].kind == .identifier`, stop at first match. This is the same pattern used in `buildReturn` (which searches for a non-NL, non-`}` expr).

### Pitfall 3: MIR `populateData` must set `m.name`

**What goes wrong:** `generateStatementMir` reads `m.name` to get the variable name. If `populateData` doesn't copy `t.variable` to `m.name`, codegen gets `null` and returns early without emitting anything.

**Why it happens:** `populateData` is a switch on AST node kind; new kinds are not automatically handled — they hit the `else => {}` branch.

**How to avoid:** Add `throw_stmt` case to `populateData` explicitly: `m.name = t.variable`.

### Pitfall 4: Propagation must handle `throw` BEFORE `checkScopeExit`

**What goes wrong:** If propagation checks scope exit without knowing about `throw`, it will emit "unhandled error union" for variables that were thrown.

**Why it happens:** `checkStatement` runs in order; `checkScopeExit` runs after all statements. As long as the `.throw_stmt` arm calls `scope.markHandled(t.variable)`, the scope exit check will see `handled = true`.

**How to avoid:** The `.throw_stmt` arm in `checkStatement` must call `scope.markHandled`. Do not forget this call — it is the single most critical line in the propagation change.

### Pitfall 5: Zig brace escaping in `emitFmt`

**What goes wrong:** `emitFmt("if ({s}) |_| {} else |_err| return _err;", ...)` will fail because `{}` in a format string is interpreted as a format specifier.

**Why it happens:** `std.fmt.allocPrint` / `emitFmt` use `{}` for format arguments; literal braces must be escaped as `{{` and `}}`.

**How to avoid:** Use `emitFmt("if ({s}) |_| {{}} else |_err| return _err;", .{var_name})`.

### Pitfall 6: `throw` on null union (D-09)

**What goes wrong:** A user writes `throw x` where `x: (null | T)`. Without an explicit check, this would pass propagation (null unions are also tracked) and generate broken Zig because `if (x) |_| {} else |_err| return _err;` doesn't work on `?T`.

**Why it happens:** `PropagationScope.UnionVar` tracks both error unions (`is_error_union = true`) and null unions (`is_error_union = false`). The `.throw_stmt` arm must check `uvar.is_error_union` and reject null unions.

**How to avoid:** Check `uvar.is_error_union == true` before accepting the throw; emit compile error for null unions.

---

## Code Examples

### Full throw_stmt builder function

```zig
// Source: pattern derived from buildReturn / builder.zig existing handlers
fn buildThrowStmt(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    // Grammar: 'throw' IDENTIFIER TERM
    // Find the IDENTIFIER token in the capture range
    var i = cap.start_pos;
    while (i < cap.end_pos and i < ctx.tokens.len) : (i += 1) {
        if (ctx.tokens[i].kind == .identifier) {
            return ctx.newNodeAt(
                .{ .throw_stmt = .{ .variable = ctx.tokens[i].text } },
                i,
            );
        }
    }
    return error.InvalidCapture;
}
```

### Full codegen emission

```zig
// Source: pattern derived from generateStatementMir, codegen.zig
.throw_stmt => {
    const var_name = m.name orelse return;
    // Emit Zig error-check-and-propagate pattern (D-06, D-07)
    try self.emitFmt("if ({s}) |_| {{}} else |_err| return _err;", .{var_name});
    // Record narrowing: subsequent `var_name.value` emits `var_name catch unreachable`
    try self.error_narrowed.put(self.allocator, var_name, {});
},
```

### Example: throw in error_handling.orh (to add)

```
// With throw (concise)
func divide_with_throw(a: i32, b: i32) (Error | i32) {
    var result = safe_divide(a, b)
    throw result
    return result
}

test "throw propagates error" {
    const r = divide_with_throw(10, 2)
    assert(r is not Error)
    const r2 = divide_with_throw(10, 0)
    assert(r2 is Error)
}
```

The generated Zig for `throw result` is:
```zig
if (result) |_| {} else |_err| return _err;
_ = &result;  // already emitted by var_decl, not re-emitted
```

Subsequent `return result` in Orhon (after narrowing) generates:
```zig
return result catch unreachable;
```

---

## State of the Art

| Old Approach (before this phase) | New Approach (after throw) | Impact |
|----------------------------------|---------------------------|--------|
| `if(result is Error) { return result.Error }` then `var value = result.value` | `throw result` then use `result` directly | Eliminates 2–3 lines of boilerplate per error-returning call |
| Manual `is Error` + early exit | `throw` as single statement | Propagation checker sees explicit intent; no implicit magic |
| `.value` required after narrowing | Direct variable use after `throw` | Cleaner read: `result` is already the success type |

---

## Environment Availability

Step 2.6: SKIPPED (no external dependencies — pure compiler source changes, no new tools or services required).

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell integration tests |
| Config file | `build.zig` (for unit tests); `test/` scripts for integration |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ERR-01 | `throw x` propagates error and returns early | integration (codegen + runtime) | `./testall.sh` (test/10_runtime.sh via tester binary) | ❌ Wave 0 — add to `error_handling.orh` |
| ERR-02 | After `throw x`, `x` narrows to `T` (no `.value` needed) | integration (codegen output check) | `./testall.sh` (test/09_language.sh grep on generated .zig) | ❌ Wave 0 — add grep check to `09_language.sh` |
| ERR-03 | `throw` in non-error function → compile error | negative test | `./testall.sh` (test/11_errors.sh) | ❌ Wave 0 — add `fail_throw.orh` fixture |
| ERR-04 | Example module + docs updated | compilation + visual | `./testall.sh` (test/09_language.sh — example compiles) | ❌ Wave 0 — add throw example to `error_handling.orh` |

### Sampling Rate

- **Per task commit:** `zig build test` (unit tests only, fast)
- **Per wave merge:** `./testall.sh` (all 11 stages)
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `test/fixtures/fail_throw.orh` — negative test fixture for ERR-03 (throw in void function, throw on non-error-union variable)
- [ ] `src/templates/example/error_handling.orh` — add `throw` usage example and test for ERR-01/ERR-02/ERR-04
- [ ] `test/09_language.sh` — add grep check that generated example.zig contains `if (` + `|_err| return _err` pattern (ERR-02 codegen check)
- [ ] `test/11_errors.sh` — add section running `fail_throw.orh` (ERR-03 negative test)
- [ ] Zig unit test for `buildThrowStmt` in `builder.zig` (optional but fast; catches capture logic errors early)

---

## Project Constraints (from CLAUDE.md)

| Directive | Impact on this Phase |
|-----------|---------------------|
| Recursive functions need `anyerror!` | `buildThrowStmt` and any new recursive helpers must use `anyerror!*Node` |
| All numeric literals are `.int_literal` | Not applicable |
| `main` is a keyword → `kw_main` | Not applicable; `throw` follows the same pattern |
| Reporter owns strings → `defer free` after `report()` | All error messages in propagation must `defer allocator.free(msg)` before `reporter.report()` |
| PEG grammar is source of truth | `throw_stmt` rule added to `orhon.peg` first; builder follows grammar |
| Zig multiline strings `\\` not `\` | Not applicable to this phase |
| `@embedFile` for complete files | Not applicable — no new embedded files |
| Template substitution — split-write | Not applicable |
| Example module must compile successfully | The `error_handling.orh` addition with `throw` must compile; it becomes a built-in integration test |
| Run `./testall.sh` after changes | Gate for every commit in this phase |
| No hacky workarounds | The `_err` variable name in the generated Zig pattern is intentional and clean |

---

## Open Questions

1. **Does `error_narrowed` get cleared between functions in codegen?**
   - What we know: `error_narrowed` is declared as a field on `CodeGen` struct, initialized empty.
   - What's unclear: Whether `generateStatementMir` for `.func` or the block generation clears it between functions, or whether this is handled by some other reset.
   - Recommendation: Search `codegen.zig` for where `reassigned_vars.clearRetainingCapacity()` is called — that is the per-function reset point. Ensure `error_narrowed` and `null_narrowed` are also cleared there. If they aren't, add them. This is a pre-condition for correct throw narrowing.

2. **Should `throw` also handle null unions in the future?**
   - What we know: D-09 says throw on non-error-union is a compile error. Null unions are excluded from this phase.
   - What's unclear: Whether `throw` on `(null | T)` would be valuable. The generated pattern would differ (`if (x) |_| {} else return null;` is conceptually different).
   - Recommendation: This is deferred. For now, propagation emits a compile error for null union throw attempts (Pitfall 6). Document this limitation in the error message: "'throw' only works on error unions — use 'if(x is null) { return }' for null unions".

---

## Sources

### Primary (HIGH confidence)

- Source code: `src/lexer.zig` — KEYWORDS map structure and TokenKind enum, verified by direct read
- Source code: `src/orhon.peg` — grammar rule patterns for statements, verified by direct read
- Source code: `src/peg/builder.zig` — dispatch table and builder function patterns, verified by direct read
- Source code: `src/parser.zig` — NodeKind enum and Node union structure, verified by direct read
- Source code: `src/propagation.zig` — PropagationScope, UnionVar, checkStatement, verified by direct read
- Source code: `src/mir.zig` — MirKind, MirLowerer.lowerNode, astToMirKind, populateData, verified by direct read
- Source code: `src/codegen.zig` — generateStatementMir, error_narrowed, generateExprMir field_access path, verified by direct read
- `docs/08-error-handling.md` — current error handling semantics, verified by direct read
- `docs/TODO.md` — throw statement design rationale, verified by direct read
- `src/templates/example/error_handling.orh` — current example module structure, verified by direct read

### Secondary (MEDIUM confidence)

None — all findings are from direct source inspection, no web search required.

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — all changes are extensions of existing, well-understood patterns
- Architecture: HIGH — every integration point verified by reading the actual source
- Pitfalls: HIGH — identified from direct code reading (brace escaping, name clearing, populateData)

**Research date:** 2026-03-27
**Valid until:** 2026-06-27 (stable codebase; only invalidated by structural refactors to MIR or codegen)
