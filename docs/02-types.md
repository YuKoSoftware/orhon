# Types

## Primitive Types

```
i8, i16, i32, i64, i128           // signed integers
u8, u16, u32, u64, u128           // unsigned integers
isize, usize                      // platform-native size, pointer sizes and indexing
f16, bf16, f32, f64, f128         // floating point
                                  // f16  — half precision, graphics and AI inference
                                  // bf16 — bfloat16, AI training
                                  // f128 — maps to C long double
bool                              // true or false
String                            // immutable text — shorthand for []const u8
                                  // always copies (cheap — just a pointer + length, 16 bytes)
                                  // for mutable byte manipulation, use []u8
```

`String` is a higher-level type. Under the hood it is `[]const u8` — an immutable slice. Copying a `String` copies the pointer, not the data, so it is always cheap. For mutable byte buffers, use `[]u8` which follows normal move semantics.

`u8` doubles as a byte and character type — interpreted based on usage context.

---

## String Literals & Escape Sequences

`String` literals are enclosed in double quotes. Escape sequences follow universal convention:

```
"hello world"       // basic string
"hello\nworld"     // newline
"hello\tworld"     // tab
"say \"hi\""      // escaped quote
"back\\slash"     // escaped backslash
"null\0term"       // null terminator
"carriage\rreturn" // carriage return
```

Multiline strings use `\n` — no special multiline syntax needed. `String` is immutable `[]const u8` under the hood.

### String Interpolation

Embed expressions inside strings with `@{expr}`. Any expression that can be formatted
is valid inside the braces:

```
const name: String = "world"
const greeting: String = "hello @{name}!"     // "hello world!"

const x: i32 = 42
const msg: String = "value is @{x}"           // "value is 42"

const a: i32 = 3
const b: i32 = 7
const calc: String = "@{a} + @{b} = @{a + b}" // "3 + 7 = 10"
```

**How it works:**
- `@{expr}` is recognized inside any string literal by the lexer
- The compiler generates `std.fmt.allocPrint` with format specifiers derived from
  the expression types (`{s}` for strings, `{d}` for integers, `{d:.N}` for floats)
- Memory is automatically managed — the compiler emits a `defer free` for each
  interpolated string to prevent leaks
- Multiple `@{...}` segments in one string are combined into a single `allocPrint` call

**Supported expression types:**
- `String` / `[]const u8` — inserted as-is
- Integer types (`i32`, `u64`, etc.) — formatted as decimal
- Float types (`f32`, `f64`, etc.) — formatted as decimal
- Any expression that evaluates to one of the above

**Not supported:** Arbitrary method calls or complex expressions inside `@{...}` should
be assigned to a variable first for clarity.

---

## Numeric Literals

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

Numeric literals always require an explicit type annotation when used in variable declarations. The compiler does not infer a default integer or float size.

```
// explicit type required for numeric literals:
var x: i32 = 42
var f: f32 = 3.14
var y: i64 = 42
var g: f16 = 3.14
```

Underscore separators are ignored by the compiler, purely for human readability.

---

## Type System

### Type annotation
Explicit when ambiguous, optional when unambiguous. See [[03-variables]] for full rules. Numeric literals always require an explicit type.

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
compt func Box(T: type) type {
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
x is i32    // true
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

// hard compiler error if variable count doesn't match field count
var a, b, c = minMax(arr)    // error — MinMax only has 2 fields
```

---

## SIMD Vectors

`Vector(N, T)` is a fixed-size SIMD vector type. `N` is the lane count (any integer), `T` is the element type (any numeric primitive). Maps directly to hardware SIMD registers.

```
// declare vectors with array literal syntax
var v: Vector(4, f32) = [1.0, 2.0, 3.0, 4.0]
var w: Vector(4, f32) = [5.0, 6.0, 7.0, 8.0]

// arithmetic operators work element-wise
var sum = v + w        // [6.0, 8.0, 10.0, 12.0]
var diff = v - w
var prod = v * w
var quot = v / w

// scalar broadcast — scalar is expanded to fill all lanes
var scaled = v * 2.0   // [2.0, 4.0, 6.0, 8.0]

// any size and numeric element type
var wide: Vector(8, f32) = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
var ints: Vector(4, i32) = [1, 2, 3, 4]
var doubles: Vector(2, f64) = [1.0, 2.0]
```

Vectors have copy semantics — assigning or passing a vector always copies. For SIMD intrinsics (reduce, shuffle), use `import std::simd`.

---

## First-Class `type`

`type` is a keyword — it represents a type as a compile-time value. You can pass types as parameters, return them from functions, and store them in `const` variables.

```
// type as a parameter
compt func Box(T: type) type {
    return struct {
        value: T
    }
}

// store a type in a const
const IntBox = Box(i32)
const b = IntBox(value: 42)

// generic struct with type params
pub struct Pair(A: type, B: type) {
    pub first: A
    pub second: B
}
```

`type` is always resolved at compile time — it never exists at runtime. Use `typeOf(x)` to get the type of a value, `typename(x)` for a string name, and `typeid(x)` for a numeric identifier.
