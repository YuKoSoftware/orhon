# Phase 23: Pattern Guards - Context

**Gathered:** 2026-03-27
**Status:** Ready for planning
**Source:** Conversation with user

<domain>
## Phase Boundary

Add pattern guard syntax to match arms so arms only fire when both the pattern matches and an optional `if` guard expression evaluates to true. Also introduces required parentheses for compound patterns (ranges, bindings with guards).

</domain>

<decisions>
## Implementation Decisions

### Match Arm Syntax
- Match test goes inside `()` followed by `=>` and then a block `{}`
- `else` does NOT need parentheses — stays bare
- Single literals (`42`, `"hello"`) and single identifiers (`North`, `Error`, `i32`) can omit parentheses
- Ranges MUST use parentheses: `(1..10) => { ... }`
- Bindings with guards MUST use parentheses: `(x if x > 0) => { ... }`
- Any compound pattern requires parentheses

### Guard Syntax
- Guard syntax: `(binding if guard_expr)` — the `if` keyword separates the binding from the guard expression
- Guard expression can reference the bound variable and variables from the enclosing scope
- Guards are optional — a match arm can be a bare value, a parenthesized pattern, or a pattern with guard

### Mixing
- Guarded and unguarded arms can coexist freely in the same match block
- All match types (value, range, string, type, enum) can be mixed with guarded arms

### Exhaustiveness
- When guards are present, the compiler should require an `else` arm since guards don't guarantee coverage

### Migration
- Existing bare range patterns (`1..3 =>`) become `(1..3) =>` — only 4 lines across 2 files need updating

### Examples (user-approved syntax)
```orh
match(value) {
    // bare — single literal or identifier
    0           => { ... }
    "hello"     => { ... }
    North       => { ... }
    Error       => { ... }

    // parens — ranges, bindings, guards
    (1..10)             => { ... }
    (x if x > 50)       => { ... }
    (Circle if Circle.radius > 5) => { ... }

    // else — always bare
    else => { ... }
}
```

### Claude's Discretion
- Internal AST representation for guard nodes
- PEG grammar rule structure for parenthesized patterns
- MIR annotation approach for guard expressions
- Codegen strategy (likely desugar to nested if inside switch arm)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Grammar and Parser
- `src/orhon.peg` — PEG grammar rules for match_stmt and match_pattern
- `src/peg/builder.zig` — AST builder that creates match nodes from PEG captures
- `src/parser.zig` — NodeKind enum, Node union, MatchStmt and MatchArm structs

### Semantic Passes
- `src/sema.zig` — SemanticContext shared by validation passes
- `src/propagation.zig` — Error propagation checker (may need guard awareness)
- `src/resolver.zig` — Type resolver (needs to resolve guard expressions)

### Code Generation
- `src/codegen.zig` — generateMatchMir() handles match codegen (3 strategies: string, type, value)
- `src/mir.zig` — MIR annotation table, MirAnnotator, MirLowerer

### Control Flow Docs
- `docs/07-control-flow.md` — Match statement documentation
- `docs/08-error-handling.md` — Error union matching

### Existing Match Examples
- `src/templates/example/control_flow.orh` — Example module match demos
- `test/fixtures/tester.orh` — Runtime test match cases
- `test/fixtures/fail_match.orh` — Negative match tests

</canonical_refs>

<specifics>
## Specific Ideas

- The `if` keyword inside `()` is unambiguous in match context since `if` can't appear as a standalone expression there
- Ranges are the only existing pattern type that gains a parentheses requirement (4 lines to update)
- Codegen can desugar `(x if guard)` to a conditional inside the switch arm body

</specifics>

<deferred>
## Deferred Ideas

None — phase scope is well-defined.

</deferred>

---

*Phase: 23-pattern-guards*
*Context gathered: 2026-03-27 via conversation*
