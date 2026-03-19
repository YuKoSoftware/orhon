# Kodr — Language Specification

---

## 1. Philosophy & Goals

### Inspiration
Kodr draws from five languages, taking the best of each and discarding what doesn't fit:

| Language | Borrow | Reject |
|----------|--------|--------|
| Rust | Memory safety, ownership model, performance | Complexity, verbose lifetime annotations |
| Go | Simplicity, readable syntax, fast compilation | Garbage collection, feels restrictive |
| Swift | Expressive syntax, modern feel, powerful type system | Platform lock-in, complex toolchain |
| Zig | Low-level control, no hidden control flow, comptime | Verbosity |
| Python | Clean readable syntax, approachability | Poor performance, dynamic typing |

### One-sentence pitch
*"A simple yet powerful language that is safe."*

### Primary user
Developers who value simplicity and explicitness — people who appreciate what Rust and Go are trying to do, but want a language that doesn't make them fight the toolchain or the type system to get things done.

### Non-goals
- **Not garbage collected** — memory is managed at compile time through ownership
- **Not platform-specific** — first-class cross-compilation, no preferred OS or runtime
- **Not complex** — if a feature can be reasonably achieved with existing language constructs, it won't be added as a special mechanism
- **Not a scripting language** — no REPL-first design, not optimized for short throwaway scripts
- **Not opinionated about domain** — no built-in async runtime, no preferred paradigm forced on the user

### Core values (in priority order)
1. **Safety** — memory safety guaranteed at compile time, no undefined behavior
2. **Simplicity** — minimal keywords, minimal special cases, learnable in a weekend
3. **Performance** — zero-cost abstractions, no runtime overhead, no GC pauses
4. **Portability** — cross-compile anywhere, no platform lock-in

---

## 2. Keywords

Every keyword in Kodr earns its place. No keyword exists for convenience alone.

```
func, var, const, if, else, for, while, return, import, pub,
match, struct, enum, defer, thread, null, void, compt,
any, module, test, and, or, not, main, as, type, label,
break, continue, true, false, extern, is
```

---

## 3. Syntax Rules

- Braces `{}` for all code blocks
- No semicolons — each line does one job, newline terminates a statement
- Parentheses `()` required around `if` and `while` conditions
- No naming conventions enforced — style is up to the programmer
- No operator overloading — but math operators work element-wise on tuples (see Section 11)
- Shadowing is not allowed — compile time error
- Inner scopes can read outer scope variables

---

## 4. Comments

```
// single line comment

/// reserved for future documentation generation — not yet implemented

/* block comment
   everything between is raw text
   useful for commenting out code */
```

Block comments use `/* */`. No nesting — the first `*/` closes the comment. Single-line `//` is preferred for regular comments; `/* */` is for temporarily disabling code blocks.

---

## 5. String Literals & Escape Sequences

String literals are enclosed in double quotes. Escape sequences follow universal convention:

```
"hello world"       // basic string
"hello\nworld"     // newline
"hello\tworld"     // tab
"say \"hi\""      // escaped quote
"back\\slash"     // escaped backslash
"null\0term"       // null terminator
"carriage\rreturn" // carriage return
```

Multiline strings use `\n` — no special multiline syntax needed. Strings are immutable `[]const u8` under the hood.

---

## 6. Numeric Literals

```
i8, i16, i32, i64, i128           // signed integers
u8, u16, u32, u64, u128           // unsigned integers
isize, usize                      // platform-native size, pointer sizes and indexing
f16, bf16, f32, f64, f128         // floating point
                                  // f16  — half precision, graphics and AI inference
                                  // bf16 — bfloat16, AI training
                                  // f128 — maps to C long double
bool                              // true or false
string                            // immutable text — shorthand for []const u8
                                  // always copies (cheap — just a pointer + length, 16 bytes)
                                  // for mutable byte manipulation, use []u8
```

`string` is a special convenience type. Under the hood it is `[]const u8` — an immutable slice. Copying a string copies the pointer, not the data, so it is always cheap. For mutable byte buffers, use `[]u8` which follows normal move semantics.

`u8` doubles as a byte and character type — interpreted based on usage context.

---

## 7. Collections

Numeric literals support multiple bases and underscore separators for readability:

```
// decimal
var x: i32 = 1_000_000    // underscore separator for readability
var y: f64 = 3.141_592    // works on floats too

// hexadecimal
var a: u32 = 0xFF
var b: u32 = 0xDEAD_BEEF

// binary
var c: u8 = 0b1010_1010

// octal
var d: u8 = 0o777
```

Numeric literals without a type annotation resolve to the project's `main.bitsize` setting. If `main.bitsize = 32`, bare `42` becomes `i32` and `3.14` becomes `f32`. If `main.bitsize = 64`, they become `i64` and `f64`. If `main.bitsize` is not set, bare numeric literals are a compile error — the type must be explicit.

```
// in main.kodr
main.bitsize = 32

// now these work:
var x = 42              // i32 (from bitsize)
var f = 3.14            // f32 (from bitsize)

// explicit override always works:
var y: i64 = 42         // i64 regardless of bitsize
var g: f16 = 3.14       // f16 regardless of bitsize
```

Underscore separators are ignored by the compiler, purely for human readability.

---

## 8. Primitive Types

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

### Array literals
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

### `splitAt` — atomic slice split
Splits a slice into two non-overlapping owned halves in a single atomic operation. The original slice is consumed — invalid after split. Used for safely sharing data between threads.

```
var data: []i32 = [1, 2, 3, 4, 5, 6]
var left, right = data.splitAt(3)    // left=[1,2,3], right=[4,5,6]
// data is now invalid
```

Hard compiler error if split index is out of range.

---

## 9. Variable Declaration

Three levels of mutability and evaluation:

```
var x: i32 = 5           // mutable, runtime
const y: i32 = 10        // immutable, runtime (optimizer may constant-fold)
compt z: i32 = 5 * 10    // compile time, guaranteed — hard error if impossible
```

- `var` — mutable, runtime. Can be reassigned.
- `const` — immutable, runtime. Cannot be reassigned. The optimizer may fold constant expressions, but this is not guaranteed by the language.
- `compt` — compile time, guaranteed. Must be fully knowable at compile time — hard compiler error otherwise. `compt` is a prefix modifier — it goes in front of declarations and statements, never inline on arbitrary expressions. Three uses:
  - `compt X: i32 = 1024` — compile-time variable
  - `compt func hash() u64 { ... }` — compile-time function (entire body is comptime)
  - `compt for(items) |item| { ... }` — compile-time loop unrolling (maps to Zig `inline for`)

All variables must be initialized at declaration — no uninitialized state. If a value is not yet known, use a `(null | T)` union:
```
var user: (null | User) = null     // explicitly "not set yet"
```

### Type annotation — optional when unambiguous
Type annotation can be omitted when the right hand side unambiguously determines the type. If there is any ambiguity — the type must be explicit.

```
// type can be omitted — unambiguous
var name = "hello"                  // clearly string
var p = Player.create("hero")       // clearly Player
var s = Circle(radius: 5.0)         // clearly Shape
var flag = true                     // clearly bool
var result = divide(10, 2)          // clearly (Error | i32)
var a: i32 = 5
var b = a                           // clearly i32, inferred from a

// numeric literals — use main.bitsize default or explicit type
var x = 42              // resolves to i32/i64 based on main.bitsize
var f = 3.14            // resolves to f32/f64 based on main.bitsize
var b: u8 = 255         // explicit override
```

**The rule:** function calls, struct instantiation, enum variants, string literals, bool literals, and other variables — type can be inferred. Numeric literals — resolve to the project's `main.bitsize` default, or must be explicitly typed if `main.bitsize` is not set.

---

## 10. Type System

### Type annotation
Explicit when ambiguous, optional when unambiguous. See Variable Declaration for full rules. Numeric literals resolve to `main.bitsize` default or require an explicit type.

### Generics with `any`
`any` replaces `<T>` syntax. Always resolved at compile time — the compiler generates a typed version per usage. Hard compiler error if the type cannot be determined at compile time.

`any` can appear in:
- Function parameters and return types
- Struct fields
- `compt` function parameters

```
// function parameter and return type
func first(arr: []any) any {
    return arr[0]
}

// struct field
struct Wrapper {
    value: any
}

// compt function — generates a new type
compt func Box(T: any) type {
    return struct {
        value: T
    }
}

// usage — compiler generates typed versions
var x = first([1, 2, 3])            // compiler generates first(arr: []i32) i32
var w: Wrapper = Wrapper(value: 42) // compiler resolves value as i32
var b: Box(f32) = Box(f32)(value: 3.14)
```

The compiler always resolves `any` at compile time. If the type cannot be determined — hard compiler error. `any` never exists at runtime.

### Unions
Inline type alternatives. Defined with pipe-separated types in parentheses. Must be defined as a named type with `const`. Duplicate types in a union are a compile time error.
```
const MyUnion = (i32 | f32)

var x: MyUnion = 100
@type(x) == i32    // true
```

Union values accessed via dot syntax with the type name:
```
var result: (Error | i32) = divide(10, 0)
result.Error.message    // access error message
result.i32              // access the i32 value
```

### Tuples
Named tuples only. Must be defined as named types with `const`. Nominal typing — two tuples with identical structure but different names are different types.

**Named tuple — named fields, accessed by dot:**
```
const Point = (x: f32, y: f32)
const Velocity = (x: f32, y: f32)

var p: Point = Point(x: 1.0, y: 2.0)
var v: Velocity = Velocity(x: 0.5, y: 0.5)
// Point and Velocity are different types even though fields are identical

p.x    // field access
p.y
```

### Tuple destructuring
A tuple can be destructured into individual variables. Variable names on the left must match field names of the tuple. Variable count must match field count — hard compiler error otherwise.
```
const MinMax = (min: i32, max: i32)
func minMax(arr: []i32) MinMax { }

var min, max = minMax(arr)    // min and max are owned i32 values

// field access still works — destructuring is an alternative not a replacement
var result: MinMax = minMax(arr)
result.min
result.max

// splitAt uses tuple destructuring
var left, right = data.splitAt(3)

// hard compiler error if variable count doesn't match field count
var a, b, c = minMax(arr)    // error — MinMax only has 2 fields
```

---

## 11. Operators

### Arithmetic
```
a + b    // add (numeric and tuples only, never strings/arrays)
a - b    // subtract
a * b    // multiply
a / b    // divide
a % b    // modulo
a ++ b   // concatenation (strings and arrays only, never numeric)
```

### Value comparison — compares the value
```
a == b    // equal
a != b    // not equal
a < b     // less than
a > b     // greater than
a <= b    // less than or equal
a >= b    // greater than or equal
```

### Type comparison — compares the type, not the value
```
a is T        // true if a is of type T
a is not T    // true if a is not of type T
```
Used with union types, `Error`, and `null`. No overlap with value comparison — explicit by design.

### Boolean logic
```
a and b    // logical AND
a or b     // logical OR
not a      // logical NOT
```

### Bitwise
```
a & b     // AND
a | b     // OR
a ^ b     // XOR
!a        // NOT
a >> 2    // right shift
a << 2    // left shift
```

### Tuple math
Math operators (`+`, `-`, `*`, `/`, `%`) work on named tuples with all-numeric fields. No operator overloading — these are built-in compiler rules.

**Tuple op Tuple** — element-wise, both must be same type:
```
const Vec2 = (x: f32, y: f32)
var a = Vec2(x: 1.0, y: 2.0)
var b = Vec2(x: 3.0, y: 4.0)
var c = a + b              // Vec2(x: 4.0, y: 6.0)
var d = a * b              // Vec2(x: 3.0, y: 8.0)
```

**Tuple op Scalar** — applies scalar to every field:
```
var doubled = a * 2.0      // Vec2(x: 2.0, y: 4.0)
var half = a / 2.0         // Vec2(x: 0.5, y: 1.0)
```

**Scalar op Tuple** — commutative:
```
var scaled = 3.0 * a       // Vec2(x: 3.0, y: 6.0)
```

Compiler error if any tuple field is non-numeric, or if tuple shapes don't match.

### String and array concatenation
`++` is the concatenation operator — distinct from `+` (arithmetic). Never user-defined. Compiler error if types don't match. Using `+` on strings or `++` on numbers is a compile error.
```
var s: string = "hello " ++ "world"    // string concatenation
var a: []i32 = [1, 2] ++ [3, 4]       // array concatenation, types must match
```

### No implicit numeric casts
Mixing numeric types in expressions is a compile error. All conversions must be explicit via `@cast(T, x)`.
```
var x: i32 = 42
var f: f32 = 3.14
var z = x + f                // ERROR — i32 + f32, types don't match
var z = @cast(f32, x) + f    // OK — explicit cast
```

---

## 12. Compiler Functions

Compiler functions are instructions to the compiler — not real function calls. Prefixed with `@` to make this distinction explicit. Zero runtime cost — they disappear entirely in the output binary.

```
@type(x)                 // returns the actual type of x — usable in type positions
@typename(x)             // returns the type name as a string — usable for display
@typeid(x)               // returns unique compiler assigned integer ID — fast identity check
@cast(T, x)              // converts x to target type T — always explicit
@copy(x)                 // explicitly copies a non-primitive, original stays valid
@move(x)                 // explicitly moves a value, original becomes invalid
@swap(x, y)              // swaps ownership between two variables
@assert(x)               // assertion, checked at compile time or test time
@assert(x, "message")    // with custom failure message
@size(x)                 // returns size of type or value in bytes
@align(x)                // returns alignment requirement of type or value in bytes
```

### `@type` — actual type
Returns the actual type — usable anywhere a type is expected, including declarations and function signatures:
```
var x: @type(some_var) = some_var           // use inferred type in declaration
func process(arg: @type(some_var)) void { } // use inferred type in signature

var result: (Error | i32) = divide(10, 0)
if(@type(result) == Error) {
    console.print(result.Error)
}
```

For type comparison, use the `is` / `is not` keywords — see Section 11:
```
result is Error        // sugar for @type(result) == Error
result is null         // sugar for @type(result) == null
result is not Error    // sugar for @type(result) != Error
result is not null     // sugar for @type(result) != null
```

### `@typename` — type name as string
Returns the name of the type as a string. Useful for debugging, logging, and serialization. Cannot be used in type positions.
```
@typename(x)              // "Player"
@typename(42)             // "i32"
@typename(Error("x"))     // "Error"
console.print(@typename(x))
```

### `@typeid` — unique type identity
Returns a compiler assigned unique integer ID for the type. Fast, unambiguous. Two structurally identical types with different names have different IDs.
```
@typeid(p1) == @typeid(p2)          // true only if exact same type
@typeid(Point) == @typeid(Velocity) // false — different types despite identical structure
```

### `@cast` — type conversion
Target type is always explicit — no inference, no guessing:
```
var x: i32 = 42
var y: i64 = @cast(i64, x)    // explicit target type
var z: f32 = @cast(f32, x)    // explicit conversion
func add(x: i64) i64 { }
add(@cast(i64, my_i32))       // explicit at call site
```
Widening casts are always safe. Narrowing casts emit a compiler warning.

### `@size` — size in bytes
Returns the size of a type or value in bytes. Resolved at compile time whenever possible.
```
@size(i32)          // 4
@size(f64)          // 8
@size(my_struct)    // size of struct instance in bytes
@size([10]i32)      // 40 — fixed array, compt value
@size([]i32)        // size of slice header, not the data
@size(i32) * 8      // 32 — bits, just multiply by 8
```

### `@align` — alignment in bytes
Returns the alignment requirement of a type or value in bytes. Essential for custom allocators, C interop, hardware access, and SIMD operations.
```
@align(i32)         // 4 — must be on a 4 byte boundary
@align(f64)         // 8
@align(MyStruct)    // largest alignment of any field in the struct
```

---

## 13. Builtin Functions & Values

Always available without any import. Have a real runtime presence — produce actual code in the output binary.

### Error
`Error` is a distinct string type. An error is just a message — the string carries all the information needed to trace and fix the problem. Can be created inline or stored as a named constant for reuse.

```
// inline
Error("division by zero")

// named constant for reuse — no type annotation needed
const ErrDivByZero = Error("division by zero")
const ErrNotFound = Error("file not found")

// usage
func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

// print the error message
console.print(result.Error)    // "division by zero"
```

### Overflow helpers
See Section 17 — Integer Overflow for full documentation.

### Special values
`null`, `true`, `false`, and `void` are keywords — see Section 2. They are listed here for reference:
```
null     // absence of a value, only exists inside a union type
void     // function returns nothing
true     // boolean true
false    // boolean false
```

### Version
A named tuple of three `u32` values following semantic versioning — major, minor, patch. String versions are never allowed — hard compiler error.
```
Version(1, 0, 0)
Version(2, 4, 1)
```

### VersionRule
An enum that tells the compiler how to resolve a dependency version:
```
enum VersionRule(u64) {
    Latest                    // ignore version, get latest
    Minimum(v: Version)       // at least this version
    Exact(v: Version)         // exactly this version
    Preferred(v: Version)     // this version if available, latest otherwise
}
```

```
Latest
Minimum(Version(2, 0, 0))
Exact(Version(2, 4, 1))
Preferred(Version(2, 4, 1))
```

### Dependency
Declares an external dependency with a URL and version rule:
```
Dependency(url: string, rule: VersionRule)
```

```
main.deps = [
    Dependency("https://github.com/user/lib", Latest)
    Dependency("https://github.com/user/lib", Minimum(Version(2, 0, 0)))
    Dependency("https://github.com/user/lib", Exact(Version(2, 4, 1)))
    Dependency("https://github.com/user/lib", Preferred(Version(2, 4, 1)))
]
```

`Version`, `VersionRule` and `Dependency` are all compiler-known builtins — no import needed since they are used in the root file before any imports.

---

## 14. Functions

### Declaration
```
func add(a: i32, b: i32) i32 {
    return a + b
}

func log(msg: string) void {
    // returns nothing
}
```

### First class functions
Functions are values — storable as named types, passable as arguments:
```
const Transform = func(i32) i32

func double(x: i32) i32 {
    return x * 2
}

var f: Transform = double

func apply(arr: []i32, f: Transform) []i32 {
    // apply f to every element
}
```

### `compt` functions
Entire function runs at compile time. Used for type generation and zero-cost abstractions. When a `compt` function generates a type, its return type is annotated with the `type` keyword:
```
compt func Vec2(T: any) type {      // returns a type, not a value
    return struct {
        x: T
        y: T
    }
}

compt func Pair(A: any, B: any) type {
    return struct {
        first: A
        second: B
    }
}

var pos: Vec2(f32) = Vec2(f32)(x: 1.0, y: 2.0)
var p: Pair(i32, string) = Pair(i32, string)(first: 42, second: "hello")
```

Note: `type` as a keyword is distinct from `@type()` as a compiler function:
- `type` — return type annotation meaning "this function produces a type"
- `@type(x)` — compiler function meaning "give me the type of this value"

### `compt for` — compile-time loop unrolling
`compt for` unrolls a loop at compile time. Maps to Zig's `inline for`. Used for generating code per type or per item in a compile-time known collection.
```
compt for(types) |T| {
    // generates code per type at compile time
}
```
If you need compile-time logic inside a runtime function, extract it into a `compt func` and call it — no inline `compt` blocks or expressions.

### No function overloading
Every function has a unique name. No ambiguity, no compiler complexity.

### No closures
Context is always passed explicitly as function arguments. No captured variables. For most use cases, loops with inner scope access cover the need:
```
var multiplier: i32 = 5
for(arr) |val| {
    result = val * multiplier    // inner scope reads outer variable
}
```
For callback patterns, pass context as extra arguments or wrap state in a struct.

---

## 15. Error Handling

Functions that can fail return a union of `Error` and the success type. No exceptions, no monads — just a union and a type check. An error is a message string with a distinct type. If unhandled before scope exit, the program crashes and prints the message. That crash is the signal — the programmer sees exactly what went wrong and where.

```
const ErrDivByZero = Error("division by zero")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

var result = divide(10, 0)
if(result is Error) {
    console.print(result.Error)    // "division by zero"
    return
}
var value: i32 = result.i32
```

Inline errors are fine for one-off cases:
```
func readFile(path: string) (Error | string) {
    return Error("could not open file")
}
```

If the error is not handled before scope exit — crash, print message, done.

---

## 16. Null Handling

Absence of a value expressed through a union with `null`. `null` is never a standalone value — it only exists inside a union type.

The same scope-based rule as error handling applies — a `(null | T)` union must be handled before leaving scope. If not handled, the compiler throws a hard error.

```
func find(id: i32) (null | User) {
    // ...
}

// must handle before scope exit
var result = find(42)
if(result is null) {
    // handle absence
    return
}
var user: User = result.User
```

---

## 17. Integer Overflow

Silent wrap around by default. Use explicit builtins when you need controlled behavior. All are builtin functions — no import needed.

```
overflow(a + b)    // returns (Error | T) if overflow occurs — handle or propagates
wrap(a + b)        // explicitly wraps around, documents intent, always succeeds
sat(a + b)         // saturating arithmetic, clamps to max/min value, always succeeds
```

```
// overflow — returns union, must be handled
var result = overflow(a + b)
if(@type(result) == Error) {
    console.print("overflow occurred")
    return
}
var value: i32 = result.i32

// wrap — always succeeds, explicit intent
var x: i32 = wrap(maxInt + 1)    // wraps to minimum value

// sat — always succeeds, clamps
var x: i32 = sat(maxInt + 1)     // stays at maximum value
```

---

## 18. Memory Model & Ownership

### Core rules
1. Every value has exactly one owner
2. When the owner goes out of scope, the value is dropped
3. Assignment moves ownership by default for non-primitives
4. You can borrow immutably many times, or mutably once — never both simultaneously
5. All safety checks are compile time only — zero runtime overhead

### Copy vs move
- **Primitives** (`i32`, `i64`, `u8`, `f64`, `bool`, `usize`, `isize`, `string` etc.) — silently copy on assignment, compiler does not track them. `string` is `[]const u8` under the hood (a pointer + length), so copying is always cheap (16 bytes).
- **Everything else** (structs, slices, user types) — move by default, compiler tracks ownership
- `@move` for explicit move intent
- `@copy` for explicit copies of non-primitives
- For mutable byte manipulation, use `[]u8` (mutable array) — this is a move type

```
var a: i32 = 5
var b: i32 = a            // copy, a still valid, compiler does not track

var s: string = "hello"
var s2: string = s        // copy, s still valid (string is a slice — cheap)

var data: MyStruct = getData()
var d2: MyStruct = data          // move, data is now invalid
var d3: MyStruct = @copy(d2)     // explicit copy, d2 still valid
var d4: MyStruct = @move(d2)     // explicit move, documents intent
```

Use-after-move is a compile time error. Zero runtime overhead — moved variables do not exist in the output binary.

### Borrowing
`&` borrows a value without transferring ownership. Caller retains ownership.
```
var s: string = "hello"
print(&s)     // borrow, s still valid
print(&s)     // still valid
print(s)      // move, s is gone after this
```

In function signatures:
```
func read(x: const &string) void { }    // immutable borrow, read only
func mutate(x: var &string) void { }    // mutable borrow, can modify
```

### Borrow rules
- `const &T` — immutable borrow, many allowed simultaneously
- `var &T` — mutable borrow, only one at a time
- Cannot have immutable and mutable borrow simultaneously — compile time error
- Functions can never return references, only owned values
- If you need to return borrowed data, use `@copy` to return an owned copy
- Instead of getters that return references, provide methods that do the work inside the struct:
```
struct Game {
    player: Player

    // Don't return &Player — provide methods instead:
    func getPlayerName(self: const &Game) string { return self.player.name }
    func damagePlayer(self: var &Game, amount: f32) void {
        self.player.health = self.player.health - amount
    }
}
```

### Lifetimes
No lifetime annotations ever. The language stays simple — complexity lives in `@` compiler functions. Functions cannot return references — only owned values. If you need to return borrowed data, use `@copy` to return an owned copy. Lexical lifetimes only — a borrow is valid only within the block it was created in.

### Structs and ownership
Structs are atomic ownership units — all fields move together or none do.
```
var p: Player = Player(name: "john", score: 0, health: 100.0)
var p2: Player = p      // entire struct moves, p is invalid

var name: &string = &p2.name    // borrow a field, p2 still owns everything
```
Moving individual fields out of a struct is a compile time error.

---

## 19. Pointers

Traditional `*T` pointer syntax does not exist in Kodr. Instead there are three distinct pointer types, each with a clear purpose. All follow the same `Type(T, value)` instantiation pattern used everywhere in Kodr.

### `Ptr(T)` — safe pointer, general use
Compiler tracked. Always `const` — the pointer cannot be reassigned. Points to a single value only — no pointer arithmetic, no `[]` indexing. Must be initialized from a variable address (`&x`) — raw integer addresses are not allowed. The ownership pass ensures you cannot use a `Ptr(T)` after the pointee has moved — this is a hard compile-time error. No warnings emitted.

```
var x: i32 = 10
const ptr: Ptr(i32) = Ptr(i32, &x)

ptr.value          // read the pointed-to value

var x2: i32 = x   // x moved — compiler error if ptr.value is used after this
```

### `RawPtr(T)` — unsafe pointer, no restrictions
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

### `VolatilePtr(T)` — unsafe pointer, hardware registers
Same as `RawPtr(T)` with one difference: every read and write is volatile — the compiler never caches or optimizes them away. For memory-mapped hardware registers where the value can change outside the program. Always emits a compiler warning.

```
const reg: VolatilePtr(u32) = VolatilePtr(u32, 0xFF200000)
reg[0]         // volatile read
reg[0] = 0x1   // volatile write
reg[1] = 0x2   // volatile write to next register
```

### Rules
- `Ptr(T)` — always `const`, safe, no warnings, single value, `&variable` only
- `RawPtr(T)` — always warns, no restrictions, full pointer arithmetic, escape hatch
- `VolatilePtr(T)` — always warns, like `RawPtr(T)` but all accesses are volatile, hardware registers only
- Self-referential structures use array indices instead of pointers — faster and safer

---

## 20. Defer

Runs a block at the end of the scope it is declared in — not end of function. Multiple defers in the same scope execute in reverse order (LIFO).

```
func example() void {
    defer { cleanup() }
    {
        defer { inner() }
    }                      // inner() runs here
}                          // cleanup() runs here
```

---

## 21. Structs

```
struct Player {
    pub name: string        // pub = accessible outside module
    health: f32             // private by default
    score: i32

    // static variable — no self, belongs to the type
    var defaultHealth: f32 = 100.0

    // static method — no self, called on type name
    func create(name: string) Player {
        return Player(name: name, score: 0, health: Player.defaultHealth)
    }

    // immutable instance method
    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    // mutable instance method
    func takeDamage(self: var &Player, amount: f32) void {
        self.health = self.health - amount
    }

    // consuming instance method — takes ownership, caller loses it
    func destroy(self: Player) void {
        // player dropped at end of function
    }
}
```

### Default field values
Fields can have default values using `=`. Any field with a default can be omitted during instantiation:
```
struct Player {
    pub name: string
    health: f32 = 100.0      // default value
    score: i32 = 0           // default value
    position: Vec2f = Vec2f(x: 0.0, y: 0.0)
}

// omit fields with defaults
var p: Player = Player(name: "hero")    // health=100.0, score=0, position=(0,0)

// override defaults
var p: Player = Player(name: "hero", health: 50.0)
```

Default values also work for enum variants, tuple fields, and function parameters:
```
// function parameter defaults
func greet(name: string, greeting: string = "hello") void { }
greet("world")              // uses default greeting
greet("world", "hi")        // overrides default

// tuple field defaults
const Config = (width: i32 = 800, height: i32 = 600, fullscreen: bool = false)
var cfg = Config(width: 800, height: 600, fullscreen: false)    // all explicit
var cfg = Config(width: 1920, height: 1080)                        // override some, fullscreen uses default
```

### Rules
- Named instantiation always — `Player(name: "john", score: 0, health: 100.0)`
- `self` is always the explicit first argument for instance methods
- No `self` = static, `const &T` = immutable, `var &T` = mutable, `T` = consuming
- Fields are private by default — `pub` makes them accessible outside the module

### Static struct variables
Static variables are shared across all instances. Both `var` and `const` are supported. Ownership rules apply — moving a static variable out makes it invalid.
```
struct Player {
    var defaultHealth: f32 = 100.0    // mutable, shared across all instances
    const maxPlayers: i32 = 64        // immutable, shared across all instances
}

Player.defaultHealth = 200.0          // allowed, var
Player.maxPlayers = 128               // compile error, const
```

### Composition
Explicit only — no automatic method forwarding:
```
struct Animal {
    name: string
    func speak(self: const &Animal) void { }
}

struct Dog {
    animal: Animal
    breed: string
}

var d: Dog = Dog(animal: Animal(name: "rex"), breed: "labrador")
d.animal.speak()    // explicit, always clear where the method comes from
```

---

## 22. Enums

Enums always require an explicit backing type — the compiler never silently chooses one. Hard compiler error if backing type is omitted.

```
// regular enum — named constants, explicit backing type
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum — compiler assigns powers of 2 automatically
enum Permissions(u32, bitfield) {
    Read      // 0b0001
    Write     // 0b0010
    Execute   // 0b0100
    Delete    // 0b1000
}

// data-carrying enum — explicit backing type
enum Shape(u32) {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point                               // can mix — some variants with data, some without
}
```

### Instantiation
The enum type name is declared once on the variable — never repeated on the right hand side:
```
var d: Direction = North
var s: Shape = Circle(radius: 5.0)
```

### Bitfield enum operations
Bitfield enums natively support flag operations. The underlying mechanism is standard bitwise operators on the backing integer type — `|` is bitwise OR, `&` is bitwise AND etc. The compiler knows the type is a bitfield enum and provides named convenience methods. Type safe — mixing flags from different enums is a hard compiler error.
```
var p: Permissions = Read | Write    // combine flags — bitwise OR on u32
p.has(Read)                          // check if set — bool, uses bitwise AND
p.set(Execute)                       // add flag — bitwise OR
p.clear(Write)                       // remove flag — bitwise AND NOT
p.toggle(Read)                       // toggle flag — bitwise XOR
```

### Methods on enums
Same rules as structs — `self` as first argument, match on self inside:
```
enum Shape(u32) {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point

    func area(self: const &Shape) f32 {
        match self {
            Circle    => { return 3.14 * Circle.radius * Circle.radius }
            Rectangle => { return Rectangle.width * Rectangle.height }
            Point     => { return 0.0 }
        }
    }
}
```

---

## 23. Pattern Matching

`match` is the only way to safely extract enum variant data. Must be exhaustive — compiler error if any variant is unhandled. `_` is the catch-all wildcard and must be last.

Inside a match arm, variant data accessed via dot syntax on the variant name. No local binding names needed.

```
match s {
    Circle    => { var area: f32 = 3.14 * Circle.radius * Circle.radius }
    Rectangle => { var area: f32 = Rectangle.width * Rectangle.height }
    Point     => { }
    _         => { }
}
```

`match` works on integers, strings, ranges, enum variants, and types:
```
match value {
    0       => { }    // exact integer
    4..8    => { }    // inclusive range
    "hello" => { }    // string
    North   => { }    // enum variant, no type prefix
    _       => { }    // catch-all
}
```

### Type matching
`match` can match on `@type()` and on type parameters in `compt` functions. Always resolved at compile time — hard compiler error if used in a runtime context. Zero runtime overhead.

```
// matching on @type() — compt resolved
func process(val: any) void {
    match @type(val) {
        i32    => { console.print("integer") }
        f32    => { console.print("float") }
        string => { console.print("string") }
        Player => { console.print("player") }
        _      => { console.print("unknown") }
    }
}

// matching on type parameter in compt function
compt func describe(T: any) type {
    match T {
        i32 => { return @type(struct { value: i32, label: string }) }
        f32 => { return @type(struct { value: f32, label: string }) }
        _   => { }
    }
}
```

---

## 24. Loops

### `for` — iteration
Used for iterating over collections and ranges. `for` is the only loop for iteration — never used for conditions.

```
for(my_array, 0..) |value, index| { }    // value and index
for(my_array) |value| { }                // value only
for(0..10) |i| { }                       // range
for(array_a, array_b) |a, b| { }        // two arrays simultaneously
```

### `while` — condition based
Used for looping on a condition. Never used for iteration.

```
var i: i32 = 0
while(i < 10) : (i += 1) { }    // with continue expression

while(running) { }               // simple condition

while(true) { }                  // infinite loop
```

### `break` and `continue`
```
// break — exit the current loop immediately
while(true) {
    if(done) {
        break
    }
}

// continue — skip to next iteration
for(my_array) |value| {
    if(value == 0) {
        continue
    }
}
```

### Labels — named loop control
`label` placed directly before a loop. Used with `break` and `continue` to control nested loops. Labels are compile time only — zero runtime overhead, disappear entirely in output binary.

```
label outerLoop
for(array_a) |a| {
    label innerLoop
    for(array_b) |b| {
        if(someCondition) {
            break outerLoop      // exit outer loop entirely
        }
        if(otherCondition) {
            continue outerLoop   // next iteration of outer loop
        }
        break innerLoop          // exit inner loop only
    }
}
```

Hard compiler error if label name doesn't match any enclosing loop. No shadowing of label names allowed.

---

## 25. Modules & Imports

### Module declaration
Every `.kodr` file must declare its module at the top — this is mandatory, no exceptions.
The module tag is the only thing that determines which module a file belongs to.
Folder structure, file names, and directory nesting have no significance whatsoever.

```
module math
```

### How the compiler finds modules
The compiler scans all `.kodr` files in `src/`, reads the module tag at the top of each,
and groups files by module name. Each group becomes one **compilation unit**.

- File location doesn't matter — `src/math.kodr`, `src/extra/more_math.kodr`,
  `src/deep/nested/stuff.kodr` — all fine as long as they declare `module math`
- Folder organization is purely for the developer's convenience
- The compiler only cares about module tags, not paths

### File naming rules — anchor file
Among all files in a module, exactly one must be named after the module — the **anchor file**.
This is what `import math` resolves to. Only the anchor file can contain build metadata
(`main.build`, `main.name`, `main.version`, `main.bitsize`, etc.).

- `module math` → one of the files must be `math.kodr` (anywhere in `src/`)
- `module main` → one of the files must be `main.kodr`
- Other files in the same module can be named anything
- No anchor file found = hard compiler error
- Every project root is `main.kodr` / `module main` — for both executables and libraries

Example — module math spanning three files, freely organized:
```
src/
    math.kodr              ← anchor file — required
    utils/algebra.kodr     ← also module math, any location
    utils/geometry.kodr    ← also module math, any location
```

All three declare `module math`. The compiler groups them into one compilation unit.
Parallel compilation: each module compiles independently of others.

### Two kinds of modules

**Regular module** — no `build`, compiled as part of whatever project imports it:
```
// math.kodr — anchor file, must exist
module math

pub func add(a: i32, b: i32) i32 { }

// algebra.kodr — also part of module math, any name is fine
module math

pub func solve(a: f64, b: f64, c: f64) f64 { }
```
Regular modules are only compiled if something imports them (dead code elimination).

**Project root** — always `main.kodr` / `module main`. All metadata uses the `main.*` prefix:
```
// main.kodr — project root for executable
module main

main.build = build.exe
main.version = Version(1, 0, 0)
main.name = "my_project"

func main() void {
    // entry point — required for build.exe
}
```

```
// main.kodr — project root for library
module main

main.build = build.static
main.version = Version(1, 0, 0)
main.name = "mylib"
```

### Additional library modules
A project can contain additional library modules alongside the root.
Each has its own anchor file and build declaration:
```
src/
    main.kodr              ← module main, build.exe (root)
    math/math.kodr         ← module math, build.static (anchor)
    math/vectors.kodr      ← module math (additional file)
    network/network.kodr   ← module network, build.dynamic (anchor)
```
Library modules are only built as separate artifacts if they are actually imported.

### Multi-module project
A single project with the root module and additional library modules:
```
my_project/
    src/
        main.kodr                // root — module main, build.exe
        player.kodr              // module main — additional file
        math/math.kodr           // module math, build.static (anchor)
        math/vectors.kodr        // module math — additional file
        utils/utils.kodr         // module utils — regular module (no build)
```

### Import syntax
Import the whole module — compiler eliminates dead code automatically. No symbol lists, no wildcard imports.

Three import forms — origin is always explicit:

```
// Project-local module — no scope, looks in src/
import math
math.add(1, 2)

// Stdlib module — std:: scope, looks in <kodr_dir>/std/
import std::alpha
alpha.println("hello")

// Global shared module — global:: scope, looks in <kodr_dir>/global/
import global::utils
utils.trim("  hello  ")

// With alias — as renames the access prefix
import std::alpha as io
io.println("hello")

// External libraries (C, system) — use a Zig bridge file, see Section 31
import global::gtk     // gtk.kodr + gtk.zig — Zig handles C under the hood
import global::sdl     // sdl.kodr + sdl.zig
```

**Scope rules:**
- No `::` → project-local (`src/`)
- `std::name` → `<kodr_dir>/std/name.kodr`
- `global::name` → `<kodr_dir>/global/name.kodr`
- Only one level of `::` — `std::a::b` is never valid
- `std` and `global` are reserved — cannot be project module names
- Default alias is always the module name, never the scope prefix

### Naming collision resolution
Use `as` to disambiguate modules with the same name:
```
import std::utils as std_utils
import global::utils as my_utils

std_utils.trim("hello")
my_utils.doSomething()
```

### Precompiled Kodr libraries *(not yet implemented — planned for later)*
When compiling a library, the compiler will generate a `.kodrm` metadata sidecar file.
This allows importing a precompiled library without needing its source — the `.kodrm`
contains the public interface (exported functions, types, struct layouts) for type checking.
Think of it as an auto-generated header file.

Compiler generates a `.kodrm` metadata file alongside the binary when compiling a library:
```
mylib.a        // compiled binary
mylib.kodrm    // required metadata — pub symbols, types, functions
```

Missing `.kodrm` when importing a precompiled library is a hard compiler error.

### Visibility
- Everything private by default
- `pub` makes a symbol or struct field accessible outside the module
- No wildcard imports ever
- No circular imports ever — hard compiler error, across all project boundaries
- Diamond dependencies safe — compiler deduplicates, each module compiled exactly once

### Hard compiler errors
- Circular imports across any boundary
- Multiple `build` declarations — structurally impossible, only valid in root file
- Project metadata written in any file other than the root file
- No anchor file found — at least one file in the module must be named after the module (`math.kodr` for `module math`)
- `module main` not in `main.kodr`
- `func main()` missing when `build.exe`
- Unknown import scope (anything other than `std` or `global`)
- `extern func` with a body — extern functions must have no body
- `extern func` without a paired `.zig` file
- `func main()` present when `build.static` or `build.dynamic`

---

## 26. Project Metadata

Declared in anchor files only. The metadata prefix is always the module name — `main.*` for `module main`, `math.*` for `module math`, etc. Writing project metadata in any file other than the anchor is a hard compiler error. No build files ever — the compiler is the build system.

```
// main.kodr — executable
module main

main.name = "my_project"
main.version = Version(1, 0, 0)
main.build = build.exe
main.bitsize = 32
main.deps = [
    Dependency("https://github.com/user/lib", Preferred(Version(2, 4, 1)))
    Dependency("https://myregistry.io/package", Minimum(Version(1, 0, 0)))
]
main.allocator = mem.ArenaAllocator
main.gpu = gpu.unified.auto

func main() void { }
```

```
// main.kodr — library project root
module main

main.name = "mylib"
main.version = Version(1, 0, 0)
main.build = build.static
main.deps = [...]
```

```
// math/math.kodr — additional library module within a project
module math

math.build = build.static
math.name = "math"
```

### Build types
- `build.exe` — `func main()` required, produces runnable binary
- `build.static` — no `func main()` needed, produces `.a` or `.lib` + `.kodrm`
- `build.dynamic` — no `func main()` needed, produces `.so` or `.dll` + `.kodrm`

`build` is a compiler-known enum. No import needed.

### External dependencies
Dependencies are managed manually — the user downloads libraries and places them in their project. The compiler finds and links them from local paths. No automatic fetching, no network code in the compiler.

```
main.deps = [
    Dependency("./libs/mylib", Exact(Version(2, 4, 1)))
    Dependency("./libs/sdl2", Minimum(Version(2, 0, 0)))
]
```

**Hard compiler errors:**
- Dependency path not found
- `.kodrm` not found alongside precompiled library
- Version mismatch with `Exact` rule
- Version below minimum with `Minimum` rule

---

## 27. Concurrency & Threading

### `Thread` — CPU parallelism
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

### `Async` — IO concurrency
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

### Ownership and threads
Values move into threads — using a value after it has been moved into a thread is a compile time error. Ownership returns through `.value`.

```
var data: []i32 = [1, 2, 3]

Thread([]i32) my_thread {
    return data
}

var data: []i32 = my_thread.value    // ownership returned
```

### Sharing data between threads
Data must be explicitly split using `splitAt` — a single atomic operation that consumes the original and produces two non-overlapping slices. Passing the same owned value to two threads is a compile time error.

```
// atomic split — data consumed, no overlap possible
var left, right = data.splitAt(3)

Thread([]i32) thread_a { return left }
Thread([]i32) thread_b { return right }
```

---

## 28. Memory Allocation

### Stack allocation — automatic, no allocator needed
```
var x: i32 = 5                                         // primitive, on the stack
var arr: [10]i32 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]   // fixed array, on the stack
// both dropped automatically when scope ends
```

### Heap allocation — single value
```
// default allocator
var x: i32 = mem.allocOne(i32, 42)
var p: Player = mem.allocOne(Player, Player.create("hero"))
var s: Shape = mem.allocOne(Shape, Circle(radius: 5.0))

// custom allocator
var x: i32 = myAllocator.allocOne(i32, 42)
```

### Heap allocation — multiple values
```
// default allocator
var data: []i32 = mem.alloc(i32, 100)

// custom allocator
var data: []i32 = myAllocator.alloc(i32, 100)
```

### Heap allocation — through collections
```
var list: collections.List(i32) = collections.List(i32)
list.append(1)
list.append(2)
```

### Custom allocator
```
var pool: mem.PoolAllocator = mem.PoolAllocator(size: 1024)
var list: collections.List(i32) = collections.List(i32)
list.allocator = pool
```

All heap allocated values are dropped and freed automatically when they go out of scope — ownership model guarantees this at compile time.

### Allocator model
Every heap allocation uses an allocator. Default allocator used transparently when no explicit choice made. No hidden allocations ever. All stdlib collections have an optional `.allocator` field.

### Built-in allocators
```
mem.DefaultAllocator    // general purpose, used automatically
mem.ArenaAllocator      // allocate freely, free everything at once
mem.PoolAllocator       // fixed size chunks, great for games
mem.StackAllocator      // LIFO allocation, very fast
```

No debug allocator needed — the ownership model makes runtime memory bugs impossible by design.

### Custom allocators
Built via the `mem.Allocator` interface.

---

## 29. Testing

Tests declared with the `test` keyword. Description string directly after `test` — no parentheses. Stripped from release builds automatically.

```
test"adds two numbers correctly" {
    var result: i32 = add(1, 2)
    @assert(result == 3)
    @assert(result == 3, "expected 3")
}
```

Run with `kodr test`.

---

## 30. Build System & CLI

Fully integrated into the compiler. No build files ever.

```
kodr build                  // debug build, native platform
kodr build -x64 -release    // 64-bit release build
kodr build -arm -fast       // ARM, max optimization
kodr build -wasm            // WebAssembly target
kodr run                    // build and run
kodr run -x64               // build and run for x64
kodr test                   // run all test blocks
kodr build -zig             // show raw Zig compiler output — for compiler developers only
kodr init <name>            // create a new project in ./<name>/
kodr initstd                // create std/ and global/ folders next to the kodr binary
kodr addtopath              // add kodr to PATH in your shell profile
kodr debug                  // dump project info: source dir, modules found, files
```

### Zig output suppression
Kodr fully controls what the user sees. The Zig compiler runs silently under the hood — its output is captured and never shown to the user under normal operation.

If Zig compilation succeeds — all Zig output is suppressed. The user only sees Kodr's own output.

If Zig compilation fails due to a codegen bug — Kodr reformats the error in its own clean format. Raw Zig errors are never shown unless `-zig` flag is explicitly passed.

```
// normal mode — user never sees Zig output
kodr build

// compiler developer mode — raw Zig output visible
kodr build -zig
```

In a correctly implemented compiler, Zig errors should never reach the user — all issues are caught by Kodr's analysis passes before code generation. The `-zig` flag exists purely for debugging the compiler itself during development.

### Generated Zig output — one file per module
Each Kodr module compiles to exactly one Zig source file. Kodr is essentially a transpiler — its entire job is producing a valid Zig project from Kodr source. Everything after that is Zig's responsibility.

```
.kodr source files
    ↓ Kodr compiler (all passes in memory)
.kodr-cache/generated/*.zig    ← Kodr's responsibility ends here
    ↓ Zig compiler
zig-cache/                     ← Zig's responsibility (object files, binary)
    ↓
final binary
```

Kodr never deals with object files — that is entirely Zig's concern. Zig has its own cache (`zig-cache/`) where it manages compiled objects and incremental compilation at the binary level.

All generated files live in `.kodr-cache/generated/` and should never be edited manually.

```
bin/
    <project_name>       // final binary — named from main.name metadata, or module name

.kodr-cache/
    generated/
        math.zig        // generated from module math
        player.zig      // generated from module player
        utils.zig       // generated from module utils
        main.zig        // generated from module main
        build.zig       // generated Zig build file
    timestamps          // flat text — maps .kodr files to last modification time
    deps.graph          // flat text — module dependency graph
```

`timestamps` format:
```
src/player.kodr 1710234567
src/utils.kodr  1710234123
main.kodr       1710234890
```

`deps.graph` format:
```
main → player, math, utils
player → math
math →
utils →
```

Both are plain text — human readable, easy to delete, never committed to version control. `.kodr-cache` belongs in `.gitignore`.

Example generated `math.zig`:
```zig
// generated from module math — do not edit
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn divide(a: i32, b: i32) i32 {
    if (b == 0) { /* error handling */ }
    return @divTrunc(a, b);
}
```

Example generated `main.zig`:
```zig
// generated from module main — do not edit
const std = @import("std");
const math = @import("math.zig");
const player = @import("player.zig");

pub fn main() void {
    const result = math.divide(10, 2);
}
```

### Incremental compilation
Checked at Module Resolution — unchanged modules skip all passes and reuse cached `.zig` files. Works at two levels:
- **Kodr level** — unchanged modules skip passes 4-12 entirely, cached `.zig` file reused
- **Zig level** — Zig's own incremental compilation handles object files and binary caching independently
- Only changed modules and their dependents regenerate `.zig` files
- Kodr cache stored in `.kodr-cache/`, Zig cache in `zig-cache/` — separate concerns, no overlap

---

## 31. Zig Bridge — `extern func` and paired `.zig` files

Kodr handles all external interop through Zig. Kodr never talks to C, system APIs,
or external libraries directly — that complexity always lives in a paired `.zig` file.
Zig already has first-class C interop, handles ABI, calling conventions, and struct
layouts. No need to duplicate that work in Kodr.

### How it works

A Kodr module can be paired with a hand-written `.zig` file that provides the actual
implementation. The `.kodr` file declares the public interface using `extern func`.
The compiler emits nothing for `extern func` bodies — it uses the paired `.zig` directly.

```
// zigstd.kodr — public Kodr interface
module zigstd

pub extern func print(msg: string) void
pub extern func println(msg: string) void
```

```zig
// zigstd.zig — hand-written Zig implementation
const std = @import("std");

pub fn print(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

pub fn println(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
}
```

```
// usage in any Kodr file
import std::zigstd

func main() void {
    zigstd.print("hello kodr !\n")
}
```

### `extern func` rules
- `extern func` has a signature but no body — hard compiler error if body is present
- Must be `pub` — extern functions are always part of a module's public interface
- The paired `.zig` file must exist alongside the `.kodr` file — hard compiler error if missing
- The `.zig` function signature must match the Kodr declaration — mismatch is a Zig compile error

### Calling C through Zig
C interop goes through `.zig` bridge files. The `.kodr` file exposes a clean Kodr API,
the `.zig` file handles all C details internally:

```zig
// gtk.zig — Zig handles all C interop
const c = @cImport(@cInclude("gtk4.h"));

pub fn windowNew() *c.GtkWidget {
    return c.gtk_window_new();
}
```

```
// gtk.kodr — clean Kodr interface, no C visible
module gtk

pub extern func windowNew() Ptr(u8)
```

```
// usage
import global::gtk

var window = gtk.windowNew()
```

### Naming convention
Zig bridge files use the `zig` prefix to signal they are bridges, not native Kodr:
- `zigstd.kodr` / `zigstd.zig` — Zig stdlib bridge
- `zigmath.kodr` / `zigmath.zig` — Zig math bridge
- `zigallocator.kodr` / `zigallocator.zig` — Zig allocator bridge

Third-party C libraries use descriptive names without the prefix:
- `gtk.kodr` / `gtk.zig`
- `sdl.kodr` / `sdl.zig`
- `vulkan.kodr` / `vulkan.zig`

---

## 32. Style Guide

Naming conventions are never enforced by the compiler — style is up to the programmer. However the following guidelines are used for all official Kodr code including the standard library. Following them is recommended for consistency across the ecosystem.

### Naming conventions

```
// types — PascalCase
// structs, enums, tuples, unions
struct PlayerHealth { }
enum Direction(u32) { }
const Point = (x: f32, y: f32)
const MyUnion = (i32 | f32)

// functions — camelCase
func takeDamage() void { }
func isAlive() bool { }

// variables and constants — camelCase
var playerHealth: f32 = 100.0
const maxPlayers: i32 = 64

// compt constants — SCREAMING_SNAKE_CASE
compt MAX_PLAYERS: i32 = 64
compt PI: f32 = 3.14159

// modules — lowercase, no separators, keep short
module mathutils
module playerphysics

// enum variants — PascalCase
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum variants — PascalCase
enum Permissions(u32, bitfield) {
    Read
    Write
    Execute
}

// error constants — PascalCase with Err prefix
const ErrNotFound: Error = Error("not found")
const ErrDivByZero: Error = Error("division by zero")
```

### Reasoning
- `PascalCase` for types — universally understood, immediately signals "this is a type"
- `camelCase` for functions and variables — clean, minimal, widely used
- `SCREAMING_SNAKE_CASE` for compt constants — signals compile time constant, universally understood
- `lowercase` for modules — clean, no separators, module names should be short and descriptive
- `Err` prefix for error constants — immediately signals what it is at the call site

---

## 33. Complete Example

This example covers the entire Kodr language. Read it as a short tutorial.

```
module main

main.build = build.exe
main.version = Version(1, 0, 0)
main.name = "example"
main.description = "Kodr language tour"

import std.console              // access via console.*
import std.math.linear as lin   // access via lin.*

// --- NUMERIC LITERALS ---
compt HEX_COLOR: u32 = 0xFF_AA_00
compt MAX_HEALTH: f32 = 100.0
compt BIG_NUMBER: i64 = 1_000_000

// --- COMPT TYPE GENERATION ---
// compt function generates a type at compile time
const Vec2f = lin.Vec2(f32)    // compt resolved, zero runtime cost

// generic function — any resolved at compile time
func identity(val: any) any {
    return val
}

// compt function returning a type
compt func Pair(A: any, B: any) type {
    return struct {
        first: A
        second: B
    }
}

// --- ENUMS ---
// regular enum with explicit backing type
enum Direction(u32) {
    North
    South
    East
    West
}

// bitfield enum — compiler assigns powers of 2
enum Permissions(u32, bitfield) {
    Read      // 0b0001
    Write     // 0b0010
    Execute   // 0b0100
}

// data carrying enum with method
enum Shape(u32) {
    Circle(radius: f32)
    Rectangle(width: f32, height: f32)
    Point

    func area(self: const &Shape) f32 {
        match self {
            Circle    => { return 3.14 * Circle.radius * Circle.radius }
            Rectangle => { return Rectangle.width * Rectangle.height }
            Point     => { return 0.0 }
        }
    }
}

// --- STRUCTS ---
struct Player {
    pub name: string
    health: f32 = MAX_HEALTH    // compt constant as default
    score: i32 = 0
    position: Vec2f = Vec2f(x: 0.0, y: 0.0)

    const maxPlayers: i32 = 64   // static const
    var activeCount: i32 = 0     // static var

    func create(name: string) Player {
        Player.activeCount = Player.activeCount + 1
        return Player(name: name)    // all other fields use defaults
    }

    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    func takeDamage(self: var &Player, amount: f32) void {
        self.health = self.health - amount
    }

    func destroy(self: Player) void {
        Player.activeCount = Player.activeCount - 1
        // player dropped here
    }
}

// --- TUPLES ---
const MinMax = (min: i32, max: i32)

func findMinMax(arr: []i32) MinMax {
    return MinMax(min: arr[0], max: arr[arr.len - 1])
}

// --- ERROR HANDLING ---
const ErrDivByZero: Error = Error("ERROR: division by zero")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

// null handling
func findPlayer(id: i32) (null | Player) {
    if(id < 0) {
        return null
    }
    return Player.create("found")
}

// recursive function
func fibonacci(n: i32) i32 {
    if(n <= 1) { return n }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

// first class function
const Transform = func(i32) i32

func double(x: i32) i32 {
    return x * 2
}

func applyToAll(arr: []i32, f: Transform) void {
    for(arr) |val| {
        console.print(f(val))
    }
}

func main() void {

    // --- VARIABLES ---
    var x: i32 = 42                    // explicit type — numeric literal
    var name = "hello\nworld"          // inferred — string literal with escape
    var flag = true                    // inferred — bool literal
    const pi: f32 = 3.141_592          // explicit — numeric literal
    compt SIZE: usize = 1_024          // compile time constant

    // --- STRUCT USAGE ---
    var p = Player.create("hero")
    p.takeDamage(10.0)

    if(p.isAlive()) {
        console.print(p.name)
    }

    // --- ENUM USAGE ---
    var d: Direction = North
    match d {
        North => { console.print("going north") }
        South => { console.print("going south") }
        East  => { console.print("going east") }
        West  => { console.print("going west") }
    }

    // --- BITFIELD ENUM ---
    var perms: Permissions = Read | Write
    perms.set(Execute)
    console.print(perms.has(Read))     // true
    perms.clear(Write)
    perms.toggle(Execute)

    // --- DATA CARRYING ENUM ---
    var s: Shape = Circle(radius: 5.0)
    console.print(s.area())

    // type matching
    match @type(s) {
        Shape => { console.print("its a shape") }
        _     => { }
    }

    // --- ERROR HANDLING ---
    var result = divide(10, 2)
    if(@type(result) == Error) {    // @type returns actual type, not string
        if(result.Error == ErrDivByZero) {
            console.print("division by zero")
        }
        return
    }
    console.print(result.i32)

    // --- NULL HANDLING ---
    var found = findPlayer(1)
    if(@type(found) == null) {
        console.print("not found")
        return
    }
    console.print(found.Player.name)

    // --- TUPLES ---
    var min, max = findMinMax([3, 1, 4, 1, 5, 9, 2, 6])
    console.print(min)
    console.print(max)

    // --- COMPT PAIR TYPE ---
    var pair: Pair(i32, string) = Pair(i32, string)(first: 42, second: "hello")
    console.print(pair.first)

    // --- LOOPS ---
    for(0..5) |i| {
        console.print(i)
    }

    for([1, 2, 3, 4, 5], 0..) |val, idx| {
        console.print(val)
        console.print(idx)
    }

    var i: i32 = 0
    while(i < 10) : (i += 1) {
        if(i == 5) { continue }
        console.print(i)
    }

    // labeled break
    label outerLoop
    for([1, 2, 3]) |a| {
        for([4, 5, 6]) |b| {
            if(a == 2 and b == 5) {
                break outerLoop
            }
        }
    }

    // --- FIRST CLASS FUNCTIONS ---
    applyToAll([1, 2, 3, 4, 5], double)

    // --- RECURSION ---
    console.print(fibonacci(10))

    // --- COMPILER FUNCTIONS ---
    console.print(@size(Player))       // size in bytes
    console.print(@align(f64))        // alignment in bytes
    console.print(@typename(p))       // "Player"
    console.print(@typeid(p))         // unique integer ID

    // --- THREADING ---
    var data: []i32 = [1, 2, 3, 4, 5, 6]
    var left, right = data.splitAt(3)

    Thread([]i32) thread_a { return left }
    Thread([]i32) thread_b { return right }

    var leftResult: []i32 = thread_a.value
    var rightResult: []i32 = thread_b.value

    // async IO
    Async(string) my_request {
        return "fetched data"
    }
    var response = my_request.value

    // --- POINTERS ---
    var val: i32 = 10
    var ptr = Ptr(i32, &val)
    console.print(ptr.valid)           // true
    console.print(ptr.value)           // 10

    // --- DEFER ---
    defer { console.print("cleanup") }
    console.print("before cleanup")
    // "cleanup" prints at end of scope

    // --- OVERFLOW ---
    var big: i32 = 2_147_483_647
    var wrapped = wrap(big + 1)        // wraps to minimum
    var saturated = sat(big + 1)       // stays at maximum
    var safe = overflow(big + 1)       // returns (Error | i32)
    if(@type(safe) == Error) {
        console.print("overflow detected")
    }
}

test"player takes damage correctly" {
    var p = Player.create("test")
    p.takeDamage(50.0)
    @assert(p.health == 50.0)
    @assert(p.isAlive())
}

test"divide returns error on zero" {
    var result = divide(10, 0)
    @assert(@type(result) == Error)
    @assert(result.Error == ErrDivByZero)
}

test"fibonacci is correct" {
    @assert(fibonacci(0) == 0)
    @assert(fibonacci(1) == 1)
    @assert(fibonacci(10) == 55)
}
```
