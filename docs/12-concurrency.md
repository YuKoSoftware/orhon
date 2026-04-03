# Concurrency & Threading

> `thread` is implemented. `Atomic(T)` is available via `std::async`. IO-based async/await is deferred.

---

## `thread` — CPU Parallelism

Creates a real OS thread. Use for CPU-heavy work.
```
thread compute(x: i32) Handle(i32) {
    return Handle(heavy_computation(x))
}

const h: Handle(i32) = compute(42)
h.value       // blocks until done, returns i32 (move — one call only)
h.finished    // bool, non-blocking
h.wait()      // block without getting value
h.cancel()    // cooperative cancellation — thread checks flag
```

`thread` is a keyword. Thread functions return `Handle(T)` where `T` is the result type. No import needed.

> IO-based `async` is deferred — will use IO concurrency instead of OS threads. Not designed yet.
>
> For lock-free shared state, `Atomic(T)` is available now via `use std::async`.

---

## Ownership and Threads

Thread functions accept arguments. The compiler enforces safety rules based on how arguments are passed:

| Passing style | Allowed? | Effect on original |
|---|---|---|
| Owned value (`x`) | Yes | **Moved** — variable dead until thread joined |
| Const borrow (`const& x`) | Yes | **Frozen** — read-only until thread joined |
| Mutable borrow (`mut& x`) | **No** | Compile error |

### Owned values move into threads

Passing an owned value to a thread transfers ownership. Using the variable after the thread is spawned is a compile error.

```
thread consumer(data: i32) Handle(i32) {
    return Handle(data)
}

var x: i32 = 42
const h: Handle(i32) = consumer(x)
// x is moved — using it here is a compile error
var result: i32 = h.value    // ownership returned (move)
```

### Const borrows freeze the original

Passing a const borrow (`const& x`) to a thread freezes the original variable — it becomes read-only until the thread is joined via `.value` or `.wait()`. This prevents data races where the caller mutates data while the thread reads it.

```
thread reader(val: const& i32) Handle(void) {
    // can read val, cannot modify it
}

var x: i32 = 10
const h: Handle(void) = reader(mut& x)
x = 20        // compile error — cannot mutate 'x' while it is borrowed by thread
h.wait()      // thread joined — freeze released
x = 20        // ok — x is unfrozen after join
```

### Mutable borrows are forbidden

Passing a mutable borrow (`mut& x`) to a thread is always a compile error. Two things writing to the same data concurrently is a data race — no static analysis can make it safe without synchronization primitives.

```
thread writer(val: mut& i32) Handle(void) { }

var x: i32 = 10
const h: Handle(void) = writer(mut& x)    // compile error — cannot pass mutable borrow to thread
```

### `.value` is a move

Calling `.value` transfers ownership back from the thread. A second `.value` call is a use-after-move error. Store the result in a variable if you need it multiple times.

```
var result: i32 = worker.value    // ok — ownership moves to result
var again: i32 = worker.value     // compile error — use-after-move
```

### Unjoined threads are compile errors

Every thread must be consumed before its scope ends — either via `.value` or `.wait()`. A thread that goes out of scope without being joined is a compile error, similar to how unhandled error unions are errors.

```
func bad() void {
    const h: Handle(i32) = worker(42)
}   // compile error — thread 'h' not joined before scope exit

func good() void {
    const h: Handle(i32) = worker(42)
    h.wait()    // ok
}
```

---

## Cancellation

Cancellation is cooperative. Calling `.cancel()` sets a flag — the thread body is responsible for checking it. The thread is not killed mid-execution.

```
thread process_all(items: []i32) Handle(i32) {
    var total: i32 = 0
    for(items) |item| {
        // thread checks cancellation flag internally
        total += process(item)
    }
    return Handle(total)
}

const h: Handle(i32) = process_all(items)
h.cancel()     // sets the flag — thread exits at next check point
h.wait()       // still must join
```

The exact mechanism for checking the flag inside the body is TBD (may be automatic at loop boundaries, or an explicit `thread.cancelled()` check).

---

## Sharing Data Between Threads

No shared mutable state. Data must be explicitly split using [[06-collections#`@splitAt` — Atomic Slice Split|@splitAt]] — a single atomic operation that consumes the original and produces two non-overlapping pieces. Passing the same owned value to two threads is a compile time error.

```
// atomic split — data consumed, no overlap possible
var left, right = @splitAt(data, 3)

thread process_left(d: []i32) Handle([]i32) { return Handle(d) }
thread process_right(d: []i32) Handle([]i32) { return Handle(d) }

const a: Handle([]i32) = process_left(left)
const b: Handle([]i32) = process_right(right)
```

`@splitAt` works on slices, Lists, and any collection type where splitting is meaningful.

---

## Error Handling in Threads

If the thread body can produce an error, the return type is `ErrorUnion(T)` (see [[08-error-handling]]). The error must be handled before scope exit — unhandled errors crash the program.

```
thread risky_work() Handle(ErrorUnion(i32)) {
    return Handle(risky_operation())
}

var result: ErrorUnion(i32) = risky_work().value
match result {
    Error => { console.println("failed") }
    i32   => { console.println("ok") }
}
```

---

## Nested Threads

Threads can spawn other threads. The same ownership and move rules apply at every level.

```
thread compute() Handle(i32) {
    return Handle(heavy_work())
}

thread orchestrate() Handle(i32) {
    const inner: Handle(i32) = compute()
    return Handle(inner.value + 1)
}

var result: i32 = orchestrate().value
```

---

## Thread Body Restrictions

None. Any function can be called inside a thread body. Safety comes from ownership — not from restricting what code runs. If the data moved in, the thread owns it.

---

## Summary

| Rule | Decision |
|------|----------|
| Owned values | Move into thread — original variable dead until join |
| Const borrows (`const& x`) | Allowed — original frozen (read-only) until join |
| Mutable borrows (`mut& x`) | Forbidden — compile error |
| `.value` | Move — one call only, second is compile error |
| Unjoined thread | Compile error — must `.value` or `.wait()` |
| Cancellation | Cooperative — flag-based, not forced |
| Error handling | Must handle before scope exit |
| Nested threads | Allowed — same rules apply |
| Body restrictions | None — ownership provides safety |
| Sharing data | `@splitAt` — atomic split, original consumed |
