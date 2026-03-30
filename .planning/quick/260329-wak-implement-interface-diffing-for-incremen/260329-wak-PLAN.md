---
phase: quick
plan: 260329-wak
type: execute
wave: 1
depends_on: []
files_modified:
  - src/cache.zig
  - src/pipeline.zig
autonomous: true
must_haves:
  truths:
    - "When a module's source changes but its public interface stays the same, downstream dependents skip recompilation"
    - "When a module's public interface changes, downstream dependents recompile"
    - "First build computes and stores interface hashes for all modules"
    - "Existing source-level semantic hashing continues to work unchanged"
  artifacts:
    - path: "src/cache.zig"
      provides: "Interface hash computation, storage, and lookup"
      contains: "hashInterface"
    - path: "src/pipeline.zig"
      provides: "Interface-aware incremental skip logic"
      contains: "interface_hashes"
  key_links:
    - from: "src/pipeline.zig"
      to: "src/cache.zig"
      via: "hashInterface + interface hash storage"
      pattern: "hashInterface|interface_hashes"
    - from: "src/cache.zig"
      to: "src/declarations.zig"
      via: "DeclTable iteration for hashing"
      pattern: "DeclTable"
---

<objective>
Implement interface diffing for incremental compilation.

After declaration collection (Pass 4), compute a canonical hash of each module's
public interface (exported functions, structs, enums, bitfields, constants, type
aliases). Store interface hashes in `.orh-cache/interfaces`. When a module's source
changes but its public interface hash matches the cached one, downstream modules
that import it can skip recompilation (passes 5-12).

Purpose: Reduce recompilation cascading — internal-only changes (function bodies,
private helpers) no longer force all importers to rebuild.

Output: Updated `src/cache.zig` with interface hashing, updated `src/pipeline.zig`
with interface-aware dependency checking.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@src/cache.zig
@src/pipeline.zig
@src/declarations.zig
@src/types.zig
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Add interface hashing and interface hash storage to cache.zig</name>
  <files>src/cache.zig</files>
  <behavior>
    - hashInterface(DeclTable) produces a deterministic u64 from public declarations only
    - Two DeclTables with same public funcs/structs/enums/bitfields/vars/types produce same hash
    - Adding a private func (is_pub=false) does not change the hash
    - Adding a public func changes the hash
    - Changing a public func's return type changes the hash
    - Adding a field to a public struct changes the hash
    - Interface hashes load/save round-trip correctly via .orh-cache/interfaces file
  </behavior>
  <action>
Add to cache.zig:

1. Add `pub const INTERFACES_FILE = ".orh-cache/interfaces";` constant.

2. Add an `interface_hashes: std.StringHashMap(u64)` field to `Cache` struct alongside the existing
   `hashes` field. Initialize in `init()`, free keys in `deinit()`.

3. Add `pub fn loadInterfaceHashes(self: *Cache) !void` — same pattern as `loadHashes()` but reads
   from INTERFACES_FILE.

4. Add `pub fn saveInterfaceHashes(self: *Cache) !void` — same pattern as `saveHashes()` but writes
   to INTERFACES_FILE.

5. Add `pub fn hashInterface(decls: *const declarations.DeclTable) u64` — a standalone pub function
   that computes a deterministic hash of a module's public interface:

   Import `declarations` at top: `const declarations = @import("declarations.zig");` and
   `const types = @import("types.zig");`.

   The function must produce identical hashes for identical interfaces regardless of HashMap
   iteration order. Strategy:
   - Use XxHash3 with a running seed (same pattern as hashSemanticContent).
   - For each category (funcs, structs, enums, bitfields, vars, types), hash a category
     marker byte first (e.g., 0x01 for funcs, 0x02 for structs, etc.).
   - Collect all public entry names into a temporary buffer, sort them alphabetically,
     then hash each entry's canonical representation. Use a stack-allocated array for sorting
     up to 256 names; beyond that, skip sorting (rare edge case, still correct enough).
   - For funcs: hash name, each param type (via resolvedTypeTag), return type, is_compt, is_thread.
   - For structs: hash name, then sorted field names + field types + is_pub.
   - For enums: hash name, backing type, sorted variant names.
   - For bitfields: hash name, backing type, sorted flag names.
   - For vars: hash name, type (if present), is_const, is_compt.
   - For types (aliases): hash name.

   For hashing ResolvedType, write a helper `fn hashResolvedType(seed: u64, rt: types.ResolvedType) u64`
   that hashes the tag discriminant + inner data recursively (for primitives: hash the Primitive enum
   value; for named: hash the name string; for slice/error_union/null_union: recurse on inner; for
   generic: hash name + recurse on type_args; for ptr: hash kind + recurse on pointee; for inferred/unknown:
   hash just the tag).

   Only hash entries where `is_pub == true`. Skip private declarations entirely — this is the
   key property that makes interface diffing work.

6. Add `pub fn depInterfaceChanged(self: *Cache, dep_name: []const u8) bool` — returns true if
   the dependency's current interface hash differs from cached, or if no cached hash exists.

7. Add unit tests:
   - "interface hash deterministic" — build two identical DeclTables, verify same hash.
   - "interface hash ignores private" — add a non-pub func, verify hash unchanged.
   - "interface hash changes on public change" — add a pub func, verify hash differs.
   - "interface hashes load save roundtrip" — save to temp file, load back, verify values match.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build test 2>&1 | tail -5</automated>
  </verify>
  <done>
    hashInterface produces deterministic hashes from DeclTable public entries.
    Interface hash storage (load/save) works via .orh-cache/interfaces.
    All new unit tests pass. Existing cache tests still pass.
  </done>
</task>

<task type="auto">
  <name>Task 2: Integrate interface hashing into pipeline incremental logic</name>
  <files>src/pipeline.zig</files>
  <action>
Modify `runPipeline()` in pipeline.zig to use interface hashing for smarter dependency tracking:

1. After `comp_cache.loadHashes()` and `comp_cache.loadDeps()` (around line 68), add:
   ```
   try comp_cache.loadInterfaceHashes();
   ```

2. After each module's Pass 4 declaration collection completes successfully (after
   `try all_module_decls.put(mod_name, &decl_collector.table);` around line 158), compute
   and store the current interface hash:
   ```
   const current_iface_hash = cache.hashInterface(&decl_collector.table);
   ```

3. Modify the `moduleNeedsRecompile` check (around line 161). The current logic is:
   - If any source file changed OR any dependency's .zig file missing -> recompile.

   Replace the dependency check with interface-aware logic. Instead of calling
   `comp_cache.moduleNeedsRecompile(mod_name, mod_ptr.files)`, implement inline:

   a. Check if any of the module's own source files changed (use `comp_cache.hasChanged(file)`).
      If yes, the module itself needs recompile.
   b. If own sources unchanged, check if any dependency's interface hash changed
      (use `comp_cache.depInterfaceChanged(dep_name)` for each dep in `comp_cache.deps.get(mod_name)`).
      Also check if dep's generated .zig file exists (existing check). If any dep interface
      changed or .zig missing, this module needs recompile.
   c. If neither own sources nor dep interfaces changed, skip recompilation.

4. After codegen completes for a module (after `try cache.writeGeneratedZig(...)` around line 301),
   update the interface hash in the cache:
   ```
   const iface_key_result = try comp_cache.interface_hashes.getOrPut(mod_name);
   if (!iface_key_result.found_existing) {
       iface_key_result.key_ptr.* = try allocator.dupe(u8, mod_name);
   }
   iface_key_result.value_ptr.* = current_iface_hash;
   ```
   Note: `current_iface_hash` must be stored in a variable that survives to this point.
   Declare it before the `needs_recompile` check and set it after Pass 4.

5. After `try comp_cache.saveDeps();` (around line 321), add:
   ```
   try comp_cache.saveInterfaceHashes();
   ```

6. Update the dependency graph saving. Currently `comp_cache.saveDeps()` saves whatever was
   loaded. The deps are populated during module resolution, not pipeline. Verify the deps
   map is being populated — look at where `comp_cache.deps` gets written. If deps are only
   loaded (not updated), add logic after module resolution to update deps from `mod_resolver`:
   for each module in order, put its imports list into `comp_cache.deps`.

Do NOT modify `moduleNeedsRecompile()` in cache.zig — keep it as-is for backward compatibility.
The new logic lives inline in pipeline.zig where we have access to both the cache and the
DeclTable.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | tail -5 && ./testall.sh 2>&1 | tail -20</automated>
  </verify>
  <done>
    Pipeline computes interface hashes after Pass 4 for every compiled module.
    Interface hashes are persisted to .orh-cache/interfaces between builds.
    Dependency recompilation checks use interface hashes instead of just file existence.
    All 11 test stages pass. No regressions.
  </done>
</task>

</tasks>

<verification>
1. `zig build test` — all unit tests pass (including new cache tests)
2. `./testall.sh` — all 11 test stages pass
3. Manual verification: build a multi-module project twice, confirm second build skips
   downstream modules when only function bodies change in upstream modules
</verification>

<success_criteria>
- Interface hash is computed from public DeclTable entries only (private changes ignored)
- Hash is deterministic (sorted iteration, canonical form)
- .orh-cache/interfaces file persists between builds
- Downstream modules skip passes 5-12 when upstream interface unchanged
- All existing tests pass — zero regressions
</success_criteria>

<output>
After completion, create `.planning/quick/260329-wak-implement-interface-diffing-for-incremen/260329-wak-SUMMARY.md`
</output>
