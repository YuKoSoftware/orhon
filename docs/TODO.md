# Orhon — TODO

Actionable items for the current development phase. Deferred and future work is in [[future]].

---

## Compiler Bugs

### `_unions` cross-import for root-module user types `medium`

Arbitrary unions whose members include user types from the *root* module fail at the
Zig build step. Codegen emits `_unions.zig` containing `@import("rootmod")`, but
`src/zig_runner/zig_runner_multi.zig` only cross-wires shared `mod_*` modules — root
modules aren't in `shared_set`, so the import is never wired and Zig errors with
`no module named 'rootmod' available within module '_unions'`.

Reproduces with a 2-member `(A | B)` local var where A/B are same-module structs.
Affects type-alias unions and inline arbitrary unions equally. Fix lives in the
cross-wire pass in `zig_runner_multi.zig`.

Discovered while resolving GAP-005 (2026-04-12). Tracked in tamga's `compiler-gaps.md`.

---

## Architectural Cleanup

Discovered during a 2026-04-12 codebase audit. Grouped by sequencing batch — finishing
a whole batch in one pass leaves the touched area cleaner than picking single items.

### Batch A — Free wins `small` (each)

#### `NodeInfo.type_class` is derived state with sync risk
**`src/mir/mir_types.zig:56-62`** — `type_class` is computed via
`classifyType(resolved_type)` at every NodeInfo construction. If anyone updates
`resolved_type` without recomputing, codegen reads stale classification. Make it a
method, not a field.

#### `struct_methods` string-key concatenation
**`src/declarations.zig:92`, `src/mir/mir_annotator.zig:199-205`** — `StringHashMap`
keyed by `"StructName.method"` built via `allocPrint` at every lookup. Replace with
nested `StringHashMap(StringHashMap(FuncSig))`. Removes per-call string building and
the silent-failure footgun if format ever drifts.

#### Defer-cleanup boilerplate in `pipeline.zig`
**`src/pipeline.zig:578-619`** — Seven near-identical defer blocks freeing
`[][]const u8` collections. One `OwnedSliceList` wrapper type with a single `deinit`
replaces all of them.

#### `reportFmt()` adoption is incomplete
**`src/errors.zig:82-86`** — The reporter already provides a fmt-style helper that
handles allocation and freeing. Most call sites still do manual `allocPrint` +
`defer free` + `report`. Mechanical batch replacement.

### Batch B — Coercion + emission tightening `small` (each)

Bundle these with the `_unions` generic factory implementation — they all touch the
same area and benefit from being done together.

#### `CoercionResult` should be a tagged union
**`src/mir/mir_annotator.zig:157-160`** — Currently
`{ kind: ?Coercion, tag: ?[]const u8 }` where `tag` is only meaningful for one kind.
Replace with `union(enum) { none, simple: Coercion, wrap_union: struct { ... } }`.
Forces exhaustive handling, makes the invariant load-bearing in the type system.

#### Sidecar-emission decision scattered across 8 sites
**`src/codegen/codegen_decls.zig` (multiple) + `codegen.zig:391`** — `is_zig_module` /
`has_zig_sidecar` checked in eight places, each making the same emit-vs-re-export
call. Centralize in one `shouldEmitDeclMir(kind, m)` predicate.

#### Duplicated unwrap-binding logic
**`src/codegen/codegen_stmts.zig:43-92` and `:110-187`** — The unwrap pattern (`.?`
for null, `catch` for error, `._tag` for union) is implemented twice — once for match
arms, once for narrowing. Make `emitUnwrapBindingNamed` the single source.

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
tagged unions that need them. The `_unions` plan addresses `coerce_tag` specifically;
this is the broader version.

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

#### `K.Type` constants compared via string equality
**~30 occurrences** including `src/codegen/codegen_decls.zig:43,45`,
`src/codegen/codegen_stmts.zig:49,214`, `src/codegen/codegen_exprs.zig:214` — Patterns
like `std.mem.eql(u8, ret_type.type_named, K.Type.VOID)` repeated throughout. Cleaner
form is an `enum(u32)` tag set during MIR annotation so `type_class` carries the right
variant directly. May be intentional for AST compatibility — verify before changing.

#### Interpolation hoisting via ad-hoc `pre_stmts` buffer
**`src/codegen/codegen.zig:62,258-261`** and **`codegen_match.zig:570-609`** — The
`pre_stmts` buffer exists solely to hoist interpolation temp-var declarations before
the statement that uses them. Manual flush at statement boundaries via
`flushPreStmts`. Either move the hoisting into `MirLowerer` (`temp_var` injection
already exists for related cases) or rename it into a `InterpolationHoist` named
type with documented semantics. Possibly intentional architecture.

#### Manual deep-dup helpers
**`src/pipeline.zig:878-893`** (`dupSliceOfSlices`, `dupModuleTypes`) — Two helpers
that exist solely to clone sequences of slices/structs. The pattern repeats in
`cache.zig`. Consolidate into a single utilities module, or — better — make the
ownership flow not require deep copies in the first place by using arena allocators
across the boundaries that currently need duping.

#### `codegen_match.zig` may want to split further `medium`
**`src/codegen/codegen_match.zig` (1041 lines)** — Already well-commented and
function-split, but handles plain match, type match, string match, range patterns,
guarded match, interpolation, and compiler functions in one file. Could split into
`codegen_match_patterns.zig` (range/guard/string/plain) and a `codegen_match_compt.zig`
satellite. Low priority — the file is well-structured as-is.

### Skipped: already covered by the `_unions` generic factory plan

For audit completeness — these were flagged but are already addressed by the
in-flight redesign at `docs/superpowers/specs/2026-04-12-unions-generic-factory-design.md`:

- `mir_registry.canonicalize` manual canonical name building → comptime memoization
- Union cache entry redundancy (`module_types`, name strings) → drop the cached
  derived data
- `inferArbitraryUnionTagMir` re-deriving tags at every emit → positional tags
  computed once via `union_sort` helper

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
