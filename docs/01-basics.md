# Basics

## Philosophy & Goals

### Inspiration
Kodr draws from five languages, taking the best of each and discarding what doesn't fit:

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

Every keyword in Kodr earns its place. No keyword exists for convenience alone.

```
func, var, const, if, else, for, while, return, import, pub,
match, struct, enum, defer, thread, null, void, compt,
any, module, test, and, or, not, main, as,
break, continue, true, false, extern, is,
cast, copy, move, swap, assert, size, align, typename, typeid
```

---

## Syntax Rules

- Braces `{}` for all code blocks
- No semicolons — each line does one job, newline terminates a statement
- Parentheses `()` required around `if` and `while` conditions
- No naming conventions enforced — style is up to the programmer
- No operator overloading — but math operators work element-wise on tuples (see operators doc)
- Shadowing is not allowed — compile time error
- Inner scopes can read outer scope variables

---

## Comments

```
// single line comment

/// reserved for future documentation generation — not yet implemented

/* block comment
   everything between is raw text
   useful for commenting out code */
```

Block comments use `/* */`. No nesting — the first `*/` closes the comment. Single-line `//` is preferred for regular comments; `/* */` is for temporarily disabling code blocks.
