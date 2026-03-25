# Phase 7: Full Test Suite Gate - Discussion Log

> **Audit trail only.**

**Date:** 2026-03-25
**Phase:** 07-full-test-suite-gate
**Areas discussed:** Null union test fix, String interpolation PEG builder gap
**Mode:** --auto

---

## Null Union Test

| Option | Description | Selected |
|--------|-------------|----------|
| Fix the test | Update grep to check for ? instead of OrhonNullable | ✓ |
| Revert codegen | Re-add OrhonNullable wrapper | |

**User's choice:** [auto] Fix the test (recommended — codegen is correct)

## String Interpolation

| Option | Description | Selected |
|--------|-------------|----------|
| Builder-level detection | Post-process STRING_LITERAL in builder | ✓ |
| Grammar-level rules | Add new PEG rules for interpolated strings | |

**User's choice:** [auto] Builder-level detection (recommended — minimal grammar change)

## Deferred Ideas

None
