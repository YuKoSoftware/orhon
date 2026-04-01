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

### Compiler simplifications

Opportunities found via full codebase scan. Same spirit as the CoreType unification —
simplify the compiler without removing features.

**Medium — cross-cutting but mechanical:**

- ~~Generic `ScopeBase(V)` — done (v0.14.2, `src/scope.zig`)~~
- ~~Consolidate `nodeLoc()` — done (v0.14.2, `module.resolveNodeLoc()`)~~
- `TypeResolver` → `SemanticContext`. Every other checker takes `SemanticContext`.
  TypeResolver takes individual fields. Standardize. (Deferred — 183 mechanical
  `self.X` → `self.ctx.X` changes for cosmetic consistency.)

**Larger — needs careful planning:**

- Unify `const_decl`/`var_decl`/`compt_decl`. All three map to `VarDecl`. Add
  `kind` enum field instead of three `NodeKind` variants. ~48 pattern matches.
- ~~`FuncDecl` flags → context enum — done (v0.14.3, `parser.FuncContext`)~~
- ~~Merge `buildZigContent()`/`buildZigContentMulti()` — done (v0.14.3, unified into `buildZigContentMulti`)~~
- ~~`hashInterface()` in `cache.zig` — done (v0.14.2, generic helpers)~~
- ~~Binary operator / builtin name enums — done (v0.14.3, `CompilerFunc` enum + `Op` constants)~~
- Remove AST-path remnants in codegen if fully replaced by MIR path.
- ~~Unify union wrapping in codegen — done (v0.14.2, shared operator maps)~~
- Standardize `catch` patterns across infrastructure.
- ~~`appendFmt()` helper for zig_runner — done (v0.14.3, 35 instances converted, -57 lines)~~
- ~~Builtin type name constants — done (v0.14.3, `builtins.BT.*` + `isPtrType()`, 47 replacements)~~
- `reportFmt()` helper on Reporter — allocPrint+defer+report pattern repeats across
  every checker. One helper eliminates 3 lines per error message.
- Extract Ptr/RawPtr/VolatilePtr coercion check — identical 5-line block repeated 4x
  in codegen_decls.zig and codegen_stmts.zig.

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

### Dynamic library output folder

Compiled `.so`/`.dll` files should go in a separate output folder instead of `src/`.

**Blocked:** Splitting exe (`bin/`) and lib (`lib/`) breaks runtime discovery —
the exe can't find the `.so` without an rpath. Needs rpath support first.

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

### Codegen snapshot tests

Capture generated `.zig` output for representative programs and diff against expected
output. Catches subtle codegen regressions that runtime tests miss.

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
| Implicit conversions | Explicit `cast()` is correct. Implicit conversions cause subtle bugs |
| Refinement types | Struct-validation pattern already covers this |
| Full Polonius borrow checker | Overkill. NLL gives 85% of the benefit for 30% of the work |
| Zig IR layer in codegen | Would model Zig semantics inside the compiler |
| Arena allocator pairing syntax | `.new(alloc)` already covers composed allocators via bridge |
| `#derive` auto-generation | Blueprints require explicit implementation. No implicit anything |
| `#extern` / `#packed` struct layout | Sidecar `.zig` files already support these via bridge |
| `async` keyword | Wait for Zig's new async design, then map cleanly. `thread` + `Atomic` covers parallelism |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
