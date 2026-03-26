---
status: awaiting_human_verify
trigger: "Fix 5 compiler bugs from Tamga companion project"
created: 2026-03-26T00:00:00Z
updated: 2026-03-26T13:00:00Z
---

## Current Focus

hypothesis: Bug 4 root cause confirmed and fixed — lib-to-lib addImport was missing from build.zig generation, causing "file exists in modules 'root' and 'tamga_sdl3'" when tamga_vk3d.zig's @import("tamga_sdl3") fell back to file-path resolution
test: ./testall.sh — 251 tests pass; new unit test buildZigContentMulti lib-to-lib test added and passes
expecting: User confirms the build no longer fails with "file exists in modules" error for tamga_sdl3
next_action: Human verification of fix

## Symptoms

expected: `orhon build` compiles successfully when a module has multiple .orh files and a Zig sidecar
actual: `orhon build` fails with `internal codegen error: tamga_sdl3.zig:1:1: error: file exists in modules 'root' and 'tamga_sdl3'`
errors: "file exists in modules 'root' and 'tamga_sdl3'" — Zig build system error indicating a .zig file is registered in two different modules
reproduction: Build a project where lib A (tamga_vk3d) imports lib B (tamga_sdl3); both are static lib targets
started: Phase 2 plan 02-01

## Eliminated

- hypothesis: Bug 4 caused by sidecar .zig file being picked up by directory scanner
  evidence: scanDirRecursive only processes .orh files, not .zig files
  timestamp: 2026-03-26

- hypothesis: Bug 4 caused by tamga_sdl3 not being in module_builds map
  evidence: tamga_sdl3 has #build = static, is correctly mapped as .static
  timestamp: 2026-03-26

- hypothesis: Bug 4 caused by duplicate addImport/linkLibrary in exe section of build.zig
  evidence: Previous fix deduplicated lib_imports in main.zig but this didn't address the real issue. The actual error was that tamga_vk3d.zig (a lib) did @import("tamga_sdl3") with no addImport registered for that dependency in lib_tamga_vk3d, causing Zig to fall back to file-path resolution.
  timestamp: 2026-03-26

## Evidence

- timestamp: 2026-03-26
  checked: tamga_framework/.orh-cache/generated/build.zig (before fix)
  found: lib_tamga_vk3d only got addImport for _orhon_str and _orhon_collections, not for tamga_sdl3 or tamga_vma despite tamga_vk3d.zig doing @import("tamga_sdl3") and @import("tamga_vma")
  implication: Zig fell back to file-path resolution for @import("tamga_sdl3"), treating tamga_sdl3.zig as a file in vk3d's module. Since tamga_sdl3.zig was already the root of lib_tamga_sdl3, conflict = "file exists in modules 'root' and 'tamga_sdl3'"

- timestamp: 2026-03-26
  checked: zig_runner.zig buildZigContentMulti Pass 1 (lib emit)
  found: Pass 1 emitted lib targets with only _orhon_str and _orhon_collections imports. No addImport for lib-to-lib dependencies. No topological sort.
  implication: Fix required: (1) topologically sort lib targets by dependency order, (2) emit addImport for each lib_import that is also a lib target

- timestamp: 2026-03-26
  checked: After fix applied — tamga_framework/.orh-cache/generated/build.zig
  found: lib_tamga_vk3d now has addImport("tamga_sdl3", lib_tamga_sdl3.root_module) and addImport("tamga_vma", lib_tamga_vma.root_module). Lib targets emitted in correct dependency order: vma/sdl3 before vk3d.
  implication: Original "file exists in modules" error for tamga_sdl3 is resolved.

- timestamp: 2026-03-26
  checked: Tamga build output after fix
  found: New error "file exists in modules 'tamga_vma' and 'root'" for tamga_vk3d_bridge.zig — caused by tamga_vk3d_bridge.zig importing tamga_vma_bridge.zig via file path (@import("tamga_vma_bridge.zig")). This is a cross-bridge file-path import that violates Zig's "one file per module" rule.
  implication: This is a SEPARATE issue from Bug 4. Bug 4 ("file exists in modules 'root' and 'tamga_sdl3'") is fully fixed. The new error is a Tamga project design issue where hand-written bridges cross-import each other via file paths. This requires changes to Tamga's bridge files (out of scope for this session).

## Resolution

root_cause: |
  buildZigContentMulti in zig_runner.zig only emitted addImport for _orhon_str and _orhon_collections in lib target sections. When lib A (tamga_vk3d) imports lib B (tamga_sdl3), no addImport("tamga_sdl3", lib_tamga_sdl3.root_module) was emitted for lib_tamga_vk3d. Zig resolved @import("tamga_sdl3") as a file path, adding tamga_sdl3.zig to the vk3d module's file set — but tamga_sdl3.zig was already the root of lib_tamga_sdl3. Conflict: "file exists in modules 'root' and 'tamga_sdl3'".
  Additionally, lib targets were emitted in arbitrary order. If lib A depended on lib B but B was emitted after A, the Zig build variable lib_B would be undefined when lib_A's addImport line referenced it.

fix: |
  In buildZigContentMulti (zig_runner.zig):
  1. Topologically sort lib targets before Pass 1 — libs whose dependencies have been emitted are ready first. If a circular dependency is detected (no progress in a full pass), remaining libs are emitted in arbitrary order.
  2. After emitting each lib's _orhon_str and _orhon_collections addImports, emit addImport for each lib_import that is also a lib target.
  Added regression test: "buildZigContentMulti - lib-to-lib imports added to prevent file-module conflicts" verifying both lib-to-lib addImport presence and topological order.

verification: |
  ./testall.sh — 251 tests pass (same count as before; test count is stable).
  New unit test passes: "buildZigContentMulti - lib-to-lib imports added to prevent file-module conflicts".
  tamga_framework build: "file exists in modules 'root' and 'tamga_sdl3'" error is gone.

files_changed: [src/zig_runner.zig]
