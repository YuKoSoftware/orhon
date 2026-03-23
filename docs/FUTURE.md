# Orhon — Future Ideas

Ideas and language decisions that are not yet committed.

---

## Decided Against

- **Closures** — function pointers cover the use case. Captures create ownership complexity. Pass variables as arguments instead.
- **Traits / interfaces** — `any` + `compt` covers generic type dispatch. Traits add complexity (hierarchies, orphan rules, associated types) without proportional value.
- **Coroutines / async** — threads + move semantics cover parallelism. Coroutines need a runtime, colored functions, and an executor.
- **REPL** — compiled language. `orhon run` is fast enough. A REPL needs an interpreter or incremental compiler.
- **Top-level `println`** — keep in `std::console`. One import, all I/O. No special-case global functions.
- **Collection method chaining** — `.filter().map().take()` allocates intermediate collections. For loops are explicit, zero-alloc, and already work.
- **Untagged unions** — all unions carry a tag. Safety requires knowing which type is active. Use `extern struct` with Zig sidecar for unsafe C interop.
- **Goroutines** — need a runtime, GC, scheduler. OS threads + move semantics are deterministic with no runtime overhead.
- **`Array(T, N)` / `Slice(T)` syntax** — `[N]T` and `[]T` are shorter, universal, and match array literals.
- **`else` on `for`/`while`** — confusing semantics. Use `if(items.len == 0)` instead.
- **Enum associated values** — arbitrary unions + `is` already cover this cleanly.

---

## Standard Library Roadmap

All stdlib modules use the bridge pattern (module + `.zig` sidecar). The codegen has no knowledge of stdlib types — everything goes through `extern` declarations. Users can build their own bridge modules the same way.

### Implemented (bridge modules)
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
```

### Not started
```
std.net           // raw sockets — TCP, UDP
std.encoding      // base64, hex, UTF-8, UTF-16
std.unicode       // full unicode support, normalization
std.process       // spawn processes, pipes, child processes
std.reflect       // type introspection
std.crypto        // primitives only — hashing, symmetric, asymmetric encryption
std.compress      // algorithms only — lz4, zstd, deflate
std.regex         // pattern matching
std.xml           // parse and emit XML
std.csv           // parse and emit CSV
std.hash          // fast general purpose hashing — FNV, xxHash, SipHash
std.io            // raw streams, buffers, readers, writers
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

### Deliberately excluded
- `std.http` — too opinionated, third party
- `std.db` — too opinionated, third party
- `std.log` — too opinionated, third party
- GUI frameworks — too opinionated, third party

---

## Missing Tooling

### Documentation Generator (`orhon doc`)
Generate HTML/Markdown docs from `pub` declarations and doc comments.

### Fuzz Testing
Use Zig's built-in `std.testing.fuzz` to fuzz the lexer and parser.

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

## MIR Roadmap

### Phase 1 — Typed Annotation Pass (implemented)
The MIR annotator (pass 10) walks the AST + resolver type_map to produce a NodeMap — an annotation table keyed by AST node pointer. Each entry carries `ResolvedType`, `TypeClass`, and optional coercion/narrowing info. Codegen can query this instead of re-discovering types via ad-hoc hashmaps. Includes a `UnionRegistry` for canonical union type deduplication.

### Phase 2 — Single Source of Truth (implemented)
MIR is the single source of truth for type information in codegen. Eliminated all AST type inspection functions (`isErrorUnionType`, `isNullUnionType`, `isArbitraryUnion`), the `arb_union_vars` hashmap, and 4 function return type tracking fields. Added `var_types` registry, `current_func_node` tracking, and `funcReturnTypeClass()`/`funcReturnMembers()` helpers. Codegen queries MIR for all type decisions. Only `narrowed_vars` remains (legitimate runtime scope state from `is` checks).

### Phase 3 — Typed Tree
Lower the NodeMap into a proper `MirNode` tree with its own node types. Codegen reads the MirNode tree instead of the AST. This enables desugaring and tree transformations before code emission.

### Phase 4 — SSA + Optimization
Flatten the MirNode tree to basic blocks with SSA form. Add optimization passes: dead code elimination, constant folding, inlining decisions. Codegen reads the SSA IR.
