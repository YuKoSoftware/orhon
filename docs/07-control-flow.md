# Control Flow

## `for` — Iteration

Used for iterating over collections and ranges. `for` is the only loop for iteration — never used for conditions.

```
for(my_array, 0..) |value, index| { }    // value and index
for(my_array) |value| { }                // value only
for(0..10) |i| { }                       // range
for(array_a, array_b) |a, b| { }        // two arrays simultaneously
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

## Labels — Named Loop Control

`label` placed directly before a loop. Used with `break` and `continue` to control nested loops. Labels are compile time only — zero runtime overhead, disappear entirely in output binary.

```
label outerLoop
for(array_a) |a| {
    label innerLoop
    for(array_b) |b| {
        if(someCondition) {
            break outerLoop      // exit outer loop entirely
        }
        if(otherCondition) {
            continue outerLoop   // next iteration of outer loop
        }
        break innerLoop          // exit inner loop only
    }
}
```

Hard compiler error if label name doesn't match any enclosing loop. No shadowing of label names allowed.

---

## Pattern Matching

`match` is the only way to safely extract enum variant data. Must be exhaustive — compiler error if any variant is unhandled. `_` is the catch-all wildcard and must be last.

Inside a match arm, variant data accessed via dot syntax on the variant name. No local binding names needed.

```
match s {
    Circle    => { var area: f32 = 3.14 * Circle.radius * Circle.radius }
    Rectangle => { var area: f32 = Rectangle.width * Rectangle.height }
    Point     => { }
    _         => { }
}
```

`match` works on integers, strings, ranges, enum variants, and types:
```
match value {
    0       => { }    // exact integer
    4..8    => { }    // inclusive range
    "hello" => { }    // string
    North   => { }    // enum variant, no type prefix
    _       => { }    // catch-all
}
```

### Type Matching
`match` can match on `@type()` and on type parameters in `compt` functions. Always resolved at compile time — hard compiler error if used in a runtime context. Zero runtime overhead.

```
// matching on @type() — compt resolved
func process(val: any) void {
    match @type(val) {
        i32    => { console.print("integer") }
        f32    => { console.print("float") }
        string => { console.print("string") }
        Player => { console.print("player") }
        _      => { console.print("unknown") }
    }
}

// matching on type parameter in compt function
compt func describe(T: any) type {
    match T {
        i32 => { return @type(struct { value: i32, label: string }) }
        f32 => { return @type(struct { value: f32, label: string }) }
        _   => { }
    }
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
