# Requirements: Orhon Compiler

**Defined:** 2026-03-28
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v0.17 Requirements

Requirements for v0.17 Codegen Refactor & Error Quality milestone. Each maps to roadmap phases.

### Codegen Refactor

- [ ] **CGR-01**: codegen.zig split into 2-3 files — declarations (structs, enums, top-level functions), expressions, and statements — with a shared helpers module
- [ ] **CGR-02**: Type-to-Zig mapping consolidated into one location (currently scattered across typeToZig, emitType, and inline checks)
- [ ] **CGR-03**: Emit helpers (emit, emitFmt, emitIndent, emitLine) extracted to shared module importable by all codegen files
- [ ] **CGR-04**: Zero codegen output changes — generated Zig byte-for-byte identical before and after refactor (262 tests as gate)

### Error Quality

- [ ] **ERR-01**: "Did you mean X?" suggestions for identifier typos using Levenshtein distance against known names in scope
- [ ] **ERR-02**: Type mismatch errors show expected vs actual types (e.g., "expected i32, got f64")
- [ ] **ERR-03**: Ownership/borrow violation errors suggest fixes ("consider using `copy()`" or "consider borrowing with `const &`")

### Parser Errors

- [ ] **PEG-01**: PEG expected-set accumulation — when alternatives fail at the same position, show all expected tokens instead of just one

## Future Requirements

None deferred — all Tier 2 items included in v0.17.

## Out of Scope

| Feature | Reason |
|---------|--------|
| PEG labeled failures | Enhancement beyond expected-set; separate milestone |
| Codegen behavior changes | Pure refactor — no new codegen patterns |
| MIR SSA / optimization | Tier 4, separate milestone |
| Blueprints / traits | Tier 3, separate milestone |
| Cross-module error context | Nice-to-have, not core error quality |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CGR-01 | — | Not started |
| CGR-02 | — | Not started |
| CGR-03 | — | Not started |
| CGR-04 | — | Not started |
| ERR-01 | — | Not started |
| ERR-02 | — | Not started |
| ERR-03 | — | Not started |
| PEG-01 | — | Not started |

**Coverage:**
- v0.17 requirements: 8 total
- Mapped to phases: 0 (pending roadmap)
- Unmapped: 8

---
*Requirements defined: 2026-03-28*
*Last updated: 2026-03-28*
