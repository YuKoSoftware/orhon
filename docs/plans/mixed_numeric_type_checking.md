# Plan: Mixed Numeric Type Checking and For-Loop Index Type

**Date:** 2026-04-05
**Status:** draft
**Scope:** Enforce the spec rule "mixing numeric types is a compile error" in binary expressions; change for-loop index from hidden i32 cast to native usize

## Context

The spec (docs/04-operators.md line 80) says "Mixing numeric types in expressions is a compile error" but the resolver does not enforce this. The binary expression handler in resolver_exprs.zig has a deferred NOTE at line 122-124. Additionally, the for-loop index is typed as `usize` in the resolver but codegen inserts a hidden `@intCast` to `i32`, creating a type mismatch between what the resolver reports and what the generated code does. Both issues need to be fixed together since the for-loop index type directly affects what mixed-type errors users will encounter.

## Decisions (pre-resolved)

1. **Strict, no implicit widening** in binary expressions. `i32 + i64` is a compile error.
2. **For-loop index stays `usize`**, remove the hidden `@intCast` to `i32` in codegen.
3. **Assignment widening works** without `@cast` (matches Zig). `var x: i64 = my_i32` is OK.
4. **Function argument widening works** without `@cast` (matches Zig). `foo(my_i32)` where foo takes `i64` is OK.
5. **Comparison operators across types are errors** too. Same rule for all binary operators.
6. **Numeric literals (`numeric_literal`/`float_literal`) coerce freely** as they do today.
7. **Error messages suggest the fix** -- e.g., "cannot mix i32 and i64 -- use @cast(i64, x)".

## Approach

Add a focused mixed-numeric check in the binary expression handler in resolver_exprs.zig. Do NOT touch `typesCompatible` globally -- it is used for assignment and function argument checking where integer-to-integer compatibility is correct (decisions 3 and 4). The check fires only when both operands are resolved numeric primitives, neither is a literal pseudo-type, and the two types differ. Separately, remove the `@intCast` to `i32` wrapper in codegen_exprs.zig for for-loop range captures, then update all test fixtures and example code that relied on the implicit cast.

## Steps

### 1. Add mixed numeric binary expression check in the resolver
- **Files:** `src/resolver_exprs.zig`
- **What:** After the existing `++` on numeric types check (line 120) and before the NOTE at line 122-124, add a new check:
  - If both `left` and `right` are `.primitive` and both are numeric (`.isNumeric()`)
  - And neither is `.numeric_literal` nor `.float_literal`
  - And `left.primitive != right.primitive`
  - Then report an error with a message like: "cannot mix {left_name} and {right_name} in binary expression -- use @cast({wider}, x) to convert"
  - The error message should suggest casting to the wider/target type. A simple heuristic: suggest the left type (since the result type is currently the left operand's type), or just name both types and let the user decide.
- **Why:** This is the core enforcement of the spec rule. Placing it here means it only applies to binary expressions (arithmetic, comparison, bitwise), not assignments or function arguments.
- **Difficulty:** easy
- **Isolated:** yes

### 2. Remove the NOTE comment in resolver_exprs.zig
- **Files:** `src/resolver_exprs.zig`
- **What:** Delete the three-line NOTE at lines 122-124 that says the check is deferred. It is no longer deferred.
- **Why:** Stale comment cleanup.
- **Difficulty:** easy
- **Isolated:** no -- depends on step 1 (the check replaces the NOTE)

### 3. Remove the hidden `@intCast` to `i32` for for-loop range captures in codegen
- **Files:** `src/codegen/codegen_exprs.zig`
- **What:** Three changes in `generateForMir`:
  1. **Line 624-629 (tuple capture path):** Remove the loop that emits `const {s}: i32 = @intCast(_orhon_{s})` for range captures. Instead, emit `const {s} = _orhon_{s};` (no type annotation, no cast) so the capture keeps its native `usize` type.
  2. **Line 670-673 (non-tuple path):** Same removal -- delete the `@intCast` to `i32` lines for range captures.
  3. **Line 658-662 (capture naming):** Since range captures no longer need the `_orhon_` prefix/rename trick, emit the capture name directly instead of `_orhon_{s}`. The `_orhon_` prefix was only needed to allow the `const i: i32 = @intCast(_orhon_i)` rebinding.
  4. **Line 607-609 (tuple extra captures):** Same -- emit `{s}` instead of `_orhon_{s}`.
  5. **`needs_cast` logic (lines 579-586):** Remove the `needs_cast` variable and the range-detection loop entirely, since range captures no longer need special handling. The block structure (`| {\n ... }` vs `| `) can be simplified -- if the only reason for the block was the intCast, it is no longer needed for range-only for-loops.
  6. **`writeRangeExprMir` (lines 548-568):** Keep the `@intCast` on range BOUNDS. These are still needed -- when a user writes `for(0..n)` where `n: i32`, Zig needs `@intCast(n)` to convert the bound to `usize`. Only the capture-side cast is removed.
- **Why:** The capture should be `usize` (Zig's native range counter type). The hidden cast to `i32` violates zero magic and creates a resolver/codegen type mismatch.
- **Difficulty:** medium -- the `needs_cast` / `_orhon_` prefix logic is intertwined with the for-loop emitter; careful removal is needed to avoid breaking non-range for-loops or tuple captures.
- **Isolated:** yes -- this is purely a codegen change, independent of the resolver check

### 4. Update test fixtures that use for-loop index in i32 arithmetic
- **Files:** `test/fixtures/tester.orh`, `test/fixtures/tester_main.orh`
- **What:** Three functions use the for-loop index in arithmetic with `i32` variables:
  1. **`indexed_sum()` (tester.orh:294-301):** `total += val + i` where `total: i32`, `val: i32`, `i` is now `usize`. Change to `total += val + @cast(i32, i)`.
  2. **`sum_range(n: i32)` (tester.orh:305-311):** `total += i` where `total: i32`, `i` is now `usize`. Change to `total += @cast(i32, i)`.
  3. **`test_tuple_capture_index()` (tester.orh:1658-1665):** `total += x + y + i` where `total: i32`, `x: i32`, `y: i32`, `i` is now `usize`. Change to `total += x + y + @cast(i32, i)`.
  - The expected return values (63, 10, 213) do NOT change -- only the types change.
  - Check `tester_main.orh` expected values are still correct (they are: 63, 10, 213).
- **Why:** These fixtures rely on the old implicit i32 cast. With usize index and strict numeric checking, they would fail.
- **Difficulty:** easy
- **Isolated:** no -- depends on step 3 (codegen change) and step 1 (resolver check)

### 5. Update example module for-loop code
- **Files:** `src/templates/example/control_flow.orh`
- **What:**
  1. **`sum_range(n: i32)` (line 58-63):** `total += i` where `total: i32`, `i` is now `usize`. Change to `total += @cast(i32, i)`. Add a short comment explaining that for-loop indices are `usize`.
  2. **`indexed_sum` pattern (line 134 area):** Check if `i` is used in i32 arithmetic. If so, add `@cast`.
- **Why:** The example module is a living language manual and must compile. It should demonstrate the `@cast` pattern for for-loop indices.
- **Difficulty:** easy
- **Isolated:** no -- depends on steps 1 and 3

### 6. Add a negative test fixture for mixed numeric types
- **Files:** `test/fixtures/fail_mixed_numeric.orh` (new file)
- **What:** Create a fixture with several cases that should each produce a compile error:
  - `i32 + i64` -- different integer widths
  - `i32 + usize` -- different integer types
  - `f32 + f64` -- different float widths
  - `i32 + f32` -- integer + float
  - `i32 < i64` -- comparison across types
  - Also include cases that should PASS (but do not need to be in the negative fixture): `i32 + 1` (literal coerces), `var x: i64 = my_i32` (assignment widening)
  - The fixture should be a valid module with `#build = exe`, `func main() void {}`, and the bad expressions inside functions.
- **Why:** Negative tests ensure the check works and does not regress.
- **Difficulty:** easy
- **Isolated:** no -- depends on step 1

### 7. Add negative test entries in 11_errors.sh
- **Files:** `test/11_errors.sh`
- **What:** Add `run_fixture` calls for the new fixture:
  - `run_fixture neg_mixed_num fail_mixed_numeric.orh "cannot mix" "fixture: rejects mixed numeric types"`
- **Why:** Wires the fixture into the test suite.
- **Difficulty:** easy
- **Isolated:** no -- depends on step 6

### 8. Update the spec to document all numeric type decisions
- **Files:** `docs/04-operators.md`
- **What:** Expand the "No Implicit Numeric Casts" section (lines 79-86) to document:
  1. The existing rule (already there): mixing numeric types in binary expressions is a compile error.
  2. **Add:** This applies to ALL binary operators -- arithmetic, comparison, bitwise. `i32 < i64` is an error, same as `i32 + i64`. Reasoning: consistency, no special cases.
  3. **Add:** Assignment widening is allowed: `var x: i64 = my_i32` works without `@cast`. This matches Zig's integer widening coercion at assignment sites.
  4. **Add:** Function argument widening is allowed: `foo(my_i32)` where `foo` takes `i64` works. Same as assignment -- the target type is known.
  5. **Add:** Numeric literals (`1`, `3.14`) coerce freely to any compatible numeric type. `x + 1` works when `x: i32` because `1` is a `numeric_literal`, not a typed integer.
  6. **Add:** For-loop range indices are `usize`. Use `@cast` to convert: `@cast(i32, i)`.
  7. **Add:** `arr.len` is `usize`. Mixing with other integer types requires `@cast`.
- **Why:** The spec should document all the decisions, not just the headline rule.
- **Difficulty:** easy
- **Isolated:** yes

### 9. Update TODO.md to mark this item as done
- **Files:** `docs/TODO.md`
- **What:** Remove or mark as complete the "Mixed numeric type checking and for-loop index type" section (lines 36-54).
- **Why:** Keep TODO current.
- **Difficulty:** easy
- **Isolated:** no -- depends on all other steps being complete

### 10. Run tests
- **Command:** `./testall.sh`
- **Expected:** All tests pass. Specifically:
  - `test/01_unit.sh` -- unit tests for resolver should pass (typesCompatible tests unchanged since we did not touch it)
  - `test/09_language.sh` -- example module compiles
  - `test/10_runtime.sh` -- tester runtime values unchanged (63, 10, 213)
  - `test/11_errors.sh` -- new negative test passes
- **Difficulty:** easy
- **Isolated:** no -- final validation

## Risks & Edge Cases

- **Array literal element checking** (`resolver_exprs.zig:405`) uses `typesCompatible`. Since we are NOT changing `typesCompatible`, `[my_i32, my_i64]` will still be accepted by the resolver. This is arguably correct (the array type is inferred), and Zig will catch any real issues. If this needs tightening, it is a separate task.

- **Compound assignment operators** (`+=`, `-=`, etc.) go through the binary expression handler. `total += i` where `total: i32` and `i: usize` WILL be caught by the new check. This is correct and intended, but the test fixture updates in step 4 must handle this.

- **`needs_cast` removal in step 3** is the riskiest change. The `_orhon_` prefix and block-form emission may be used by other code paths. Need to verify that the only reason for the prefix/block is the i32 cast. If tuple captures also use the block form for field destructuring (they do -- see line 611), the tuple path's block form must be preserved. Only the non-tuple `needs_cast` block should be simplified.

- **Range bound `@intCast` must be preserved.** `writeRangeExprMir` wraps non-literal range bounds in `@intCast` so that `for(0..n)` where `n: i32` produces valid Zig (`@intCast(n)`). Step 3 must NOT remove this -- only the capture-side cast.

- **Existing code that uses for-loop index with i32** will break. This is intentional (pre-1.0 breaking change) but the example module and test fixtures must be updated first.

- **Bitwise operators** are binary expressions and will be covered by the same check. `my_u8 & my_u32` will be an error. This is correct.

## Out of Scope

- **Unary negation on unsigned types** (`-my_u32`) -- separate check, not part of this plan.
- **Tightening `typesCompatible` globally** -- the current permissive integer-to-integer behavior is needed for assignment and argument widening.
- **Typed for-loop captures** (`for(arr) |val, i: i32|`) -- future syntax enhancement, not needed now.
- **Tuple math** type checking -- depends on tuple math being implemented first.
- **Integer overflow builtins** (`@overflow`, `@wrap`, `@sat`) -- separate feature.

## Open Questions

None -- all design decisions were pre-resolved.
