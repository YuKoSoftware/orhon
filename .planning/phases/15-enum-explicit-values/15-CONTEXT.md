# Phase 15: Enum Explicit Values - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Allow typed enum variants to carry explicit integer assignments (e.g., `A = 4`). Currently the grammar only supports auto-numbered sequential variants. This blocks Tamga from mapping SDL3 scancodes directly to enum values.

</domain>

<decisions>
## Implementation Decisions

### Syntax
- **D-01:** Enum variants support `= integer_literal` after the identifier: `A = 4`
- **D-02:** A variant gets `= value` OR `(fields)`, never both — mutual exclusion enforced at parse time
- **D-03:** `A(f32) = 4` is a parse error — tagged union variants cannot have explicit discriminant values

### Codegen Mapping
- **D-04:** Explicit values map 1:1 to Zig enum values — `A = 4` in Orhon emits `A = 4` in generated Zig
- **D-05:** Backing type from `enum(u32)` carries through unchanged — Zig handles overflow/validation

### Validation
- **D-06:** Mutual exclusion (value vs data) enforced at parse level — grammar branches are `('=' expr)` or `('(' param_list ')')`
- **D-07:** Value uniqueness and overflow validation deferred to Zig — the compiler does not need custom checks since Zig will reject duplicates and out-of-range values

### Claude's Discretion
- Whether to use `expr` or `integer_literal` as the grammar rule for the value (expressions allow hex `0x1F`, binary `0b1010` etc.)
- AST node structure for carrying the optional value field
- Test fixture design

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Grammar & Parser
- `src/orhon.peg` — PEG grammar, specifically `enum_variant` rule at line 155
- `src/peg/builder.zig` — `buildEnumVariant()` at line 675, `buildEnumDecl()` at line 620

### AST
- `src/parser.zig` — `NodeKind.enum_variant` definition (name + fields structure)

### Codegen
- `src/codegen.zig` — enum generation, `generateEnumMir()` and `enum_variant_def` handling

### Existing Enum Examples
- `src/templates/example/example.orh` — `Direction` enum at line 107 (simple typed enum)
- `src/templates/example/advanced.orh` — tagged union enum pattern at line 186

### Bug Source
- `/home/yunus/Projects/orhon/tamga_framework/docs/bugs.txt` — OPEN: Enum variants with explicit integer values

</canonical_refs>

<code_context>
## Existing Code Insights

### Current Grammar
- `enum_variant <- IDENTIFIER ('(' _ param_list _ ')')? TERM` — no `= value` branch exists
- The `('(' param_list ')')` optional group handles associated data — new `= expr` group goes as an alternative

### AST Node
- `enum_variant` node has `{ .name, .fields }` — needs a new optional `value` field

### Codegen Pattern
- Codegen iterates enum variants and emits `name,` — needs to conditionally emit `name = value,` when value is present

### Integration Points
- `src/declarations.zig` — enum declaration collection
- `src/mir.zig` — MIR annotation for enums
- `src/resolver.zig` — type resolution for enum types

</code_context>

<specifics>
## Specific Ideas

- The Tamga use case is SDL3 scancodes: `pub enum(u32) Scancode { A = 4, B = 5, ... }` — pure integer enums with no associated data
- Hex literals (`0x1F`) should work in the value position since all numeric literals fold to `.int_literal` in the lexer

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 15-enum-explicit-values*
*Context gathered: 2026-03-25*
