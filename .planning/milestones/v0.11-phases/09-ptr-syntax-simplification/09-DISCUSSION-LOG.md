# Phase 9: Ptr Syntax Simplification - Discussion Log

> **Audit trail only.**

**Date:** 2026-03-25
**Phase:** 09-ptr-syntax-simplification
**Areas discussed:** Grammar removal, Type-directed coercion, Integer address handling
**Mode:** --auto

---

## Grammar Removal

| Option | Description | Selected |
|--------|-------------|----------|
| Remove both rules | Delete ptr_cast_expr and ptr_expr from PEG | ✓ |
| Keep as deprecated | Parse but warn | |

**User's choice:** [auto] Remove both rules (recommended — one way to do things)

## Type-Directed Coercion

| Option | Description | Selected |
|--------|-------------|----------|
| Codegen-level | Check type annotation at declaration emit time | ✓ |
| MIR-level | Add new coercion kind | |

**User's choice:** [auto] Codegen-level (recommended — simpler, no MIR changes)

## Integer Address Handling

| Option | Description | Selected |
|--------|-------------|----------|
| @ptrFromInt in codegen | Detect int literal + Ptr type annotation | ✓ |
| Require & always | Force address-of even for hardware addresses | |

**User's choice:** [auto] @ptrFromInt in codegen (recommended — hardware addresses need integer literals)

## Deferred Ideas

None
