# Thread Removal + std::thread Design

## Summary

Remove the `thread` keyword, `Handle(T)` CoreType, `thread_safety.zig` (pass 8), and all
thread-related codegen from the compiler. Replace `src/std/async.zig` with `src/std/thread.zig`
providing `Thread(T)`, `Atomic(T)`, `Mutex`, and a convenience `spawn()` function.

The existing ownership and borrow checkers already enforce thread safety: values passed to
`spawn()` are moved (use-after-move = error), borrows are tracked (conflict = error). The
dedicated thread safety pass is redundant and gets deleted.

**Motivation:** The `thread` keyword requires special grammar, codegen (SharedState + wrapper
generation), and a dedicated 971-line safety pass. All of this can be a library. `Handle(T)` is
the last CoreType variant — removing it eliminates the entire CoreType struct from the compiler.

---

## Compiler Removal

### Files and what gets removed

| File | Removal |
|---|---|
| `src/peg/orhon.peg` | `thread_decl` rule, `'thread'` from top_level_start lookahead and decl choices |
| `src/peg/builder_decls.zig` | `buildThreadDecl()` function, thread dispatch in pub_decl builder |
| `src/parser.zig` | `FuncContext.thread` variant from enum |
| `src/codegen/codegen_decls.zig` | `generateThreadFuncMir()` function (86 lines), `is_thread` dispatch |
| `src/codegen/codegen.zig` | Handle branch in `typeToZig()`, async-related delegation |
| `src/thread_safety.zig` | **Entire file deleted** (971 lines, pass 8) |
| `src/pipeline.zig` (or pipeline_passes) | Thread safety pass invocation, `ASYNC_ZIG` special copy to generated dir |
| `src/builtins.zig` | `"Handle"` from BUILTIN_TYPES, `BT.HANDLE` constant |
| `src/types.zig` | `CoreType` struct entirely, `.core_type` variant from ResolvedType union, `isCoreType()`, `coreInner()` helpers |
| `src/mir/mir_types.zig` | `TypeClass.thread_handle` variant, Handle classification in `classifyType()` |
| `src/mir/mir_annotator.zig` | `.core_type` comparison in `typesMatch()` |
| `src/resolver.zig` | `coreTypeName()` function, core_type compatibility checks in `typesCompatible()` and `typesMatchWithSubstitution()` |
| `src/lsp/lsp_analysis.zig` | `.core_type` branch in `formatType()` |
| `src/cache.zig` | `.core_type` branch in `hashResolvedType()` |
| `src/std/async.zig` | **Entire file replaced** by thread.zig |
| `src/std_bundle.zig` | Replace `ASYNC_ZIG` with `THREAD_ZIG`, update files array |

### What's eliminated

- `CoreType` struct — no more variants, struct deleted entirely
- `.core_type` variant removed from `ResolvedType` union
- `thread` keyword removed from grammar
- Pass 8 (thread safety) removed from pipeline
- `_orhon_async` module no longer generated

### Why thread_safety.zig is redundant

The existing ownership checker (pass 6) and borrow checker (pass 7) already cover thread safety:

- **Owned args:** `spawn(compute, data)` — ownership checker sees `data` as moved. Use after = error.
- **Const borrows:** `spawn(work, const& x)` — borrow checker tracks active borrow. Mutation = error.
- **Mutable borrows:** `spawn(work, mut& x)` — borrow checker enforces single mutable borrow.
- **Join enforcement:** Not enforced. Acceptable trade-off — users are responsible, like with `std::ptr`.
- **Double value consumption:** Not enforced at Orhon level. Zig's type system can handle this.

---

## std::thread Module

### New file: `src/std/thread.zig`

Replaces `src/std/async.zig`. Three structs + one convenience function.

### Thread(T) — spawn and join

```
import std::thread

func compute(x: i32) i32 {
    return x * 2
}

// convenience spawn — infers T from function return type
var t: thread.Thread(i32) = thread.spawn(compute, 42)

// explicit form also works
var t2: thread.Thread(i32) = thread.Thread(i32).spawn(compute, 42)

// join and get result
const result: i32 = t.join()

// non-blocking check
const ready: bool = t.done()

// void thread
func do_work(data: i32) void { }
var t3: thread.Thread(void) = thread.spawn(do_work, 10)
t3.join()
```

**Methods:**
- `.spawn(func, args...)` — static, start a thread, returns `Thread(T)`
- `.join()` → `T` — block until done, return result (void threads return nothing)
- `.done()` → `bool` — non-blocking completion check

**Convenience function:**
- `thread.spawn(func, args...)` — top-level shorthand, infers `T` from function return type

**Zig implementation:** Allocates SharedState (result slot + atomic completion flag) via
page_allocator, wraps user function in a struct with `run()` method that writes result and
sets completion flag, calls `std.Thread.spawn`, returns `Thread(T)` holding the thread
handle and state pointer. `.join()` calls `std.Thread.join()`, reads result, frees state.

### Atomic(T) — lock-free atomic values

```
var counter: thread.Atomic(i32) = thread.Atomic(i32).new(0)
counter.store(5)
const val: i32 = counter.load()
counter.fetchAdd(1)
counter.fetchSub(1)
const prev: i32 = counter.exchange(10)
```

**Methods:** `.new(initial)`, `.load()`, `.store(val)`, `.exchange(val)`, `.fetchAdd(val)`, `.fetchSub(val)`

All operations use sequential consistency (`.seq_cst`). Same as current `async.zig` Atomic.

### Mutex — mutual exclusion

```
var lock: thread.Mutex = thread.Mutex.new()
lock.lock()
// critical section
lock.unlock()
```

**Methods:** `.new()`, `.lock()`, `.unlock()`

Thin wrapper over `std.Thread.Mutex`.

---

## Pipeline Changes

- Remove thread safety pass (pass 8) invocation from pipeline
- Remove `ASYNC_ZIG` special copy to `.orh-cache/generated/_orhon_async.zig`
- The auto-discovered `thread.zig` in `.orh-cache/std/` becomes available as `import std::thread`
  through the normal zig-module conversion pipeline — no special handling needed

---

## Test Updates

| File | Change |
|---|---|
| `test/fixtures/tester.orh` | Rewrite 6 thread functions: remove `thread` keyword declarations, use normal `func` + `thread.spawn()`. Replace `Handle(T)` with `thread.Thread(T)`. Replace `.value()` with `.join()`. Replace `.wait()` with `.join()`. |
| `test/fixtures/tester_main.orh` | Update thread test call patterns if needed |
| `test/10_runtime.sh` | Keep thread/atomic test entries (names stay same) |
| `test/11_errors.sh` | Remove thread-specific error tests: unjoined thread, move-into-thread, frozen var mutation, mutable borrow to thread — these relied on pass 8 which is deleted |
| `test/fixtures/fail_*.orh` | Delete thread-specific failure fixtures |

---

## Documentation Updates

| File | Change |
|---|---|
| `src/templates/example/advanced.orh` | Rewrite thread examples with `import std::thread` API |
| `docs/TODO.md` | Mark thread codegen simplification as done |

---

## Design Decisions

1. **No `thread` keyword** — any function can be spawned. No special declaration needed.
   Convention over syntax, like Zig/Rust/Go.
2. **CoreType deleted entirely** — Handle was the last variant. ResolvedType union simplified.
3. **thread_safety.zig deleted** — ownership + borrow checkers already enforce the important rules.
   Join enforcement is an acceptable loss.
4. **`async.zig` replaced, not extended** — "async" is misleading (it's OS threads, not async/await).
   `thread.zig` is accurate.
5. **Convenience `thread.spawn()`** — avoids verbose `thread.Thread(i32).spawn()`. Zig comptime
   infers T from the function's return type.
6. **Mutex added** — basic synchronization primitive. Completing the threading toolkit alongside
   Thread and Atomic.
