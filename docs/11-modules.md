# Modules & Project Metadata

## Module Declaration

Every `.orh` file must declare its module at the top — this is mandatory, no exceptions.
The module tag is the only thing that determines which module a file belongs to.
Folder structure, file names, and directory nesting have no significance whatsoever.

```
module math
```

### How the Compiler Finds Modules
The compiler scans all `.orh` files in `src/`, reads the module tag at the top of each,
and groups files by module name. Each group becomes one **compilation unit**.

- File location doesn't matter — `src/math.orh`, `src/extra/more_math.orh`,
  `src/deep/nested/stuff.orh` — all fine as long as they declare `module math`
- Folder organization is purely for the developer's convenience
- The compiler only cares about module tags, not paths

### File Naming Rules — Anchor File
Among all files in a module, exactly one must be named after the module — the **anchor file**.
This is what `import math` resolves to. Only the anchor file can contain metadata
(`#build`, `#name`, `#version`, `#dep`, etc.).

- `module math` → one of the files must be `math.orh` (anywhere in `src/`)
- `module myproj` → one of the files must be `myproj.orh`
- Other files in the same module can be named anything
- No anchor file found = hard compiler error
- Every project root is named after the project folder — for both executables and libraries

Example — module math spanning three files, freely organized:
```
src/
    math.orh              ← anchor file — required
    utils/algebra.orh     ← also module math, any location
    utils/geometry.orh    ← also module math, any location
```

All three declare `module math`. The compiler groups them into one compilation unit.
Parallel compilation: each module compiles independently of others.

### Two Kinds of Modules

**Regular module** — no `build`, compiled as part of whatever project imports it:
```
// math.orh — anchor file, must exist
module math

pub func add(a: i32, b: i32) i32 { }

// algebra.orh — also part of module math, any name is fine
module math

pub func solve(a: f64, b: f64, c: f64) f64 { }
```
Regular modules are only compiled if something imports them (dead code elimination).

**Project root** — named after the project folder. Metadata uses `#key = value`:
```
// myproj.orh — project root for executable
module myproj

#build   = exe
#version = (1, 0, 0)
#name    = "myproj"

func main() void {
    // entry point — required for #build = exe
}
```

```
// mylib.orh — project root for library
module mylib

#build   = static
#version = (1, 0, 0)
#name    = "mylib"
```

### Primary Module Detection

The **primary module** is the exe module whose name matches the project folder name and
whose anchor file lives directly in `src/` (not in a subdirectory). This is the module
`orhon run` builds and executes.

Rules:
- Module name == project folder name → primary module
- Anchor file must be at `src/<name>.orh` (top-level, not nested)
- All other `#build = exe` modules must have their anchor file in a subdirectory of `src/`
- Only one primary module per project — having two top-level exe anchors is a hard compiler error

```
myproj/
    src/
        myproj.orh          ← primary module anchor (module myproj, #build = exe)
        player.orh          ← also module myproj — additional file
        tools/tools.orh     ← module tools, #build = exe (non-primary exe — must be in subdir)
```

### Additional Library Modules
A project can contain additional library modules alongside the root.
Each has its own anchor file and build declaration:
```
src/
    myproj.orh            ← module myproj, #build = exe (root)
    math/math.orh         ← module math, #build = static (anchor)
    math/vectors.orh      ← module math (additional file)
    network/network.orh   ← module network, #build = dynamic (anchor)
```
Library modules are only built as separate artifacts if they are actually imported.

### Multi-module Project
```
myproj/
    src/
        myproj.orh              // root — module myproj, #build = exe
        player.orh              // module myproj — additional file
        math/math.orh           // module math, #build = static (anchor)
        math/vectors.orh        // module math — additional file
        utils/utils.orh         // module utils — regular module (no #build)
```

---

## Import Syntax

Two ways to bring a module into scope: `import` (namespaced) and `use` (flat). Both
import the whole module — compiler eliminates dead code automatically. No symbol lists,
no wildcard imports.

### `import` — namespaced access

Access symbols through the module name (or alias). The module name acts as a namespace:

```
// Project-local module
import math
math.add(1, 2)

// Stdlib module — std:: scope
import std::collections
var list: collections.List(i32) = collections.List(i32).new()

// With alias — as renames the access prefix
import std::alpha as io
io.println("hello")
```

### `use` — flat access (scope merge)

Brings all `pub` symbols directly into the current scope. No prefix needed:

```
use std::collections
var list: List(i32) = List(i32).new()

use std::alpha
println("hello")
```

`use` does not support `as` aliasing — since names are merged into scope, there is
no prefix to rename.

### `import` vs `use` summary

| | `import` | `use` |
|---|----------|-------|
| Access | `module.symbol` | `symbol` |
| Aliasing | `import X as Y` | not supported |
| Name conflicts | explicit via prefix | can collide with local names |
| When to use | default choice — clear provenance | when you use many symbols from one module |

Both compile to the same thing — `use` generates re-exports so symbols appear local.
Zero runtime difference.

### Scope rules
- No `::` → project-local (`src/`)
- `std::name` → embedded stdlib (auto-extracted to `.orh-cache/std/`)
- Only one level of `::` — `std::a::b` is never valid
- `std` is reserved — cannot be a project module name
- Default alias is always the module name, never the scope prefix

### Naming Collision Resolution
Use `as` to disambiguate modules with the same name:
```
import std::utils as std_utils
import utils as my_utils

std_utils.trim("hello")
my_utils.doSomething()
```

### Library Interface File
When compiling a `#build = static` or `#build = dynamic` module (see [[13-build-cli]]), the compiler generates
a `.orh` interface file alongside the binary output. This file contains only the
`pub` declarations — functions, types, structs — and serves as the public API surface.

```
mylib.a        // compiled binary
mylib.orh     // generated interface — pub declarations only, for type checking
```

The interface file is a valid Orhon source file. Consumers can read it to understand
the library's public API. The compiler uses it for type checking when importing
a precompiled library without its full source.

### Visibility
- Everything private by default
- `pub` makes a symbol or struct field accessible outside the module
- No wildcard imports ever
- No circular imports ever — hard compiler error, across all project boundaries
- Diamond dependencies safe — compiler deduplicates, each module compiled exactly once

### Hard Compiler Errors
- Circular imports across any boundary
- Project metadata written in any file other than the anchor file
- No anchor file found — at least one file in the module must be named after the module
- Primary module anchor not at `src/<name>.orh` (must be top-level, not nested)
- Two `#build = exe` anchors at `src/` top-level
- `func main()` used outside a `#build = exe` anchor file
- `func main()` missing when `#build = exe`
- Unknown import scope (only `std` is supported)
- `func main()` present when `#build = static` or `#build = dynamic`

---

## Project Metadata

Declared in anchor files only using `#key = value` syntax. Writing metadata in any
file other than the anchor is a hard compiler error. No build files ever — the
compiler is the build system.

```
// myproj.orh — executable
module myproj

#name    = "myproj"
#version = (1, 0, 0)
#build   = exe

func main() void { }
```

```
// mylib.orh — library project root
module mylib

#name    = "mylib"
#version = (1, 0, 0)
#build   = static
```

```
// math/math.orh — additional library module within a project
module math

#build = static
#name  = "math"
```

### Build Types
- `#build = exe` — `func main()` required, produces runnable binary
- `#build = static` — no `func main()` needed, produces `.a` or `.lib` + `.orh` interface file
- `#build = dynamic` — no `func main()` needed, produces `.so` or `.dll` + `.orh` interface file

### External Dependencies

Declared with `#dep` in the anchor file. The compiler never fetches dependencies —
the developer places them at the declared paths.

```
#dep "./libs/mylib" (1, 0, 0)   // path + minimum version
#dep "./libs/utils"                     // path only — no version check
```

**Version semantics** — `(x, y, z)` is the minimum required version:
- Exact match → silent
- Library is newer → warning: `mylib is version 1.2.0, expected 1.0.0`
- Library is older → hard compiler error: `mylib version 0.9.0 below required 1.0.0`
- No version specified → no check performed

The library declares its version in its anchor file:
```
#version = (1, 0, 0)
```

**Dependency types:**
- `#build = static` / `#build = dynamic` — compiled as a separate artifact, linked into the project
- Regular module (no `#build`) — source files added to the compiler scan, compiled into the importer

**Import syntax** is unchanged — `import mylib`. No new scope needed. Deps resolve
the same way as project-local modules, just sourced from the declared path.

**Transitive dependencies** — if `mylib` has its own deps, they live inside `mylib`'s
folder. The consuming project does not declare them.
