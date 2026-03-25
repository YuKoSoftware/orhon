# Phase 5: Error Suppression Sweep - Context

**Gathered:** 2026-03-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace all remaining silent error suppressors in the compiler and stdlib with proper error handling. Gate: `grep -c 'catch unreachable' src/codegen.zig` returns 0 for compiler-side instances, and `grep -rn 'catch {}' src/std/` returns 0.

</domain>

<decisions>
## Implementation Decisions

### Codegen catch unreachable (4 real instances)
- **D-01:** Only 4 of the 15 `catch unreachable` are actual compiler-side issues (lines 700, 726, 950, 983) — thread shared state allocation via `page_allocator.create()`. These crash the compiler on OOM instead of propagating errors.
- **D-02:** The other 8 instances (lines 1854-1879, 2292-2314) emit `catch unreachable` in **generated Zig output** — this is correct behavior after error union narrowing. These MUST stay unchanged.
- **D-03:** Line 2579 is a comment. Ignore.
- **D-04:** Fix the 4 compiler-side instances by propagating errors through `anyerror!` return types.

### Stdlib catch {} (28 instances across 6 files)
- **D-05:** Phase 2 already classified all 28 as either "fire-and-forget" (I/O in void functions) or "best-effort" (cleanup). Comments were added. The remaining work is mechanical replacement.
- **D-06:** For collections.zig (6 instances): `append`/`put` failures should return errors, not silently drop data. These are **data loss** bugs — the caller thinks the item was added.
- **D-07:** For console.zig (6), tui.zig (9), stream.zig (2): These are void I/O functions. Replace `catch {}` with `catch return` or document as intentional fire-and-forget with a project-wide constant comment pattern.
- **D-08:** For fs.zig (3), system.zig (2): Best-effort cleanup. Replace with `catch |_| {}` to acknowledge the error, or `catch return` where appropriate.

### Claude's Discretion
- Whether console/tui fire-and-forget catch sites need code changes or just documentation
- Exact error propagation pattern for collections (return error vs set a flag)
- Whether to add a project-level comment constant like `// FIRE_AND_FORGET` for auditing

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Error suppression locations
- `src/codegen.zig` lines 700, 726, 950, 983 — thread shared state allocation catch unreachable
- `src/codegen.zig` lines 1854-1879, 2292-2314 — generated Zig output (DO NOT CHANGE)
- `src/std/collections.zig` — 6 catch {} on append/put (data loss risk)
- `src/std/console.zig` — 6 catch {} on I/O writes (fire-and-forget)
- `src/std/fs.zig` — 3 catch {} on seek/cleanup (best-effort)
- `src/std/stream.zig` — 2 catch {} on stream writes (fire-and-forget)
- `src/std/system.zig` — 2 catch {} on signal handling (fire-and-forget)
- `src/std/tui.zig` — 9 catch {} on terminal I/O (fire-and-forget)

### Prior work
- `.planning/phases/02-memory-error-safety/` — Phase 2 classified all 103 original instances, fixed 75, documented remaining 28

### Project constraints
- `CLAUDE.md` — "Reporter owns all message strings — always defer free after report()"
- `CLAUDE.md` — "No hacky workarounds — clean fixes only"

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Patterns
- Phase 2 established the classification pattern: Category A (fire-and-forget I/O) vs Category B (data builders that must propagate)
- All 28 remaining instances already have inline comments from Phase 2 explaining their category

### Key Distinction
- **4 compiler-side catch unreachable** = crash the orhon compiler itself on OOM → must fix
- **8 generated-code catch unreachable** = correct narrowed unwrap in output Zig → must NOT change
- **28 stdlib catch {}** = mix of fire-and-forget (ok-ish) and data loss (must fix)

### Integration Points
- collections.zig changes may require updating bridge declarations in collections.orh if function signatures change to return errors
- codegen.zig thread state allocation changes need to preserve thread spawning behavior

</code_context>

<specifics>
## Specific Ideas

No specific requirements — this is a mechanical sweep with clear categories.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 05-error-suppression-sweep*
*Context gathered: 2026-03-25*
