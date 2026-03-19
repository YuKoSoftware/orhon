# Build System & CLI

Fully integrated into the compiler. No build files ever.

```
kodr build                  // debug build, native platform
kodr build -x64 -release    // 64-bit release build
kodr build -arm -fast       // ARM, max optimization
kodr build -wasm            // WebAssembly target
kodr run                    // build and run
kodr run -x64               // build and run for x64
kodr test                   // run all test blocks
kodr build -zig             // show raw Zig compiler output — for compiler developers only
kodr init <name>            // create a new project in ./<name>/
kodr initstd                // create std/ and global/ folders next to the kodr binary
kodr addtopath              // add kodr to PATH in your shell profile
kodr debug                  // dump project info: source dir, modules found, files
```

---

## Zig Output Suppression

Kodr fully controls what the user sees. The Zig compiler runs silently under the hood — its output is captured and never shown to the user under normal operation.

If Zig compilation succeeds — all Zig output is suppressed. The user only sees Kodr's own output.

If Zig compilation fails due to a codegen bug — Kodr reformats the error in its own clean format. Raw Zig errors are never shown unless `-zig` flag is explicitly passed.

```
// normal mode — user never sees Zig output
kodr build

// compiler developer mode — raw Zig output visible
kodr build -zig
```

In a correctly implemented compiler, Zig errors should never reach the user — all issues are caught by Kodr's analysis passes before code generation. The `-zig` flag exists purely for debugging the compiler itself during development.

---

## Generated Zig Output — One File per Module

Each Kodr module compiles to exactly one Zig source file. Kodr is essentially a transpiler — its entire job is producing a valid Zig project from Kodr source. Everything after that is Zig's responsibility.

```
.kodr source files
    ↓ Kodr compiler (all passes in memory)
.kodr-cache/generated/*.zig    ← Kodr's responsibility ends here
    ↓ Zig compiler
zig-cache/                     ← Zig's responsibility (object files, binary)
    ↓
final binary
```

Kodr never deals with object files — that is entirely Zig's concern. Zig has its own cache (`zig-cache/`) where it manages compiled objects and incremental compilation at the binary level.

All generated files live in `.kodr-cache/generated/` and should never be edited manually.

```
bin/
    <project_name>       // final binary — named from main.name metadata, or module name

.kodr-cache/
    generated/
        math.zig        // generated from module math
        player.zig      // generated from module player
        utils.zig       // generated from module utils
        main.zig        // generated from module main
        build.zig       // generated Zig build file
    timestamps          // flat text — maps .kodr files to last modification time
    deps.graph          // flat text — module dependency graph
```

`timestamps` format:
```
src/player.kodr 1710234567
src/utils.kodr  1710234123
main.kodr       1710234890
```

`deps.graph` format:
```
main → player, math, utils
player → math
math →
utils →
```

Both are plain text — human readable, easy to delete, never committed to version control. `.kodr-cache` belongs in `.gitignore`.

Example generated `math.zig`:
```zig
// generated from module math — do not edit
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn divide(a: i32, b: i32) i32 {
    if (b == 0) { /* error handling */ }
    return @divTrunc(a, b);
}
```

Example generated `main.zig`:
```zig
// generated from module main — do not edit
const std = @import("std");
const math = @import("math.zig");
const player = @import("player.zig");

pub fn main() void {
    const result = math.divide(10, 2);
}
```

---

## Incremental Compilation

Checked at Module Resolution — unchanged modules skip all passes and reuse cached `.zig` files. Works at two levels:
- **Kodr level** — unchanged modules skip passes 4-12 entirely, cached `.zig` file reused
- **Zig level** — Zig's own incremental compilation handles object files and binary caching independently
- Only changed modules and their dependents regenerate `.zig` files
- Kodr cache stored in `.kodr-cache/`, Zig cache in `zig-cache/` — separate concerns, no overlap
