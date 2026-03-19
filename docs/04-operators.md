# Operators

## Arithmetic
```
a + b    // add (numeric and tuples only, never strings/arrays)
a - b    // subtract
a * b    // multiply
a / b    // divide
a % b    // modulo
a ++ b   // concatenation (strings and arrays only, never numeric)
```

## Value Comparison — compares the value
```
a == b    // equal
a != b    // not equal
a < b     // less than
a > b     // greater than
a <= b    // less than or equal
a >= b    // greater than or equal
```

## Type Comparison — compares the type, not the value
```
a is T        // true if a is of type T
a is not T    // true if a is not of type T
```
Used with union types, `Error`, and `null`. No overlap with value comparison — explicit by design.

## Boolean Logic
```
a and b    // logical AND
a or b     // logical OR
not a      // logical NOT
```

## Bitwise
```
a & b     // AND
a | b     // OR
a ^ b     // XOR
!a        // NOT
a >> 2    // right shift
a << 2    // left shift
```

## Tuple Math
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

## String and Array Concatenation
`++` is the concatenation operator — distinct from `+` (arithmetic). Never user-defined. Compiler error if types don't match. Using `+` on strings or `++` on numbers is a compile error.
```
var s: string = "hello " ++ "world"    // string concatenation
var a: []i32 = [1, 2] ++ [3, 4]       // array concatenation, types must match
```

## No Implicit Numeric Casts
Mixing numeric types in expressions is a compile error. All conversions must be explicit via `@cast(T, x)`.
```
var x: i32 = 42
var f: f32 = 3.14
var z = x + f                // ERROR — i32 + f32, types don't match
var z = @cast(f32, x) + f    // OK — explicit cast
```

---

## Integer Overflow

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
