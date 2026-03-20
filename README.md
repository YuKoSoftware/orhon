# Kodr

**A simple yet powerful language that is safe.**

Kodr is a compiled, memory-safe programming language that transpiles to Zig. It draws the best from Rust, Go, Swift, Zig, and Python — and discards the complexity.

You get ownership and borrow checking without lifetime annotations. Explicit error handling without exceptions. Compile-time generics without a type-level language. Zero-cost abstractions without a garbage collector.

The compiler catches memory bugs, null dereference, and use-after-move at compile time. What it generates is readable Zig — one module, one `.zig` file, fully transparent.

---

## Getting Started

```bash
kodr init myproject    # create a new project
cd myproject
kodr build             # compile
kodr run               # build and run
kodr test              # run all test blocks
```

Every new project includes an example module that covers the entire language. Read it, modify it, break it — that's the tutorial.

Requires Zig 0.15.x installed globally.

---

## Documentation

The full language spec lives in [`docs/`](docs/):

| File | Topic |
|------|-------|
| [01-basics.md](docs/01-basics.md) | Philosophy, keywords, syntax rules, comments |
| [02-types.md](docs/02-types.md) | Primitive types, string literals, numeric literals, type system |
| [03-variables.md](docs/03-variables.md) | Variable declaration |
| [04-operators.md](docs/04-operators.md) | Operators, integer overflow |
| [05-functions.md](docs/05-functions.md) | Functions, compiler functions, builtin functions |
| [06-collections.md](docs/06-collections.md) | Arrays, slices, splitAt |
| [07-control-flow.md](docs/07-control-flow.md) | Loops, pattern matching, defer |
| [08-error-handling.md](docs/08-error-handling.md) | Error handling, null handling |
| [09-memory.md](docs/09-memory.md) | Memory model, ownership, pointers, heap allocation |
| [10-structs-enums.md](docs/10-structs-enums.md) | Structs, enums |
| [11-modules.md](docs/11-modules.md) | Modules, imports, project metadata |
| [12-concurrency.md](docs/12-concurrency.md) | Thread, async, ownership and threads |
| [13-build-cli.md](docs/13-build-cli.md) | Build system, CLI, generated Zig output |
| [14-zig-bridge.md](docs/14-zig-bridge.md) | extern func, C interop, naming conventions |
| [15-testing.md](docs/15-testing.md) | Testing |

---

## Non-Goals

- Not garbage collected
- Not platform-specific
- Not a scripting language
- No built-in async runtime forced on you
- No operator overloading
- No implicit anything
