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
- **Everything else** (structs, slices, user types) — move by default, compiler tracks ownership
- `move` for explicit move intent
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
```

Use-after-move is a compile time error. Zero runtime overhead — moved variables do not exist in the output binary.

### Borrowing
`&` borrows a value without transferring ownership. Caller retains ownership.
```
var s: String = "hello"
print(&s)     // borrow, s still valid
print(&s)     // still valid
print(s)      // move, s is gone after this
```

In function signatures:
```
func read(x: const &String) void { }    // immutable borrow, read only
func mutate(x: &String) void { }        // mutable borrow, can modify
```

### Borrow Rules
- `&T` — mutable borrow, only one at a time (`var &T` is the explicit form, same thing)
- `const &T` — immutable borrow, many allowed simultaneously
- Cannot have immutable and mutable borrow simultaneously — compile time error
- Functions can never return references, only owned values
- If you need to return borrowed data, use `copy` to return an owned copy
- Instead of getters that return references, provide methods that do the work inside the struct:
```
struct Game {
    player: Player

    // Don't return &Player — provide methods instead:
    func getPlayerName(self: const &Game) String { return self.player.name }
    func damagePlayer(self: &Game, amount: f32) void {
        self.player.health = self.player.health - amount
    }
}
```

### Lifetimes
No lifetime annotations ever. The language stays simple — complexity lives in `@` compiler functions. Functions cannot return references — only owned values. If you need to return borrowed data, use `copy` to return an owned copy. Lexical lifetimes only — a borrow is valid only within the block it was created in.

### Structs and Ownership
Structs are atomic ownership units — all fields move together or none do.
```
var p: Player = Player(name: "john", score: 0, health: 100.0)
var p2: Player = p      // entire struct moves, p is invalid

var name: &String = &p2.name    // borrow a field, p2 still owns everything
```
Moving individual fields out of a struct is a compile time error.

---

## Pointers

Traditional `*T` pointer syntax does not exist in Kodr. Instead there are three distinct pointer types, each with a clear purpose. All follow the same `Type(T, value)` instantiation pattern used everywhere in Kodr.

### `Ptr(T)` — Safe Pointer, General Use
Compiler tracked. Always `const` — the pointer cannot be reassigned. Points to a single value only — no pointer arithmetic, no `[]` indexing. Must be initialized from a variable address (`&x`) — raw integer addresses are not allowed. The ownership pass ensures you cannot use a `Ptr(T)` after the pointee has moved — this is a hard compile-time error. No warnings emitted.

```
var x: i32 = 10
const ptr: Ptr(i32) = Ptr(i32, &x)

ptr.value          // read the pointed-to value

var x2: i32 = x   // x moved — compiler error if ptr.value is used after this
```

### `RawPtr(T)` — Unsafe Pointer, No Restrictions
Zero overhead — just a memory address. No compiler tracking, no ownership checks, no bounds checking. Accepts `&variable` or a raw integer address. `[]` indexing with full pointer arithmetic. Always emits a compiler warning — you are opting out of safety.

```
// from a variable
const raw: RawPtr(i32) = RawPtr(i32, &x)
raw[0]    // read value, no bounds check

// from a hardware address
const vga: RawPtr(u8) = RawPtr(u8, 0xB8000)
vga[0]
vga[5]

// from a C function returning a pointer
const arr: RawPtr(i32) = some_c_function()
arr[n]    // nth element, pointer arithmetic under the hood
```

### `VolatilePtr(T)` — Unsafe Pointer, Hardware Registers
Same as `RawPtr(T)` with one difference: every read and write is volatile — the compiler never caches or optimizes them away. For memory-mapped hardware registers where the value can change outside the program. Always emits a compiler warning.

```
const reg: VolatilePtr(u32) = VolatilePtr(u32, 0xFF200000)
reg[0]         // volatile read
reg[0] = 0x1   // volatile write
reg[1] = 0x2   // volatile write to next register
```

### Pointer Rules
- `Ptr(T)` — always `const`, safe, no warnings, single value, `&variable` only
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
var a = mem.DebugAllocator()

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

### Passing Allocators Around
```
// mem.Allocator is the interface type — accepts any allocator
func process(a: mem.Allocator, n: i32) []i32 {
    var buf: []i32 = a.alloc(i32, n)
    return buf    // caller owns buf, caller is responsible for freeing
}

var a = mem.DebugAllocator()
var result: []i32 = process(a, 100)
// ... use result ...
a.free(result)
```

Returning a heap-allocated value without also returning or passing the allocator is a compiler warning — the caller needs to know which allocator to free with.

Custom allocator *implementation* belongs in Zig via `extern func` — Kodr code uses allocators but does not build them.

### Built-in Allocators

| Allocator | Speed | Notes |
|-----------|-------|-------|
| `mem.SMP()` | fastest | default for release builds — per-thread freelist, zero setup, global singleton |
| `mem.DebugAllocator()` | safe | debug builds — leak detection, double-free checks, general purpose |
| `mem.Arena()` | fast | batch work, free all at once via `freeAll()` |
| `mem.Page()` | varies | OS page-sized chunks, large allocations, bypasses heap |
| `mem.Stack(n)` | fastest | stack-backed scratch, no heap, auto-reset at scope exit — `n` must be a compile-time constant |

### Arena — Batch Free
```
var arena = mem.Arena()
var buf: []u8 = arena.alloc(u8, 4096)
var tmp: []i32 = arena.alloc(i32, 100)
arena.freeAll()    // frees everything at once — all arena values become invalid
```

`arena.free(x)` on an individually arena-allocated value is a no-op — Arena does not track individual allocations. Use `arena.freeAll()` to release memory.

### Stack — Stack-backed Scratch
```
var scratch = mem.Stack(4096)       // 4096 bytes on the stack — must be a compile-time constant
var buf: []u8 = scratch.alloc(u8, 256)
var nums: []i32 = scratch.alloc(i32, 16)
// all memory freed automatically when scratch goes out of scope — no heap involved
```

`n` must be a compile-time constant (a literal or `compt` variable) — the buffer lives on the stack.
