# Orhon — TODO

---

## Bugs

### Codegen — cross-module struct ref-passing

When calling a method on an imported module's struct, the codegen doesn't know the
method's parameter types. If a parameter takes `const &T`, the codegen emits the
argument by value instead of taking its address with `&`. Zig then errors with
`expected type '*const T', found 'T'`.

Affected: any cross-module struct method with `const &` non-self parameters.
Workaround: use by-value parameters for cross-module struct methods.

Fix: codegen needs access to imported module DeclTables during method call generation,
or the MIR pass should annotate call arguments with the expected parameter passing mode.

### Resolver — qualified generic types not validated

`math.Vec2(f64)` passes resolver validation without checking that `Vec2` exists in the
math module's DeclTable. Currently, any dot-qualified generic type is trusted — validation
is deferred to Zig compile time. `math.Nonexistent(f64)` would pass the resolver silently.

Fix: resolver needs cross-module DeclTable access during `validateType()` for
`type_generic` nodes with qualified names.

### Ownership — const values treated as moved on by-value pass

Passing a `const` struct value to a function by value counts as a move. Using the same
const value in two separate calls errors with "use of moved value". Const values are
immutable and should be implicitly copyable — the ownership checker should treat by-value
passing of const values as a copy, not a move.

```
const a: Vec2(f64) = Vec2(f64)(x: 1.0, y: 2.0)
const b: Vec2(f64) = a.add(a)   // ERROR: use of moved value 'a'
```

### Codegen — tester module fails to compile (cross-module codegen)

The tester module (`test/fixtures/tester.orh`) fails with multiple Zig compilation errors
when built as a separate module. Errors include undeclared identifiers in for-loop index
contexts and type mismatches for null union assignments. The same code compiles when
inlined into the main module.

Errors observed:
- `tester.zig: error: use of undeclared identifier 'i'` — for-loop with index variable
  generates code referencing `i` without declaring it in the loop capture
- `tester.zig: error: expected type 'OrhonNullable(i32)', found '@TypeOf(null)'` — null
  literal assignment to a nullable type not wrapped correctly in cross-module context

Fix: investigate codegen differences between main-module and cross-module paths for
for-loop index captures and null union literal wrapping.

### Module — sidecar path leaked (`error(gpa)`)

`module.zig:660` allocates a sidecar path string with `allocPrint` that is stored in
`mod.sidecar_path` on success but never freed when the module is cleaned up. Shows as
`error(gpa): memory address ... leaked` in library and multi-target builds.

Fix: track sidecar_path ownership and free during module cleanup, or use the module's
arena allocator.

### `orhon test` — output format mismatch

`orhon test` reports `0 passed, 0 failed` instead of running tests and reporting
`all tests passed`. The test command generates the test binary but either doesn't run
the Zig test runner or doesn't parse its output correctly.

Affected: `test/05_compile.sh` — "orhon test — all tests pass" check.

### Stdlib — string interpolation leaks memory

`@{variable}` interpolation allocates temporary buffers that are never freed. Known
since early implementation. Fix after default allocator strategy matures.

### Codegen — `catch unreachable` in generated code

Thread shared state allocation and string interpolation emit `catch unreachable` in
the generated Zig code (`codegen.zig` lines 655, 688, 2123). This crashes on OOM
instead of propagating errors.

Fix: generated code should propagate allocation errors through the Zig error system.

### Stdlib — silent error suppression (`catch {}`)

103 instances of `catch {}` across 15 stdlib sidecar files silently swallow allocation
failures and I/O errors. Affected: collections, json, xml, yaml, csv, toml, ini, http,
fs, system, console, stream, regex, str, tui.

Fix: stdlib bridge functions should propagate errors back to the caller or use a
consistent error handling strategy.

---

## Polish

### Fuzz Testing

Use Zig's built-in `std.testing.fuzz` to fuzz the lexer and parser.

---

## Architecture

### PEG Parser — Error Recovery ✓

~~The PEG parser currently stops at the first error.~~ **Done in v0.9.3.** Grammar-level
error recovery via `error_skip` + `top_level_start` rules in `orhon.peg`. On top-level
parse failure, skips bad tokens until the next declaration keyword (`func`, `struct`, etc.)
and continues parsing. Multiple syntax errors collected via `BuildContext.syntax_errors`.

### MIR — Complete Self-Containment Migration ✓

~~MirNode now carries self-contained data fields populated during lowering. ~37 `m.ast.*`
accesses in codegen still read through the AST back-pointer.~~ **Done.** All semantic data
reads from MirNode. Added `LiteralKind` enum, `is_const`, `type_annotation`, `return_type`,
`backing_type`, `type_params`, `default_value`, `bit_members`, `arg_names`, `field_names`,
`captures`, `index_var`, `names`, `interp_parts` fields. Match arm children now include
pattern (`[pattern, body]`). `collectAssignedMir` traverses MirNode tree. 6 residual
`m.ast` accesses remain for: source location queries, current function node tracking,
and `type_expr`/`passthrough` (type trees are structural, not duplicated into MIR).

**Next:** split codegen into three layers:
- **Zig IR** — small explicit representation of target Zig AST (~15-20 node types)
- **Lowering** (MIR → Zig IR) — coercions, union wrapping, bridge imports
- **Zig Printer** (Zig IR → text) — trivial pretty-printer (~500 lines)

### Dependency-Parallel Module Compilation

Modules are processed sequentially in topological order. Independent modules (whose deps
are all complete) could be processed in parallel via a thread pool.

**Prerequisites:**
- Thread-safe `Reporter` (atomic append to error/warning lists)
- Per-module allocators (already arena-based, close to ready)
- Work-stealing queue with dependency tracking
- Careful DeclTable registration ordering for cross-module refs

The `SemanticContext` refactor (v0.9.3) lays groundwork — each pass now takes a shared
context rather than wiring individual fields, making per-thread state easier.

### PEG Parser — Syntax Documentation Generator

Auto-generate a formatted syntax reference from `src/orhon.peg`. Each rule name
becomes a section heading, alternatives become the documented forms.

### MIR Phase 4 — Optimization + Caching

Selective optimization passes — only where Orhon has type knowledge that Zig/LLVM lacks.
Inspired by vnmakarov/MIR's philosophy: pick high-impact passes, skip what the downstream compiler already handles.

**4a — SSA construction.** Flatten MirNode tree to basic blocks, build SSA form using Braun's
algorithm (simple, no dominance frontiers needed). Each value gets a single definition, phi
nodes at join points. This is the foundation — all subsequent passes run on SSA form.

**4b — Inlining.** Identify inline candidates: bridge wrappers, single-expression functions,
generated coercion wrappers. Substitute at call sites. SSA makes substitution clean (no
variable name collisions). Reduces emitted Zig volume and gives LLVM better input.

**4c — Dead code elimination.** Trivial on SSA: if an SSA value has no uses, delete it.
Reachability analysis from entry points, skip emission of unreachable code. Less emitted
Zig = faster Zig compilation.

**4d — Type-aware constant folding.** Fold `@type(x) == T` when statically known, eliminate
redundant wrap/unwrap coercion chains, simplify coercion sequences. Single definitions mean
constants propagate in one pass.

**4e — MIR caching.** Binary serialization/deserialization of SSA IR per module. Cache
invalidation via file content hashing. Skip annotation + lowering for unchanged modules on
incremental rebuilds.
