# Orhon — TODO

Items ordered by importance and how much they unblock future work.
Research sources: `.planning/research/` (compiler-techniques, zig-ecosystem, language-design).

---

## Bugs

*No open bugs.*

---

## Core — Language Ergonomics

These are the highest-impact language changes. Every user benefits immediately.

### Non-lexical lifetimes (NLL)

Move borrow checker from lexical lifetimes to "borrow ends at last use." Currently
borrows are dropped at scope exit (`dropBorrowsAtDepth`). NLL accepts more valid
programs without sacrificing safety — eliminates the most common "fighting the borrow
checker" scenarios.

**Implementation:** build use-def chains during type resolution, use them in borrow
checking. A borrow's lifetime extends from creation to the last use of the reference,
not to the end of the scope. ~85% of Rust's safety for ~30% of Polonius complexity.

Full Polonius (flow-sensitive dataflow analysis) is overkill for Orhon.

---

## Core — Compiler Architecture

Ordered by how much each item unblocks downstream work.

### ~~Incremental compilation — semantic hashing~~ DONE (v0.10.20)

~~Replace timestamp-based cache invalidation with semantic hashing.~~ Shipped.
`cache.zig` now hashes the token stream via `hashSemanticContent()`, skipping
newlines and doc comments. Whitespace-only and comment-only edits no longer
invalidate the cache.

### ~~Incremental compilation — interface diffing~~ DONE (v0.10.21)

~~After declaration pass, compare public interface against cached interface.~~ Shipped.
`cache.zig` has `hashInterface()` that hashes sorted public DeclTable entries
(funcs, structs, enums, bitfields, vars, type aliases). Pipeline checks dependency
interface hashes — downstream modules skip passes 5-12 when upstream public API unchanged.

### PEG error recovery — labeled failures

Add optional human-readable labels to grammar rules in `orhon.peg`. When a labeled
rule fails, use the label in error messages instead of the raw rule name.

```
VarDecl <- 'var' IDENTIFIER ':' TypeExpr '=' Expr
         {label: "variable declaration (var name: Type = value)"}
```

Medium effort, high impact for error quality.

### MIR — SSA construction (Phase 4a)

Flatten MirNode tree to basic blocks, build SSA form using Braun's algorithm (simple,
no dominance frontiers needed). Each value gets a single definition, phi nodes at join
points. This is the foundation — all subsequent optimization passes run on SSA form.

Unblocks: inlining (4b), dead code elimination (4c), constant folding (4d), MIR
caching (4e). Nothing in the optimization pipeline works without SSA.

### MIR — caching (Phase 4e)

Binary serialization/deserialization of SSA IR per module. Cache invalidation via file
content hashing. Skip annotation + lowering for unchanged modules on incremental rebuilds.

Unblocks: fast incremental builds for large projects. Currently all 11 passes re-run
for every changed module.

### Dependency-parallel module compilation

Modules are processed sequentially in topological order. Independent modules (whose deps
are all complete) could be processed in parallel via a thread pool.

**Prerequisites:**
- Thread-safe `Reporter` (atomic append to error/warning lists)
- Per-module allocators (already arena-based, close to ready)
- Work-stealing queue with dependency tracking
- Careful DeclTable registration ordering for cross-module refs

The `SemanticContext` refactor (v0.9.3) lays groundwork — each pass now takes a shared
context rather than wiring individual fields, making per-thread state easier.

Unblocks: compilation speed scales with CPU cores. Matters most for projects with many
independent modules.

### MIR — residual AST accesses

6 `m.ast` reads remain in codegen: source location queries, current function node
tracking, `type_expr`/`passthrough` (type trees are structural, not duplicated into MIR).
Decide: migrate into MirNode fields or document as permanent architectural boundary.

### ~~Bridge module import scoping~~ PARTIALLY DONE (v0.10.22)

~~Named bridge modules added to all targets.~~ Multi-target builds fixed: each lib/exe/test
target now only receives `addImport` for bridges it actually imports. Single-target path
left as-is — transitive bridge resolution requires all bridges to be available.

---

## Core — Build System

### Thread cancellation mechanism

`.cancel()` sets a flag, but the mechanism for checking it inside the thread body is TBD.
May be automatic at loop boundaries or an explicit `thread.cancelled()` check.

---

## Core — Developer Experience

### Error message quality

The highest-ROI tooling investment. Every user hits errors. Good messages = faster
learning = more adoption. Elm, Gleam, and Rust set the bar.

**Improvements:**
- "Did you mean X?" for identifier typos (Levenshtein distance to known names)
- Expected vs actual display for type mismatches
- Ownership/borrow violations should suggest fixes ("consider using `copy()`" or
  "consider borrowing with `const &`")
- Cross-module errors should show module context
- Generic instantiation failures should show the constraint that failed

**PEG parser improvements (see Compiler Architecture section):**
- Labeled failures — human-readable error messages from grammar rules
- Common mistake detection — try token insertions/deletions at failure point
  ("missing ':' in variable declaration")

### Formatter — line-length awareness

Current formatter handles indentation and blank lines but has no concept of line length.
Missing: wrapping for long lines, function signature breaking rules, alignment for
multi-line assignments, comment-aware formatting, configurable style.

### LSP — feature-gated passes

Instead of running passes 1-9 on every change, gate by request type:
- **Completion:** passes 1-4 only (parse + declarations)
- **Hover:** passes 1-5 (parse + declarations + type resolution)
- **Diagnostics:** passes 1-9 (all analysis), debounced 100-300ms after last keystroke

Add cancellation tokens — if a new change arrives while analysis is running, cancel
and restart. This is rust-analyzer's architecture and the gold standard for LSP
responsiveness.

### LSP — incremental document sync

Full reparse on every keystroke. No background compilation, no incremental updates.
Limited completion context (not method-chain aware).

### Source mapping for debugger

Emit `.orh.map` files during codegen mapping generated `.zig` line numbers back to
original `.orh` source lines. Build a VS Code DAP adapter that reads these maps.
Simpler than DWARF manipulation but gives users `.orh`-level debugging.

---

## Features — Language

Ordered by how much they expand what Orhon programs can express and unblock downstream
features.

### Blueprints (abstract structs — Orhon's traits)

The missing type system foundation. Unlocks constrained generics, `#derive`, and
library patterns. Uses `blueprint` keyword — an abstract struct containing only
definitions, no implementation. Keep it simple:

```
blueprint Drawable {
    func draw(self: const &Self) void
}

impl Drawable for Circle {
    func draw(self: const &Circle) void { ... }
}

func render(item: any where Drawable) void {
    item.draw()
}
```

**Rules:** methods only, explicit `impl`, no inheritance, no associated types in v1.
Composition via requiring multiple blueprints. No blueprint objects initially.

**Open question:** Can `compt` type introspection complement or reduce the scope
needed? Zig uses comptime + `@hasDecl` for structural generics without traits.
Investigate whether extending compt is a simpler path before full blueprint
implementation.

Unblocks: generic constraints (already in TODO), `#derive`, numerous library patterns.

### Compile-time struct introspection

Compiler functions for structural checks inside `compt` code. Complements blueprints
(nominal contracts) with low-level introspection (structural queries). Needed for
`#derive`, serialization, conditional codegen.

```
hasField(MyStruct, "x")       // does the struct have field "x"?
hasDecl(MyStruct, "deinit")   // does it have a method or const "deinit"?
fieldType(MyStruct, "x")      // returns the type of field "x"
```

These are tools for `compt` metaprogramming, not a substitute for blueprints at API
boundaries. Blueprints say "this type must conform." Introspection says "what does
this type have?"

### `#derive` for common traits

Once traits exist, auto-generate standard implementations:

```
#derive(Eq, Hash, Debug)
struct Point {
    x: f32
    y: f32
}
```

Implement via `compt`, not macros. Rust's `#[derive]` is enormously popular. Eliminates
massive boilerplate for common patterns.

### Union spreading syntax

Compose unions from other unions:
```
pub const GuiEvent: type = (...InputEvent | ButtonClickEvent | ScrollEvent)
```
where `InputEvent` is itself a union. Avoids repeating type lists across modules.
From Tamga feedback — needed for event hierarchies.

### Explicit capture — `capture()` compiler function

Instead of implicit closures, use explicit `capture()` to bring outer variables into
a nested function's scope. Follows Orhon's "no implicit anything" philosophy — you
see exactly what's captured.

```
var x: i32 = 42
var data: MyStruct = MyStruct(...)

var callback = func() i32 {
    capture(x)           // copies primitive
    capture(copy(data))  // explicit copy of non-primitive
    capture(&data)       // borrows as const
    return x + data.value
}
```

`capture()` is a compiler function like `copy()` and `move()`. Ownership rules apply
normally — the borrow checker already handles moves, borrows, and copies. No new
semantics needed, just explicit intent.

This replaces the "first-class closures" idea. No implicit environment capture.

### `async` keyword — IO concurrency

Deferred — will share the same interface as `thread` but use IO concurrency instead of
OS threads. Not designed yet. This is the biggest missing language feature but also the
most complex to design. Needs dedicated research (stackful vs stackless, relationship
to existing `thread`).

### Bridge struct layout control

For C interop, struct field order and padding matter. Support `#extern` annotation
for C-compatible layout:

```
#extern
struct SDL_Event {
    event_type: u32
    timestamp: u64
}
```

Maps to Zig's `extern struct`. Needed for direct C struct passing without wrapper
overhead.

---

## Features — Tooling & Ecosystem

### Binding generator

Auto-generate `.orh` bridge + `.zig` sidecar pairs from C headers:

```bash
orhon bindgen vulkan.h --module vulkan
```

High-impact for systems programming use. Currently users write bridge declarations
by hand, which is tedious and error-prone for large C APIs.

### Tree-sitter grammar

Enables syntax highlighting in Neovim, Helix, Zed, and other modern editors beyond
VS Code. Should exist alongside the PEG grammar. Medium effort, extends reach.

### PEG syntax documentation generator

Auto-generate a formatted syntax reference from `src/orhon.peg`. Each rule name
becomes a section heading, alternatives become the documented forms.

Unblocks: always-accurate syntax docs that stay in sync with the grammar. Currently
docs are manually maintained and can drift.

### Web playground

Online sandbox to try Orhon without installing. Gleam, Go, Rust, Zig all have them.
Orhon already targets `wasm32-freestanding`. Single biggest adoption accelerator for
new languages — dramatically lowers the "try it" barrier.

### Debugger integration

Debug symbol generation, GDB/LLDB line mapping from generated Zig back to `.orh`
source. Currently debugging requires reading generated Zig. See also: source mapping
in Developer Experience section.

### Dynamic library output folder

Compiled `.so`/`.dll` files should go in a separate output folder instead of
cluttering `src/`. From Tamga feedback.

**Blocked:** Splitting exe (`bin/`) and lib (`lib/`) breaks runtime discovery —
the exe can't find the `.so` without an rpath. Either set `$ORIGIN/../lib` rpath
in generated `build.zig`, or keep everything in `bin/`. Needs rpath support first.

### Interface file tagging

When a dynamic library is compiled, its interface could be tagged as `interface`
instead of `module` to distinguish API surface from implementation. From Tamga feedback.

---

## Optimization Passes (require SSA — Phase 4a)

### Inlining (Phase 4b)

Identify inline candidates: bridge wrappers, single-expression functions, generated
coercion wrappers. Substitute at call sites. SSA makes substitution clean (no variable
name collisions). Reduces emitted Zig volume and gives LLVM better input.

### Dead code elimination (Phase 4c)

Trivial on SSA: if an SSA value has no uses, delete it. Reachability analysis from
entry points, skip emission of unreachable code. Less emitted Zig = faster Zig
compilation.

### Type-aware constant folding (Phase 4d)

Fold `@type(x) == T` when statically known, eliminate redundant wrap/unwrap coercion
chains, simplify coercion sequences. Single definitions mean constants propagate in
one pass.

---

## Testing Improvements

### Codegen snapshot tests

Capture generated `.zig` output for representative programs and diff against expected
output. Catches subtle codegen regressions that runtime tests miss (e.g., unnecessary
allocations, wrong variable names, missing `defer`).

### Property-based pipeline testing

Beyond "does it crash" fuzzing — test semantic properties across the pipeline:
- Parse then pretty-print should round-trip
- Type-checking the same input twice should give identical results
- Codegen output should always be valid Zig (run `zig ast-check` on it)

---

## Explicitly NOT Adding

| Feature | Why Not |
|---------|---------|
| Macros | `compt` covers the use cases without readability costs. Zig made this choice. |
| Algebraic effects | Too complex. Union-based errors + bridge-based I/O is simpler and sufficient. |
| Row polymorphism / structural typing | Contradicts Orhon's nominal type system. |
| Garbage collection | Contradicts the systems language positioning. Explicit allocators are right. |
| Exceptions | Already decided against. Union-based errors are better for compiled languages. |
| Operator overloading | Leads to unreadable code. Named methods are always clearer. |
| Multiple inheritance | Composition via struct embedding is simpler and sufficient. |
| Implicit conversions | Orhon's explicit `cast()` is correct. Implicit conversions cause subtle bugs. |
| Refinement types | Struct-validation pattern already covers this. No language change needed. |
| Full Polonius borrow checker | Overkill for Orhon. NLL gives 85% of the benefit for 30% of the work. |
| Zig IR layer in codegen | Would model Zig semantics inside the compiler. See codegen refactor entry. |
| Arena allocator pairing syntax | Mode 2 `.new(alloc)` already covers composed allocators via bridge. |

---

## Done

### Thread safety argument enforcement ✓

**Done in v0.10.17 (post-v0.17).** Three rules enforced at compile time when passing arguments to thread functions:
1. **Owned values** → moved into thread, original variable dead until join
2. **Const borrows (`&x`)** → original frozen (read-only) until thread joined via `.value` or `.wait()`
3. **Mutable borrows (`var &x`)** → compile error (no mutable sharing across threads)

Infrastructure: `moved_to_thread` map (existed, now populated), `frozen_for_thread` map (new), `checkThreadCallArgs` (new), `unfreezeForThread` (new). 14 unit tests + 4 negative integration fixtures.

### `throw` statement for error propagation ✓

**Done in v0.15 Phase 22.** `throw x` propagates error and narrows the variable
to its value type. Statement form (not expression prefix like Zig's `try`).

### Pattern guards in match ✓

**Done in v0.15 Phase 23.** `(x if x > 0) => { ... }` — parenthesized guard
syntax in match arms. Guards desugar to Zig labeled blocks with if/else chains.

### C/C++ source compilation in modules ✓

**Done in v0.15 Phase 24.** `#cimport = { name: "vma", include: "vk_mem_alloc.h",
source: "vma_impl.cpp" }` — the `source:` field compiles `.c`/`.cpp` files.
Auto-detects C++ from extension and applies `linkLibCpp()`.

### Runtime Library Removal ✓

**Done.** Zero runtime libraries. The only hardcoded imports are `const std = @import("std");`
and `str` (auto-imported for string method dispatch when not explicitly imported).

**What was removed:**
- `_orhon_collections` — collections require explicit `use std::collections` or `import std::collections` (v0.10.20)
- `_orhon_rt` — **deleted entirely**. `_rt.zig` and `_rt.orh` no longer exist.
- All `_rt.` references in codegen replaced with native Zig equivalents
- `_str` and `_collections` hardcoded prefixes replaced with user import aliases
- `OrhonRing`/`OrhonORing` stubs removed

**Native type mapping (no wrappers):**
- `(null | T)` -> `?T` (native Zig optional)
- `(Error | T)` -> `anyerror!T` (native Zig error union)
- `Error("msg")` -> `error.msg_sanitized` (native Zig error code)
- `typeid(x)` -> `@intFromPtr(@typeName(@TypeOf(x)).ptr)` (inline)
- Allocator -> `std.heap.smp_allocator` (inline)
- `Handle(T)` -> `_OrhonHandle(T)` (comptime helper emitted per file)

### PEG Parser — Error Recovery ✓

**Done in v0.9.3.** Grammar-level error recovery via `error_skip` + `top_level_start`
rules in `orhon.peg`. On top-level parse failure, skips bad tokens until the next
declaration keyword (`func`, `struct`, etc.) and continues parsing. Multiple syntax
errors collected via `BuildContext.syntax_errors`.

### MIR — Complete Self-Containment Migration ✓

**Done.** All semantic data reads from MirNode. Added `LiteralKind` enum, `is_const`,
`type_annotation`, `return_type`, `backing_type`, `type_params`, `default_value`,
`bit_members`, `arg_names`, `field_names`, `captures`, `index_var`, `names`,
`interp_parts` fields. Match arm children now include pattern (`[pattern, body]`).
`collectAssignedMir` traverses MirNode tree. 6 residual `m.ast` accesses remain for:
source location queries, current function node tracking, and `type_expr`/`passthrough`
(type trees are structural, not duplicated into MIR).

### Fuzz Testing ✓

**Done in v0.12.** `std.testing.fuzz` covers lexer and parser. Standalone harness in
`src/fuzz.zig` with 5 strategies and 50,000 iterations.

### Bridge codegen fixes ✓

**Done in v0.16 Phase 25.** `const &BridgeStruct` parameters now pass by pointer
(not by value). Sidecar `export fn` declarations are fixed to `pub export fn` via
read-modify-write scanner. `is_bridge` flag on FuncSig guards const auto-borrow for
bridge calls.

### Cross-module `is` operator and negative literal parsing ✓

**Done in v0.16 Phase 26.** Cross-module `is` operator uses tagged union tag
comparison for arbitrary unions. Unary `-` placed before `&` in PEG unary_expr rule
to fix negative literal parsing.

### C interop: sidecar dedup, cimport include paths, linkSystemLibrary ✓

**Done in v0.16 Phase 27.** Infinite loop in pub-fixup scanner fixed. `addIncludePath`
derives path from sidecar dirname. Unconditional `cimport_source == null` guards
removed. Multi-file modules with Zig sidecars build correctly.

### Cross-compilation target fix and build cache cleanup ✓

**Done in v0.16 Phase 28.** Cross-compilation target flag corrected. Build cache
cleaned up. Dead `Async(T)` codegen branch removed from `typeToZig`.

### Codegen refactor ✓

**Done.** Split into 5 files: hub (`codegen.zig`) + 4 satellites (`codegen_decls.zig`,
`codegen_exprs.zig`, `codegen_stmts.zig`, `codegen_match.zig`). Zig IR layer rejected
— direct string emission kept. All smart decisions happen in MIR.

### Builtins cleanup — `List`, `Map`, `Set` no longer hardcoded ✓

**Done in v0.10.20.** Removed `List`, `Map`, `Set` from `BUILTIN_TYPES`. Collections
are now resolved through the import system like any other module. `use std::collections`
or `import std::collections` required. Added bridge func declarations to `collections.orh`.
Fixed `preScanImports` to recognize `use` keyword. Always collect declarations for all
modules (including cached) so cross-module type resolution works. Codegen's collection
auto-import and prefix logic removed.
