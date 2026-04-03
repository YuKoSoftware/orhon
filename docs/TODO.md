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

### ~~Pointer redesign~~ — done (v0.17.0)
Ptr/RawPtr/VolatilePtr moved from compiler builtins to `std::ptr`. @deref removed.

### Clean up collections.zig — import allocator from std `easy`

- Remove `const _default_alloc = std.heap.smp_allocator` from collections.zig
- Import allocator from `allocator.zig` for the default — one source of truth

### ~~Thread codegen simplification~~ — done (v0.18.0)
`thread` keyword removed. Threading moved to `std::thread`. thread_safety.zig deleted.

### Bitfield as pure Orhon std module `hard` — DEFERRED

- Design: enum-based API — `Bitfield(Perm)` wraps a user enum, maps variants to bit positions
- Must be implemented as a pure Orhon module in std, not Zig
- **Blockers:**
  1. Compt iteration over enum variants
  2. Compt arithmetic (`1 << index` at compile time)
  3. Compt `@intFromEnum` equivalent
- Users can create bitfields manually with `u32` + bitwise operators in the meantime

### Break up oversized functions `medium`

- `generateExprMir()` in codegen_exprs.zig — 537 lines, one giant switch
- Split into per-expression-kind functions (binary, call, field, index, etc.)

### Audit codegen string comparisons `easy`

- Grep `eql(u8,` in `src/codegen/` — nothing should match specific type/method/field
  names except language keywords (`"else"`, `"self"`, `"main"`).

### Remove stale type_class values from MIR `medium`

- `.thread_handle` is unused after `thread` keyword removal — evaluate and remove.

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
| `async` keyword | Wait for Zig's new async design, then map cleanly. `std::thread` + `thread.Atomic` covers parallelism |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
