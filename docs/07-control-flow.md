# Control Flow

## `if` / `elif` / `else` — Conditional Branching

```
if (x > 10) {
    doA()
} elif (x > 5) {
    doB()
} elif (x > 0) {
    doC()
} else {
    doD()
}
```

`elif` chains are syntactic sugar for nested if/else — each `elif` produces a nested `if` in the AST. Use `match` for multi-way branching on values or types.

Note: `else if` (two keywords) is not supported — use `elif`.

## `for` — Iteration

Used for iterating over collections and ranges. `for` is the only loop for iteration — never used for conditions.

```
for(my_array) |value| { }                    // value only
for(my_array, 0..) |value, index| { }       // value and explicit index
for(0..10) |i| { }                          // range
for(arr1, arr2) |a, b| { }                  // parallel iteration
for(entries) |(key, value)| { }              // tuple capture — struct destructure
for(entries, 0..) |(key, value), index| { }  // tuple capture with index
```

## `while` — Condition Based

Used for looping on a condition. Never used for iteration.

```
var i: i32 = 0
while(i < 10) : (i += 1) { }    // with continue expression

while(running) { }               // simple condition

while(true) { }                  // infinite loop
```

## `break` and `continue`

```
// break — exit the current loop immediately
while(true) {
    if(done) {
        break
    }
}

// continue — skip to next iteration
for(my_array) |value| {
    if(value == 0) {
        continue
    }
}
```

## Breaking Out of Nested Loops

Labels are not supported. To break out of a nested loop early, extract the inner logic into a function and use `return`:

```
func findZero(items: []Item) bool {
    for(items) |item| {
        for(item.values) |v| {
            if(v == 0) { return true }
        }
    }
    return false
}
```

`break label` and `continue label` are compiler errors.

---

## Pattern Matching

`match` is the only way to safely extract enum variant data. Must be exhaustive — compiler error if any variant is unhandled. `else` is the catch-all arm and must be last.

Inside a match arm, variant data accessed via dot syntax on the variant name. No local binding names needed.

```
match s {
    Circle    => { var area: f32 = 3.14 * Circle.radius * Circle.radius }
    Rectangle => { var area: f32 = Rectangle.width * Rectangle.height }
    Point     => { }
    else      => { }
}
```

`match` works on integers, strings, ranges, [[10-structs-enums#Enums|enum]] variants, and [[02-types#Unions|union]] types:
```
match value {
    0       => { }    // exact integer
    (4..8)  => { }    // inclusive range — parentheses required
    "hello" => { }    // str
    North   => { }    // enum variant, no type prefix
    else    => { }    // catch-all
}
```

### Parenthesized Patterns

Some patterns require parentheses; others allow them to be omitted:

| Pattern | Parentheses | Example |
|---------|-------------|---------|
| Single literal | optional | `42 =>`, `"hello" =>` |
| Single identifier (enum variant, type name) | optional | `North =>`, `Error =>` |
| Range | required | `(1..10) =>` |
| Binding with guard | required | `(x if x > 0) =>` |
| `else` | never | `else =>` |

Range patterns always require parentheses:
```
match(n) {
    (1..3) => { return 1 }
    (4..6) => { return 2 }
    else   => { return 0 }
}
```

### Pattern Guards

Match arms can include a guard expression using the `if` keyword. The arm only
fires when both the pattern matches and the guard evaluates to true.

Guard syntax requires parentheses around the binding and guard:
```
match(value) {
    (x if x > 0)  => { return x }
    (x if x < 0)  => { return 0 - x }
    else           => { return 0 }
}
```

The guard expression can reference the bound variable and variables from the
enclosing scope:
```
func clamp(n: i32, max: i32) i32 {
    match(n) {
        (x if x > max)  => { return max }
        else             => { return n }
    }
}
```

When any arm has a guard, an `else` arm is required — guards do not guarantee
exhaustive coverage.

Guarded and unguarded arms can coexist freely in the same match block.

### Matching on Union Types

`match` can branch on which type an `(Error | T)` or `(null | T)` union currently holds (see [[08-error-handling]]).
Arms are type names — no binding syntax needed, access the payload via the usual dot syntax.

```
// (Error | T)
match result {
    Error => { console.println(result.Error) }
    i32   => { console.println(result.i32) }
}

// (null | T)
match user {
    null => { return "not found" }
    User => { return user.User.name }
}
```

The two arm kinds never mix in the same `match` block — value matching and type matching are separate.

### Type Checking in `compt` Functions

Use `is` / `is not` to branch on type inside a [[05-functions#`compt` Functions|compt func]]:

```
compt func describe(val: any) str {
    if(val is i32) { return "integer" }
    if(val is f32) { return "float" }
    if(val is str) { return "str" }
    return "unknown"
}
```

---

## Defer

Runs a block at the end of the scope it is declared in — not end of function. Multiple defers in the same scope execute in reverse order (LIFO).

```
func example() void {
    defer { cleanup() }
    {
        defer { inner() }
    }                      // inner() runs here
}                          // cleanup() runs here
```
