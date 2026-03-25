# Phase 4: Codegen Correctness - Research

**Researched:** 2026-03-25
**Domain:** Zig code generation from MIR — collection constructor rewriting, cross-module ref-passing, qualified generic validation
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Generate tester.zig first, inspect the 9 failing lines (791, 802, 813, 826, 840, 853, 882, 912, 1217), trace each back to the codegen path that produced it
- **D-02:** The error pattern `type 'i32' has no members` means codegen is emitting `.field` access on a primitive — likely a field access or method call on a variable that codegen thinks is a struct but is actually `i32`/`u8`
- **D-03:** Diagnose tester failures first before assuming BUG-01/02 are the cause — the root issue may be different or partially overlapping
- **D-04:** Fix is in codegen call argument generation — when calling an imported module's struct method with `const &T` parameters, codegen must emit `&arg` instead of `arg`
- **D-05:** Codegen needs access to the imported module's DeclTable or MIR argument mode annotations to know which parameters are `const &`
- **D-06:** Fix is in resolver — when processing `module.Type(params)` where `is_qualified` is true, check the referenced module's DeclTable for the type's existence
- **D-07:** Produce a clear Orhon-level error instead of deferring to Zig compile time

### Claude's Discretion
- Exact diagnostic approach and fix ordering within the phase
- Whether to fix codegen field access classification or MIR type annotation — whichever is the actual root cause
- Test additions — what regression tests to add for each fix

### Deferred Ideas (OUT OF SCOPE)
- None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CGEN-01 | Tester module compiles successfully — test stages 09 and 10 pass (100 tests) | Root cause identified: collection `.new()` constructor codegen path emits wrong initializer. Fix is in `src/codegen.zig` MIR call handler. |
| CGEN-02 | Cross-module struct methods emit correct `&` for `const &` parameters (BUG-01) | Fix location confirmed: `src/codegen.zig` call argument generation ~lines 3430-3460, using `all_decls` lookup. |
| CGEN-03 | Qualified generic types (e.g. `math.Vec2(f64)`) validated at Orhon level before codegen (BUG-02) | Fix location confirmed: `src/resolver.zig:839-868`. Validation logic already partially present — the fallback `is_known = true` for missing module case needs tightening. |
</phase_requirements>

---

## Summary

Phase 4 fixes three related codegen correctness issues that together block all 100 runtime tests (stages 09 + 10).

**CGEN-01 (primary blocker):** The root cause of all 9 errors in the generated `tester.zig` has been diagnosed precisely. It is NOT a MIR misclassification issue. `List(i32).new()`, `Map(String, i32).new()`, and `Set(i32).new()` are collection constructor calls that parse as a `call_expr` (calling `.new` on a generic type instantiation). In the MIR path, when codegen processes this as a normal `.call` node, the callee is a `field_access` node (`List(i32)` dot `new`). The object of that field access is another `.call` node whose callee is `i32` (the type parameter extracted from the generic instantiation). This produces `i32.new()` instead of `.{}`. The fix is to detect this pattern in `generateExprMir`'s `.call` handler: when the callee is a `field_access` whose object is a generic type call for a collection (`List`, `Map`, `Set`) and the method is `new`, emit `.{}` directly.

**CGEN-02 (BUG-01):** Cross-module struct method calls with `const &T` parameters emit by-value instead of by-reference. The `all_decls` cross-module DeclTable lookup exists in `fillDefaultArgsMir` but the `value_to_const_ref` coercion annotation is not applied to arguments in cross-module calls. The MIR annotator's `lookupCallSig` at lines 558-588 already handles cross-module lookup — the same lookup must be used to annotate call arguments with `value_to_const_ref` coercions.

**CGEN-03 (BUG-02):** The resolver already has qualified generic validation at lines 839-868. It correctly looks up the module's DeclTable and checks type existence. However the fallback at line 862 (`is_known = true` when `all_decls` is null or the module isn't in `all_decls`) silently trusts any qualified name when module info isn't available. This is the residual issue: `math.Nonexistent(f64)` still passes when `math` module isn't yet in `all_decls`.

**Primary recommendation:** Fix CGEN-01 first (unblocks stages 09+10), then CGEN-02 (cross-module ref-passing), then CGEN-03 (resolver validation). All three fixes are localized to two files: `src/codegen.zig` and `src/mir.zig` for CGEN-01/02, and `src/resolver.zig` for CGEN-03.

---

## Architecture Patterns

### The Two Codegen Paths

Codegen has two parallel expression generators:
- `generateExpr()` — AST-path (legacy, still used for `type_expr` and `passthrough`)
- `generateExprMir()` — MIR-path (current target state, used for all real expressions)

All new fixes must go in `generateExprMir()` (the MIR path). The collection `.new()` pattern is definitely hitting the MIR path since it goes through the `.call` handler at line 2064.

### Collection Constructor Pattern

**Orhon syntax:** `List(i32).new()`, `Map(String, i32).new()`, `Set(i32).new()`

**AST structure:**
```
call_expr {
  callee: field_expr {
    object: call_expr {          ← List(i32) as a call
      callee: identifier "List"
      args: [type_named "i32"]
    }
    field: "new"
  }
  args: []                       ← empty
}
```

**MIR structure (lowered):**
```
.call {
  children[0] (callee): .field_access {
    name: "new"
    children[0] (object): .call {
      children[0] (callee): .identifier { name: "List" }
      children[1..] (args): [type_expr for i32]
    }
  }
  children[1..] (args): []
}
```

**Current emission (wrong):** `i32.new()`
**Required emission:** `.{}`

**Why it emits `i32.new()`:** When `generateExprMir` hits the outer `.call`, it recurses into `callee_mir` (field_access). The `field_access` handler emits `{object}.{field}`, so it calls `generateExprMir` on the inner `.call` node `List(i32)`. The inner `.call` node's callee is identifier `"List"` and its arg is `type_expr` for `i32`. Since there are args, it emits `List(i32)` — but `typeToZig` for the type arg `i32` goes through `generateExprMir` which emits just `i32`, making the whole thing emit `i32.new()`.

Actually on re-inspection: the inner `.call` for `List(i32)` — the arg is a `type_expr` (type node) that when emitted as a MIR `type_expr` node falls through to `generateExpr(m.ast)` on the AST. But in the call_args emission path, it calls `generateCoercedExprMir(arg)` → `generateExprMir(arg)` for the type arg. A `type_expr` in MIR falls through to `passthrough` which calls `generateExpr(m.ast)`. The AST for the type arg is `type_named "i32"` which emits `i32`. So the inner call emits `i32)` — wait, but the callee is `List`, not `i32`.

Let me re-examine: the `call_expr` for `List(i32)` has callee `List` (identifier) and args `[i32]` (type args). In Orhon, `List(i32)` written as a call_expr has `arg_names = []` so it goes to the positional branch — `generateExprMir(callee_mir)` emits `List`, then `(`, then for each arg it calls `generateCoercedExprMir`. The type arg `i32` is a `type_expr` node — its `kind` maps to `.type_expr` via `astToMirKind`. In the MIR `generateExprMir` switch, there's no explicit `.type_expr` case, so it falls to... let me check.

### How `type_expr` nodes are handled in generateExprMir

```zig
// In generateExprMir switch:
// (no explicit .type_expr case)
// Falls through to the else branch which likely delegates to generateExpr(m.ast)
```

The generated `tester.zig` shows `i32.new()` not `List(i32).new()`. This means the callee MIR for the outer call's `field_access` renders the object call as `i32`, not `List(i32)`. The inner call `List(i32)` emits the type arg `i32` but the callee identifier `List` is emitted too... unless there is a special path. Let me look at what `typeToZig` returns for a type named "List" and whether there's a call expression rewrite happening.

Actually looking at the generated code more carefully: `i32.new()` — this is `{type_param}.new()`, not `{collection_name}(type_param).new()`. The simplest explanation is that codegen for `List(i32).new()` is somehow treating the **first type argument** as the callable, not the collection name. This could happen if the `call_expr` for `List(i32)` is treated as a "generic type instantiation used as a type expression" and codegen emits only the first type argument.

The collection constructor `List(i32).new()` — in the older code, this may have been a `collection_expr` node. After migration to `.new()` style, it's a `call_expr`. The codegen may have a special path that converts a `call_expr` where the callee is a collection type name into `.{}` — but that path is not triggered when the callee is inside a `field_expr` (the `.new` method call).

### Confirmed Fix Location for CGEN-01

In `generateExprMir`, in the `.call` handler (around line 2064), add detection before the general call emission:

```zig
// Collection constructor: List(T).new(), Map(K, V).new(), Set(T).new() → .{}
if (callee_is_field) {
    const method = callee_mir.name orelse "";
    if (std.mem.eql(u8, method, "new")) {
        const obj_mir = callee_mir.children[0];
        if (obj_mir.kind == .call) {
            const obj_callee = obj_mir.getCallee();
            if (obj_callee.kind == .identifier) {
                const type_name = obj_callee.name orelse "";
                if (std.mem.eql(u8, type_name, "List") or
                    std.mem.eql(u8, type_name, "Map") or
                    std.mem.eql(u8, type_name, "Set"))
                {
                    try self.emit(".{}");
                    return;
                }
            }
        }
    }
}
```

This must also be added to the AST-path `.call_expr` handler at line 1640 for the same pattern (in case any collection is still generated via the AST path).

### Cross-Module Ref-Passing Fix (CGEN-02)

The `value_to_const_ref` coercion is defined in `mir.zig` (`Coercion` enum, line 60) and already used for same-module calls. The MIR annotator's `lookupCallSig` at `mir.zig:558-588` already does cross-module DeclTable lookup.

The fix requires annotating cross-module call arguments with `value_to_const_ref` coercion. This annotation happens in `MirAnnotator.annotateCallCoercions()` (or equivalent). The same `all_decls` lookup that works for default args (`fillDefaultArgsMir`) must be applied to coercion annotation.

In codegen, `generateCoercedExprMir()` already checks `coercion == .value_to_const_ref` and emits `&`. The issue is that the coercion isn't being set on the argument MIR node for cross-module calls.

### Resolver Qualified Generic Fix (CGEN-03)

`src/resolver.zig:839-868` already validates qualified generics. Current code:
```zig
if (is_qualified and !is_known) {
    if (self.all_decls) |ad| {
        if (ad.get(module_name)) |mod_decls| {
            is_known = ... // checks structs/enums/funcs/types
        } else {
            // Module not found — trust it (Zig validates at compile time)
            is_known = true;  // ← this is the residual problem
        }
    } else {
        // No cross-module info — trust it (fallback)
        is_known = true;
    }
}
```

The fallback `is_known = true` when `all_decls` is null or the module isn't present means validation silently passes when module info is unavailable. This covers the case where topological processing hasn't reached that module yet. Whether to tighten this requires understanding whether `all_decls` is populated by the time the resolver runs. If `all_decls` is populated with all modules before resolver runs, the fallback may be removable. If not, false positives will occur.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Collection init detection | New collection node type | Detect `GenericName.new()` pattern in existing `.call` handler | Already lowered as call; adding new MIR node kind is bigger change |
| Cross-module type lookup | New lookup mechanism | Existing `all_decls` StringHashMap already threaded through codegen | The infrastructure exists at `codegen.zig:32` |
| Coercion annotation | New annotation pass | Extend existing `MirAnnotator` coercion logic | `value_to_const_ref` coercion mechanism already implemented |

---

## Common Pitfalls

### Pitfall 1: Fixing Only the MIR Path, Missing the AST Path
**What goes wrong:** The `.new()` fix added only to `generateExprMir` (MIR path). If any function still routes through `generateExpr` (AST path), collection constructors there remain broken.
**Why it happens:** Two parallel codegen paths exist (`generateExpr` and `generateExprMir`).
**How to avoid:** Apply the same collection `.new()` detection in both the `.call_expr` handler at line 1640 and the `.call` handler in `generateExprMir` at line 2064.
**Warning signs:** Some collection functions compile but others don't; inconsistent behavior depending on whether a function goes through MIR path.

### Pitfall 2: Breaking the Non-.new() Collection Path
**What goes wrong:** The old `collection_expr` node (for `List(i32)` without `.new()`) still works. Adding a detection for `.new()` must not interfere with collection_expr codegen.
**Why it happens:** Two syntax forms exist for collection construction: `List(i32).new()` (new) and possibly older `collection_expr` forms (old).
**How to avoid:** Only trigger the `.{}` emission when the method name is exactly `"new"` and the callee object is a known collection generic.
**Warning signs:** `generateCollectionExprMir` stops being called.

### Pitfall 3: Ptr.cast() Pattern Has Same Structure
**What goes wrong:** `RawPtr(i32).cast(&x)` has the same AST shape as `List(i32).new()` — generic type instantiation followed by a method call. The `.cast()` method must NOT emit `.{}`.
**Why it happens:** The fix must be specific to `new` + collection names only.
**How to avoid:** Guard the `.{}` emission with both method name check (`"new"`) AND collection name check (`List`/`Map`/`Set`).
**Warning signs:** `raw_ptr_read()` or `safe_ptr_read()` tests start failing.

### Pitfall 4: Cross-Module Coercion Annotation Ordering
**What goes wrong:** `all_decls` is populated incrementally as modules process in topological order. If module B is annotated before module A's DeclTable is populated in `all_decls`, cross-module coercions in B that call A's methods won't get annotated.
**Why it happens:** MIR annotation happens per-module before all modules are fully processed.
**How to avoid:** The coercion annotation for cross-module calls should be tolerant of missing module info — if the module isn't in `all_decls` yet, skip the coercion annotation (same behavior as today, which is the bug). The fix only applies when the module IS found in `all_decls`.

### Pitfall 5: CGEN-03 False Positives from Module Processing Order
**What goes wrong:** Tightening the qualified generic validation causes false "unknown type" errors for modules processed before their dependency.
**Why it happens:** Topological ordering processes dependencies first, but edge cases (circular-ish deps, optional imports) may cause ordering issues.
**How to avoid:** Keep the `is_known = true` fallback when the module genuinely isn't in `all_decls`. Only report an error when the module IS found in `all_decls` but the type isn't in it.

---

## Code Examples

### Collection Constructor Detection Pattern (CGEN-01)
```zig
// Source: generated tester.zig (verified error), codegen.zig structure analysis
// In generateExprMir .call handler, BEFORE the general call emission:
if (callee_is_field) {
    const method = callee_mir.name orelse "";
    if (std.mem.eql(u8, method, "new") and call_args.len == 0) {
        const obj_mir = callee_mir.children[0];
        if (obj_mir.kind == .call) {
            const inner_callee = obj_mir.getCallee();
            if (inner_callee.kind == .identifier) {
                const tname = inner_callee.name orelse "";
                const is_coll = std.mem.eql(u8, tname, "List") or
                    std.mem.eql(u8, tname, "Map") or
                    std.mem.eql(u8, tname, "Set");
                if (is_coll) {
                    try self.emit(".{}");
                    return;
                }
            }
        }
    }
}
```

### Same Detection for AST Path (CGEN-01, .call_expr handler around line 1713)
```zig
// In generateExpr .call_expr handler, before string method rewriting:
if (c.callee.* == .field_expr) {
    const method = c.callee.field_expr.field;
    const obj = c.callee.field_expr.object;
    if (std.mem.eql(u8, method, "new") and c.args.len == 0) {
        if (obj.* == .call_expr) {
            const inner_callee = obj.call_expr.callee;
            if (inner_callee.* == .identifier) {
                const tname = inner_callee.identifier;
                const is_coll = std.mem.eql(u8, tname, "List") or
                    std.mem.eql(u8, tname, "Map") or
                    std.mem.eql(u8, tname, "Set");
                if (is_coll) {
                    try self.emit(".{}");
                    return;
                }
            }
        }
    }
}
```

### Existing Coercion Check (CGEN-02 reference)
```zig
// Source: codegen.zig generateCoercedExprMir (existing)
// When a MIR node has coercion == .value_to_const_ref, codegen emits &:
fn generateCoercedExprMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
    if (m.coercion == .value_to_const_ref) {
        try self.emit("&");
    }
    try self.generateExprMir(m);
}
```

### Cross-Module Param Lookup (CGEN-02 reference)
```zig
// Source: mir.zig:558-588 — MirAnnotator.lookupCallSig (existing)
// This already handles cross-module lookup via all_decls.
// The same pattern should be used when annotating call arg coercions.
if (self.all_decls) |ad| {
    if (ad.get(module_name)) |mod_decls| {
        fsig = mod_decls.funcs.get(func_name);
    }
}
```

### Resolver Qualified Fix (CGEN-03 reference)
```zig
// Source: resolver.zig:849-867 (current code, partially correct)
if (is_qualified and !is_known) {
    if (dot_pos) |dp| {
        const module_name = g.name[0..dp];
        const type_name_part = g.name[dp + 1..];
        if (self.all_decls) |ad| {
            if (ad.get(module_name)) |mod_decls| {
                is_known = mod_decls.structs.contains(type_name_part) or
                    mod_decls.enums.contains(type_name_part) or
                    mod_decls.funcs.contains(type_name_part) or
                    mod_decls.types.contains(type_name_part);
                // is_known = false here means: module found, type NOT found → report error
                // (previously was: is_known = true when module not found → silent pass)
            }
            // If module not in all_decls: leave is_known = false → report error
            // OR keep is_known = true to avoid false positives from ordering
        }
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `collection_expr` node for `List(i32){}` syntax | `call_expr` with `.new()` method: `List(i32).new()` | v0.9.x (Ptr.cast migration) | Collection constructors now parse as regular call_exprs — codegen must detect and special-case them |
| Direct codegen `catch unreachable` | MIR-annotated coercion nodes | v0.9.5+ | Coercions are annotations on MIR nodes, not ad-hoc codegen logic |

---

## Open Questions

1. **Does `generateCollectionExprMir` still get called for any collection syntax?**
   - What we know: `collection_expr` → `MirKind.collection` → `generateCollectionExprMir` emits `.{}`
   - What's unclear: Whether any Orhon syntax still produces `collection_expr` AST nodes, or if ALL collection constructors now go through `call_expr`
   - Recommendation: Check `src/peg/builder.zig` for `collection_expr` production. If it's dead code, the fix still needs to be in the call path. If it's still used, the fix is needed only in the call path for `.new()`.

2. **Are there other `.new()` calls that should NOT become `.{}`?**
   - What we know: `Ptr(T).cast()` must NOT become `.{}`. `Counter.create()` is a struct static method, not a collection.
   - What's unclear: Whether any user-defined struct might have a `.new()` method that also uses the `Type(T).new()` pattern
   - Recommendation: Guard strictly on `List`/`Map`/`Set` names only. User-defined generic structs with `.new()` should be left to the normal call emission path.

3. **Is the CGEN-02 coercion annotation already applying in same-module calls but not cross-module?**
   - What we know: Same-module struct methods with `const &` params work (confirmed by existing passing tests). Cross-module calls don't get `value_to_const_ref` annotated.
   - What's unclear: Exactly which function in the MIR annotator handles call argument coercion, and why it doesn't cover cross-module
   - Recommendation: Before implementing CGEN-02 fix, search for `value_to_const_ref` annotation assignment in `src/mir.zig` to understand the existing annotator logic.

---

## Environment Availability

Step 2.6: SKIPPED (no external dependencies beyond the project's own compiler and Zig toolchain, both confirmed present from prior phases)

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in test blocks + bash integration tests |
| Config file | `build.zig` (test step defined) |
| Quick run command | `bash test/01_unit.sh` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CGEN-01 | Tester module compiles | integration | `bash test/09_language.sh` | YES |
| CGEN-01 | 100 runtime tests pass | integration | `bash test/10_runtime.sh` | YES |
| CGEN-02 | Cross-module `&` ref-passing | integration | `bash test/09_language.sh` (tester uses same-module, not cross-module for this) | YES (needs fixture) |
| CGEN-03 | Qualified generic error at Orhon level | integration (negative) | `bash test/11_errors.sh` | needs fixture |

### Sampling Rate
- **Per task commit:** `bash test/01_unit.sh && bash test/02_build.sh`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] No missing test files — existing test infrastructure covers all phase requirements
- [ ] CGEN-02 may need a new `test/fixtures/` file if the tester module doesn't exercise cross-module `const &` params. Review tester_main.orh to confirm.
- [ ] CGEN-03 needs an `11_errors.sh` fixture testing `module.Nonexistent(T)` produces an Orhon-level error.

---

## Project Constraints (from CLAUDE.md)

- All compiler code is Zig 0.15.2+ — no new dependencies
- Recursive functions need `anyerror!` return type (not just `!`)
- Reporter owns message strings — always `defer allocator.free(msg)` after `report()`
- `./testall.sh` is the gate — 11 test stages must pass
- No hacky workarounds — clean fixes only
- Changes must not break existing `.orh` programs or the example module
- Tests in same file as code (Zig `test` blocks)

---

## Sources

### Primary (HIGH confidence)
- Direct inspection of generated `tester.zig` at `/tmp/comptest_phase4/.orh-cache/generated/tester.zig` — confirmed all 9 error lines
- `src/codegen.zig` lines 2064-2194 (`.call` MIR handler) — confirmed normal call emission path
- `src/codegen.zig` lines 1640-1771 (AST-path `.call_expr` handler) — confirmed parallel path
- `src/codegen.zig` lines 3586-3653 (`typeToZig` for `.type_generic`) — confirmed collection prefix logic
- `src/mir.zig` lines 762-811 (`MirKind` enum, all node kinds) — confirmed `.collection` kind exists
- `src/resolver.zig` lines 839-868 — confirmed current qualified generic validation logic
- `src/mir.zig` lines 558-588 (`lookupCallSig`) — confirmed cross-module DeclTable lookup exists

### Secondary (MEDIUM confidence)
- `docs/TODO.md` BUG-01/BUG-02 descriptions — aligned with code evidence
- `.planning/codebase/CONCERNS.md` — aligned with code evidence

---

## Metadata

**Confidence breakdown:**
- Root cause of CGEN-01: HIGH — directly observed in generated output + traced through codegen
- Fix approach for CGEN-01: HIGH — pattern is clear, location is precise
- Root cause of CGEN-02: HIGH — confirmed in CONCERNS.md + code review
- Fix approach for CGEN-02: MEDIUM — the MIR annotation path for cross-module coercions needs verification before exact line numbers confirmed
- Root cause/fix for CGEN-03: HIGH — code examined directly, logic is clear

**Research date:** 2026-03-25
**Valid until:** Indefinite (internal codebase, no external dependency staleness)
