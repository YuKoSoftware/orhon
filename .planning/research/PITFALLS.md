# Domain Pitfalls

**Domain:** Programming language design and evolution
**Researched:** 2026-03-27

## Critical Pitfalls

Mistakes that cause rewrites, community fractures, or language identity loss.

### Pitfall 1: Feature Creep Destroys Simplicity
**What goes wrong:** Adding features because other languages have them, not because users need them. Each feature seems small in isolation but compounds in complexity -- interactions between features grow quadratically.
**Why it happens:** Every language designer sees elegant features in other languages and wants to incorporate them. Users request features from languages they already know.
**Consequences:** The language becomes "another Rust" or "another C++" -- losing its identity. Compilation slows. Error messages degrade. New users face a steeper learning curve.
**Prevention:** Every proposed feature must pass the "simplicity tax" test: does this feature's benefit outweigh the complexity it adds to (a) the compiler, (b) error messages, (c) the learning curve, (d) feature interactions? If the answer is unclear, don't add it.
**Detection:** Warning sign: "we need X to implement Y properly" chains longer than 2 features deep.

### Pitfall 2: Breaking Changes Without Migration
**What goes wrong:** Changing syntax or semantics of existing features, breaking user code without a clear migration path.
**Why it happens:** Better design insights come from real usage. The temptation is to "just fix it now" before more code depends on the old behavior.
**Consequences:** User trust erosion. Community fragmentation (some stay on old version). Projects abandoned.
**Prevention:** Deprecation warnings for at least one release before removal. Migration guides for every breaking change. Consider edition system (like Rust editions) for accumulated changes.
**Detection:** Check if any change would break the example module or Tamga.

### Pitfall 3: Trait System Scope Explosion
**What goes wrong:** Starting with "minimal traits" but then needing associated types, then default methods, then trait objects, then trait aliases, then negative impls, then specialization -- each addition justified by real needs.
**Why it happens:** Traits/interfaces are inherently extensible. Every real-world use case reveals another needed capability.
**Consequences:** The type system becomes Rust's, which is the exact thing Orhon aims to avoid.
**Prevention:** Ship traits with ONLY: method declarations, explicit `impl` blocks, `any where Trait` bounds. No associated types, no default methods, no trait inheritance, no `dyn`. Review after 6 months of usage before adding anything.
**Detection:** If implementing a trait feature requires modifying more than 3 compiler passes, it's probably too complex.

### Pitfall 4: Closure Ownership Footgun
**What goes wrong:** Closures capture variables in ways that violate ownership expectations. User creates a closure in a loop, captures a variable, variable is moved/invalidated, closure use is a use-after-move.
**Why it happens:** Closures interact with ownership in subtle ways. The happy path is obvious but edge cases are treacherous.
**Consequences:** Users encounter confusing ownership errors when using closures. Closures feel "unsafe" or "unreliable."
**Prevention:** Keep closure capture rules identical to thread capture rules (already implemented). Move by default for `var`, auto-borrow for `const`. No implicit mutable captures. The compiler should refuse to compile closures that would create ownership violations, with clear error messages explaining what was captured and why it's invalid.
**Detection:** Write closure test cases that intentionally trigger every ownership edge case before shipping.

## Moderate Pitfalls

### Pitfall 1: Error Message Regression
**What goes wrong:** Adding new features degrades error messages for existing features. A new AST node type is unhandled in an error path, producing a generic "unexpected error" instead of a helpful message.
**Prevention:** Every new feature must include negative tests (expected compilation failures with verified error messages). The test/11_errors.sh stage is the gate.

### Pitfall 2: Codegen Growth Without Layering
**What goes wrong:** Codegen.zig grows beyond 5000 lines with interleaved concerns (coercion, emission, bridge handling, trait dispatch).
**Prevention:** The TODO already identifies the 3-layer split (Zig IR + Lowering + Printer). Do this before adding traits or closures to codegen. New features on a clean architecture are cheaper than new features on a monolith.

### Pitfall 3: `try` Ambiguity with Existing Error Handling
**What goes wrong:** Users confused about when to use `try` vs explicit `if(result is Error)` pattern. Both work but have different trade-offs.
**Prevention:** Clear documentation: `try` propagates to caller (function must return Error union). `if(result is Error)` handles locally. Both are valid. `try` is sugar for the common case.

### Pitfall 4: Derive Without Customization Path
**What goes wrong:** `#derive(Eq)` generates field-by-field equality, but user needs custom equality (e.g., ignore a cache field). No way to partially derive or override.
**Prevention:** `#derive` and manual `impl` should both work. If you write `impl Eq for T` manually, `#derive(Eq)` is ignored/errored for that type. Manual impl always wins.

### Pitfall 5: Web Playground Security
**What goes wrong:** Running arbitrary user code on a server creates security vulnerabilities.
**Prevention:** Compile to WASM and run in browser sandbox. No server-side execution. If server-side is needed, use strict sandboxing (time limits, memory limits, no filesystem, no network).

## Minor Pitfalls

### Pitfall 1: Keyword Collision
**What goes wrong:** New keywords (`try`, `trait`, `impl`) conflict with existing user identifiers in `.orh` code.
**Prevention:** Check the example module and Tamga for uses of proposed keywords. If collision exists, choose a different keyword or provide a migration release with warnings.

### Pitfall 2: Tree-sitter Grammar Drift
**What goes wrong:** PEG grammar and tree-sitter grammar diverge, causing highlighting bugs in some editors.
**Prevention:** Generate tree-sitter grammar from PEG, or maintain both with shared test suite.

### Pitfall 3: Over-Documenting During Design
**What goes wrong:** Writing extensive documentation for features still in design, then needing to rewrite docs when design changes.
**Prevention:** For in-progress features, use the TODO.md format (brief description + status). Full documentation only after implementation is stable.

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| `try` keyword | Ambiguity with existing error handling | Clear docs, both patterns valid |
| Traits | Scope explosion (associated types, trait objects, etc.) | Hard limit: methods only for v1. Review after 6 months |
| Closures | Ownership interaction complexity | Mirror thread capture semantics exactly |
| `#derive` | No customization escape hatch | Manual impl always overrides derive |
| Generic constraints | Complex error messages when constraint not satisfied | "Type X does not implement Trait Y" with suggestion to add impl |
| C/C++ compilation | Build system complexity | Keep it simple: `#compile "file.c"` directive, let Zig handle the rest |
| Web playground | Security, maintenance burden | WASM-in-browser only, no server execution |
| Async | Colored function problem (async/non-async split) | Study Zig's approach; consider making async transparent |

## Sources

- Training data on Rust evolution pitfalls, C++ committee lessons, Swift generics evolution (MEDIUM confidence)
- Orhon TODO.md, Tamga bugs.txt (direct observation)
- Programming language design community discourse patterns (LOW-MEDIUM confidence)
