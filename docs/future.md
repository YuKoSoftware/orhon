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

### Formatter — AST-based rewrite `hard`

Line-length warnings are implemented (`orhon fmt --line-length N`). Full auto-wrapping
requires an AST-based formatter and a grammar decision about line continuation
(Orhon uses newlines as statement terminators). Remaining:
- Auto-wrapping long lines (needs line continuation rule in grammar)
- Function signature breaking rules
- Alignment for multi-line assignments
- Comment-aware formatting


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

### Dependency / Package Manager `medium`

Orhon currently has no way to depend on external packages — all imports resolve to
local `src/` modules or the embedded stdlib. The `orhon.project` manifest only
declares project metadata (`#name`, `#version`, `#build`, `#target`). A dependency
manager will become essential once the Orhon ecosystem exists outside a single
repository.

**Design decisions (to settle before implementation):**

- **Source of truth — git URLs or registry.** Early adopters can use direct git
  dependencies (like Go pre-modules or Zig 0.11). A central registry can be added
  later. The manifest should support both paths. Git is the MVP because it requires
  zero infrastructure.

- **Manifest format — extend `orhon.project` or create `orhon.zon`.** The existing
  `#key = value` line format is simple but doesn't nest well for dependency objects
  (name + version + url). A structured ZON format (matching Zig's `build.zig.zon`)
  would be more natural for dependency declarations. The TODO file references this
  as "`orhon.zon` manifest" in M26.

- **Version resolution — minimum version selection (Go) vs. semver solver (Cargo/npm).**
  MVS is simpler to implement and predict. Semver gives more flexibility but adds
  complexity. Leaning toward MVS for a systems language.

- **Lock file — `orhon.lock`.** Reproducible builds require pinning exact versions
  and content hashes. The existing cache infrastructure (`src/cache.zig` — ZON format,
  schema-versioned, atomic tmp→rename writes) provides a strong pattern to follow.

- **Zig build integration.** Orhon transpiles to Zig and invokes `zig build`. An
  Orhon package manager must either present fetched packages as Zig packages (via
  `build.zig.zon` dependencies) or generate a monolithic Zig project. The monolithic
  approach is simpler but loses incremental cache benefits. Package-as-Zig-dependency
  requires mapping Orhon's module graph onto Zig's package graph.

**Implementation phases (rough):**

| Phase | Scope | Effort |
|-------|-------|--------|
| 1. Manifest expansion | Add `#dep` keys to `orhon.project` (name, url, version). Parse and validate. | Small |
| 2. Git fetching | `git clone` dependencies into a local cache (`.orh-packages/`). Shallow clones, tag resolution. | Medium |
| 3. Module resolution | Extend import resolution to search external package paths. Namespace isolation — packages must not shadow project-local modules. | Medium |
| 4. Lock file | `orhon.lock` with pinned versions + content hashes. Generated on first resolve, checked in. | Small |
| 5. CLI commands | `orhon add <pkg>`, `orhon remove <pkg>`, `orhon update`. Update `src/cli.zig` `Command` enum. | Small |
| 6. Registry + publish | Central package registry service. `orhon publish` command. Versioning, ownership, documentation hosting. | Large |

**Relationship to Zig's package manager:**
Zig 0.15+ has its own package manager via `build.zig.zon` dependencies. Orhon could
potentially piggyback on it — declare Orhon packages as Zig dependencies, let Zig
fetch them, then have Orhon's compiler find the fetched sources. However, this
creates a tight coupling to Zig's toolchain and doesn't handle Orhon-specific
concerns (semver for Orhon APIs, interface hashing, documentation). A dedicated
Orhon package manager is recommended for the long term, with the possibility of
a bridge layer that converts Orhon dependencies into Zig build system dependencies
under the hood.

**Prerequisites:** None (can be started independently of other compiler work). The
main dependency is having external Orhon packages to depend on — a chicken-and-egg
problem that resolves naturally as the ecosystem grows.
