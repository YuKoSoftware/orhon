# Kodr — Future Ideas

Ideas and language decisions that are not yet committed. These may make it into the language, get rejected, or evolve into something else.

---

## Missing Core Language Features

### Interfaces / Traits
No polymorphism mechanism exists. Composition works but there is no way to write a function that accepts "anything with a `.draw()` method". This blocks plugins, generic algorithms, and callback-by-type patterns. Every serious language has this — Rust has traits, Go has interfaces, Swift has protocols.

Design options to evaluate:
- `interface Drawable { func draw(self: const &Self) void }` — structural or nominal?
- Anonymous interface satisfaction (Go-style, implicit) vs explicit `impl` (Rust-style)
- Whether interface dispatch is always static (compt) or can be dynamic (vtable)

**Priority: high** — blocks real-world design patterns.

### Iterator Protocol
`for` only works on arrays, slices, and integer ranges. Custom structs cannot be made iterable. No lazy sequences, no generators, no pipeline-style data processing. Also means `Map` and `Set` key-value iteration is not possible today.

Needs a protocol that structs can implement — likely tied to the interfaces design above.
Something like: a struct with `func next(self: var &Self) (null | T)` becomes iterable.

**Priority: high** — blocks usable collections.

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

### String Formatting — DONE
`Format(Types...)` builtin type. `const fmt = Format(i32, String)` then `fmt("{} scored {}", 42, "alice")`.
Returns owned String via `std.fmt.allocPrint`. Default SMP allocator, optional shared allocator.
`{}` placeholders auto-mapped to Zig format specifiers based on declared types.

### Variadic Functions
No `func log(args: ...)` equivalent. Blocks building any API that takes variable numbers of arguments — including making `console.print` accept mixed types natively without overloads.

Likely maps to Zig's `anytype` variadics via the `extern func` bridge, or a `...any` syntax.

**Priority: medium** — needed for ergonomic stdlib APIs.

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

### Remote Package Registry
`#dep` currently only supports local paths. No way to pull a published library by name/version. Needs a registry design and a resolution/download step in the compiler.

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

`#gpu` is reserved for future GPU/concurrency design. Deferred until `Thread`/`Async` semantics are settled.
