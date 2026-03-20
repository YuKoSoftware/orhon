# Kodr — Future Ideas

Ideas and language decisions that are not yet committed. These may make it into the language, get rejected, or evolve into something else.

---

## Next Steps

### Intra-project library linking
When a project has multiple `#build` targets (e.g. an exe + a dynamic lib), the exe
currently compiles the lib's Kodr source inline — it does NOT link against the built
`.so`/`.a`. The artifacts are produced as standalone files but not wired together.

What's needed:
- In `zig_runner.buildZigContent`, when building the exe, detect which sibling modules
  are lib targets and emit `exe.linkLibrary(lib)` / `b.installArtifact(lib)` calls so
  Zig links them properly.
- A single `build.zig` that builds all targets in one `zig build` invocation (instead
  of N sequential invocations) would be cleaner and avoid redundant compilation.
- The module system needs to distinguish "import as source" vs "link as library" —
  when a module has `#build = dynamic`, importing it from the exe should mean linking,
  not inlining the source.

Until this is implemented: within a single project, share code via regular modules
(no `#build`). Use `#build` only for artifacts meant to be distributed to other
projects via `#dep`.

---

## Missing Core Language Features


### Arbitrary Unions
The spec documents `const MyUnion = (i32 | f32)` but only `(Error | T)` and `(null | T)` are confirmed working end-to-end. General-purpose unions beyond those two need to be verified and fully implemented in codegen + all analysis passes.

**Priority: medium** — needed for expressing domain types cleanly.

### String Operations — PARTIALLY DONE
Non-allocating string methods are implemented as compiler-known field operations on `String`:
`s.contains()`, `s.startsWith()`, `s.endsWith()`, `s.trim()`, `s.trimLeft()`, `s.trimRight()`,
`s.indexOf()`, `s.lastIndexOf()`, `s.count()`, `s.split()` (destructuring only).

Still missing (allocating — need design decision on allocator passing):
`toUpper`, `toLower`, `replace`, `repeat`, `join`, `parseInt`, `parseFloat`, `toString`.

**Priority: medium** — non-allocating ops done, allocating ones need allocator design.

---

## Missing Standard Library

Only `std::console` exists today. Minimum viable stdlib for a general-purpose language:

| Module | Contents |
|---|---|
| `std::str` | format, join, toUpper, toLower, replace, repeat, parseInt, parseFloat, toString (non-allocating ops now builtin on String) |
| `std::fs` | **DONE** — File/Dir builtin types + fs.exists/delete/rename/createDir/deleteDir |
| `std::math` | **DONE** — pow, sqrt, abs, min, max, floor, ceil, sin, cos, tan, ln, log2, PI, E |
| `std::env` | environment variables, process args, cwd |
| `std::time` | timestamps, sleep, duration, formatting |
| `std::net` | TCP/UDP sockets, basic HTTP client |
| `std::json` | parse and emit JSON |
| `std::sort` | sort slices and lists, custom comparators |

All of these are wrappable from Zig's stdlib. The work is designing the Kodr API surface and adding codegen/builtins support for each.

**Priority: `std::str`, `std::fs`, `std::math` are high. The rest are medium.**

---

## Missing Tooling

### Language Server (LSP)
No editor integration. Blocks adoption — most developers expect go-to-definition, autocomplete, and inline errors. Needed before the language is usable day-to-day.

### Formatter (`kodr fmt`)
No canonical formatter. Needed for consistent codebases and CI pipelines. Should be opinionated with no configuration — one style, always.

### Documentation Generator (`kodr doc`)
Generate HTML/Markdown docs from `pub` declarations and doc comments. Needed for publishing libraries.

---

## Extended `extern` — data, types, and Zig-generated code

Currently `extern func` only bridges Kodr → Zig for functions. The bridge should be extended to cover:

- **`extern func` with `any` params** — maps to `anytype` in the sidecar `.zig`, enabling generic Zig utilities callable from Kodr
- **`extern var` / `extern const`** — expose a Zig variable or constant to Kodr (e.g. hardware registers, OS constants)
- **`extern struct` / `extern enum`** — declare a type whose layout and implementation lives in Zig, used as an opaque or fully-typed value in Kodr
- **Zig-generated code** — allow a sidecar `.zig` file to `comptime`-generate types or values that Kodr then imports, enabling macros/codegen patterns without adding them to the Kodr language itself

This would make the Zig bridge a full interop layer, not just a function escape hatch. Particularly useful for: hardware bindings, wrapping C libraries, and letting power users drop into Zig for anything Kodr doesn't cover yet.

---

## Additional allocators — `mem.Pool`, `mem.Ring`, `mem.OverwriteRing`

Three allocator types are designed but not yet implemented in the compiler:

- `mem.Pool(T)` — homogeneous object pool, fixed-size chunks, no fragmentation
- `mem.Ring(T, n)` — circular buffer, returns Error when full (backpressure)
- `mem.OverwriteRing(T, n)` — circular buffer, silently overwrites oldest when full

These map to Zig's `std.heap.MemoryPool` and ring buffer implementations.
Priority: low — implement after core language is stable.

---

## `#gpu` metadata — GPU/concurrency

`#gpu` is reserved for future GPU/concurrency design. `thread` is implemented; `async` is deferred.
