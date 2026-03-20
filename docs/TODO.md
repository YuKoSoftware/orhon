# Kodr — Next Steps

Prioritized list of best next moves as of 2026-03-20.

---

## Open Decisions

### D6. `splitAt()` — atomic slice split
Tied to Thread/Async. Defer until concurrency is designed.

---

## Missing Features

### F3. Pass 8: Thread safety
100-line stub. Blocked on `splitAt` (D6) and concurrency design.
`Thread(T)` and `Async(T)` emit a compiler error.

---

## Done

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
