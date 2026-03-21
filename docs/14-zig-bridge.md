# Zig Bridge — `extern` Declarations and Paired `.zig` Files

Kodr handles all external interop through Zig. Kodr never talks to C, system APIs,
or external libraries directly — that complexity always lives in a paired `.zig` file.
Zig already has first-class C interop, handles ABI, calling conventions, and struct
layouts. No need to duplicate that work in Kodr.

---

## How It Works

A Kodr module can be paired with a hand-written `.zig` file that provides the actual
implementation. The `.kodr` file declares the interface using `extern` — always implicitly public.
The compiler emits nothing for `extern` bodies — it re-exports from the paired `.zig` directly.

```
// console.kodr — public Kodr interface
module console

extern func print(msg: String) void
extern func println(msg: String) void
extern func get() (Error | String)
```

```zig
// console.zig — hand-written Zig implementation
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

## `extern` Declaration Types

All `extern` declarations are implicitly public. `pub extern` is a compiler error (redundant).
A paired `.zig` sidecar file must exist alongside the `.kodr` file — hard error if missing.

### `extern func` — bridge a Zig function
```
extern func print(msg: String) void
extern func sqrt(x: any) any
```
No body allowed. The Zig sidecar must have a matching `pub fn`.

### `extern const` — expose a Zig constant
```
extern const PI: f64
extern const E: f64
```
The Zig sidecar must have a matching `pub const`.

### `extern struct` — import an opaque type from Zig
```
extern struct Socket
```
The Zig sidecar must have a matching `pub const Socket = struct { ... };` or type alias.
The struct's fields and methods are defined entirely in Zig.

---

## Error Union Return Types

When an `extern func` returns `(Error | T)`, the Zig sidecar must return a union with
`.ok: T` and `.err: struct { message: []const u8 }` tags. The codegen accesses these
by tag name, so the Zig type name does not need to match exactly.

```zig
// sidecar pattern for (Error | String) return
const GetError = struct { message: []const u8 };
const GetResult = union(enum) { ok: []const u8, err: GetError };

pub fn get() GetResult {
    // ...
    return .{ .ok = line };
    // or
    return .{ .err = .{ .message = "end of input" } };
}
```

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

extern func windowNew() Ptr(u8)
```

```
// usage — place gtk.kodr + gtk.zig in your project src/
import gtk

const window = gtk.windowNew()
```
