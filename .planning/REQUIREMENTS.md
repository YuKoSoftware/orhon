# Requirements: Orhon Compiler — Quality & Polish

**Defined:** 2026-03-25
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v0.12 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Fuzz Testing

- [x] **FUZZ-01**: Lexer fuzz testing using `std.testing.fuzz` — random input doesn't crash the lexer
- [x] **FUZZ-02**: Parser fuzz testing using `std.testing.fuzz` — random token streams don't crash the parser

### Tester Module

- [x] **TEST-01**: Tester module compiles end-to-end with zero cross-module codegen errors — test stages 09+10 fully pass

### Test Reliability

- [x] **RELY-01**: Intermittent unit test failure diagnosed and fixed — `zig build test` passes reliably across 5 consecutive runs

### Gate

- [ ] **GATE-01**: `./testall.sh` passes all 11 stages with 0 failures

## v2 Requirements

Deferred to future milestones.

### Architecture

- **ARCH-01**: Zig IR layer — split codegen into IR structs, lowering pass, and printer
- **ARCH-02**: Dependency-parallel module compilation via thread pool
- **ARCH-03**: MIR optimization passes (SSA, inlining, DCE, constant folding)
- **ARCH-04**: MIR binary serialization and caching
- **ARCH-05**: PEG syntax documentation auto-generator

### Polish

- **PLSH-01**: MIR residual AST accesses cleanup (6 remaining)

## Out of Scope

| Feature | Reason |
|---------|--------|
| New language features | Quality-focused milestone |
| Zig IR refactor | Large architectural change, separate milestone |
| Parallel compilation | Optimization, not correctness |
| MIR optimization | Optimization, not correctness |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| FUZZ-01 | Phase 12 | Complete |
| FUZZ-02 | Phase 12 | Complete |
| TEST-01 | Phase 13 | Complete |
| RELY-01 | Phase 13 | Complete |
| GATE-01 | Phase 14 | Pending |

**Coverage:**
- v0.12 requirements: 5 total
- Mapped to phases: 5
- Unmapped: 0

---
*Requirements defined: 2026-03-25*
*Last updated: 2026-03-25*
