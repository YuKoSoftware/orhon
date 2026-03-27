# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- ✅ **v0.12 Quality & Polish** - Phases 12-14 (shipped 2026-03-25)
- ✅ **v0.13 Tamga Compatibility** - Phases 15-18 (shipped 2026-03-26)
- ✅ **v0.14 Build System** - Phases 19-21 (shipped 2026-03-27)
- 🚧 **v0.15 Language Ergonomics** - Phases 22-24 (in progress)

## Phases

<details>
<summary>✅ v0.10 Bug Fix & Cleanup (Phases 1-7) - SHIPPED 2026-03-24</summary>

### Phase 1: Cross-Module Codegen Fixes
**Goal**: Cross-module const argument passing and generic type validation work correctly
**Plans**: Complete

### Phase 2: Error Handling & Pointer Constructors
**Goal**: OOM errors propagate honestly and pointer constructors use method style
**Plans**: Complete

### Phase 3: LSP Memory & Security
**Goal**: LSP server handles memory and malformed input safely
**Plans**: Complete

### Phase 4-7: Earlier phases
**Plans**: Complete

</details>

<details>
<summary>✅ v0.11 Language Simplification (Phases 8-11) - SHIPPED 2026-03-25</summary>

### Phase 8: Const Auto-Borrow
**Goal**: Const non-primitive values auto-pass as `const &` at call sites
**Plans**: Complete

### Phase 9: Ptr Syntax Simplification
**Goal**: Type annotation + `&` replaces verbose `.cast()` syntax
**Plans**: Complete

### Phase 10: Tamga Compatibility Update
**Goal**: Tamga companion project updated for v0.11 syntax changes
**Plans**: Complete

### Phase 11: Full Test Suite Gate
**Goal**: All 240 tests pass across 11 stages
**Plans**: Complete

</details>

<details>
<summary>✅ v0.12 Quality & Polish (Phases 12-14) - SHIPPED 2026-03-25</summary>

### Phase 12: Fuzz Testing
**Goal**: The lexer and parser are covered by fuzz targets that run without crashes on random input
**Plans**: 1/1 complete

### Phase 13: Bug Fixes
**Goal**: Tester module compiles end-to-end and unit tests pass reliably on every run
**Plans**: 1/1 complete

### Phase 14: Gate
**Goal**: The full test suite passes cleanly — zero failures across all 11 stages
**Plans**: Complete (pass-through)

</details>

<details>
<summary>✅ v0.13 Tamga Compatibility (Phases 15-18) - SHIPPED 2026-03-26</summary>

### Phase 15: Enum Explicit Values
**Goal**: Typed enums support explicit integer value assignments per variant (e.g., `A = 4`)
**Plans**: 2/2 complete

### Phase 16: `is` Operator Qualified Types
**Goal**: The `is` operator works with cross-module types — both `mod.Type` and unqualified forms
**Plans**: 1/1 complete

### Phase 17: Void in Error Unions
**Goal**: `void` accepted in error union position — `(Error | void)` compiles to `anyerror!void`
**Plans**: 1/1 complete

### Phase 18: Type Alias Syntax
**Goal**: `const Alias: type = T` declarations supported, generating Zig `const Alias = Type`
**Plans**: 1/1 complete

</details>

<details>
<summary>✅ v0.14 Build System (Phases 19-21) - SHIPPED 2026-03-27</summary>

- [x] Phase 19: Bridge Modules as Named Zig Modules (1/1 plans)
- [x] Phase 20: Tamga Build Verification (3/3 plans)
- [x] Phase 21: Flexible Allocators (2/2 plans)

See: [milestones/v0.14-ROADMAP.md](milestones/v0.14-ROADMAP.md)

</details>

### 🚧 v0.15 Language Ergonomics (In Progress)

**Milestone Goal:** Reduce boilerplate and clean up C interop directives — make Orhon code more concise and the bridge system simpler.

- [x] **Phase 22: `throw` Statement** - Error propagation with automatic type narrowing (completed 2026-03-27)
- [x] **Phase 23: Pattern Guards** - Conditional match arms with `case x if expr` syntax (completed 2026-03-27)
- [ ] **Phase 24: `#cimport` Unification** - One directive per C library replaces four separate ones

## Phase Details

### Phase 22: `throw` Statement
**Goal**: Orhon programs can use `throw x` to propagate errors and automatically narrow the type of `x` to its value type
**Depends on**: Phase 21 (previous milestone complete)
**Requirements**: ERR-01, ERR-02, ERR-03, ERR-04
**Success Criteria** (what must be TRUE):
  1. `throw x` in a function returning `(Error | T)` returns early with the error and `x` narrows to type `T` after the statement
  2. Code following `throw x` can use `x` directly as type `T` without `.value` unwrapping
  3. Using `throw` in a function that returns a non-error type produces a compile error with a clear message
  4. The example module demonstrates `throw` usage and compiles successfully
**Plans**: 2 plans
Plans:
- [x] 22-01-PLAN.md -- Implement throw across compiler pipeline (lexer, PEG, builder, propagation, MIR, codegen)
- [x] 22-02-PLAN.md -- Tests, example module, and docs for throw

### Phase 23: Pattern Guards
**Goal**: Match arms accept an optional `if` guard expression so arms only fire when both the pattern and the guard are true
**Depends on**: Phase 22
**Requirements**: GUARD-01, GUARD-02, GUARD-03
**Success Criteria** (what must be TRUE):
  1. A match arm written as `(x if x > 0)` only executes when the pattern matches and the guard evaluates to true
  2. The guard expression can reference the bound variable and variables from the enclosing scope
  3. The example module demonstrates pattern guards and compiles successfully
**Plans**: 2 plans
Plans:
- [x] 23-01-PLAN.md -- Implement guards across compiler pipeline (grammar, builder, AST, resolver, MIR, codegen)
- [x] 23-02-PLAN.md -- Documentation update for pattern guards

### Phase 24: `#cimport` Unification
**Goal**: A single `#cimport "lib"` directive replaces the four separate `#linkC`, `#cInclude`, `#csource`, and `#linkCpp` directives, and the Tamga framework is migrated to use it
**Depends on**: Phase 23
**Requirements**: CIMP-01, CIMP-02, CIMP-03, CIMP-04, CIMP-05, CIMP-06
**Success Criteria** (what must be TRUE):
  1. `#cimport "lib"` compiles a bridge that links the named C library with no additional directives needed
  2. The optional block form `#cimport "lib" { include: "...", source: "..." }` overrides include path and source file as needed
  3. Using `#cimport` for the same library twice in the same project produces a compile error
  4. The old `#linkC`, `#cInclude`, `#csource`, `#linkCpp` directives are removed or emit a clear deprecation error
  5. The Tamga framework builds successfully using `#cimport` with zero legacy directives remaining
**Plans**: 2 plans
Plans:
- [ ] 24-01-PLAN.md — Implement #cimport across compiler pipeline (grammar, parser, builder, declarations, main.zig, zig_runner, tests)
- [ ] 24-02-PLAN.md — Tamga migration, documentation update, and human verification

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-7 | v0.10 | All | Complete | 2026-03-24 |
| 8-11 | v0.11 | All | Complete | 2026-03-25 |
| 12-14 | v0.12 | All | Complete | 2026-03-25 |
| 15-18 | v0.13 | 5/5 | Complete | 2026-03-26 |
| 19-21 | v0.14 | 6/6 | Complete | 2026-03-27 |
| 22. `throw` Statement | v0.15 | 2/2 | Complete    | 2026-03-27 |
| 23. Pattern Guards | v0.15 | 2/2 | Complete    | 2026-03-27 |
| 24. `#cimport` Unification | v0.15 | 0/? | Not started | - |
