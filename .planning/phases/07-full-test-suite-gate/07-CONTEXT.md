# Phase 7: Full Test Suite Gate - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Make `./testall.sh` pass all 11 stages with zero failures. Currently 232 passed, 6 failed. Fix the 2 root causes: (1) stale null union codegen test checking for removed `OrhonNullable` type, (2) PEG builder missing string interpolation support.

</domain>

<decisions>
## Implementation Decisions

### Null union codegen test (1 failure in stage 09)
- **D-01:** The test `grep -q "OrhonNullable" "$GEN_TESTER"` checks for a legacy wrapper type that was removed when native Zig `?T` optionals were adopted (v0.9.7). The codegen is correct — the test is stale.
- **D-02:** Fix the test in `test/09_language.sh` to check for the native `?` optional pattern instead of `OrhonNullable`.

### String interpolation (4 failures in stage 10 + 1 aggregate)
- **D-03:** The PEG grammar has `STRING_LITERAL` with a comment "may contain @{expr} interpolation" but the builder (`src/peg/builder.zig`) has no interpolation handling. Strings with `@{expr}` are treated as plain string literals.
- **D-04:** The codegen already has full interpolation support (`generateInterpolatedString` and `generateInterpolatedStringMir`) — it just never receives interpolation nodes from the PEG builder.
- **D-05:** Fix approach: Add interpolation detection in the PEG builder. When a `STRING_LITERAL` contains `@{`, split it into an `interpolated_string` AST node with `.literal` and `.expr` parts. The parser already defines `InterpolatedString` and `InterpolationPart` types.
- **D-06:** The PEG grammar itself may need a rule change — either split `STRING_LITERAL` into two token types at the lexer level, or handle interpolation in the builder by post-processing string literals.

### Claude's Discretion
- Whether to handle interpolation at the PEG grammar level (new rules) or the builder level (post-process STRING_LITERAL)
- Exact pattern for detecting and splitting `@{expr}` in strings
- Whether nested interpolation `@{a ++ @{b}}` needs handling (probably not for now)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Null union test
- `test/09_language.sh` — lines checking `OrhonNullable`, `.none`, `.some` in generated tester.zig

### String interpolation — PEG/builder
- `src/orhon.peg` line 416 — STRING_LITERAL comment about interpolation
- `src/peg/builder.zig` — no interpolation handling (gap)
- `src/lexer.zig` — STRING_LITERAL tokenization (does it preserve `@{...}`?)

### String interpolation — existing AST + codegen
- `src/parser.zig` — `InterpolatedString`, `InterpolationPart` types (already defined)
- `src/codegen.zig` lines 2577-2620 — `generateInterpolatedString` (AST path, with new defer-free)
- `src/codegen.zig` lines 2982-3040 — `generateInterpolatedStringMir` (MIR path)
- `src/mir.zig` — `interp_parts`, `.interpolation` kind, `LiteralKind.interp_lit`

### Test fixtures
- `test/fixtures/tester.orh` — `test_interpolation()` and `test_interpolation_int()` functions
- `test/10_runtime.sh` — runtime test that runs compiled tester and checks output

### Phase 6 interpolation work
- `.planning/phases/06-polish-completeness/06-01-SUMMARY.md` — defer-free fix details

</canonical_refs>

<code_context>
## Existing Code Insights

### Full Interpolation Pipeline Already Exists
The entire pipeline from AST → MIR → codegen is implemented. The ONLY missing piece is the PEG builder creating `interpolated_string` nodes from `STRING_LITERAL` tokens that contain `@{`.

### Lexer Preserves `@{...}`
The lexer captures the full string literal including `@{expr}` — it doesn't strip or interpret them. The builder needs to detect `@{` in the captured string and split into parts.

### Parser Types Ready
```zig
pub const InterpolationPart = union(enum) {
    literal: []const u8,
    expr: *Node,
};
pub const InterpolatedString = struct {
    parts: []InterpolationPart,
};
```

### Test Is Simple to Fix
The null union test just needs `grep -q "OrhonNullable"` changed to check for `?` (native Zig optional syntax).

</code_context>

<specifics>
## Specific Ideas

No specific requirements — fix the 2 root causes and the gate passes.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 07-full-test-suite-gate*
*Context gathered: 2026-03-25*
