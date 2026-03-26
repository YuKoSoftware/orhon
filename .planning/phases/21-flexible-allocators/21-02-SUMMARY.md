---
phase: 21-flexible-allocators
plan: 02
subsystem: docs, example-module
tags: [allocators, documentation, example-module, collections]
dependency_graph:
  requires: [21-01]
  provides: [allocator-docs, allocator-example]
  affects: [docs/09-memory.md, src/templates/example/example.orh]
tech_stack:
  added: []
  patterns: [include-for-flat-access, import-for-scoped-access]
key_files:
  created: []
  modified:
    - docs/09-memory.md
    - src/templates/example/example.orh
decisions:
  - "include std::collections added to example module to make List/Map/Set available without prefix"
metrics:
  duration: 10min
  completed_date: "2026-03-26"
  tasks_completed: 1
  files_modified: 2
---

# Phase 21 Plan 02: Docs and Example Module Summary

Allocator modes documented in docs/09-memory.md with all three patterns (default SMP, inline, external variable), and example module updated with working compilable allocator_demo() function plus include std::collections.

## Tasks Completed

| Task | Description | Commit | Files |
|------|-------------|--------|-------|
| 1 | docs/09-memory.md allocator section + example.orh allocator_demo() | 0038345 | docs/09-memory.md, example.orh |

## What Was Built

**Task 1:**
- `docs/09-memory.md`: added `## Allocators` section documenting three collection allocator modes with code examples for each, plus a table of available allocators and a note on custom allocators
- `src/templates/example/example.orh`: added `import std::allocator` at module scope, converted `include std::collections` from comment to active statement, replaced stale commented-out allocator example with working `pub func allocator_demo()` demonstrating all three modes
- Example module compiles as part of the full build — `./testall.sh` passes all 253 tests

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing critical functionality] example.orh used List(i32) without importing collections**
- **Found during:** Task 1 — the new allocator_demo() function uses `List(i32)` but the example module only had `include std::collections` inside a comment
- **Issue:** Without an active `include std::collections`, the List/Map/Set types would not be in scope and the example would not compile
- **Fix:** Converted the commented-out `include std::collections` to an active include statement, updating the surrounding comment to accurately reflect it
- **Files modified:** `src/templates/example/example.orh`
- **Commit:** 0038345

## Known Stubs

None. All three allocator modes are documented and demonstrated with working compilable code.

## Self-Check: PASSED

- commit 0038345 exists in git log
- `docs/09-memory.md` exists and contains `## Allocators`, `List(i32).new()`, `.new(arena.allocator())`, `SMP`
- `src/templates/example/example.orh` exists and contains `import std::allocator`, `pub func allocator_demo()`
- all 253 tests pass
