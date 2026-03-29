# Phase 36: PEG Builder Split - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-29
**Phase:** 36-peg-builder-split
**Areas discussed:** Split granularity, File boundaries, Dispatch pattern, Test placement
**Mode:** auto (all decisions auto-selected with recommended defaults)

---

## Split Granularity

| Option | Description | Selected |
|--------|-------------|----------|
| 5 satellite files (decls/stmts/exprs/types + hub) | Mirrors codegen split, proven pattern | ✓ |
| 6+ files (context/dispatch/decls/stmts/exprs/types) | Finer granularity per roadmap goal | |
| 4 files (decls/stmts/exprs, types merged into exprs) | Fewer files, types are small | |

**User's choice:** [auto] 5 satellite files — matches codegen pattern exactly, proven approach
**Notes:** builder_types.zig is small (~170 lines) but types are conceptually distinct from expressions

---

## Dispatch Pattern

| Option | Description | Selected |
|--------|-------------|----------|
| Hub imports satellites, dispatch calls satellite functions | Matches codegen.zig pattern | ✓ |
| Satellites register into a dispatch table | More dynamic, harder to follow | |
| BuildContext methods delegate to satellites | Requires BuildContext to know about satellites | |

**User's choice:** [auto] Hub imports satellites — direct delegation like codegen.zig
**Notes:** buildNode stays in builder.zig, calls decls_impl.buildProgram(ctx, cap) etc.

---

## Helper Placement

| Option | Description | Selected |
|--------|-------------|----------|
| Keep shared helpers in builder.zig | Satellites import builder for helpers | ✓ |
| Move helpers to builder_utils.zig | Extra file for ~100 lines of helpers | |
| Duplicate helpers per satellite | No cross-file deps, but code duplication | |

**User's choice:** [auto] Keep in builder.zig — avoids extra file, satellites already import builder
**Notes:** tokenText, findTokenInRange, buildAllChildren, collectExprsRecursive etc. stay in hub

---

## Test Placement

| Option | Description | Selected |
|--------|-------------|----------|
| Keep tests in builder.zig | Tests use buildAST entry points, test integrated behavior | ✓ |
| Move tests to satellite files | Would need to re-export test helpers | |
| New builder_test.zig | Extra file, same integration tests | |

**User's choice:** [auto] Keep in builder.zig — tests exercise the full pipeline through buildAST
**Notes:** All 4 existing tests call buildAST which dispatches through buildNode

---

## Claude's Discretion

- Exact helper/satellite boundary within builder.zig
- buildDestructFromTail placement (recommended: with decls)
- Whether to further split decls if it exceeds 510 lines

## Deferred Ideas

None
