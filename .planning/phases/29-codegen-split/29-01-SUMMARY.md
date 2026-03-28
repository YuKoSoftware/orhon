---
phase: 29-codegen-split
plan: 01
subsystem: codegen
tags: [zig, refactor, codegen, split, wrapper-stubs]

# Dependency graph
requires: []
provides:
  - codegen.zig split into 5 focused files under 1200 lines each
  - wrapper stub pattern established for Zig 0.15 cross-file method delegation
  - codegen_decls.zig for declaration generators
  - codegen_stmts.zig for statement/block generators
  - codegen_exprs.zig for core MIR expression generators
  - codegen_match.zig for match/interpolation/compiler-func generators
affects: [blueprints, closures, any future codegen changes]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Wrapper stub pattern: helper files define pub fn foo(cg: *CodeGen, ...), codegen.zig has one-liner stubs that delegate"
    - "File-scope pub forwarders in codegen.zig for static functions helper files need (extractValueType, isTypeAlias, mirIsString, opToZig, isResultValueField)"
    - "No direct inter-helper imports — all cross-file calls route through *CodeGen stubs in codegen.zig"

key-files:
  created:
    - src/codegen_decls.zig
    - src/codegen_stmts.zig
    - src/codegen_exprs.zig
    - src/codegen_match.zig
  modified:
    - src/codegen.zig
    - build.zig
    - test/08_codegen.sh

key-decisions:
  - "Split codegen_exprs.zig into codegen_exprs.zig + codegen_match.zig because MIR expressions section (1895 lines) was much larger than the research estimate of ~1180 lines"
  - "Made all CodeGen struct methods pub to allow helper files to call them via cg.method()"
  - "Added file-scope pub forwarders in codegen.zig for static functions (no self param) called by helpers"
  - "opToZig and isResultValueField moved to codegen_match.zig (with their original implementation); available via codegen.opToZig() file-scope forwarder"
  - "extractValueType moved to file scope in codegen.zig (was struct method but has no self param)"

patterns-established:
  - "Wrapper stub: fn foo(self: *CodeGen, ...) RetType { return impl_module.foo(self, ...); }"
  - "Helper file header: const codegen = @import(codegen.zig); const CodeGen = codegen.CodeGen;"
  - "Static utility functions exposed at file scope in codegen.zig as pub fn for helpers to call as codegen.fn()"

requirements-completed: [CGR-01, CGR-02, CGR-03, CGR-04]

# Metrics
duration: 126min
completed: 2026-03-28
---

# Phase 29 Plan 01: Codegen Split Summary

**codegen.zig split from 4354-line monolith into 5 focused files (938-1082 lines each) using Zig 0.15 wrapper stub pattern, with all 262 tests passing and byte-for-byte identical codegen output**

## Performance

- **Duration:** ~126 min
- **Started:** 2026-03-28T18:05:00Z
- **Completed:** 2026-03-28T20:11:00Z
- **Tasks:** 1
- **Files modified:** 7 (4 created, 3 modified)

## Accomplishments
- Extracted 4354-line codegen.zig into 5 focused files, all under 1200 lines
- Established wrapper stub pattern as the Zig 0.15 cross-file delegation mechanism
- Made all 262 tests pass with zero output changes (pure refactor per D-05)
- Updated test/08_codegen.sh to check the correct file for interpolation error propagation

## Task Commits

1. **Task 1: Split codegen.zig into 5 focused files** - `dcc23f0` (feat)

## Files Created/Modified
- `src/codegen.zig` (938 lines) - CodeGen struct, emit helpers, typeToZig, wrapper stubs for all moved functions, file-scope pub forwarders
- `src/codegen_decls.zig` (877 lines) - Declaration generators: func/struct/enum/bitfield/var/const/compt/test
- `src/codegen_stmts.zig` (779 lines) - Block/statement generators + AST generateExpr
- `src/codegen_exprs.zig` (967 lines) - Core MIR expression generators, continue/range/interpolation/for/destruct
- `src/codegen_match.zig` (1082 lines) - Match/type-match/string-match/interpolated-string-mir/compiler-func/ptr-coercion/arithmetic overflow generators
- `build.zig` - Added 4 new codegen files to test_files array
- `test/08_codegen.sh` - Updated interpolation OOM test to check codegen_exprs.zig instead of codegen.zig

## Decisions Made
- Split into 5 files instead of planned 4: codegen_exprs.zig needed to split further because the MIR expressions section was 1895 lines vs the research estimate of ~1180. Created codegen_match.zig for match/compiler-func generators.
- Made all CodeGen struct methods pub: helper files call methods via `cg.method()` which requires pub visibility
- File-scope pub forwarders in codegen.zig: static functions (no self param) like `opToZig`, `mirIsString`, `extractValueType`, `isTypeAlias`, `isResultValueField` are exposed as `pub fn` at file scope so helpers call `codegen.functionName()` without importing each other

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing] Added pub visibility to all CodeGen struct methods**
- **Found during:** Task 1 (first build attempt)
- **Issue:** Helper files call methods via `cg.method(...)` which requires `pub` on the struct methods
- **Fix:** Added `pub` to all 91 struct methods that didn't already have it
- **Files modified:** src/codegen.zig
- **Verification:** Build succeeded after change
- **Committed in:** dcc23f0 (task commit)

**2. [Rule 3 - Blocking] Split codegen_exprs.zig into exprs + match files**
- **Found during:** Task 1 (line count verification)
- **Issue:** codegen_exprs.zig was 2032 lines, exceeding the 1200-line constraint. The research estimated ~1180 but the actual MIR expressions section was 1895 lines.
- **Fix:** Created codegen_match.zig (lines 968-2032 of the original exprs file), added match_impl import to codegen.zig, updated all affected stubs
- **Files modified:** src/codegen.zig, src/codegen_exprs.zig, src/codegen_match.zig (new), build.zig
- **Verification:** All 262 tests pass, all files under 1200 lines
- **Committed in:** dcc23f0 (task commit)

**3. [Rule 1 - Bug] Fixed collectAssigned/collectAssignedMir stubs missing `alloc` parameter**
- **Found during:** Task 1 (Python stub generator bug)
- **Issue:** Stub generator parsed `std.mem.Allocator` as having only 2 params (missed `alloc` due to dot in type name)
- **Fix:** Manually corrected the stubs to pass `alloc` as third argument
- **Files modified:** src/codegen.zig
- **Verification:** Build succeeded
- **Committed in:** dcc23f0 (task commit)

**4. [Rule 1 - Bug] Updated test/08_codegen.sh after moving functions to helper files**
- **Found during:** Task 1 (testall.sh run)
- **Issue:** Test checked `codegen.zig` for interpolation error propagation patterns, but those functions moved to `codegen_exprs.zig`
- **Fix:** Updated the test to check `codegen_exprs.zig` instead
- **Files modified:** test/08_codegen.sh
- **Verification:** test passes 9/9
- **Committed in:** dcc23f0 (task commit)

---

**Total deviations:** 4 auto-fixed (1 missing visibility, 1 blocking split needed, 1 parameter bug, 1 test update)
**Impact on plan:** Split uses 5 files instead of planned 4 to meet the 1200-line constraint. Architecture is identical — same wrapper stub pattern, same routing through *CodeGen stubs.

## Issues Encountered
- Python brace-counting script failed on 5 functions with `{{ }}` escape sequences in format strings — manually stubbed those 5 functions
- The `generateEnumMir` collapse ate the entire bottom half of the struct (including typeToZig) because the brace counter was confused by escaped format sequences — restored the TYPE TRANSLATION section from git history

## Next Phase Readiness
- Codegen is now split and manageable — each file is focused on one category of constructs
- Future features (blueprints, closures) can be added to the appropriate helper file
- No blockers

---
*Phase: 29-codegen-split*
*Completed: 2026-03-28*
