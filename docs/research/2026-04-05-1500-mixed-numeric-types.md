# Research: Mixed Numeric Type Checking and For-Loop Index Type

**Date:** 2026-04-05
**Topic:** Enforce the spec rule "mixing numeric types is a compile error" and decide on for-loop index type behavior
**Requested by:** user

## Summary

Orhon's spec (docs/04-operators.md line 80) says "mixing numeric types in expressions is a compile error" but the check is not enforced. The resolver currently treats all integer-to-integer and all float-to-float as compatible (resolver.zig line 674-675), and the binary expression handler (resolver_exprs.zig line 122-124) has a NOTE deferring the check. This research evaluates three widening strategies and their interaction with the for-loop index type (currently `usize` in the resolver, cast to `i32` in codegen). The recommendation is: **no implicit widening at all** -- require explicit `@cast` for all mixed numeric operations, matching the spec exactly, and keep the for-loop index as `usize` with the existing `@intCast` wrapper in codegen.

## How Others Do It

### Zig (the backend)
- **Approach:** Zig allows same-signedness integer widening (u8 -> u16 -> u32, i8 -> i16 -> i32) implicitly. Cross-signedness (u32 + i32) is a compile error. Integer-to-float is a compile error unless the float can represent all values of the integer without rounding (proposal #18614, not yet merged as of 2025). `comptime_int` coerces freely to any integer type at comptime. Mixing different runtime integer types in a binary expression (e.g. `var a: u8; var b: u32; _ = a + b`) is a compile error -- you must use `@intCast` or `@as`.
- **Tradeoffs:** Very explicit. Catches real bugs. Somewhat verbose for common patterns like array indexing with different-width counters.
- **Relevance to Orhon:** Since Orhon transpiles to Zig, any implicit widening Orhon allows must be implemented by inserting `@intCast`/`@floatCast` in the generated Zig. If Orhon matches Zig's strictness, codegen is trivial (1:1 mapping). If Orhon is more permissive, codegen must insert casts.

### Rust
- **Approach:** Zero implicit numeric conversions. `i32 + i64` is a compile error. All conversions require `as` keyword: `x as i64 + y`. No widening, no narrowing, no cross-family -- everything is explicit.
- **Tradeoffs:** Maximum safety. Annoying for math-heavy code. The Rust community has debated implicit widening (internals.rust-lang.org/t/implicit-numeric-widening-coercion-proposal/23660) but it has been rejected multiple times -- the consensus is that explicitness catches real bugs.
- **Relevance to Orhon:** Rust proves that "no implicit conversions" is viable in a popular systems language. The ergonomic cost is real but manageable. Rust's `as` maps directly to Orhon's `@cast`.

### Go
- **Approach:** Zero implicit numeric conversions. `int + int32` is a compile error. All conversions require explicit type constructor syntax: `int64(x) + y`. Go's strong type system treats every integer width as a distinct type with no implicit coercion.
- **Tradeoffs:** Very explicit, catches real bugs. Less annoying than Rust because Go has fewer integer types in practice (most code uses `int` and `int64`).
- **Relevance to Orhon:** Confirms that no-implicit-conversion is the norm in modern compiled languages. Go's simplicity aligns with Orhon's "simple yet powerful" goal.

### Swift
- **Approach:** No implicit widening between runtime numeric types. `Int + Int32` is a compile error. Requires explicit `Int(x)` constructor calls. Integer and float literals have special "literal protocol" types that coerce freely to any compatible type at the assignment site (similar to Zig's `comptime_int`).
- **Tradeoffs:** Explicit for runtime values, ergonomic for literals. Swift developers frequently complain about CGFloat/Float/Double conversion friction.
- **Relevance to Orhon:** Swift's literal coercion is the closest model to what Orhon already does with `numeric_literal` and `float_literal` pseudo-types.

### Carbon
- **Approach:** Allows implicit lossless widening within the same signedness family. i32 -> i64 is implicit. Signed/unsigned mixing is an error. Designed as a "better C++" so they prioritize ergonomics over maximum strictness.
- **Tradeoffs:** More ergonomic for common math. Risk of subtle widening surprises.
- **Relevance to Orhon:** Shows that same-family widening is the middle ground. However, Carbon has to deal with C++ interop constraints that Orhon does not.

## Current Orhon State

### What exists

1. **Spec rule** (docs/04-operators.md:80): "Mixing numeric types in expressions is a compile error. All conversions must be explicit via `@cast(T, x)`."

2. **Primitive type system** (src/types.zig:10-135): Complete set of numeric types: i8/i16/i32/i64/i128, u8/u16/u32/u64/u128, isize/usize, f16/f32/f64/f128, plus pseudo-types `numeric_literal` and `float_literal`. Has `isInteger()`, `isFloat()`, `isNumeric()` helpers. Does NOT have `isSigned()`, `isUnsigned()`, or `bitWidth()` helpers.

3. **typesCompatible** (src/resolver.zig:661-697): Lines 674-675 currently say "Integer-to-integer and float-to-float are compatible (Zig handles coercion)" -- this is the overly-permissive behavior that needs tightening. ALL integers are treated as compatible with ALL other integers. ALL floats are treated as compatible with ALL other floats.

4. **Binary expression resolver** (src/resolver_exprs.zig:91-128): Has the deferred NOTE at line 122-124. Currently returns the LEFT operand's type for arithmetic, which means `i32 + i64` silently returns `i32` as the result type -- wrong even if widening were allowed.

5. **Numeric literal compatibility** (src/resolver.zig:668-672): `numeric_literal` is compatible with any integer type, `float_literal` with any float type. This is correct and should stay -- it matches Zig's `comptime_int`/`comptime_float` behavior.

6. **For-loop index** (src/resolver.zig:637): `inferCaptureType` returns `usize` for range expressions. Codegen (src/codegen/codegen_exprs.zig:628, 672) wraps range captures with `const i: i32 = @intCast(_orhon_i);` -- hardcoded i32 cast.

7. **@cast implementation**: Already works for numeric conversions. Maps to Zig's `@intCast`, `@floatCast`, `@intFromFloat`, `@floatFromInt` depending on source/target types.

### What would need to change

1. **resolver_exprs.zig**: Add mixed numeric type checking in the `.binary_expr` handler (around line 122).
2. **resolver.zig**: Tighten `typesCompatible` to reject cross-type integer/float mixing (lines 674-675).
3. **types.zig**: Optionally add `isSigned()` and `bitWidth()` helpers to `Primitive` if same-family widening is chosen.
4. **For-loop codegen**: Decide on index type and possibly change the hardcoded `i32` cast.

## Feasibility Assessment

- **Can Orhon do this?** Yes -- this is a straightforward resolver-level check. The infrastructure (type resolution, binary expression handling, error reporting) all exists.
- **Zig backend constraints:** Zig rejects mixed numeric types in binary expressions. If Orhon allows implicit widening, codegen must insert `@intCast`/`@floatCast`. If Orhon matches Zig's strictness, codegen needs no changes.
- **Implementation difficulty:** Easy for strict mode (just tighten the check). Medium for widening mode (need to determine result type, insert casts in codegen, handle edge cases with usize/isize).
- **Estimated scope:** 2-4 files (resolver_exprs.zig, resolver.zig, types.zig, possibly codegen_exprs.zig). ~50-150 lines of changes depending on approach.

## Design Options

### Option A: Strict — No Implicit Widening (Match the Spec)

- **Description:** Enforce the spec exactly. Any binary expression where left and right have different numeric types is a compile error. `i32 + i64` -> error, `f32 + f64` -> error, `i32 + f64` -> error. User must write `@cast(i64, x) + y`. Numeric literals (`numeric_literal`/`float_literal`) remain compatible with any integer/float type respectively (this is already implemented and matches Zig's comptime behavior).
- **Pros:**
  - Matches the existing spec exactly -- no spec change needed
  - Simplest implementation -- just tighten the check, no codegen changes
  - 1:1 Zig mapping -- Orhon's strictness matches Zig's, so generated code needs no inserted casts
  - Maximum safety -- no accidental precision loss or sign issues
  - Zero magic -- the programmer sees exactly what type every expression has
- **Cons:**
  - Verbose for common patterns like `i32_var + 1` (BUT: `1` is a `numeric_literal`, not `i32`, so this actually works fine -- the literal coerces)
  - `arr.len + my_i32` requires a cast (arr.len is usize)
  - Math-heavy code with mixed widths needs many `@cast` calls
- **Zig mapping:** Direct 1:1. No inserted casts. What the user writes is what gets generated.
- **Orhon philosophy fit:** Perfect. Zero magic, explicit over implicit, 1:1 Zig mapping.

### Option B: Same-Family Widening

- **Description:** Allow automatic lossless widening within the same signedness family. `i32 + i64` -> `i64`. `u8 + u32` -> `u32`. `f32 + f64` -> `f64`. Cross-family mixing is an error: `i32 + u32` -> error, `i32 + f64` -> error, `usize + i32` -> error.
- **Pros:**
  - More ergonomic for common math patterns
  - Still safe -- only lossless conversions are implicit
  - Catches the truly dangerous cases (signed/unsigned, int/float)
- **Cons:**
  - Requires codegen to insert `@intCast`/`@floatCast` in the generated Zig
  - Violates "explicit over implicit" -- the result type of `i32 + i64` is not obvious without knowing the widening rule
  - Violates 1:1 Zig mapping -- Zig does NOT allow `i32 + i64`, so the generated Zig must have a cast that the user did not write
  - Adds complexity to the resolver (must determine result type as max-width of the two)
  - Edge cases with usize/isize: is `i32 + isize` valid? (isize is platform-dependent, could be 32 or 64 bits)
  - Creates a hidden rule that deviates from both Zig and the current spec
- **Zig mapping:** Not 1:1. Codegen must insert `@intCast` calls that do not appear in the source.
- **Orhon philosophy fit:** Poor. Violates zero magic, explicit over implicit, and 1:1 Zig mapping.

### Option C: Hybrid — Strict by Default, Widening via @cast

- **Description:** Same as Option A (strict), but improve `@cast` ergonomics. For example, allow `@cast(i64, x + y)` where x and y are different integer types, with the cast applying to the expression as a whole. This is just the current system with better documentation/error messages.
- **Pros:** Keeps strict semantics while making the workaround clear
- **Cons:** This is essentially just Option A with better error messages
- **Zig mapping:** 1:1
- **Orhon philosophy fit:** Good

## For-Loop Index Type

### Current behavior

The resolver types range captures as `usize` (resolver.zig:637). Codegen inserts `const i: i32 = @intCast(_orhon_i);` for all range captures (codegen_exprs.zig:628, 672). This means:

1. The resolver thinks the index is `usize`
2. The generated Zig code casts it to `i32`
3. There is a type mismatch between what the resolver believes and what codegen emits

### Options for index type

**Option F1: Keep usize, keep @intCast to i32 in codegen**
- Current behavior. Works but the resolver/codegen disagree on the type. If mixed numeric checking is enabled, using the index with i32 variables works (codegen made it i32), but using it with usize variables would require a cast in user code even though the original iterable is usize.
- Problem: resolver says usize, codegen emits i32. The type the user "sees" in error messages would be wrong.

**Option F2: Resolver types range captures as i32, codegen keeps @intCast**
- Change `inferCaptureType` to return `i32` for range expressions instead of `usize`. Codegen already casts to i32, so this makes resolver and codegen agree.
- Pro: Consistent. i32 is the most common integer type in user code.
- Con: Zig's native index type is usize. If the user needs to index into an array with the loop variable, they need `@cast(usize, i)`, which is backwards from Zig.

**Option F3: Resolver types as usize, codegen keeps usize (remove @intCast)**
- Remove the `@intCast` wrapper in codegen. Range captures stay as `usize`, matching Zig's native behavior.
- Pro: 1:1 Zig mapping. No hidden cast. Resolver and codegen agree.
- Con: Users mixing `usize` index with `i32` variables need explicit `@cast`.

**Option F4: Let the range expression determine the type**
- `0..10` where both bounds are `numeric_literal` -> the capture type adapts to context (similar to Zig comptime_int).
- If both bounds are typed (`var start: i32 = 0; for(start..end)`) -> capture type matches the bound type.
- Pro: Flexible, matches Zig's comptime coercion behavior.
- Con: Complex to implement. Orhon range bounds are currently untyped (always parsed as expressions, not type-annotated).

### Recommendation for index type

**Option F3** (keep usize, remove @intCast). Rationale:
- 1:1 Zig mapping -- Zig for-loops with ranges produce usize counters
- No hidden cast -- explicit over implicit
- Resolver and codegen agree -- no type mismatch
- If strict numeric checking is enabled, users who need i32 write `var idx: i32 = @cast(i32, i)` or `@cast(i32, i)` at use site
- This is exactly what the spec says: "mixing numeric types is a compile error, use @cast"

## Pros & Cons

| Factor | Option A (Strict) | Option B (Widening) |
|--------|-------------------|---------------------|
| Simplicity | Simplest -- just tighten the check | Medium -- need result-type logic and codegen cast insertion |
| Safety | Maximum -- no hidden conversions | Good -- only lossless, but hidden |
| Performance | Zero overhead -- no inserted operations | Minimal -- casts are zero-cost in Zig |
| Zig mapping | Perfect 1:1 | Broken -- codegen inserts casts user did not write |
| Composability | Works with existing @cast | Adds new implicit rules |
| Learnability | "All conversions are explicit" -- one rule | "Same-family widening is implicit" -- must learn families |
| Future-proofness | Easy to relax later if needed | Hard to tighten later (breaks existing code) |

## Future-Proofness

- **Relaxing strictness is easy.** If Option A (strict) proves too annoying, same-family widening can be added later as a backward-compatible change -- code that compiled before still compiles.
- **Tightening is hard.** If Option B (widening) is chosen and later proves problematic, removing it breaks existing code. This is a one-way door.
- **Tuple math** (specced but unimplemented) would benefit from strict rules -- element-wise operations need types to match exactly.
- **SIMD/vector operations** (potential future feature) require exact type matching. Strict rules now mean no surprises later.
- **For-loop index**: Changing from i32 to usize is a minor breaking change (existing code that relies on the implicit cast might need explicit @cast). Better to do it now while the language is pre-1.0.

## Risks & Edge Cases

1. **Literal coercion must keep working.** `var x: i32 = 42` and `x + 1` must compile -- `1` is a `numeric_literal` that coerces to `i32`. The current literal compatibility (resolver.zig:668-672) already handles this. But `x + y` where `y: i64` must fail. Need to ensure the check distinguishes literals from typed values.

2. **Comparison operators.** Should `i32 < i64` be an error? In Zig it is. Consistency says yes -- the same rule applies to all binary operators on different numeric types.

3. **Assignment coercion.** `var x: i64 = my_i32` -- should this be an error? The spec (docs/04-operators.md) only mentions "expressions", but assignment is a common widening site. Zig allows this (integer widening coercion). This is a separate question from binary expression mixing and should be researched separately.

4. **Unary negation.** `-my_u32` -- should this be an error? Zig rejects this. Orhon should probably reject it too, but it is a separate check.

5. **Function argument passing.** `func foo(x: i64)` called with `foo(my_i32)` -- should this work? This is assignment coercion at the call site. Zig allows this (widening). This is outside the scope of the binary expression check but needs to be considered for consistency.

6. **The `typesCompatible` function is used in multiple places** -- not just binary expressions. Tightening it will affect array literal element checking (resolver_exprs.zig:405), function return type checking, and more. Each use site needs to be audited. It may be better to add a NEW function `numericTypesMatch(a, b)` for the binary expression check rather than tightening `typesCompatible` globally.

7. **For-loop index change (i32 -> usize)**: The `@intCast` is hardcoded in two places in codegen_exprs.zig (lines 628 and 672). Both need to be removed. Test fixtures and the example module may need updates if any for-loop uses the index in i32 arithmetic.

## Recommendation

**Do Option A (strict, no implicit widening) + Option F3 (usize index, remove @intCast).**

Reasoning:

1. **The spec already says this.** docs/04-operators.md:80 is unambiguous: "Mixing numeric types in expressions is a compile error." The implementation should match the spec.

2. **1:1 Zig mapping.** Zig does not allow mixed numeric types in binary expressions. Making Orhon match means codegen is trivial -- no inserted casts, no hidden transformations. This is the core Orhon philosophy.

3. **Explicit over implicit.** The `@cast` function exists precisely for this purpose. It is visible, searchable, and self-documenting. A reader of Orhon code immediately sees where type conversions happen.

4. **Easy to relax, hard to tighten.** If strict proves too annoying for common patterns, same-family widening can be added later as a backward-compatible change. The reverse is not true.

5. **Literals already work.** The `numeric_literal` and `float_literal` pseudo-types already coerce to any compatible integer/float type. This means `x + 1`, `x * 2.0`, and `var y: i64 = 42` all work without explicit casts. The most common "mixing" scenario (literal + typed variable) is already ergonomic.

6. **For-loop usize is the honest answer.** Zig ranges produce usize. Hiding this behind an @intCast to i32 violates zero magic and creates a resolver/codegen type mismatch. Users who want i32 can cast explicitly.

**Implementation approach:** Add a new check in the `.binary_expr` handler in resolver_exprs.zig. Do NOT tighten `typesCompatible` globally -- it serves multiple purposes and some of those (like assignment coercion) may legitimately want wider compatibility. Instead, add a focused `checkNumericBinaryOp(left_type, right_type)` function that errors when both operands are numeric primitives but not the same type, excluding the `numeric_literal`/`float_literal` pseudo-types which should remain flexible.

## Open Questions

1. **Assignment widening.** Should `var x: i64 = my_i32` work without @cast? Zig allows this. The spec only says "expressions", not "assignments". This is a separate design decision that should be resolved before or alongside this work. If assignment widening is allowed, `typesCompatible` should stay permissive for integer-to-wider-integer, and only binary expressions get the strict check.

2. **Function argument widening.** Should `foo(my_i32)` work when `foo` takes `i64`? Same question as assignment. Zig allows it. This needs a decision.

3. **Comparison operators across types.** Should `my_i32 < my_i64` be an error? Zig says yes. But comparisons are arguably safer than arithmetic (no result type ambiguity). Need a decision.

4. **usize arithmetic.** `arr.len` returns usize. Common pattern: `arr.len - 1`. If the user has `var n: i32`, then `arr.len - n` would be an error. Is this acceptable? The alternative (arr.len returns i32) would diverge from Zig.

5. **Error message quality.** When the user writes `i32 + i64`, the error should suggest the fix: "cannot mix i32 and i64 in expression -- use @cast(i64, x) to convert". Should the compiler suggest which direction to cast?
