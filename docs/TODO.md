# Orhon — TODO

Actionable items for the current development phase. Deferred and future work is in [[future]].

---

## Architectural Cleanup

Discovered during a 2026-04-12 codebase audit. Grouped by sequencing batch — finishing
a whole batch in one pass leaves the touched area cleaner than picking single items.

### Batch B — Coercion + emission tightening `small` (each)

#### Duplicated unwrap-binding logic (partially done)
**`src/codegen/codegen_match.zig:548,619`** — The unwrap pattern (`.?` for null,
`catch` for error, `._tag` for union) still has one inline copy in the match-arm
codegen path. The `codegen_stmts.zig` / `codegen_exprs.zig` copies were folded into
the shared `codegen.valueUnwrapForm` helper. Folding the match-arm copy requires
first untangling its `pre_stmts` / interpolation hoisting context.

### Batch C — Layering fix `medium`

Highest architectural payoff: turns codegen into the mechanical lowering layer it
claims to be. Both findings should land together.

#### Codegen does name resolution it shouldn't
**`src/codegen/codegen.zig:182-203, 323-332`** (`isEnumVariant`, `isEnumTypeName`,
`isErrorConstant`) — Three methods on `CodeGen` query `self.decls` at emit time to
classify identifiers. The MIR annotator should set `resolved_kind` on every
identifier; codegen should only read MIR fields.

#### `@overflow` operand types resolved by codegen guessing
**`src/codegen/codegen_match.zig:864-909`** — When `@overflow` operands are literals,
`@TypeOf` gives `comptime_int`, so codegen falls back to walking `cg.type_ctx`. This
is type inference happening during emit. The annotator should compute and store the
effective operand types; codegen reads them.

### Standalone — Cache format `medium`

#### Cache serialization is hand-rolled, unversioned, fragile
**`src/cache.zig:72-134, 250-280, 318-368`** — Tab/comma/newline parsing with no
escaping and no schema version. A module name with a tab silently corrupts the cache.
Migrate to ZON (preferred — already used for `.zon` configs) or `std.json`. Unifies
all five cache files behind one structured format.

### Larger refactors — Discuss before doing `large`

These need brainstorming first; they're design-loaded, not mechanical.

#### `MirNode` carries load-bearing optional string fields
**`src/mir/mir_node.zig:33-51`** (`coerce_tag`, `narrowed_to`, `name`) — Multiple
optional strings whose meaning depends on which other fields are set. Codegen has to
check field combinations like `if (coercion == .arbitrary_union_wrap and coerce_tag != null)`.
Cleaner: tighten the schema by moving optional metadata into the variants of the
tagged unions that need them. `CoercionResult` was converted to a tagged union in a
prior pass; the broader cleanup pushes that same shape into `MirNode` itself so the
readers in `mir_annotator_nodes.zig` can stop flattening the variant back out.

#### `DeclTable`'s seven parallel StringHashMaps
**`src/declarations.zig:83-92`** — `funcs`, `structs`, `enums`, `handles`, `vars`,
`types`, `blueprints` — adding a new declaration kind requires touching 7 places.
Could be one `StringHashMap(Declaration)` over a `union(enum)`. Trade-off: existing
code reads naturally as `decls.structs.get(name)`; the unified form is
`decls.get(.struct, name)`. Worth doing only if new declaration kinds are imminent.

#### `resolver.zig` is 2041 lines doing two passes' worth of work
**`src/resolver.zig`** — Mixes declaration registration with type resolution. The
pipeline already labels these as separate passes (4 and 5). Extract declaration
collection into a `resolver_decls.zig` hub aligned with the pass boundary.

#### `main.zig` command dispatch is a long if-chain
**`src/main.zig:25-93`** — 11 sequential `if (cli.command == .X)` blocks. Table-driven
dispatch via a `[_]struct{ cmd, handler }` array makes adding a command a one-line
data change. Low risk because it's at the entry point.

#### Implicit dependency tracking via interface-hash diffing
**`src/pipeline.zig:336-365`** — The recompilation decision walks `mod_resolver.modules`,
`comp_cache.deps`, and per-file hash maps to derive a graph that's never made explicit.
Building an actual `BuildGraph` data structure once and topologically sorting it would
centralize the logic and unblock future parallel builds. Only worth doing if parallelism
is on the roadmap.

### Lower-confidence findings — Verify before acting

The audit flagged these but flagged them as "may be by design" or "low confidence."
Read the call sites first; some may turn out to be intentional.

#### ~~`K.Type` constants compared via string equality~~ (verified intentional, 2026-04-13)
**~50 occurrences** reviewed. Most are load-bearing string work: AST `type_named` field
comparisons (pre-resolution), constructed AST/MIR nodes, user-written identifier
comparisons in match patterns, and builtin-name whitelist lookups. The only sites that
could genuinely become variant checks are the ~5 in `mir_lowerer.zig` /
`codegen_stmts.zig` narrowing path, and those are downstream of the "MirNode optional
string fields → tagged union" Larger-refactor item below — folding them in isolation
would be duplicate work. No action on K.Type itself.

#### ~~Interpolation hoisting via ad-hoc `pre_stmts` buffer~~ (verified intentional, 2026-04-13)
**`src/codegen/codegen.zig:65,306-308`** and **`codegen_match.zig:568-625`** — Reviewed.
The two options were "move into MirLowerer" or "rename for clarity." Both are wrong:
- **MirLowerer option** is architecturally mismatched. The hoisted temp is a
  `std.fmt.allocPrint` call with a Zig format string plus a `defer free`, built by
  redirecting `cg.output` into `pre_stmts` so the existing `generateExprMir` can
  walk the child MIR nodes. That machinery is Zig-backend-specific — MirLowerer
  doesn't know about `allocPrint`, `{s}`/`{}` format specifiers, or `smp_allocator`,
  and shouldn't. Keeping hoisting in codegen is correct.
- **Rename option** is cosmetic. `pre_stmts` already has a clear doc comment at
  `codegen.zig:63-64`, single-purpose use (only written by the interpolation emitter),
  and only two flush points (`codegen_stmts.zig:31,137`). Renaming to
  `interpolation_hoist` gains nothing except at the field declaration site.

No action. The architecture is load-bearing.

#### ~~`codegen_match.zig` may want to split further~~ (verified, not actionable alone, 2026-04-13)
**`src/codegen/codegen_match.zig` (1061 lines)** — Reviewed. The file is still
well-commented, function-boundaries are clean, and size growth since the audit is
trivial (~20 lines). Won't split as a standalone task.

The real finding: the file's name says "match" but ~300 lines of it handle arithmetic
compiler intrinsics (`@overflow`, `@wrapping`, `@saturating`, `@type`, introspection)
that have nothing to do with pattern matching. If this file ever needs other
structural work, the cleanest extraction is a `codegen_compt.zig` satellite holding
`generateCompilerFuncMir`, `emitIntrospectionType`, and the overflow/wrapping/
saturating helpers — NOT the `codegen_match_compt.zig` name the audit proposed,
which buries the mismatch.

---

## Developer Experience

### LSP — feature-gated passes `medium`

Gate passes by request type instead of running 1–9 on every change:
- **Completion:** passes 1–4 (parse + declarations)
- **Hover:** passes 1–5 (+ type resolution)
- **Diagnostics:** passes 1–9, debounced 100–300ms

Add cancellation tokens for in-flight analysis.

### LSP — incremental document sync `hard`

Full reparse on every keystroke. No incremental updates, no background compilation,
limited completion context.

---

## Testing

### Incremental cache skip verification `medium`

`test/05_compile.sh` only checks that rebuild succeeds and hashes file exists.
It does not verify that unchanged modules are actually skipped. Add a test that
builds twice without changes and verifies generated `.zig` timestamps are unchanged.

### Property-based pipeline testing `medium`

- Parse then pretty-print should round-trip
- Type-checking the same input twice should give identical results
- Codegen output should always be valid Zig (`zig ast-check`)

---

## Architectural Decisions (Settled)

| Decision | Rationale |
|----------|-----------|
| Fix bugs before architecture work | Correctness before performance/elegance |
| Pointers in std, not compiler | Borrows handle safe refs; std::ptr is the escape hatch |
| Transparent (structural) type aliases | `Speed == i32`, not a distinct nominal type |
| Allocator via `.withAlloc(alloc)`, not generic param | Keeps generics pure (types only) |
| SMP as default allocator | GeneralPurposeAllocator optimized for general use |
| Zig-as-module for Zig interop | `.zig` files auto-convert to Orhon modules |
| Explicit error propagation via `if/return` | No hidden control flow, no special keywords |
| Parenthesized guard syntax `(x if expr)` | Consistent with syntax containment rule |
| Hub + satellite split pattern | All large file splits use same pattern for consistency |
| `is` restricted to if/elif only | Narrowing only works in if/elif; `@typeOf` covers other contexts |
| `blueprint` for traits, not `impl` blocks | Everything visible at the definition site |
| No Zig IR layer in codegen | Direct string emission. MIR/SSA is the optimization target |

---

## Explicitly NOT Adding

| Feature | Why Not |
|---------|---------|
| Macros | `compt` covers the use cases without readability costs |
| Algebraic effects | Too complex. Union-based errors + Zig module I/O is sufficient |
| Row polymorphism / structural typing | Contradicts Orhon's nominal type system |
| Garbage collection | Contradicts systems language positioning. Explicit allocators |
| Exceptions | Union-based errors are better for compiled languages |
| Operator overloading | Leads to unreadable code. Named methods are clearer |
| Multiple inheritance | Composition via struct embedding is sufficient |
| Implicit conversions | Explicit `@cast()` is correct. Implicit conversions cause subtle bugs |
| Refinement types | Struct-validation pattern already covers this |
| Full Polonius borrow checker | Overkill. NLL gives 85% of the benefit for 30% of the work |
| Zig IR layer in codegen | Would model Zig semantics inside the compiler |
| Arena allocator pairing syntax | `.withAlloc(alloc)` already covers composed allocators via Zig module |
| `#derive` auto-generation | Blueprints require explicit implementation. No implicit anything |
| `#extern` / `#packed` struct layout | `.zig` modules already support these natively |
| `async` keyword | Wait for Zig's new async design, then map cleanly. `std::thread` + `thread.Atomic` covers parallelism |
| Compound `is` (`and`/`or`) | Narrowing can't handle multiple simultaneous type checks. Use nested ifs |
| `is` outside if/elif | `is` is a narrowing construct, not a general operator. Use `@typeOf` for type checks |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
