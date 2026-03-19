# Zig Bridge — `extern func` and Paired `.zig` Files

Kodr handles all external interop through Zig. Kodr never talks to C, system APIs,
or external libraries directly — that complexity always lives in a paired `.zig` file.
Zig already has first-class C interop, handles ABI, calling conventions, and struct
layouts. No need to duplicate that work in Kodr.

---

## How It Works

A Kodr module can be paired with a hand-written `.zig` file that provides the actual
implementation. The `.kodr` file declares the public interface using `extern func`.
The compiler emits nothing for `extern func` bodies — it uses the paired `.zig` directly.

```
// zigstd.kodr — public Kodr interface
module zigstd

pub extern func print(msg: string) void
pub extern func println(msg: string) void
```

```zig
// zigstd.zig — hand-written Zig implementation
const std = @import("std");

pub fn print(msg: []const u8) void {
    std.debug.print("{s}", .{msg});
}

pub fn println(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
}
```

```
// usage in any Kodr file
import std::zigstd

func main() void {
    zigstd.print("hello kodr !\n")
}
```

---

## `extern func` Rules

- `extern func` has a signature but no body — hard compiler error if body is present
- Must be `pub` — extern functions are always part of a module's public interface
- The paired `.zig` file must exist alongside the `.kodr` file — hard compiler error if missing
- The `.zig` function signature must match the Kodr declaration — mismatch is a Zig compile error

---

## Calling C Through Zig

C interop goes through `.zig` bridge files. The `.kodr` file exposes a clean Kodr API,
the `.zig` file handles all C details internally:

```zig
// gtk.zig — Zig handles all C interop
const c = @cImport(@cInclude("gtk4.h"));

pub fn windowNew() *c.GtkWidget {
    return c.gtk_window_new();
}
```

```
// gtk.kodr — clean Kodr interface, no C visible
module gtk

pub extern func windowNew() Ptr(u8)
```

```
// usage
import global::gtk

var window = gtk.windowNew()
```

---

## Naming Convention

Zig bridge files use the `zig` prefix to signal they are bridges, not native Kodr:
- `zigstd.kodr` / `zigstd.zig` — Zig stdlib bridge
- `zigmath.kodr` / `zigmath.zig` — Zig math bridge
- `zigallocator.kodr` / `zigallocator.zig` — Zig allocator bridge

Third-party C libraries use descriptive names without the prefix:
- `gtk.kodr` / `gtk.zig`
- `sdl.kodr` / `sdl.zig`
- `vulkan.kodr` / `vulkan.zig`
