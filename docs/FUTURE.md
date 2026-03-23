# Orhon — Roadmap

---

## Priority 1 — Architecture

These unblock open bugs and enable major features.

### ~~MIR Phase 3 — Coercion Pass + MirNode Tree~~ (implemented v0.5.3)

MIR annotator compares types at call sites, declarations, and return statements,
marking coercion fields on AST nodes. MirLowerer builds a typed MirNode tree that
codegen walks instead of the AST. Codegen reads type info directly from MirNode
(`type_class`, `coercion`, `resolved_type`) — no more NodeMap hash lookups for
the main dispatch path.

**Coercions:** array_to_slice, null_wrap, error_wrap, arbitrary_union_wrap, optional_unwrap.
**MirNode tree:** Top-level → block → statement → expression dispatch all on MirKind.
**Type narrowing:** `extractNarrowing` pre-computes `IfNarrowing` (then/else/post types).
**Interpolation hoisting:** `temp_var`/`injected_defer` injected nodes in blocks.

**Cleanup (v0.5.4):** All statement/expression codegen migrated to MIR path — struct/enum
members, match, for, destruct, test bodies, thread bodies. `stampNarrowing()` stamps
`narrowed_to` on MirNode descendants during lowering. MIR codegen path is fully
self-contained — no `type_narrowed_vars` map, no fallthrough to AST-path functions.
AST-path codegen retained only for unit tests (which build raw AST without MIR setup).

### ~~Threading — `thread` keyword + `Handle(T)`~~ (implemented v0.5.0)

Thread functions compile to OS threads via `std.Thread`. `Handle(T)` is a compiler-generated
type with `.value`, `.wait()`, `.done()`, `.join()` methods. Thread safety checker ensures
handles are consumed before scope exit. See [Threading Model](#threading-model) for design.

---

## Priority 2 — Standard Library

All stdlib modules use the bridge pattern (module + `.zig` sidecar). The codegen has no knowledge of stdlib types — everything goes through `bridge` declarations. Users can build their own bridge modules the same way.

### Implemented
```
std.allocator     // memory allocators — SMP, Arena, Page
std.console       // terminal I/O — print, println, get
std.fs            // filesystem — readFile, writeFile, exists, remove, mkdir, readDir
std.json          // JSON — get, hasKey, object, stringify
std.math          // math — abs, sqrt, pow, trig, floor, ceil, round + integer variants
std.random        // random — int, float, boolean, seed
std.sort          // sorting — intAsc, intDesc, floatAsc, strAsc, reverse
std.str           // string utilities — contains, replace, toUpper, parseInt, toString, etc.
std.system        // OS — run, getEnv, cwd, exit, signals (trap, check, clear, raise)
std.time          // time — now, sleepMs, elapsed, format
std.collections   // List(T), Map(K,V), Set(T) — generic collections via bridge
std.ziglib        // bridge testbed — exercises all interop patterns
std.simd          // SIMD vector intrinsics — reduce, splat, reverse
```

### Next up
```
std.process       // spawn processes, pipes, child processes
std.encoding      // base64, hex, UTF-8, UTF-16
std.io            // raw streams, buffers, readers, writers
std.net           // raw sockets — TCP, UDP
std.crypto        // primitives only — hashing, symmetric, asymmetric encryption
```

### Remaining
```
std.unicode       // full unicode support, normalization
std.reflect       // type introspection
std.compress      // algorithms only — lz4, zstd, deflate
std.regex         // pattern matching
std.xml           // parse and emit XML
std.csv           // parse and emit CSV
std.hash          // fast general purpose hashing — FNV, xxHash, SipHash
std.bytes         // raw byte manipulation, endianness, bit operations
std.math.linear   // Vec2(T), Vec3(T), Vec4(T), Mat4(T), Quat(T)
```

### Far future
```
std.yaml          // parse and emit YAML
std.audio         // audio device access, playback primitives
std.window        // window creation, input events, platform abstraction only
std.gpu           // GPU access, compute, backend agnostic (Vulkan, OpenGL, WebGPU)
```

---

## Priority 3 — Polish & Tooling

### Example Module Updates

Add coverage for features not yet in the example module:
- String interpolation `@{variable}`
- Bitfield enums (`enum @bitfield`)
- Stdlib import/usage examples

### Fuzz Testing

Use Zig's built-in `std.testing.fuzz` to fuzz the lexer and parser.

---

## Priority 4 — Future Architecture

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

---

## MIR Roadmap

### Phase 1 — Typed Annotation Pass (implemented)
The MIR annotator (pass 10) walks the AST + resolver type_map to produce a NodeMap — an annotation table keyed by AST node pointer. Each entry carries `ResolvedType`, `TypeClass`, and optional coercion/narrowing info. Codegen can query this instead of re-discovering types via ad-hoc hashmaps. Includes a `UnionRegistry` for canonical union type deduplication.

### Phase 2 — Single Source of Truth (implemented)
MIR is the single source of truth for type information in codegen. Eliminated all AST type inspection functions (`isErrorUnionType`, `isNullUnionType`, `isArbitraryUnion`), the `arb_union_vars` hashmap, and 4 function return type tracking fields. Added `var_types` registry, `current_func_node` tracking, and `funcReturnTypeClass()`/`funcReturnMembers()` helpers. Codegen queries MIR for all type decisions. Only `narrowed_vars` remains (legitimate runtime scope state from `is` checks).

### Phase 3 — Coercion Pass + Typed Tree (implemented)
Coercion annotation pass complete for all 5 coercion types. MirLowerer builds a full MirNode tree from AST + NodeMap. Codegen walks the MirNode tree for top-level → block → statement → expression dispatch, reading `type_class`/`coercion`/`resolved_type` directly from MirNode instead of hash-querying NodeMap. MirNode accessors (`body()`, `condition()`, `lhs()`, `rhs()`, `getCallee()`, `callArgs()`, etc.) make child layout self-documenting. `extractNarrowing` pre-computes `IfNarrowing` with then/else/post types. MirLowerer injects `temp_var`/`injected_defer` nodes for interpolation hoisting.

**v0.5.4 cleanup:** All codegen migrated to MIR path. Struct/enum members iterate MirNode children (`field_def`, `enum_variant_def`). Match, for, destruct, test, thread — all use MirNode tree. `stampNarrowing()` stamps `narrowed_to` on descendant MirNodes during lowering (if_stmt then/else/post, match arms). MIR codegen is fully self-contained — no runtime `type_narrowed_vars` map, no AST-path fallthrough. AST-path functions retained only for unit tests.

### Phase 4 — Optimization + Caching
Selective optimization passes — only where Orhon has type knowledge that Zig/LLVM lacks. Inspired by vnmakarov/MIR's philosophy: pick high-impact passes, skip what the downstream compiler already handles.
4a: SSA construction (Braun's algorithm, basic blocks, phi nodes — foundation for all passes).
4b: Inlining (bridge wrappers, single-expression functions, coercion wrappers).
4c: Dead code elimination (trivial on SSA — unused values, unreachable code).
4d: Type-aware constant folding (static @type checks, redundant coercion chain elimination).
4e: MIR caching (binary serialization per module, file-hash invalidation for incremental builds).

---

## Threading Model

Threading is a **language-level feature**, not a stdlib module. A thread is a function that runs concurrently and returns a `Handle(T)`.

### Syntax

Declaration — identical to `func`, but with the `thread` keyword and `Handle(T)` return type:

```
thread worker(data: List(int)) Handle(int) {
    const sum: int = data.reduce(fn(a, b) { return a + b })
    return Handle(sum)
}
```

Calling a thread starts it immediately. The return value is a `Handle(T)`:

```
const h: Handle(int) = worker(my_data)
const result: int = h.return()
```

### Handle(T)

The handle is the interface between the caller and the running thread. Internally it holds a pointer to the OS thread and an optional result slot.

**Methods:**
- `.return()` — blocks until done, moves the value out, consumes the handle
- `.wait()` — blocks until done, does not consume
- `.done()` — non-blocking bool check
- `.join()` — blocks, discards value, cleans up

Calling `.return()` twice is a **compile error** — the value is moved on first call, the handle is consumed.

### Ownership rules

Threads follow the same ownership rules as functions — no special cases:

- **Move** — data moves into the thread on the call, comes back on `.return()`. No window where two threads access the same data.
- **Immutable borrow** — pass freely to multiple threads. Multiple readers, no conflict.
- **Mutable borrow** — one thread only. Enforced by existing borrow checker.
- **Split** — divide mutable data between threads. Each gets its own slice.

No mutexes, no locks, no atomics at the language level. The borrow checker prevents data races by design.

### Multiple spawns

Each call returns a fresh handle. Thread declarations are templates, handles are live instances:

```
const a: Handle(int) = worker(data1)
const b: Handle(int) = worker(data2)
const r1: int = a.return()
const r2: int = b.return()
```

### Void threads

```
thread logger(msg: str) Handle(void) {
    print(msg)
    return Handle(void)
}

const h: Handle(void) = logger("hello")
h.return()
```

### Implementation

- Threads map to OS threads (`std.Thread` in Zig).
- `Handle(T)` is a compiler-generated generic struct.
- `.done()` uses an atomic bool under the hood — invisible to the user.
- `.return()` and `.wait()` use OS thread join for synchronization.
- No runtime, no scheduler, no colored functions.
- Users can build their own thread pools using `List(Handle(T))`.

### Design decisions

- No `std.thread` module — threading is a language primitive.
- No goroutines — no runtime, no GC, no scheduler overhead.
- No async/await — no colored functions, no executor.
- Thread pool is a user-space concern — a list of handles is a pool.
- Shared mutable state between threads is impossible by design.

---

## Decided Against

- **Closures** — function pointers cover the use case. Captures create ownership complexity. Pass variables as arguments instead.
- **Traits / interfaces** — `any` + `compt` covers generic type dispatch. Traits add complexity (hierarchies, orphan rules, associated types) without proportional value.
- **Coroutines / async** — threads + move semantics cover parallelism. Coroutines need a runtime, colored functions, and an executor.
- **REPL** — compiled language. `orhon run` is fast enough. A REPL needs an interpreter or incremental compiler.
- **Top-level `println`** — keep in `std::console`. One import, all I/O. No special-case global functions.
- **Collection method chaining** — `.filter().map().take()` allocates intermediate collections. For loops are explicit, zero-alloc, and already work.
- **Untagged unions** — all unions carry a tag. Safety requires knowing which type is active. Use `bridge struct` with Zig sidecar for unsafe C interop.
- **Goroutines** — need a runtime, GC, scheduler. OS threads + move semantics are deterministic with no runtime overhead.
- **`Array(T, N)` / `Slice(T)` syntax** — `[N]T` and `[]T` are shorter, universal, and match array literals.
- **`else` on `for`/`while`** — confusing semantics. Use `if(items.len == 0)` instead.
- **Enum associated values** — arbitrary unions + `is` already cover this cleanly.
