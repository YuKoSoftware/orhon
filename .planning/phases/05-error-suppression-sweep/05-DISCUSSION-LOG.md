# Phase 5: Error Suppression Sweep - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-25
**Phase:** 05-error-suppression-sweep
**Areas discussed:** Error propagation strategy, Stdlib catch handling policy
**Mode:** --auto (all areas auto-selected, recommended defaults chosen)

---

## Error Propagation Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Replace with anyerror propagation | Proper error returns through compiler call chain | ✓ |
| Replace with @panic with message | Crash with diagnostic info | |
| Keep catch unreachable | Status quo | |

**User's choice:** [auto] Replace with anyerror propagation (recommended default)
**Notes:** Only 4 of 15 instances are actual compiler-side issues. The other 11 are generated code output (correct) or comments.

---

## Stdlib Catch Handling Policy

| Option | Description | Selected |
|--------|-------------|----------|
| Fix data-loss sites, document fire-and-forget | Collections must propagate, I/O can stay void | ✓ |
| Fix all to return errors | Every catch {} becomes a returned error | |
| Document all as intentional | Add comments, no code changes | |

**User's choice:** [auto] Fix data-loss sites, document fire-and-forget (recommended default)
**Notes:** collections.zig catch {} sites are data loss bugs. Console/tui are legitimately fire-and-forget.

---

## Claude's Discretion

- Console/tui fire-and-forget handling approach
- Collections error propagation pattern
- Comment convention for fire-and-forget sites

## Deferred Ideas

None
