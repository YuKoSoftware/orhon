# Collections

## Arrays and Slices

```
[]T      // slice — dynamic length
[n]T     // fixed size array — size known at compile time
```

Both have the following fields:
```
arr.len    // number of elements — compt for [n]T, runtime for []T
arr[i]     // index access, bounds checked, compile time error if out of range
arr.ptr    // RawPtr(T), for bare metal / Zig bridge use — always emits a compiler warning
```

### Array Literals
```
// fixed array — size must match literal count exactly
var arr: [3]i32 = [1, 2, 3]
var arr: [5]f32 = [1.0, 2.0, 3.0, 4.0, 5.0]

// empty fixed array — zero initialized
var arr: [10]i32 = []

// slice — dynamic, built from literal
var arr: []i32 = [1, 2, 3, 4, 5]
```

Higher level collections (map, set, queue, stack, list) live in `std.collections`. Can be promoted to keywords later if clearly necessary.

---

## `splitAt` — Atomic Slice Split

Splits a slice into two non-overlapping owned halves in a single atomic operation. The original slice is consumed — invalid after split. Used for safely sharing data between threads.

```
var data: []i32 = [1, 2, 3, 4, 5, 6]
var left, right = data.splitAt(3)    // left=[1,2,3], right=[4,5,6]
// data is now invalid
```

Hard compiler error if split index is out of range.
