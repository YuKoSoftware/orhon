---
phase: 25-bridge-codegen-fixes
plan: 01
subsystem: codegen
tags: [bridge, codegen, mir, const-auto-borrow, sidecar, visibility]

# Dependency graph
requires:
  - phase: 24-cimport-unification
    provides: Bridge module system with #cimport directive
provides:
  - is_bridge flag on FuncSig for const auto-borrow exclusion
  - pub visibility fixup for sidecar export fn declarations
  - Bridge function calls no longer incorrectly receive const auto-borrow promotion
affects: [26-cross-module-is, 27-parser-fixes, 28-build-fixes]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "is_bridge bool on FuncSig guards against incorrect const auto-borrow on bridge calls"
    - "Sidecar copy uses read-modify-write to ensure pub visibility on export fn"

key-files:
  created: []
  modified:
    - src/declarations.zig
    - src/mir.zig
    - src/main.zig

key-decisions:
  - "Add is_bridge to FuncSig (not to DeclTable as a separate set) — field co-locates flag with sig, simpler lookup"
  - "Bridge struct methods in struct_methods always set is_bridge = true — they are always bridge declarations"
  - "Sidecar pub fixup via indexOfPos scan — simple, no regex, handles already-prefixed cases without double-prefix"

patterns-established:
  - "FuncSig.is_bridge: use this flag in any pass that needs to distinguish bridge vs Orhon-defined functions"

requirements-completed: [CGN-01, CGN-02, CGN-03]

# Metrics
duration: 3min
completed: 2026-03-28
---

# Phase 25 Plan 01: Bridge Codegen Fixes Summary

**Added is_bridge to FuncSig to prevent incorrect const auto-borrow on bridge calls, and fixed sidecar pub visibility so @import resolves all bridge symbols**

## Performance

- **Duration:** 3 min
- **Started:** 2026-03-28T09:13:03Z
- **Completed:** 2026-03-28T09:15:42Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Added `is_bridge: bool` to `FuncSig` in declarations.zig — set from AST node in `collectFunc`, and set to `true` for bridge struct methods in `collectStruct`
- `annotateCallCoercions` in mir.zig now skips const auto-borrow for bridge function calls (`!sig.is_bridge` guard) — prevents bridge struct value params from being incorrectly promoted to `*const`
- `detectCoercion` still correctly handles `const & BridgeStruct` params (the `value_to_const_ref` path is type-driven, not affected by this guard)
- Sidecar `.zig` copy in main.zig replaced with read-modify-write that prepends `pub ` to any `export fn` not already prefixed — ensures `@import("mod_bridge")` can resolve all symbols

## Task Commits

1. **Task 1: Fix const auto-borrow for bridge functions (CGN-01 + CGN-02)** - `02815b6` (fix)
2. **Task 2: Fix sidecar pub visibility (CGN-03)** - `969d077` (fix)

## Files Created/Modified
- `src/declarations.zig` - Added `is_bridge: bool` field to `FuncSig`; set it in `collectFunc` and bridge struct method collection
- `src/mir.zig` - Added `!sig.is_bridge` guard in `annotateCallCoercions` before const auto-borrow block
- `src/main.zig` - Replaced `copyFile` with read-modify-write sidecar copy that fixes `export fn` → `pub export fn`

## Decisions Made
- Added `is_bridge` as a field on `FuncSig` rather than a separate set in `DeclTable` — the flag belongs with the sig since it's used at the point of sig resolution in MIR
- Bridge struct methods in `struct_methods` always receive `is_bridge = true` — they are always methods of a `bridge struct`, so hardcoding is correct and avoids threading the `f.is_bridge` flag through a non-`FuncDecl` context
- The sidecar pub fixup uses a simple `indexOfPos` scan loop rather than regex — lightweight, correct, handles the `already_pub` check via index comparison

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- CGN-01, CGN-02, CGN-03 fixed — bridge codegen correctness improved
- Remaining v0.16 work: Phase 26 (cross-module is operator), Phase 27 (parser fixes), Phase 28 (build fixes)
- All 260 tests pass

---
*Phase: 25-bridge-codegen-fixes*
*Completed: 2026-03-28*
