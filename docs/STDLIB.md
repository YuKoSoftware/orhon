# Kodr — Standard Library

---

## 1. Standard Library

### Guiding rule
Foundation and building blocks only. Reduces code rewrites without making decisions for the programmer. No opinionated high-level frameworks.

### Phase 1 — Essential
```
std.mem           // allocators, copy, swap, raw memory
std.math          // abs, min, max, clamp, lerp, trig, rounding, constants (pi, tau, e)
std.math.linear   // Vec2(T), Vec3(T), Vec4(T), Mat2(T), Mat3(T), Mat4(T), Quat(T)
std.string        // manipulation, search, split, trim, parse
std.bytes         // raw byte manipulation, endianness, bit operations
std.collections   // list, map, set, queue, stack
std.os            // environment variables, signals, process info
std.io            // raw streams, buffers, readers, writers
std.console       // terminal — print, input, colors, cursor, clear
std.fs            // file read/write, copy, move, watch
std.path          // path join, split, normalize, extension, stem
std.time          // clock, duration, formatting, timers
std.hash          // fast general purpose hashing — FNV, xxHash, SipHash
std.random        // random number generation
std.sort          // sorting algorithms
std.atomic        // atomic operations, compare-and-swap, memory ordering
```

### Phase 2 — Core
```
std.net           // raw sockets only — TCP, UDP
std.encoding      // base64, hex, UTF-8, UTF-16 encoding and decoding
std.unicode       // full unicode support, normalization
std.fmt           // string formatting: std.fmt.format("hello {}", name)
std.test          // test utilities, assert helpers
std.process       // spawn processes, pipes, child processes
std.signal        // OS signals — SIGINT, SIGTERM etc
std.sync          // synchronization primitives — mutexes, semaphores, channels
std.reflect       // type introspection
```

### Phase 3 — Complete
```
std.crypto        // primitives only — hashing, symmetric, asymmetric encryption
std.compress      // algorithms only — lz4, zstd, deflate
std.json          // parse and emit JSON
std.regex         // pattern matching
std.xml           // parse and emit XML
std.csv           // parse and emit CSV
```

### Phase 4 — Extended
```
std.yaml          // parse and emit YAML
std.audio         // audio device access, playback primitives
std.window        // window creation, input events, platform abstraction only
std.gpu           // GPU access — see below
```

### `std.gpu` — Graphics & Compute
```
std.gpu              // device detection, capability queries, shared types
gpu.unified      // unified abstraction layer — write once, runs on any backend
gpu.vulkan       // Vulkan API bindings
gpu.opengl       // OpenGL bindings
gpu.gles         // OpenGL ES bindings
gpu.webgpu       // WebGPU bindings, works native and wasm
gpu.compute      // GPU compute, backend agnostic
```

Backend selection resolved entirely at compile time via `compt` — zero runtime overhead. The unified layer compiles away completely, leaving only direct backend calls in the binary. Platform-specific APIs (Metal, DirectX) deliberately excluded.

### Game & graphics math
```
var pos: linear.Vec2(f32) = linear.Vec2(f32)(x: 1.0, y: 2.0)
var vel: linear.Vec2(i32) = linear.Vec2(i32)(x: 1, y: 0)
```

### Deliberately excluded
- `std.http` — too opinionated, third party
- `std.db` — too opinionated, third party
- `std.log` — too opinionated, third party
- GUI frameworks — too opinionated, third party
- Higher level thread pools — use `thread` keyword directly
