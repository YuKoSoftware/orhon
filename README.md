# Kodr

**A simple yet powerful language that is safe.**

Kodr is a compiled, memory-safe programming language that transpiles to Zig. It draws the best from Rust, Go, Swift, Zig, and Python — and discards the complexity.

---

## Why Kodr?

| | |
|---|---|
| **Safe** | Memory safety at compile time. Ownership, borrow checking, no use-after-free, no null dereference. No runtime overhead. |
| **Simple** | Minimal keywords. Minimal special cases. Learnable in a weekend. No fighting the type system. |
| **Fast** | Zero-cost abstractions. No GC pauses. Cross-compiles anywhere. Zig handles the ABI. |
| **Explicit** | No hidden control flow. No default allocator. No magic. Every allocation is intentional. |

---

## A Taste of Kodr

```
module main

main.build = build.exe

import std::console
import std::mem

// Structs with methods
struct Player {
    pub name: string
    health: f32 = 100.0

    func isAlive(self: const &Player) bool {
        return self.health > 0.0
    }

    func takeDamage(self: var &Player, amount: f32) void {
        self.health = self.health - amount
    }
}

// Error handling — explicit unions, no exceptions
func divide(a: i32, b: i32) (Error | i32) {
    if(b == 0) { return Error("division by zero") }
    return a / b
}

func main() void {
    // Ownership — values move, borrows are checked
    var p = Player(name: "hero")
    p.takeDamage(30.0)

    if(p.isAlive()) {
        console.println(p.name)
    }

    // Error handling — is/is not for type checks
    var result = divide(10, 2)
    if(result is Error) {
        console.println("error!")
        return
    }
    console.println(result.i32)

    // Explicit allocation — no default allocator
    var a = mem.GPA()
    var data: []i32 = a.alloc(i32, 64)
    defer a.free(data)

    // Threads with move semantics — no shared mutable state
    var left, right = data.splitAt(32)
    Thread([]i32) t1 { return left }
    Thread([]i32) t2 { return right }
    var l = t1.value
    var r = t2.value
}

test"damage reduces health" {
    var p = Player(name: "test")
    p.takeDamage(50.0)
    @assert(p.health == 50.0)
    @assert(p.isAlive())
}
```

---

## Key Features

- **Ownership & borrow checking** — compile-time memory safety, no GC
- **Explicit allocators** — `mem.GPA()`, `mem.Arena()`, `mem.Temp(n)`, `mem.Page()`
- **Error & null as types** — `(Error | T)` and `(null | T)` unions, handled explicitly
- **`is` / `is not`** — clean type comparisons at the call site
- **Structs & enums** — methods, data-carrying variants, bitfield enums
- **Threads & async** — move semantics enforced, no accidental sharing
- **`compt`** — compile-time variables, functions, and loop unrolling
- **Zig bridge** — `extern func` + paired `.zig` for C interop, no C in Kodr
- **No build files** — `kodr build`, `kodr run`, `kodr test` — fully integrated
- **One module = one generated `.zig` file** — readable output, transparent codegen

---

## Language Documentation

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
| [16-style.md](docs/16-style.md) | Style guide |
| [17-example.md](docs/17-example.md) | Complete language example |

---

## Status

**Phase 2** — full pipeline working end-to-end. 110 tests passing.

Transpiles to Zig 0.15.x. No bundled binary — Zig installed globally.

```bash
kodr init myproject    # create a new project
kodr build             # compile
kodr run               # build and run
kodr test              # run all test blocks
```

---

## Non-Goals

- Not garbage collected
- Not platform-specific
- Not a scripting language
- No built-in async runtime forced on you
- No operator overloading
- No implicit anything
