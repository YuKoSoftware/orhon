# Orhon — TODO

Items ordered by importance and how much they unblock future work.

---

## Core — Language Ergonomics

### Data-carrying enums (tagged unions) `hard`

Specced in `docs/10-structs-enums.md` (lines 145-150) but broken across the pipeline.
Variant field information is dropped at every stage:

1. **EnumSig** (`declarations.zig`) — only stores variant names, no field info
2. **MIR lowerer** (`mir_lowerer.zig:570-577`) — copies only name/value, drops fields
3. **Codegen** (`codegen_decls.zig:286-318`) — always emits `enum(backing)`, never `union(enum(backing))`
4. **Resolver** — no validation of variant field types

Needs a vertical slice: extend EnumSig with VariantSig (fields list), carry fields
through MIR, emit `union(enum(backing))` in codegen for data-carrying variants,
validate field types in resolver. Also: reject variants that have both data fields
AND explicit integer discriminants (currently produces confusing Zig error).

Simple value enums work correctly — this only affects data-carrying variants.

### Review metadata directives (`#version`, `#build`, `#dep`) `medium`

Remaining questions:
- Should `#dep` move to `.zon` files (like C deps already do)?
- Is `#dep` tested? (Currently zero tests)
- Should metadata be unified into one system instead of split between `#` directives and `.zon`?

`#name` removed entirely — binary name always comes from the module name.
Not blocking zero-magic work — metadata doesn't touch codegen. But needs a design pass.

### Mixed numeric type checking and for-loop index type `medium`

The spec says "mixing numeric types is a compile error" but the check is not yet
enforced. Design decision needed on automatic widening rules:

**Same-family widening (automatic, lossless):**
- `i32 + i64` → `i64`, `f32 + f64` → `f64`, `u8 + u32` → `u32`

**Cross-family mixing (require `@cast`):**
- `i32 + f64` → error (int/float)
- `u32 + i32` → error (signed/unsigned)
- `usize + i32` → error (platform-dependent size)

Also blocked on for-loop index type — currently `usize`. Options:
- Typed index: `for (arr) |val, i: i32| { }`
- Default index to `i32` instead of `usize`
- Keep `usize` and require explicit `@cast`

Once resolved, enable mixed numeric type checking in `resolver_exprs.zig`.

### std::thread limitations `medium`

Known Zig comptime friction with Orhon codegen:
- **No top-level `spawn()` convenience** — Zig-to-Orhon converter can't handle `anytype` params.
  Users must write `thread.Thread(i32).spawn(func, arg)` instead of `thread.spawn(func, arg)`.
- **spawn/spawn2 arity split** — `spawn(func, arg)` for 1-arg, `spawn2(func, a, b)` for 2-arg.
  Zig's `@call` needs a tuple but Orhon passes individual values. Needs spawn3+ for more args.

### Tuple math (element-wise arithmetic, scalar broadcast) `hard` — DEFERRED

Specced in `docs/04-operators.md` but not implemented. Needs codegen expansion to
per-field operations and scalar broadcast wrapping. No current use cases in Tamga.

### Automatic error propagation `medium`

`propagation.zig:374-376` comments say unhandled error unions in error-returning
functions will "automatically propagate with trace." But no codegen implements this.
Unhandled `(Error | T)` in a function returning `(Error | T)` is silently allowed
but the error value is discarded at runtime. Either implement auto-propagation
(insert `try`-like unwrap in codegen) or always reject unhandled unions.

### `(null | Error | T)` remaining gaps `medium`

- `is Error` codegen (`codegen_exprs.zig`) — generates `if (x) |_| false else |_| true`
  which unwraps the optional, not the error union. Needs two-step: null check then
  error check.
- Narrowing fallback (`codegen_exprs.zig:305-307`) — after `is null` narrowing on
  `(null | Error | T)`, `.value` generates `.?` but should generate `catch unreachable`
  since null is already eliminated.

### `compt for` — implement grammar and builder `medium`

Spec documents `compt for(fields) |field| { ... }` but grammar only supports
`compt func`. `ForStmt.is_compt` field exists, codegen handles it (`inline for`),
but builder hardcodes `is_compt = false`. Need to add `'compt'?` prefix to `for_stmt`
grammar rule and set the flag in the builder.

### Consuming method calls not tracked by ownership checker `medium`

Methods with `self: T` (by value, not borrow) should move the receiver and mark it
invalid after the call. Currently `ownership_checks.zig:204` always passes
`is_borrow=true` for method receivers. `p.destroy(); p.use()` is not caught.
Needs: look up method signature, check if self param is by value, mark receiver moved.

### Method/cross-module call argument count validation `medium`

`resolver_exprs.zig:198` looks up method signatures for return type but doesn't
validate argument count. Direct identifier calls (line 175) do validate. Add the
same arity check for `field_expr` callee paths (method calls and `module.func()` calls).

Complications: `use`-imported struct methods appear in `funcs` with implicit `self` param;
zig-module auto-generated stubs don't expose inner struct methods; generic return types
(e.g., `List(i32)`) don't register methods. Self parameter detection (instance vs static)
needs careful handling across all lookup paths.

### Interpolated strings in non-hoisted positions produce invalid Zig `medium`

`findInterpolation` in `mir_lowerer.zig` only hoists interpolated strings in var_decl,
call args, assignment, and return. In other positions (if conditions, binary exprs,
match arms), the codegen fallback emits the temp var after its use, producing invalid
Zig (use-before-declaration). Either expand `findInterpolation` to recurse all
expression positions, or restructure pre_stmts flushing.

### Array literal resolver returns element type, not array type `medium`

`resolver_exprs.zig:393` returns the first element's type (e.g., `i32`) instead of
an array type. This breaks `array_to_slice` coercion detection in the MIR annotator.
`var arr: []i32 = [1, 2, 3]` likely produces invalid Zig. Fix: return a proper array
resolved type, or special-case array literal nodes in coercion detection.

### Cross-module arbitrary union type mismatch `medium`

When a function in module A returns an arbitrary union type (e.g., `(i32 | str)`) and
module B calls it, codegen generates two separate Zig union types with different names
(e.g., `test_arb_union_cross__union_24527` vs `make_union_val__union_24528`). Zig rejects
the type mismatch. Reproduction: `tester.orh` functions `test_arb_union_cross` and
`test_arb_union_inferred` — both fail with "expected type X, found Y" at Zig compilation.
Root cause: the union registry generates function-scoped union names; cross-module calls
need unified union type names. The `arb_union_cross` and `arb_union_inferred` tests in
`tester.orh` are blocked on this bug and cannot be added to `tester_main.orh` until fixed.

### Resolver: type-check test bodies `medium`

The resolver (pass 5) has no `.test_decl` arm — test bodies are entirely skipped.
Type errors in tests are only caught at Zig compilation (pass 12). Cannot simply
add a test_decl case because the resolver runs per-file and test bodies reference
functions from other files in the same module. Needs cross-file module scope support
in the resolver first.

### Partial field move detection `medium`

Ownership pass claims to enforce struct atomicity (no partial field moves) but has no
field-access tracking. `let b = player.name` moves a single field without error.
Either implement field-level ownership states or document the limitation.

### `@this` — replace `Self` keyword `medium`

`Self` rejected outside struct bodies (enforced via `struct_depth` in resolver).
Needed for anonymous structs returned from `compt func` where no named type exists.
Named structs can use their own name.

Blocked by a PEG engine bug — multi-token alternatives (`'@' 'this'`) in the type
rule cause an alignment panic in the hash map. Needs PEG engine fix first.

### PEG engine crash with multi-token type alternatives `medium`

Adding `'@' 'this'` (two tokens) as an alternative in the `type` grammar rule causes
an alignment panic in `std.hash_map` during `resolveNodeLoc`. The crash occurs in
`module_parse.zig:186` when looking up import node locations. Single-token alternatives
work fine. The issue likely involves capture position tracking for multi-token
sequences inside ordered choice (`/`) alternatives in type rules.

Blocks: `@this` as a replacement for `Self` in `.orh` source.

### Circular import crash when `import std::allocator` is absent `medium`

Removing `import std::allocator` from the example module causes "circular import
detected: string → allocator" followed by an alignment panic. The `allocator` import
in the example template is unused but prevents this crash — it's a workaround.

Root cause: std modules have internal dependencies (`string` depends on `allocator`),
and the module resolver fails to handle them correctly when `allocator` isn't imported
by any user module. The import order or resolution graph likely has a missing edge.

### Instance method detection uses `self` name — should use type `medium`

The borrow checker, MIR annotator, and codegen detect instance methods by checking
if the first parameter is named `"self"`. This prevents users from choosing their own
parameter name (e.g., `this`, `me`). Should detect instance methods by checking if the
first parameter's type references the enclosing struct instead.

Affected locations:
- `borrow_checks.zig:124` — `sig.params[0].name == "self"`
- `mir_annotator_nodes.zig:287` — `sig.params[0].name == "self"`
- `codegen_match.zig:187,368` — `name == "self"`
- `declarations.zig:708` — constructs test sig with name `"self"`

### Bitfield as pure Orhon std module `hard` — DEFERRED

- Design: enum-based API — `Bitfield(Perm)` wraps a user enum, maps variants to bit positions
- Must be implemented as a pure Orhon module in std, not Zig
- **Blockers:**
  1. Compt iteration over enum variants
  2. Compt arithmetic (`1 << index` at compile time)
  3. Compt `@intFromEnum` equivalent
- Users can create bitfields manually with `u32` + bitwise operators in the meantime

### Named tuple nominal typing `medium`

Spec says named tuples are nominally typed (two tuples with identical structure but
different names are different types). Current codegen emits anonymous Zig structs
(`struct { x: f32, y: f32 }`), which are structurally typed — no type distinction
between `Point` and `Velocity` with the same fields.

Fix: emit named struct constants instead of inline anonymous structs.

### Dead NodeKind variants: `type_primitive`, `type_tuple_anon` `medium`

`type_primitive` and `type_tuple_anon` exist in `parser.zig` NodeKind but are never
produced by any PEG builder function. However, they are referenced in ~15 match arms
across 8 files (codegen, types, resolver, mir, lsp, interface, docgen) and constructed
in `interface.zig` tests. `type_tuple_anon` has contradictory handling in `types.zig`
(treated as union) vs `codegen.zig` (treated as struct). Removing them requires updating
all consuming switch arms and deciding whether `type_named` should absorb primitives.

### Break up oversized functions `medium`

- `generateExprMir()` in codegen_exprs.zig — 537 lines, one giant switch
- Split into per-expression-kind functions (binary, call, field, index, etc.)

### Extract shared `blockHasEarlyExit` utility `easy`

`blockHasEarlyExit` is duplicated in `propagation.zig`, `mir/mir_lowerer.zig`, and
`ownership_checks.zig`. Extract to a shared location (e.g., `parser.zig` helper or
new `ast_utils.zig`) so all three call the same function.

### Deduplicate pipeline/LSP module resolution sequence `medium`

`pipeline.zig` and `lsp/lsp_analysis.zig` both duplicate the same module resolution
sequence: scan → parse → circular import check → validate imports. Extract into a
shared function (e.g., `Resolver.resolveAll()`) that both call.

---

## Core — Compiler Architecture

### MIR — SSA construction (Phase 4a) `hard`

Flatten MirNode tree to basic blocks, build SSA form using Braun's algorithm.
Each value gets a single definition, phi nodes at join points.

Unblocks: inlining (4b), dead code elimination (4c), constant folding (4d), MIR
caching (4e). Nothing in the optimization pipeline works without SSA.

### MIR — caching (Phase 4e) `hard`

Binary serialization/deserialization of SSA IR per module. Cache invalidation via
file content hashing. Skip annotation + lowering for unchanged modules.

### Dependency-parallel module compilation `hard`

Modules are processed sequentially in topological order. Independent modules could
be processed in parallel via a thread pool.

**Prerequisites:**
- Thread-safe `Reporter` (atomic append)
- Per-module allocators (already arena-based)
- Work-stealing queue with dependency tracking
- Careful DeclTable registration ordering for cross-module refs

---

## Core — Developer Experience

### Error message quality `medium`

- Cross-module errors should show module context
- Generic instantiation failures should show the constraint that failed
- Common mistake detection — token insertions/deletions at failure point
- `else if` → suggest `elif` (currently produces generic parse error expecting `{`)

### Formatter — line-length awareness `medium`

Missing: wrapping for long lines, function signature breaking rules, alignment
for multi-line assignments, comment-aware formatting, configurable style.

### LSP — feature-gated passes `medium`

Gate passes by request type instead of running 1–9 on every change:
- **Completion:** passes 1–4 (parse + declarations)
- **Hover:** passes 1–5 (+ type resolution)
- **Diagnostics:** passes 1–9, debounced 100–300ms

Add cancellation tokens for in-flight analysis.

### LSP — incremental document sync `hard`

Full reparse on every keystroke. No incremental updates, no background compilation,
limited completion context.

### Source mapping for debugger `hard`

Emit `.orh.map` files mapping generated `.zig` lines back to `.orh` source.
Build a VS Code DAP adapter that reads these maps.

---

## Features — Tooling & Ecosystem

### Binding generator `hard`

Auto-generate Zig module wrappers from C headers:
```bash
orhon bindgen vulkan.h --module vulkan
```

### Tree-sitter grammar `medium`

Enables syntax highlighting in Neovim, Helix, Zed, and other editors beyond VS Code.

### Web playground `hard`

Online sandbox to try Orhon without installing. Already targets `wasm32-freestanding`.
Single biggest adoption accelerator for new languages.

### Debugger integration `hard`

Debug symbol generation, GDB/LLDB line mapping from generated Zig back to `.orh`
source. See also: source mapping in Developer Experience section.

---

## Optimization Passes (require SSA — Phase 4a)

### Inlining (Phase 4b) `hard`

Inline Zig module wrappers, single-expression functions, coercion wrappers at call sites.

### Dead code elimination (Phase 4c) `hard`

If an SSA value has no uses, delete it. Reachability analysis from entry points.

### Type-aware constant folding (Phase 4d) `hard`

Fold `@type(x) == T` when statically known, eliminate redundant wrap/unwrap chains,
simplify coercion sequences.

---

## Testing Improvements

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
| Const auto-borrow via MIR annotation | Re-derive const-ness from AST, avoid coupling to ownership checker |
| Pointers in std, not compiler | Borrows handle safe refs; std::ptr is the escape hatch |
| Transparent (structural) type aliases | `Speed == i32`, not a distinct nominal type |
| Allocator via `.new(alloc)`, not generic param | Keeps generics pure (types only) |
| SMP as default allocator | GeneralPurposeAllocator optimized for general use |
| Zig-as-module for Zig interop | `.zig` files auto-convert to Orhon modules |
| Explicit error propagation via `if/return` | No hidden control flow, no special keywords |
| Parenthesized guard syntax `(x if expr)` | Consistent with syntax containment rule |
| Hub + satellite split pattern | All large file splits use same pattern for consistency |
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
| Arena allocator pairing syntax | `.new(alloc)` already covers composed allocators via Zig module |
| `#derive` auto-generation | Blueprints require explicit implementation. No implicit anything |
| `#extern` / `#packed` struct layout | `.zig` modules already support these natively |
| `async` keyword | Wait for Zig's new async design, then map cleanly. `std::thread` + `thread.Atomic` covers parallelism |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
