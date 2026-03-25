# Phase 8: Const Auto-Borrow - Discussion Log

> **Audit trail only.**

**Date:** 2026-03-25
**Phase:** 08-const-auto-borrow
**Areas discussed:** Ownership semantics, MIR coercion scope, Edge cases
**Mode:** --auto

---

## Ownership Semantics

| Option | Description | Selected |
|--------|-------------|----------|
| Keep is_const, change meaning | Prevents move AND triggers auto-borrow | ✓ |
| Remove is_const, add auto_borrow | New flag entirely | |
| Change codegen only | Let ownership stay, fix in codegen | |

**User's choice:** [auto] Keep is_const, change meaning (recommended)

## MIR Coercion Scope

| Option | Description | Selected |
|--------|-------------|----------|
| In annotateCallCoercions | When const non-primitive arg passed to by-value param | ✓ |
| In codegen at emit time | Check const-ness during code generation | |

**User's choice:** [auto] In annotateCallCoercions (recommended — uses existing coercion infrastructure)

## Edge Cases

| Option | Description | Selected |
|--------|-------------|----------|
| Call sites only | Assignment still copies, only function args auto-borrow | ✓ |
| All pass contexts | Including assignment, return, etc. | |

**User's choice:** [auto] Call sites only (recommended — matches Zig behavior)

## Deferred Ideas

None
