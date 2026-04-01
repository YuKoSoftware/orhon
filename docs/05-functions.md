# Functions

## Declaration
```
func add(a: i32, b: i32) i32 {
    return a + b
}

func log(msg: String) void {
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

`compt` marks a function for compile-time evaluation. The entire body runs during
compilation — nothing from the function exists at runtime. Two main uses: generating
types and computing constant values.

### Type-generating `compt` — returns `type`

When a `compt` function returns `type`, it generates a new struct, enum, or other type
at compile time. The `type` keyword in the return position signals this:

```
compt func Vec2(T: type) type {
    return struct {
        x: T
        y: T
    }
}

compt func Pair(A: type, B: type) type {
    return struct {
        first: A
        second: B
    }
}

var pos: Vec2(f32) = Vec2(f32)(x: 1.0, y: 2.0)
var p: Pair(i32, String) = Pair(i32, String)(first: 42, second: "hello")
```

Type-generating `compt` functions map to Zig's `comptime` functions. Each unique set
of type arguments produces a distinct concrete type.

### Value-computing `compt` — returns a value

When a `compt` function returns a regular type (not `type`), it computes a constant
value at compile time. Maps to Zig `inline fn`:

```
compt func doubled(n: i32) i32 {
    return n * 2
}

const result: i32 = doubled(21)    // 42 — computed at compile time
```

### `compt` with `any` parameters

`any` in a `compt` parameter position means the function works with multiple types.
The compiler generates a specialized version for each concrete type used:

```
compt func describe(val: any) String {
    if(val is i32) { return "integer" }
    if(val is f32) { return "float" }
    return "unknown"
}
```

### `compt for` — compile-time loop unrolling

`compt for` unrolls the loop at compile time. Each iteration becomes separate code
in the output:

```
compt for(fields) |field| {
    // each iteration is a separate block in the generated code
}
```

### Rules

- `compt` functions can call other functions (Zig's comptime allows this)
- `compt` functions with `T: type` parameters require the type to be known at compile time
- `compt` functions returning `type` cannot be called at runtime — types don't exist at runtime
- `compt` is a function-level modifier, not a block-level one — the entire function is compile-time
- `compt` variables at module level (`compt const X = ...`) are compile-time constants


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
For callback patterns, pass context as extra arguments or wrap state in a [[10-structs-enums|struct]].

---

## Compiler Functions

Compiler functions are reserved keywords that look like function calls. Zero runtime cost — they disappear entirely in the output binary. Cannot be shadowed or redefined by user code.

```
@typename(x)             // returns the type name as a String — usable for display
@typeid(x)               // returns unique compiler assigned integer ID — fast identity check
@cast(T, x)              // converts x to target type T — always explicit
@copy(x)                 // explicitly copies a non-primitive, original stays valid
@move(x)                 // explicitly moves a value, original becomes invalid
@swap(x, y)              // swaps ownership between two variables
@assert(x)               // assertion, checked at compile time or test time
@assert(x, "message")    // with custom failure message
@size(x)                 // returns size of type or value in bytes
@align(x)                // returns alignment requirement of type or value in bytes
@hasField(T, "name")     // true if struct T has a field named "name"
@hasDecl(T, "name")      // true if type T has a declaration (method, const) named "name"
@fieldType(T, "name")    // returns the type of field "name" on struct T
@fieldNames(T)           // returns comptime slice of all field names on struct T
```

### `@typename` — type name as `String`
Returns the name of the type as a `String`. Useful for debugging, logging, and serialization. Cannot be used in type positions.
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

### `@typeOf` — first-class type value
Returns the actual type of a value as a compile-time `type`. Can be stored in a `const` or passed to functions.
```
const x: i32 = 42
const T: type = @typeOf(x)    // T is i32
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
Returns the alignment requirement of a type or value in bytes. Essential for custom [[09-memory#Memory Allocation|allocators]], [[14-zig-bridge|C interop]], hardware access, and SIMD operations.
```
@align(i32)         // 4 — must be on a 4 byte boundary
@align(f64)         // 8
@align(MyStruct)    // largest alignment of any field in the struct
```

### `@hasField` — struct field check
Returns `true` if the struct type has a field with the given name. Works with types and values. Compile-time evaluation — zero runtime cost.
```
@hasField(Point, "x")       // true
@hasField(Point, "z")       // false
@hasField(my_point, "x")    // true — value is auto-wrapped in typeOf
```

### `@hasDecl` — declaration check
Returns `true` if the type has any declaration (method, compt function, constant) with the given name. Useful for conditional logic based on type capabilities.
```
@hasDecl(Counter, "create")     // true — Counter has a create method
@hasDecl(Vec2, "nonexistent")   // false
```

### `@fieldType` — field type extraction
Returns the compile-time `type` of a named field on a struct. Can be stored in a `const` or used in compt code for type-level programming.
```
const XType: type = @fieldType(Point, "x")   // f32
```

### `@fieldNames` — all field names
Returns a compile-time slice of all field names on a struct. Primary use: iterating fields in compt for-loops for auto-derive patterns.
```
compt for(@fieldNames(Point)) |name| {
    // name is a comptime string: "x", "y"
}
```

---

## Builtin Functions & Values

Always available without any import. Have a real runtime presence — produce actual code in the output binary.

### Error
`Error` is a distinct `String` type (see [[08-error-handling]]). An error is just a message — the `String` carries all the information needed to trace and fix the problem. Can be created inline or stored as a named constant for reuse.

```
// inline
Error("division by zero")

// named constant for reuse — no type annotation needed
const ErrDivByZero = Error("division by zero")
const ErrNotFound = Error("file not found")

// usage
func divide(a: i32, b: i32) ErrorUnion(i32) {
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
A named tuple of three `u32` values following semantic versioning — major, minor, patch.
String versions are never allowed — hard compiler error. Used in `#version` and `#dep` metadata:
```
Version(major: u32, minor: u32, patch: u32)
```

```
#version = Version(1, 0, 0)
#dep "./libs/mylib" Version(2, 0, 0)   // minimum version — warn if newer, error if older
#dep "./libs/utils"                     // no version constraint
```

`Version` is a compiler-known builtin — no import needed.
