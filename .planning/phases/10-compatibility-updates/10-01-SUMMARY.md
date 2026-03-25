---
phase: 10-compatibility-updates
plan: 01
subsystem: compatibility
tags: [tamga, ptr-syntax, error-union, codegen, docs]
dependency_graph:
  requires: [phase-08, phase-09]
  provides: [COMP-01, COMP-02, COMP-03]
  affects: [tamga, codegen, docs]
tech_stack:
  added: []
  patterns:
    - "(if (x) |_| unreachable else |_e| @errorName(_e)) for .Error fallback in codegen"
    - "anyerror!T bridge return types replacing custom result unions"
key_files:
  created: []
  modified:
    - /home/yunus/Projects/orhon/tamga/src/example/data_types.orh
    - /home/yunus/Projects/orhon/tamga/src/TamgaSDL3/tamga_sdl3.zig
    - /home/yunus/Projects/orhon/tamga/src/TamgaVK3D/tamga_vk3d.zig
    - src/codegen.zig
    - docs/09-memory.md
    - docs/TODO.md
decisions:
  - "Updated Tamga bridge sidecars to return anyerror!T instead of custom WindowResult/RendererResult unions (required by Phase 9 error union codegen)"
  - "Fixed codegen .Error fallback: emit (if (x) |_| unreachable else |_e| @errorName(_e)) not x catch |_e| @errorName(_e)"
metrics:
  duration_min: 7
  completed_date: "2026-03-25"
  tasks_completed: 3
  files_modified: 6
---

# Phase 10 Plan 01: Compatibility Updates Summary

**One-liner:** Tamga updated to new Ptr syntax and Zig error unions; codegen .Error fallback fixed to emit correct Zig type; all docs and fixtures verified current.

## What Was Done

### Task 1: Update Tamga Ptr syntax and rebuild

Updated Tamga companion project to use the new Phase 9 Ptr syntax:
- `data_types.orh:85` — `Ptr(i32, &x)` → `&x`
- Cleared `.orh-cache/` and rebuilt with clean cache

Discovered pre-existing incompatibility: Tamga's bridge sidecars returned custom `WindowResult`/`RendererResult` union types, but Phase 9 codegen now generates native Zig error union patterns (`anyerror!T`). Fixed both bridge files.

Also discovered and fixed a codegen bug: the `.Error` fallback expression `result catch |_e| @errorName(_e)` has type `T` in Zig (not `[]const u8`), causing a type mismatch compile error. Fixed to emit `(if (result) |_| unreachable else |_e| @errorName(_e))` which correctly returns `[]const u8`.

**Result:** Tamga builds cleanly. All 240 compiler tests pass.

### Task 2: Verify fixtures and docs are current

Verified:
- `src/templates/`: 0 `.cast(` matches, all Ptr examples use new syntax
- `test/fixtures/`: only `fail_ptr_cast.orh` has `.cast(` (negative test, expected)
- `docs/09-memory.md`: has `const p: Ptr(i32) = &x` new syntax + "auto-borrow" documentation
- `docs/05-functions.md`: no stale `.cast()` or old Ptr constructor references

Added missing const auto-borrow documentation to `docs/09-memory.md`:
- `const` non-primitives entry in Copy vs Move section
- Code example showing `processA(config)` auto-borrows
- "Why const Auto-Borrows" section explaining the zero-cost mechanism

Updated `docs/TODO.md` to mark Ptr constructor migration as complete.

### Task 3: Checkpoint (Auto-approved)

⚡ Auto-approved: Tamga builds with new Ptr syntax and Zig error unions, compiler tests pass (240/240).

## Commits

| Task | Repo | Hash | Description |
|------|------|------|-------------|
| 1 | orhon_compiler | `74efbf8` | fix(10-01): fix .Error fallback codegen |
| 1 | tamga | `5bc1826` | feat(10-01): update Tamga to new Ptr syntax |
| 2 | orhon_compiler | `e5d2609` | docs(10-01): verify and update docs |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Tamga bridge sidecars used custom result unions instead of Zig error unions**
- **Found during:** Task 1 (Tamga clean rebuild)
- **Issue:** `tamga_sdl3.zig` and `tamga_vk3d.zig` returned `WindowResult`/`RendererResult` (custom tagged unions) but Phase 9 codegen generates native `anyerror!T` error union patterns
- **Fix:** Changed `Window.create()` and `Renderer.create()` bridge functions to return `anyerror!Window` and `anyerror!Renderer`
- **Files modified:** `/home/yunus/Projects/orhon/tamga/src/TamgaSDL3/tamga_sdl3.zig`, `/home/yunus/Projects/orhon/tamga/src/TamgaVK3D/tamga_vk3d.zig`
- **Commit:** tamga@5bc1826

**2. [Rule 1 - Bug] .Error fallback codegen generates wrong Zig type**
- **Found during:** Task 1 (Tamga rebuild after bridge fix)
- **Issue:** Fallback path for `result.Error` when no error capture variable is in scope emitted `result catch |_e| @errorName(_e)`. In Zig, `catch |e| expr` has type `T` (the success type), not the type of `expr`. When `T` is `Window` and `expr` is `@errorName(_e)` (`[]const u8`), Zig rejects with "expected type '[]const u8', found 'Window'".
- **Fix:** Changed fallback to `(if (result) |_| unreachable else |_e| @errorName(_e))` which returns `[]const u8` in both the success (unreachable) and error branches
- **Files modified:** `src/codegen.zig` (two locations: AST-path and MIR-path)
- **Commit:** compiler@74efbf8

## Known Stubs

None. All code paths are real and functional.

## Self-Check: PASSED

- FOUND: `/home/yunus/Projects/orhon/tamga/src/example/data_types.orh`
- FOUND: `src/codegen.zig`
- FOUND: `.planning/phases/10-compatibility-updates/10-01-SUMMARY.md`
- FOUND commit: `74efbf8` (compiler codegen fix)
- FOUND commit: `e5d2609` (docs update)
- FOUND commit: tamga@`5bc1826` (Tamga Ptr + bridge fix)
