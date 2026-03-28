# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- ✅ **v0.12 Quality & Polish** - Phases 12-14 (shipped 2026-03-25)
- ✅ **v0.13 Tamga Compatibility** - Phases 15-18 (shipped 2026-03-26)
- ✅ **v0.14 Build System** - Phases 19-21 (shipped 2026-03-27)
- ✅ **v0.15 Language Ergonomics** - Phases 22-24 (shipped 2026-03-27)
- ✅ **v0.16 Bug Fixes** - Phases 25-28 (shipped 2026-03-28)
- [ ] **v0.17 Codegen Refactor & Error Quality** - Phases 29-31

## Phases

<details>
<summary>✅ v0.10 Bug Fix & Cleanup (Phases 1-7) - SHIPPED 2026-03-24</summary>

See: [milestones/v0.10-ROADMAP.md](milestones/v0.10-ROADMAP.md)

</details>

<details>
<summary>✅ v0.11 Language Simplification (Phases 8-11) - SHIPPED 2026-03-25</summary>

See: [milestones/v0.11-ROADMAP.md](milestones/v0.11-ROADMAP.md)

</details>

<details>
<summary>✅ v0.12 Quality & Polish (Phases 12-14) - SHIPPED 2026-03-25</summary>

See: [milestones/v0.12-ROADMAP.md](milestones/v0.12-ROADMAP.md)

</details>

<details>
<summary>✅ v0.13 Tamga Compatibility (Phases 15-18) - SHIPPED 2026-03-26</summary>

See: [milestones/v0.13-ROADMAP.md](milestones/v0.13-ROADMAP.md)

</details>

<details>
<summary>✅ v0.14 Build System (Phases 19-21) - SHIPPED 2026-03-27</summary>

See: [milestones/v0.14-ROADMAP.md](milestones/v0.14-ROADMAP.md)

</details>

<details>
<summary>✅ v0.15 Language Ergonomics (Phases 22-24) - SHIPPED 2026-03-27</summary>

See: [milestones/v0.15-ROADMAP.md](milestones/v0.15-ROADMAP.md)

</details>

<details>
<summary>✅ v0.16 Bug Fixes (Phases 25-28) - SHIPPED 2026-03-28</summary>

- [x] Phase 25: Bridge Codegen Fixes — const &, error-union params, pub export fn (1/1 plans)
- [x] Phase 26: Codegen Correctness & Parser — cross-module is, Async(T) error, negative literals (1/1 plans)
- [x] Phase 27: C Interop & Multi-Module Build — sidecar dedup, cimport paths, linkSystemLibrary (1/1 plans)
- [x] Phase 28: Cross-Compile, Cache & Docs — target flag fix, -fast cache leak, Async(T) removal (2/2 plans)

See: [milestones/v0.16-ROADMAP.md](milestones/v0.16-ROADMAP.md)

</details>

### v0.17 Codegen Refactor & Error Quality (Phases 29-31)

- [ ] **Phase 29: Codegen Split** - Split codegen.zig into focused files with shared helpers
- [ ] **Phase 30: Error Quality** - "Did you mean?" suggestions, type mismatch display, ownership fix hints
- [ ] **Phase 31: PEG Error Messages** - Show all expected tokens when alternatives fail at same position

## Phase Details

### Phase 29: Codegen Split
**Goal**: codegen.zig is broken into 2-3 focused files with no behavior change — all 262 tests still pass
**Depends on**: Nothing (first phase of milestone)
**Requirements**: CGR-01, CGR-02, CGR-03, CGR-04
**Success Criteria** (what must be TRUE):
  1. codegen.zig is split into at least 2 files (e.g. codegen_decls.zig, codegen_exprs.zig) — no single file exceeds ~1200 lines
  2. Emit helpers (emit, emitFmt, emitIndent, emitLine) live in one shared module imported by all codegen files
  3. Type-to-Zig mapping (typeToZig, emitType) exists in exactly one location with no inline duplicates
  4. `./testall.sh` passes 262/262 — generated Zig output is byte-for-byte identical to pre-refactor
**Plans:** 1 plan
Plans:
- [ ] 29-01-PLAN.md — Split codegen.zig into 4 files (core + decls + stmts + exprs) using wrapper stub pattern

### Phase 30: Error Quality
**Goal**: Compiler errors give developers actionable guidance — typos get suggestions, mismatches show types, ownership violations say what to do
**Depends on**: Phase 29
**Requirements**: ERR-01, ERR-02, ERR-03
**Success Criteria** (what must be TRUE):
  1. Misspelling a known identifier in scope produces "did you mean 'X'?" appended to the error message
  2. A type mismatch error shows "expected T1, got T2" with both type names resolved and spelled out
  3. A move-after-use error suggests "consider using `copy()`" or names the offending variable
  4. A borrow violation error suggests "consider borrowing with `const &`" where applicable
**Plans**: TBD

### Phase 31: PEG Error Messages
**Goal**: Parse errors list every token the parser could have accepted at the failure point, not just the first alternative tried
**Depends on**: Phase 30
**Requirements**: PEG-01
**Success Criteria** (what must be TRUE):
  1. A syntax error at a choice point shows all expected tokens (e.g. "expected `func`, `struct`, or `enum`") instead of a single token
  2. The expected set is deduplicated — the same token name never appears twice in one error message
  3. Existing parse error tests in test/11_errors.sh still pass with the improved messages
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-7 | v0.10 | All | Complete | 2026-03-24 |
| 8-11 | v0.11 | All | Complete | 2026-03-25 |
| 12-14 | v0.12 | All | Complete | 2026-03-25 |
| 15-18 | v0.13 | 5/5 | Complete | 2026-03-26 |
| 19-21 | v0.14 | 6/6 | Complete | 2026-03-27 |
| 22-24 | v0.15 | 6/6 | Complete | 2026-03-27 |
| 25-28 | v0.16 | 5/5 | Complete | 2026-03-28 |
| 29 | v0.17 | 0/1 | Not started | - |
| 30 | v0.17 | 0/1 | Not started | - |
| 31 | v0.17 | 0/1 | Not started | - |
