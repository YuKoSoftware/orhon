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

`is` can only appear in `if` and `elif` conditions — it is a narrowing construct, not a general operator. Compound `is` with `and`/`or` is not supported. For type checks outside if/elif, use `@typeOf(x) == T`. See [[07-control-flow#Type Narrowing]].

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
const Vec2: type = {x: f32, y: f32}
var a = Vec2{x: 1.0, y: 2.0}
var b = Vec2{x: 3.0, y: 4.0}
var c = a + b              // Vec2{x: 4.0, y: 6.0}
var d = a * b              // Vec2{x: 3.0, y: 8.0}
```

**Tuple op Scalar** — applies scalar to every field:
```
var doubled = a * 2.0      // Vec2{x: 2.0, y: 4.0}
var half = a / 2.0         // Vec2{x: 0.5, y: 1.0}
```

**Scalar op Tuple** — commutative:
```
var scaled = 3.0 * a       // Vec2{x: 3.0, y: 6.0}
```

Compiler error if any tuple field is non-numeric, or if tuple shapes don't match.

## String and Array Concatenation
`++` is the concatenation operator — distinct from `+` (arithmetic). Never user-defined. Compiler error if types don't match. Using `+` on strings or `++` on numbers is a compile error.
```
var s: str = "hello " ++ "world"    // str concatenation
var a: []i32 = [1, 2] ++ [3, 4]       // array concatenation, types must match
```

## Compound Assignment
```
a += b    // add and assign
a -= b    // subtract and assign
a *= b    // multiply and assign
a /= b    // divide and assign
```
Shorthand for `a = a op b`. Same type rules as the corresponding binary operator — no implicit casts.

## No Implicit Numeric Casts
Mixing numeric types in binary expressions is a compile error. This applies to all binary operators — arithmetic (`+`, `-`, `*`, `/`, `%`), comparison (`<`, `>`, `==`, etc.), and bitwise (`&`, `|`, `^`). Consistency: no special cases, one rule for all operators.

All conversions must be explicit via `@cast(T, x)` (see [[05-functions#Compiler Functions]]).
```
var x: i32 = 42
var y: i64 = 100
var f: f32 = 3.14
var z = x + f                // ERROR — i32 + f32
var z = x + y                // ERROR — i32 + i64
var z = x < y                // ERROR — comparison across types too
var z = @cast(f32, x) + f    // OK — explicit cast
var z = @cast(i64, x) + y    // OK — explicit cast
```

**Numeric literals coerce freely** — literal values like `1`, `3.14` adapt to the target type automatically (matching Zig's comptime coercion). No cast needed:
```
var x: i32 = 42
var y = x + 1                // OK — 1 coerces to i32
var f: f64 = 3.14 + 1.0     // OK — literals coerce to f64
```

**Assignment and argument widening is allowed** — when the target type is known (variable declaration, function argument), same-family widening works without `@cast`. This matches Zig's integer widening coercion at assignment sites:
```
var x: i32 = 42
var y: i64 = x               // OK — i32 widens to i64 at assignment
func takes_big(n: i64) void { }
takes_big(x)                  // OK — i32 widens to i64 at call site
```

**For-loop range indices are `usize`** — this is the native range counter type in Zig. Use `@cast` when mixing with other integer types:
```
for(0..10) |i| {
    var n: i32 = @cast(i32, i)   // i is usize, cast to i32
}
```

**`arr.len` is `usize`** — mixing with other integer types requires `@cast`:
```
var arr: []i32 = [1, 2, 3]
var n: i32 = @cast(i32, arr.len)  // explicit cast from usize
```

---

## Integer Overflow

Silent wrap around by default. Use explicit builtins when you need controlled behavior. All are builtin functions — no import needed.

```
@overflow(a + b)    // returns (Error | T) if overflow occurs — handle or propagate (see [[08-error-handling]])
@wrap(a + b)        // explicitly wraps around, documents intent, always succeeds
@sat(a + b)         // saturating arithmetic, clamps to max/min value, always succeeds
```

```
// @overflow — returns union, must be handled
var result = @overflow(a + b)
if(result is Error) {
    console.print("overflow occurred")
    return
}
var value: i32 = result.i32

// @wrap — always succeeds, explicit intent
var x: i32 = @wrap(maxInt + 1)    // wraps to minimum value

// @sat — always succeeds, clamps
var x: i32 = @sat(maxInt + 1)     // stays at maximum value
```
