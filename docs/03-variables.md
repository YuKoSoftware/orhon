# Variables

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

---

## Type Annotation — optional when unambiguous

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
