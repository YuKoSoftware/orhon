# Kodr — Complete Language Reference

Everything the compiler supports as of v0.3.5.

---

## Types

### Primitives
```
i8  i16  i32  i64  i128       // signed integers
u8  u16  u32  u64  u128       // unsigned integers
isize  usize                  // platform-native
f16  bf16  f32  f64  f128     // floats
bool                          // true / false
String                        // immutable text ([]const u8)
void                          // no value
```

### Numeric Literals
```kodr
const a: i32 = 1_000_000      // decimal
const b: u32 = 0xFF            // hex
const c: u8  = 0b1010          // binary
const d: u8  = 0o77            // octal
const e: f64 = 3.141_592       // float
```
Bare literals resolve to `#bitsize` default or require explicit type.

### Union Types
```kodr
(Error | i32)                  // error union
(null | User)                  // nullable union
(i32 | String)                 // arbitrary union
(i32 | f32 | bool)             // 3+ member union
```

---

## Variables

```kodr
const x: i32 = 10             // immutable — module or function level
var y: i32 = 5                // mutable — function level only
var z: (null | i32) = null    // nullable
```

Module-level must be `const`. All variables must be initialized.

### Type Inference
```kodr
var name = "hello"             // String
var p = Player.create("hero")  // Player
var flag = true                // bool
const result = divide(10, 2)   // (Error | i32)
```

### Destructuring
```kodr
const min, max = minMax(3, 7)
const before, after = s.split(":")
const left, right = arr.splitAt(3)
```

---

## Operators

### Arithmetic
```kodr
a + b    a - b    a * b    a / b    a % b
a ++ b   // concatenation (strings, arrays)
```

### Comparison
```kodr
a == b   a != b   a < b   a > b   a <= b   a >= b
```

### Type Check
```kodr
x is Error        x is not null
x is i32          x is not String
```

### Logical
```kodr
a and b    a or b    not a
```

### Bitwise
```kodr
a & b    a | b    a ^ b    a << n    a >> n
```

### Compound Assignment
```kodr
x += y    x -= y    x *= y    x /= y
```

### Overflow Control
```kodr
overflow(a + b)    // returns (Error | T)
wrap(a + b)        // wrapping arithmetic
sat(a + b)         // saturating arithmetic
```

---

## Functions

```kodr
func add(a: i32, b: i32) i32 {
    return a + b
}

pub func greet(name: String, msg: String = "hello") String {
    return msg ++ " " ++ name
}

// recursive
func fib(n: i32) i32 {
    if(n <= 1) { return n }
    return fib(n - 1) + fib(n - 2)
}

// compile-time
compt func double(n: i32) i32 {
    return n * 2
}

// type-returning compt
compt func Box(T: any) type {
    return struct { value: T }
}
```

### Function Pointers
```kodr
func negate(x: i32) i32 { return 0 - x }

func apply(f: func(i32) i32, x: i32) i32 {
    return f(x)
}

const f: func(i32) i32 = negate
f(10)
```

---

## Structs

```kodr
pub struct Player {
    pub name: String
    health: f32               // private by default
    score: i32 = 0            // default value

    pub func create(n: String) Player {
        return Player(name: n, health: 100.0)
    }

    pub func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    pub func takeDamage(self: &Player, amount: f32) void {
        self.health = self.health - amount
    }
}

var p: Player = Player.create("hero")
p.takeDamage(25.0)
```

---

## Enums

```kodr
pub enum(u8) Direction {
    North
    South
    East
    West

    pub func opposite(self: const &Direction) Direction {
        match(self) {
            North => { return South }
            South => { return North }
            East  => { return West }
            West  => { return East }
        }
        return North
    }
}

const d: Direction = North
const o: Direction = d.opposite()
```

---

## Bitfields

```kodr
bitfield(u8) FileMode {
    Read
    Write
    Execute
}

var mode: FileMode = FileMode(Read, Write)
mode.has(Read)        // true
mode.set(Execute)
mode.clear(Write)
mode.toggle(Read)
```

---

## Control Flow

### if / else
```kodr
if(x > 0) {
    return x
} else {
    return 0 - x
}
```

### while
```kodr
while(i < n) {
    i += 1
}

// with continue expression
while(i < n) : (i += 1) {
    total += i
}
```

### for
```kodr
for(arr) |val| { }               // iterate values
for(arr) |val, i| { }            // with index
for(0..10) |i| { }               // range
for(my_map) |(key, value)| { }   // map yields tuples
for(my_set) |key| { }            // set yields keys
```

### match
```kodr
// integers
match(n) {
    1 => { return "one" }
    2 => { return "two" }
    else => { return "other" }
}

// ranges (inclusive)
match(age) {
    0..12   => { return "child" }
    13..17  => { return "teen" }
    18..120 => { return "adult" }
    else    => { return "unknown" }
}

// strings
match(cmd) {
    "start" => { run() }
    "stop"  => { halt() }
    else    => { }
}

// union types
match(result) {
    Error => { return 0 }
    i32   => { return result.i32 }
}
```

### defer
```kodr
defer { cleanup() }
// runs at scope exit, LIFO order for multiple defers
```

### break / continue
```kodr
while(true) {
    if(done) { break }
    if(skip) { continue }
}
```

---

## Error Handling

```kodr
const ErrNotFound = Error("not found")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) { return Error("division by zero") }
    return a / b
}

// check with is
const result = divide(10, 0)
if(result is Error) {
    return 0           // early exit narrows type
}
return result.i32      // safe after check

// check with match
match(result) {
    Error => { return 0 }
    i32   => { return result.i32 }
}
```

Unsafe unwrap (`result.i32` without checking) is a compile error.
Unhandled error unions at scope exit are a compile error.

---

## Null Handling

```kodr
func find(id: i32) (null | User) {
    if(id <= 0) { return null }
    return lookupUser(id)
}

const result = find(42)
if(result is null) { return }
const user = result.User     // safe after check

// nullable variable
var x: (null | i32) = null
x = 42
```

---

## Arbitrary Unions

```kodr
func getValue(flag: bool) (i32 | String) {
    if(flag) { return 42 }
    return "hello"
}

// type check
const val = getValue(true)
if(val is i32) { return val.i32 }

// reassignment auto-wraps
var x: (i32 | String) = 10
x = "changed"
```

---

## Arrays & Slices

```kodr
const arr: [3]i32 = [10, 20, 30]
var buf: [5]i32 = [1, 2, 3, 4, 5]
const part: []i32 = buf[1..4]        // slice [2,3,4]

arr.len          // length
arr[i]           // index access
```

### splitAt
```kodr
const left, right = arr.splitAt(3)
// arr is consumed — using it after is a compile error
```

---

## Tuples

```kodr
func minMax(a: i32, b: i32) (min: i32, max: i32) {
    if(a < b) { return (min: a, max: b) }
    return (min: b, max: a)
}

const result = minMax(3, 7)
result.min    // 3
result.max    // 7

// destructure
const min, max = minMax(3, 7)
```

---

## Generics

```kodr
// generic function
func identity(val: any) any {
    return val
}

// compt type dispatch
compt func describe(val: any) String {
    if(val is i32) { return "integer" }
    if(val is String) { return "string" }
    return "unknown"
}

// compt type constructor
compt func Box(T: any) type {
    return struct { value: T }
}

const b = Box(i32)(value: 99)
```

---

## Pointers

```kodr
// Ptr(T) — safe, read-only
var x: i32 = 42
const p: Ptr(i32) = Ptr(i32, &x)
p.value    // 42

// RawPtr(T) — unsafe, always warns
var arr: [3]i32 = [1, 2, 3]
const raw: RawPtr(i32) = RawPtr(i32, &arr)
raw[1]     // pointer arithmetic

// VolatilePtr(T) — hardware registers
const reg: VolatilePtr(u32) = VolatilePtr(u32, 0xFF200000)
```

---

## Ownership & Borrowing

```kodr
// primitives copy
var a: i32 = 5
var b: i32 = a         // copy

// non-primitives move
var s: Data = getData()
var s2: Data = s       // s is now invalid

// explicit
var c = copy(data)     // explicit copy
var d = move(data)     // explicit move
swap(x, y)             // swap ownership

// borrow
const r: const &Point = &p     // immutable borrow
const m: &Point = &p           // mutable borrow

// rules:
// - no simultaneous mutable + immutable borrows
// - method calls create temporary borrows
// - use-after-move is compile error
```

---

## Memory

### Allocators
```kodr
import std::mem

const alloc = mem.DebugAllocator()
var items: List(i32) = List(i32, alloc)

// or default (SMP)
var items: List(i32) = List(i32)
```

| Allocator | Usage |
|-----------|-------|
| `mem.SMP()` | Default, fast, per-thread |
| `mem.DebugAllocator()` | Leak detection |
| `mem.Arena()` | Batch alloc, `freeAll()` |
| `mem.Page()` | OS pages |
| `mem.Stack(n)` | Stack-backed scratch |
| `mem.Pool(T)` | Object pool |

### Direct Allocation
```kodr
const alloc = mem.DebugAllocator()
var buf: []i32 = alloc.alloc(i32, 100)
var val: i32 = alloc.allocOne(i32, 42)
alloc.free(buf)
alloc.free(val)
```

---

## Collections

### List(T)
```kodr
var items: List(i32) = List(i32)
defer { items.free() }
items.add(10)
items.get(0)     // 10
items.set(0, 20)
items.remove(0)
items.len        // count
for(items) |v| { }
```

### Map(K, V)
```kodr
var m: Map(String, i32) = Map(String, i32)
defer { m.free() }
m.put("key", 42)
m.has("key")     // true
m.get("key")     // 42
m.remove("key")
for(m) |(k, v)| { }
```

### Set(T)
```kodr
var s: Set(i32) = Set(i32)
defer { s.free() }
s.add(1)
s.has(1)         // true
s.remove(1)
for(s) |k| { }
```

### Ring / ORing
```kodr
var r: Ring(i32, 8) = Ring(i32, 8)
r.push(1)
r.pop()          // (null | i32)
r.isFull()
r.isEmpty()
r.count()

// ORing overwrites oldest when full
var o: ORing(i32, 4) = ORing(i32, 4)
```

---

## Threads

```kodr
const x: i32 = 21
thread(i32) worker {
    return x * 2
}
const result: i32 = worker.value   // blocks, returns result

// thread properties
worker.finished    // bool
worker.wait()      // block without value
worker.cancel()    // cooperative cancel
```

Rules:
- Values move into threads — original invalid after spawn
- Threads must be joined (`.value` or `.wait()`) before scope exit
- `.value` is a move — can only be called once
- Use `splitAt` for safe data partitioning

---

## Compiler Functions

```kodr
cast(i64, x)          // type cast
copy(data)            // explicit copy
move(data)            // explicit move
swap(a, b)            // swap ownership
assert(cond)          // assertion
assert(cond, "msg")   // with message
size(i32)             // 4 (bytes)
align(f64)            // 8 (alignment)
typename(x)           // "i32" (string)
typeid(x)             // unique type ID
```

---

## String Methods

### Non-Allocating
```kodr
s.contains("x")       s.startsWith("x")    s.endsWith("x")
s.trim()               s.trimLeft()          s.trimRight()
s.indexOf("x")         s.lastIndexOf("x")   s.count("x")
s.split(":")           s.parseInt()          s.parseFloat()
```

### Allocating
```kodr
s.toUpper()    s.toLower()    s.replace("a", "b")    s.repeat(3)
```

---

## Standard Library

```kodr
import std::console    // print, println, flush, debugPrint, get
import std::str        // from, join, fromBytes, toBytes
import std::math       // pow, sqrt, abs, min, max, floor, ceil, sin, cos, tan, ln, log2, PI, E
import std::mem        // SMP, DebugAllocator, Arena, Page, Stack, Pool
import std::system     // getEnv, setEnv, args, cwd, exit, pid
import std::time       // now, nowMs, sleep, elapsed
import std::fs         // exists, delete, rename, createDir, deleteDir
import std::json       // parse, stringify, get, isValid
import std::sort       // sort, sortDesc, isSorted, reverse, min, max
```

---

## Modules & Imports

```kodr
module main                    // module declaration (required)

import math                    // project-local module
import std::console            // stdlib module
import std::math as m          // with alias

pub func visible() void { }   // accessible from other modules
func hidden() void { }        // module-private
```

---

## Project Metadata

```kodr
#name    = "myproject"
#version = Version(1, 0, 0)
#build   = exe                 // exe | static | dynamic
#bitsize = 32                  // default numeric literal size
```

---

## Extern (Zig Bridge)

```kodr
// kodr side (math.kodr)
extern func sqrt(x: any) any
extern const PI: f64
extern struct Socket

// paired zig side (math.zig)
pub fn sqrt(x: anytype) @TypeOf(x) { ... }
pub const PI: f64 = 3.14159;
pub const Socket = struct { ... };
```

---

## Testing

```kodr
test "add works" {
    assert(add(2, 3) == 5)
}

test "division error" {
    const r = divide(10, 0)
    assert(r is Error)
}
```

Run with `kodr test`. Stripped from release builds.

---

## CLI

```
kodr build                     // debug build
kodr build -fast               // release, max speed
kodr build -small              // release, min size
kodr build -linux_x64          // cross-compile
kodr build -zig                // emit Zig source
kodr run                       // build and execute
kodr test                      // run all test blocks
kodr fmt                       // format all .kodr files
kodr init <name>               // create new project
kodr debug                     // dump project info
kodr addtopath                 // add kodr to PATH
kodr version                   // print version
```

---

## Comments

```kodr
// single line

/* block comment
   everything between */

/// reserved for doc generation (future)
```
