# Phase 20: Tamga Build Verification - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-27
**Phase:** 20-tamga-build-verification
**Areas discussed:** Bug scope, Verification strategy, Workaround removal

---

## Bug Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Core codegen bugs | 6 bugs: null union, cast, empty struct, pub export, const &Bridge, reserved size | ✓ |
| Multi-file sidecar build bug | "file exists in two modules" build system fix | ✓ |
| C/C++ source compilation | #csource directive for .c/.cpp files in modules | ✓ |
| Shared @cImport modules | Generate shared C import module for same-library sidecars | ✓ |

**User's choice:** All 9 bugs in scope. No deferrals.
**Notes:** User wants complete Tamga compatibility in one phase.

---

## Verification Strategy

| Option | Description | Selected |
|--------|-------------|----------|
| Build Tamga from its repo | Run orhon build in Tamga repo with new compiler | ✓ |
| Fixture tests only | Minimal .orh fixtures reproducing each bug | |
| Both | Fixture tests + final Tamga build gate | |

**User's choice:** Build Tamga from its repo. Success = orhon build completes without errors.
**Notes:** Most realistic verification — proves real-world project builds.

---

## Workaround Removal

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, remove workarounds | Fix compiler AND update Tamga source to remove all workarounds | ✓ |
| Compiler fixes only | Fix compiler, leave Tamga workarounds in place | |
| Remove where safe | Remove trivial workarounds, keep structural ones | |

**User's choice:** Remove ALL workarounds from Tamga source files.
**Notes:** Proves fixes work with clean code, not just backward-compatible with workarounds.

---

## Claude's Discretion

- Implementation order of the 9 bug fixes (dependency analysis left to planner)
- Whether to add regression tests for each bug in the compiler test suite

## Deferred Ideas

None — discussion stayed within phase scope.
