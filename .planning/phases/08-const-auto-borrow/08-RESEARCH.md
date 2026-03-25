# Phase 8: Const Auto-Borrow — Research

**Researched:** 2026-03-25
**Domain:** Orhon MIR annotator, ownership checker, codegen — calling convention for const non-primitives
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**D-01:** Keep `is_const` flag on `VarState` but change its meaning: const values are never marked `.moved` AND trigger `value_to_const_ref` coercion at call sites.

**D-02:** Line 368 in ownership.zig — the `!state.is_const` skip stays unchanged. The real change is in MIR/codegen.

**D-03:** `copy()` on a const value still works — explicitly creates an owned copy, bypassing auto-borrow.

**D-04:** In `annotateCallCoercions` (mir.zig), when an argument is a const non-primitive identifier being passed to a by-value parameter, annotate with `value_to_const_ref` coercion.

**D-05:** The MIR annotator needs to know which arguments are `const` — requires checking the variable's declaration (const_decl vs var_decl) or ownership checker's `is_const` flag.

**D-06:** ONLY at function call sites. Assignment (`var b = const_a`) still behaves as before.

**D-07:** `generateCoercedExprMir` already handles `value_to_const_ref` by emitting `&expr`. No codegen changes expected.

**D-08:** The new behavior extends this to ALL non-primitive const arguments, even when the parameter type is `T` (by-value).

**D-09:** Primitives are unaffected — always copy regardless of const/var.

**D-10:** `String` is a primitive (cheap 16-byte copy) — no auto-borrow needed.

**D-11:** `copy(const_val)` must still produce an owned value, not a borrow.

### Claude's Discretion

- How to propagate const-ness from ownership checker to MIR annotator (shared data structure or re-derive from AST).
- Whether to add a unit test for const auto-borrow in MIR or ownership.
- Exact implementation of the "is this argument a const identifier" check in MIR.

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.

</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CBOR-01 | `const` non-primitive values auto-borrow as `const &` when passed by value — no silent deep copies | Requires MIR annotator changes + function signature changes; see critical finding below |
| CBOR-02 | Explicit `copy()` still works for owned copies of `const` values | `copy()` in codegen emits the inner expression directly — no `&`. Ownership checker already treats `copy()` as borrow (line 453-455). No change needed. |
| CBOR-03 | `var` non-primitive values still move on by-value pass (unchanged) | Ownership checker already marks var identifiers as `.moved`. No change needed. |

</phase_requirements>

---

## Summary

Phase 8 implements const auto-borrow: when a `const` non-primitive variable is passed to a function expecting a by-value `T` parameter, the compiler transparently passes a `*const T` reference instead of copying. This avoids silent deep copies while keeping the user code clean.

The existing pipeline already has all infrastructure for `value_to_const_ref` coercion — it is currently used when a caller passes a plain value to an explicit `const &T` parameter. The change extends this to also apply when the **caller's variable** is `const`, regardless of the parameter's declared type.

**Critical finding:** Zig does NOT accept `&value` where `T` is expected. Verified by compilation test: `expected type 'T', found pointer`. This means D-08 as stated requires that the **Zig function signature also change to `*const T`** when the compiler decides to pass by reference. Two concrete strategies exist; see Architecture Patterns below.

**Primary recommendation:** Use Strategy B (constituent-only approach) — track a `const_args` set in the MirAnnotator keyed on variable name, and only apply coercion when the parameter type is `T` by value. Simultaneously change the Zig function signature for those parameters to `*const T`. This is sound and requires changes in two places: `annotateCallCoercions` (MIR) and `generateFuncMir` (codegen), but no cross-module coordination is needed.

---

## Standard Stack

No new libraries. All implementation uses existing Orhon compiler infrastructure.

| Component | Location | Current Role | Change Required |
|-----------|----------|--------------|-----------------|
| `MirAnnotator` | `src/mir.zig` | Annotates call coercions | Add const-arg detection |
| `annotateCallCoercions` | `src/mir.zig:437` | Compares arg types with param types | Extend to detect const identifiers |
| `generateCoercedExprMir` | `src/codegen.zig:2456` | Emits `&` for `value_to_const_ref` | No change needed |
| `generateFuncMir` | `src/codegen.zig:~560` | Generates Zig function signature | Must emit `*const T` for by-value non-primitive params that receive const args |
| `OwnershipScope::VarState` | `src/ownership.zig:15` | Tracks `is_const` per variable | Existing field — no change |
| `DeclTable::VarSig` | `src/declarations.zig:60` | Stores `is_const` for module-level vars | Existing field — no change |

---

## Architecture Patterns

### Critical: Zig Type System Constraint

Confirmed by live Zig compilation test (Zig 0.15 installed):

```
// Zig REJECTS this:
fn process(v: Vec2) f32 { ... }
const config = Vec2{...};
_ = process(&config);  // error: expected type 'Vec2', found pointer
```

The MIR annotator can annotate a const arg with `value_to_const_ref` and codegen will emit `&config`. But if the Zig function signature says `v: Vec2`, this is a hard compile error. Therefore the function signature must also change to `v: *const Vec2`.

Confirmed also:
- `*T` coerces to `*const T` in Zig (so `var` args work with `&mutable_val` too)
- Zig auto-derefs pointer field access: `v.x` works for both `Vec2` and `*const Vec2`

---

### Strategy A: Universal non-primitive by-ref (NOT recommended)

Change ALL non-primitive by-value Zig function parameters to `*const T` and emit `&arg` for all callers. Simple to reason about, but:
- Breaks internal parameter copy semantics (`var copy = param` must become `var copy = param.*`)
- Affects `var` callers too (they'd all pass `&mutable_val`)
- Large blast radius — touches every struct parameter in the codebase
- Requires body-level changes for any code that treats a param as an owned copy

**Not recommended** for this phase.

---

### Strategy B: Caller-side const detection with per-call signature tracking (RECOMMENDED)

Apply `value_to_const_ref` coercion **only** when the caller's argument is a `const` identifier AND the parameter is declared by-value. Simultaneously emit `*const T` in the function signature for those parameters.

**Problem:** A function doesn't know at declaration time whether all its callers will pass `const` or `var`. A single function might be called from both:
```
const c: Config = ...
var m: Config = ...
func doWork(cfg: Config) void { ... }
doWork(c)   // would want *const T at call site
doWork(m)   // would want T at call site (or *const T if var can coerce)
```

**Solution:** Since `*T` coerces to `*const T` in Zig, we can safely change the function signature to `*const T` for ALL non-primitive by-value params, and emit `&arg` for ALL non-primitive by-value call sites (both const and var). This is equivalent to Strategy A but WITHOUT changing the function body (field access still works via auto-deref, and explicit copy `var x = param.*` is only needed if the user mutates the param copy — which is rare and can be handled).

Wait — the concern with Strategy A is internal mutation. Let me think: does Orhon allow reassigning a by-value parameter inside a function body? If yes, that would break with `*const T`.

Looking at `reassigned_vars` tracking: yes, Zig uses `var` for params that are reassigned. But reassigning a by-value param (e.g., `param = new_val`) is distinct from calling methods on it. If we change the Zig param to `*const T`, reassignment is impossible (it's const). But in Orhon, you can't reassign a by-value parameter anyway — ownership rules prevent it (var params would be moved on reassignment, const params never moved).

**Refined Strategy B:** Apply the approach only where there is no semantic ambiguity:
1. When a `const` identifier is passed to a by-value non-primitive parameter:
   - Mark the arg with `value_to_const_ref` in MIR
   - Emit `&arg` at call site (existing codegen handles this)
   - Change the function's parameter type in Zig to `*const T`
2. When a `var` identifier is passed to the same parameter:
   - Also emit `&arg` (because the param is now `*const T` due to step 1)
   - `*T` coerces to `*const T` so this is valid

The challenge is that the function signature must be decided at function codegen time, but the caller const-ness is only known at call site codegen time. This creates a chicken-and-egg problem.

**Pragmatic resolution:** Track which parameters of which functions are "const-borrows eligible" in the MIR node for the function declaration (new `const_params` set), populated during `annotateCallCoercions` when a const arg is detected. Then `generateFuncMir` reads this and emits `*const T` for those params.

However, this requires a two-pass approach or revisiting call sites.

**Simplest working approach (recommended for this phase):**

Re-derive const-ness at `annotateCallCoercions` by looking up the AST node of the argument. If the argument is an `.identifier`, look up whether its declaration was a `const_decl`. The `var_types` map in MirAnnotator currently stores `NodeInfo` for variables (keyed by name), but does NOT track `is_const`. We need to add a separate `const_vars: std.StringHashMapUnmanaged(void)` set to MirAnnotator, populated when processing `const_decl` nodes.

For the function signature problem, use a `const_borrow_params: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void))` — mapping function name → set of param names that need `*const T`. This is populated in `annotateCallCoercions` and consumed in `generateFuncMir`.

**OR simpler:** Use a `const_ref_funcs: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(usize, void))` map — function name → set of param indices. Populated during annotation, consumed during codegen.

---

### Recommended Project Structure (no change)

```
src/
├── mir.zig            # Add const_vars + const_ref_params tracking to MirAnnotator
├── codegen.zig        # Read const_ref_params in generateFuncMir to emit *const T
├── ownership.zig      # No change (D-02 confirmed)
└── declarations.zig   # No change (VarSig.is_const already exists)
```

---

### Pattern 1: Tracking const variable names in MirAnnotator

The MirAnnotator processes `const_decl` nodes (line 242 of mir.zig). Currently it stores `NodeInfo` in `var_types` but does NOT track whether the variable was `const` vs `var`. Add a parallel set:

```zig
// In MirAnnotator struct (src/mir.zig ~line 162):
const_vars: std.StringHashMapUnmanaged(void) = .{},
```

Populate it in `annotateNode` when processing `const_decl`:
```zig
.const_decl => |v| {
    // ... existing logic ...
    try self.const_vars.put(self.allocator, v.name, {});
},
```

This lets `annotateCallCoercions` check `self.const_vars.contains(name)` to detect const args.

---

### Pattern 2: Tracking which params need *const T

During `annotateCallCoercions`, when a const arg is detected for a by-value non-primitive param:
1. Mark the arg node with `value_to_const_ref` (existing mechanism)
2. Record the (function_name, param_index) pair as needing `*const T` in Zig output

```zig
// In MirAnnotator struct (src/mir.zig):
const_ref_params: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .{},
```

In `annotateCallCoercions`:
```zig
if (arg.* == .identifier) {
    const name = arg.identifier;
    if (self.const_vars.contains(name)) {
        const arg_type = self.lookupType(arg) orelse continue;
        if (!isPrimitiveType(arg_type)) {
            // Mark call arg with coercion
            try self.node_map.put(self.allocator, arg, .{
                .resolved_type = arg_type,
                .type_class = classifyType(arg_type),
                .coercion = .value_to_const_ref,
            });
            // Record that this param needs *const T in the function sig
            try self.recordConstRefParam(func_name, param_index);
        }
    }
}
```

In `generateFuncMir`:
```zig
// When emitting param type, check if it should be *const T:
if (self.mir_annotator.const_ref_params.contains(func_name)) {
    // Check if this param index is in the set
    // If so, emit "*const {type}" instead of "{type}"
}
```

---

### Anti-Patterns to Avoid

- **Applying coercion to non-identifier arguments:** Only identifiers can be looked up in `const_vars`. Struct literals, function calls, etc. are not const variable references.
- **Applying coercion to primitive types:** Check `classifyType(arg_type) != .plain` or use `builtins.isPrimitiveName` — but `String` is `.string` which is also primitive. Use the same primitive check as ownership.zig (line 220).
- **Double-borrowing when forwarding a const param:** If a function param is already `*const T` (because it was changed), and it gets passed to another function, adding `&` again would produce `**const T`. Must check that the caller's variable is NOT a function parameter already typed as `*const T`.
- **Cross-module calls:** Functions defined in other modules may need signature updates too. Consider module-local scope for phase 8 (only handle same-module calls initially, or defer cross-module).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Const-ness detection | Custom AST scan | `const_vars` set in MirAnnotator | Direct O(1) lookup; AST scan adds complexity |
| Type primitiveness check | Custom type check | `builtins.isPrimitiveName` + `builtins.isValueType` | Already used in ownership.zig line 220 |
| `value_to_const_ref` emission | New codegen branch | Existing `generateCoercedExprMir` at line 2481 | Already emits `&` correctly |
| Param type override | Full type re-resolution | `const_ref_params` map | Only need to know which params need `*const T` |

---

## Common Pitfalls

### Pitfall 1: D-08 Requires Function Signature Change
**What goes wrong:** Annotating a const arg with `value_to_const_ref` and emitting `&val` at the call site, but the Zig function signature still says `T` — Zig compilation fails.
**Why it happens:** D-08 assumes the calling convention change is invisible, but Zig enforces type safety at the call site.
**How to avoid:** Every time `value_to_const_ref` is applied to a call arg, also record that the corresponding function parameter needs `*const T` in the Zig signature.
**Warning signs:** Zig compile errors like `expected type 'T', found pointer` in generated code.

### Pitfall 2: `var` Callers of an Updated Function
**What goes wrong:** Function `f(x: Config)` gets changed to `f(x: *const Config)` because one caller has `const c: Config`. Another caller has `var m: Config`. The `var` caller still emits `m` (no coercion), but now Zig expects `*const Config`.
**Why it happens:** Coercion is only applied to `const` args, but the function signature change affects all callers.
**How to avoid:** When `const_ref_params` records that a function param needs `*const T`, also apply a `value_to_const_ref` annotation to `var` callers of the same function/param. OR always emit `&arg` for non-primitive by-value args regardless of const/var.
**Warning signs:** Zig compile errors `expected type '*const T', found T` for `var` callers.

### Pitfall 3: Double-Borrow on Forwarded Params
**What goes wrong:** Function `a(x: Config)` receives x as `*const Config`, then calls `b(x)` where b also takes `Config` by value. If x is in `const_vars` for function a's body, it would get another `&` applied, producing `**const Config`.
**Why it happens:** The `const_vars` set in MirAnnotator doesn't distinguish between "declared const" and "received-as-const-ref".
**How to avoid:** Track function parameters separately from `const_decl` variables. Parameters received as `*const T` should NOT be annotated with `value_to_const_ref` when forwarded — they're already references.
**Warning signs:** Generated Zig with `&&variable`.

### Pitfall 4: copy() Bypass
**What goes wrong:** `copy(const_val)` gets the const arg inside `copy()` annotated with `value_to_const_ref`, emitting `&const_val` inside the copy expression.
**Why it happens:** The compiler sees `const_val` as a const identifier and annotates it.
**How to avoid:** The `copy()` compiler function in codegen (line 3257) directly calls `generateExprMir(args[0])` — it does NOT call `generateCoercedExprMir`. So even if the arg is annotated with `value_to_const_ref`, copy() will ignore it. **This is already safe** — verify this is the case.
**Warning signs:** `copy(x)` generating `copy(&x)` in Zig output.

### Pitfall 5: Cross-Module Calls
**What goes wrong:** `annotateCallCoercions` calls `resolveCallSig`, which already supports cross-module lookup. But `const_ref_params` only records data for the local module. Cross-module function signatures can't be patched from the caller's module.
**Why it happens:** Function signatures are generated per-module.
**How to avoid:** For phase 8, limit const auto-borrow to same-module calls only. Cross-module is a deferred concern. OR document that Orhon programs using cross-module const passing need explicit `const &T` parameters (the existing mechanism).
**Warning signs:** Cross-module struct-passing calls failing Zig compilation.

---

## Code Examples

### How value_to_const_ref currently works (explicit const & param)

```zig
// Source: src/mir.zig:532-538
// Value → const ref (T → const &T)
if (dst == .ptr) {
    if (std.mem.eql(u8, dst.ptr.kind, "const &")) {
        if (typesMatch(src, dst.ptr.elem.*)) {
            return .{ .kind = .value_to_const_ref };
        }
    }
}
```

```zig
// Source: src/codegen.zig:2481-2484
.value_to_const_ref => {
    // T → *const T: take address for const & parameter passing
    try self.emit("&");
    try self.generateExprMir(m);
},
```

### How annotateCallCoercions currently works

```zig
// Source: src/mir.zig:437-452
fn annotateCallCoercions(self: *MirAnnotator, c: parser.CallExpr) !void {
    const sig = self.resolveCallSig(c) orelse return;
    const param_count = @min(c.args.len, sig.params.len);
    for (c.args[0..param_count], sig.params[0..param_count]) |arg, param| {
        const arg_type = self.lookupType(arg) orelse continue;
        const coercion = detectCoercion(arg_type, param.type_);
        if (coercion.kind) |kind| {
            try self.node_map.put(self.allocator, arg, .{
                .resolved_type = arg_type,
                .type_class = classifyType(arg_type),
                .coercion = kind,
                .coerce_tag = coercion.tag,
            });
        }
    }
}
```

The new logic must bypass `detectCoercion` (which compares types) and directly annotate the arg when it is a const identifier AND the param type is by-value non-primitive.

### VarState.is_const usage in ownership.zig

```zig
// Source: src/ownership.zig:368
if (!is_borrow and !state.is_primitive and !state.is_const and state.state == .owned) {
    _ = scope.setState(name, .moved);
}
```

This is why const values are never marked `.moved`. The `is_const` flag lives in `OwnershipScope` (runtime scope), not in `DeclTable.vars`. However, `DeclTable.VarSig` also has `is_const: bool` for module-level declarations.

### Detecting const-ness in MirAnnotator

The MirAnnotator has `var_types: std.StringHashMapUnmanaged(NodeInfo)` which maps variable name → NodeInfo. However NodeInfo contains only `resolved_type`, `type_class`, and `coercion` — NOT `is_const`.

The AST does carry this information: when annotating `const_decl` nodes vs `var_decl` nodes, the annotator already distinguishes them (line 242: `.var_decl, .const_decl => |v|`). We can add a `const_vars: std.StringHashMapUnmanaged(void)` to MirAnnotator and populate it when processing `const_decl` nodes.

The ownership checker's `is_const` is also available but it runs before MIR. To propagate this data, we could either:
- Option A (AST re-derive): Add `const_vars` to MirAnnotator populated from `const_decl` processing. Simple, self-contained.
- Option B (ownership data): Pass ownership scope or `const_vars` set from ownership checker to MirAnnotator. Adds coupling.

**Option A is the right choice** — re-deriving from the AST is clean and doesn't introduce coupling.

### copy() behavior (CBOR-02 verified safe)

```zig
// Source: src/codegen.zig:3257-3258
} else if (std.mem.eql(u8, cf_name, "copy")) {
    if (args.len > 0) try self.generateExprMir(args[0]);
```

`copy()` calls `generateExprMir` directly (not `generateCoercedExprMir`). So even if the inner arg node has a `value_to_const_ref` annotation, `copy(const_val)` will emit just `const_val` — the annotation is ignored. CBOR-02 is safe without any changes.

---

## State of the Art

| Old Behavior | New Behavior | Notes |
|--------------|--------------|-------|
| `const` struct passed by value → silent copy | `const` struct passed by `*const T` ref → no copy | Only applies at call sites (D-06) |
| `var` struct passed by value → move | `var` struct passed by value → still move | CBOR-03 unchanged |
| `const &T` param → value_to_const_ref applied (existing) | Same plus: by-value `T` param also gets `*const T` if caller has const arg | Extends existing mechanism |

---

## Open Questions

1. **How to handle var callers of a function that has been promoted to *const T**
   - What we know: `*T` coerces to `*const T` in Zig. So emitting `&var_val` where `*const T` is expected works.
   - What's unclear: Should we apply `value_to_const_ref` coercion to `var` callers too? Or make this a uniform transform (all non-primitive by-value args become `&arg`)?
   - Recommendation: Apply `value_to_const_ref` to ALL non-primitive by-value args (const and var alike) once we decide a function param should be `*const T`. Track this in `const_ref_params`. The planner should decide: do we apply coercion only to const callers and handle var callers separately, or uniformly?

2. **Cross-module function signature mismatches**
   - What we know: `resolveCallSig` supports cross-module lookup. But signature changes are per-module.
   - What's unclear: If module A defines `func f(x: Config)` and module B passes `const c: Config` to it, module A generates the Zig sig without knowing about B's const usage.
   - Recommendation: Limit phase 8 to same-module const args only. Cross-module is a deferred concern. Document this limitation.

3. **Function parameters received as *const T being re-forwarded**
   - What we know: If `f(x: Config)` becomes `f(x: *const Config)`, then inside f, `x` is `*const Config`. If f calls `g(x)` where g takes `Config`, we'd annotate x with `value_to_const_ref` again — wrong.
   - What's unclear: How does the MirAnnotator know `x` came in as `*const Config`?
   - Recommendation: Add function parameters to a `param_names: std.StringHashMapUnmanaged(void)` set (separate from `const_vars`) and skip `value_to_const_ref` for those.

---

## Environment Availability

Step 2.6: No new external dependencies. All implementation is in Zig source.

Verified: `zig build` works, test infrastructure in place, `./testall.sh` is the gate.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in test blocks + shell test runners |
| Config file | `build.zig` (test step) |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CBOR-01 | `const` struct auto-borrows as `const &` at call site | unit (mir.zig) | `zig build test` | ❌ Wave 0 |
| CBOR-01 | Generated Zig uses `*const T` param for const-arg functions | integration (09_language) | `./testall.sh` | ❌ Wave 0 (fixture needed) |
| CBOR-02 | `copy(const_val)` produces owned copy, not borrow | unit (codegen/mir) | `zig build test` | ❌ Wave 0 |
| CBOR-03 | `var` values still move on by-value pass | unit (ownership.zig) | `zig build test` | ✅ (existing test at line 1022) |

### Sampling Rate
- **Per task commit:** `zig build test`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `src/mir.zig` — add unit test for const-arg `value_to_const_ref` annotation
- [ ] `src/mir.zig` — add unit test for const_vars tracking
- [ ] `test/fixtures/tester.orh` — add test function with const struct param + const caller
- [ ] `test/fixtures/tester_main.orh` — add test call for the new fixture function

---

## Sources

### Primary (HIGH confidence)
- Direct source code inspection: `src/ownership.zig`, `src/mir.zig`, `src/codegen.zig`, `src/declarations.zig`
- Live Zig compilation tests — verified behavior of `*const T`, `*T → *const T` coercion, field auto-deref

### Secondary (MEDIUM confidence)
- `test/fixtures/tester.orh` — existing test patterns for `const &` parameters
- `docs/09-memory.md` — already-updated language spec for const auto-borrow

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new libraries, all existing infrastructure
- Architecture: HIGH — verified Zig type system behavior directly
- Pitfalls: HIGH — confirmed by live Zig compilation tests; pitfall 1 and 2 are verified failures

**Research date:** 2026-03-25
**Valid until:** Stable (no external dependencies; all verified against codebase)
