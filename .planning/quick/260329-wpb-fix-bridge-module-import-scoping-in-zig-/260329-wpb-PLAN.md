---
phase: quick
plan: 260329-wpb
type: execute
wave: 1
depends_on: []
files_modified:
  - src/zig_runner/zig_runner_multi.zig
  - src/pipeline.zig
autonomous: true
requirements: [BLD-SCOPE]
must_haves:
  truths:
    - "Each multi-target only receives bridge imports for modules it actually imports"
    - "Single-target bridge_mods only includes bridges the root module imports"
    - "All existing tests still pass"
  artifacts:
    - path: "src/zig_runner/zig_runner_multi.zig"
      provides: "Per-target scoped extra_bridge_modules wiring"
    - path: "src/pipeline.zig"
      provides: "Scoped bridge_mods collection for single-target path"
  key_links:
    - from: "src/pipeline.zig"
      to: "src/zig_runner/zig_runner_multi.zig"
      via: "extra_bridge_mods passed to buildAll"
      pattern: "extra_bridge_mods"
---

<objective>
Fix bridge module import scoping so each build target only receives bridge imports for modules it actually uses, not all bridges in the project.

Purpose: Currently `extra_bridge_modules` are added to every lib/exe/test target in multi-target builds, and `bridge_mods` in single-target builds collects every non-root bridge module regardless of whether the root imports it. This adds unnecessary imports and violates the principle of minimal coupling.

Output: Tightened bridge import wiring in both single-target and multi-target paths.
</objective>

<execution_context>
@.planning/quick/260329-wpb-fix-bridge-module-import-scoping-in-zig-/260329-wpb-PLAN.md
</execution_context>

<context>
@src/zig_runner/zig_runner_multi.zig
@src/zig_runner/zig_runner_build.zig
@src/zig_runner/zig_runner.zig
@src/pipeline.zig
</context>

<tasks>

<task type="auto">
  <name>Task 1: Scope extra_bridge_modules per target in multi-target builds</name>
  <files>src/zig_runner/zig_runner_multi.zig</files>
  <action>
In `buildZigContentMulti`, the three places where `extra_bridge_modules` are blindly added to all targets need to be scoped:

1. **Lib targets (lines ~327-335):** Currently iterates `extra_bridge_modules` and adds every one to every lib target. Change to: only add `bmod_name` to `lib_{t.module_name}` if `bmod_name` appears in `t.mod_imports`. The `mod_imports` field already contains the non-lib imported module names for each target.

2. **Exe targets (lines ~467-474):** Same pattern — currently adds all `extra_bridge_modules` to every exe. Change to: only add `bmod_name` if it appears in `t.mod_imports`.

3. **Test target (lines ~584-591):** Same pattern — adds all `extra_bridge_modules` to the test target. Change to: only add `bmod_name` if it appears in `t.mod_imports` (where `t` is the first exe target used for tests).

For each of the three loops, wrap the inner body with a check:
```zig
for (extra_bridge_modules) |bmod_name| {
    // Only add bridge import if this target actually imports the module
    var uses_module = false;
    for (t.mod_imports) |mod_name| {
        if (std.mem.eql(u8, mod_name, bmod_name)) {
            uses_module = true;
            break;
        }
    }
    if (!uses_module) continue;
    // ... existing addImport emission
}
```

Do NOT change bridge_set logic, bridge-to-bridge wiring, or shared @cImport wiring — those are already correctly scoped.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build test 2>&1 | tail -5</automated>
  </verify>
  <done>extra_bridge_modules are only wired to targets that declare them in mod_imports</done>
</task>

<task type="auto">
  <name>Task 2: Scope bridge_mods collection in single-target pipeline path</name>
  <files>src/pipeline.zig</files>
  <action>
In the single-target build path (around lines 842-857), the `bridge_mods` collection iterates ALL non-root modules with bridges:

```zig
var bmod_it = mod_resolver.modules.iterator();
while (bmod_it.next()) |bmod_entry| {
    const bmod = bmod_entry.value_ptr;
    if (bmod.is_root) continue;
    if (bmod.has_bridges) {
        try bridge_mods.append(allocator, bmod.name);
    }
}
```

Change this to only collect bridge modules that the current root module actually imports (directly). Replace the iterator with a loop over `mod.imports`:

```zig
for (mod.imports) |imp_name| {
    const dep_mod = mod_resolver.modules.get(imp_name) orelse continue;
    if (dep_mod.is_root) continue;
    if (dep_mod.has_bridges) {
        try bridge_mods.append(allocator, dep_mod.name);
    }
}
```

This matches the existing pattern used by `shared_mods` collection (lines 860-869) which already correctly scopes to `mod.imports`.

Do NOT change the multi-target `extra_bridge_mods` collection (lines 692-703) — that uses a different data flow (the `MultiTarget.mod_imports` field carries per-target info, fixed in Task 1).
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -20</automated>
  </verify>
  <done>Single-target bridge_mods only includes bridges the root module imports; full test suite passes</done>
</task>

</tasks>

<verification>
- `zig build test` passes (unit tests including buildZigContent* tests)
- `./testall.sh` passes all 11 stages
- For a project with multiple modules where only some have bridges, generated build.zig only wires bridge imports to the targets that use them
</verification>

<success_criteria>
- Each build target (lib, exe, test) only receives `addImport` for bridge modules it actually imports
- No regression in existing test suite
- Generated build.zig is cleaner — no spurious bridge imports on unrelated targets
</success_criteria>

<output>
After completion, create `.planning/quick/260329-wpb-fix-bridge-module-import-scoping-in-zig-/260329-wpb-SUMMARY.md`
</output>
