---
phase: quick
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  # Moved files (25 total)
  - src/codegen/codegen.zig
  - src/codegen/codegen_decls.zig
  - src/codegen/codegen_exprs.zig
  - src/codegen/codegen_match.zig
  - src/codegen/codegen_stmts.zig
  - src/lsp/lsp.zig
  - src/lsp/lsp_analysis.zig
  - src/lsp/lsp_edit.zig
  - src/lsp/lsp_json.zig
  - src/lsp/lsp_nav.zig
  - src/lsp/lsp_semantic.zig
  - src/lsp/lsp_types.zig
  - src/lsp/lsp_utils.zig
  - src/lsp/lsp_view.zig
  - src/mir/mir.zig
  - src/mir/mir_annotator.zig
  - src/mir/mir_lowerer.zig
  - src/mir/mir_node.zig
  - src/mir/mir_registry.zig
  - src/mir/mir_types.zig
  - src/zig_runner/zig_runner.zig
  - src/zig_runner/zig_runner_build.zig
  - src/zig_runner/zig_runner_discovery.zig
  - src/zig_runner/zig_runner_multi.zig
  - src/peg/orhon.peg
  # Updated importers
  - src/pipeline.zig
  - src/main.zig
  - build.zig
autonomous: true
requirements: []
must_haves:
  truths:
    - "All 266 tests pass (./testall.sh)"
    - "Zero behavior change — only file locations changed"
    - "25 files moved into 4 subdirectories plus orhon.peg into peg/"
  artifacts:
    - path: "src/codegen/"
      provides: "codegen.zig + 4 satellites"
    - path: "src/lsp/"
      provides: "lsp.zig + 8 satellites"
    - path: "src/mir/"
      provides: "mir.zig + 5 satellites"
    - path: "src/zig_runner/"
      provides: "zig_runner.zig + 3 satellites"
    - path: "src/peg/orhon.peg"
      provides: "PEG grammar in peg/ directory"
  key_links:
    - from: "src/pipeline.zig"
      to: "src/codegen/codegen.zig, src/mir/mir.zig, src/zig_runner/zig_runner.zig"
      via: '@import("codegen/codegen.zig") etc.'
      pattern: '@import\("(codegen|mir|zig_runner)/'
    - from: "src/main.zig"
      to: "src/lsp/lsp.zig"
      via: '@import("lsp/lsp.zig")'
      pattern: '@import\("lsp/'
    - from: "src/peg.zig"
      to: "src/peg/orhon.peg"
      via: '@embedFile("peg/orhon.peg")'
      pattern: '@embedFile\("peg/orhon.peg"\)'
---

<objective>
Move 25 source files from the flat src/ directory into logical subdirectories (codegen/, lsp/, mir/, zig_runner/) and move orhon.peg into the existing src/peg/ directory. Update all @import paths, @embedFile paths, and build.zig test references. Zero behavior change.

Purpose: Organize src/ from a flat 50-file directory into coherent subsystem directories, continuing the pattern established by the existing src/peg/ and src/std/ directories.
Output: Clean directory structure with all tests passing.
</objective>

<execution_context>
@/home/yunus/.claude/get-shit-done/workflows/execute-plan.md
@/home/yunus/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@src/pipeline.zig (imports codegen, mir, zig_runner)
@src/main.zig (imports lsp)
@build.zig (test_files array)
@src/peg.zig (@embedFile for orhon.peg)
@src/peg/grammar.zig (@embedFile for orhon.peg)
</context>

<tasks>

<task type="auto">
  <name>Task 1: Move files into subdirectories and update intra-group imports</name>
  <files>
    src/codegen/ (5 files), src/lsp/ (9 files), src/mir/ (6 files), src/zig_runner/ (4 files), src/peg/orhon.peg
  </files>
  <action>
Create four new directories and move files using git mv:

```
mkdir -p src/codegen src/lsp src/mir src/zig_runner
git mv src/codegen.zig src/codegen_decls.zig src/codegen_exprs.zig src/codegen_match.zig src/codegen_stmts.zig src/codegen/
git mv src/lsp.zig src/lsp_analysis.zig src/lsp_edit.zig src/lsp_json.zig src/lsp_nav.zig src/lsp_semantic.zig src/lsp_types.zig src/lsp_utils.zig src/lsp_view.zig src/lsp/
git mv src/mir.zig src/mir_annotator.zig src/mir_lowerer.zig src/mir_node.zig src/mir_registry.zig src/mir_types.zig src/mir/
git mv src/zig_runner.zig src/zig_runner_build.zig src/zig_runner_discovery.zig src/zig_runner_multi.zig src/zig_runner/
git mv src/orhon.peg src/peg/orhon.peg
```

Then update ALL @import paths in the moved files. Two categories of path updates:

**A) Intra-group imports (sibling files in same new directory) — NO change needed.**
Files like codegen_decls.zig importing codegen.zig already use @import("codegen.zig") which resolves relative to the file's own directory. Since they moved together, these stay the same.

Similarly: lsp_*.zig importing each other, mir_*.zig importing each other, zig_runner_*.zig importing each other — all unchanged.

**B) Cross-group imports (reaching files in src/ root) — prepend "../".**
Every moved file that imports a src/ root file (parser.zig, types.zig, errors.zig, etc.) must change from @import("X.zig") to @import("../X.zig"). This follows the exact pattern established by src/peg/ files.

Specific files and their root imports to update:

codegen/ files (all 5 import from root):
- codegen.zig: parser, builtins, declarations, errors, K=constants, module, RT=types, mir → change all to ../X.zig. ALSO change mir import: @import("mir.zig") becomes @import("../mir/mir.zig") since mir is now in its own subdirectory.
- codegen_decls.zig: parser, mir, declarations, errors, K=constants, module, RT=types, builtins → same pattern. mir becomes @import("../mir/mir.zig").
- codegen_exprs.zig: parser, mir, declarations, errors, K=constants, module, RT=types, builtins → same. mir becomes @import("../mir/mir.zig").
- codegen_match.zig: parser, mir, declarations, errors, K=constants, module, RT=types, builtins → same. mir becomes @import("../mir/mir.zig").
- codegen_stmts.zig: parser, mir, declarations, errors, K=constants, module, RT=types, builtins → same. mir becomes @import("../mir/mir.zig").

lsp/ files:
- lsp.zig: lexer → @import("../lexer.zig")
- lsp_analysis.zig: parser, module, declarations, resolver, ownership, sema, errors, cache, types, builtins → all prepend ../
- lsp_edit.zig: builtins → @import("../builtins.zig")
- lsp_semantic.zig: lexer → @import("../lexer.zig")
- lsp_types.zig: parser, declarations, types, lexer → all prepend ../
- lsp_utils.zig: parser, declarations, builtins → all prepend ../
- lsp_json.zig: only lsp_types (sibling) → no change needed. Check for root imports.
- lsp_nav.zig: only lsp siblings → check for root imports.
- lsp_view.zig: only lsp siblings → check for root imports.

mir/ files:
- mir.zig: imports mir_types, mir_node, mir_registry, mir_annotator, mir_lowerer — all siblings, NO change needed.
- mir_annotator.zig: parser, declarations, errors, types, K=constants → all prepend ../
- mir_lowerer.zig: parser, declarations, K=constants → all prepend ../
- mir_node.zig: parser → @import("../parser.zig")
- mir_registry.zig: check for root imports.
- mir_types.zig: check for root imports (likely has types.zig).

zig_runner/ files:
- zig_runner.zig: errors, cache, module → all prepend ../
- zig_runner_build.zig: errors, cache, module → all prepend ../
- zig_runner_discovery.zig: errors → @import("../errors.zig")
- zig_runner_multi.zig: errors, cache, module → all prepend ../

IMPORTANT: For each file, read it first, identify ALL @import lines, classify each as sibling (no change) or root (prepend ../), and update. Do NOT miss any imports. Verify no @import("X.zig") remains where X.zig is a root file (not a sibling).

Also check for @embedFile paths. In lsp_analysis.zig or any lsp file, check for @embedFile references that may need path adjustment.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -30</automated>
  </verify>
  <done>All 25 files moved to subdirectories, all intra-file @import paths updated, compiler builds successfully with zig build.</done>
</task>

<task type="auto">
  <name>Task 2: Update external importers and build.zig test references</name>
  <files>
    src/pipeline.zig, src/main.zig, src/peg.zig, src/peg/grammar.zig, build.zig
  </files>
  <action>
Update the 3 files in src/ root that import the moved hub files:

1. **src/pipeline.zig** — 3 imports to update:
   - @import("mir.zig") → @import("mir/mir.zig")
   - @import("codegen.zig") → @import("codegen/codegen.zig")
   - @import("zig_runner.zig") → @import("zig_runner/zig_runner.zig")

2. **src/main.zig** — 1 import to update:
   - @import("lsp.zig") → @import("lsp/lsp.zig") (line 54, inside comptime block)

3. **src/peg.zig** — 1 @embedFile to update:
   - @embedFile("orhon.peg") → @embedFile("peg/orhon.peg")

4. **src/peg/grammar.zig** — 1 @embedFile to update:
   - @embedFile("../orhon.peg") → @embedFile("orhon.peg") (orhon.peg is now a sibling in peg/)

5. **build.zig** — Update test_files array paths (lines 59-89). Change all moved files:
   - "src/mir.zig" → "src/mir/mir.zig"
   - "src/mir_types.zig" → "src/mir/mir_types.zig"
   - "src/mir_registry.zig" → "src/mir/mir_registry.zig"
   - "src/mir_node.zig" → "src/mir/mir_node.zig"
   - "src/mir_annotator.zig" → "src/mir/mir_annotator.zig"
   - "src/mir_lowerer.zig" → "src/mir/mir_lowerer.zig"
   - "src/codegen.zig" → "src/codegen/codegen.zig"
   - "src/codegen_decls.zig" → "src/codegen/codegen_decls.zig"
   - "src/codegen_stmts.zig" → "src/codegen/codegen_stmts.zig"
   - "src/codegen_exprs.zig" → "src/codegen/codegen_exprs.zig"
   - "src/codegen_match.zig" → "src/codegen/codegen_match.zig"
   - "src/zig_runner.zig" → "src/zig_runner/zig_runner.zig"
   - "src/zig_runner_build.zig" → "src/zig_runner/zig_runner_build.zig"
   - "src/zig_runner_discovery.zig" → "src/zig_runner/zig_runner_discovery.zig"
   - "src/zig_runner_multi.zig" → "src/zig_runner/zig_runner_multi.zig"
   - "src/lsp.zig" → "src/lsp/lsp.zig"
   - "src/lsp_types.zig" → "src/lsp/lsp_types.zig"
   - "src/lsp_json.zig" → "src/lsp/lsp_json.zig"
   - "src/lsp_utils.zig" → "src/lsp/lsp_utils.zig"
   - "src/lsp_analysis.zig" → "src/lsp/lsp_analysis.zig"
   - "src/lsp_nav.zig" → "src/lsp/lsp_nav.zig"
   - "src/lsp_edit.zig" → "src/lsp/lsp_edit.zig"
   - "src/lsp_view.zig" → "src/lsp/lsp_view.zig"
   - "src/lsp_semantic.zig" → "src/lsp/lsp_semantic.zig"

NOTE on build.zig test compilation: Satellite files in subdirectories use @import("../X.zig") to reach root files. When build.zig compiles them as standalone test roots, Zig resolves relative paths from the file's directory. This should work — but if any satellite test fails to compile standalone (like the peg/ pattern from Phase 36 decision), those files may need to be removed from test_files. Check Phase 36 decision: "Peg satellites not in build.zig test_files: src/peg/ relative imports break standalone compilation." The same may apply here. If standalone test compilation fails for satellite files, remove them from test_files (keep only hub files: codegen.zig, lsp.zig, mir.zig, zig_runner.zig).

Also grep for any other files in src/ that might import the moved files — check docgen.zig, formatter.zig, sema.zig, etc.:
```
grep -rn '@import("codegen\|@import("lsp\|@import("mir\|@import("zig_runner' src/*.zig
```
Update any found references.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -10 && zig build test 2>&1 | tail -5</automated>
  </verify>
  <done>All external imports point to new subdirectory paths, build.zig test_files updated, zig build and zig build test both pass.</done>
</task>

<task type="auto">
  <name>Task 3: Full test suite validation and cleanup</name>
  <files>build.zig (if satellite test fix needed)</files>
  <action>
Run the full test suite to confirm zero behavior change:

```bash
./testall.sh
```

If any test stage fails:
1. Read the failure output carefully
2. Most likely cause: a missed @import path or @embedFile path
3. Fix the specific path and re-run

Verify no stale files remain in src/ root:
```bash
ls src/codegen*.zig src/lsp*.zig src/mir*.zig src/zig_runner*.zig src/orhon.peg 2>&1
```
All should report "No such file" — every file was git mv'd.

Verify the new directory structure:
```bash
ls src/codegen/ src/lsp/ src/mir/ src/zig_runner/ src/peg/orhon.peg
```

If satellite files fail standalone test compilation (per Phase 36 pattern), remove them from build.zig test_files — keep only the 4 hub files (codegen.zig, lsp.zig, mir.zig, zig_runner.zig) plus any satellites that compile standalone.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -20</automated>
  </verify>
  <done>All 266 tests pass. No stale files in src/ root. Directory structure is clean: src/codegen/ (5), src/lsp/ (9), src/mir/ (6), src/zig_runner/ (4), src/peg/orhon.peg.</done>
</task>

</tasks>

<verification>
- `zig build` succeeds (compiler builds)
- `zig build test` succeeds (unit tests pass)
- `./testall.sh` passes all 11 stages, 266 tests
- No codegen/lsp/mir/zig_runner/orhon.peg files remain in src/ root
- `git diff --stat` shows only renames + path edits, no logic changes
</verification>

<success_criteria>
- 25 files moved into 4 subdirectories + orhon.peg into peg/
- All @import and @embedFile paths updated
- build.zig test_files array updated
- All 266 tests pass unchanged
- git history preserved (git mv)
</success_criteria>

<output>
Create summary at .planning/quick/260329-ndd-move-25-files-into-logical-subdirectorie/260329-ndd-SUMMARY.md after completion.
</output>
