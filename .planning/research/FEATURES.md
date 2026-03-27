# Feature Landscape

**Domain:** Programming language design for Orhon evolution
**Researched:** 2026-03-27

## Table Stakes

Features users expect from a modern compiled language. Missing = Orhon feels incomplete.

| Feature | Why Expected | Complexity | Status |
|---------|--------------|------------|--------|
| Error propagation operator (`try`) | Every modern language has one (Rust `?`, Zig `try`, Swift `try`) | Low | NOT IMPLEMENTED |
| Pattern guards in match | Standard in ML-family, Rust, Swift, Gleam | Low | In TODO |
| Constrained generics | Unchecked generics feel like C++ templates; users expect Rust-style bounds | Medium | In TODO as "generic constraints" |
| Good error messages | Elm/Gleam/Rust set the bar; "did you mean?" is expected | Medium | In TODO, basic |
| Formatter with line-length | Every modern language ships one | Medium | Basic formatter exists, line-length missing |
| Closures / lambdas | Expected for callbacks, event handlers, functional patterns | Medium | In TODO |
| Async / IO concurrency | Expected for any networked application | High | In TODO, deferred |

## Differentiators

Features that set Orhon apart. Not expected but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Traits + `#derive` | Eliminate boilerplate for Eq, Hash, Debug, Clone | Medium | Requires traits as prerequisite |
| Union spreading | Compose union types from other unions | Low | In TODO, Tamga needs this |
| `try...else` error context | Add context to propagated errors | Low | Novel ergonomic improvement |
| Binding generator (`orhon bindgen`) | Auto-generate bridge files from C headers | High | Major productivity win for FFI-heavy projects |
| Web playground | Try Orhon in browser, lowers adoption barrier | Medium | Leverages existing WASM target |
| Compile-time reflection | Inspect type structure in compt functions | Medium | Enables serialization, generic algorithms |
| `#extern` struct layout | C-compatible struct layout for FFI | Low | Needed for serious C interop |

## Anti-Features

Features to explicitly NOT build.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Macros | Unreadable code, complex implementation, Zig chose against them | Use `compt` for type generation, `#derive` for common patterns |
| Algebraic effects | Too complex for the target audience, academic | Union-based errors + bridge-based I/O |
| Structural typing / row polymorphism | Contradicts nominal type system, weakens type safety | Traits for ad-hoc polymorphism |
| Garbage collection | Contradicts systems language positioning | Explicit allocators (already have SMP, Arena, Page) |
| Exceptions | Union-based errors are strictly better for compiled languages | `(Error \| T)` + `try` |
| Operator overloading | Leads to unreadable code, hides behavior | Named methods |
| Multiple inheritance | Complexity without proportional benefit | Composition via struct embedding, multiple trait impls |
| Implicit conversions | Source of subtle bugs | Explicit `cast()` |
| Lifetime annotations | Orhon's #1 differentiator vs Rust is NOT having these | Lexical lifetimes + no reference returns |
| REPL | Compiled language, doesn't fit | Web playground instead |

## Feature Dependencies

```
Traits -> Constrained Generics (requires trait bounds)
Traits -> #derive (derive generates trait implementations)
Closures -> Functional patterns (map, filter, fold on collections)
try keyword -> try...else (error context extension)
C/C++ compilation -> Tamga VMA, serious FFI projects
WASM target (exists) -> Web playground
Tree-sitter grammar -> Multi-editor highlighting
```

## MVP Recommendation (Next 3 Phases)

Prioritize:
1. `try` keyword -- highest impact per line of implementation, every user benefits
2. Pattern guards -- small feature, big ergonomic win, already in TODO
3. Error message improvements -- "did you mean?", expected vs actual, fix suggestions
4. Traits (minimal) -- methods only, explicit impl, no inheritance
5. Constrained generics -- `any where Trait`, unlocked by traits

Defer:
- `async` -- complex, needs design research, thread covers CPU parallelism
- Web playground -- needs stable WASM pipeline, lower priority than language features
- Binding generator -- big project, manual bridge writing works for now
- Compile-time reflection -- powerful but not urgent

## Sources

- Training data analysis of language feature trends (MEDIUM confidence)
- Orhon project docs: TODO.md, all spec files (02-types through 15-testing)
- Observed patterns from Gleam, Rust, Zig, Swift, Go communities
