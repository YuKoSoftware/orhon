# Requirements: Orhon Compiler — Bug Fixes & Cleanup

**Defined:** 2026-03-24
**Core Value:** A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Bug Fixes

- [x] **BUG-01**: Cross-module struct method calls emit by-value instead of `const &` — codegen needs imported DeclTables or MIR argument mode annotations
- [x] **BUG-02**: Qualified generic types (`math.Vec2(f64)`) pass validation without checking target type exists in referenced module's DeclTable
- [x] **BUG-03**: Const struct values incorrectly treated as moved when passed by value to functions — ownership checker should treat by-value passing of const as copy
- [x] **BUG-04**: `orhon test` reports 0 passed/0 failed instead of actually running test blocks — debug test command pipeline

### Memory & Error Handling

- [x] **MEM-01**: String interpolation `@{variable}` allocates temp buffers that are never freed — establish cleanup strategy
- [x] **MEM-02**: `catch unreachable` in codegen (lines 655, 688, 2123) crashes on OOM instead of propagating errors through Zig error system
- [x] **MEM-03**: 103 `catch {}` instances across 15 stdlib bridge files silently suppress allocation/I/O failures — propagate or apply consistent error strategy
- [x] **MEM-04**: Tester module pointer/collection constructors need migration to `.new()`/`.cast()` method-style constructors

### LSP Hardening

- [ ] **LSP-01**: Wrap `runAnalysis()` in per-request ArenaAllocator to prevent unbounded memory growth during long editing sessions
- [ ] **LSP-02**: Replace fixed 1024-byte header line buffer in `readMessage()` with dynamic allocation or larger compile-time constant
- [ ] **LSP-03**: Add upper bound on content-length header to prevent OOM from malicious or oversized requests

## v2 Requirements

Deferred to future milestones. Tracked but not in current roadmap.

### Architecture

- **ARCH-01**: Zig IR layer — split codegen into Zig IR structs, lowering pass, and printer
- **ARCH-02**: Dependency-parallel module compilation via thread pool
- **ARCH-03**: MIR optimization passes (SSA, inlining, DCE, constant folding)
- **ARCH-04**: MIR binary serialization and caching
- **ARCH-05**: PEG syntax documentation auto-generator

## Out of Scope

| Feature | Reason |
|---------|--------|
| New language features | Stabilization milestone — no new syntax or semantics |
| Zig IR refactor | Large architectural change, separate milestone |
| Parallel compilation | Optimization, not correctness |
| Tamga companion bugs | External project, different scope |
| v1.0 release | This milestone prepares for it but doesn't ship it |
| Formatter improvements | Not a bug, not blocking |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUG-01 | Phase 1 | Complete |
| BUG-02 | Phase 1 | Complete |
| BUG-03 | Phase 1 | Complete |
| BUG-04 | Phase 1 | Complete |
| MEM-01 | Phase 2 | Complete |
| MEM-02 | Phase 2 | Complete |
| MEM-03 | Phase 2 | Complete |
| MEM-04 | Phase 2 | Complete |
| LSP-01 | Phase 3 | Pending |
| LSP-02 | Phase 3 | Pending |
| LSP-03 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 11 total
- Mapped to phases: 11
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-24*
*Last updated: 2026-03-24 after roadmap creation*
