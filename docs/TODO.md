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
