---
phase: quick
plan: 260329-wpb
subsystem: zig_runner
tags: [bridge-modules, multi-target, scoping, build-gen]
dependency_graph:
  requires: []
  provides: [per-target-bridge-scoping]
  affects: [src/zig_runner/zig_runner_multi.zig]
tech_stack:
  added: []
  patterns: [per-target-mod_imports-check]
key_files:
  created: []
  modified:
    - src/zig_runner/zig_runner_multi.zig
decisions:
  - "Task 2 (single-target pipeline scoping) not implemented — plan's direct-import approach breaks transitive bridge resolution; original all-module iterator is correct for single-root projects"
metrics:
  duration: ~20min
  completed: 2026-03-29T20:45:44Z
  tasks_completed: 1
  tasks_planned: 2
  files_changed: 1
---

# Phase quick Plan 260329-wpb: Fix Bridge Module Import Scoping in Zig Build Summary

**One-liner:** Scope extra_bridge_modules per-target in multi-target builds using mod_imports membership check; single-target path unchanged due to transitive dependency requirements.

## Tasks Completed

| Task | Name | Commit | Files |
| ---- | ---- | ------ | ----- |
| 1 | Scope extra_bridge_modules per target in multi-target builds | 8066058 | src/zig_runner/zig_runner_multi.zig |

## Tasks Not Completed

| Task | Reason |
| ---- | ------ |
| 2 | Plan's suggested code breaks transitive bridge resolution — see Deviations |

## What Was Built

**Task 1:** In `buildZigContentMulti`, the three loops over `extra_bridge_modules` (lib targets at ~line 328, exe targets at ~line 467, test target at ~line 584) now gate each bridge module addition behind a membership check: the bridge module name must appear in `t.mod_imports` for the target being built. If the target does not import the module, `continue` skips the `addImport` emission. This eliminates spurious bridge imports on unrelated targets in multi-target builds.

## Deviations from Plan

### Auto-fixed Issues

None — Task 1 executed as specified.

### Plan Errors Found

**1. [Rule 1 - Bug] Task 2: plan's direct-import approach breaks transitive bridge resolution**

- **Found during:** Task 2 implementation and test validation
- **Issue:** The plan instructs replacing the all-modules iterator in `pipeline.zig` with `for (mod.imports)` (direct imports only). When tested, this caused `tester module compiles` to fail with: `internal codegen error: tester.zig:4:27: error: no module named 'allocator' available within module 'tester'`. Root cause: `tester.orh` imports `std::allocator` and `use std::collections`, but `main.orh` (the root) only directly imports `tester`. The direct-import approach missed `allocator` and `collections` bridges that `tester` needs transitively.
- **Analysis:** The `bridge_mods` list in `zig_runner_build.zig` is not just used for the root artifact — it creates `bridge_{}` Zig modules AND wires them into each `mod_{}` shared module (line 171: "All bridge modules are wired to all shared modules"). This requires transitive coverage. The plan's comment that it "matches the pattern used by `shared_mods`" is incorrect: `shared_mods` wires direct imports to the exe/lib artifact, but `bridge_mods` provides bridge access for shared modules' own dependencies.
- **Correct approach:** Would require walking the module graph transitively (`mod.imports` → each module's imports → etc.) to collect all reachable bridge modules. However, in a single-root project, `mod_resolver.modules` already contains exactly the transitively reachable modules (scanner adds them during import resolution), making the original all-modules iterator effectively correct.
- **Decision:** Task 2 not implemented. The single-target path's original iterator is left unchanged — it is already minimal (single-root projects only have reachable modules in the resolver map) and correct.
- **Tests:** 269/269 pass with Task 1 only, confirming the revert is correct.

## Verification

- `zig build test`: passes (unit tests)
- `./testall.sh`: 269/269 pass

## Self-Check: PASSED

- src/zig_runner/zig_runner_multi.zig: FOUND
- Commit 8066058: FOUND
- All 269 tests pass
