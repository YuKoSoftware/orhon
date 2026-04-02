# Unify build.zig Generation — Design Spec

## Goal

Eliminate `buildZigContent()` by routing all build.zig generation through `buildZigContentMulti()`. Single-target projects become a single-element `MultiTarget` array.

## Current State

- `zig_runner_build.zig` has `buildZigContent()` (~430 lines) for single-target builds
- `zig_runner_multi.zig` has `buildZigContentMulti()` (~620 lines) for multi-target builds
- ~400 lines of overlap: preamble, bridge module creation, @cImport modules, shared module wiring, artifact creation, test step
- `zig_runner.zig` hub has two entry points: `generateBuildZig()` → `generateBuildZigWithTests()` for single, `buildAll()` for multi
- `pipeline.zig` dispatches to one or the other based on target count

## Design

### 1. Delete `buildZigContent()` and its tests

Remove the function and its 7 unit tests from `zig_runner_build.zig`. Keep the shared helpers that `buildZigContentMulti` already imports:
- `sanitizeHeaderStem()` / `StemResult`
- `generateSharedCImportFiles()`
- `emitLinkLibs()`
- `emitIncludePath()`
- `emitCSourceFiles()`

### 2. Collapse `generateBuildZig` / `generateBuildZigWithTests` into one method

`generateBuildZig()` is a trivial pass-through to `generateBuildZigWithTests()`. Fold them into a single method that:
1. Constructs a `MultiTarget` from its parameters
2. Calls `buildZigContentMulti()` with a single-element slice
3. Calls `generateSharedCImportFiles()` if needed
4. Writes build.zig to cache

The `bridge_modules` parameter maps to `extra_bridge_modules` (non-root modules with bridges). The target itself gets `has_bridges = bridge_modules.len > 0` (conservative — harmless if some bridges are from non-root modules since the bridge variable just won't be used).

Actually, more precisely: `bridge_modules` contains ALL modules with bridges (root and non-root). The `MultiTarget.has_bridges` flag should be true if the root module has bridges. But `buildZigContentMulti` uses `has_bridges` per-target and `extra_bridge_modules` for non-root. For a single target, we can set `has_bridges = true` when `bridge_modules` is non-empty and pass all bridge module names as `extra_bridge_modules` — the multi path handles deduplication via `bridge_set`.

Wait — the multi path creates bridge modules from both `targets[].has_bridges` targets AND `extra_bridge_modules`. If we set `has_bridges = true` on the single target AND also pass bridge names as `extra_bridge_modules`, we'd get duplicate `bridge_{name}` declarations.

Correct approach: pass `bridge_modules` as `extra_bridge_modules`, set `has_bridges = false` on the target. The multi path creates bridge modules for all `extra_bridge_modules` names, which covers everything. This works because `extra_bridge_modules` was designed for exactly this — non-target modules that have bridges. From the multi path's perspective, a single-target build has no per-target bridges, just "extra" bridge modules.

Alternative: set `has_bridges = true` only if the root module itself is in `bridge_modules`, and put the rest in `extra_bridge_modules`. But this requires knowing which bridge modules belong to the root — info the caller doesn't currently separate. The simpler approach (all as extra) is correct and simpler.

### 3. Update `pipeline.zig` single-target path

Line 973 calls `runner.generateBuildZig()` with 12 args. Update to call the new collapsed method with the same args. No structural change to pipeline.zig — just the method name and signature.

### 4. Remove `buildZigContent` re-export

Delete `pub const buildZigContent = ...` from `zig_runner.zig`. No external callers use it (only the hub's own `generateBuildZigWithTests`).

### 5. Migrate unit tests

The 7 `buildZigContent` tests in `zig_runner_build.zig` become `buildZigContentMulti` tests in `zig_runner_multi.zig`. Each constructs a single-element `MultiTarget` array. Assertions stay the same (they check for `addExecutable`, `installArtifact`, etc. — not variable names).

### 6. Variable naming change

Single-target builds will generate `exe_{name}`/`lib_{name}` instead of bare `exe`/`lib`. This is functionally identical — Zig doesn't care about variable names. Integration tests (test/05-08) validate behavior, not variable names.

## Files Changed

| File | Action |
|------|--------|
| `src/zig_runner/zig_runner_build.zig` | Delete `buildZigContent()` + 7 tests (~430 lines removed) |
| `src/zig_runner/zig_runner.zig` | Collapse `generateBuildZig`/`generateBuildZigWithTests` into one method using `buildZigContentMulti`; remove `buildZigContent` re-export |
| `src/zig_runner/zig_runner_multi.zig` | Add 7 migrated single-target tests |
| `src/pipeline.zig` | Update single-target call site (line 973) |
| `docs/TODO.md` | Mark simplification as done |

## Risks

- **Generated build.zig variable names change** for single-target projects (`exe` → `exe_{name}`). Mitigated: integration tests validate behavior, not names.
- **Bridge module wiring semantics** — need to verify that passing all bridges as `extra_bridge_modules` with `has_bridges = false` produces correct output. Mitigated: existing multi tests + integration tests.
- **`shared_modules` mapping** — single-target's `shared_modules` maps to `mod_imports` on the `MultiTarget`. Need to verify the multi path handles this identically. Mitigated: test coverage.
