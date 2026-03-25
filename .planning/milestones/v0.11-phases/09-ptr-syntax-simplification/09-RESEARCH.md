# Phase 9: Ptr Syntax Simplification - Research

**Researched:** 2026-03-25
**Domain:** Orhon compiler — PEG grammar, builder, codegen, MIR
**Confidence:** HIGH

## Summary

Phase 9 removes the two old pointer-construction syntaxes (`Ptr(T).cast(&x)` and `Ptr(T, &x)`) and replaces them with type-directed construction: `const p: Ptr(T) = &x`. The implementation is a small, self-contained change across five files. Every site that needs updating is already known from the CONTEXT.md canonical references.

The key insight is that codegen already emits the correct Zig for each pointer kind — the coercion logic in `generatePtrExpr` / `generatePtrExprMir` moves to the declaration site and fires when the type annotation is a Ptr generic type and the value is a `borrow_expr` (or integer literal). No new Zig APIs are needed. The `warned_rawptr` flag and its warning logic stays in codegen and moves with the coercion.

**Primary recommendation:** Remove PEG rules and builder dead code first, then add the declaration-level coercion in a single helper that both `generateStmtDecl` / `generateStmtDeclMir` call. The AST-path and MIR-path need separate coercion hooks since they operate on different node types.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Remove `ptr_cast_expr` rule (line 433-434 in orhon.peg)
- **D-02:** Remove `ptr_expr` rule (line 437-438 in orhon.peg)
- **D-03:** Remove both from `primary_expr` alternatives (lines 391-392)
- **D-04:** The `&` unary operator (line 349) stays — it's how users take addresses
- **D-05:** Remove `buildPtrCastExpr` function from builder.zig (line 1354)
- **D-06:** Remove ptr_cast_expr dispatch in build function (line 177)
- **D-07:** Remove the pointer constructor detection in generic call handling (lines 1397-1406)
- **D-08:** Type-directed coercion in codegen: Ptr(T)+&expr→`&expr`, RawPtr(T)+&expr→`@as([*]T, @ptrCast(&expr))`, RawPtr(T)+int→`@as([*]T, @ptrFromInt(N))`, VolatilePtr(T)+&expr→`@as(*volatile T, @ptrCast(&expr))`, VolatilePtr(T)+int→`@as(*volatile T, @ptrFromInt(N))`
- **D-09:** Coercion is codegen-level, NOT a MIR coercion — triggers on type annotation during declaration/assignment code emission
- **D-10:** `generatePtrExpr` and `generatePtrExprMir` functions replaced by the coercion logic
- **D-11:** `test/fixtures/tester.orh` lines 692, 699, 705 — change `.cast()` to new syntax
- **D-12:** `src/templates/example/data_types.orh` lines 87, 95, 100 — update Ptr example and comments
- **D-13:** `docs/09-memory.md` — already uses new syntax (verify current)
- **D-14:** No custom migration error message needed — PEG engine's generic parse error is sufficient

### Claude's Discretion
- Whether to keep `generatePtrExpr`/`generatePtrExprMir` as dead code during transition or remove immediately
- Exact codegen location for the type-directed coercion check
- Whether RawPtr warning is emitted at parse time, codegen time, or both

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope

</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PTRS-01 | `const p: Ptr(T) = &x` creates a safe pointer via type annotation + `&` | Coercion at decl site: type annotation `Ptr(T)` + value `borrow_expr` → emit `&expr`. `typeToZig` already maps `Ptr(T)` → `*const T`. |
| PTRS-02 | `const r: RawPtr(T) = &x` creates an unsafe pointer | Coercion: `RawPtr(T)` + `borrow_expr` → `@as([*]T, @ptrCast(&expr))`. Warning logic already in `generatePtrExpr` can move here. |
| PTRS-03 | `const v: VolatilePtr(T) = 0xFF200000` creates volatile pointer from integer | Coercion: `RawPtr(T)` or `VolatilePtr(T)` + integer literal → `@as([*]T/@as(*volatile T, @ptrFromInt(N))`. |
| PTRS-04 | Old `Ptr(T).cast(&x)` and `Ptr(T, &x)` syntax removed — compile error | Remove PEG rules; parser will produce generic parse error for old syntax. |

</phase_requirements>

---

## Standard Stack

This is an internal compiler change. No external libraries are added or removed.

| Component | File | Role in Phase |
|-----------|------|--------------|
| PEG grammar | `src/orhon.peg` | Remove `ptr_cast_expr` and `ptr_expr` rules from `primary_expr` |
| PEG builder | `src/peg/builder.zig` | Remove `buildPtrCastExpr` dispatch and generic-call ptr detection |
| Parser types | `src/parser.zig` | `PtrExpr` struct and `.ptr_expr` NodeKind become unused — remove |
| MIR | `src/mir.zig` | Remove `.ptr_expr` annotation, lowering, and kind mapping |
| Codegen | `src/codegen.zig` | Remove `generatePtrExpr`/`generatePtrExprMir`, add declaration coercion |
| Resolver | `src/resolver.zig` | Remove `.ptr_expr` branch (line 674) |
| Fixtures | `test/fixtures/tester.orh` | Update 3 lines to new syntax |
| Example | `src/templates/example/data_types.orh` | Update live code and comments |

---

## Architecture Patterns

### Pattern 1: Type-Directed Coercion at Declaration Site

The coercion check is inserted in both `generateDecl` (top-level, AST path) and `generateStmtDecl` (function body, AST path), and in `generateTopLevelDeclMir` and `generateStmtDeclMir` (MIR paths). When the type annotation is a `type_generic` node with name `Ptr`, `RawPtr`, or `VolatilePtr`, and the value is a `borrow_expr` or integer literal, the specialized Zig is emitted instead of the generic expression.

**AST-path check** (both `generateDecl` and `generateStmtDecl`):
```zig
// Source: src/codegen.zig generateDecl / generateStmtDecl
if (v.type_annotation) |t| {
    if (t.* == .type_generic) {
        const name = t.type_generic.name;
        const is_ptr_kind = std.mem.eql(u8, name, "Ptr") or
                            std.mem.eql(u8, name, "RawPtr") or
                            std.mem.eql(u8, name, "VolatilePtr");
        if (is_ptr_kind) {
            try self.generatePtrCoercion(name, t.type_generic.args[0], v.value);
            return;  // or continue to semicolon
        }
    }
}
try self.generateExpr(v.value);
```

**MIR-path check** (`generateTopLevelDeclMir` and `generateStmtDeclMir`):
```zig
// Source: src/codegen.zig generateTopLevelDeclMir / generateStmtDeclMir
if (m.type_annotation) |t| {
    if (t.* == .type_generic) {
        const name = t.type_generic.name;
        const is_ptr_kind = ...;
        if (is_ptr_kind and m.value().kind == .borrow or
                            m.value().kind == .int_lit or
                            m.value().kind == .int_literal) {
            try self.generatePtrCoercionMir(name, t.type_generic.args[0], m.value());
            return;
        }
    }
}
try self.generateExprMir(m.value());
```

### Pattern 2: What the New Coercion Emits

Exactly matching the logic already in `generatePtrExpr` / `generatePtrExprMir`:

| Type Annotation | Value | Emitted Zig |
|----------------|-------|-------------|
| `Ptr(T)` | `&x` (borrow_expr) | `&x` |
| `RawPtr(T)` | `&x` (borrow_expr) | `@as([*]T, @ptrCast(&x))` |
| `RawPtr(T)` | integer literal | `@as([*]T, @ptrFromInt(N))` |
| `VolatilePtr(T)` | `&x` (borrow_expr) | `@as(*volatile T, @ptrCast(&x))` |
| `VolatilePtr(T)` | integer literal | `@as(*volatile T, @ptrFromInt(N))` |

The `warned_rawptr` flag lives in `CodeGen` struct (line 26, codegen.zig) and should continue to fire from the new coercion path.

### Pattern 3: MIR `borrow` kind vs `borrow_expr` NodeKind

In the MIR path, `borrow_expr` AST nodes lower to `MirNode` with `kind == .borrow` (mir.zig line 1615: `.borrow_expr => .borrow`). The existing `generatePtrExprMir` already checks `addr_arg.kind == .borrow` (line 3210). The new coercion uses the same check on `m.value().kind`.

### Pattern 4: Removal of ptr_expr from all switch statements

The following switch arms must be removed after the PEG/builder/parser cleanup:
- `resolver.zig` line 674: `.ptr_expr =>` branch
- `mir.zig` line 424: `.ptr_expr =>` annotation branch
- `mir.zig` line 1178: `.ptr_expr =>` lowering branch
- `mir.zig` line 1577: `.ptr_expr =>` name extraction
- `mir.zig` line 1618: `.ptr_expr => .ptr_expr` kind mapping
- `codegen.zig` line 1965: `.ptr_expr =>` AST-path expression dispatch
- `codegen.zig` line 2444: `.ptr_expr =>` MIR-path expression dispatch

### Recommended Removal Order

1. Update fixtures and example files first (makes old syntax a test failure)
2. Remove PEG rules from `orhon.peg`
3. Remove builder code from `builder.zig`
4. Remove `PtrExpr` struct and `.ptr_expr` NodeKind from `parser.zig`
5. Remove `.ptr_expr` arms from `resolver.zig` and `mir.zig`
6. Add coercion logic to `codegen.zig` declaration sites
7. Remove `generatePtrExpr` and `generatePtrExprMir` from `codegen.zig`
8. Run `./testall.sh`

### Anti-Patterns to Avoid

- **Don't add coercion to `generateExpr` / `generateExprMir` directly.** The coercion only fires when a declaration's type annotation declares a Ptr kind. Putting it in the expression dispatch would break uses like passing a pointer by value.
- **Don't leave the type_generic ptr detection in `buildGenericType`.** Lines 1397-1411 in builder.zig detect `Ptr(T, &x)` and produce a `ptr_expr` node. This path produces the nodes the phase is removing. It must be deleted even though the function name says "generic type."
- **Don't treat the AST and MIR paths as one path.** The codebase runs either AST-path or MIR-path codegen depending on whether MIR annotations are available. Both paths need the coercion independently.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Checking if type_annotation is Ptr/RawPtr/VolatilePtr | Custom type string parsing | `t.* == .type_generic` + name comparison — same pattern as `typeToZig` (line 3801-3818) |
| Emitting `@as([*]T, ...)` | New allocation or format helper | `self.emitFmt` + `self.typeToZig(t.type_generic.args[0])` — both already used in `generatePtrExpr` |
| Warning on RawPtr usage | New warning system | `self.warned_rawptr` flag + `std.debug.print` — already in codegen, just move to new coercion helper |

---

## Common Pitfalls

### Pitfall 1: The `buildGenericType` ptr detection at lines 1397-1406

**What goes wrong:** Forgetting to remove the two-arg generic type detection in `buildGenericType`. This is the code path for `Ptr(T, &x)` classic syntax. It's inside `buildGenericType`, not `buildPtrCastExpr`, so it's easy to miss when removing only the named function.

**Why it happens:** The `ptr_cast_expr` PEG rule has its own builder (`buildPtrCastExpr`), but the `ptr_expr` PEG rule is handled by the generic type builder (lines 1397-1411 in builder.zig) because `Ptr(T, &x)` looks like a generic type call with two args.

**How to avoid:** Delete lines 1397-1411 of builder.zig (the `is_ptr` check and two-arg special case) when removing D-07. Not just the `buildPtrCastExpr` function.

### Pitfall 2: `borrow_expr` vs `borrow` kind confusion

**What goes wrong:** Checking `v.value.* == .borrow_expr` in the AST path but checking `m.value().kind == .borrow_expr` in the MIR path. The MIR kind is `.borrow`, not `.borrow_expr`.

**Why it happens:** AST uses the `NodeKind` enum (`.borrow_expr`), but MirNode uses `MirKind` (`.borrow`) which is the lowered form. These are different enums.

**How to avoid:** In AST path check `v.value.* == .borrow_expr`. In MIR path check `m.value().kind == .borrow`.

### Pitfall 3: Integer literal kind in MIR path

**What goes wrong:** The integer literal might be `.int_lit` or `.int_literal` in MIR — they map differently depending on where the node came from.

**Why it happens:** `astToMirKind` in mir.zig maps `.int_literal => .int_lit`. So in MIR path use `.int_lit`, not `.int_literal`.

**How to avoid:** Check `m.value().kind == .int_lit` in MIR path. In AST path check `v.value.* == .int_literal`.

### Pitfall 4: Forgetting assignment statements

**What goes wrong:** Only updating `const_decl` and `var_decl` but not assignment statements. If someone writes `p = &x` where `p: Ptr(T)` was declared earlier, the assignment path could also need coercion.

**Why it happens:** The CONTEXT.md decisions focus on declarations but assignment codegen also emits values.

**How to avoid:** Check if `tester.orh` or other fixtures have assignment re-assignment of Ptr vars. Looking at lines 692, 699, 705 in tester.orh, all are `const` declarations with a single initial value — no reassignment. The existing fixtures don't exercise this path, so it's safe to defer.

### Pitfall 5: `docs/09-memory.md` already uses new syntax

**What goes wrong:** Re-writing docs that are already correct, potentially introducing inconsistency.

**Why it happens:** The CONTEXT.md says "verify it's current." The docs already show `const ptr: Ptr(i32) = &x` style (lines 101, 113, 117, 130, 141-147).

**How to avoid:** Read the file before editing. It needs no changes. D-13 is already done.

### Pitfall 6: The `ptr_expr` NodeKind in parser.zig

**What goes wrong:** Leaving `.ptr_expr` in `NodeKind` enum and `PtrExpr` struct after all builders and codegen handling is removed. Zig `switch` on `Node` union will warn about unhandled cases if the variant remains in the union but callers removed the match arm.

**Why it happens:** Removing the PEG rules makes the nodes unreachable from parsing, but the type definition still exists.

**How to avoid:** Remove `ptr_expr: PtrExpr` from the `Node` union and `ptr_expr` from `NodeKind`, and remove the `PtrExpr` struct from parser.zig. This will cause compile errors that pinpoint every remaining arm that needs removal.

---

## Code Examples

Verified patterns from the existing codebase:

### Current `generatePtrExpr` (AST path — to be removed)
```zig
// Source: src/codegen.zig line 3604
fn generatePtrExpr(self: *CodeGen, p: parser.PtrExpr) anyerror!void {
    if (std.mem.eql(u8, p.kind, "Ptr")) {
        try self.generateExpr(p.addr_arg);
    } else if (std.mem.eql(u8, p.kind, "RawPtr")) {
        if (!self.warned_rawptr) {
            std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
            self.warned_rawptr = true;
        }
        const zig_type = try self.typeToZig(p.type_arg);
        if (p.addr_arg.* == .borrow_expr) {
            try self.emitFmt("@as([*]{s}, @ptrCast(", .{zig_type});
            try self.generateExpr(p.addr_arg);
            try self.emit("))");
        } else {
            try self.emitFmt("@as([*]{s}, @ptrFromInt(", .{zig_type});
            try self.generateExpr(p.addr_arg);
            try self.emit("))");
        }
    } else if (std.mem.eql(u8, p.kind, "VolatilePtr")) {
        // same pattern with *volatile T
    }
}
```

### New coercion function shape (AST path)
```zig
// New helper — called from generateDecl and generateStmtDecl
fn generatePtrCoercion(self: *CodeGen, kind: []const u8, type_node: *parser.Node, value: *parser.Node) anyerror!void {
    if (std.mem.eql(u8, kind, "Ptr")) {
        try self.generateExpr(value);
    } else if (std.mem.eql(u8, kind, "RawPtr")) {
        if (!self.warned_rawptr) {
            std.debug.print("WARNING: RawPtr used — unsafe, no bounds checking\n", .{});
            self.warned_rawptr = true;
        }
        const zig_type = try self.typeToZig(type_node);
        if (value.* == .borrow_expr) {
            try self.emitFmt("@as([*]{s}, @ptrCast(", .{zig_type});
            try self.generateExpr(value);
            try self.emit("))");
        } else {
            try self.emitFmt("@as([*]{s}, @ptrFromInt(", .{zig_type});
            try self.generateExpr(value);
            try self.emit("))");
        }
    } else if (std.mem.eql(u8, kind, "VolatilePtr")) {
        // same, with *volatile {zig_type}
    }
}
```

### Detection pattern in generateDecl / generateStmtDecl
```zig
// Source: src/codegen.zig — insert before "try self.generateExpr(v.value);"
if (v.type_annotation) |t| {
    if (t.* == .type_generic and t.type_generic.args.len > 0) {
        const n = t.type_generic.name;
        if (std.mem.eql(u8, n, "Ptr") or std.mem.eql(u8, n, "RawPtr") or
            std.mem.eql(u8, n, "VolatilePtr"))
        {
            try self.generatePtrCoercion(n, t.type_generic.args[0], v.value);
            try self.emit(";\n");  // or "; _ = &name;" for stmt path
            return;
        }
    }
}
```

### Fixture updates — tester.orh (lines 692, 699, 705)
```
// Before:
const raw: RawPtr(i32) = RawPtr(i32).cast(&x)
const raw: RawPtr(i32) = RawPtr(i32).cast(&arr)
const p: Ptr(i32) = Ptr(i32).cast(&x)

// After:
const raw: RawPtr(i32) = &x
const raw: RawPtr(i32) = &arr
const p: Ptr(i32) = &x
```

### Example module update — data_types.orh (line 87)
```
// Before:
const p: Ptr(i32) = Ptr(i32).cast(&x)

// After:
const p: Ptr(i32) = &x
```

---

## State of the Art

| Old Approach | Current Approach | Impact |
|---|---|---|
| `Ptr(T).cast(&x)` / `Ptr(T, &x)` | `const p: Ptr(T) = &x` | Simpler syntax; type annotation carries safety level |
| Separate `ptr_cast_expr` + `ptr_expr` PEG rules | None — address-of `&` + type annotation | Two fewer grammar rules, fewer AST node kinds |
| `ptr_expr` AST node, full MIR lowering pipeline | Coercion at declaration site only | No AST node type needed, no MIR variant needed |

---

## Environment Availability

Step 2.6: SKIPPED — no external dependencies. This phase is purely compiler source code changes (Zig files, `.orh` files).

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell test scripts |
| Config file | `build.zig` (test step) |
| Quick run command | `zig build test` (unit tests) |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PTRS-01 | `const p: Ptr(T) = &x` compiles and produces correct `*const T` | integration | `./testall.sh` — runtime: `safe_ptr` | ✅ tester.orh line 703 |
| PTRS-02 | `const r: RawPtr(T) = &x` produces `@as([*]T, @ptrCast(&x))` | integration | `./testall.sh` — runtime: `raw_ptr` | ✅ tester.orh lines 690, 697 |
| PTRS-03 | `const v: VolatilePtr(T) = 0xFF200000` compiles | compile-only | `./testall.sh` — stage 09 codegen | ❌ Wave 0 — needs fixture |
| PTRS-04 | Old `Ptr(T).cast(...)` syntax fails to parse | negative test | `./testall.sh` — stage 11 errors | ❌ Wave 0 — needs error fixture |

### Sampling Rate
- **Per task commit:** `zig build test` (unit tests only — fast)
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `test/fixtures/` — negative test fixture for old `Ptr(T).cast(...)` syntax → covers PTRS-04 in `test/11_errors.sh`
- [ ] `test/fixtures/tester.orh` or separate fixture — VolatilePtr integer address test → covers PTRS-03

*(These can be added as part of the fixture update task rather than a separate Wave 0 task, given the small scope.)*

---

## Open Questions

1. **VolatilePtr from integer address in tester.orh**
   - What we know: The existing `raw_ptr_read` and `raw_ptr_index` test functions only use `&x`-style RawPtr. No fixture currently tests the integer-address path.
   - What's unclear: Should PTRS-03 be covered by a new function in tester.orh, or is it sufficient that the codegen path is exercised by example/data_types.orh (which is comments only)?
   - Recommendation: Add a compile-only test function in tester.orh that creates a VolatilePtr from an integer literal. No need to run it — it just needs to compile.

2. **`warned_rawptr` flag — stays in CodeGen struct**
   - What we know: `warned_rawptr` on line 26 of codegen.zig is a per-module flag.
   - What's unclear: Should the warning be suppressed in any new context? The CONTEXT.md says it stays as-is.
   - Recommendation: Move the warning print from the removed functions into the new coercion helper — exact same behavior.

---

## Sources

### Primary (HIGH confidence)
- Direct source code inspection: `src/orhon.peg` lines 380-448 (grammar rules)
- Direct source code inspection: `src/peg/builder.zig` lines 177, 1351-1413 (builder functions)
- Direct source code inspection: `src/codegen.zig` lines 1207-1241, 1487-1506, 1965-1967, 2444, 3197-3235, 3604-3642, 3718-3825 (codegen functions)
- Direct source code inspection: `src/mir.zig` lines 32-50, 424-428, 917, 1178-1183, 1577-1582, 1615-1618 (MIR handling)
- Direct source code inspection: `src/parser.zig` lines 52, 115, 117, 336-340 (PtrExpr AST types)
- Direct source code inspection: `src/resolver.zig` lines 674-678 (resolver branch)
- Direct source code inspection: `test/fixtures/tester.orh` lines 690-707 (fixture Ptr usage)
- Direct source code inspection: `src/templates/example/data_types.orh` lines 81-103 (example Ptr usage)
- Direct source code inspection: `docs/09-memory.md` lines 96-153 (docs — already use new syntax)

### Secondary (MEDIUM confidence)
- N/A — all findings are from direct source code inspection

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all relevant files read directly
- Architecture: HIGH — coercion pattern extracted directly from existing generatePtrExpr logic
- Pitfalls: HIGH — pitfalls derived from actual code structure (two separate builder paths, two different MIR enum names)

**Research date:** 2026-03-25
**Valid until:** 2026-04-25 (stable codebase, no fast-moving dependencies)
