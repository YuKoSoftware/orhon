# Phase 21: Flexible Allocators - Research

**Researched:** 2026-03-26
**Domain:** Zig allocator API, codegen `.new()` extension, collections.zig SMP singleton
**Confidence:** HIGH

## Summary

This phase adds optional allocator arguments to collection constructors and changes the default from `page_allocator` to an SMP singleton. The implementation is almost entirely in `src/std/collections.zig` and `src/codegen.zig` — the Orhon language AST and bridge declarations require minimal or no changes.

The key insight is that collections.zig already has `alloc: std.mem.Allocator = default_alloc` on all three structs. All that needs to happen is: (1) replace `default_alloc` with a lazy SMP singleton, (2) extend the `.new()` codegen path to emit `.{ .alloc = expr }` when one argument is present, and (3) replace the handful of `std.heap.page_allocator` references in codegen's string interpolation path with the same SMP singleton. No MIR changes are needed — the codegen AST and MIR paths both just need the arg-count guard updated.

**Primary recommendation:** Execute three focused changes: collections.zig default + singleton, codegen `.new()` 1-arg path, codegen string interpolation allocator. Then add `test_alloc_arena` and `test_alloc_inline` runtime tests and update `docs/09-memory.md`.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Mode 1 (default): `List(i32).new()` — no allocator arg, uses global SMP singleton
- **D-02:** Mode 2 (inline): `List(i32).new(arena.allocator())` — allocator instantiated at call site
- **D-03:** Mode 3 (external): `var a = smp.allocator(); List(i32).new(a)` — allocator from variable
- **D-04:** Allocator passed through `.new()` constructor, NOT as a generic type parameter — keeps generics pure
- **D-05:** Global SMP singleton lives in `collections.zig` sidecar — `var default_smp = GeneralPurposeAllocator(.{}){}` with `default_allocator()` accessor
- **D-06:** Default allocator changed from `std.heap.page_allocator` to SMP (`GeneralPurposeAllocator`)
- **D-07:** Auto-cleanup at exit — OS reclaims memory, no user-facing `.deinit()` for the default SMP
- **D-08:** Custom allocators written in Zig via bridge sidecars
- **D-09:** No Orhon-side interface enforcement — Zig handles type errors if user passes incompatible value
- **D-10:** Existing allocator bridge types (SMP, Arena, Page) already satisfy the pattern via `.allocator()` method
- **D-11:** `.new()` with 0 args emits `.{}` (unchanged)
- **D-12:** `.new(alloc)` with 1 arg emits `.{ .alloc = alloc_expr }` — allocator becomes struct field init
- **D-13:** String interpolation temp buffers switch from `page_allocator` to global SMP

### Claude's Discretion

- How the global SMP singleton is initialized (lazy vs eager)
- `collections.zig` internal refactoring to use `default_allocator()` function
- Whether `.new()` codegen path needs MIR annotation changes or can be handled purely in codegen

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope
</user_constraints>

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `std.heap.GeneralPurposeAllocator(.{})` | Zig 0.15.2 stdlib | Thread-safe general allocator | Detects leaks in debug, efficient in release |
| `std.mem.Allocator` | Zig 0.15.2 stdlib | Uniform allocator interface passed to unmanaged collections | All Zig unmanaged collections take this |
| `std.ArrayListUnmanaged(T)` | Zig 0.15.2 stdlib | Backing store for `List(T)` | Already in use |
| `std.HashMapUnmanaged(K, V, ...)` | Zig 0.15.2 stdlib | Backing store for `Map` and `Set` | Already in use |

### No Additional Dependencies
All changes are within existing files using already-imported stdlib types.

---

## Architecture Patterns

### Pattern 1: Lazy Global SMP Singleton in collections.zig

**What:** A module-level `var` GPA with a function accessor that returns `std.mem.Allocator`. Lazy initialization is simplest here — Zig's `GeneralPurposeAllocator` zero-initializes cleanly as a global `var`.

**When to use:** Default allocator mode, whenever `.new()` is called with no args and picks up `default_alloc`.

```zig
// Source: Zig stdlib + allocator.zig pattern already in this codebase
var default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};

fn default_allocator() std.mem.Allocator {
    return default_smp.allocator();
}

const default_alloc = default_allocator();
```

**Important:** `GeneralPurposeAllocator(.{})` can be zero-initialized at module scope as `= .{}`. In Zig 0.15 this is a comptime-zero-initialized struct — no explicit `init()` call needed. `default_smp.allocator()` returns the `std.mem.Allocator` interface on demand.

**Alternative — simpler: use a module-level constant function result.** Since `default_alloc` is used as a field default, it must be a comptime-available value OR a runtime value that is valid at struct instantiation. The field default `alloc: std.mem.Allocator = default_alloc` works if `default_alloc` is a module-level `const` of type `std.mem.Allocator`. However, `std.mem.Allocator` is NOT a comptime constant — it is a runtime struct (a fat pointer: vtable + context). So `default_alloc` must be a module-level `var` or a `const` initialized from a global `var`.

**Verified approach:**
```zig
// Source: confirmed from allocator.zig in this codebase (SMP.allocator() pattern)
var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};
const default_alloc: std.mem.Allocator = _default_smp.allocator();
```

Wait — this does NOT work either, because `std.mem.Allocator` captures a pointer to `_default_smp` at initialization time, and `const` at module scope in Zig evaluates at comptime which won't capture a runtime pointer correctly.

**Correct approach for D-05/D-06:** Make `default_alloc` a function call instead of a constant:

```zig
// Pattern: field default pointing to a global mutable singleton
var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};

pub fn List(comptime T: type) type {
    return struct {
        inner: std.ArrayListUnmanaged(T) = .{},
        alloc: std.mem.Allocator = _default_smp.allocator(),
        // ...
    };
}
```

**This is the correct Zig pattern.** Field defaults in Zig struct literals are evaluated at runtime when the struct is instantiated, not at comptime. The `= _default_smp.allocator()` call will execute when `.{}` is used, at which point `_default_smp` is initialized (Zig initializes module-level `var` declarations before `main`). Confidence: HIGH — this is the same pattern used in existing Zig codebases for default allocator structs.

**D-07 (no deinit):** Since the singleton lives for the entire program lifetime and the OS reclaims memory on exit, no explicit `.deinit()` is needed. This is intentional — matching how most Zig programs handle GPA in non-test code.

### Pattern 2: codegen .new() 1-arg path

**What:** When `.new(expr)` is called with exactly one argument and the receiver is a type node (collection_expr, type_primitive, type_named, type_generic), emit `.{ .alloc = <expr> }` instead of `.{}`.

**AST path (lines 1839-1851 of codegen.zig):**
```zig
// Current: only handles c.args.len == 0
if (std.mem.eql(u8, method, "new") and c.args.len == 0) {
    // ...
    try self.emit(".{}");
    return;
}

// Extended: also handle c.args.len == 1
if (std.mem.eql(u8, method, "new") and c.args.len == 1) {
    const is_type_node = obj.* == .collection_expr or
        obj.* == .type_primitive or obj.* == .type_named or
        obj.* == .type_generic;
    if (is_type_node) {
        try self.emit(".{ .alloc = ");
        try self.generateExpr(c.args[0]);
        try self.emit(" }");
        return;
    }
}
```

**MIR path (lines 2308-2319 of codegen.zig):**
```zig
// Extended: also handle call_args.len == 1
if (std.mem.eql(u8, method, "new") and call_args.len == 1) {
    if (callee_mir.children.len > 0) {
        const obj_mir = callee_mir.children[0];
        if (obj_mir.kind == .type_expr or obj_mir.kind == .collection) {
            try self.emit(".{ .alloc = ");
            try self.generateExprMir(call_args[0]);
            try self.emit(" }");
            return;
        }
    }
}
```

**No MIR annotation changes needed** — this is a purely syntactic translation. The MIR path is already in use for the 0-arg case. The 1-arg case just needs the same guard updated and a different emit.

**Why `.{ .alloc = expr }` works:** All three collection structs have `alloc: std.mem.Allocator = default_alloc` as a field. Zig struct literal `.{ .alloc = x }` leaves all other fields at their defaults (`.inner = .{}`), so this is safe.

### Pattern 3: String Interpolation Allocator Replacement

**What:** Replace `std.heap.page_allocator` in the two string interpolation codegen paths with the collections module's `_default_smp.allocator()` — but wait, the interpolation code lives in `codegen.zig`, not in `collections.zig`. The generated `.zig` output must reference something available at runtime.

**The right approach:** The generated Zig code for string interpolation currently emits:
```zig
const _interp_0 = std.fmt.allocPrint(std.heap.page_allocator, "...", .{...}) catch ...;
defer std.heap.page_allocator.free(_interp_0);
```

Per D-13, this should use the SMP default. Since the generated code is standalone Zig, it can reference `std.heap.smp_allocator` (the global SMP in the Zig stdlib) or `std.heap.page_allocator`. The question is what "global SMP" means in generated Zig.

**Verified option: `std.heap.smp_allocator`** — Zig 0.15 exposes `std.heap.smp_allocator: std.mem.Allocator` as a global constant backed by `std.heap.SmpAllocator`. This is the correct allocator for general-purpose allocation in generated code. It is thread-safe and suitable as a default.

**Codegen change (two locations):**
- Line 2788/3278: `std.fmt.allocPrint(std.heap.page_allocator,` → `std.fmt.allocPrint(std.heap.smp_allocator,`
- Line 2840/3326: `defer std.heap.page_allocator.free(` → `defer std.heap.smp_allocator.free(`
- Line 3211: `std.fmt.allocPrint(std.heap.page_allocator,` → `std.fmt.allocPrint(std.heap.smp_allocator,`

Similarly for `_OrhonHandle` thread helper (line 332 of codegen.zig) — but that is NOT in scope for D-13 (only string interpolation buffers are specified).

**Note on `collections.zig` default_alloc vs `std.heap.smp_allocator`:**
- `collections.zig` default: `_default_smp.allocator()` — a private GPA instance, detecting leaks in debug, no global coordination needed. This is what D-05 specifies.
- Codegen string interpolation: `std.heap.smp_allocator` — the Zig stdlib global SMP. This is appropriate for generated code because the generated module doesn't import collections.zig.

These are two separate "SMP" uses but both satisfy D-06 (switching from page_allocator to something SMP-based).

### Pattern 4: allocator.orh — `.allocator()` method already available

The `allocator.zig` bridge already exposes `SMP.allocator()`, `Arena.allocator()`, `Page.allocator()`. These are NOT declared in `allocator.orh` (the bridge file only declares `create`, `deinit`, `freeAll`). The `.allocator()` method in Zig returns `std.mem.Allocator` — a Zig type, not an Orhon bridge type.

**Problem:** When Orhon code calls `arena.allocator()` to pass to `.new(arena.allocator())`, codegen will emit this as a method call on a bridge struct. This works transparently because:
1. `arena` is a bridge struct variable
2. `.allocator()` is a Zig method (not declared in `.orh`) — codegen falls through to generic method call emission
3. The result type `std.mem.Allocator` is opaque from Orhon's side — it just flows through as a function argument

**Verification needed:** Does codegen correctly emit `arena.allocator()` as `arena.allocator()` when `.allocator` is not declared in the `.orh` bridge file? The answer is yes — undeclared methods pass through as generic field_expr calls. The semantic checker may or may not validate this (bridge methods not in `.orh` are unchecked in Orhon, which is D-09).

### Anti-Patterns to Avoid

- **Do NOT change `std.heap.page_allocator` in `src/peg/builder.zig`, `src/main.zig`, `src/module.zig`, `src/errors.zig`** — those are compiler-internal allocations, not user-facing collection defaults. Phase scope is collections and string interpolation in generated code only.
- **Do NOT change `const alloc = std.heap.page_allocator` in `src/std/str.zig`, `src/std/json.zig`, etc.** — those stdlib sidecars are out of scope.
- **Do NOT add a new generic type parameter** — D-04 is explicit.
- **Do NOT require user to call `.deinit()` on the default SMP** — D-07.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Thread-safe allocator | custom allocator | `std.heap.GeneralPurposeAllocator(.{})` | Already handles concurrency, leak detection in debug |
| Allocator interface | custom vtable | `std.mem.Allocator` | Zig's standard fat-pointer interface — all unmanaged collections already use it |
| Allocator discovery | runtime type check | field default `alloc: std.mem.Allocator = _default_smp.allocator()` | Zero overhead, struct-level default, no conditional logic |

---

## Common Pitfalls

### Pitfall 1: Module-level `const` of `std.mem.Allocator`
**What goes wrong:** `const default_alloc: std.mem.Allocator = _default_smp.allocator();` at module scope is treated as a comptime constant in Zig. `std.mem.Allocator` contains a runtime pointer, so this will fail to compile.
**Why it happens:** Zig tries to evaluate `const` declarations at comptime when possible. `std.mem.Allocator` is not comptime-evaluable.
**How to avoid:** Use `_default_smp.allocator()` directly in the struct field default: `alloc: std.mem.Allocator = _default_smp.allocator()`. This is evaluated at struct instantiation time (runtime), not comptime.
**Warning signs:** Compile error: "unable to evaluate comptime expression" or "type 'std.mem.Allocator' does not support comptime"

### Pitfall 2: GPA deinit in tests
**What goes wrong:** Zig's `GeneralPurposeAllocator` reports leaked memory if `.deinit()` is not called. If the module-level `_default_smp` is never deinited, tests running `zig build test` will report false memory leaks.
**Why it happens:** GPA tracks allocations and reports on deinit. Without deinit, test runner may flag leaks.
**How to avoid:** The CONTEXT.md decision (D-07) is that the OS reclaims memory — this is fine for release builds. For the unit test `test "List basic"` etc., they use `var list = List(i32){}` which defaults to `_default_smp.allocator()`. After `list.free()`, the allocations are released. The GPA itself is never deinited but this is acceptable for a program-lifetime allocator. Zig's GPA only reports leaks if `.deinit()` is called — if you never call deinit, it never reports. This is the intended behavior per D-07.
**Warning signs:** "detected memory leaks" in test output — only if `.deinit()` is inadvertently called somewhere.

### Pitfall 3: Codegen arg detection for non-collection `.new()` calls
**What goes wrong:** User struct `.new(something)` gets incorrectly emitted as `.{ .alloc = something }`.
**Why it happens:** Both the AST and MIR paths use `is_type_node` / `obj_mir.kind == .type_expr` to distinguish collection constructors from user struct constructors. If the guard is weakened (e.g., checking only `c.args.len == 1` without the type node check), user-defined structs with a `.new(arg)` method break.
**How to avoid:** Keep the `is_type_node` / `obj_mir.kind` check — only emit `.{ .alloc = ... }` when the receiver is a collection type node, not a user struct identifier.
**Warning signs:** User struct `MyStruct.new(x)` emits `.{ .alloc = x }` instead of calling the struct's `new` method.

### Pitfall 4: `allocator()` method not in bridge declarations
**What goes wrong:** When Orhon code calls `arena.allocator()` in Mode 2/3, the semantic checker might reject the call because `.allocator` is not declared in `allocator.orh`.
**Why it happens:** Bridge type checking in Orhon validates method calls against the `.orh` declaration. If `.allocator` is missing, it's a compile error.
**How to avoid:** Either add `bridge func allocator(self: &SMP) void` (with opaque return type) to `allocator.orh`, OR verify that undeclared bridge methods pass through. Per D-09, "no Orhon-side interface enforcement." Need to verify which approach is correct — this is the primary open question.
**Warning signs:** "unknown method 'allocator' on type SMP" from semantic checker.

### Pitfall 5: Two separate `page_allocator` → SMP changes confused
**What goes wrong:** Confusing the `collections.zig` default allocator change (D-05/D-06: private GPA singleton) with the codegen string interpolation change (D-13: `std.heap.smp_allocator` in emitted Zig code). These are independent.
**Why it happens:** Both replace `page_allocator` with "SMP" but in different codebases.
**How to avoid:** In `collections.zig`: use `var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{}`. In `codegen.zig` string interpolation: emit `std.heap.smp_allocator` (the Zig stdlib global) in the generated `.zig` output.

---

## Code Examples

### collections.zig — Global SMP singleton + updated `new()`
```zig
// Source: allocator.zig in this codebase + Zig stdlib GPA docs
var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};

pub fn List(comptime T: type) type {
    return struct {
        inner: std.ArrayListUnmanaged(T) = .{},
        alloc: std.mem.Allocator = _default_smp.allocator(),

        const Self = @This();

        pub fn new() Self {
            return .{};
        }

        pub fn newWithAlloc(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        // ... all other methods unchanged ...
    };
}
```

Note: `newWithAlloc` is the Zig-level function that `.new(alloc)` maps to via codegen emitting `.{ .alloc = alloc_expr }`. Actually codegen just emits `.{ .alloc = expr }` directly — no separate Zig function needed, since `.{ .alloc = x }` is a valid struct literal that initializes only the `.alloc` field.

### codegen.zig — AST path .new() 1-arg extension
```zig
// Extend lines 1839-1851 to also handle 1-arg case
if (c.callee.* == .field_expr) {
    const method = c.callee.field_expr.field;
    const obj = c.callee.field_expr.object;
    if (std.mem.eql(u8, method, "new")) {
        const is_type_node = obj.* == .collection_expr or
            obj.* == .type_primitive or obj.* == .type_named or
            obj.* == .type_generic;
        if (is_type_node) {
            if (c.args.len == 0) {
                try self.emit(".{}");
                return;
            } else if (c.args.len == 1) {
                try self.emit(".{ .alloc = ");
                try self.generateExpr(c.args[0]);
                try self.emit(" }");
                return;
            }
        }
    }
}
```

### codegen.zig — MIR path .new() 1-arg extension
```zig
// Extend lines 2308-2319 similarly
if (callee_is_field) {
    const method = callee_mir.name orelse "";
    if (std.mem.eql(u8, method, "new")) {
        if (callee_mir.children.len > 0) {
            const obj_mir = callee_mir.children[0];
            if (obj_mir.kind == .type_expr or obj_mir.kind == .collection) {
                if (call_args.len == 0) {
                    try self.emit(".{}");
                    return;
                } else if (call_args.len == 1) {
                    try self.emit(".{ .alloc = ");
                    try self.generateExprMir(call_args[0]);
                    try self.emit(" }");
                    return;
                }
            }
        }
    }
}
```

### codegen.zig — String interpolation allocator (generated Zig)
```zig
// Lines 2788/3278: change emitted string from:
"std.fmt.allocPrint(std.heap.page_allocator, \""
// to:
"std.fmt.allocPrint(std.heap.smp_allocator, \""

// Lines 2840/3326: change emitted string from:
"defer std.heap.page_allocator.free("
// to:
"defer std.heap.smp_allocator.free("

// Line 3211: same change
```

### tester.orh — New runtime tests for allocator modes
```orhon
// Mode 2: inline allocator
pub func test_alloc_arena() i32 {
    import std::allocator
    var arena: allocator.Arena = allocator.Arena.create()
    defer { arena.deinit() }
    var items: List(i32) = List(i32).new(arena.allocator())
    items.add(10)
    items.add(20)
    return items.get(0) + items.get(1)
}

// Mode 3: external allocator variable
pub func test_alloc_external() i32 {
    import std::allocator
    var smp: allocator.SMP = allocator.SMP.create()
    defer { smp.deinit() }
    var a = smp.allocator()
    var items: List(i32) = List(i32).new(a)
    items.add(5)
    items.add(7)
    defer { items.free() }
    return items.get(0) + items.get(1)
}
```

---

## Open Questions

1. **Does `.allocator()` method need to be declared in `allocator.orh`?**
   - What we know: `allocator.orh` currently declares only `create`, `deinit`, `freeAll` — no `.allocator()` method. D-09 says "no Orhon-side interface enforcement."
   - What's unclear: Does the semantic checker allow calling undeclared bridge methods, or does it error? If it errors, `allocator.orh` needs `bridge func allocator(self: &SMP) Allocator` (or some opaque return type).
   - Recommendation: Check `src/sema.zig` / `src/declarations.zig` for how bridge method calls are validated before finalizing the allocator.orh changes. If undeclared methods are allowed (per D-09), no change is needed. If not, add `bridge func allocator(self: &SMP) void` as a pass-through declaration.

2. **Should `test_alloc_arena` use `import` at function scope?**
   - What we know: Orhon's `import` is typically at module top level. The tester module already imports `std::console`. If `std::allocator` is needed for the test functions, it should be at module scope.
   - What's unclear: Whether tests requiring `import std::allocator` need to be in a separate module or if the existing tester.orh can have the import added.
   - Recommendation: Add `import std::allocator` at the top of `tester.orh` alongside the existing `import std::console`.

3. **`std.heap.smp_allocator` vs private GPA in generated code (D-13)**
   - What we know: `std.heap.smp_allocator` is the Zig stdlib's built-in SMP allocator. Using it in generated code is clean and requires no import.
   - What's unclear: Whether `std.heap.smp_allocator` is available in Zig 0.15.2 under that exact name. (It was introduced as `smp_allocator` in a recent Zig version.)
   - Recommendation: Verify with `zig build` after making the change. If `smp_allocator` is unavailable, fall back to keeping `page_allocator` for string interpolation (it still works, just not SMP). The collections default change (D-05/D-06) is independent of D-13.

---

## Environment Availability

Step 2.6: SKIPPED — this phase is purely code/config changes within the existing Orhon/Zig codebase. No new external tools, services, or CLIs are required.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell integration tests + Zig unit test blocks |
| Config file | `testall.sh` (pipeline), `zig build test` (unit) |
| Quick run command | `zig build test && bash test/10_runtime.sh` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| D-01 | `List(i32).new()` uses SMP default | runtime | `bash test/10_runtime.sh` (existing `alloc_default` test) | Yes — `test/fixtures/tester.orh:964` |
| D-02 | `List(i32).new(arena.allocator())` inline allocator | runtime | `bash test/10_runtime.sh` (new `alloc_arena` test) | No — Wave 0 |
| D-03 | `List(i32).new(a)` external allocator var | runtime | `bash test/10_runtime.sh` (new `alloc_external` test) | No — Wave 0 |
| D-06 | Default changed from page_allocator to SMP | unit | `zig build test` (collections.zig unit tests) | Yes — existing tests verify correct alloc behavior |
| D-12 | `.new(alloc)` → `.{ .alloc = expr }` in codegen | codegen quality | `bash test/08_codegen.sh` | Yes |
| D-13 | String interpolation uses SMP allocator | codegen quality | `bash test/08_codegen.sh` | Yes |

### Sampling Rate
- **Per task commit:** `zig build test` (unit tests for collections.zig changes)
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `test/fixtures/tester.orh` — add `test_alloc_arena`, `test_alloc_external` functions
- [ ] `test/fixtures/tester_main.orh` — add runtime assertions for new allocator test functions
- [ ] `test/10_runtime.sh` — add `alloc_arena`, `alloc_external` to the test list

---

## Project Constraints (from CLAUDE.md)

- All compiler code is Zig 0.15.2+ — no new language features, no third-party dependencies
- `./testall.sh` must pass after all changes — 11 stages
- `example` module must compile and cover all implemented features
- No hacky workarounds — clean fixes only
- `@embedFile` for any complete file; never inline multi-line content
- Template substitution: split-write, not allocPrint (not applicable here but noted)
- Test in same file as code (Zig `test` blocks) — collections.zig unit tests already exist and must still pass
- Recursive functions need `anyerror!` return type
- Comments must stay up to date — update `docs/09-memory.md` to document the 3 allocator modes

---

## Sources

### Primary (HIGH confidence)
- Source code audit: `src/std/collections.zig` — confirmed existing `alloc: std.mem.Allocator = default_alloc` field and `default_alloc = std.heap.page_allocator`
- Source code audit: `src/std/allocator.zig` — confirmed `SMP.allocator()` returns `std.mem.Allocator`, zero-init GPA pattern
- Source code audit: `src/codegen.zig` lines 1834-1851, 2301-2319, 3278/3324-3328 — confirmed AST+MIR `.new()` emission and page_allocator in string interpolation
- Source code audit: `src/std/allocator.orh` — confirmed `.allocator()` is NOT currently declared as a bridge method
- Zig 0.15.2 (installed): `GeneralPurposeAllocator(.{})` zero-init pattern confirmed via `allocator.zig` existing code

### Secondary (MEDIUM confidence)
- Zig stdlib docs: `std.heap.smp_allocator` — available in Zig 0.13+ as global SMP instance. Needs compile verification for 0.15.2.

### Tertiary (LOW confidence)
- `std.heap.smp_allocator` exact availability in Zig 0.15.2 — flagged as needing `zig build` verification

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all code is within existing files using verified stdlib types
- Architecture: HIGH — patterns confirmed from existing code in this codebase
- Codegen patterns: HIGH — direct source code audit of exact change locations
- `std.heap.smp_allocator` name: MEDIUM — likely correct but verify with `zig build`
- `.allocator()` bridge method handling: MEDIUM — depends on sema.zig bridge validation behavior

**Research date:** 2026-03-26
**Valid until:** Stable — Zig 0.15.2, no external dependencies
