# Multi-file Zig Sidecars

**Date:** 2026-04-02
**Status:** Design
**Origin:** Tamga `docs/ideas.md` — discovered 2026-04-01

## Problem

A bridge module's Zig sidecar is a single `.zig` file. The compiler copies only that file to `.orh-cache/generated/`, so any `@import("helper.zig")` inside it fails — Zig can't resolve the path. Large bridge implementations (e.g., wrapping Vulkan) cannot be split into logical units.

## Solution

Allow sidecar `.zig` files to `@import` additional `.zig` files. The compiler discovers these imports by scanning the sidecar content, validates them, and copies them to the generated directory alongside the sidecar.

## Design

### Discovery

When the compiler copies a sidecar to `generated/`, it scans the file content for `@import("...zig")` patterns (string argument ending in `.zig`). For each match:

1. Resolve the path relative to the sidecar's source directory
2. Add the file to a copy list
3. Recursively scan the discovered file for further `@import`s
4. Track visited paths to avoid cycles

### Validation

Three rules enforced at discovery time:

1. **Source boundary:** Each resolved `.zig` path must be within the project's source directory. Error if a path escapes (e.g., `@import("../../outside.zig")`).
2. **Collision detection:** Each destination path in `generated/` must be unique across all modules. Error if two different source files would map to the same destination (e.g., module `foo` and module `bar` both importing a different `helpers.zig`).
3. **Existence:** Each referenced `.zig` file must exist on disk. Error if missing.

### Copying

Copy each discovered `.zig` file to the same relative position from `generated/`. Create subdirectories as needed.

Example:
```
Source:
  src/gfx/vulkan.zig          (sidecar)
  src/gfx/pipeline.zig        (@imported by vulkan.zig)
  src/gfx/utils/helpers.zig   (@imported by pipeline.zig)

Generated:
  .orh-cache/generated/vulkan_bridge.zig   (sidecar, renamed as usual)
  .orh-cache/generated/pipeline.zig
  .orh-cache/generated/utils/helpers.zig
```

### Import Direction Constraint

The sidecar itself is renamed from `{module}.zig` to `{module}_bridge.zig` to avoid colliding with the generated Orhon module file `{module}.zig`. This means extra files cannot `@import` back to the sidecar by its original name. This is fine — the sidecar is the entry point, extra files are its helpers. Imports flow outward from the sidecar, not back to it.

### No build.zig Changes

Relative `@import` paths resolve naturally since all files maintain their relative positions from the sidecar. No changes to module registration or `build.zig` generation are needed.

### Applies to Both Copy Sites

The import scanning and copying applies at both places the compiler handles sidecars:

1. **Import-time copy** in `module.zig` (~line 574) — for imported module sidecars
2. **Root module copy** in `pipeline.zig` (~line 367) — for the root module sidecar (includes `pub` fixup on `export fn`)

### Error Messages

- `bridge '{name}': sidecar import '{path}' escapes project source directory`
- `bridge '{name}': sidecar import '{path}' not found`
- `bridge '{name}': sidecar import '{path}' collides with import from module '{other}'`
