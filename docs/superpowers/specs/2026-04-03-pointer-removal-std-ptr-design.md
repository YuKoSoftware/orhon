# Pointer Removal + std::ptr Design

## Summary

Remove `Ptr(T)`, `RawPtr(T)`, `VolatilePtr(T)` from the compiler as builtin types and
`@deref` as a compiler function. Provide the same functionality in `std::ptr` as pure
Zig-backed structs with no compiler awareness. The borrow system (`const&` / `mut&`)
already handles safe reference passing — pointers are the explicit opt-in escape hatch
that lives in the standard library.

**Motivation:** Pointers as builtin types violate the zero magic rule. They require
special-cased codegen, MIR type classification, type resolution, and coercion logic.
The borrow system covers ~95% of reference use cases. The remaining 5% (FFI, hardware,
pointer arithmetic) belongs in std — explicit, opt-in, and library-maintained.

---

## Compiler Removal

### Files and what gets removed

| File | Removal |
|---|---|
| `src/builtins.zig` | `Ptr`, `RawPtr`, `VolatilePtr` from `BUILTIN_TYPES`; `BT.PTR`, `BT.RAW_PTR`, `BT.VOLATILE_PTR` constants; `isPtrType()` helper; `@deref` from `COMPILER_FUNCS` |
| `src/types.zig` | `.safe_ptr`, `.raw_ptr`, `.volatile_ptr` from `CoreType.Kind`; associated `name()` and resolution logic |
| `src/codegen/codegen.zig` | `typeToZig()` special cases for Ptr/RawPtr/VolatilePtr; `getPtrCoercionTarget()`; `PtrCoercionInfo` struct |
| `src/codegen/codegen_match.zig` | `generatePtrCoercionMir()`; `@deref` handler; `coreTypeName()` pointer branches |
| `src/codegen/codegen_decls.zig` | Pointer coercion call site in `generateTopLevelDeclMir()` |
| `src/mir/mir_types.zig` | `TypeClass.safe_ptr`, `TypeClass.raw_ptr`; classification logic for pointer types |
| `src/resolver.zig` | `coreTypeName()` pointer branches; core type compatibility checks for pointer types |
| `src/lsp/lsp_analysis.zig` | `formatType()` CoreType pointer rendering |

### What stays

- `CoreType` remains with `.handle` only (Handle moves to std::async in a future task)
- Borrow system (`const&` / `mut&`) unchanged — this is the safe reference mechanism
- `ResolvedType.ptr` variant unchanged — borrows are not pointers

---

## std::ptr Module

### New files

- `src/std/ptr.zig` — Zig implementation
- `src/std/ptr.orh` — Orhon declarations

### Structs

#### `Ptr(T)` — Safe Single-Value Pointer

Wraps Zig `*T`. Points to a single value. Must be constructed from a variable borrow —
no raw integer addresses allowed. This is the safe pointer for when you need to hold
an address explicitly.

```
import std::ptr

var x: i32 = 10
var p: ptr.Ptr(i32) = ptr.Ptr(i32).new(mut& x)

const val: i32 = p.read()     // read value
p.write(42)                    // write value
const addr: usize = p.address() // get raw address
```

**Construction:** `.new(mut& x)` or `.new(const& x)` — from a borrow only.
No `.fromAddress()` — safe pointers come from real variables.

**Zig backing:**
```zig
pub fn Ptr(comptime T: type) type {
    return struct {
        raw: *T,
        const Self = @This();

        pub fn new(ref: *T) Self {
            return .{ .raw = ref };
        }

        pub fn read(self: Self) T {
            return self.raw.*;
        }

        pub fn write(self: Self, val: T) void {
            self.raw.* = val;
        }

        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}
```

#### `RawPtr(T)` — Unsafe Indexable Pointer

Wraps Zig `[*]T`. Supports offset indexing (`at`, `set`) and pointer arithmetic. For FFI,
C interop, and cases where you need array-style access through a pointer.

```
import std::ptr

var arr: [4]i32 = [1, 2, 3, 4]
var r: ptr.RawPtr(i32) = ptr.RawPtr(i32).new(mut& arr)
const val: i32 = r.at(0)      // read at offset
r.set(2, 99)                   // write at offset
const addr: usize = r.address() // get raw address

// From integer address (FFI/hardware)
var mem: ptr.RawPtr(u8) = ptr.RawPtr(u8).fromAddress(0xB8000)
```

**Construction:** `.new(mut& x)` / `.new(const& x)` from a borrow, or `.fromAddress(usize)`
from a raw integer address.

#### `VolatilePtr(T)` — Unsafe Hardware Pointer

Wraps Zig `*volatile T`. Every read and write is volatile — the compiler never caches or
optimizes them away. For memory-mapped hardware registers.

```
import std::ptr

var reg: ptr.VolatilePtr(u32) = ptr.VolatilePtr(u32).fromAddress(0xFF200000)
const val: u32 = reg.read()   // volatile read
reg.write(0x1)                 // volatile write
const addr: usize = reg.address() // get raw address
```

**Construction:** `.new(mut& x)` / `.new(const& x)` from a borrow, or `.fromAddress(usize)`
from a raw integer address.

### Const safety

The borrow type determines mutability. Passing `const& x` gives Zig `*const T` —
the struct can read but not write. Passing `mut& x` gives Zig `*T` — read and write
both work. Zig enforces this at compile time with no Orhon compiler involvement.

---

## Documentation Updates

| File | Change |
|---|---|
| `docs/09-memory.md` | Remove Pointers section (lines 100-162), add note pointing to `std::ptr` |
| `docs/02-types.md` | Remove Ptr/RawPtr/VolatilePtr references |
| `docs/TODO.md` | Mark pointer redesign as done |

---

## Example Module Update

`src/templates/example/data_types.orh` — replace current pointer examples with `std::ptr`
usage showing the import and new API for all three types.

---

## Test Updates

| File | Change |
|---|---|
| `test/fixtures/tester.orh` | Remove/replace Ptr/RawPtr test functions with std::ptr equivalents |
| `test/fixtures/fail_ptr_cast.orh` | Remove (tests builtin pointer cast that no longer exists) |
| New test cases | Add std::ptr construction, read, write, address for all three types |

---

## Design Decisions

1. **No new syntax** — no `*T`, no `->`, no `&x`. Borrows handle safe references; std::ptr
   handles the rest through method calls.
2. **No new compiler functions** — `@addressOf` not needed because `mut&`/`const&` already
   provide addresses to the Zig-backed structs.
3. **Ptr.new() requires a borrow** — safe pointers must come from real variables, not raw
   addresses. RawPtr and VolatilePtr allow `.fromAddress(usize)` for FFI/hardware.
4. **Single Ptr(T) for now** — no MutPtr/ConstPtr split. The borrow type (`const&` vs `mut&`)
   determines mutability, enforced by Zig's type system.
5. **Handle(T) stays** — CoreType retains `.handle` only. Handle moves to std::async in a
   separate future task.
