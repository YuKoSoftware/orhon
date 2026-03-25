# Requirements: Orhon Compiler — Test Suite & Code Quality

**Defined:** 2026-03-25
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v0.10 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Codegen Correctness

- [x] **CGEN-01**: Tester module compiles successfully — test stages 09 and 10 pass (100 tests)
- [x] **CGEN-02**: Cross-module struct methods emit correct `&` for `const &` parameters (BUG-01)
- [x] **CGEN-03**: Qualified generic types (e.g. `math.Vec2(f64)`) validated at Orhon level before codegen (BUG-02)

### Error Suppression

- [ ] **ESUP-01**: All `catch unreachable` in codegen.zig replaced with proper error propagation (15 instances)
- [ ] **ESUP-02**: All `catch {}` in stdlib sidecars replaced with proper error handling (28 instances across 6 files)

### Project Hygiene

- [ ] **HYGN-01**: Version numbers aligned across build.zig, build.zig.zon, and PROJECT.md
- [ ] **HYGN-02**: String interpolation temp buffers freed after use (BUG-05)

### Documentation

- [ ] **DOCS-01**: Example module covers all implemented language features (RawPtr/VolatilePtr, #bitsize, any generics, typeOf(), include vs import)

### Gate

- [ ] **GATE-01**: `./testall.sh` passes all 11 stages with 0 failures

## v0.9 Requirements (Previous Milestone — Complete)

### Bug Fixes

- [x] **BUG-01**: Cross-module struct method calls emit by-value instead of `const &` — Phase 1
- [x] **BUG-02**: Qualified generic types pass validation without checking target type exists — Phase 1
- [x] **BUG-03**: Const struct values incorrectly treated as moved — Phase 1
- [x] **BUG-04**: `orhon test` reports 0 passed/0 failed — Phase 1

### Memory & Error Handling

- [x] **MEM-01**: String interpolation temp buffer cleanup via MIR defer injection — Phase 2
- [x] **MEM-02**: OOM error propagation in codegen — Phase 2
- [x] **MEM-03**: 103 `catch {}` classified and fixed/documented — Phase 2
- [x] **MEM-04**: Ptr(T).cast(addr) method-style constructors — Phase 2

### LSP Hardening

- [x] **LSP-01**: Per-request ArenaAllocator — Phase 3
- [x] **LSP-02**: Header buffer hardening — Phase 3
- [x] **LSP-03**: Content-length guard — Phase 3

## v2 Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### Architecture

- **ARCH-01**: Zig IR layer — split codegen into Zig IR structs, lowering pass, and printer
- **ARCH-02**: Dependency-parallel module compilation via thread pool
- **ARCH-03**: MIR optimization passes (SSA, inlining, DCE, constant folding)
- **ARCH-04**: MIR binary serialization and caching
- **ARCH-05**: PEG syntax documentation auto-generator

### Polish

- **PLSH-01**: MIR residual AST accesses cleanup (6 remaining)
- **PLSH-02**: Fuzz testing integration into CI

## Out of Scope

| Feature | Reason |
|---------|--------|
| New language features | Stabilization milestone — no new syntax or semantics |
| Zig IR refactor | Large architectural change, separate milestone |
| Parallel compilation | Optimization, not correctness |
| Tamga companion modifications | Read-only reference project |
| v1.0 release | This milestone prepares for it but doesn't ship it |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CGEN-01 | Phase 4 | Complete |
| CGEN-02 | Phase 4 | Complete |
| CGEN-03 | Phase 4 | Complete |
| ESUP-01 | Phase 5 | Pending |
| ESUP-02 | Phase 5 | Pending |
| HYGN-01 | Phase 6 | Pending |
| HYGN-02 | Phase 6 | Pending |
| DOCS-01 | Phase 6 | Pending |
| GATE-01 | Phase 7 | Pending |

**Coverage:**
- v0.10 requirements: 9 total
- Mapped to phases: 9
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-25*
*Last updated: 2026-03-25 after roadmap creation*
