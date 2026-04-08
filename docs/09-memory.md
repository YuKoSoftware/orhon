# Memory, Ownership & Allocation

## Memory Model & Ownership

### Core Rules
1. Every value has exactly one owner
2. When the owner goes out of scope, the value is dropped
3. Assignment moves ownership by default for non-primitives
4. You can borrow immutably many times, or mutably once — never both simultaneously
5. All safety checks are compile time only — zero runtime overhead

### Copy vs Move
- **Primitives** (`i32`, `i64`, `u8`, `f64`, `bool`, `usize`, `isize`, `str` etc.) — silently copy on assignment, compiler does not track them. `str` is `[]const u8` under the hood (a pointer + length), so copying is always cheap (16 bytes).
- **`var` non-primitives** (structs, slices, user types) — move by default, compiler tracks ownership
- **`const` non-primitives** — passed by value (copied). Use `const&` in function parameters to pass by reference for large types. Use `@copy()` for explicit deep copies.
- `@move` for explicit move intent (see [[05-functions#Compiler Functions]])
- `@copy` for explicit copies of non-primitives
- For mutable byte manipulation, use `[]u8` (mutable array) — this is a move type

```
var a: i32 = 5
var b: i32 = a            // copy, a still valid, compiler does not track

var s: str = "hello"
var s2: str = s        // copy, s still valid (str is a slice — cheap)

var data: MyStruct = getData()
var d2: MyStruct = data          // move, data is now invalid
var d3: MyStruct = @copy(d2)     // explicit copy, d2 still valid
var d4: MyStruct = @move(d2)     // explicit move, documents intent

const config: Config = getConfig()
processA(config)        // passed by value (copied)
processB(config)        // still valid — const, never moved
var mine: Config = @copy(config)  // explicit copy when you need owned data

// Use const& for large types to avoid copies:
func processLarge(data: const& LargeStruct) void { ... }
```

Use-after-move is a compile time error. Zero runtime overhead — moved variables do not exist in the output binary.

### Why `const` Auto-Borrows
`const` means immutable — the value will never change. Since it cannot change, passing it by reference is always safe. The compiler passes `const& T` under the hood, avoiding silent copies of large structs. This is zero-cost and invisible to the user. If you need an actual owned copy, use `@copy()` explicitly.

### Borrowing
`mut&` borrows a value mutably, `const&` borrows immutably. Caller retains ownership.
```
var s: str = "hello"
print(mut& s)     // borrow, s still valid
print(mut& s)     // still valid
print(s)          // move, s is gone after this
```

In function signatures:
```
func read(x: const& str) void { }    // immutable borrow, read only
func mutate(x: mut& str) void { }    // mutable borrow, can modify
```

### Borrow Rules
- `mut& T` — mutable borrow, only one at a time
- `const& T` — immutable borrow, many allowed simultaneously
- Cannot have immutable and mutable borrow simultaneously — compile time error
- Functions can never return references, only owned values
- If you need to return borrowed data, use `copy` to return an owned copy
- Instead of getters that return references, provide methods that do the work inside the struct:
```
struct Game {
    player: Player

    // Don't return references — provide methods instead:
    func getPlayerName(self: const& Game) str { return self.player.name }
    func damagePlayer(self: mut& Game, amount: f32) void {
        self.player.health = self.player.health - amount
    }
}
```

### Lifetimes
No lifetime annotations ever. The language stays simple — complexity lives in `@` compiler functions. Functions cannot return references — only owned values. If you need to return borrowed data, use `copy` to return an owned copy.

Non-lexical lifetimes (NLL) — a borrow ends at the **last use** of the reference, not at the end of the block. This accepts more valid programs without sacrificing safety:
```
var data: MyStruct = getData()
read(const& data)                           // immutable borrow — expires after call
mutate(mut& data)                           // OK — previous borrow already expired
```

Reference types (`const& T`, `mut& T`) are only valid in function parameters — they cannot appear in variable declarations. Borrows are always expression-level.

### Structs and Ownership
Structs are atomic ownership units — all fields move together or none do.
```
var p = Player{name: "john", score: 0, health: 100.0}
var p2: Player = p      // entire struct moves, p is invalid

modify(mut& p2.name)                 // borrow a field, p2 still owns everything
```
Moving individual fields out of a struct is a compile time error.

---

## Pointers

Orhon does not have pointer types as language builtins. The borrow system (`const&` / `mut&`) handles safe reference passing — this covers the vast majority of use cases.

For explicit pointer control (FFI, hardware access, pointer arithmetic), use `std::ptr`:

```
import std::ptr

var x: i32 = 10
var p: ptr.Ptr(i32) = ptr.Ptr(i32).new(mut& x)
const val: i32 = p.read()
p.write(42)
```

See `src/std/ptr.zig` for the full API.

### Pointer Rules
- Use borrows (`const&` / `mut&`) for passing references — this is the normal path
- Use `std::ptr` only when you need to hold an address explicitly
- `Ptr(T)` — safe single-value pointer, constructed from borrows only
- `RawPtr(T)` — unsafe, indexable, allows integer addresses (FFI/hardware)
- `VolatilePtr(T)` — unsafe, volatile reads/writes (hardware registers)
- Self-referential structures use array indices instead of pointers — faster and safer

---

## Memory Allocation

### Stack Allocation — Automatic, No Allocator Needed
```
var x: i32 = 5                                         // primitive, on the stack
var arr: [10]i32 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]   // fixed array, on the stack
// both dropped automatically when scope ends
```

### Heap Allocation — Requires an Explicit Allocator

Orhon allocators provide a uniform interface: `Type.create()` to instantiate, `.allocator()` to get the underlying Zig `std.mem.Allocator` handle. Heap allocation happens through that handle, not directly on the allocator struct.

```
import std::allocator

var smp: allocator.SMP = allocator.SMP.create()
defer { smp.deinit() }
```

Every heap allocation is tied to an explicit allocator. No hidden allocations ever. Custom allocator *implementation* belongs in Zig modules — Orhon code uses allocators but does not build them.

### Built-in Allocators

| Allocator | Speed | Notes |
|-----------|-------|-------|
| `allocator.SMP` | fast | general-purpose, thread-safe — wraps Zig's `smp_allocator` (lock-free, pooled) |
| `allocator.Arena` | fast | batch work, free all at once via `freeAll()` |
| `allocator.Page` | varies | OS page-sized chunks, large allocations, stateless |
| `allocator.Fixed` | fast | allocates from a caller-provided buffer, no OS calls |
| `allocator.Debug` | slow | leak-detecting allocator for development and testing |

`SMP`, `Arena`, and `Debug` have `.deinit()` to tear down. `Page` and `Fixed` are stateless — no `.deinit()` needed (`Fixed` has `.reset()` to reuse the buffer).

### Arena — Batch Free
```
var arena: allocator.Arena = allocator.Arena.create()
defer { arena.deinit() }
// ... allocate via arena.allocator() ...
arena.freeAll()    // frees everything at once — all arena values become invalid
```

`arena.freeAll()` releases all allocations but retains capacity for reuse. Call `.deinit()` to release the backing memory.

---

## Allocators

Collections (`List`, `Map`, `Set`) accept an optional allocator argument. Three usage modes:

### Mode 1 — Default SMP Allocator (no argument)

Collections use the global SMP allocator by default. No import or setup needed:

```
var items: List(i32) = List(i32).new()    // uses default SMP allocator
items.add(42)
defer { items.free() }
```

### Mode 2 — Inline Allocator

Pass an allocator directly to `.withAlloc()`:

```
import std::allocator
var arena: allocator.Arena = allocator.Arena.create()
defer { arena.deinit() }
var items: List(i32) = List(i32).withAlloc(arena.allocator())
items.add(42)
```

The arena owns all memory allocated by `items`. Calling `arena.deinit()` releases everything at once — no need to call `items.free()` separately.

### Mode 3 — External Allocator Variable

Store the allocator interface in a variable for reuse across multiple collections:

```
import std::allocator
var smp: allocator.SMP = allocator.SMP.create()
defer { smp.deinit() }
var a = smp.allocator()
var items: List(i32) = List(i32).withAlloc(a)
var counts: Map(str, i32) = Map(str, i32).withAlloc(a)
defer { items.free() }
defer { counts.free() }
```

### Available Allocators

| Allocator | Notes |
|-----------|-------|
| `allocator.SMP` | General-purpose, thread-safe — default for collections |
| `allocator.Arena` | Batch work — `freeAll()` releases all allocations at once |
| `allocator.Page` | OS page-sized chunks, good for large allocations |
| `allocator.Fixed` | Fixed-buffer allocator, no OS calls — use `.reset()` to reuse |
| `allocator.Debug` | Leak-detecting allocator for development and testing |

All allocators follow the same interface: `Type.create()` to instantiate, `.allocator()` to get the allocator handle, `.deinit()` to tear down (where applicable).

### Custom Allocators

Custom allocators must be implemented in Zig modules — Orhon code uses allocators but does not build them. See [[14-zig-bridge]] for the zig-as-module system.
