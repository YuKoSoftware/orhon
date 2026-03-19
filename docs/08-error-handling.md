# Error & Null Handling

## Error Handling

Functions that can fail return a union of `Error` and the success type. No exceptions, no monads — just a union and a type check. An error is a message string with a distinct type. If unhandled before scope exit, the program crashes and prints the message. That crash is the signal — the programmer sees exactly what went wrong and where.

```
const ErrDivByZero = Error("division by zero")

func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) {
        return ErrDivByZero
    }
    return a / b
}

var result = divide(10, 0)
if(result is Error) {
    console.print(result.Error)    // "division by zero"
    return
}
var value: i32 = result.i32
```

Inline errors are fine for one-off cases:
```
func readFile(path: string) (Error | string) {
    return Error("could not open file")
}
```

If the error is not handled before scope exit — crash, print message, done.

---

## Null Handling

Absence of a value expressed through a union with `null`. `null` is never a standalone value — it only exists inside a union type.

The same scope-based rule as error handling applies — a `(null | T)` union must be handled before leaving scope. If not handled, the compiler throws a hard error.

```
func find(id: i32) (null | User) {
    // ...
}

// must handle before scope exit
var result = find(42)
if(result is null) {
    // handle absence
    return
}
var user: User = result.User
```
