---
phase: 27-c-interop-multi-module-build
plan: 01
subsystem: build-system
tags: [cimport, bridge, sidecar, multi-file-module, zig-runner, build-zig]

# Dependency graph
requires:
  - phase: 25-bridge-codegen-fixes
    provides: Bridge sidecar pub-fixup logic in main.zig pipeline
  - phase: 26-codegen-correctness-parser
    provides: Correct codegen for all tested language features
provides:
  - BLD-01: Multi-file module + Zig sidecar builds without hang or conflict
  - BLD-02: addIncludePath for module-relative cimport headers in generated build.zig
  - BLD-03: linkSystemLibrary always emitted for #cimport name regardless of source: presence
affects: [tamga-framework, any-cimport-user, any-bridge-module-user]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "needle.len advance pattern: when scanning with indexOfPos and appending the found needle, always advance pos by needle.len to prevent infinite loop re-matching the same occurrence"

key-files:
  created:
    - test/07_multimodule.sh (section added: Multi-file module with Zig sidecar)
  modified:
    - src/main.zig
    - src/zig_runner.zig

key-decisions:
  - "BLD-01 root cause was infinite loop in pub-fixup scanner: pos = idx never advanced past 'export fn', causing while loop to re-match same occurrence forever. Fix: append needle to result buffer and advance pos by needle.len."
  - "BLD-02: source_dir derived from sidecar_path dirname — no new struct field needed in main.zig, just derive at call site"
  - "BLD-03: the cimport_source == null guard was wrong — linkSystemLibrary must always be emitted alongside addCSourceFiles when #cimport has both name: and source:"

patterns-established:
  - "Bridge pub-fixup scanner: append needle text explicitly, advance pos past needle length to avoid infinite re-match"

requirements-completed: [BLD-01, BLD-02, BLD-03]

# Metrics
duration: ~90min (multi-session)
completed: 2026-03-28
---

# Phase 27 Plan 01: C Interop & Multi-Module Build Fixes Summary

**Fixed three build system bugs: infinite-loop pub-fixup scanner (BLD-01), missing addIncludePath for cimport headers (BLD-02), suppressed linkSystemLibrary when source: present (BLD-03); 262 tests pass**

## Performance

- **Duration:** ~90 min (multi-session)
- **Started:** 2026-03-28
- **Completed:** 2026-03-28T11:30:28Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- Fixed infinite loop hang when building user modules with `pub bridge func` (100% CPU spin, never produced output)
- Added `addIncludePath` emission to both single-target and multi-target build.zig generation paths for cimport module-relative headers
- Removed erroneous `cimport_source == null` guards that prevented `linkSystemLibrary` from being emitted when `#cimport` had both `name:` and `source:`
- Added multi-file-sidecar integration test to test/07_multimodule.sh covering BLD-01 scenario

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix BLD-03 — always emit linkSystemLibrary for #cimport name** - `4972175` (fix)
2. **Task 2: Fix BLD-02 — addIncludePath for module-relative cimport headers** - `03adaba` (fix)
3. **Task 3: Fix BLD-01 — infinite loop in bridge sidecar pub-fixup** - `b933527` (fix)

## Files Created/Modified
- `src/main.zig` - Removed three `cimport_source == null` guards (BLD-03); fixed infinite loop in `export fn` pub-fixup scanner (BLD-01)
- `src/zig_runner.zig` - Added `source_dir` field to `MultiTarget`, `emitIncludePath` helper, `addIncludePath` emission in both `buildZigContent` and `buildZigContentMulti` paths (BLD-02)
- `test/07_multimodule.sh` - Added "Multi-file module with Zig sidecar" test section

## Decisions Made
- BLD-01 root cause was in `main.zig` not `zig_runner.zig` or `module.zig` — the pub-fixup while loop doing `pos = idx` never advanced past the matched "export fn" string, creating an infinite loop for any module with bridge declarations
- For BLD-02, `source_dir` is derived from `mod.sidecar_path` dirname at the call site in `main.zig`; no schema change to how modules store their paths was needed
- BLD-03 fix is minimal: three `if (meta.metadata.cimport_source == null)` guards removed unconditionally

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Infinite loop in bridge sidecar pub-fixup scanner (BLD-01 root cause)**
- **Found during:** Task 3 (BLD-01 investigation)
- **Issue:** Plan described a "file exists in two modules" Zig error for multi-file modules with sidecars. During testing, the actual failure was a hang (100% CPU spin, no output). The `while` loop in main.zig bridge sidecar copy code at line ~1127 searched for `"export fn"` using `indexOfPos`, appended content up to the match, optionally prepended `"pub "`, then set `pos = idx`. Since `pos` never advanced past the `"export fn"` token, the next `indexOfPos` call started at the same position and found the same occurrence forever.
- **Fix:** Appended the `needle` text (`"export fn"`) to the result buffer explicitly and set `pos = idx + needle.len`, so each occurrence is processed exactly once.
- **Files modified:** `src/main.zig`
- **Verification:** `timeout 90 orhon build` completes in ~5s producing `bin/sidecarmod` and `bin/libmylib.a`; all 262 tests pass
- **Committed in:** `b933527` (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** The root cause differed from the plan's hypothesis (plan expected Zig "file exists in two modules" error from duplicate module registration; actual was an infinite loop in string scanning code). The fix scope is narrower and simpler than planned. No scope creep.

## Issues Encountered
- The "file exists in two modules" error mentioned in the plan was not reproducible — existing Tamga/multi-target builds already handle module deduplication correctly via named Zig modules. The actual symptom for BLD-01 was a hang, not a Zig error.
- Tracing required redirecting stderr to a file (debug prints go to stderr which `timeout ... 2>&1 | head -30` can buffer-deadlock on in some shells).

## Next Phase Readiness
- All three BLD bugs fixed; Tamga framework C interop builds should now work correctly
- 262 tests pass (2 new tests added in test/07_multimodule.sh)
- No open blockers

---
*Phase: 27-c-interop-multi-module-build*
*Completed: 2026-03-28*
