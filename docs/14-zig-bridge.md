# Zig Modules — Using `.zig` Files as Orhon Modules

Orhon handles all external interop through Zig. Orhon never talks to C, system APIs,
or external libraries directly — that complexity lives in `.zig` files. Zig already
has first-class C interop, handles ABI, calling conventions, and struct layouts. No
need to duplicate that work in Orhon.

The Zig module system is universal — the standard library uses the same mechanism as
user code.

---

## How It Works

Any `.zig` file in `src/` automatically becomes an Orhon module. The compiler:

1. Discovers `.zig` files in `src/` (recursive, skips `_`-prefixed files)
2. Parses them with `std.zig.Ast`
3. Extracts `pub` declarations and maps Zig types to Orhon types
4. Generates an internal `.orh` module (cached in `.orh-cache/`)
5. Codegen emits re-exports from the `.zig` file
6. Build system wires the `.zig` file as a named Zig module

From Orhon's perspective, the result is a regular module you can `import`.

```
// src/mylib.zig — just a Zig file
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub const GREETING = "hello";

pub const Calculator = struct {
    value: i32,
    pub fn create() Calculator { return .{ .value = 0 }; }
    pub fn addValue(self: *Calculator, x: i32) void { self.value += x; }
};
```

```
// src/app.orh — Orhon code using the Zig module
module app
#build = exe

import mylib

func main() {
    var sum: i32 = mylib.add(10, 32)
    var calc: mylib.Calculator = mylib.Calculator.create()
}
```

---

## Type Mapping

The compiler maps Zig types to Orhon types automatically:

| Zig | Orhon |
|-----|-------|
| `u8`, `i32`, `f64`, `bool`, `void`, `usize` | same |
| `[]const u8` | `str` |
| `?T` | `(null \| T)` |
| `anyerror!T` | `(Error \| T)` |
| `*T` | `mut& T` |
| `*const T` | `const& T` |
| `comptime T: type` | `T: type` (no `compt` keyword — `type` implies comptime) |
| `anytype` | `any` |

---

## What Gets Skipped

Declarations with unmappable types are silently excluded from the generated module.
If any parameter or return type can't be mapped, the entire function is skipped.

Common unmappable types:
- `std.mem.Allocator`, `std.io.Writer` — Zig stdlib types
- `[]T` (slices other than `[]const u8`) — no Orhon equivalent yet
- `[*]T`, `[*c]T` — many-item and C pointers

**To make a function available to Orhon:** adjust its signature to use mappable types.
This is far less work than writing a full interface declaration.

---

## Underscore Convention

Files starting with `_` are private — they won't be converted to modules:

```
src/
  mylib.zig        → becomes module mylib
  _helpers.zig     → ignored (private)
  _internal.zig    → ignored (private)
```

Use this for Zig implementation files that are imported by other `.zig` files but
shouldn't be exposed as Orhon modules.

---

## Structs and Methods

Public structs with public methods are fully supported:

```zig
pub const SMP = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    pub fn create() SMP { ... }
    pub fn deinit(self: *SMP) void { ... }
    pub fn allocator(self: *SMP) std.mem.Allocator { ... }
};
```

The compiler maps self-parameter patterns:
- `self: *StructName` → `self: mut& StructName`
- `self: *const StructName` → `self: const& StructName`
- `self: StructName` → `self: StructName`

Methods with unmappable non-self parameters are skipped individually — the struct
still appears with its other methods.

---

## Constants

Simple constants with literal values are mapped:

```zig
pub const RED = "\x1b[31m";    // → pub const RED: str = "\x1b[31m"
pub const MAGIC = 42;          // → pub const MAGIC: i64 = 42
```

Constants with complex initializers (function calls, struct literals) are skipped.

---

## C Interop

C dependencies are configured through a paired `.zon` file next to the `.zig` module.
The Zig module handles the actual C FFI:

```zig
// src/mylib.zig
const c = @cImport(@cInclude("vulkan/vulkan.h"));

pub fn init() bool {
    // Use c.vkCreateInstance etc.
}
```

```zig
// src/mylib.zon — build config for C dependencies
.{
    .link = .{ "vulkan" },
}
```

```
// src/app.orh — just import and use
module app
#build = exe

import mylib

func main() {
    mylib.init()
}
```

### `.zon` Config Reference

All fields are optional. No `.zon` file needed if there are no C dependencies.

```zig
.{
    .link = .{ "SDL2", "openssl" },           // system libraries
    .include = .{ "vendor/" },                 // header search paths
    .source = .{ "vendor/stb_image.c" },       // C/C++ source files
    .define = .{ "SDL_MAIN_HANDLED" },         // preprocessor defines
}
```

| Field | Purpose | build.zig call |
|-------|---------|---------------|
| `.link` | System libraries | `linkSystemLibrary()` |
| `.include` | Header search paths | `addIncludePath()` |
| `.source` | C/C++ source files | `addCSourceFiles()` |
| `.define` | Preprocessor macros | not yet implemented |

Local `.c`/`.cpp` files in the same directory as the `.zig` file are auto-detected —
`.source` is only needed for files in other directories.

---

## Standard Library

The stdlib uses the same mechanism. Each stdlib module is a `.zig` file in `src/std/`
that gets auto-converted. The only exception is `linear.orh` which is pure Orhon.

To see what's available in a stdlib module, read the `.zig` source directly — every
`pub fn`, `pub const`, and `pub struct` with mappable types will be available.
