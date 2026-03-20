# Kodr — Next Steps

Prioritized list of best next moves as of 2026-03-20.

---

## Missing Features

### F5. Pass 8: Thread safety + `Thread(T)` implementation
Concurrency design is finalized (see `docs/12-concurrency.md`). Implementation needed:
1. Parse `Thread(T) name { body }` syntax
2. Codegen to `std.Thread.spawn` + wrapper struct
3. Pass 8 — enforce moved captures not used after thread spawn, unjoined threads are errors
4. `.value` (move), `.finished`, `.wait()`, `.cancel()` (cooperative)
5. `splitAt` for safe data sharing across threads

### F6. `splitAt()` — atomic split
Design settled: consumes the original, produces two non-overlapping pieces.
Works on slices, Lists, and any collection where splitting is meaningful.
Implement alongside Thread.

### F4. Intra-project library linking
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

## Done

- Map/Set iteration — `for(map) |(key, value)|`, `for(set) |key|`, optional index as last capture, removed `0..` counter syntax
- `#dep "path" Version?` — external dependency support: scan dep dirs, parse modules, version check (error if older, warn if newer)
- `#key = value` metadata syntax — replaced old `main.field = value` with `#` prefix throughout compiler + docs
- Warning infrastructure — `reporter.warn()`, `hasWarnings()`, warnings printed before errors with `WARNING:` prefix + source location + summary line
- `var` → `const` promotion + Kodr warning — unmutated vars: warning fired at Kodr level, emitted as `const` in Zig; method-call receivers correctly excluded
- `extern func` is always implicitly public — `pub extern func` is a compiler error
- `mem.Allocator` as parameter type — scoped type parsed + mapped to `std.mem.Allocator`
- `compt` generics — `any` params/returns, `is`/`is not` type checks, `return struct { ... }` type generation
- `compt` restricted to `compt func` only — `compt var` and `compt for` are now compiler errors
- Overflow helpers — `overflow()`, `wrap()`, `sat()` — codegen + example module
- Extern func sidecar validation — clear error when `.zig` sidecar is missing
- `arr[a..b]` slice expressions — parser + codegen + all passes
- `bitfield` keyword — constructor + `.has()/.set()/.clear()/.toggle()`
- `String` (uppercase) — consistent naming, docs + templates + tests
- `std::console` — print, println, debugPrint, get
- `typeid` — fixed, unique per type via `@intFromPtr(@typeName(T).ptr)`
- Thread/Async — replaced broken codegen with clear "not yet implemented" error
- Spec cleanup — removed auto-deferred free, arr.ptr, Pool/Ring allocators from spec
- `match` on ranges — range arms emit `4...8` (Zig inclusive)
- `match` on strings — desugars to `if (std.mem.eql(u8, ...))` / else-if chain
- `match @type(val)` — dropped; use `is` / `is not` for type checking
- Labels removed — `break label` / `continue label` are compiler errors
- `extern func` visibility — always implicitly public, `pub extern func` is an error
- `GPA` renamed to `DebugAllocator` — matches Zig 0.15 naming
- `List(T)`, `Map(K,V)`, `Set(T)` — builtin collection types, registered in builtins.zig
- Zig 0.15 codegen updates — unmanaged ArrayList/HashMap, `smp_allocator` as default
