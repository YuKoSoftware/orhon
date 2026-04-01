# Basics

## Philosophy & Goals

### Inspiration
Orhon draws from five languages, taking the best of each and discarding what doesn't fit:

| Language | Borrow | Reject |
|----------|--------|--------|
| Rust | Memory safety, ownership model, performance | Complexity, verbose lifetime annotations |
| Go | Simplicity, readable syntax, fast compilation | Garbage collection, feels restrictive |
| Swift | Expressive syntax, modern feel, powerful type system | Platform lock-in, complex toolchain |
| Zig | Low-level control, no hidden control flow, comptime | Verbosity |
| Python | Clean readable syntax, approachability | Poor performance, dynamic typing |

### One-sentence pitch
*"A simple yet powerful language that is safe."*

### Primary user
Developers who value simplicity and explicitness — people who appreciate what Rust and Go are trying to do, but want a language that doesn't make them fight the toolchain or the type system to get things done.

### Non-goals
- **Not garbage collected** — memory is managed at compile time through ownership
- **Not platform-specific** — first-class cross-compilation, no preferred OS or runtime
- **Not complex** — if a feature can be reasonably achieved with existing language constructs, it won't be added as a special mechanism
- **Not a scripting language** — no REPL-first design, not optimized for short throwaway scripts
- **Not opinionated about domain** — no built-in async runtime, no preferred paradigm forced on the user

### Core values (in priority order)
1. **Safety** — memory safety guaranteed at compile time, no undefined behavior
2. **Simplicity** — minimal keywords, minimal special cases, learnable in a weekend
3. **Performance** — zero-cost abstractions, no runtime overhead, no GC pauses
4. **Portability** — cross-compile anywhere, no platform lock-in

---

## Keywords

Every keyword in Orhon earns its place. No keyword exists for convenience alone.

```
func, var, const, if, elif, else, for, while, return, import, use, pub,
match, struct, enum, bitfield, blueprint, defer, thread, null, void, compt,
any, module, test, and, or, not, as, type,
break, continue, true, false, bridge, is, throw
```

Compiler functions (`@cast`, `@copy`, `@move`, `@swap`, `@assert`, `@size`, `@align`, `@typename`, `@typeid`) are not keywords — they are intrinsics called with the `@` prefix. See [[05-functions#Compiler Functions]].

---

## Syntax Rules

- Braces `{}` for all code blocks
- No semicolons — each line does one job, newline terminates a statement
- Parentheses `()` required around `if` and `while` conditions
- No naming conventions enforced — style is up to the programmer
- No operator overloading — but math operators work element-wise on tuples (see [[04-operators]])
- Shadowing is not allowed — compile time error
- Inner scopes can read outer scope variables

---

## Comments

```
// single line comment

/// doc comment — documents the declaration below it
/// multiple consecutive lines merge into one doc block

/* block comment
   everything between is raw text
   useful for commenting out code */
```

Block comments use `/* */`. No nesting — the first `*/` closes the comment. Single-line `//` is preferred for regular comments; `/* */` is for temporarily disabling code blocks.

Doc comments (`///`) attach to the declaration immediately below them. At the top of an anchor file (after `module`), they document the module itself. Consecutive `///` lines merge into a single doc block. A blank line between `///` and the declaration breaks the attachment. Use `orhon gendoc` to generate Markdown documentation from `pub` declarations and their doc comments.

---

## Design Rationale

Why Orhon makes the choices it does. These are intentional constraints, not missing
features.

### No closures — explicit context only

Closures implicitly capture variables from their environment. This creates hidden state,
makes ownership tracking ambiguous, and complicates the borrow checker. In Orhon, all
context is passed explicitly as function arguments. Loops with inner scope access cover
most closure use cases. For callbacks, pass context as arguments or wrap state in a struct.

**Inspiration:** Zig also has no closures for the same reasons.

### No lifetime annotations — scope-based ownership

Rust's lifetime annotations (`'a`, `'b`) are powerful but add significant cognitive load.
Orhon uses scope-based ownership: borrows are valid within the scope they're created in.
Non-lexical lifetimes (NLL) extend borrows to "last use" instead of "scope exit" —
capturing 85% of Rust's expressiveness without any annotation syntax.

**Trade-off:** Some valid programs are rejected. This is intentional — simpler mental
model wins over accepting every theoretically safe program.

### No operator overloading — named methods only

Operator overloading lets `+` mean anything — string concatenation, vector addition,
matrix multiplication, database queries. Reading code becomes guessing. In Orhon, `+`
always means numeric addition (or SIMD element-wise). Everything else uses named methods
(`concat`, `add`, `multiply`). The code says what it does.

### Nominal types — no structural typing

Two types with identical fields but different names are different types. `Point(x: f32,
y: f32)` and `Velocity(x: f32, y: f32)` are incompatible. This catches bugs at compile
time that structural typing would silently accept. It also makes code self-documenting —
the type name carries meaning.

### No exceptions — union-based errors

Exceptions create invisible control flow paths. Every function might throw, and nothing
in the signature tells you. Orhon uses `ErrorUnion(T)` wrapper types — the error possibility
is visible in the return type. `throw` propagates errors explicitly (see [[08-error-handling]]). The compiler tracks
error flow through every path.

### No garbage collection — compile-time memory management

Orhon is a systems language. GC pauses, unpredictable memory usage, and runtime overhead
contradict the performance goals. Memory is managed through ownership, borrowing, and
explicit allocators (see [[09-memory]]). The compiler verifies safety at compile time — no runtime cost.

### No macros — `compt` covers it

Macros are powerful but create a language-within-a-language. Code that looks like Orhon
but follows different rules. `compt` (compile-time evaluation, see [[05-functions]]) covers the same use
cases — type generation, constant computation, conditional compilation — using regular
Orhon syntax. What you write in a `compt` function is the same language you write
everywhere else.

**Inspiration:** Zig's `comptime` — same philosophy, same decision.

### Explicit `@cast()` — no implicit conversions

Implicit conversions cause subtle bugs. `i32` silently becoming `f64`, integers
narrowing without warning, boolean coercion from integers. In Orhon, every type
conversion is an explicit `@cast(TargetType, value)`. The code shows exactly where
types change. Narrowing casts emit a compiler warning.
