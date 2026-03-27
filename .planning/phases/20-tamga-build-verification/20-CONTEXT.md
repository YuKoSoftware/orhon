# Phase 20: Tamga Build Verification - Context

**Gathered:** 2026-03-27
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix all 9 open compiler bugs discovered during Tamga framework development so that
Tamga builds end-to-end with `orhon build` — no workarounds needed. Remove all
workarounds from Tamga source files to prove the fixes work with clean code.

</domain>

<decisions>
## Implementation Decisions

### Bug Scope
- **D-01:** All 9 open Tamga bugs are in-scope. No deferrals.
  1. Multi-type null union collapses to optional (`?A` instead of tagged union)
  2. `cast(EnumType, int)` emits `@intCast` instead of `@enumFromInt`
  3. Empty struct construction `TypeName()` generates invalid Zig (should be `TypeName{}`)
  4. Multi-file module with Zig sidecar: "file exists in two modules"
  5. `size` is a reserved keyword in bridge func parameters
  6. `const &BridgeStruct` passes by value instead of by pointer
  7. Sidecar `export fn` should emit `pub export fn`
  8. Cross-module `@cImport` type identity (shared C import module)
  9. No mechanism to compile C/C++ source files in modules (`#csource` directive)

### Verification Strategy
- **D-02:** Verify by building Tamga from its repo with the newly-built compiler. Success = `orhon build` completes without errors in the Tamga project directory.
- **D-03:** The compiler's existing test suite (`./testall.sh`) must also pass — no regressions.

### Workaround Removal
- **D-04:** Remove ALL workarounds from Tamga source files after fixing each compiler bug:
  - Remove `NoEvent` sentinel struct, use `(null | QuitEvent | KeyDownEvent | ...)` directly
  - Remove dummy `pub empty: bool` field from zero-field structs
  - Rename `byte_size`/`byte_count` back to `size` where it was the natural name
  - Use `cast(Scancode, raw_int)` instead of raw integer comparisons
  - Use `const &Mesh` parameters instead of by-value pass
  - Remove manual `pub` additions from sidecar `export fn`
  - Remove manual `@ptrCast` at cross-module C type boundaries
  - Remove manual `build.zig` patching for C/C++ sources

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Tamga Bug Documentation
- `/home/yunus/Projects/orhon/tamga_framework/docs/bugs.md` — All 9 open bugs with root cause analysis, impact, workarounds, and fix descriptions

### Tamga Source Files (workaround removal targets)
- `/home/yunus/Projects/orhon/tamga_framework/src/TamgaSDL3/tamga_sdl3.orh` — NoEvent sentinel, enum workarounds, type aliases
- `/home/yunus/Projects/orhon/tamga_framework/src/TamgaSDL3/tamga_loop.orh` — Event loop using workaround types
- `/home/yunus/Projects/orhon/tamga_framework/src/TamgaVMA/tamga_vma.orh` — `byte_size` rename, C++ compilation workaround
- `/home/yunus/Projects/orhon/tamga_framework/src/TamgaVK3D/tamga_vk3d.orh` — `const &Mesh` by-value workaround, @ptrCast
- `/home/yunus/Projects/orhon/tamga_framework/src/test/test_sdl3.orh` — Raw integer comparisons instead of enum cast
- `/home/yunus/Projects/orhon/tamga_framework/src/test/test_vulkan.orh` — Cross-module type dispatch
- `/home/yunus/Projects/orhon/tamga_framework/src/main.orh` — Bridge func declarations

### Compiler Source (fix targets)
- `src/codegen.zig` — Bugs 1-3, 6-7 (codegen fixes)
- `src/zig_runner.zig` — Bug 4 (build graph), Bug 8 (shared @cImport), Bug 9 (#csource)
- `src/peg/builder.zig` or `src/orhon.peg` — Bug 5 (`size` keyword)
- `docs/TODO.md` — Full bug descriptions with fix guidance

</canonical_refs>

<code_context>
## Existing Code Insights

### Fix Targets in Compiler
- `codegen.zig` `typeToZig()` — handles union type emission, needs multi-null-union fix
- `codegen.zig` cast handling — needs enum detection for `@enumFromInt`
- `codegen.zig` call_expr — needs zero-field struct detection for `TypeName{}`
- `zig_runner.zig` `buildZigContent*()` — generates build.zig, needs sidecar dedup + C source support
- Keyword list in parser/PEG — check if `size` is intentionally reserved

### Tamga Project Layout
- 13 `.orh` files across 8 modules (TamgaSDL3, TamgaVK3D, TamgaVMA, etc.)
- Zig sidecars for bridge modules (tamga_sdl3.zig, tamga_vk3d.zig, tamga_vma.zig)
- C++ source: `vma_impl.cpp` in TamgaVMA
- System libraries: SDL3, vulkan

</code_context>

<specifics>
## Specific Ideas

No specific requirements — the bugs and their fixes are well-documented in Tamga's
bugs.md with root cause analysis and fix descriptions for each.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 20-tamga-build-verification*
*Context gathered: 2026-03-27*
