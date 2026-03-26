# Phase 15: Enum Explicit Values - Research

**Researched:** 2026-03-26
**Domain:** PEG grammar extension, AST struct modification, MIR data propagation, Zig codegen
**Confidence:** HIGH

## Summary

Phase 15 adds explicit integer value assignments to typed enum variants (`A = 4`). The feature touches exactly four locations in the compiler pipeline: the PEG grammar rule (`enum_variant`), the AST builder (`buildEnumVariant`), the MIR lowerer (propagating the value field through `enum_variant` handling), and the codegen (`generateEnumMir`). No semantic analysis pass needs to change — value validity is delegated to Zig as decided in D-07.

The change is localized and low-risk. Existing sequential enums are unaffected because the `= value` clause is optional in the grammar. The only struct that needs a new field is `parser.EnumVariant`, which gains `value: ?*Node = null`. Three downstream readers of `enum_variant` (docgen, LSP formatter in main.zig, and declarations collector) need minor touch-ups to handle the new optional field gracefully.

**Primary recommendation:** Add `('=' int_literal)?` to the `enum_variant` PEG rule — use `int_literal` not `expr`, consistent with how integer-only contexts are handled in the grammar. Thread the optional literal text through AST → MIR → codegen as a `?[]const u8` on `MirNode`.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Enum variants support `= integer_literal` after the identifier: `A = 4`
- **D-02:** A variant gets `= value` OR `(fields)`, never both — mutual exclusion enforced at parse time
- **D-03:** `A(f32) = 4` is a parse error — tagged union variants cannot have explicit discriminant values
- **D-04:** Explicit values map 1:1 to Zig enum values — `A = 4` in Orhon emits `A = 4` in generated Zig
- **D-05:** Backing type from `enum(u32)` carries through unchanged — Zig handles overflow/validation
- **D-06:** Mutual exclusion enforced at parse level — grammar branches are `('=' expr)` or `('(' param_list ')')`
- **D-07:** Value uniqueness and overflow validation deferred to Zig

### Claude's Discretion
- Whether to use `expr` or `integer_literal` as the grammar rule for the value position
- AST node structure for carrying the optional value field
- Test fixture design

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TAMGA-01 | Typed enums support explicit integer value assignments per variant (e.g., `A = 4`) | Grammar rule extension + AST field + MIR propagation + codegen conditional emit |
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
| `src/orhon.peg` | Grammar rule edit | Add `('=' int_literal)?` branch to `enum_variant` |
| `src/peg/builder.zig` | Function edit | `buildEnumVariant` — extract value token text when present |
| `src/parser.zig` | Struct edit | `EnumVariant` gains `value: ?*Node = null` |
| `src/mir.zig` | Field + lowerer edit | `MirNode` gets no new field (reuse `literal`); lowerer propagates value text |
| `src/codegen.zig` | Codegen edit | `generateEnumMir` emits `name = value,` when `literal` is non-null |
| `src/main.zig` | Minor edit | LSP hover formatter for enum variants — handle new `value` field |
| `src/docgen.zig` | Minor edit | Doc generator — optionally display value |
| `src/templates/example/example.orh` | Addition | Add explicit-value enum example |
| `test/fixtures/fail_enums.orh` | Addition | Add negative test for `A(f32) = 4` |
| `test/09_language.sh` | Addition | Assert generated Zig contains `= N` assignment |

---

## Architecture Patterns

### How the Pipeline Carries Enum Variant Data (Current)

```
orhon.peg
  enum_variant <- IDENTIFIER ('(' _ param_list _ ')')? TERM

builder.zig  buildEnumVariant()
  .enum_variant = .{ .name = name, .fields = fields }

parser.zig  EnumVariant struct
  { name: []const u8, fields: []*Node, doc: ?[]const u8 }

mir.zig  MirLowerer.lowerNode()  (.enum_variant branch)
  m.name = v.name
  (no children lowered — leaf node in current code)

codegen.zig  generateEnumMir()  (.enum_variant_def branch)
  try self.emitFmt("{s},\n", .{vname});
```

### How It Looks After the Change

```
orhon.peg
  enum_variant <- IDENTIFIER ('=' int_literal / '(' _ param_list _ ')')? TERM

builder.zig  buildEnumVariant()
  finds '=' token in range, captures next token as int_literal node
  .enum_variant = .{ .name = name, .fields = fields, .value = optional_node }

parser.zig  EnumVariant struct
  { name: []const u8, fields: []*Node, value: ?*Node = null, doc: ?[]const u8 }

mir.zig  MirLowerer.lowerNode()  (.enum_variant branch)
  m.name = v.name
  if (v.value) |val| m.literal = val.int_literal  // reuse existing literal field

codegen.zig  generateEnumMir()  (.enum_variant_def branch)
  if (child.literal) |lit|
      try self.emitFmt("{s} = {s},\n", .{ vname, lit });
  else
      try self.emitFmt("{s},\n", .{vname});
```

### Grammar Rule Design

Use `int_literal` (not `expr`) in the value position:

```peg
enum_variant
    <- IDENTIFIER ('=' int_literal / '(' _ param_list _ ')')? TERM
```

**Why `int_literal` not `expr`:**
- Matches the problem domain exactly (SDL3 scancodes are integer constants)
- All numeric bases fold to `.int_literal` in the lexer (`0x1F`, `0b1010`, `255` all produce `INT_LITERAL`)
- Using `expr` would admit `A = foo + bar` which has no semantic meaning in a Zig enum
- Consistent with how other integer-only contexts work in the grammar (`bitfield` backing type, `enum` backing type)
- Simpler builder logic: read a single token instead of recursively building an expression subtree

**Why ordered choice `/` not `?` with internal branch:**
The grammar uses `(alt1 / alt2)?` to model mutual exclusion. `('=' int_literal / '(' _ param_list _ ')')` means: either a value assignment OR associated data fields, never both. The PEG ordered choice naturally enforces D-02 and D-03 — if `(` appears, it takes the field branch; if `=` appears, it takes the value branch.

### Builder Pattern

The `buildEnumVariant` function currently scans tokens to find the name and uses `buildChildrenByRule` for params. For the value, the same token-scan approach applies:

```zig
fn buildEnumVariant(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = tokenText(ctx, cap.start_pos);
    // Check for explicit value: '=' followed by int_literal
    var value: ?*Node = null;
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .assign) {
            if (i + 1 < ctx.tokens.len and ctx.tokens[i + 1].kind == .int_literal) {
                value = try ctx.newNode(.{ .int_literal = ctx.tokens[i + 1].text });
            }
            break;
        }
    }
    const fields = try buildChildrenByRule(ctx, cap, "param");
    return ctx.newNode(.{ .enum_variant = .{
        .name = name,
        .fields = fields,
        .value = value,
    } });
}
```

Alternatively, use `cap.findChild("int_literal")` if the PEG capture tree names the child rule correctly. The token-scan approach is safer and consistent with how `buildEnumDecl` finds the identifier after `)`.

### MirNode Reuse Strategy

`MirNode` already has `literal: ?[]const u8`. The `enum_variant_def` kind never uses `literal` today. Reusing it for the explicit value avoids adding a new field to the 800-line `MirNode` struct. The lowerer sets `m.literal = val.int_literal` when a value node is present.

### Anti-Patterns to Avoid
- **Using `expr` in the grammar:** Admits semantically invalid constructs that Zig cannot represent as enum discriminants
- **Adding a new `MirNode` field for variant values:** `literal` is already there and unused for this kind — reuse it
- **Validating duplicates or overflow in the Orhon compiler:** D-07 locks this to Zig — emit as-is and let Zig error
- **Forgetting the mutual exclusion test:** D-03 requires that `A(f32) = 4` is a parse error — the ordered choice grammar enforces this, but a negative test fixture must confirm it

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Value validation (uniqueness, overflow) | Custom duplicate-check in declarations.zig | Let Zig compiler reject — D-07 is explicit |
| Hex/binary literal parsing | Special-case `0x`/`0b` prefixes | Lexer already folds all numeric forms to `INT_LITERAL` |
| Type checking of value vs backing type | Range check in resolver.zig | Out of scope — Zig handles it |

---

## Common Pitfalls

### Pitfall 1: Grammar Captures `assign` Token from Assignment Statements
**What goes wrong:** The `buildEnumVariant` token scan looks for `.assign` (the `=` token). If the scan range leaks beyond `TERM`, it could find `=` tokens in following statements.
**Why it happens:** Capture ranges in the PEG engine are bounded by `start_pos`/`end_pos` for the matched rule span. This is safe as long as the scan only iterates `cap.start_pos..cap.end_pos`.
**How to avoid:** Always bound the scan within `cap.start_pos..cap.end_pos`. The `TERM` token at the end of `enum_variant` acts as the boundary.
**Warning signs:** Test with a multi-variant enum and verify each variant emits the correct value.

### Pitfall 2: `buildChildrenByRule(ctx, cap, "int_literal")` Returns Empty
**What goes wrong:** If the PEG capture tree doesn't name the `int_literal` child with that exact rule string, `findChild("int_literal")` returns null even when a value is present.
**Why it happens:** The capture tree names come from grammar rule names. `int_literal` is a named rule in the grammar, so it should capture correctly — but verify before trusting it.
**How to avoid:** Use the token-scan approach (look for `.assign` then next `.int_literal`) as a fallback. This is the same pattern used in `buildEnumDecl` for finding the identifier.
**Warning signs:** Builder returns `value = null` even when `= 4` is written.

### Pitfall 3: The `literal` Field Already Set on `enum_variant_def`
**What goes wrong:** Future MIR changes might set `literal` on enum variant nodes for a different purpose, silently breaking explicit values.
**Why it happens:** `literal` is a generic "text value" field reused across kinds.
**How to avoid:** Add a comment in the MIR lowerer that `literal` on `enum_variant_def` means the explicit discriminant value. The alternative (a dedicated field) is cleaner long-term but out of scope for this phase.

### Pitfall 4: Forgetting the `main.zig` LSP Hover Formatter
**What goes wrong:** The LSP hover for an enum type emits the declaration signature (used by `orhon lsp`). At `src/main.zig:1648`, the `enum_variant` case emits `v.name` + optional fields. If `v.value` is non-null and the formatter ignores it, the hover output is misleading but not a compile error.
**Why it happens:** The formatter was written before explicit values existed.
**How to avoid:** Add `if (v.value != null) { try buf.appendSlice(" = ...") }` in the formatter. Low severity but should be kept correct.

### Pitfall 5: The `fail_enums.orh` Negative Test Needs Updating
**What goes wrong:** The existing `test/fixtures/fail_enums.orh` tests duplicate variant names. Adding `A(f32) = 4` as an additional case in the same file risks the test checking the wrong error message.
**Why it happens:** A single fixture file produces a single compiler run; the first error may mask later ones.
**How to avoid:** Either add a separate `fail_enum_value.orh` fixture, or add the invalid case to the existing fixture and check that the build fails (any error). The existing `11_errors.sh` test already only checks that the build exits non-zero for this fixture.

---

## Code Examples

### Grammar Change (verified against src/orhon.peg line 155)
```peg
# Before
enum_variant
    <- IDENTIFIER ('(' _ param_list _ ')')? TERM

# After
enum_variant
    <- IDENTIFIER ('=' int_literal / '(' _ param_list _ ')')? TERM
```

### AST Struct Change (src/parser.zig line 226)
```zig
pub const EnumVariant = struct {
    name: []const u8,
    fields: []*Node, // params for data-carrying variants
    value: ?*Node = null, // explicit integer discriminant (int_literal node)
    doc: ?[]const u8 = null,
};
```

### Builder Change (src/peg/builder.zig line 675)
```zig
fn buildEnumVariant(ctx: *BuildContext, cap: *const CaptureNode) !*Node {
    const name = tokenText(ctx, cap.start_pos);
    var value: ?*Node = null;
    // Scan for '=' followed by int_literal within this variant's token range
    for (cap.start_pos..cap.end_pos) |i| {
        if (i < ctx.tokens.len and ctx.tokens[i].kind == .assign) {
            if (i + 1 < ctx.tokens.len and ctx.tokens[i + 1].kind == .int_literal) {
                value = try ctx.newNode(.{ .int_literal = ctx.tokens[i + 1].text });
            }
            break;
        }
    }
    const fields = try buildChildrenByRule(ctx, cap, "param");
    return ctx.newNode(.{ .enum_variant = .{
        .name = name,
        .fields = fields,
        .value = value,
    } });
}
```

### MIR Lowerer Change (src/mir.zig line 1494)
```zig
.enum_variant => |v| {
    m.name = v.name;
    // Propagate explicit discriminant value as literal text for codegen
    if (v.value) |val| {
        m.literal = val.int_literal;
        m.literal_kind = .int;
    }
},
```

### Codegen Change (src/codegen.zig line 1111)
```zig
.enum_variant_def => {
    const vname = child.name orelse continue;
    try self.emitIndent();
    if (child.literal) |lit| {
        try self.emitFmt("{s} = {s},\n", .{ vname, lit });
    } else {
        try self.emitFmt("{s},\n", .{vname});
    }
},
```

### Example Module Addition (src/templates/example/example.orh)
```orhon
// ─── Typed enum with explicit values ────────────────────────────────────────

/// SDL3 scancode subset — explicit integer assignments
pub enum(u32) Scancode {
    A = 4
    B = 5
    C = 6
    Space = 44
}
```

### Negative Test Fixture Addition
```orhon
// Tagged union variant cannot have explicit discriminant
enum(u8) Bad {
    Foo(i32) = 4
}
```

---

## State of the Art

| Old Behavior | New Behavior | When Changed | Impact |
|--------------|-------------|--------------|--------|
| `enum_variant` grammar only allows `(fields)` optional | Grammar also allows `= int_literal` alternative | Phase 15 | Unlocks SDL3 scancode mappings in Tamga |
| `EnumVariant` AST struct has no value field | Gains `value: ?*Node = null` | Phase 15 | All readers of `enum_variant` must handle null gracefully |
| Codegen always emits `name,` | Emits `name = value,` when value present | Phase 15 | Generated Zig enums get correct discriminant values |

---

## Open Questions

1. **Does `findChild("int_literal")` work in the capture tree?**
   - What we know: Named rules in the PEG grammar produce named children in the capture tree. `int_literal <- INT_LITERAL` is a named rule.
   - What's unclear: Whether the capture tree propagates the child name `"int_literal"` for a terminal-only rule, or collapses it.
   - Recommendation: Use the token-scan approach (scan for `.assign` token then read next token) — it's guaranteed to work and is consistent with existing builder patterns in the codebase. If capture children work, the implementation can be simplified later.

2. **Does the `literal_kind = .int` assignment on the variant MIR node matter?**
   - What we know: `literal_kind` discriminates between literal types for codegen, but `enum_variant_def` codegen reads `child.literal` directly as a text string.
   - What's unclear: Whether any other pass reads `literal_kind` on `enum_variant_def` nodes.
   - Recommendation: Set it for consistency (`m.literal_kind = .int`) — it doesn't hurt and keeps the MirNode self-consistent.

---

## Environment Availability

Step 2.6: SKIPPED — this phase is purely code changes within the existing compiler. No external tools, services, or CLIs beyond the project's own build system are required.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Zig built-in test blocks + bash integration tests |
| Config file | `build.zig` (for `zig build test`) |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TAMGA-01 | `pub enum(u32) Foo { A = 1, B = 5 }` parses | integration | `./testall.sh` | ✅ (09_language.sh extended) |
| TAMGA-01 | Codegen emits `A = 1,` in Zig output | integration | `grep "= 1" .orh-cache/generated/example.zig` | ✅ (09_language.sh check) |
| TAMGA-01 | Existing sequential enums unchanged | integration | `./testall.sh` (full suite) | ✅ (existing tests) |
| TAMGA-01 | `A(f32) = 4` is a parse error | negative | `./testall.sh` (11_errors.sh) | ❌ Wave 0 — fixture needed |

### Sampling Rate
- **Per task commit:** `zig build test && zig build`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `test/fixtures/fail_enum_value.orh` — covers TAMGA-01 negative (tagged union + explicit value is parse error)
- [ ] `test/09_language.sh` — add grep check for `= 4` or `= 44` in generated `example.zig`

---

## Sources

### Primary (HIGH confidence)
- `src/orhon.peg` lines 155–156 — current `enum_variant` rule, read directly
- `src/peg/builder.zig` lines 619–679 — `buildEnumDecl`, `buildEnumVariant`, `collectEnumMembers`, read directly
- `src/parser.zig` lines 226–230 — `EnumVariant` struct definition, read directly
- `src/mir.zig` lines 719–793, 1494–1496 — `MirNode` fields, `enum_variant` lowering branch, read directly
- `src/codegen.zig` lines 1100–1128 — `generateEnumMir` full function, read directly
- `src/main.zig` lines 1638–1669 — LSP hover enum formatter, read directly
- `src/docgen.zig` lines 285–314 — doc generator enum variant handling, read directly
- `src/declarations.zig` lines 323–344 — `collectEnum`, enum variant iteration, read directly

### Secondary (MEDIUM confidence)
- `.planning/phases/15-enum-explicit-values/15-CONTEXT.md` — user decisions D-01 through D-07
- `.planning/phases/15-enum-explicit-values/GOAL.md` — success criteria including example module update

---

## Metadata

**Confidence breakdown:**
- Grammar change: HIGH — rule location confirmed at line 155, token kinds verified
- AST struct change: HIGH — `EnumVariant` at line 226, field pattern matches `FieldDecl.default_value`
- MIR propagation: HIGH — `enum_variant` branch at line 1494 confirmed, `literal` field reuse verified
- Codegen change: HIGH — `generateEnumMir` at line 1111, conditional emit pattern is straightforward
- Builder approach (token-scan vs findChild): MEDIUM — token-scan guaranteed; findChild depends on capture tree behavior not directly verified

**Research date:** 2026-03-26
**Valid until:** 2026-04-26 (stable domain — no external library changes)
