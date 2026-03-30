# Memory, Ownership & Allocation

## Memory Model & Ownership

### Core Rules
1. Every value has exactly one owner
2. When the owner goes out of scope, the value is dropped
3. Assignment moves ownership by default for non-primitives
4. You can borrow immutably many times, or mutably once — never both simultaneously
5. All safety checks are compile time only — zero runtime overhead

### Copy vs Move
- **Primitives** (`i32`, `i64`, `u8`, `f64`, `bool`, `usize`, `isize`, `String` etc.) — silently copy on assignment, compiler does not track them. `String` is `[]const u8` under the hood (a pointer + length), so copying is always cheap (16 bytes).
- **`var` non-primitives** (structs, slices, user types) — move by default, compiler tracks ownership
- **`const` non-primitives** — auto-borrowed as `const&` when passed by value. The compiler passes a read-only reference instead of copying. No silent deep copies. Use `copy()` when you actually need a copy.
- `move` for explicit move intent (see [[05-functions#Compiler Functions]])
- `copy` for explicit copies of non-primitives
- For mutable byte manipulation, use `[]u8` (mutable array) — this is a move type

```
var a: i32 = 5
var b: i32 = a            // copy, a still valid, compiler does not track

var s: String = "hello"
var s2: String = s        // copy, s still valid (String is a slice — cheap)

var data: MyStruct = getData()
var d2: MyStruct = data          // move, data is now invalid
var d3: MyStruct = copy(d2)     // explicit copy, d2 still valid
var d4: MyStruct = move(d2)     // explicit move, documents intent

const config: Config = getConfig()
processA(config)        // auto-borrowed as const&, no copy
processB(config)        // still valid — never moved, never copied
var mine: Config = copy(config)  // explicit copy when you need owned data
```

Use-after-move is a compile time error. Zero runtime overhead — moved variables do not exist in the output binary.

### Why `const` Auto-Borrows
`const` means immutable — the value will never change. Since it cannot change, passing it by reference is always safe. The compiler passes `const& T` under the hood, avoiding silent copies of large structs. This is zero-cost and invisible to the user. If you need an actual owned copy, use `copy()` explicitly.

### Borrowing
`mut&` borrows a value mutably, `const&` borrows immutably. Caller retains ownership.
```
var s: String = "hello"
print(mut& s)     // borrow, s still valid
print(mut& s)     // still valid
print(s)          // move, s is gone after this
```

In function signatures:
```
func read(x: const& String) void { }    // immutable borrow, read only
func mutate(x: mut& String) void { }    // mutable borrow, can modify
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
    func getPlayerName(self: const& Game) String { return self.player.name }
    func damagePlayer(self: mut& Game, amount: f32) void {
        self.player.health = self.player.health - amount
    }
}
```

### Lifetimes
No lifetime annotations ever. The language stays simple — complexity lives in `@` compiler functions. Functions cannot return references — only owned values. If you need to return borrowed data, use `copy` to return an owned copy.

Non-lexical lifetimes (NLL) — a borrow ends at the **last use** of the reference variable, not at the end of the block. This accepts more valid programs without sacrificing safety:
```
var data: MyStruct = getData()
const ref: const& MyStruct = const& data    // borrow starts
read(ref)                                    // last use of ref — borrow ends here
mutate(mut& data)                           // OK — borrow already expired
```

### Structs and Ownership
Structs are atomic ownership units — all fields move together or none do.
```
var p: Player = Player(name: "john", score: 0, health: 100.0)
var p2: Player = p      // entire struct moves, p is invalid

var name: mut& String = mut& p2.name    // borrow a field, p2 still owns everything
```
Moving individual fields out of a struct is a compile time error.

---

## Pointers

Traditional `*T` pointer syntax does not exist in Orhon. Instead there are three distinct pointer types, each with a clear purpose. Pointer construction uses the type annotation and `mut&` (address-of) — the type carries the safety level, no extra syntax needed.

### `Ptr(T)` — Safe Pointer, General Use
Compiler tracked. Always `const` — the pointer cannot be reassigned. Points to a single value only — no pointer arithmetic, no `[]` indexing. Must be initialized from a variable address (`mut& x`) — raw integer addresses are not allowed. The ownership pass ensures you cannot use a `Ptr(T)` after the pointee has moved — this is a hard compile-time error. No warnings emitted.

```
var x: i32 = 10
const ptr: Ptr(i32) = mut& x

ptr.value          // read the pointed-to value

var x2: i32 = x   // x moved — compiler error if ptr.value is used after this
```

### `RawPtr(T)` — Unsafe Pointer, No Restrictions
Zero overhead — just a memory address. No compiler tracking, no ownership checks, no bounds checking. `[]` indexing with full pointer arithmetic. Always emits a compiler warning — you are opting out of safety.

```
// from a variable
const raw: RawPtr(i32) = mut& x
raw[0]    // read value, no bounds check

// from a hardware address
const vga: RawPtr(u8) = 0xB8000
vga[0]
vga[5]

// from a C function returning a pointer
const arr: RawPtr(i32) = some_c_function()
arr[n]    // nth element, pointer arithmetic under the hood
```

### `VolatilePtr(T)` — Unsafe Pointer, Hardware Registers
Same as `RawPtr(T)` with one difference: every read and write is volatile — the compiler never caches or optimizes them away. For memory-mapped hardware registers where the value can change outside the program. Always emits a compiler warning.

```
const reg: VolatilePtr(u32) = 0xFF200000
reg[0]         // volatile read
reg[0] = 0x1   // volatile write
reg[1] = 0x2   // volatile write to next register
```

### Pointer Construction
The type annotation determines pointer kind — `mut&` takes the address, integer literals provide hardware addresses:

```
// From a variable — mut& takes the address
const p: Ptr(i32) = mut& x             // safe, const, compiler-tracked
const r: RawPtr(i32) = mut& x          // unsafe, warns
const v: VolatilePtr(u32) = mut& x     // volatile, warns

// From a hardware address — integer literal
const reg: VolatilePtr(u32) = 0xFF200000
const mem: RawPtr(u8) = 0xB8000
```

### Pointer Rules
- `Ptr(T)` — always `const`, safe, no warnings, single value, `mut& variable` only
- `RawPtr(T)` — always warns, no restrictions, full pointer arithmetic, escape hatch
- `VolatilePtr(T)` — always warns, like `RawPtr(T)` but all accesses are volatile, hardware registers only
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
```
import std::allocator

var a: allocator.SMP = allocator.SMP.create()

// single value
var x: i32 = a.allocOne(i32, 42)
var p: Player = a.allocOne(Player, Player.create("hero"))

// slice — multiple values
var data: []i32 = a.alloc(i32, 100)
```

Every heap allocation is tied to an explicit allocator. No hidden allocations ever.

### Freeing Memory
```
a.free(x)       // explicit early free — x is now invalid (ownership move)
a.free(data)    // free slice
```

`a.free(x)` is an ownership move — `x` becomes invalid after the call. Using `x` after freeing is a compile-time error. Heap-allocated values that go out of scope without an explicit free are a memory leak — always call `a.free(x)` explicitly.

Custom allocator *implementation* belongs in Zig via `bridge func` — Orhon code uses allocators but does not build them.

### Built-in Allocators

| Allocator | Speed | Notes |
|-----------|-------|-------|
| `allocator.SMP` | fast | general-purpose, thread-safe — wraps Zig's `GeneralPurposeAllocator` |
| `allocator.Arena` | fast | batch work, free all at once via `freeAll()` |
| `allocator.Page` | varies | OS page-sized chunks, large allocations, stateless |

All allocators follow the same pattern: `Type.create()` to instantiate, `.deinit()` to tear down.

### Arena — Batch Free
```
var arena: allocator.Arena = allocator.Arena.create()
var buf: []u8 = arena.alloc(u8, 4096)
var tmp: []i32 = arena.alloc(i32, 100)
arena.freeAll()    // frees everything at once — all arena values become invalid
arena.deinit()
```

`arena.freeAll()` releases all allocations but retains capacity for reuse. Call `.deinit()` to release the backing memory.

---

## Allocators

Collections (`List`, `Map`, `Set`) accept an optional allocator argument. Three usage modes:

### Mode 1 — Default SMP Allocator (no argument)

Collections use a module-level SMP (`GeneralPurposeAllocator`) by default. No import or setup needed:

```
var items: List(i32) = List(i32).new()    // uses default SMP allocator
items.add(42)
defer { items.free() }
```

### Mode 2 — Inline Allocator

Pass an allocator directly to `.new()`:

```
import std::allocator
var arena: allocator.Arena = allocator.Arena.create()
defer { arena.deinit() }
var items: List(i32) = List(i32).new(arena.allocator())
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
var items: List(i32) = List(i32).new(a)
var counts: Map(String, i32) = Map(String, i32).new(a)
defer { items.free() }
defer { counts.free() }
```

### Available Allocators

| Allocator | Notes |
|-----------|-------|
| `allocator.SMP` | General-purpose, thread-safe (default for collections) |
| `allocator.Arena` | Batch work — `freeAll()` releases all allocations at once |
| `allocator.Page` | OS page-sized chunks, good for large allocations |

All allocators follow the same interface: `Type.create()` to instantiate, `.allocator()` to get the allocator handle, `.deinit()` to tear down.

### Custom Allocators

Custom allocators must be implemented in Zig as bridge sidecars — Orhon code uses allocators but does not build them. See [[14-zig-bridge]] for the bridge pattern.
