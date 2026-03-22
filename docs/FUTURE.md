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
std.str           // string utilities — contains, replace, toUpper, parseInt, toString, etc.
std.ziglib        // bridge testbed — exercises all interop patterns
```

### Being rebuilt (emptied for fresh bridge implementation)
```
std.json          // JSON parsing and serialization
std.math          // mathematical functions
std.random        // random number generation
std.sort          // sorting and ordering
std.system        // OS interaction
std.time          // time and duration
```

### Not started
```
std.collections   // List, Map, Set — generic collection types (bridge)
std.net           // raw sockets — TCP, UDP
std.encoding      // base64, hex, UTF-8, UTF-16
std.unicode       // full unicode support, normalization
std.process       // spawn processes, pipes, child processes
std.signal        // OS signals — SIGINT, SIGTERM etc
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
std.thread        // thread spawning, joining (bridge replacement for builtin thread)
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

## Pending Language Work

### `for` loop over bridge types
Solved by having bridge types expose `.items()` returning a slice. Standard `for` iteration works on slices. No codegen change needed — bridge modules implement the pattern.

## Future Language Features

### `unsafe` keyword
Relaxes bridge safety rules within a block — allows mutable refs across the Orhon↔Zig boundary. Not yet implemented; strict mode (option 1) is the current default.

### `#gpu` metadata
Reserved for future GPU/concurrency design.
