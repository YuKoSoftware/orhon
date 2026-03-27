---
phase: 20-tamga-build-verification
plan: 02
subsystem: compiler
tags: [zig_runner, build-system, c-interop, codegen, metadata]

requires:
  - phase: 20-tamga-build-verification plan 01
    provides: "Multi-module build fixes (bugs 1-3, 5, 6), working bridge infrastructure"

provides:
  - "Bug 8 fixed: shared @cImport wrapper module generated per unique #cInclude header — eliminates cross-module C type identity issues"
  - "Bug 9 fixed: #csource directive adds C/C++ source compilation to generated build.zig via addCSourceFiles + linkLibCpp"
  - "#cInclude, #csource, #linkCpp metadata grammar rules added to orhon.peg"
  - "MultiTarget struct extended with c_includes, c_source_files, needs_cpp fields"
  - "generateSharedCImportFiles: auto-writes _{stem}_c.zig wrappers to cache before zig build"
  - "emitCSourceFiles helper: emits addCSourceFiles with -std=c++17 for .cpp files"
  - "Metadata collection in main.zig multi-target path for all three new directives"
  - "Unit tests for both bugs: 16/16 zig_runner tests pass, 253/253 testall.sh pass"

affects: [20-03, tamga-build-verification]

tech-stack:
  added: []
  patterns:
    - "#cInclude 'header.h' alongside #linkC generates a shared cimport_{stem} Zig module wired into all bridge modules using that header"
    - "#csource 'file.cpp' + optional #linkCpp causes addCSourceFiles + linkLibCpp in generated build.zig"
    - "Shared cImport file _{stem}_c.zig is written to .orh-cache/generated/ before zig build runs"
    - "Stem derivation: basename → strip extension → sanitize non-alphanumeric to '_'"

key-files:
  created: []
  modified:
    - src/orhon.peg
    - src/zig_runner.zig
    - src/main.zig

key-decisions:
  - "Use #cInclude 'header.h' metadata (separate from #linkC) to specify which header to wrap in the shared @cImport module — clean separation of library linking vs. type import"
  - "Derive shared module name from header filename stem (e.g., 'vulkan/vulkan.h' -> 'vulkan_c') — predictable, no extra metadata needed"
  - "Write _{stem}_c.zig wrapper files to cache directory before zig build runs — keeps file I/O in buildAll where other generated files live"
  - "Flag-style #linkCpp (no argument) signals C++ linking without requiring a source file — allows explicit opt-in when needed"
  - "Task 1 and Task 2 committed together (same files, changes interleaved) — one commit covers both bugs"

patterns-established:
  - "Pattern: new metadata directives follow linkC pattern — grammar literal + optional expr, builder handles via generic tokenText/fallback, main.zig collects by field name string comparison"

requirements-completed: [REQ-20]

duration: 45min
completed: 2026-03-27
---

# Phase 20 Plan 02: Bug 8 and 9 Summary

**Shared @cImport wrapper module generation (#cInclude) and C/C++ source compilation (#csource) added to the Orhon build system for Tamga's Vulkan/VMA modules**

## Performance

- **Duration:** 45 min
- **Started:** 2026-03-27T08:00:00Z
- **Completed:** 2026-03-27T08:45:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Bug 8 resolved: modules sharing `#linkC "vulkan"` can now declare `#cInclude "vulkan/vulkan.h"`, causing the compiler to generate a shared `cimport_vulkan` Zig module and wire it into all bridge modules. Sidecars can `@import("vulkan_c")` for type identity across module boundaries — no more `@ptrCast` at every VkBuffer boundary.
- Bug 9 resolved: modules can declare `#csource "vma_impl.cpp"` (and optionally `#linkCpp`) to have C/C++ source files compiled as part of the build. The generated `build.zig` emits `addCSourceFiles` with `-std=c++17` for `.cpp`/`.cc` files and `linkLibCpp()` for C++ linking.
- Grammar, metadata collection, build.zig emission, and file generation fully wired end-to-end. 253/253 testall.sh tests pass.

## Task Commits

1. **Task 1: Bug 8 (shared @cImport module generation)** - `dd247ba` (feat) — includes Task 2 changes (interleaved files)
2. **Task 2: Bug 9 (#csource directive)** - `dd247ba` (feat) — same commit as Task 1

## Files Created/Modified

- `src/orhon.peg` - Added `#cInclude`, `#csource`, `#linkCpp` metadata grammar rules as alternatives in `metadata_body`
- `src/zig_runner.zig` - `MultiTarget` struct extended with `c_includes`, `c_source_files`, `needs_cpp`; `generateSharedCImportFiles` function writes `_{stem}_c.zig` wrappers; `emitCSourceFiles` helper emits `addCSourceFiles` + `linkLibCpp`; shared cImport module creation and wiring in `buildZigContentMulti`; two new unit tests
- `src/main.zig` - Multi-target metadata collection extended to gather `#cInclude`, `#csource`, `#linkCpp` from module AST and pass to `MultiTarget` via new fields

## Decisions Made

- Used `#cInclude "header.h"` as a separate directive from `#linkC "libname"` — clean separation of library system linking (which the build system handles) vs. C header import (which affects Zig type identity)
- Shared module naming: header basename stem + `_c` suffix (e.g., `vulkan/vulkan.h` → `vulkan_c`, `SDL3/SDL.h` → `SDL3_c`) — predictable, no extra configuration
- Wrapper files written to `.orh-cache/generated/` as `_{stem}_c.zig` before `zig build` runs — consistent with how other generated files work in `buildAll`
- `#linkCpp` is a flag (no argument) for explicit C++ linking; `.cpp`/`.cc` extensions in `#csource` also auto-enable it

## Deviations from Plan

None - plan executed exactly as written. The plan suggested either a convention or `#cInclude` for the header mapping; `#cInclude` was chosen as the cleaner explicit approach.

## Issues Encountered

None.

## Next Phase Readiness

- Bug 8 and Bug 9 are compiler-side complete. Tamga sidecars (tamga_vma.zig, tamga_vk3d.zig) still use inline `@cImport` and `@ptrCast` workarounds — Plan 03 removes those workarounds by updating the Tamga sidecars to use `@import("vulkan_c")` and adding `#csource`/`#cInclude` to `tamga_vma.orh`.
- Bug 7 (export fn pub visibility) is also Plan 03 scope.
- All 253 tests pass — no regressions.

---
*Phase: 20-tamga-build-verification*
*Completed: 2026-03-27*
