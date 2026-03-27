# Requirements: Orhon Compiler v0.15

**Defined:** 2026-03-27
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v1 Requirements

### Error Propagation

- [ ] **ERR-01**: `throw x` propagates error from `(Error | T)` and returns early from enclosing function
- [ ] **ERR-02**: After `throw x`, variable `x` narrows to value type `T` (no `.value` needed)
- [ ] **ERR-03**: `throw` in a function that doesn't return an error type produces compile error
- [ ] **ERR-04**: Example module and docs updated with `throw` usage

### Pattern Guards

- [ ] **GUARD-01**: Match arms accept `case x if expr` guard syntax — arm only matches when guard is true
- [ ] **GUARD-02**: Guard expression can reference the bound variable and outer scope
- [ ] **GUARD-03**: Example module and docs updated with pattern guard usage

### C Import Unification

- [ ] **CIMP-01**: `#cimport "lib"` directive replaces `#linkC`, `#cInclude`, `#csource`, `#linkCpp`
- [ ] **CIMP-02**: Optional block syntax `#cimport "lib" { include: "...", source: "..." }` for overrides
- [ ] **CIMP-03**: Duplicate `#cimport` for same library across project produces compile error
- [ ] **CIMP-04**: Old directives (#linkC, #cInclude, #csource, #linkCpp) removed or deprecated
- [ ] **CIMP-05**: Tamga framework migrated to `#cimport` syntax
- [ ] **CIMP-06**: Example module and docs updated with `#cimport` usage

## Future Requirements

### Compiler Architecture (Tier 2)
- **ARCH-01**: Codegen split into 2-3 files (declarations, expressions, statements)
- **ARCH-02**: PEG expected-set error accumulation
- **ARCH-03**: PEG labeled failures
- **ARCH-04**: Error message quality ("did you mean?", fix suggestions)

### Type System (Tier 3)
- **TYPE-01**: Minimal traits (methods only, explicit impl)
- **TYPE-02**: NLL borrow checking (borrow ends at last use)

## Out of Scope

| Feature | Reason |
|---------|--------|
| `try` expression prefix | Rejected — `throw` statement is cleaner, less noisy |
| Implicit error propagation | Too much hidden control flow |
| Traits | Large scope, better after codegen refactor (Tier 3) |
| SSA/optimization passes | Optimization, not correctness (Tier 4) |
| Incremental compilation improvements | Optimization, not correctness (Tier 4) |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| ERR-01 | — | Pending |
| ERR-02 | — | Pending |
| ERR-03 | — | Pending |
| ERR-04 | — | Pending |
| GUARD-01 | — | Pending |
| GUARD-02 | — | Pending |
| GUARD-03 | — | Pending |
| CIMP-01 | — | Pending |
| CIMP-02 | — | Pending |
| CIMP-03 | — | Pending |
| CIMP-04 | — | Pending |
| CIMP-05 | — | Pending |
| CIMP-06 | — | Pending |

**Coverage:**
- v1 requirements: 13 total
- Mapped to phases: 0
- Unmapped: 13 (pending roadmap)

---
*Requirements defined: 2026-03-27*
*Last updated: 2026-03-27 after initial definition*
