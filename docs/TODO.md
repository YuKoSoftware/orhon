# Orhon — TODO

Items ordered by importance and how much they unblock future work.
Research sources: `.planning/research/` (compiler-techniques, zig-ecosystem, language-design).

---

## Bugs

### Codegen — multi-type null union collapses to optional

`(null | A | B | C)` generates `?A` instead of a proper tagged union with null.
Tamga workaround: `NoEvent` sentinel struct instead of null in event unions.

### Codegen — `cast(EnumType, int)` emits `@intCast` instead of `@enumFromInt`

Cannot cast raw integers to enum variants. Tamga workaround: stores raw `u32`/`u8`
fields instead of enum types for SDL scancodes and mouse buttons.

### Codegen — empty struct construction generates invalid Zig

`TypeName()` for a zero-field struct emits `TypeName()` in Zig (invalid).
Tamga workaround: dummy `pub empty: bool` field on `NoEvent`.

### Build — multi-file module with Zig sidecar: "file exists in two modules"

Build fails when a module has multiple `.orh` files and a `.zig` sidecar.
Pre-existing issue, confirmed before Tamga VMA work.

### Parser — `size` is a reserved keyword in bridge func parameters

Cannot use `size` as a parameter name. Tamga workaround: renamed to `byte_size`.

### Codegen — `const &BridgeStruct` passes by value instead of by pointer

Bridge struct parameters typed as `const &` generate by-value passing in Zig.
Tamga workaround: pass small bridge structs by value.

### Codegen — sidecar `export fn` should emit `pub export fn`

Bridge functions in a module's sidecar `.zig` are not accessible from generated
Orhon code because `export fn` lacks `pub`.

### ~~Codegen — cross-module struct ref-passing~~ — fixed v0.10 Phase 4

~~Codegen didn't know imported method parameter types.~~ Fixed: MIR `resolveCallSig`
now resolves cross-module instance method signatures for `value_to_const_ref` coercion.

### ~~Resolver — qualified generic types not validated~~ — fixed v0.10 Phase 4

~~Qualified generic types bypassed validation.~~ Fixed: resolver reports Orhon-level
errors when module is found but type doesn't exist in its DeclTable.

### ~~Ownership — const values treated as moved on by-value pass~~ — fixed v0.11 Phase 8

~~Const struct values counted as moves.~~ Fixed: const non-primitives now auto-borrow
as `const &` at call sites. Codegen emits `*const T` signatures and `&arg` at call sites.
`copy()` still works for explicit copies.

### ~~Codegen — tester module fails to compile (cross-module codegen)~~ — fixed v0.12 Phase 13

~~For-loop index variables, destructure name leaking, named tuple types, null literal
wrapping, pointer syntax, collection constructors~~ — all fixed. Test stages 09 (21/21)
and 10 (102/102) pass fully. Cross-module codegen is correct end-to-end.

### ~~Unit test — intermittent "read module name" failure~~ — fixed v0.12 Phase 13

~~The "read module name" test in module.zig wrote to a hardcoded `/tmp/test_module.orh`
path, causing write/delete races when Zig runs tests in parallel threads or when multiple
`zig build test` invocations overlap.~~ Fixed: switched to `std.testing.tmpDir` so each
test invocation gets an isolated temporary directory with automatic cleanup.

### Module — sidecar path leaked (`error(gpa)`) — fixed v0.9.6

~~`module.zig:660` allocates a sidecar path string that is never freed.~~ Fixed: freed
in `Resolver.deinit()`.

### ~~`orhon test` — output format mismatch~~ — fixed v0.10 Phase 4 (v0.9 Phase 1)

~~Reports 0 passed/0 failed.~~ Fixed: test output parsing corrected.

### ~~Stdlib — string interpolation leaks memory~~ — fixed v0.10 Phase 6

~~`@{variable}` allocates temp buffers never freed.~~ Fixed: codegen emits
`defer std.heap.page_allocator.free(...)` after each `allocPrint`.

### ~~Codegen — `catch unreachable` in generated code~~ — fixed v0.10 Phase 5

~~Thread shared state allocation crashes on OOM.~~ Fixed: 4 compiler-side instances
replaced with `@panic` with diagnostic messages. 8 generated-code instances are
correct (error union narrowing) and remain.

### ~~Stdlib — silent error suppression (`catch {}`)~~ — fixed v0.10 Phase 5

~~103 instances of `catch {}` across 15 files.~~ Fixed: v0.9 Phase 2 fixed 75 instances,
v0.10 Phase 5 fixed remaining 8 data-loss sites (collections, stream). 20 fire-and-forget
I/O sites (console, tui, fs, system) intentionally retained.

---

## Core — Language Ergonomics

These are the highest-impact language changes. Every user benefits immediately.

### `try` keyword for error propagation

The single biggest ergonomic improvement. Eliminates 3-4 lines of boilerplate per
error-returning call. Maps directly to Zig's `try`.

```
// Current (verbose)
var result: (Error | i32) = divide(10, 0)
if(result is Error) { return result.Error }
var value: i32 = result.value

// With try (concise)
var value: i32 = try divide(10, 0)
```

The function must return `(Error | T)` to use `try`. Compile error otherwise.
Rust's `?`, Zig's `try`, Swift's `try` all prove this pattern works. Every modern
language with error unions has single-character propagation.

### Pattern guards in match

`case x if x > 0` — conditional match arms. Currently requires nested `if` inside
match body. Small feature, big ergonomic win. Standard in Rust, Scala, Gleam, Swift.

### Non-lexical lifetimes (NLL)

Move borrow checker from lexical lifetimes to "borrow ends at last use." Currently
borrows are dropped at scope exit (`dropBorrowsAtDepth`). NLL accepts more valid
programs without sacrificing safety — eliminates the most common "fighting the borrow
checker" scenarios.

**Implementation:** build use-def chains during type resolution, use them in borrow
checking. A borrow's lifetime extends from creation to the last use of the reference,
not to the end of the scope. ~85% of Rust's safety for ~30% of Polonius complexity.

Full Polonius (flow-sensitive dataflow analysis) is overkill for Orhon.

### Allocator pairing — already covered

~~Should arena allocators accept a backing allocator?~~ **Not needed.** Mode 2
(`.new(my_allocator)`) already handles this. Users create composed allocators in
bridge code and pass them through. No new syntax — Orhon's value is hiding this
complexity, not exposing it.

---

## Core — Compiler Architecture

Ordered by how much each item unblocks downstream work.

### Codegen — refactor, not rewrite

~~Original plan: 3-layer split (Zig IR + Lowering + Printer).~~ **Rejected.** A Zig IR
would mean modeling Zig's semantics inside the compiler — a second representation that
can drift from real Zig on every version bump. Bugs would hide across two layers instead
of one. The real optimization target is MIR/SSA (our own IR), not a Zig AST model.

**Instead:** keep direct string emission but clean up the 3262-line codegen:
- Extract helper functions, group by construct type
- Split into 2-3 files (declarations, expressions, statements)
- 80% of the maintainability benefit without the abstraction cost

The Zig printer should stay dumb and direct. All smart decisions (coercions, union
wrapping, bridge imports) happen in MIR.

### Incremental compilation — semantic hashing

Replace timestamp-based cache invalidation with semantic hashing. Hash the token
stream (or normalized AST) after lexing. Avoids unnecessary recompilations when files
are touched but not changed (git checkout, save without editing, formatting).

Quick win — moderate effort, high impact.

### Incremental compilation — interface diffing

After declaration pass on a changed module, compare its public interface (exported
functions, types, constants) against the cached interface. If unchanged, downstream
modules skip recompilation even though the implementation changed. This is TypeScript's
declaration-file trick.

**Implementation:** serialize public DeclTable to canonical form, hash it, store hash.
When checking downstream modules, compare interface hash, not file hash.

### PEG error recovery — expected-set accumulation

Replace single `furthest_expected` with a set. When alternatives `A / B / C` all fail
at the same position, the error message becomes "expected keyword, identifier, or '('"
instead of just "expected '('". Low effort, high impact.

**Implementation in `engine.zig`:**
```zig
// Replace single furthest_expected with:
furthest_expected_set: std.EnumSet(TokenKind) = .{},
// On terminal match failure at furthest_pos: insert into set
// On new furthest_pos: clear set and start fresh
```

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

### Bridge module import scoping

Named bridge modules are currently added as imports to all targets in the generated
`build.zig`, not just the target that owns the bridge. Functionally safe — codegen only
emits `@import` for a module's own bridge — but the extra `addImport` entries are
unnecessary. Tighten so each target only receives its own bridge import if the build
graph gets large enough for this to matter.

---

## Core — Build System

### C/C++ source compilation in modules

No mechanism to compile `.c`/`.cpp` files as part of a module build. Tamga VMA requires
manually patching the generated `build.zig` after every build to add `vma_impl.cpp`.

In Zig 0.15, the pattern is `exe.root_module.addCSourceFiles(.{ .files = &.{"file.cpp"},
.flags = &.{"-std=c++17"} })`. Needs an Orhon directive like `#cSources "file.c"`.

Unblocks: any project that wraps C/C++ libraries (game engines, system bindings).
Without this, users must maintain manual build scripts alongside Orhon.

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
- Expected-set accumulation — show all expected tokens, not just one
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

### Traits (minimal)

The missing type system foundation. Unlocks constrained generics, `#derive`, and
library patterns. Keep it simple:

```
trait Drawable {
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
Composition via requiring multiple traits. No trait objects initially.

Unblocks: generic constraints (already in TODO), `#derive`, numerous library patterns.

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

### First-class closures

`fn(T) R` with captured environment. Currently captured variables must be simple
identifiers. Full closures enable callbacks, event handlers, and functional patterns.
Ownership of captures follows normal rules.

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

### Comma-separated `#linkC`

`#linkC "vulkan, SDL3"` instead of multiple `#linkC` lines. Split on `,` + trim in
directive handler.

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

## Documentation Gaps

### `include` vs `import` semantics

No dedicated section explaining the difference. `include` brings names into current
scope, `import` keeps them namespaced — but this is only mentioned once in COMPILER.md.

### String interpolation `@{...}`

Not documented in the language spec at all. Syntax, supported expressions, format
specifiers, and memory behavior should be specified.

### Testing framework

Only 15 lines of docs. Missing: test filtering, fixtures, assertion variety, output
format, organization patterns.

### LSP capabilities

No user-facing documentation. Missing: supported features, editor setup guide,
VS Code extension usage.

### `compt` function rules

When and how compile-time evaluation triggers. Can compt functions call other compt
functions? What happens with non-constant arguments?

### Design rationale documentation

Explain WHY Orhon chose "no closures," "no lifetime annotations," "nominal tuples."
These are interesting design decisions that attract language enthusiasts and help users
understand the philosophy. Gleam, Roc, and Zig all do this well.

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

### Runtime Library Removal ✓

**Done.** Zero runtime libraries. The compiler injects no hardcoded imports. The only
hardcoded import is `const std = @import("std");`.

**What was removed:**
- `_orhon_collections` — collections are now a normal bridge module (`import std::collections`)
- `_orhon_str` — string ops are a normal bridge module (`import std::str`)
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
