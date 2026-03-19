# Kodr — Next Steps

Prioritized list of best next moves as of 2026-03-19.

---

## 1. Fix README spec inconsistency (quick)
README Section 19 still references `ptr.valid` which was removed in commit `3048e14`.
Update the spec to match the current pointer model.

## 2. Heap allocation — `alloc` / `free`
Specified in README Section 28 but not in parser/codegen at all.
Critical language feature. Needs:
- Parser: `alloc T` and `free x` expressions
- Codegen: map to allocator calls in Zig
- Resolver: track allocator availability in scope

## 3. Slice operations — `arr[a..b]`
Only index access `arr[i]` works. Slice syntax is unimplemented.
~100 lines in parser + codegen.

## 4. Bitfield enum methods
`enum Flags(u8, bitfield)` parses, but `.has()`, `.set()`, `.clear()`, `.toggle()`
methods don't generate. Simple codegen addition, ~50 lines.

## 5. Pass 8: Thread safety
Currently a 100-line stub. `Thread(T)` and `Async(T)` types exist but no real
sendability checking or `splitAt` validation.

## 6. Overflow helpers — `overflow()`, `wrap()`, `sat()`
Specified in README, not in parser or codegen at all.
~20 lines parser + ~50 lines codegen mapping to Zig builtins.

## 7. Tighten `compt` generics
The `any` type works in simple cases but complex nested generics have untested
edge cases. `compt for` generates `inline for` but compile-time semantics may
not fully match.

## 8. Extern func sidecar validation
Missing `.zig` sidecars produce cryptic Zig errors instead of clear Kodr errors.
Add a focused error check pass.
