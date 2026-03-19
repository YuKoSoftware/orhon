# Kodr — Next Steps

Prioritized list of best next moves as of 2026-03-19.

---

## Decisions Needed — Spec vs Implementation Mismatches

These must be resolved before implementing anything that depends on them.
Each item has a doc that says one thing and code that does another (or nothing).

---

### D1. Bitfield enum representation — fundamental mismatch

**Doc says** (`docs/10-structs-enums.md`):
Bitfield enums use bitwise operators on the backing integer:
```
var p: Permissions = Read | Write    // bitwise OR on u32
p.set(Execute)                       // bitwise OR
p.clear(Write)                       // bitwise AND NOT
p.toggle(Read)                       // bitwise XOR
```
Variants get powers of 2 automatically (Read=0b0001, Write=0b0010, etc.).

**Code does** (`src/codegen.zig` lines 417–447):
Generates a `packed struct` with `bool` fields — not integer flags. `.has()` works,
but `|`, `&`, `^` operators on a packed struct bool won't match the doc's intent.
`.set()`, `.clear()`, `.toggle()` are not generated at all.

**Decision needed:** Pick one model:
- A) Integer flags (`u32` with `|`, `&`, `^` — fix codegen to use a Zig enum with `@intFromEnum`)
- B) Packed struct bools (keep codegen, update doc to drop `|`/`&`/`^` and use only methods)

---

### D2. Thread/Async wrapper types — codegen emits undefined types

**Doc says** (`docs/12-concurrency.md`):
```
my_thread.value       // blocks until done, returns T
my_thread.finished    // bool, non-blocking
my_thread.wait()      // block without getting value
my_thread.cancel()    // cancel the thread
```

**Code does** (`src/codegen.zig` lines 997, 1002, 1473, 1478):
Emits `KodrThread(T)` and `KodrAsync(T)` — types that don't exist anywhere.
The generated Zig will fail to compile if any Thread or Async block is used.

**Decision needed:** Either:
- A) Stub out in docs — mark Thread/Async as "planned, not yet implemented", remove from spec
- B) Define `KodrThread(T)` / `KodrAsync(T)` in a runtime support file and implement the properties

---

### D3. Heap auto-deferred free — spec promise not implemented

**Doc says** (`docs/09-memory.md` line 166):
> If a heap-allocated value goes out of scope without an explicit free, the compiler
> inserts a deferred free automatically — no leaks, no manual cleanup needed in the common case.

**Code does:** Nothing. There is no ownership tracking of allocator-associated variables,
no codegen pass that inserts `defer alloc.destroy(x)` or `defer alloc.free(x)`.

**Decision needed:** Either:
- A) Implement it — pass 6 (ownership) tracks which vars came from an allocator, codegen emits `defer`
- B) Remove the guarantee from the spec — programmer must always call `a.free(x)` explicitly

---

### D4. `arr.ptr` field — type mismatch

**Doc says** (`docs/06-collections.md` line 14):
```
arr.ptr    // RawPtr(T), for bare metal / Zig bridge use — always emits a compiler warning
```

**Code does:** Nothing special — `.ptr` just passes through to Zig's `arr.ptr` which gives `[*]T`,
not a `RawPtr(T)`. No warning is emitted. The type in generated code is wrong.

**Decision needed:** Either:
- A) Generate a wrapper: `arr.ptr` → `RawPtr(T, @intFromPtr(arr.ptr))` with a warning
- B) Remove `.ptr` from the spec — it's an escape hatch that's not worth the complexity now

---

### D5. mem.Pool, mem.Ring, mem.OverwriteRing — in spec, not in codegen

**Doc says** (`docs/09-memory.md`): Seven allocator types exist.

**Code does** (`src/codegen.zig` lines 12–13):
Only four are implemented: `gpa`, `arena`, `temp`, `page`.
`Pool(T)`, `Ring(T, n)`, `OverwriteRing(T, n)` are completely absent from codegen.

**Decision needed:** Either:
- A) Implement them now (codegen maps to Zig's MemoryPool, RingBuffer, etc.)
- B) Move Pool/Ring/OverwriteRing to `docs/FUTURE.md` until stdlib phase

---

### D6. slice.splitAt() — in spec, not implemented

**Doc says** (`docs/06-collections.md` lines 34–44):
```
var left, right = data.splitAt(3)    // atomic split, data consumed after
```

**Code does:** Nothing — no parser rule, no codegen path for `.splitAt()`.

**Decision needed:** Either:
- A) Implement it — parser recognizes `.splitAt(n)`, codegen emits slice splits
- B) Keep in spec but explicitly mark as "not yet implemented"

Note: `splitAt` is also the mechanism for safely sharing data between threads (D2).
Both should be resolved together.

---

### D7. main.deps and main.gpu — in spec examples, never parsed

**Doc shows** (`docs/11-modules.md` lines 199–203):
```
main.deps = [
    Dependency("https://github.com/user/lib", Preferred(Version(2, 4, 1)))
]
main.gpu = gpu.unified.auto
```

**Code does:** These fields are recognized by the parser (in `BUILD_FIELDS`), not rejected,
but nothing is ever done with them — no codegen, no validation, no output.

**Decision needed:** Move `main.deps` and `main.gpu` to `docs/FUTURE.md` and remove
from spec examples, OR add a "future" note in the docs so they're not mistaken for
working features.

---

### ~~D9. `@typeid` — generates undefined function, broken codegen~~ ✓ DONE

Resolved: `kodrTypeId` now emitted in the runtime preamble when `@typeid` is used.
Uses unique-per-comptime-instantiation static address pattern.

---

### ~~D8. console in doc examples — shown without import~~ ✓ DONE

Resolved: `std::console` is now a real stdlib module. Doc examples that use
`console.print()` / `console.println()` need `import std::console` added at the
top, OR the examples can be left as-is (they show concepts, not complete programs).
Pending: audit each doc file and add the import where missing.

---

## Implementation Items

These are clear gaps with no design ambiguity — just need to be built.
Resolve relevant decisions above before starting.

---

## 1. Slice operations — `arr[a..b]`
Only index access `arr[i]` works. Slice syntax is unimplemented.
~100 lines in parser + codegen.

## 2. Bitfield enum methods — `.set()`, `.clear()`, `.toggle()`
`.has()` is generated. The other three methods are missing.
Blocked on D1 — representation must be decided first.
~30 lines codegen once D1 is resolved.

## 3. Overflow helpers — `overflow()`, `wrap()`, `sat()`
Documented in `docs/04-operators.md`, not in parser or codegen at all.
~20 lines parser + ~50 lines codegen mapping to Zig builtins.

## 4. Pass 8: Thread safety
Currently a 100-line stub. Blocked on D2 and D6.
`Thread(T)` and `Async(T)` codegen currently emits undefined types.

## 5. Tighten `compt` generics
The `any` type works in simple cases but complex nested generics have untested
edge cases. `compt for` generates `inline for` but compile-time semantics may
not fully match.

## 6. Extern func sidecar validation
Missing `.zig` sidecars produce cryptic Zig errors instead of clear Kodr errors.
Add a focused error check pass.
