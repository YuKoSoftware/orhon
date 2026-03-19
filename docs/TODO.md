# Kodr — Next Steps

Prioritized list of best next moves as of 2026-03-19.

---

## Open Decisions

### D6. `splitAt()` — atomic slice split
Tied to Thread/Async. Defer until concurrency is designed.

---

## Bugs — valid code produces wrong output

### ~~B1. `match` on ranges~~
Fixed. Range arms now emit `4...8` (Zig inclusive) instead of `4..8`.

### ~~B2. `match` on strings~~
Fixed. String match desugars to `if (std.mem.eql(u8, ...))` / else-if chain.

---

## Missing Features

### ~~F1. `match @type(val)` — type matching~~
Dropped. `@type` removed — use `is` / `is not` for type checking, works at both runtime and compt time.

### ~~F2. `mem.Allocator` as a parameter type~~
Fixed. `parseType` now handles `name.field` scoped types; `typeToZig` maps `mem.Allocator` → `std.mem.Allocator`.

### F3. Pass 8: Thread safety
100-line stub. Blocked on `splitAt` (D6) and concurrency design.
`Thread(T)` and `Async(T)` emit a compiler error.

---

## Missing Validation

### ~~V1. Label name validation~~
Labels removed entirely. `break label` / `continue label` are compiler errors. Use a func + return instead.

### ~~V2. `extern func` visibility~~
`extern func` is always implicitly public — `pub extern func` is now a compiler error (redundant). `pub` dropped from all examples and stdlib.

---

## Edge Cases

### E1. `compt` generics
`any` type works for simple cases. Complex nested generics have untested edge cases.
`compt for` generates `inline for` but compile-time semantics may not fully match.

---

## Done

- `extern func` is always implicitly public — `pub extern func` is a compiler error
- `mem.Allocator` as parameter type — scoped type parsed + mapped to `std.mem.Allocator`
- Overflow helpers — `overflow()`, `wrap()`, `sat()` — codegen + example module
- Extern func sidecar validation — clear error when `.zig` sidecar is missing
- `arr[a..b]` slice expressions — parser + codegen + all passes
- `bitfield` keyword — constructor + `.has()/.set()/.clear()/.toggle()`
- `String` (uppercase) — consistent naming, docs + templates + tests
- `std::console` — print, println, debugPrint, get
- `typeid` — fixed, unique per type via `@intFromPtr(@typeName(T).ptr)`
- Thread/Async — replaced broken codegen with clear "not yet implemented" error
- Spec cleanup — removed auto-deferred free, arr.ptr, Pool/Ring allocators from spec
