# Testing

## Test Declaration

Tests are declared with the `test` keyword followed by a description string and a block.
No parentheses around the name — it's a string literal directly after `test`:

```
test "adds two numbers correctly" {
    const result: i32 = add(1, 2)
    assert(result == 3)
}

test "is_positive works" {
    assert(is_positive(1))
    assert(not is_positive(0 - 1))
}
```

Run all tests with `orhon test`. Tests live in the same file as the code they test.

---

## Assertions

### `assert` — compiler function

The built-in `assert` is a compiler function. It checks a boolean condition and panics
on failure. Optionally takes a message:

```
assert(x > 0)                    // panics with generic message
assert(x > 0, "x must be positive")  // panics with custom message
```

### `std::testing` — stdlib assertions

Import the testing module for richer assertions:

```
use std::testing

test "string equality" {
    assertEq("hello", greeting)      // string equality
    assertNe("hello", "world")       // string inequality
    assertContains(output, "error")  // substring check
    assertTrue(flag)                 // explicit boolean true
    assertFalse(flag)                // explicit boolean false
    fail("should not reach here")    // unconditional failure
}
```

| Function | Purpose |
|----------|---------|
| `assertTrue(value)` | Assert value is `true` |
| `assertFalse(value)` | Assert value is `false` |
| `assertEq(a, b)` | Assert two strings are equal |
| `assertNe(a, b)` | Assert two strings are not equal |
| `assertContains(text, sub)` | Assert text contains substring |
| `fail(msg)` | Fail unconditionally with message |

---

## Test Output

`orhon test` produces clean, minimal output:

```
  PASS  all tests passed
```

On failure:
```
  FAIL  test_name_1
  FAIL  test_name_2

2 passed, 2 failed
```

The Zig compiler's raw test output is captured and reformatted — users never see Zig
internals unless `-verbose` is passed.

---

## Organization

- Tests live in the same file as the code they test — no separate test files
- One or two focused tests per feature is enough — don't clutter
- If a feature is a stub or placeholder, skip the test until it's real
- Test names should describe what's being tested, not how
- All tests in the project run together — no test filtering yet

### When to add tests

Ask: "if this breaks, will a test catch it?" If yes, add one. Prefer testing the code
path directly rather than through a long integration chain.

When touching existing code, check if nearby code lacks coverage — add a test if it's
quick and clear.

---

## Limitations

- **No test filtering** — `orhon test` runs all tests, no way to select specific ones
- **No test fixtures** — setup/teardown is manual within each test block
- **No parallel test execution** — tests run sequentially
- **No coverage reporting** — not yet implemented
