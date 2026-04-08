# Error & Null Handling

## Error Handling

Functions that can fail return an `(Error | T)` union type. No exceptions, no monads — just a union and a type check. Errors map directly to native Zig error codes (see [[14-zig-bridge#Type Mapping|Zig mapping]]). If unhandled before scope exit, the compiler rejects the code.

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
var value: i32 = result.i32        // safe — Error case eliminated
```

Inline errors are fine for one-off cases:
```
func readFile(path: str) (Error | str) {
    return Error("could not open file")
}
```

**Note:** `result.Error` returns the error name as a string. The message is sanitized
to an identifier (spaces become underscores): `Error("division by zero")` produces
`"division_by_zero"`.

### Union Unwrap

After narrowing a union with `is` + early exit, access the remaining value by its type name:

```
const result: (Error | i32) = divide(10, 2)
if(result is Error) { return 0 }
return result.i32                  // type name access — compiler knows it's i32
```

`.value` is a universal unwrap that works for all union types and is the required syntax
for `(null | Error | T)` after both cases are eliminated:

```
const result: (null | Error | i32) = fetch(id)
if(result is null) { return 0 }
if(result is Error) { return 0 }
return result.value                // .value — only safe syntax after dual narrowing
```

Using either syntax without prior narrowing is a compile error:
```
const result: (Error | i32) = divide(10, 2)
return result.i32                  // ERROR: unsafe unwrap
```

### Exhaustive Match

`match` on a union type must cover all members or include `else`:

```
match(result) {
    Error => { console.print(result.Error) }
    i32   => { var value: i32 = result.i32 }
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

## Error Propagation

To propagate an error up the call stack, check for the error and return it:

```
func divide_or_propagate(a: i32, b: i32) (Error | i32) {
    const result = safe_divide(a, b)
    if(result is Error) {
        return result
    }
    return result.i32
}
```

The enclosing function must return an error union type (`(Error | T)`) for propagation to work. If no function in the call stack handles the error, it reaches `main` and the program crashes with the error message.

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
var user: User = result.User       // safe — null case eliminated
```

Or with `match`:
```
match(result) {
    null => { return }
    User => { var user: User = result.User }
}
```

---

## Null Error Union — `(null | Error | T)`

A value can be null, an error, or a valid value. Maps to Zig's `?anyerror!T`.

```
func fetch(url: str) (null | Error | str) {
    if(url.len == 0) { return null }
    if(url == "bad") { return Error("invalid url") }
    return "response"
}
```

All the same operators work — `is null`, `is Error`, `.value`, `.Error`, and `match`:

```
const result: (null | Error | str) = fetch(url)
if(result is null) { return }
if(result is Error) { return }
const body: str = result.value
```

Match handles all three cases:

```
match(result) {
    null  => { console.println("nothing") }
    Error => { console.println("failed") }
    else  => { console.println("got response") }
}
```

---

## Zig Mapping

| Orhon | Zig |
|-------|-----|
| `(Error \| T)` | `anyerror!T` |
| `(null \| T)` | `?T` |
| `(null \| Error \| T)` | `?anyerror!T` |
| `Error("message")` | `error.message_sanitized` |
| `null` | `null` |
| `result.TypeName` (error union) | `result catch unreachable` |
| `result.TypeName` (null union) | `result.?` |
| `result.value` (any union) | same as `result.TypeName` — universal form |
| `result.value` (null error union) | `result.? catch unreachable` |
| `result.Error` | `@errorName(err)` |
| `result is Error` | `if (result) false else true` |
| `result is null` | `result == null` |
