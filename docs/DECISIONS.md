# Kodr — Design Decisions

Settled choices and the reasoning behind them. Before changing anything listed here,
read the entry first — the alternative was likely already considered and rejected.

---

## Language

### `extern func` is always public
`pub extern func` is a compiler error — redundant and rejected.
Extern functions are a bridge to a paired `.zig` sidecar. By definition they are part
of the module's public interface. There is no meaningful private extern.

### `pub` applies only to user-defined declarations
`pub` is valid on `func`, `struct`, `enum`, `bitfield`, `const`, `var`, `compt`.
Not on `extern` (always public), not on `test` (never exported).

### `String` is uppercase
Signals it is a managed type, not a primitive. Lowercase types (`i32`, `bool`, `f32`)
are primitives with no runtime overhead. `String` carries length and is heap-allocated.
`string` was rejected — too easy to confuse with a primitive.

### Compiler functions are keywords, not `@`-prefixed
`cast`, `assert`, `size`, `align`, `copy`, `move`, `swap`, `typename`, `typeid` — reserved keywords, called like regular functions. The `@` prefix was borrowed from Zig but added visual noise for no benefit. Keyword status already makes them special; the sigil was redundant. These names cannot be used for user-defined functions.

### No implicit casting
All type conversions go through `cast(T, val)`. Silent coercions are a common source
of bugs. The explicitness is intentional — if you are casting, it should be visible.

### `compt` only on declarations and statements
`compt X: i32 = 1`, `compt func f()`, `compt for(...)`. Never inline on arbitrary
expressions. If you need a compile-time value inside a runtime function, extract it
into a `compt func` and call it. Keeping `compt` at statement level makes it easy
to audit what runs at compile time.

### No `inline` keyword
`compt func` covers the use case. One keyword for compile-time, not two.

### No labeled `break` / `continue`
`break label` and `continue label` are compiler errors. Labels add syntax complexity for a rare use case — breaking out of nested loops is always clearer as a function with `return`. The `label` keyword does not exist.

### `@type` removed — `is` / `is not` covers everything
`@type(x)` was removed. `is` / `is not` handles all type checking, at both runtime and compile time, including inside `compt func`. Simpler surface, no redundancy.

### `is` / `is not` for type comparison
`result is Error`, `result is not null`. Not `==` on types, not `typeof(x) == Y`.
Reads as English, avoids confusion with value equality.

### `Error` is a human-readable string, not a code
`Error("something went wrong")` — no error codes, no error enums, no numeric IDs.
Kodr errors are for humans. If you need structured errors, use a struct.

### `match` on strings desugars to `if/else` chain
Zig has no string switch. Rather than expose this limitation, Kodr hides it — the
compiler generates `if (std.mem.eql(...)) ... else if ...` automatically. The Kodr
syntax is the same regardless of the matched type.

---

## Compiler & Output

### Overflow helpers are functions, not operators
`wrap(a + b)`, `sat(a + b)`, `overflow(a + b)` — not new operator syntax like `+%`.
Operator syntax would require parser changes and is harder to search for. Function
call form is explicit, greppable, and does not pollute the operator table.

### Warnings fire once per module, not per usage
`RawPtr` and similar unsafe constructs emit one warning per module, not one per call
site. Repeated warnings on the same issue are noise. If the developer uses `RawPtr`
ten times, they know — one warning is enough.

### `main.bitsize` sets numeric literal defaults
`main.bitsize = 32` means untyped integer literals default to `i32` and float literals
to `f32`. This controls the entire module. No per-expression type inference guessing.

---

## Module System

### Module name must match anchor file stem
`module math` requires a file named `math.kodr` to exist as the anchor. Other files
in the module can be named anything, but the anchor name is enforced. This makes
modules discoverable without reading file headers.

### Dead modules are skipped entirely
A module that is never imported is not compiled. No warnings, no errors — it simply
does not participate in the build. This enables having library modules in a project
that are opt-in.
