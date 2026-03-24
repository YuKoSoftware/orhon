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
safety guarantees are maintained at the boundary.

| Direction | `T` (value) | `const &T` | `&T` (mutable) |
|-----------|------------|------------|-----------------|
| Orhon → Zig | Move | Borrow (read) | **Not allowed** |
| Zig → Orhon | Owned | Borrow (read) | **Not allowed** |

**Exception:** `self: &BridgeStruct` on bridge struct methods is allowed — Zig
mutates its own data, not Orhon-owned data.

Violating this rule produces a compile error:
```
mutable reference '&data' not allowed across bridge — use 'const &data' or pass by value
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
    bridge func get(self: const &Counter) i32
    bridge func increment(self: &Counter) void
}
```
The sidecar must have a matching struct with `pub fn` methods.

### `bridge struct` with type parameters — generic bridge types
```
bridge struct Box(T: type) {
    bridge func create(val: T) Box
    bridge func get(self: const &Box) T
    bridge func set(self: &Box, val: T) void
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
    bridge func append(self: &RawList, item: T) void
    bridge func deinit(self: &RawList) void
}

// Orhon API — ergonomic wrapper
pub struct List(T: type) {
    raw: RawList(T)

    pub func create() List {
        return List(raw: RawList(T).init(defaultAlloc()))
    }

    pub func add(self: &List, item: T) void {
        self.raw.append(item)
    }

    pub func free(self: &List) void {
        self.raw.deinit()
    }
}
```

---

## Error Union Return Types

When an `bridge func` returns `(Error | T)`, the Zig sidecar must return a union with
`.ok: T` and `.err: struct { message: []const u8 }` tags.

```zig
const GetError = struct { message: []const u8 };
const GetResult = union(enum) { ok: []const u8, err: GetError };

pub fn get() GetResult {
    return .{ .ok = line };
    // or
    return .{ .err = .{ .message = "end of input" } };
}
```

---

## Calling C Through Zig

C interop goes through `.zig` bridge files. The `.orh` file exposes a clean Orhon API,
the `.zig` file handles all C details internally.

Use `#linkC` in the anchor file to declare C library dependencies. The compiler
generates the correct `linkSystemLibrary` + `linkLibC` calls in the build system.

```
// sdl.orh — clean Orhon interface
module sdl
#linkC "SDL3"

pub bridge func init() void
pub bridge func quit() void
```

```zig
// sdl.zig — Zig handles all C interop
const c = @cImport(@cInclude("SDL3/SDL.h"));

pub fn init() void {
    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
}

pub fn quit() void {
    c.SDL_Quit();
}
```

Multiple `#linkC` directives are allowed if a module wraps more than one C library.

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
