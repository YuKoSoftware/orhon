# Orhon — TODO

---

## Bugs

### Codegen — cross-module struct ref-passing

When calling a method on an imported module's struct, the codegen doesn't know the
method's parameter types. If a parameter takes `const &T`, the codegen emits the
argument by value instead of taking its address with `&`. Zig then errors with
`expected type '*const T', found 'T'`.

Affected: any cross-module struct method with `const &` non-self parameters.
Workaround: use by-value parameters for cross-module struct methods.

Fix: codegen needs access to imported module DeclTables during method call generation,
or the MIR pass should annotate call arguments with the expected parameter passing mode.

### Resolver — qualified generic types not validated

`math.Vec2(f64)` passes resolver validation without checking that `Vec2` exists in the
math module's DeclTable. Currently, any dot-qualified generic type is trusted — validation
is deferred to Zig compile time. `math.Nonexistent(f64)` would pass the resolver silently.

Fix: resolver needs cross-module DeclTable access during `validateType()` for
`type_generic` nodes with qualified names.

### Ownership — const values treated as moved on by-value pass

Passing a `const` struct value to a function by value counts as a move. Using the same
const value in two separate calls errors with "use of moved value". Const values are
immutable and should be implicitly copyable — the ownership checker should treat by-value
passing of const values as a copy, not a move.

```
const a: Vec2(f64) = Vec2(f64)(x: 1.0, y: 2.0)
const b: Vec2(f64) = a.add(a)   // ERROR: use of moved value 'a'
```

### Stdlib — string interpolation leaks memory

`@{variable}` interpolation allocates temporary buffers that are never freed. Known
since early implementation. Fix after default allocator strategy matures.

### Codegen — `catch unreachable` in generated code

Thread shared state allocation and string interpolation emit `catch unreachable` in
the generated Zig code (`codegen.zig` lines 655, 688, 2123). This crashes on OOM
instead of propagating errors.

Fix: generated code should propagate allocation errors through the Zig error system.

### Stdlib — silent error suppression (`catch {}`)

103 instances of `catch {}` across 15 stdlib sidecar files silently swallow allocation
failures and I/O errors. Affected: collections, json, xml, yaml, csv, toml, ini, http,
fs, system, console, stream, regex, str, tui.

Fix: stdlib bridge functions should propagate errors back to the caller or use a
consistent error handling strategy.

---

## Polish

### Fuzz Testing

Use Zig's built-in `std.testing.fuzz` to fuzz the lexer and parser.

---

## Architecture

### PEG Grammar — Replace Hand-Written Parser

**Decision:** Replace the hand-written recursive descent parser with a PEG (Parsing
Expression Grammar) driven parser. The grammar file becomes the single source of truth
for all valid Orhon syntax.

**Why PEG over alternatives:**
- **No ambiguity by design** — ordered choice means exactly one parse path, always
- **Handles operator precedence naturally** — layered rules, no shift/reduce conflicts
- **Newlines as terminators** — explicit token control, fits Orhon's no-semicolon design
- **Human readable** — grammar rules read like the language spec itself

**Why not CFG/ANTLR/tree-sitter:**
- CFG (yacc/bison) needs separate lexer, can have ambiguity conflicts, more ceremony
- ANTLR is Java-based tooling, heavy, overkill
- Tree-sitter is for incremental editor reparsing, not compilation

**Benefits:**
- Grammar file replaces ~2000 lines of hand-written parser code
- Watertight by construction — if it's not in the grammar, it cannot parse
- New features = add a grammar rule, done. No touching multiple parser functions
- Grammar file doubles as the formal language spec — no drift between docs and code
- Downstream stages (MIR, codegen) can trust AST shape without defensive checks
- Clean pipeline: grammar handles syntax, MIR handles semantics, no overlap
- Velocity increases over time instead of decreasing
- Syntax changes become trivial — edit one rule, not scattered parser functions

**Pipeline with PEG:**
1. **Grammar parser** — rejects anything structurally wrong (syntax)
2. **MIR** — rejects anything semantically wrong (types, scopes, lifetimes)
3. **Codegen** — straightforward translation, zero defensive checks

**Implementation plan:**
1. Write `docs/orhon.peg` — formal PEG grammar matching current parser exactly
2. Build a small PEG engine in Zig that reads the grammar and produces the same AST
3. Run both parsers side by side, verify identical output on all test fixtures
4. Swap out the old parser, delete the hand-written parsing functions

### MIR Phase 4 — Optimization + Caching

Selective optimization passes — only where Orhon has type knowledge that Zig/LLVM lacks.
Inspired by vnmakarov/MIR's philosophy: pick high-impact passes, skip what the downstream compiler already handles.

**4a — SSA construction.** Flatten MirNode tree to basic blocks, build SSA form using Braun's
algorithm (simple, no dominance frontiers needed). Each value gets a single definition, phi
nodes at join points. This is the foundation — all subsequent passes run on SSA form.

**4b — Inlining.** Identify inline candidates: bridge wrappers, single-expression functions,
generated coercion wrappers. Substitute at call sites. SSA makes substitution clean (no
variable name collisions). Reduces emitted Zig volume and gives LLVM better input.

**4c — Dead code elimination.** Trivial on SSA: if an SSA value has no uses, delete it.
Reachability analysis from entry points, skip emission of unreachable code. Less emitted
Zig = faster Zig compilation.

**4d — Type-aware constant folding.** Fold `@type(x) == T` when statically known, eliminate
redundant wrap/unwrap coercion chains, simplify coercion sequences. Single definitions mean
constants propagate in one pass.

**4e — MIR caching.** Binary serialization/deserialization of SSA IR per module. Cache
invalidation via file content hashing. Skip annotation + lowering for unchanged modules on
incremental rebuilds.
