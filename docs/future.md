# Orhon — Future Work

Items deferred until the core compiler is stable. Not actionable now — revisit after
language features, error handling, and tooling reach stable quality.

---

## Language Features (deferred)

### Tuple math (element-wise arithmetic, scalar broadcast) `hard`

Specced in `docs/04-operators.md` but not implemented. Needs codegen expansion to
per-field operations and scalar broadcast wrapping. No current use cases in Tamga.

---

## Compiler Architecture

### Cache-aware worklist optimization `medium`

The iterative worklist in `parseModules()` always re-parses every module. For unchanged
modules, load their import list from the cached dependency graph (`deps.graph`) instead
of re-parsing. This skips lexing/PEG/AST for modules whose source hasn't changed,
improving incremental build performance.

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

## Optimization Passes (require SSA — Phase 4a)

### Inlining (Phase 4b) `hard`

Inline Zig module wrappers, single-expression functions, coercion wrappers at call sites.

### Dead code elimination (Phase 4c) `hard`

If an SSA value has no uses, delete it. Reachability analysis from entry points.

### Type-aware constant folding (Phase 4d) `hard`

Fold `@type(x) == T` when statically known, eliminate redundant wrap/unwrap chains,
simplify coercion sequences.

---

## Language Features (deferred)

### `@call` compiler function — controlled call semantics `medium`

Maps to Zig's `@call(modifier, fn, args)`. Lets the caller control call behavior:
- `@call(.compile_time, fn, args)` — force compile-time evaluation on any function
- `@call(.always_inline, fn, args)` — force inlining
- `@call(.always_tail, fn, args)` — force tail call optimization

Deferred until `compt func` codegen is correct and compt system is stable.
Complementary to `compt func`: `compt func` marks a function as *always* compile-time,
`@call(.compile_time, ...)` lets the *caller* force it on any function.

---

## Tooling & Ecosystem

### Source mapping for debugger `hard`

Emit `.orh.map` files mapping generated `.zig` lines back to `.orh` source.
Build a VS Code DAP adapter that reads these maps.

### Tree-sitter grammar `medium`

Enables syntax highlighting in Neovim, Helix, Zed, and other editors beyond VS Code.

### Web playground `hard`

Online sandbox to try Orhon without installing. Already targets `wasm32-freestanding`.
Single biggest adoption accelerator for new languages.

### Debugger integration `hard`

Debug symbol generation, GDB/LLDB line mapping from generated Zig back to `.orh`
source. See also: source mapping.
