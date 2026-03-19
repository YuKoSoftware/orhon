# Functions

## Declaration
```
func add(a: i32, b: i32) i32 {
    return a + b
}

func log(msg: string) void {
    // returns nothing
}
```

## First Class Functions
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

## `compt` Functions
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

## `compt for` — Compile-time Loop Unrolling
`compt for` unrolls a loop at compile time. Maps to Zig's `inline for`. Used for generating code per type or per item in a compile-time known collection.
```
compt for(types) |T| {
    // generates code per type at compile time
}
```
If you need compile-time logic inside a runtime function, extract it into a `compt func` and call it — no inline `compt` blocks or expressions.

## No Function Overloading
Every function has a unique name. No ambiguity, no compiler complexity.

## No Closures
Context is always passed explicitly as function arguments. No captured variables. For most use cases, loops with inner scope access cover the need:
```
var multiplier: i32 = 5
for(arr) |val| {
    result = val * multiplier    // inner scope reads outer variable
}
```
For callback patterns, pass context as extra arguments or wrap state in a struct.

---

## Compiler Functions

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

For type comparison, use the `is` / `is not` keywords — see the operators doc:
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

## Builtin Functions & Values

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

### Special values
`null`, `true`, `false`, and `void` are keywords. Listed here for reference:
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
