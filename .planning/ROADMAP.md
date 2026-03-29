# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- ✅ **v0.12 Quality & Polish** - Phases 12-14 (shipped 2026-03-25)
- ✅ **v0.13 Tamga Compatibility** - Phases 15-18 (shipped 2026-03-26)
- ✅ **v0.14 Build System** - Phases 19-21 (shipped 2026-03-27)
- ✅ **v0.15 Language Ergonomics** - Phases 22-24 (shipped 2026-03-27)
- ✅ **v0.16 Bug Fixes** - Phases 25-28 (shipped 2026-03-28)
- [ ] **v0.17 Codegen Refactor & Error Quality** - Phases 29-36

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

### v0.17 Codegen Refactor & Error Quality (Phases 29-36)

- [x] **Phase 29: Codegen Split** - Split codegen.zig into focused files with shared helpers (completed 2026-03-28)
- [x] **Phase 30: Error Quality** - "Did you mean?" suggestions, type mismatch display, ownership fix hints (completed 2026-03-28)
- [x] **Phase 31: PEG Error Messages** - Show all expected tokens when alternatives fail at same position (completed 2026-03-28)
- [x] **Phase 32: LSP Split** - Split lsp.zig (3301 lines) into types, JSON, analysis, handlers, and server loop (completed 2026-03-29)
- [x] **Phase 33: MIR Split** - Split mir.zig (2356 lines) into types, registry, node, annotator, lowerer, and utils (completed 2026-03-29)
- [x] **Phase 34: Main Split** - Split main.zig (2315 lines) into CLI, pipeline, init, stdlib bundler, and interface gen (completed 2026-03-29)
- [x] **Phase 35: Zig Runner Split** - Split zig_runner.zig (1952 lines) into runner, build gen, multi-target gen, and discovery (completed 2026-03-29)
- [x] **Phase 36: PEG Builder Split** - Split peg/builder.zig (1836 lines) into context, dispatch, decls, stmts, exprs, and types (completed 2026-03-29)

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
**Plans:** 1/1 plans complete
Plans:
- [x] 29-01-PLAN.md — Split codegen.zig into 4 files (core + decls + stmts + exprs) using wrapper stub pattern

### Phase 30: Error Quality
**Goal**: Compiler errors give developers actionable guidance — typos get suggestions, mismatches show types, ownership violations say what to do
**Depends on**: Phase 29
**Requirements**: ERR-01, ERR-02, ERR-03
**Success Criteria** (what must be TRUE):
  1. Misspelling a known identifier in scope produces "did you mean 'X'?" appended to the error message
  2. A type mismatch error shows "expected T1, got T2" with both type names resolved and spelled out
  3. A move-after-use error suggests "consider using `copy()`" or names the offending variable
  4. A borrow violation error suggests "consider borrowing with `const &`" where applicable
**Plans:** 2/2 plans complete
Plans:
- [x] 30-01-PLAN.md — Levenshtein infrastructure + "did you mean?" in resolver + type mismatch standardization
- [x] 30-02-PLAN.md — Ownership/borrow/thread fix hints + integration tests for all ERR requirements

### Phase 31: PEG Error Messages
**Goal**: Parse errors list every token the parser could have accepted at the failure point, not just the first alternative tried
**Depends on**: Phase 30
**Requirements**: PEG-01
**Success Criteria** (what must be TRUE):
  1. A syntax error at a choice point shows all expected tokens (e.g. "expected `func`, `struct`, or `enum`") instead of a single token
  2. The expected set is deduplicated — the same token name never appears twice in one error message
  3. Existing parse error tests in test/11_errors.sh still pass with the improved messages
**Plans:** 1/1 plans complete
Plans:
- [x] 31-01-PLAN.md — Extend PEG engine expected-set accumulation + consumer formatting

### Phase 32: LSP Split
**Goal**: lsp.zig is broken into focused files (types, JSON, analysis, handler groups, server loop) with no behavior change — LSP features work identically
**Depends on**: Phase 29
**Requirements**: SPLIT-01, SPLIT-02
**Success Criteria** (what must be TRUE):
  1. lsp.zig is split into 8+ files — no single file exceeds ~600 lines
  2. Handler groups (navigation, editing, view/hints) are in separate files
  3. JSON infrastructure and type definitions are isolated modules
  4. `./testall.sh` passes all tests — LSP unit tests pass in their new locations
**Plans:** 2/2 plans complete
Plans:
- [x] 32-01-PLAN.md — Extract foundation modules (lsp_types, lsp_json, lsp_utils, lsp_analysis)
- [x] 32-02-PLAN.md — Extract handler modules (lsp_nav, lsp_edit, lsp_view, lsp_semantic)

### Phase 33: MIR Split
**Goal**: mir.zig is broken into focused files (types, registry, node, annotator, lowerer, utils) with no behavior change — all tests pass
**Depends on**: Phase 29
**Requirements**: SPLIT-03, SPLIT-02
**Success Criteria** (what must be TRUE):
  1. mir.zig is split into 6+ files — MirAnnotator, MirLowerer, and UnionRegistry each in their own file
  2. Type definitions (TypeClass, Coercion, NodeInfo, MirKind) are in a shared types module
  3. MirNode struct is in its own file with accessor methods
  4. `./testall.sh` passes all tests — MIR unit tests pass in their new locations
**Plans:** 2/2 plans complete
Plans:
- [x] 33-01-PLAN.md — Extract foundation modules (mir_types, mir_registry, mir_node) from mir.zig
- [x] 33-02-PLAN.md — Extract implementation modules (mir_annotator, mir_lowerer), finalize mir.zig facade

### Phase 34: Main Split
**Goal**: main.zig is broken into focused files (CLI, pipeline, init, stdlib bundler, interface gen) with no behavior change — all tests pass
**Depends on**: Phase 29
**Requirements**: SPLIT-04, SPLIT-02
**Success Criteria** (what must be TRUE):
  1. main.zig is reduced to ~115 lines — allocator setup + command dispatch only
  2. Pipeline orchestration (runPipeline) is in its own file
  3. CLI parsing, project init, stdlib bundling, and interface generation are separate modules
  4. `./testall.sh` passes all tests — pipeline integration tests pass in their new locations
**Plans:** 2/2 plans complete
Plans:
- [x] 34-01-PLAN.md — Extract foundation modules (cli.zig, init.zig, std_bundle.zig, interface.zig)
- [x] 34-02-PLAN.md — Extract pipeline.zig and commands.zig, finalize main.zig facade

### Phase 35: Zig Runner Split
**Goal**: zig_runner.zig is broken into focused files (runner, single-target build gen, multi-target build gen, discovery) with no behavior change — all tests pass
**Depends on**: Phase 29
**Requirements**: SPLIT-05, SPLIT-02
**Success Criteria** (what must be TRUE):
  1. zig_runner.zig is reduced to ~400 lines — ZigRunner struct and invocation logic only
  2. buildZigContent (414 lines) and buildZigContentMulti (594 lines) are in separate files
  3. Zig binary discovery is in its own module
  4. `./testall.sh` passes all tests — build generation tests pass in their new locations
**Plans:** 1/1 plans complete
Plans:
- [x] 35-01-PLAN.md — Extract zig_runner_build.zig, zig_runner_multi.zig, zig_runner_discovery.zig; reduce zig_runner.zig to re-export facade

### Phase 36: PEG Builder Split
**Goal**: peg/builder.zig is broken into focused files (context, dispatch, decls, stmts, exprs, types) mirroring the codegen split pattern — all tests pass
**Depends on**: Phase 29
**Requirements**: SPLIT-06, SPLIT-02
**Success Criteria** (what must be TRUE):
  1. builder.zig is split into 6+ files — no single file exceeds ~510 lines
  2. Split follows the same decls/stmts/exprs/types pattern as the codegen split (Phase 29)
  3. Dispatch table remains centralized in one file importing all builder categories
  4. `./testall.sh` passes all tests — PEG builder tests pass in their new locations
**Plans:** 1/1 plans complete
Plans:
- [x] 36-01-PLAN.md — Split builder.zig into hub + 5 satellites (decls, bridge, stmts, exprs, types) with dispatch routing

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
| 29 | v0.17 | 1/1 | Complete    | 2026-03-28 |
| 30 | v0.17 | 2/2 | Complete    | 2026-03-28 |
| 31 | v0.17 | 1/1 | Complete    | 2026-03-28 |
| 32 | v0.17 | 2/2 | Complete    | 2026-03-29 |
| 33 | v0.17 | 2/2 | Complete    | 2026-03-29 |
| 34 | v0.17 | 2/2 | Complete    | 2026-03-29 |
| 35 | v0.17 | 1/1 | Complete    | 2026-03-29 |
| 36 | v0.17 | 1/1 | Complete    | 2026-03-29 |
