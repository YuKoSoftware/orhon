# Requirements: Orhon Compiler

**Defined:** 2026-03-28
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v0.17 Requirements

Requirements for v0.17 Codegen Refactor & Error Quality milestone. Each maps to roadmap phases.

### Codegen Refactor

- [x] **CGR-01**: codegen.zig split into 2-3 files — declarations (structs, enums, top-level functions), expressions, and statements — with a shared helpers module
- [x] **CGR-02**: Type-to-Zig mapping consolidated into one location (currently scattered across typeToZig, emitType, and inline checks)
- [x] **CGR-03**: Emit helpers (emit, emitFmt, emitIndent, emitLine) extracted to shared module importable by all codegen files
- [x] **CGR-04**: Zero codegen output changes — generated Zig byte-for-byte identical before and after refactor (262 tests as gate)

### Error Quality

- [x] **ERR-01**: "Did you mean X?" suggestions for identifier typos using Levenshtein distance against known names in scope
- [x] **ERR-02**: Type mismatch errors show expected vs actual types (e.g., "expected i32, got f64")
- [x] **ERR-03**: Ownership/borrow violation errors suggest fixes ("consider using `copy()`" or "consider borrowing with `const &`")

### Parser Errors

- [x] **PEG-01**: PEG expected-set accumulation — when alternatives fail at the same position, show all expected tokens instead of just one

### Module Splits

- [x] **SPLIT-01**: lsp.zig split into 8+ files — types, JSON infra, analysis, navigation handlers, edit handlers, view handlers, text utils, and server loop
- [x] **SPLIT-02**: Zero behavior change gate — `./testall.sh` passes all tests before and after each split, unit tests work in new locations
- [x] **SPLIT-03**: mir.zig split into 6+ files — types, registry, node, annotator, lowerer, and utils
- [x] **SPLIT-04**: main.zig split into 6+ files — CLI, pipeline, project init, stdlib bundler, interface gen, and slim dispatcher
- [ ] **SPLIT-05**: zig_runner.zig split into 4+ files — runner core, single-target build gen, multi-target build gen, and Zig discovery
- [ ] **SPLIT-06**: peg/builder.zig split into 6+ files — context, dispatch, decls, stmts, exprs, and types (mirrors codegen pattern)

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
| CGR-01 | Phase 29 | Complete |
| CGR-02 | Phase 29 | Complete |
| CGR-03 | Phase 29 | Complete |
| CGR-04 | Phase 29 | Complete |
| ERR-01 | Phase 30 | Complete |
| ERR-02 | Phase 30 | Complete |
| ERR-03 | Phase 30 | Complete |
| PEG-01 | Phase 31 | Complete |
| SPLIT-01 | Phase 32 | Complete |
| SPLIT-02 | Phases 32-36 | Complete |
| SPLIT-03 | Phase 33 | Complete |
| SPLIT-04 | Phase 34 | Complete |
| SPLIT-05 | Phase 35 | Pending |
| SPLIT-06 | Phase 36 | Pending |

**Coverage:**
- v0.17 requirements: 14 total
- Mapped to phases: 14 (Phase 29: 4, Phase 30: 3, Phase 31: 1, Phases 32-36: 6)
- Unmapped: 0

---
*Requirements defined: 2026-03-28*
*Last updated: 2026-03-28*
