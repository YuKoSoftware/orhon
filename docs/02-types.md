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

## Type System

### Type annotation
Explicit when ambiguous, optional when unambiguous. See the variables doc for full rules. Numeric literals resolve to `main.bitsize` default or require an explicit type.

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

// splitAt uses tuple destructuring
var left, right = data.splitAt(3)

// hard compiler error if variable count doesn't match field count
var a, b, c = minMax(arr)    // error — MinMax only has 2 fields
```
