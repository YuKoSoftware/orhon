# Orhon

**A simple yet powerful language that is safe.**

Orhon is a compiled, memory-safe programming language that transpiles to Zig. It takes Rust's ownership model and Zig's simplicity — and cuts the ceremony.

You get ownership and borrow checking without lifetime annotations. Thread safety enforcement at compile time. Explicit error handling without exceptions. Compile-time generics without the complexity. Zero-cost abstractions without a garbage collector.

The compiler catches memory bugs, null dereference, use-after-move, and unsafe thread sharing at compile time. What it generates is readable Zig — one module, one `.zig` file, fully transparent.

Cross-compiles to Linux, Windows, macOS, and WebAssembly. Ships with an LSP server and a VS Code extension.

---

## Getting Started

```bash
orhon init myproject    # create a new project
cd myproject
orhon build             # compile
orhon run               # build and run
orhon test              # run all test blocks
```

Every new project includes an example module that covers the core language. Read it, modify it, break it — that's the tutorial.

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
| [10-structs-enums.md](docs/10-structs-enums.md) | Structs, enums, bitfields, generic structs |
| [11-modules.md](docs/11-modules.md) | Modules, imports, project metadata |
| [12-concurrency.md](docs/12-concurrency.md) | Threads, ownership and threads |
| [13-build-cli.md](docs/13-build-cli.md) | Build system, CLI, generated Zig output |
| [14-zig-bridge.md](docs/14-zig-bridge.md) | Extern bridge, safety rules, generic bridge types |
| [15-testing.md](docs/15-testing.md) | Testing |

---

## Non-Goals

- Not garbage collected
- Not platform-specific
- Not a scripting language
- No operator overloading
- No implicit anything
