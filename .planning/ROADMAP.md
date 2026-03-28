# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- ✅ **v0.12 Quality & Polish** - Phases 12-14 (shipped 2026-03-25)
- ✅ **v0.13 Tamga Compatibility** - Phases 15-18 (shipped 2026-03-26)
- ✅ **v0.14 Build System** - Phases 19-21 (shipped 2026-03-27)
- ✅ **v0.15 Language Ergonomics** - Phases 22-24 (shipped 2026-03-27)
- 🚧 **v0.16 Bug Fixes** - Phases 25-28 (in progress)

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

- [x] Phase 22: `throw` Statement — error propagation with automatic type narrowing (2/2 plans)
- [x] Phase 23: Pattern Guards — conditional match arms with `(x if expr)` syntax (2/2 plans)
- [x] Phase 24: `#cimport` Unification — one directive per C library replaces four (2/2 plans)

See: [milestones/v0.15-ROADMAP.md](milestones/v0.15-ROADMAP.md)

</details>

### v0.16 Bug Fixes (In Progress)

**Milestone Goal:** Fix all known open bugs — zero known workarounds remaining after this milestone.

- [x] **Phase 25: Bridge Codegen Fixes** - `const &BridgeStruct`, error-union by-value, and `pub export fn` all emit correct Zig (completed 2026-03-28)
- [x] **Phase 26: Codegen Correctness & Parser** - cross-module `is` operator, `Async(T)` error, and negative literal parsing fixed (completed 2026-03-28)
- [x] **Phase 27: C Interop & Multi-Module Build** - multi-file sidecar conflict, cimport include paths, and linkSystemLibrary all resolved (completed 2026-03-28)
- [ ] **Phase 28: Cross-Compile, Cache & Docs** - cross-compilation step name fixed, `-fast` cache leak eliminated, TODO.md cleaned up

## Phase Details

### Phase 25: Bridge Codegen Fixes
**Goal**: Bridge function codegen emits correct Zig for all three known pointer/visibility bugs
**Depends on**: Phase 24 (previous milestone complete)
**Requirements**: CGN-01, CGN-02, CGN-03
**Success Criteria** (what must be TRUE):
  1. A `const &BridgeStruct` parameter generates `&arg` at the call site, not a by-value copy
  2. A bridge struct value parameter inside an error-union function stays by-value — no silent `*const` promotion
  3. A sidecar `export fn` generates `pub export fn` so the symbol is accessible from Orhon callers
  4. All 260 tests continue to pass with the corrected codegen
**Plans**: 1 plan
Plans:
- [x] 25-01-PLAN.md — Fix bridge codegen: const &, error-union params, pub export fn

### Phase 26: Codegen Correctness & Parser
**Goal**: Cross-module type checks emit correct Zig, `Async(T)` is rejected at compile time, and negative literals parse as arguments
**Depends on**: Phase 25
**Requirements**: CGN-04, CGN-05, PRS-01
**Success Criteria** (what must be TRUE):
  1. `ev is mod.Type` emits a tagged union check in Zig, not a `@TypeOf` comparison
  2. `Async(T)` in a type annotation produces a clear compile error instead of silently resolving to `void`
  3. `-0.5` and `-1` are accepted as function call arguments without a parse error
  4. All 260 tests continue to pass
**Plans**: 1 plan
Plans:
- [x] 26-01-PLAN.md — Fix unary negation, cross-module is operator, Async(T) error

### Phase 27: C Interop & Multi-Module Build
**Goal**: Multi-file modules with Zig sidecars, `#cimport` include paths, and system library linking all work without errors
**Depends on**: Phase 26
**Requirements**: BLD-01, BLD-02, BLD-03
**Success Criteria** (what must be TRUE):
  1. A multi-file module that includes a Zig sidecar compiles without a "file exists in two modules" error
  2. A `#cimport` bridge file resolves module-relative header paths correctly (no "file not found" at Zig compile time)
  3. `#cimport source:` generates a `linkSystemLibrary` call in the Zig build script for the owning module
  4. All 260 tests continue to pass
**Plans**: 1 plan
Plans:
- [x] 27-01-PLAN.md — Fix sidecar dedup, cimport include paths, and linkSystemLibrary for source:

### Phase 28: Cross-Compile, Cache & Docs
**Goal**: Cross-compilation targets pass valid step names to Zig, `-fast` builds stay clean, and TODO.md reflects current bug status
**Depends on**: Phase 27
**Requirements**: BLD-04, BLD-05, DOC-01, CLN-01
**Success Criteria** (what must be TRUE):
  1. `orhon build -win_x64` passes a valid step name to the Zig build system without garbling
  2. `orhon build -fast` does not leak any files into the project `bin/` directory
  3. TODO.md marks `cast_to_enum`, `null_multi_union`, `empty_struct`, and `size` keyword bugs as fixed
  4. `Async(T)` removed from grammar and codegen — no dead language constructs
  5. All 260 tests continue to pass
**Plans**: 2 plans
Plans:
- [ ] 28-01-PLAN.md — Fix cross-compilation target flag use-after-free and -fast cache leak
- [x] 28-02-PLAN.md — Remove Async(T) from codegen and update TODO.md

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-7 | v0.10 | All | Complete | 2026-03-24 |
| 8-11 | v0.11 | All | Complete | 2026-03-25 |
| 12-14 | v0.12 | All | Complete | 2026-03-25 |
| 15-18 | v0.13 | 5/5 | Complete | 2026-03-26 |
| 19-21 | v0.14 | 6/6 | Complete | 2026-03-27 |
| 22-24 | v0.15 | 6/6 | Complete | 2026-03-27 |
| 25. Bridge Codegen Fixes | v0.16 | 1/1 | Complete    | 2026-03-28 |
| 26. Codegen Correctness & Parser | v0.16 | 1/1 | Complete    | 2026-03-28 |
| 27. C Interop & Multi-Module Build | v0.16 | 1/1 | Complete    | 2026-03-28 |
| 28. Cross-Compile, Cache & Docs | v0.16 | 1/2 | In Progress|  |
