# Phase 18: Type Alias Syntax - Research

**Researched:** 2026-03-26
**Domain:** Orhon compiler — parser, declarations, MIR, codegen
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Type aliases use `const Name: type = T` syntax — reuses existing const declaration, no new keyword form
- **D-02:** `pub const Name: type = T` for public aliases — `pub` modifier works the same as other const declarations
- **D-03:** Aliases are transparent (structural) — `const Speed: type = i32` means Speed equals i32, not a distinct type
- **D-04:** Type aliases allowed at top-level and inside structs — same placement rules as `const_decl`
- **D-05:** Type aliases inside function bodies also work (Zig supports local const type aliases)
- **D-06:** All type forms valid on the RHS — primitives, generics (`List(T)`), pointers (`&T`, `const &T`), function types (`func(T) R`), struct types, enum types, slices (`[]T`), arrays (`[N]T`), error unions (`(Error | T)`), null unions (`(T | null)`)
- **D-07:** `const Name: type = T` emits `const Name = T` in Zig — the `: type` annotation is dropped (Zig infers it)
- **D-08:** `pub const Name: type = T` emits `pub const Name = T` in Zig
- **D-09:** No new grammar rule needed — existing `const_decl` already parses `const IDENTIFIER (':' type)? '=' expr TERM`; the type annotation will be `type` (keyword_type)
- **D-10:** The RHS expression must be interpreted as a type expression — when annotation is `type`, the value is a type, not a runtime value
- **D-11:** Type aliases registered in `DeclTable.types` hashmap — already exists with comment "type aliases and compt types"

### Claude's Discretion
- How to distinguish type alias const_decl from regular const_decl in builder/codegen (check if type annotation is `type` keyword)
- Whether to add a flag to VarDecl AST node or detect at codegen time
- Test fixture design and example module placement

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TAMGA-04 | `const Alias: type = T` declarations supported, generating Zig `const Alias = Type` | All five integration points mapped; detection mechanism confirmed |
</phase_requirements>

## Summary

Phase 18 adds type alias support to the Orhon compiler. The key insight from code reading is that the syntax `const Name: type = T` already parses today — the `const_decl` PEG rule accepts `': type'` in the annotation slot, `keyword_type` produces a `type_named` node with text `"type"`, and `K.Type.TYPE = "type"` is already defined in `constants.zig`. The work is entirely in what happens after parsing: declarations collection, MIR annotation, and codegen must all learn to recognize when a `const_decl` carries a `: type` annotation and treat the RHS as a type expression rather than a runtime value.

The codegen already has an established pattern for this kind of detection: `K.Type.TYPE` is used in `generateFuncMir()` and `generateFunc()` to detect `compt func` signatures that return types. The same `std.mem.eql(u8, annotation.type_named, K.Type.TYPE)` idiom applies directly here.

There are five integration points: (1) `declarations.zig collectVar()` must route type aliases into `DeclTable.types` instead of `DeclTable.vars`; (2) `mir.zig MirAnnotator.annotateNode()` must skip value annotation for type aliases; (3) `mir.zig MirLowerer.lowerNode()` must lower the RHS as a `type_expr` child; (4) `codegen.zig generateTopLevelDeclMir()` must detect type alias and emit `const Name = TypeExpr`; and (5) `codegen.zig generateStatementMir()` must do the same for in-body aliases.

**Primary recommendation:** Detect type alias by checking `m.type_annotation != null and m.type_annotation.* == .type_named and std.mem.eql(u8, m.type_annotation.type_named, K.Type.TYPE)` in both codegen paths. No new AST node kind, no new VarDecl field — detection at use site matches the `is_compt` precedent from `compt_decl`.

## Standard Stack

### Core

| File | Role | Change Needed |
|------|------|---------------|
| `src/declarations.zig` | `collectVar()` — routes to `types` vs `vars` | YES — detect `: type` annotation, put in `types` map |
| `src/mir.zig` | `MirAnnotator.annotateNode()` — annotations for `const_decl` | YES — skip value annotation for type alias |
| `src/mir.zig` | `MirLowerer.lowerNode()` — lowers const_decl children | YES — lower RHS as type_expr |
| `src/codegen.zig` | `generateTopLevelDeclMir()` — emits top-level const | YES — detect type alias, emit without Zig annotation |
| `src/codegen.zig` | `generateStatementMir()` — emits in-body const | YES — same detection |

### No-Change Files

| File | Why Unchanged |
|------|---------------|
| `src/orhon.peg` | `const_decl` rule already parses `: type` annotation |
| `src/peg/builder.zig` | `buildConstDecl()` already captures type annotation; `buildKeywordType()` already produces `type_named{"type"}` |
| `src/parser.zig` | `VarDecl` struct already has `type_annotation: ?*Node` |
| `src/lexer.zig` | `kw_type` token already defined |
| `src/peg/token_map.zig` | `"type"` → `.kw_type` already mapped |
| `src/constants.zig` | `K.Type.TYPE = "type"` already defined |
| `src/resolver.zig` | Cross-module `types.contains()` check already in place |

## Architecture Patterns

### Detection Pattern

The type alias detection string (used in declarations, MIR, and codegen) is:

```zig
// Source: src/constants.zig + existing compt detection pattern in codegen.zig:640
fn isTypeAlias(type_annotation: ?*parser.Node) bool {
    const ta = type_annotation orelse return false;
    return ta.* == .type_named and std.mem.eql(u8, ta.type_named, K.Type.TYPE);
}
```

This is the exact same idiom already used at `codegen.zig:640` for detecting type-returning compt funcs:
```zig
const returns_type = ret_type.* == .type_named and
    std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
```

### Declarations Integration (collectVar)

Currently `collectVar()` always puts into `DeclTable.vars`. It must branch:

```zig
// src/declarations.zig — collectVar(), after D-11
if (isTypeAlias(v.type_annotation)) {
    // Register as type alias: name → Zig type string
    // DeclTable.types stores []const u8 (the Zig type repr)
    // For now store the Orhon type name or a sentinel; codegen reads AST directly
    try self.table.types.put(v.name, v.name); // name signals existence
    return;
}
// existing vars path
const sig = VarSig{ ... };
try self.table.vars.put(v.name, sig);
```

Note: `DeclTable.types` maps `name → []const u8`. For type aliases, the value should be the alias name itself (or the type text). Codegen does not read from `DeclTable.types` for code emission — it reads the AST directly. The `types` map is used for existence checks in the resolver (cross-module `types.contains()`).

### MIR Annotator

For `const_decl` with `: type` annotation, the value is a type node, not a runtime value. The annotator currently calls `annotateNode(v.value)` which descends into expressions. For type aliases the value IS a type node (e.g., `type_named`, `type_generic`) which will fall through to the `else` branch in `annotateNode()` (currently a no-op). This is safe — no change strictly required. However, `recordNode` will be called with `RT.unknown` since there is no type_map entry for the alias node. This is fine because codegen for type aliases bypasses the resolved_type entirely.

### MIR Lowerer

Currently `var_decl, .const_decl` branch lowers `v.value` as a child. For type alias, `v.value` is a type AST node (e.g., `type_named{"i32"}`). The `lowerNode()` for type nodes maps to `.type_expr` MirKind (confirmed at `mir.zig:1614`). This means the MirNode child will have `kind == .type_expr` — which is exactly what `generateTopLevelDeclMir()` already checks:

```zig
// codegen.zig:1328 — already present
} else if (m.value().kind == .type_expr) {
    // Type in expression position = default constructor (.{})
    try self.emit(".{}");
}
```

This existing path emits `.{}` which is wrong for type aliases. The type alias codegen path must be detected BEFORE reaching this branch.

### Codegen — Top-Level Path

```zig
// src/codegen.zig — generateTopLevelDeclMir(), insert before existing compt check
fn generateTopLevelDeclMir(self: *CodeGen, m: *mir.MirNode) anyerror!void {
    const name = m.name orelse return;
    if (m.is_bridge) return self.generateBridgeReExport(name, m.is_pub);

    // NEW: type alias detection — must precede is_compt check
    if (m.is_const and isTypeAlias(m.type_annotation)) {
        if (m.is_pub) try self.emit("pub ");
        try self.emitFmt("const {s} = ", .{name});
        try self.emit(try self.typeToZig(m.type_annotation.?)); // ← WRONG: annotation is "type", not the RHS type
        // CORRECT: typeToZig(m.value().ast.*) — the RHS is the actual type node
        ...
    }
```

**Critical detail:** `m.type_annotation` is the `: type` annotation node (value = `"type"`). The actual type to emit is the RHS — `m.value().ast` which is the type AST node (e.g., `type_named{"i32"}`). So codegen must call `typeToZig` on the value child's AST node, not on the annotation:

```zig
if (m.is_const and isTypeAlias(m.type_annotation)) {
    if (m.is_pub) try self.emit("pub ");
    try self.emitFmt("const {s} = ", .{name});
    try self.emit(try self.typeToZig(m.value().ast));
    try self.emit(";\n");
    return;
}
```

The `m.value().ast` back-pointer gives us the original type AST node, and `typeToZig()` already handles all type node variants (primitives, generics, pointers, slices, arrays, func types, unions).

### Codegen — Statement Path (in-body aliases)

Same pattern in `generateStatementMir()`, in the `.var_decl` branch, before the `is_compt` check:

```zig
.var_decl => {
    const var_name = m.name orelse return;
    // NEW: type alias in function body
    if (m.is_const and isTypeAlias(m.type_annotation)) {
        try self.emitFmt("const {s} = ", .{var_name});
        try self.emit(try self.typeToZig(m.value().ast));
        try self.emit(";");
        return;
    }
    if (m.is_compt) { ... }
```

Note: No `_ = &name;` suffix for type aliases (that suppresses unused-variable warnings for runtime values — not applicable to type aliases in Zig).

### Anti-Patterns to Avoid

- **Calling typeToZig on m.type_annotation:** The annotation is `type_named{"type"}` which typeToZig would map via `primitiveToZig("type")` — unknown result. Always call `typeToZig(m.value().ast)`.
- **Adding is_type_alias field to VarDecl:** Unnecessary — detection at use site from type annotation is cleaner and matches the existing `is_compt` / `returns_type` detection pattern.
- **Modifying generateStmtDecl (AST path):** The AST-path codegen is legacy. The phase should implement the MIR path only; the AST path can be left as-is (it would produce incorrect output for type aliases, but only if MIR annotation fails, which blocks the codegen pass entirely).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Type string emission | Custom type serializer | `typeToZig()` — handles all 10+ type forms already |
| Type alias existence check | New hashmap | `DeclTable.types` — already initialized and queried by resolver |
| Keyword detection | String scanning | `K.Type.TYPE` constant + `type_named` node tag |

## Common Pitfalls

### Pitfall 1: typeToZig on the annotation node
**What goes wrong:** Calling `typeToZig(m.type_annotation)` emits `"type"` (via `primitiveToZig`) instead of the actual aliased type.
**Why it happens:** `m.type_annotation` is the annotation (`: type`) — it's the sentinel, not the RHS.
**How to avoid:** Always call `typeToZig(m.value().ast)` to get the RHS type node.
**Warning signs:** Generated Zig contains `const Speed = type;` which fails to compile.

### Pitfall 2: type_expr .{} emission
**What goes wrong:** Without a type alias check, the existing `m.value().kind == .type_expr` branch fires and emits `.{}` (default constructor syntax).
**Why it happens:** `generateTopLevelDeclMir` already has a special case for type nodes in value position — but it was written for struct instantiation, not type alias RHS.
**How to avoid:** Insert the type alias branch BEFORE the `is_compt` check and the `.{}` branch.
**Warning signs:** Generated Zig contains `const Speed = .{};` which is wrong.

### Pitfall 3: collectVar puts alias in vars map
**What goes wrong:** If `collectVar()` doesn't branch, the alias is registered in `DeclTable.vars` as a `VarSig` with `type_ = Some(RT.named("type"))`. This won't crash but will leave `DeclTable.types` empty, breaking cross-module alias resolution.
**Why it happens:** `collectVar` currently has no type alias detection.
**How to avoid:** Check `isTypeAlias(v.type_annotation)` at the top of `collectVar()` and route to `types.put()`.

### Pitfall 4: unused-variable suppression for type aliases
**What goes wrong:** Adding `_ = &SpeedAlias;` after a type alias declaration causes a Zig compile error (can't take address of type).
**Why it happens:** `generateStmtDeclMir` currently appends `; _ = &{s};` to suppress unused-variable warnings.
**How to avoid:** Type alias path must return early before reaching `generateStmtDeclMir`, or the suppression line must be omitted for type aliases.

### Pitfall 5: MIR annotator annotating type node as value
**What goes wrong:** `annotateNode(v.value)` on a type alias descends into `type_named{"i32"}` which hits the `else` branch (no-op). This is safe. However, if the type node is something more complex (e.g., `type_union`), the annotator may try to annotate its children as expressions.
**Why it happens:** The annotator `annotateNode()` switch has no arm for type node kinds.
**How to avoid:** Skip `annotateNode(v.value)` for type aliases in the MirAnnotator's `const_decl` branch, or verify that all type node kinds fall through `else` cleanly.

## Code Examples

### How keyword_type produces type_named (confirmed)
```zig
// src/peg/builder.zig:1395
fn buildKeywordType(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    return ctx.newNode(.{ .type_named = tokenText(ctx, cap.start_pos) });
}
// Result: type_named{"type"} for `const X: type = ...`
```

### How K.Type.TYPE is used for detection (existing pattern)
```zig
// src/codegen.zig:640
const returns_type = ret_type.* == .type_named and
    std.mem.eql(u8, ret_type.type_named, K.Type.TYPE);
```

### typeToZig for all required RHS type forms
```zig
// src/codegen.zig:3810 — handles all cases needed by D-06
// type_named  → primitiveToZig(name)         e.g. "i32" → "i32"
// type_slice  → "[]{inner}"                  e.g. "[]i32"
// type_array  → "[N]{inner}"
// type_ptr    → "*const T" or "*T"
// type_func   → "*const fn(params) ret"
// type_generic → "Ptr(T)" → "*T" etc.
// type_union  → "anyerror!T", "?T", or "union(enum){...}"
```

### DeclTable.types usage (existing cross-module check)
```zig
// src/resolver.zig:852
is_known = mod_decls.structs.contains(type_name) or
    mod_decls.enums.contains(type_name) or
    mod_decls.funcs.contains(type_name) or
    mod_decls.types.contains(type_name);  // ← type aliases already included
```

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Shell integration tests (`test/*.sh`) + Zig unit tests (`zig build test`) |
| Config file | `testall.sh` |
| Quick run command | `zig build && ./zig-out/bin/orhon build` in a test project |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TAMGA-04-1 | `const Speed: type = i32` parses and compiles | integration | `./testall.sh` (09_language.sh) | ❌ Wave 0 (add to example module) |
| TAMGA-04-2 | `pub const Callback: type = func(i32) void` parses and compiles | integration | `./testall.sh` (09_language.sh) | ❌ Wave 0 |
| TAMGA-04-3 | Codegen emits `const Speed = i32` in Zig | codegen grep | `test/09_language.sh` | ❌ Wave 0 |
| TAMGA-04-4 | Aliases work with all type forms | integration | `./testall.sh` | ❌ Wave 0 (example module) |

### Sampling Rate
- **Per task commit:** `zig build && cd /tmp/test && orhon build`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] Type alias declarations in `src/templates/example/advanced.orh` — covers TAMGA-04 primitives, generics, pointers, func types
- [ ] Grep assertion in `test/09_language.sh` — checks generated Zig for `const Speed = i32` pattern
- [ ] No new test fixture files needed (positive cases go in example module; no expected failure case for type aliases)

## Environment Availability

Step 2.6: SKIPPED (no external dependencies — compiler changes only, no new tools required).

## Sources

### Primary (HIGH confidence)
- Direct code reading of `src/orhon.peg`, `src/peg/builder.zig`, `src/parser.zig`, `src/declarations.zig`, `src/mir.zig`, `src/codegen.zig`, `src/constants.zig`, `src/resolver.zig` — all findings are from the actual codebase.

### Secondary (MEDIUM confidence)
- CONTEXT.md decisions — confirmed against implementation by code reading.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all integration points verified by direct code reading
- Architecture: HIGH — detection pattern confirmed from existing `K.Type.TYPE` usage at codegen.zig:640
- Pitfalls: HIGH — each pitfall identified from actual code paths (type_expr branch at 1328, `_ = &{s};` at 1288, collectVar routing at 374)

**Research date:** 2026-03-26
**Valid until:** 2026-04-25 (stable codebase, no external dependencies)
