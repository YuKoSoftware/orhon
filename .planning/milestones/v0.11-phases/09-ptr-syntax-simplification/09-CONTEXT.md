# Phase 9: Ptr Syntax Simplification - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Remove `Ptr(T).cast(&x)` and `Ptr(T, &x)` syntax. Pointer construction becomes type-directed: `const p: Ptr(T) = &x`. Remove PEG rules, add codegen coercion. Update all fixtures and examples.

</domain>

<decisions>
## Implementation Decisions

### PEG grammar changes
- **D-01:** Remove `ptr_cast_expr` rule (line 433-434 in orhon.peg)
- **D-02:** Remove `ptr_expr` rule (line 437-438 in orhon.peg)
- **D-03:** Remove both from `primary_expr` alternatives (line 391-392)
- **D-04:** The `&` unary operator (line 349) stays — it's how users take addresses

### Builder changes
- **D-05:** Remove `buildPtrCastExpr` function from builder.zig (line 1354)
- **D-06:** Remove ptr_cast_expr dispatch in build function (line 177)
- **D-07:** Remove the pointer constructor detection in generic call handling (lines 1397-1406)

### Codegen — type-directed coercion (NEW)
- **D-08:** When processing a `const_decl` or `var_decl` where:
  - Type annotation is `Ptr(T)` AND value is `&expr` → emit `&expr` (already `*const T`)
  - Type annotation is `RawPtr(T)` AND value is `&expr` → emit `@as([*]T, @ptrCast(&expr))`
  - Type annotation is `RawPtr(T)` AND value is integer literal → emit `@as([*]T, @ptrFromInt(N))`
  - Type annotation is `VolatilePtr(T)` AND value is `&expr` → emit `@as(*volatile T, @ptrCast(&expr))`
  - Type annotation is `VolatilePtr(T)` AND value is integer literal → emit `@as(*volatile T, @ptrFromInt(N))`
- **D-09:** This is a codegen-level coercion, NOT a MIR coercion — it happens when emitting assignment/declaration code based on the type annotation
- **D-10:** The old `generatePtrExpr` and `generatePtrExprMir` functions can be replaced with this coercion logic

### Fixture/example updates
- **D-11:** `test/fixtures/tester.orh` — change 3 Ptr/RawPtr lines from `.cast()` to new syntax
- **D-12:** `src/templates/example/data_types.orh` — update Ptr example and RawPtr/VolatilePtr comments
- **D-13:** `docs/09-memory.md` — already updated in v0.10 (verify it's current)

### Error message for old syntax
- **D-14:** If someone writes `Ptr(T).cast(...)` or `Ptr(T, ...)`, the PEG parser will now fail to parse it. The generic error message from the PEG engine is sufficient — no custom migration message needed.

### Claude's Discretion
- Whether to keep generatePtrExpr/generatePtrExprMir as dead code during transition or remove immediately
- Exact codegen location for the type-directed coercion check
- Whether RawPtr warning is emitted at parse time, codegen time, or both

</decisions>

<canonical_refs>
## Canonical References

### PEG grammar
- `src/orhon.peg` lines 391-392, 431-438 — ptr_cast_expr, ptr_expr rules to remove

### Builder
- `src/peg/builder.zig` lines 177, 1351-1410 — buildPtrCastExpr and generic ptr detection

### Codegen
- `src/codegen.zig` lines 1965-1966 — AST-path ptr_expr handler
- `src/codegen.zig` lines 2444, 3197 — MIR-path ptr_expr handler
- `src/codegen.zig` lines 3604+ — generatePtrExpr function

### Parser types
- `src/parser.zig` — PtrExpr AST node type (will become unused)

### Fixtures to update
- `test/fixtures/tester.orh` lines 692, 699, 705 — Ptr/RawPtr usage
- `src/templates/example/data_types.orh` lines 83-103 — Ptr examples

### Design decision
- Memory file: `project_ptr_syntax_simplification.md` — full rationale

</canonical_refs>

<code_context>
## Existing Code Insights

### Current Ptr Codegen (to be replaced)
`generatePtrExpr` handles Ptr→`&x`, RawPtr→`@as([*]T, @ptrCast(&x))`, VolatilePtr→`@as(*volatile T, @ptrCast(&x))`. This same logic moves to the declaration/assignment codegen path, triggered by type annotation instead of AST node kind.

### Type Annotation Available in Codegen
Codegen already has access to type annotations on declarations — `typeToZig` resolves `Ptr(T)` to `*const T`, `RawPtr(T)` to `[*]T`, `VolatilePtr(T)` to `[*]volatile T`. The coercion check can key on the type annotation string.

### MIR Already Classifies Ptr Types
MIR's `classifyType` returns `.safe_ptr` for Ptr and `.raw_ptr` for RawPtr/VolatilePtr. This classification is available in codegen via `getTypeClass()`.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — the design decision is clear.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 09-ptr-syntax-simplification*
*Context gathered: 2026-03-25*
