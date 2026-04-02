# Orhon — TODO

Items ordered by importance and how much they unblock future work.

---

## Bugs

---

## Core — Language Ergonomics

---

## Core — Compiler Architecture

### MIR — SSA construction (Phase 4a)

Flatten MirNode tree to basic blocks, build SSA form using Braun's algorithm.
Each value gets a single definition, phi nodes at join points.

Unblocks: inlining (4b), dead code elimination (4c), constant folding (4d), MIR
caching (4e). Nothing in the optimization pipeline works without SSA.

### MIR — caching (Phase 4e)

Binary serialization/deserialization of SSA IR per module. Cache invalidation via
file content hashing. Skip annotation + lowering for unchanged modules.

### Dependency-parallel module compilation

Modules are processed sequentially in topological order. Independent modules could
be processed in parallel via a thread pool.

**Prerequisites:**
- Thread-safe `Reporter` (atomic append)
- Per-module allocators (already arena-based)
- Work-stealing queue with dependency tracking
- Careful DeclTable registration ordering for cross-module refs

---

## Core — Developer Experience

### Error message quality

- Cross-module errors should show module context
- Generic instantiation failures should show the constraint that failed
- Common mistake detection — token insertions/deletions at failure point

### Formatter — line-length awareness

Missing: wrapping for long lines, function signature breaking rules, alignment
for multi-line assignments, comment-aware formatting, configurable style.

### LSP — feature-gated passes

Gate passes by request type instead of running 1–9 on every change:
- **Completion:** passes 1–4 (parse + declarations)
- **Hover:** passes 1–5 (+ type resolution)
- **Diagnostics:** passes 1–9, debounced 100–300ms

Add cancellation tokens for in-flight analysis.

### LSP — incremental document sync

Full reparse on every keystroke. No incremental updates, no background compilation,
limited completion context.

### Source mapping for debugger

Emit `.orh.map` files mapping generated `.zig` lines back to `.orh` source.
Build a VS Code DAP adapter that reads these maps.

---

## Features — Language

### Zig-as-module — replace bridge system

Eliminate the `bridge` keyword and the paired `.orh`/`.zig` sidecar system. Instead,
the compiler auto-discovers `.zig` files in `src/` and converts them into regular
Orhon modules.

**Mechanism:**
- New `src/zig_module.zig` — self-contained converter, uses `std.zig.Ast` to parse
- Runs early in pipeline, before module resolution
- Discovers `.zig` files in `src/` (and subfolders), generates `.orh` into `.orh-cache/zig_modules/`
- Generated modules are regular Orhon modules — no `bridge` keyword, no special syntax
- Module name = filename stem (`mylib.zig` → `module mylib`)
- Module-level flag (`is_zig_module`) tells codegen to emit re-exports
- Build.zig wires the original `.zig` as a named module

**Type mapping (Zig → Orhon):**
- Primitives: `u8`, `i32`, `f64`, `bool`, `void`, `usize` → same
- `[]const u8` → `String`
- `?T` → `NullUnion(T)`
- `anyerror!T` → `ErrorUnion(T)`
- `*T` → `mut& T`, `*const T` → `const& T`
- `pub const X = struct { ... }` → `struct X { ... }` with `pub fn` methods
- Incompatible signatures (`anytype`, `comptime`, complex generics) → silently skipped

**What gets removed:**
- `bridge` keyword from grammar, parser, declarations, codegen
- All 27 `.orh` bridge files from `src/std/` (keep only `.zig` implementations)
- Sidecar detection/copy logic in module_parse.zig and pipeline_passes.zig
- Bridge-specific codegen in codegen_decls.zig

**What stays the same:**
- Module resolution, type resolution, semantic passes — see regular modules
- Codegen re-export mechanism — triggered by module flag instead of per-decl `bridge`
- Build.zig named module wiring — same pattern, different naming

### Compiler simplifications

**Hub+satellite splits (files over 1000 lines):**

- ~~`resolver.zig`~~ — DONE (v0.14.5): split into hub + resolver_exprs.zig + resolver_validation.zig
- ~~`pipeline.zig`~~ — DONE (v0.14.6): split into hub + pipeline_passes.zig
- ~~`mir_annotator.zig`~~ — DONE (v0.17): split into hub + satellites
- ~~`module.zig`~~ — DONE (v0.17): split into hub + module_parse.zig
- ~~`borrow.zig`~~ — DONE: split into hub + borrow_checks.zig
- ~~`ownership.zig`~~ — DONE: split into hub + ownership_checks.zig

**Dead code:**

- `collectAssigned()`/`getRootIdent()` in codegen_decls.zig — AST-path remnants

---

## Features — Tooling & Ecosystem

### Binding generator

Auto-generate `.orh` bridge + `.zig` sidecar pairs from C headers:
```bash
orhon bindgen vulkan.h --module vulkan
```

### Tree-sitter grammar

Enables syntax highlighting in Neovim, Helix, Zed, and other editors beyond VS Code.

### PEG syntax documentation generator

Auto-generate a formatted syntax reference from `src/orhon.peg`. Keeps syntax
docs always in sync with the grammar.

### Web playground

Online sandbox to try Orhon without installing. Already targets `wasm32-freestanding`.
Single biggest adoption accelerator for new languages.

### Debugger integration

Debug symbol generation, GDB/LLDB line mapping from generated Zig back to `.orh`
source. See also: source mapping in Developer Experience section.

---

## Optimization Passes (require SSA — Phase 4a)

### Inlining (Phase 4b)

Inline bridge wrappers, single-expression functions, coercion wrappers at call sites.

### Dead code elimination (Phase 4c)

If an SSA value has no uses, delete it. Reachability analysis from entry points.

### Type-aware constant folding (Phase 4d)

Fold `@type(x) == T` when statically known, eliminate redundant wrap/unwrap chains,
simplify coercion sequences.

---

## Testing Improvements

### Property-based pipeline testing

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
| Named bridge modules via build system | createModule/addImport eliminates file-path imports |
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
| Algebraic effects | Too complex. Union-based errors + bridge-based I/O is sufficient |
| Row polymorphism / structural typing | Contradicts Orhon's nominal type system |
| Garbage collection | Contradicts systems language positioning. Explicit allocators |
| Exceptions | Union-based errors are better for compiled languages |
| Operator overloading | Leads to unreadable code. Named methods are clearer |
| Multiple inheritance | Composition via struct embedding is sufficient |
| Implicit conversions | Explicit `@cast()` is correct. Implicit conversions cause subtle bugs |
| Refinement types | Struct-validation pattern already covers this |
| Full Polonius borrow checker | Overkill. NLL gives 85% of the benefit for 30% of the work |
| Zig IR layer in codegen | Would model Zig semantics inside the compiler |
| Arena allocator pairing syntax | `.new(alloc)` already covers composed allocators via bridge |
| `#derive` auto-generation | Blueprints require explicit implementation. No implicit anything |
| `#extern` / `#packed` struct layout | Sidecar `.zig` files already support these via bridge |
| `async` keyword | Wait for Zig's new async design, then map cleanly. `thread` + `Atomic` covers parallelism |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
