# Concurrency & Threading

## `Thread` — CPU Parallelism

Creates a real OS thread. Use for CPU-heavy work.
```
Thread(i32) my_thread {
    return result
}

my_thread.value       // blocks until done, returns i32
my_thread.finished    // bool, non-blocking
my_thread.wait()      // block without getting value
my_thread.cancel()    // cancel the thread
```

## `Async` — IO Concurrency

OS parks and wakes on IO completion. Use for network, file, database operations.
```
Async(string) my_request {
    return fetch(url)
}

my_request.value      // blocks until done, returns string
my_request.finished   // bool
my_request.wait()
my_request.cancel()
```

`Thread` and `Async` are compiler builtin types. No import needed. Same interface, different OS scheduling behavior.

---

## Ownership and Threads

Values move into threads — using a value after it has been moved into a thread is a compile time error. Ownership returns through `.value`.

```
var data: []i32 = [1, 2, 3]

Thread([]i32) my_thread {
    return data
}

var data: []i32 = my_thread.value    // ownership returned
```

## Sharing Data Between Threads

Data must be explicitly split using `splitAt` — a single atomic operation that consumes the original and produces two non-overlapping slices. Passing the same owned value to two threads is a compile time error.

```
// atomic split — data consumed, no overlap possible
var left, right = data.splitAt(3)

Thread([]i32) thread_a { return left }
Thread([]i32) thread_b { return right }
```
