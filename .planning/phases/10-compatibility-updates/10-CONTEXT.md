# Phase 10: Compatibility Updates - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Update Tamga companion project for new Ptr syntax, verify example module and tester fixtures are current, verify docs reflect both changes (const auto-borrow + Ptr syntax).

</domain>

<decisions>
## Implementation Decisions

### Tamga updates (COMP-01)
- **D-01:** Tamga has 2 files with old Ptr syntax:
  - `src/example/data_types.orh:85` — `Ptr(i32, &x)` → `&x` (new syntax)
  - `src/TamgaVK3D/tamga_vk3d.orh:6` — `Ptr(u8)` in function parameter (this is a TYPE annotation, not a constructor — may be fine as-is)
- **D-02:** Tamga currently compiles because incremental cache has old .zig files. Must clear cache and rebuild to verify.
- **D-03:** Tamga is NOT read-only for this phase — COMP-01 explicitly requires updating it. CLAUDE.md says "Do not modify any files in this project" but the REQUIREMENTS override this for Ptr syntax migration.
- **D-04:** After updating, delete `.orh-cache/` in Tamga and rebuild from scratch to confirm clean compilation.

### Example module (COMP-02)
- **D-05:** Phase 9 already migrated example module to new Ptr syntax. Verify it's complete — no `.cast()` references remain.
- **D-06:** Tester fixtures already migrated in Phase 9. Verify no `.cast()` references remain.
- **D-07:** Example module should demonstrate const auto-borrow behavior (new in Phase 8) — add a brief example if missing.

### Language docs (COMP-03)
- **D-08:** `docs/09-memory.md` was already updated for Ptr syntax (during v0.10 discussion). Verify it's current.
- **D-09:** `docs/09-memory.md` was already updated for const auto-borrow (during v0.10 discussion). Verify it's current.
- **D-10:** Check `docs/05-functions.md` for any `copy()` / `move()` / const semantics that need updating.

### Claude's Discretion
- Whether to add a const auto-borrow example to the example module
- Whether to clear Tamga's .orh-cache before or after the syntax update
- Any other docs that reference old Ptr syntax

</decisions>

<canonical_refs>
## Canonical References

### Tamga files to update
- `/home/yunus/Projects/orhon/tamga/src/example/data_types.orh` line 85 — old `Ptr(i32, &x)` syntax
- `/home/yunus/Projects/orhon/tamga/src/TamgaVK3D/tamga_vk3d.orh` line 6 — `Ptr(u8)` in param type (verify)

### Compiler files to verify
- `src/templates/example/data_types.orh` — Ptr examples (already migrated Phase 9)
- `test/fixtures/tester.orh` — Ptr tests (already migrated Phase 9)
- `docs/09-memory.md` — Ptr + const auto-borrow docs (already updated)
- `docs/05-functions.md` — copy/move/const semantics

</canonical_refs>

<code_context>
## Existing Code Insights

### Most Work Already Done
Phases 8 and 9 already migrated the compiler's own fixtures and examples. This phase is verification + Tamga update.

### Tamga Incremental Cache
Tamga compiles now only because `.orh-cache/generated/` has stale .zig files. Clearing the cache will expose the old `Ptr(i32, &x)` syntax as a parse error.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — verification and Tamga migration.

</specifics>

<deferred>
## Deferred Ideas

None

</deferred>

---

*Phase: 10-compatibility-updates*
*Context gathered: 2026-03-25*
