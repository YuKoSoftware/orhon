# Zig Bridge — `bridge` Declarations and Paired `.zig` Files

Orhon handles all external interop through Zig. Orhon never talks to C, system APIs,
or external libraries directly — that complexity always lives in a paired `.zig` file.
Zig already has first-class C interop, handles ABI, calling conventions, and struct
layouts. No need to duplicate that work in Orhon.

The bridge is universal — the standard library uses the same mechanism as user code.
Reading the stdlib source is the best way to learn the bridge pattern.

---

## How It Works

A module can be paired with a hand-written `.zig` sidecar. The `.orh` file declares
the interface using `bridge`. The `.zig` file provides the implementation in plain Zig.
The codegen re-exports from the sidecar — pure 1:1 translation, no special cases.

```
// console.orh — Orhon interface
module console

pub bridge func print(msg: String) void
pub bridge func println(msg: String) void
```

```zig
// console.zig — plain Zig implementation
const std = @import("std");

pub fn print(msg: []const u8) void {
    std.io.getStdOut().writer().writeAll(msg) catch {};
}

pub fn println(msg: []const u8) void {
    const w = std.io.getStdOut().writer();
    w.writeAll(msg) catch {};
    w.writeAll("\n") catch {};
}
```

---

## Bridge Safety Rules

Mutable references cannot cross the bridge in either direction. This ensures Orhon's
[[09-memory#Borrow Rules|safety guarantees]] are maintained at the boundary.

| Direction | `T` (value) | `const& T` | `mut& T` (mutable) |
|-----------|------------|------------|-----------------|
| Orhon → Zig | Move | Borrow (read) | **Not allowed** |
| Zig → Orhon | Owned | Borrow (read) | **Not allowed** |

**Exception:** `self: mut& BridgeStruct` on bridge struct methods is allowed — Zig
mutates its own data, not Orhon-owned data.

Violating this rule produces a compile error:
```
mutable reference 'mut& data' not allowed across bridge — use 'const& data' or pass by value
```

---

## `bridge` Declaration Types

Use `pub bridge` to make declarations visible outside the module. Without `pub`, bridge declarations are module-private — useful for internal implementation details wrapped by Orhon functions.
A paired `.zig` sidecar file must exist alongside the `.orh` file — hard error if missing.

### `bridge func` — bridge a function
```
bridge func print(msg: String) void
bridge func sqrt(x: any) any
```
No body. The Zig sidecar must have a matching `pub fn`.

### `bridge func` with default arguments
Default arguments provide ergonomics — users can omit parameters with sensible defaults.
The compiler fills defaults at the call site.
```
bridge func greet(name: String, prefix: String = "Hello") String
```
Calling `greet("world")` generates `greet("world", "Hello")` in Zig.

### `bridge const` — expose a Zig constant
```
bridge const PI: f64
```
The Zig sidecar must have a matching `pub const`.

### `bridge struct` — bridge a Zig type with methods
```
bridge struct Counter {
    bridge func create(start: i32) Counter
    bridge func get(self: const& Counter) i32
    bridge func increment(self: mut& Counter) void
}
```
The sidecar must have a matching struct with `pub fn` methods.

### `bridge struct` with type parameters — generic bridge types
```
bridge struct Box(T: type) {
    bridge func create(val: T) Box
    bridge func get(self: const& Box) T
    bridge func set(self: mut& Box, val: T) void
}
```
The sidecar implements this as a comptime function returning a type:
```zig
pub fn Box(comptime T: type) type {
    return struct {
        value: T,
        const Self = @This();
        pub fn create(val: T) Self { return .{ .value = val }; }
        pub fn get(self: *const Self) T { return self.value; }
        pub fn set(self: *Self, val: T) void { self.value = val; }
    };
}
```

---

## Orhon Wrappers Over Extern Types

The bridge `.orh` file can contain both bridge declarations and regular Orhon code.
This enables ergonomic wrappers — the bridge provides the raw Zig interface, and
Orhon code wraps it with defaults, validation, or convenience methods.

```
module mylib

// Raw bridge — thin bridge declarations
bridge struct RawList(T: type) {
    bridge func init(alloc: any) RawList
    bridge func append(self: mut& RawList, item: T) void
    bridge func deinit(self: mut& RawList) void
}

// Orhon API — ergonomic wrapper
pub struct List(T: type) {
    raw: RawList(T)

    pub func create() List {
        return List(raw: RawList(T).init(defaultAlloc()))
    }

    pub func add(self: mut& List, item: T) void {
        self.raw.append(item)
    }

    pub func free(self: mut& List) void {
        self.raw.deinit()
    }
}
```

---

## Error Union Return Types

When a `bridge func` returns `ErrorUnion(T)` (see [[08-error-handling]]), the Zig sidecar must return `anyerror!T`
(native Zig error union). Use Zig error codes for failures.

```zig
pub fn get() anyerror![]const u8 {
    return line;
    // or
    return error.end_of_input;
}
```

For nullable returns `NullUnion(T)`, use `?T` (native Zig optional):

```zig
pub fn find(key: []const u8) ?[]const u8 {
    return map.get(key); // returns value or null
}
```

---

## Calling C Through Zig

C interop goes through `.zig` bridge files. The `.orh` file exposes a clean Orhon API,
the `.zig` file handles all C details internally.

Use `#cimport` in the [[11-modules#Module Declaration|anchor file]] to declare C library dependencies. The block must
always include `name:` and `include:` keys. The compiler generates the correct
`linkSystemLibrary` + `linkLibC` calls and a shared `@cImport` wrapper module
in the build system.

```
// sdl.orh — clean Orhon interface
module sdl
#cimport = { name: "SDL3", include: "SDL3/SDL.h" }

pub bridge func init() void
pub bridge func quit() void
```

```zig
// sdl.zig — Zig handles all C interop
// The compiler generates a shared @cImport module; import it:
const c = @import("SDL_c").c;

pub fn init() void {
    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c.SDL_Quit();
}
```

### Block Syntax

The `#cimport` block uses colon-suffix keys with comma separators:

- `name:` — library name for linking and deduplication (required)
- `include:` — C header path (required)
- `source:` — C/C++ source file to compile (optional)

Unknown keys produce a compile error.

```
// Source-only library (no system lib linked)
#cimport = { name: "vma", include: "vk_mem_alloc.h", source: "../../src/vma_impl.cpp" }
```

When `source:` is present, the compiler skips `linkSystemLibrary` — the library name
is used only for project-wide identity and deduplication. C++ linking is auto-detected
from `.cpp`, `.cc`, or `.cxx` file extensions.

### One Library Per Project

Each C library can only be declared with `#cimport` once across the entire project.
Other modules access the library's C types by importing the owning bridge module:

```
// tamga_vk3d.orh — gets SDL types via import, not re-declaring #cimport
module tamga_vk3d
import tamga_sdl3
#cimport = { name: "vulkan", include: "vulkan/vulkan.h" }
```

Declaring `#cimport` with `name: "SDL3"` in both `tamga_sdl3` and `tamga_vk3d` is a compile error.

---

## Cross-Bridge Imports in Sidecars

When a `.zig` sidecar needs types or functions from another module's bridge sidecar,
use the **named module import** — the module name without the `.zig` extension:

```zig
// tamga_vk3d.zig — uses a type from another bridge
const sdl3 = @import("tamga_sdl3_bridge");  // named module — correct
// NOT: @import("tamga_sdl3_bridge.zig")    // file path — breaks build
```

The compiler registers each bridge sidecar as a named Zig module in the build graph
and wires cross-bridge dependencies via `addImport`. Named imports resolve through
the build system; file-path imports cause "file exists in two modules" errors.

**File-path `@import` is fine for helper files** that belong to the same bridge:

```zig
const helpers = @import("vk_helpers.zig");  // internal file — correct
```

The rule: use named imports for other bridges, file-path imports for your own files.

---

## Module Pairing

One `.zig` sidecar per module. A module can span multiple `.orh` files (all declaring
the same module name). The sidecar file name matches the module name.

```
src/
  math.orh          // module math — bridge declarations
  math_utils.orh    // module math — more Orhon code, same module
  math.zig          // sidecar — all Zig implementations for module math
```
