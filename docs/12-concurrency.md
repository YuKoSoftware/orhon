# Concurrency & Threading

> Threading is available via `import std::thread`. The library provides `Thread(T)`, `Atomic(T)`, and `Mutex`.

---

## `std::thread` — CPU Parallelism

Import the threading module:
```
import std::thread
```

### Thread(T)

`Thread(T)` spawns an OS thread. `T` is the join return type.

```
func doubler(x: i32) i32 {
    return x * 2
}

var t: thread.Thread(i32) = thread.Thread(i32).spawn(doubler, 21)
const result: i32 = t.join()    // blocks, returns 42
```

Methods:
| Method | Description |
|--------|-------------|
| `spawn(f, arg)` | Spawn a thread running `f(arg)`. Returns `Thread(T)`. |
| `spawn2(f, arg1, arg2)` | Spawn a thread running `f(arg1, arg2)`. Returns `Thread(T)`. |
| `join()` | Block until thread completes, return result of type `T`. |
| `done()` | Non-blocking check — returns `bool`. |

For void-returning threads, use `Thread(void)`:
```
func worker(x: i32) void {
    // do work
}

var t: thread.Thread(void) = thread.Thread(void).spawn(worker, 42)
t.join()
```

For two arguments, use `spawn2` directly or pack them into a struct:
```
struct Args {
    pub a: i32
    pub b: i32
}

func adder(args: Args) i32 {
    return args.a + args.b
}

var t: thread.Thread(i32) = thread.Thread(i32).spawn(adder, Args{a: 17, b: 25})
const result: i32 = t.join()
```

### Atomic(T)

Lock-free atomic operations over type `T`. Uses sequential consistency.

```
var counter: thread.Atomic(i32) = thread.Atomic(i32).new(0)
counter.store(10)
const val: i32 = counter.load()
const prev: i32 = counter.fetchAdd(1)
```

Methods:
| Method | Description |
|--------|-------------|
| `new(initial)` | Create atomic with initial value. |
| `load()` | Atomically read the current value. |
| `store(val)` | Atomically write a new value. |
| `exchange(val)` | Swap and return the previous value. |
| `fetchAdd(val)` | Add and return the previous value. |
| `fetchSub(val)` | Subtract and return the previous value. |

### Mutex

Mutual exclusion lock for protecting shared state.

```
var mu: thread.Mutex = thread.Mutex.new()
mu.lock()
// critical section
mu.unlock()
```

Methods:
| Method | Description |
|--------|-------------|
| `new()` | Create a new unlocked mutex. |
| `lock()` | Acquire the lock. Blocks if held. |
| `unlock()` | Release the lock. |

---

## Limitations

- **Spawn arity** — `spawn(f, arg)` takes one argument; `spawn2(f, arg1, arg2)` takes two. For zero args, the function must accept a dummy parameter. For three or more args, pack into a struct.
- **No ownership enforcement** — the compiler does not currently track ownership across thread boundaries. The programmer must ensure thread safety manually using `Atomic(T)` and `Mutex`.
- **No unjoined-thread detection** — forgetting to call `join()` leaks the thread's shared state.

---

## Planned: `thread` Keyword

A language-level `thread` keyword is planned for a future version. It would provide compiler-enforced safety:

- Owned values move into threads — original variable dead until join
- Const borrows freeze the original (read-only until join)
- Mutable borrows forbidden (compile error)
- `.value` as a move — second call is use-after-move error
- Unjoined threads are compile errors
- Cooperative cancellation

This is **not implemented**. The current `std::thread` library is the working API.

> IO-based `async` is also deferred — see [[future]].
