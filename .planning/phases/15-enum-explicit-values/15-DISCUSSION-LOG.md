# Phase 15: Enum Explicit Values - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-25
**Phase:** 15-enum-explicit-values
**Areas discussed:** Syntax design, Codegen mapping, Validation rules

---

## Syntax Design

| Option | Description | Selected |
|--------|-------------|----------|
| Value OR data, not both | `A = 4` or `A(i32)`, but not `A(i32) = 4`. Matches Zig. | ✓ |
| Allow both | `A(i32) = 4` valid — more flexible but no Zig precedent | |

**User's choice:** Value OR data, never both
**Notes:** User asked whether explicit values would conflict with tagged union enums. Conclusion: they're separate grammar branches (`= expr` vs `(fields)`), no syntactic conflict. Semantic mutual exclusion enforced at parse time.

## Codegen Mapping

**User's choice:** 1:1 mapping to Zig enum values
**Notes:** Straightforward — backing type carries through, Zig handles validation.

## Validation Rules

**User's choice:** Defer to Zig for uniqueness/overflow checks
**Notes:** No custom validation needed in the Orhon compiler since Zig rejects duplicates and out-of-range values at its compilation step.

---

## Claude's Discretion

- Grammar rule for value (`expr` vs `integer_literal`)
- AST node structure for optional value field
- Test fixture design

## Deferred Ideas

None
