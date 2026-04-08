# Variables

Two mutability levels:

```
var x: i32 = 5      // mutable, runtime
const y: i32 = 10   // immutable, runtime
```

- `var` — mutable, runtime. Can be reassigned.
- `const` — immutable, runtime. Cannot be reassigned. If the value comes from a `compt func`, the compiler evaluates it at compile time automatically.

Module-level declarations must be `const` — mutable state lives inside functions. This eliminates shared mutable state and prevents data races by design.

For compile-time computation, use a `compt func` and assign the result to a `const`:
```
compt func bufferSize() i32 { return 1024 }

const BUFFER_SIZE: i32 = bufferSize()   // evaluated at compile time
```

All variables must be initialized at declaration — no uninitialized state. If a value is not yet known, use a `(null | T)` union:
```
var user: (null | User) = null     // explicitly "not set yet"
```

Module-level `const` declarations can be exported with `pub`:
```
pub const MAX_SIZE: i32 = 1024
```

---

## Type Annotation — optional when unambiguous

Type annotation can be omitted when the right hand side unambiguously determines the type. If there is any ambiguity — the type must be explicit.

```
// type can be omitted — unambiguous
var name = "hello"                  // clearly str
var p = Player.create("hero")       // clearly Player
var s = Player{name: "hero"}        // clearly Player
var flag = true                     // clearly bool
var result = divide(10, 2)          // clearly (Error | i32)
var a: i32 = 5
var b = a                           // clearly i32, inferred from a

// numeric literals — explicit type required
var x: i32 = 42
var f: f32 = 3.14
var b: u8 = 255
```

**The rule:** function calls, struct instantiation, enum variants, `str` literals, bool literals, and other variables — type can be inferred. Numeric literals — must have an explicit type annotation.

---

## Destructuring

Multiple variables can be declared from a single function call that returns a named tuple. Both `const` and `var` work:

```
const min, max = min_max(1, 9)   // names must match tuple field names
var left, right = split_data()
```

The right-hand side must return a named tuple (struct with matching field names). Each variable binds to the corresponding field by name.

---

## Type Aliases

A `const` with `: type` annotation declares a type alias — a new name for an existing type. Works both at module level and inside functions:

```
// module level
const Point: type = {x: f32, y: f32}
const MinMax: type = {min: i32, max: i32}

// inside a function
func inspect(x: i32) void {
    const T: type = @typeOf(x)
}
```

---

## Move and Copy Semantics

Variable assignment follows ownership rules:

- **Primitives** (`i32`, `f32`, `bool`, `u8`, etc.) and `str` — always copy. Safe to use after assignment.
- **Structs and other non-primitive types** — move by default. After assignment, the original is no longer usable.
- **`const` values** — implicitly copyable, never moved.

```
var a: i32 = 5
var b = a           // copy — a is still valid

var s = Player{name: "hero"}
var t = s           // move — s is no longer valid after this
```

Use `@copy` to explicitly copy a non-primitive type. Use `const&` or `mut&` to borrow without transferring ownership.

---

## Compiler Warning — unused mutability

If a `var` is never reassigned, the compiler emits a warning and uses `const` in the generated Zig:

```
var x: i32 = 5   // warning: 'x' is declared as var but never reassigned — use const
```
