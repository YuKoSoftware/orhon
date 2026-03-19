# Modules & Project Metadata

## Module Declaration

Every `.kodr` file must declare its module at the top — this is mandatory, no exceptions.
The module tag is the only thing that determines which module a file belongs to.
Folder structure, file names, and directory nesting have no significance whatsoever.

```
module math
```

### How the Compiler Finds Modules
The compiler scans all `.kodr` files in `src/`, reads the module tag at the top of each,
and groups files by module name. Each group becomes one **compilation unit**.

- File location doesn't matter — `src/math.kodr`, `src/extra/more_math.kodr`,
  `src/deep/nested/stuff.kodr` — all fine as long as they declare `module math`
- Folder organization is purely for the developer's convenience
- The compiler only cares about module tags, not paths

### File Naming Rules — Anchor File
Among all files in a module, exactly one must be named after the module — the **anchor file**.
This is what `import math` resolves to. Only the anchor file can contain build metadata
(`main.build`, `main.name`, `main.version`, `main.bitsize`, etc.).

- `module math` → one of the files must be `math.kodr` (anywhere in `src/`)
- `module main` → one of the files must be `main.kodr`
- Other files in the same module can be named anything
- No anchor file found = hard compiler error
- Every project root is `main.kodr` / `module main` — for both executables and libraries

Example — module math spanning three files, freely organized:
```
src/
    math.kodr              ← anchor file — required
    utils/algebra.kodr     ← also module math, any location
    utils/geometry.kodr    ← also module math, any location
```

All three declare `module math`. The compiler groups them into one compilation unit.
Parallel compilation: each module compiles independently of others.

### Two Kinds of Modules

**Regular module** — no `build`, compiled as part of whatever project imports it:
```
// math.kodr — anchor file, must exist
module math

pub func add(a: i32, b: i32) i32 { }

// algebra.kodr — also part of module math, any name is fine
module math

pub func solve(a: f64, b: f64, c: f64) f64 { }
```
Regular modules are only compiled if something imports them (dead code elimination).

**Project root** — always `main.kodr` / `module main`. All metadata uses the `main.*` prefix:
```
// main.kodr — project root for executable
module main

main.build = build.exe
main.version = Version(1, 0, 0)
main.name = "my_project"

func main() void {
    // entry point — required for build.exe
}
```

```
// main.kodr — project root for library
module main

main.build = build.static
main.version = Version(1, 0, 0)
main.name = "mylib"
```

### Additional Library Modules
A project can contain additional library modules alongside the root.
Each has its own anchor file and build declaration:
```
src/
    main.kodr              ← module main, build.exe (root)
    math/math.kodr         ← module math, build.static (anchor)
    math/vectors.kodr      ← module math (additional file)
    network/network.kodr   ← module network, build.dynamic (anchor)
```
Library modules are only built as separate artifacts if they are actually imported.

### Multi-module Project
```
my_project/
    src/
        main.kodr                // root — module main, build.exe
        player.kodr              // module main — additional file
        math/math.kodr           // module math, build.static (anchor)
        math/vectors.kodr        // module math — additional file
        utils/utils.kodr         // module utils — regular module (no build)
```

---

## Import Syntax

Import the whole module — compiler eliminates dead code automatically. No symbol lists, no wildcard imports.

Three import forms — origin is always explicit:

```
// Project-local module — no scope, looks in src/
import math
math.add(1, 2)

// Stdlib module — std:: scope, looks in <kodr_dir>/std/
import std::alpha
alpha.println("hello")

// Global shared module — global:: scope, looks in <kodr_dir>/global/
import global::utils
utils.trim("  hello  ")

// With alias — as renames the access prefix
import std::alpha as io
io.println("hello")

// External libraries (C, system) — use a Zig bridge file, see zig-bridge doc
import global::gtk     // gtk.kodr + gtk.zig — Zig handles C under the hood
import global::sdl     // sdl.kodr + sdl.zig
```

**Scope rules:**
- No `::` → project-local (`src/`)
- `std::name` → `<kodr_dir>/std/name.kodr`
- `global::name` → `<kodr_dir>/global/name.kodr`
- Only one level of `::` — `std::a::b` is never valid
- `std` and `global` are reserved — cannot be project module names
- Default alias is always the module name, never the scope prefix

### Naming Collision Resolution
Use `as` to disambiguate modules with the same name:
```
import std::utils as std_utils
import global::utils as my_utils

std_utils.trim("hello")
my_utils.doSomething()
```

### Precompiled Kodr Libraries *(not yet implemented — planned for later)*
When compiling a library, the compiler will generate a `.kodrm` metadata sidecar file.
This allows importing a precompiled library without needing its source — the `.kodrm`
contains the public interface (exported functions, types, struct layouts) for type checking.

```
mylib.a        // compiled binary
mylib.kodrm    // required metadata — pub symbols, types, functions
```

Missing `.kodrm` when importing a precompiled library is a hard compiler error.

### Visibility
- Everything private by default
- `pub` makes a symbol or struct field accessible outside the module
- No wildcard imports ever
- No circular imports ever — hard compiler error, across all project boundaries
- Diamond dependencies safe — compiler deduplicates, each module compiled exactly once

### Hard Compiler Errors
- Circular imports across any boundary
- Multiple `build` declarations — structurally impossible, only valid in root file
- Project metadata written in any file other than the root file
- No anchor file found — at least one file in the module must be named after the module
- `module main` not in `main.kodr`
- `func main()` missing when `build.exe`
- Unknown import scope (anything other than `std` or `global`)
- `extern func` with a body — extern functions must have no body
- `extern func` without a paired `.zig` file
- `func main()` present when `build.static` or `build.dynamic`

---

## Project Metadata

Declared in anchor files only. The metadata prefix is always the module name — `main.*` for `module main`, `math.*` for `module math`, etc. Writing project metadata in any file other than the anchor is a hard compiler error. No build files ever — the compiler is the build system.

```
// main.kodr — executable
module main

main.name = "my_project"
main.version = Version(1, 0, 0)
main.build = build.exe
main.bitsize = 32

func main() void { }
```

```
// main.kodr — library project root
module main

main.name = "mylib"
main.version = Version(1, 0, 0)
main.build = build.static
```

```
// math/math.kodr — additional library module within a project
module math

math.build = build.static
math.name = "math"
```

### Build Types
- `build.exe` — `func main()` required, produces runnable binary
- `build.static` — no `func main()` needed, produces `.a` or `.lib` + `.kodrm`
- `build.dynamic` — no `func main()` needed, produces `.so` or `.dll` + `.kodrm`

`build` is a compiler-known enum. No import needed.

### External Dependencies

Not yet implemented. See `docs/FUTURE.md`.
