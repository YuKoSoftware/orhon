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
arr[a..b]  // slice of arr from index a up to (not including) b — returns []T
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

---

## `@splitAt` — Atomic Slice Split

Splits a slice into two non-overlapping owned halves in a single atomic operation. The original slice is consumed — invalid after split. Used for safely sharing data between [[12-concurrency|threads]].

```
var data: []i32 = [1, 2, 3, 4, 5, 6]
var left, right = @splitAt(data, 3)    // left=[1,2,3], right=[4,5,6]
// data is now invalid
```

Hard compiler error if split index is out of range.

---

## Collection Types (stdlib)

`List(T)`, `Map(K, V)`, and `Set(T)` are generic collection types in `std::collections`. They are **not** builtin types — they require an explicit [[11-modules#Import Syntax|import]] like any other module.

```
use std::collections

var items: List(i32) = List(i32).new()
items.add(42)

var table: Map(str, i32) = Map(str, i32).new()
table.put("key", 1)

var unique: Set(str) = Set(str).new()
unique.add("hello")
```

With namespaced import:
```
import std::collections

var items: collections.List(i32) = collections.List(i32).new()
```

### Collection Methods

| Type | Methods |
|------|---------|
| `List(T)` | `add(item)`, `get(index)`, `set(index, item)`, `remove(index)`, `pop()`, `len()`, `items()`, `free()` |
| `Map(K, V)` | `put(key, value)`, `get(key)`, `has(key)`, `remove(key)`, `keys()`, `values()`, `len()`, `free()` |
| `Set(T)` | `add(item)`, `has(item)`, `remove(item)`, `items()`, `len()`, `free()` |

All collections support optional allocator arguments — see [[09-memory#Allocators]] for the three allocation modes.
