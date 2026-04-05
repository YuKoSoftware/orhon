# Research: Remove Parentheses from For-Loop Tuple Capture Syntax

**Date:** 2026-04-05
**Topic:** Feasibility and design options for changing `|(k, v)|` to `|k, v|` in for-loop captures.

## Summary

Removing parentheses from tuple captures introduces a fundamental ambiguity: `|a, b|` could mean "simple capture + index" or "2-field struct destructure." This ambiguity cannot be resolved at parse time -- it requires knowing the element type of the iterable, which is only available after type resolution (pass 5). This report examines how other languages handle this, maps the exact codebase locations affected, evaluates three design options, and concludes with a recommendation.

The short answer: removing parens is feasible but pushes complexity from the user (writing two extra characters) to the compiler (semantic disambiguation across 7+ files). The tradeoff is marginal -- the current syntax is clear, unambiguous, and maps cleanly to Zig. Removing parens is a net negative unless combined with a broader syntax redesign.

## How Others Do It

### Zig

**Approach:** No destructuring in for-loop captures at all. Zig's `for` captures are positional -- each capture corresponds to one of the comma-separated iterables in the `for(a, b, 0..)` header. `|x, y, i|` means "element from a, element from b, counter." Destructuring a struct requires explicit field access inside the loop body.

**Tradeoffs:** Zero ambiguity, but more verbose for struct iteration. Users write `entry.key` and `entry.value` manually.

**Relevance:** High. Orhon transpiles to Zig. The current Orhon codegen for tuple captures already desugars `|(k, v)|` into `|_orhon_entry|` + `const k = _orhon_entry.key;` (see `codegen_exprs.zig:579-616`). This means Orhon's tuple capture is purely syntactic sugar over what Zig already requires. The parentheses in `|(k, v)|` are Orhon's way of marking this sugar -- Zig has no equivalent syntax to guide us.

### Rust

**Approach:** Patterns everywhere. `for (k, v) in map.iter()` uses the same pattern syntax as `let`, `match`, and function parameters. The pattern `(k, v)` is unambiguously a tuple destructure because Rust tuples use parens: `(i32, i32)`. No ambiguity exists because Rust's type system and pattern grammar are unified.

**Tradeoffs:** Elegant, but relies on tuples being a first-class parenthesized type. Rust never has "capture + index" as a built-in -- `.enumerate()` returns a tuple `(usize, T)`, so the index is just another destructured field.

**Relevance:** Medium. Orhon's named tuples use parens in type position (`(key: i32, value: i32)`) but struct instances use braces (`Entry{key: 1, value: 2}`). Orhon's for-loop captures aren't patterns in the Rust sense -- they're special capture syntax between pipes.

### Go

**Approach:** Fixed two-value capture: `for i, v := range slice`. The first is always the index, the second is always the value. No destructuring. No ambiguity because the positions are fixed by the language.

**Tradeoffs:** Simple and clear, but no struct destructuring at all. Users must access fields manually.

**Relevance:** Low. Go's approach is too rigid for Orhon's goals.

### Swift

**Approach:** `for (k, v) in dict` destructures tuples using parens. Like Rust, Swift tuples are parenthesized types, so `(k, v)` is unambiguously a tuple pattern. Indices require `.enumerated()`: `for (i, val) in arr.enumerated()`.

**Tradeoffs:** Clean, but tuple destructure and index capture use the same syntax -- you must call `.enumerated()` to get an index, which wraps values in a tuple.

**Relevance:** Medium. Demonstrates that parens-for-destructure is a well-established convention.

### Python

**Approach:** `for k, v in dict.items()` -- no parens needed. Python resolves unpacking semantically at runtime: the number of variables on the left must match the number of values yielded. `for a, b in [(1, 2), (3, 4)]` works; `for a, b in [1, 2, 3]` raises ValueError at runtime.

**Tradeoffs:** Maximum ergonomics, but ambiguity is resolved at runtime (not compile time). `for a, b in items` has no way to distinguish "destructure" from "value + index" at parse time -- Python doesn't have built-in index capture.

**Relevance:** Low. Python is dynamically typed and doesn't have Orhon's compile-time safety requirements.

## Current Orhon State

### Grammar (`src/orhon.peg`, lines 227-231)

```
for_stmt
    <- 'for' '(' expr ')' '|' for_captures '|' block

for_captures
    <- '(' IDENTIFIER (',' IDENTIFIER)* ')' (',' IDENTIFIER)?   # tuple: |(k, v), i|
     / IDENTIFIER (',' IDENTIFIER)?                              # simple: |val, i|
```

Two grammar alternatives, disambiguated at parse time by the presence of `(` after `|`. The first alternative captures tuple fields inside parens with an optional trailing index. The second captures a simple value with an optional index.

### AST (`src/parser.zig`, lines 277-284)

```zig
pub const ForStmt = struct {
    iterable: *Node,
    captures: [][]const u8,
    index_var: ?[]const u8,
    body: *Node,
    is_compt: bool,
    is_tuple_capture: bool,
};
```

The `is_tuple_capture` flag is set by the builder based on whether parens were present. This flag flows through the entire pipeline.

### Builder (`src/peg/builder_stmts.zig`, lines 105-157)

`buildFor()` detects tuple vs simple capture by checking if the first token in `for_captures` is `lparen`. If yes: identifiers inside parens go to `captures`, identifier after `)` goes to `index_var`, and `is_tuple_capture = true`. If no: first identifier is the capture, second is the index.

### Resolver (`src/resolver.zig`, lines 361-406)

When `is_tuple_capture` is true, the resolver:
1. Infers the element type via `inferCaptureType()` (line 366)
2. Looks up the struct signature from `decls.structs` (line 370)
3. Validates capture count matches field count (line 376)
4. Defines each capture variable with the corresponding field type (line 386)

When `is_tuple_capture` is false, all captures get the element type directly (line 400).

### Codegen (`src/codegen/codegen_exprs.zig`, lines 573-616)

Tuple captures generate: `for (iter) |_orhon_entry, ...| { const k = _orhon_entry.field_name; ... }`. The `is_tuple_capture` flag gates this entire code path.

### MIR (`src/mir/mir_lowerer.zig`, line 627; `src/mir/mir_node.zig`, line 84)

`is_tuple_capture` is copied from `ForStmt` to `MirNode` verbatim.

### Ownership (`src/ownership_checks.zig`, line 118)

`is_tuple_capture` controls whether captures are treated as primitive (struct field copies) vs potentially non-primitive.

### Files that reference `is_tuple_capture` (7 total)

1. `src/parser.zig` -- struct definition
2. `src/peg/builder_stmts.zig` -- sets the flag
3. `src/resolver.zig` -- gates struct lookup logic
4. `src/codegen/codegen_exprs.zig` -- gates destructure codegen
5. `src/mir/mir_lowerer.zig` -- copies flag to MirNode
6. `src/mir/mir_node.zig` -- MirNode field
7. `src/ownership_checks.zig` -- ownership behavior

### Test fixtures using tuple captures (3 locations)

- `src/templates/example/control_flow.orh:152` -- `|(k, v)|`
- `test/fixtures/tester.orh:1651` -- `|(x, y)|`
- `test/fixtures/tester.orh:1661` -- `|(x, y), i|`

## Feasibility Assessment

Removing parens is **technically feasible** but introduces non-trivial complexity:

1. **Grammar change is trivial.** Replace `for_captures` with `IDENTIFIER (',' IDENTIFIER)*` -- one line.

2. **Builder change is trivial.** Collect all identifiers, no paren detection needed.

3. **AST change is trivial.** Remove `is_tuple_capture` from `ForStmt`, or keep it and set it later.

4. **Resolver change is the hard part.** The resolver must now determine whether `|a, b|` means:
   - Simple capture `a` + index `b` (when iterating over a slice of primitives/non-structs)
   - 2-field destructure of `a` and `b` (when iterating over a slice of 2-field structs)

   This requires `inferCaptureType()` to succeed. It currently returns `.inferred` when the element type is unknown (generics, cross-module types, unresolved types). Under the paren-free design, `.inferred` means "we can't tell what the user meant" -- a hard error or a guess.

5. **Codegen, MIR, ownership changes are mechanical** -- they just follow the resolver's decision.

6. **Test fixture updates are minimal** -- 3 files.

## Design Options

### Option A: Remove parens, resolver disambiguates by element type

**Grammar:** `for_captures <- IDENTIFIER (',' IDENTIFIER)*`

**Disambiguation rule:** After `inferCaptureType()`:
- If element type is a struct with N fields and capture count == N: tuple destructure.
- If element type is a struct with N fields and capture count == N+1: tuple destructure + index (last capture is index).
- Otherwise: first capture is simple value, second (if present) is index. More than 2 captures is an error for non-structs.

**Pros:**
- Cleaner syntax: `|k, v|` instead of `|(k, v)|`
- Two fewer characters per tuple capture
- Aligns with Python's ergonomic feel

**Cons:**
- **Ambiguity with 2-field structs.** If you have `[]Point` where `Point{x: i32, y: i32}` and write `|a, b|`, does this destructure Point into `a=x, b=y` or capture the Point as `a` with index `b`? The resolver would choose "destructure" because capture count matches field count. To get simple + index, you'd need `|p, i|` and then access `p.x`. But the resolver doesn't know `|a, b|` vs `|p, i|` -- names don't carry semantic meaning.
- **No way to opt out.** If you want a simple capture (the whole struct as one variable) when iterating a struct slice, you'd write `|entry|` -- but then you can't also get the index without adding a second capture, which triggers destructuring.
- **Generic types break.** `func process(items: []T) void { for(items) |a, b| { } }` -- the resolver can't know T's field count.
- **`.inferred` type is ambiguous.** Cross-module types or complex expressions may not resolve. The resolver must either error ("can't determine capture mode") or guess.
- **Silent behavior changes.** Changing a struct from 2 fields to 3 would silently change `|a, b|` from "destructure" to "simple + index" -- a semantic shift with no syntax change.

**Zig mapping:** Same as current -- codegen emits `|_orhon_entry|` + field access. The change is purely at the Orhon syntax level.

### Option B: Remove parens, use trailing separator for index

**Grammar:**
```
for_captures <- IDENTIFIER (',' IDENTIFIER)* (';' IDENTIFIER)?
```

**Rule:** All comma-separated identifiers are captures (value or destructured fields). The semicolon-separated identifier (if present) is always the index.

`for(items) |a, b; i|` -- destructure into a, b with index i.
`for(items) |val; i|` -- simple capture with index.
`for(items) |val|` -- simple capture, no index.

**Disambiguation rule:** If capture count > 1, it's always a destructure. If capture count == 1, it's always a simple capture.

**Pros:**
- Zero ambiguity at parse time -- the grammar alone determines the mode.
- No resolver changes needed for disambiguation.
- Index is always explicit and syntactically distinct.
- `|a, b|` always means destructure (never simple + index).

**Cons:**
- **Breaking change to simple + index.** Current `|val, i|` becomes `|val; i|`. This affects all existing for-loops with index capture.
- **New punctuation in captures.** Semicolons inside pipes are unusual and may confuse users.
- **`|val, i|` silently becomes destructure.** If a user writes `|val, i|` expecting simple + index (old behavior), they now get a 2-field destructure. This is a dangerous migration path.
- **Single-field struct edge case.** `|a|` on a 1-field struct is "simple capture" not "destructure" -- you can't destructure a 1-field struct without also looking like a simple capture.

**Zig mapping:** Clean. Zig uses `,` between captures and has no special index syntax (index is just another iterable: `0..`).

### Option C: Keep parentheses (status quo)

**Grammar:** No change.

**Rule:** `|(k, v)|` = destructure, `|val, i|` = simple + index. Parse-time disambiguation via parens.

**Pros:**
- Zero ambiguity at any level -- grammar, resolver, codegen all know the intent.
- No risk of silent behavior changes when struct fields change.
- Works with generics, inferred types, cross-module types -- the flag is set syntactically.
- Consistent with Rust and Swift conventions (parens = destructure).
- No migration cost, no test changes, no risk of regression.
- Two extra characters is a minor cost for complete clarity.

**Cons:**
- Slightly more verbose: `|(k, v)|` vs `|k, v|`.
- The parens inside pipes look unusual (though this is subjective).

**Zig mapping:** Irrelevant -- Zig has no equivalent syntax. The parens are purely Orhon-level.

## Pros & Cons Table

| Criterion | Option A (resolver) | Option B (semicolon) | Option C (keep parens) |
|---|---|---|---|
| Parse-time clarity | No | Yes | Yes |
| Works with generics | No (must guess) | Yes | Yes |
| Works with `.inferred` | No (must error or guess) | Yes | Yes |
| Silent breakage risk | High (field count changes) | Medium (migration) | None |
| Migration effort | Low (remove parens) | Medium (change `,` to `;` for index) | None |
| Codebase changes | 7+ files, resolver logic | 7+ files, grammar + builder | None |
| User learning curve | Hidden rules | New separator | Explicit parens |
| Convention alignment | Python-like | Unique to Orhon | Rust/Swift-like |
| Zig mapping impact | None | None | None |

## Future-Proofness

### Multi-field destructuring beyond 2 fields

Current syntax handles this naturally: `|(a, b, c)|` is a 3-field destructure. With Option A, `|a, b, c|` is ambiguous (3-field destructure or 2-field + index?). Option B handles it cleanly with the semicolon separator.

### Nested destructuring

If Orhon ever supports nested destructuring (e.g., `|(a, (b, c))|`), parens are already the convention. Removing outer parens while keeping inner ones creates inconsistency.

### `compt for` (planned, per `docs/TODO.md`)

`compt for` iterates over compile-time slices (e.g., struct fields). Tuple captures in `compt for` would need the same disambiguation. Parens keep this simple.

### Named tuple types

Named tuples (`(key: i32, value: i32)`) use parens in type position. Keeping parens in capture position maintains symmetry: the type uses parens, the destructure uses parens.

### Index type annotation (per `docs/TODO.md`)

The TODO mentions `|val, i: i32|` for typed indices. With Option A, `|val, i: i32|` would need the resolver to check whether `i` is a field or an index based on the `: i32` annotation. With parens, `|(val), i: i32|` or `|val, i: i32|` are unambiguous.

## Risks & Edge Cases

### Generic types where element type is unknown

```
func sum(items: []T) i32 {
    for(items) |a, b| { }   // Option A: is T a 2-field struct?
}
```

With parens: `|(a, b)|` explicitly tells the compiler "destructure this." Without parens, the compiler must resolve T first -- which it can't in a generic context.

### `.inferred` and cross-module types

When `inferCaptureType()` returns `.inferred` (unresolved type), Option A cannot determine capture mode. The compiler would need to either:
- Error: "cannot determine capture mode for inferred element type" -- bad UX.
- Default to simple + index -- silently wrong if the user meant destructure.
- Default to destructure -- silently wrong if the user meant simple + index.

### 1-field structs

`for(items) |a|` -- is this a simple capture of the whole struct, or a 1-field destructure? With parens, `|(a)|` is a destructure, `|a|` is simple. Without parens, there's no way to distinguish them. Option A would need to always treat single capture as simple (otherwise `|a|` on a 1-field struct silently destructures).

### Struct field count changes

With Option A: changing `struct Pair { x: i32, y: i32 }` to `struct Triple { x: i32, y: i32, z: i32 }` would change the meaning of `|a, b|` from "destructure" to "simple + index" -- a silent semantic shift that could introduce bugs.

### The `|a, b, c|` question

Is `|a, b, c|` a 3-field destructure or a 2-field + index? Option A needs a rule: "if capture count == field count, destructure; if capture count == field count + 1, destructure + index." But this means the compiler must resolve the element type first, and for 2-field structs, `|a, b|` matches both "2-field destructure" and "1-field + index on a 1-field struct."

## Recommendation

**Keep the parentheses (Option C).**

The core argument: parentheses provide parse-time disambiguation that costs the user two characters and saves the compiler from semantic guesswork. Every alternative introduces edge cases (generics, inferred types, field count changes) that parens handle for free.

The languages that successfully omit parens (Python) do so because they either:
1. Don't have compile-time type resolution (Python resolves at runtime), or
2. Don't have a separate "value + index" capture mode (Rust uses `.enumerate()` which returns a tuple).

Orhon has both compile-time resolution AND a separate index capture, which creates the ambiguity. The parens resolve it cleanly.

If the syntax is felt to be too heavy, consider Option B (semicolon separator) as a compromise -- but it requires migrating all existing `|val, i|` to `|val; i|`, and introduces a new punctuation convention that no other language uses.

The TODO item should be re-evaluated: the `easy` difficulty label understates the semantic complexity. The grammar change is easy; the disambiguation is not.

## Open Questions

1. **Is the aesthetic concern strong enough to justify the complexity?** The motivation seems to be "parens look weird inside pipes." Is this a common user complaint or a theoretical concern?

2. **Could Orhon adopt Rust's approach instead?** If `for(items.enumerate()) |i, entry|` were available (returning a tuple of index + value), then `|a, b|` would always be a destructure and `|val|` would always be simple. This eliminates the ambiguity entirely but requires an `.enumerate()` method on slices.

3. **Should `for(items) |val, i|` be deprecated in favor of `for(items, 0..) |val, i|`?** Zig requires explicit `0..` for index capture. If Orhon adopted this, `|a, b|` in a single-iterable `for` would always be a destructure (never simple + index), and index capture would require the explicit range. This is the cleanest long-term path but is a larger syntax change.

4. **What about the `compt for` interaction?** `compt for` iterates compile-time slices of field descriptors. Would paren-free captures create problems there?

5. **Is `|(a, b)|` actually confusing to new users?** If the example module and docs are clear, the two extra characters may be a non-issue.
