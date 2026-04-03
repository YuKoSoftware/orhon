# Orhon — TODO

Items ordered by importance and how much they unblock future work.

---

## Bugs

---

### Review metadata directives (`#name`, `#version`, `#build`, `#dep`) `medium`

All metadata directives need to be looked at together. Questions:
- Should `#dep` move to `.zon` files (like C deps already do)?
- Is `#dep` tested? (Currently zero tests)
- Are `#name`, `#version`, `#build` the right set, or should some move to `.zon`?
- Should metadata be unified into one system instead of split between `#` directives and `.zon`?

Not blocking zero-magic work — metadata doesn't touch codegen. But needs a design pass.

---

## Core — Language Ergonomics

### Zero magic — remove all special-case codegen `hard`

**Principle:** The compiler has zero special cases for stdlib types. If something needs
complex behavior (fields, methods, constructors), it gets implemented purely in std as
Orhon or Zig code. The compiler handles it through normal code paths — same as any user
code. If the compiler can't handle it, we fix the compiler, not add workarounds.

Only `@` compiler functions (intrinsics that map to Zig builtins) and language-level
constructs (match, interpolation, operators) get codegen awareness.

**Stdlib rules:**
- Each std lib owns its domain — one source of truth per concern
- Std libs import what they need from other std libs (e.g. collections imports allocator)
- No duplication, no secret defaults, no hardcoded values that belong in another module
- Plain Zig files that compose our std — clean dependency graph
- Build system must support cross-imports between std modules

Work items ordered by: easiest first, dependencies respected. Each item is self-contained.
We will break things along the way — that's expected. Fix forward, don't look back.

**Phase A — Quick wins (no dependency chain, isolated changes)**

**~~A1. `wrap()`, `sat()`, `overflow()` → `@wrap`, `@sat`, `@overflow`~~** — DONE
- Added to PEG grammar, CompilerFunc enum, generateCompilerFuncMir
- Removed string detection from codegen_exprs.zig

**A2. `Handle(T)` call is a no-op — remove special case** `easy`
- Location: `codegen_exprs.zig:233-235`
- `Handle(value)` emits just the value — codegen detects "Handle" by name
- Fix: if Handle becomes a real std struct, this disappears naturally. Otherwise
  evaluate if this special case is even needed.

**Phase B — Move injected code to std libs**

**B1. `_OrhonHandle` → std handle lib** `medium`
- Location: `codegen.zig:297-298`
- 1-line string literal injected into EVERY module: full struct with `getValue()`,
  `wait()`, `done()`, `join()` methods
- Fix: move to `src/std/handle.zig` as a real Zig struct. `Handle(T)` type in
  `typeToZig` references the std module instead of the injected helper.
- Unblocks: B2 (`.value`/`.done` field rewriting removal)

**B2. `.value`/`.done` field rewriting on Handle — use real methods** `medium`
- Location: `codegen_exprs.zig:376-381`
- `handle.value` → `.getValue()`, `handle.done` → `.done()`
- Fix: once Handle is a std struct (B1), `.value` and `.done` are real fields/methods.
  Remove the field name detection. Users call the real API.
- Depends on: B1

**B3. `.value` field rewriting on Ptr/RawPtr — move to std** `medium`
- Location: `codegen_exprs.zig:382-387`
- `Ptr(T).value` → `.*`, `RawPtr(T).value` → `[0]`
- Fix: make Ptr/RawPtr real Zig structs in std with a `value` field or `get()` method.
  Or use `@deref` compiler function. Design decision needed.

**B4. Bitfield auto-methods → std** `medium`
- Location: `codegen_decls.zig:416-423, 447-454`
- `has()`, `set()`, `clear()`, `toggle()` injected into every bitfield by codegen
- Fix: bitfield backing logic moves to `src/std/bitfield.zig`. Generated bitfield struct
  uses the std implementation. Methods are real, visible, testable.

**Phase C — ErrorUnion/NullUnion `.value` unwrapping**

**C1. Design unwrap API for ErrorUnion/NullUnion** `hard`
- Location: `codegen_exprs.zig:388-449`
- `.value` rewrites to `catch unreachable` (error), `.?` (null), `._{tag}` (union)
- `.Error` rewrites to `@errorName()`
- These map to Zig's `anyerror!T` and `?T` which have no fields
- Fix: needs design — either `@unwrap` compiler function, or wrapper structs in std
  that expose `.value` as a real method. The wrapper approach adds overhead; the
  `@unwrap` approach keeps it lean. Decision needed before implementation.
- Depends on: clear on which approach

**C2. Remove `.Error` field magic** `medium`
- Location: `codegen_exprs.zig:388-404`
- `result.Error` → `@errorName(captured_err)`
- Fix: depends on C1 design. If ErrorUnion becomes a std struct, `.Error` is a real
  field. If it stays as `anyerror!T`, need `@errorName` as explicit compiler function.

**Phase D — Collection grammar removal (biggest change)**

**D1. Remove `collection_expr` from PEG grammar** `hard`
- Location: `orhon.peg:440-447`
- `List`, `Map`, `Set`, `Ring`, `ORing` are grammar keywords
- Fix: remove all 5 rules. `List(i32)` becomes `collections.List(i32)` — parsed as
  field access + generic call. User must `import std::collections`.
- Touches: `orhon.peg`, `parser.zig` (remove `CollectionExpr`, `collection_expr` variant),
  `peg/builder_exprs.zig` (remove `buildCollectionExpr`), `mir_lowerer.zig` (remove
  `.collection_expr` case), `mir_node.zig` (remove `.collection` kind)
- Unblocks: D2

**D2. Remove `.new()` constructor magic** `medium`
- Location: `codegen_exprs.zig:286-301`
- `Type.new()` → `.{}`, `Type.new(alloc)` → `.{ .alloc = alloc }`
- Fix: once collections are normal imports (D1), `.new()` is a real Zig method
  (already added to `collections.zig`). Remove the codegen string detection.
- Also remove: `generateCollectionExprMir` in `codegen_match.zig` (emits `.{}`)
- Depends on: D1

**D3. Clean up collections.zig — import allocator from std** `easy`
- Remove `const _default_alloc = std.heap.smp_allocator` from collections.zig
- Import allocator from `allocator.zig` for the default — one source of truth
- Depends on: D1 (build system must support cross-imports between std modules)

**Phase E — Verify and clean up**

**E1. Audit: grep for remaining string comparisons in codegen** `easy`
- After all phases, grep `eql(u8,` in `src/codegen/` — nothing should match specific
  type/method/field names except language keywords (`"else"`, `"self"`, `"main"`).

**E2. Remove stale type_class values from MIR** `medium`
- After B1-B3 and C1-C2, several `type_class` enum values may be unused:
  `.thread_handle`, `.safe_ptr`, `.raw_ptr` — evaluate if they're still needed.

**E3. Update all docs, CLAUDE.md, examples** `easy`
- Reflect the new APIs: `collections.List(i32).new()`, `handle.getValue()`, etc.
- Remove mentions of magic behavior from docs.

**Not magic — legitimate language features (keep as-is):**
- `@` compiler functions — intrinsics that map to Zig builtins
- `main` visibility — entry point must be `pub`, language requirement
- `else` in match — language keyword for exhaustiveness
- `self` dereference in match — `self.*` is how Zig accesses struct instances
- `@This()` for generic self-reference — required by Zig
- `ErrorUnion(T)` → `anyerror!T`, `NullUnion(T)` → `?T` type mapping — language-level
- `Ptr(T)` → `*const T` type mapping — language-level pointer syntax
- Division `/` → `@divTrunc()`, `%` → `@mod()` — language operator semantics
- Vector `@splat()` for scalar broadcast — language operator semantics
- String interpolation hoisting — language feature desugaring
- Match desugaring to if/else chains — Zig has no string switch
- Type narrowing after `is Error`/`is null` — compiler flow analysis
- `use` keyword unqualified imports — language import semantics
- `const std = @import("std")` — Zig stdlib, always needed

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

## Features — Language

### ~~Zig-as-module — replace bridge system~~ — DONE (v0.15.0)

Replaced the `bridge` keyword with automatic Zig module conversion. `.zig` files in
`src/` are auto-discovered, parsed with `std.zig.Ast`, and converted to Orhon modules.
Bridge keyword, grammar, and all infrastructure removed. 27 stdlib `.orh` bridge files
deleted. See `docs/14-zig-bridge.md` for the new system.

### ~~String → str rename, std::str → std::string~~ — DONE

Renamed the `String` type to `str` (lowercase, consistent with other primitives). Renamed the
`str` stdlib module to `string`. Removed all string magic: auto-import, method dispatch rewriting,
`==`/`!=` rewriting, split/splitAt destructuring. Added `equals()` to string library. `==` on `str`
is now a compile error with helpful message.

### ~~Per-module `.zon` build config — replace `#cimport`~~ — DONE (v0.15.1)

Replaced `#cimport` with paired `.zon` files. C build config now lives in the Zig
ecosystem. `#cimport` grammar, parser, and pipeline extraction removed.
See `docs/14-zig-bridge.md` for `.zon` config reference.

### Compiler cleanup — string-to-enum conversions

Replace string-based dispatch with enums throughout the compiler. Gives exhaustiveness
checking, typo safety, and better performance.

**~~Metadata field enum~~** — DONE
- Added `parser.MetadataField` enum (`.build`, `.name`, `.version`, `.dep`, `.description`, `.unknown`)
- `StaticStringMap` lookup in `parse()`. All 12 string comparisons replaced across 5 files.

**~~Operator enum~~** — DONE
- Added `parser.Operator` enum (30 variants) with `parse()`, `toZig()`, `isComparison()`, `isLogical()`
- Replaced `op: []const u8` in BinaryOp, UnaryOp, and MirNode with `Operator`
- Removed `constants.Op` struct — all string comparisons replaced across 14 files

**~~Build type enum in pipeline~~** — DONE
- `MultiTarget.build_type` changed from `[]const u8` to `module.BuildType` enum
- Added `module.parseBuildType()` with `StaticStringMap`. All string comparisons replaced.

**~~PEG rule dispatch~~** — DONE
- Replaced 70+ sequential string comparisons with `StaticStringMap(BuilderFn)` dispatch table
- 3 inline builders for break/continue/null. `buildBinaryExpr` third param removed (was unused).

### Compiler cleanup — deduplication and extraction

**~~Pipeline multi/single-target unification~~** — DONE
- Removed duplicate single-target build path (~130 lines). All builds now use unified
  multi-target path — single-target is just one entry in the `MultiTarget` slice.
- Fixed latent use-after-free: `../../`-prefixed strings now outlive `buildAll` call.

**~~`stripQuotes()` utility~~** — DONE
- Extracted to `constants.stripQuotes()`, replaced 6 call sites across 4 files

**Break up oversized functions:** `medium`
- `generateExprMir()` in codegen_exprs.zig — 537 lines, one giant switch
- Split into per-expression-kind functions (binary, call, field, index, etc.)
- Files: codegen/codegen_exprs.zig

### ~~Compiler simplifications — hub+satellite splits~~ — ALL DONE

All files under 1000 lines. Resolver, pipeline, mir_annotator, module, borrow,
ownership all split into hub + satellite files.

---

## Features — Tooling & Ecosystem

### Binding generator `hard`

Auto-generate Zig module wrappers from C headers:
```bash
orhon bindgen vulkan.h --module vulkan
```

### Tree-sitter grammar `medium`

Enables syntax highlighting in Neovim, Helix, Zed, and other editors beyond VS Code.

### ~~PEG syntax documentation generator~~ — DONE

`orhon syntax` command generates `docs/syntax.md` from the embedded PEG grammar.
Parses sections, rules, comments, and `{label:}` annotations. 1040-line reference.

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
| Type-directed pointer coercion | Type annotation carries safety level |
| Transparent (structural) type aliases | `Speed == i32`, not a distinct nominal type |
| Allocator via `.new(alloc)`, not generic param | Keeps generics pure (types only) |
| SMP as default allocator | GeneralPurposeAllocator optimized for general use |
| Zig-as-module for Zig interop | `.zig` files auto-convert to Orhon modules |
| `throw` not `try` for error propagation | Less noisy, less hidden control flow |
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
| `async` keyword | Wait for Zig's new async design, then map cleanly. `thread` + `Atomic` covers parallelism |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
