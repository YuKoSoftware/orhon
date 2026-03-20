# Concurrency & Threading

> `thread` is implemented. `async` is deferred.

---

## `thread` — CPU Parallelism

Creates a real OS thread. Use for CPU-heavy work.
```
thread(i32) my_thread {
    return heavy_computation()
}

my_thread.value       // blocks until done, returns i32 (move — one call only)
my_thread.finished    // bool, non-blocking
my_thread.wait()      // block without getting value
my_thread.cancel()    // cooperative cancellation — thread checks flag
```

`thread` is a keyword. No import needed.

> `Async` is deferred — will share the same interface but use IO concurrency instead of OS threads. Not designed yet.

---

## Ownership and Threads

Values **move** into threads — no borrows. Using a value after it has been moved into a thread is a compile time error. Ownership returns through `.value`.

```
var data: []i32 = [1, 2, 3]

thread([]i32) my_thread {
    data[0] = 99
    return data
}

// data is moved — using it here is a compile error
var result: []i32 = my_thread.value    // ownership returned (move)
```

### Captures are implicit

The compiler detects which outer variables the thread body references. All referenced variables are moved into the thread automatically — no explicit capture list needed.

### `.value` is a move

Calling `.value` transfers ownership back from the thread. A second `.value` call is a use-after-move error. Store the result in a variable if you need it multiple times.

```
var result: []i32 = worker.value    // ok — ownership moves to result
var again: []i32 = worker.value     // compile error — use-after-move
```

### Unjoined threads are compile errors

Every thread must be consumed before its scope ends — either via `.value` or `.wait()`. A thread that goes out of scope without being joined is a compile error, similar to how unhandled error unions are errors.

```
func bad() void {
    thread(i32) t { return 42 }
}   // compile error — thread 't' not joined before scope exit

func good() void {
    thread(i32) t { return 42 }
    t.wait()    // ok
}
```

---

## Cancellation

Cancellation is cooperative. Calling `.cancel()` sets a flag — the thread body is responsible for checking it. The thread is not killed mid-execution.

```
thread(i32) worker {
    var total: i32 = 0
    for(items) |item| {
        // thread checks cancellation flag internally
        total += process(item)
    }
    return total
}

worker.cancel()     // sets the flag — thread exits at next check point
worker.wait()       // still must join
```

The exact mechanism for checking the flag inside the body is TBD (may be automatic at loop boundaries, or an explicit `thread.cancelled()` check).

---

## Sharing Data Between Threads

No shared mutable state. Data must be explicitly split using `splitAt` — a single atomic operation that consumes the original and produces two non-overlapping pieces. Passing the same owned value to two threads is a compile time error.

```
// atomic split — data consumed, no overlap possible
var left, right = data.splitAt(3)

thread([]i32) thread_a { return left }
thread([]i32) thread_b { return right }
```

`splitAt` works on slices, Lists, and any collection type where splitting is meaningful.

---

## Error Handling in Threads

If the thread body can produce an error, the return type is `(Error | T)`. The error must be handled before scope exit — unhandled errors crash the program.

```
thread((Error | i32)) worker {
    return risky_operation()
}

var result: (Error | i32) = worker.value
match result {
    Error => { console.println("failed") }
    i32   => { console.println("ok") }
}
```

---

## Nested Threads

Threads can spawn other threads. The same ownership and move rules apply at every level.

```
thread(i32) outer {
    thread(i32) inner {
        return compute()
    }
    return inner.value + 1
}

var result: i32 = outer.value
```

---

## Thread Body Restrictions

None. Any function can be called inside a thread body. Safety comes from ownership — not from restricting what code runs. If the data moved in, the thread owns it.

---

## Summary

| Rule | Decision |
|------|----------|
| Data transfer | Moves only — no borrows into threads |
| Captures | Implicit — compiler detects referenced vars |
| `.value` | Move — one call only, second is compile error |
| Unjoined thread | Compile error — must `.value` or `.wait()` |
| Cancellation | Cooperative — flag-based, not forced |
| Error handling | Must handle before scope exit |
| Nested threads | Allowed — same rules apply |
| Body restrictions | None — ownership provides safety |
| Sharing data | `splitAt` — atomic split, original consumed |
