# Error & Null Handling

## Error Handling

Functions that can fail return a [[02-types#Unions|union]] of `Error` and the success type. No exceptions, no monads — just a union and a type check. Errors map directly to native Zig error codes (see [[14-zig-bridge#Error Union Return Types|Zig mapping]]). If unhandled before scope exit, the compiler rejects the code.

```
const ErrDivByZero = Error("division by zero")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

var result: (Error | i32) = divide(10, 0)
if(result is Error) {
    console.print(result.Error)    // "division_by_zero"
    return
}
var value: i32 = result.value      // safe — Error case eliminated
```

Inline errors are fine for one-off cases:
```
func readFile(path: String) (Error | String) {
    return Error("could not open file")
}
```

**Note:** `result.Error` returns the error name as a string. The message is sanitized
to an identifier (spaces become underscores): `Error("division by zero")` produces
`"division_by_zero"`.

### Union Unwrap

After narrowing a union with `is` + early exit, use `.value` to access the remaining type:

```
const result: (Error | i32) = divide(10, 2)
if(result is Error) { return 0 }
return result.value                // compiler knows it's i32
```

Using `.value` without narrowing is a compile error:
```
const result: (Error | i32) = divide(10, 2)
return result.value                // ERROR: unsafe unwrap
```

### Exhaustive Match

`match` on a union type must cover all members or include `else`:

```
match(result) {
    Error => { console.print(result.Error) }
    i32   => { var value: i32 = result.value }
}

// or with else
match(result) {
    Error => { return 0 }
    else  => { return result.value }
}

// missing arm without else = compile error
match(result) {
    Error => { return 0 }
    // ERROR: non-exhaustive match — missing arm for 'i32'
}
```

---

## throw Statement

`throw` propagates an error union upward and narrows the variable's type in the remainder of the function. It is syntactic sugar for the common pattern of checking for an error and returning it early.

**Syntax:** `throw variable_name`

**Requirements:**
- `variable_name` must be of type `(Error | T)` — not a raw expression
- The enclosing function must return an error union type (`(Error | T)`)

**Semantics:** If the variable holds an error, the function returns it immediately. If it holds a value, execution continues and the variable is narrowed to `T` (no `.value` needed afterward).

```
// without throw
func divide_manual(a: i32, b: i32) (Error | i32) {
    const result = safe_divide(a, b)
    if(result is Error) {
        return result
    }
    return result.value
}

// with throw
func divide_with_throw(a: i32, b: i32) (Error | i32) {
    var result = safe_divide(a, b)
    throw result        // early return on error; result is now i32
    return result       // .value not needed — type is narrowed
}
```

**Note:** `throw` only works on named variables (not inline expressions). This keeps control flow explicit and visible.

---

## Null Handling

Absence of a value expressed through a union with `null`. `null` is never a standalone value — it only exists inside a union type. Maps directly to native Zig optionals (`?T`).

The same scope-based rule as error handling applies — a `(null | T)` union must be handled before leaving scope. If not handled, the compiler rejects the code.

```
func find(id: i32) (null | User) {
    // ...
}

// must handle before scope exit
var result: (null | User) = find(42)
if(result is null) {
    return
}
var user: User = result.value      // safe — null case eliminated
```

Or with `match`:
```
match(result) {
    null => { return }
    User => { var user: User = result.value }
}
```

---

## Zig Mapping

| Orhon | Zig |
|-------|-----|
| `(Error \| T)` | `anyerror!T` |
| `(null \| T)` | `?T` |
| `Error("message")` | `error.message_sanitized` |
| `null` | `null` |
| `result.value` (error union) | `result catch unreachable` |
| `result.value` (null union) | `result.?` |
| `result.Error` | `@errorName(err)` |
| `result is Error` | `if (result) false else true` |
| `result is null` | `result == null` |
