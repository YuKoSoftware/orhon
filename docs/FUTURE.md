# Kodr — Future Ideas

Ideas and language decisions that are not yet committed. These may make it into the language, get rejected, or evolve into something else.

---

## Missing Core Language Features


### Arbitrary Unions — DONE
Arbitrary unions `(i32 | f32 | String)` generate Zig tagged unions with full codegen support:
type annotation, variable declaration wrapping, return auto-wrapping, assignment wrapping,
`is` type checks, field access (`result.i32`), `match` arm generation, smart tag inference
from union member types (e.g. `int_literal` in `(i64 | String)` → `i64`), and multi-member
unions (3+ types). Covered by runtime tests: return, match, field access, assignment, 3-member.

Propagation pass does not track arbitrary unions — by design, they are not error-bearing.

### String Operations — DONE
Non-allocating: `s.contains()`, `s.startsWith()`, `s.endsWith()`, `s.trim()`, `s.trimLeft()`,
`s.trimRight()`, `s.indexOf()`, `s.lastIndexOf()`, `s.count()`, `s.split()` (destructuring only),
`s.parseInt()`, `s.parseFloat()`.

Allocating (default SMP allocator, optional explicit allocator as last arg):
`s.toUpper()`, `s.toLower()`, `s.replace(old, new)`, `s.repeat(n)`.

Still missing: `join` (needs slice-of-strings), `toString` (needs generic method dispatch on non-string types).

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

## Extended `extern` — DONE

The Zig bridge now supports: `extern func`, `extern const`, `extern var`, `extern struct`.
All use the same re-export pattern from the paired sidecar `.zig` file.
`extern func` with `any` params already maps to `anytype` (used in std::math).

Still not implemented: `extern enum` (low priority — enums can be defined in Kodr directly).

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
