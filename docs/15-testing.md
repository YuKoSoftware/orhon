# Testing

Tests declared with the `test` keyword. Description string directly after `test` — no parentheses. Stripped from release builds automatically.

```
test"adds two numbers correctly" {
    var result: i32 = add(1, 2)
    assert(result == 3)
    assert(result == 3, "expected 3")
}
```

Run with `kodr test`.

Tests live in the same file as the code they test. One or two focused tests per feature is enough — don't clutter. If a feature is a stub or placeholder, skip the test until it's real.
