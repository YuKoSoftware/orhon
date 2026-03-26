# Roadmap: Orhon Compiler

## Milestones

- ✅ **v0.10 Bug Fix & Cleanup** - Phases 1-7 (shipped 2026-03-24)
- ✅ **v0.11 Language Simplification** - Phases 8-11 (shipped 2026-03-25)
- ✅ **v0.12 Quality & Polish** - Phases 12-14 (shipped 2026-03-25)
- ✅ **v0.13 Tamga Compatibility** - Phases 15-18 (shipped 2026-03-26)
- **v0.14 Build System** - Phases 19-20

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

### Phase 19: Bridge Modules as Named Zig Modules
**Goal**: Bridge .zig files compile as named Zig modules in the build graph — eliminating file-path @import and cross-module "file exists in two modules" errors
**Requirements**: [REQ-19]
**Plans:** 1/1 plans complete
Plans:
- [x] 19-01-PLAN.md — Named bridge modules in build.zig + codegen import fix

### Phase 20: Tamga Build Verification
**Goal**: Tamga framework builds end-to-end with the new bridge module system — no workarounds needed
**Requirements**: [REQ-20]
**Plans**: Not started

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-7 | v0.10 | All | Complete | 2026-03-24 |
| 8-11 | v0.11 | All | Complete | 2026-03-25 |
| 12-14 | v0.12 | All | Complete | 2026-03-25 |
| 15-18 | v0.13 | 5/5 | Complete | 2026-03-26 |
| 19-21 | v0.14 | 1/3 | In Progress | — |

### Phase 21: Flexible Allocators
**Goal**: Collections accept optional allocator parameter — 3 modes: default SMP, inline instantiation, external variable. Users can build custom allocators via bridge. Default allocator changed from page_allocator to SMP.
**Requirements**: [ALLOC-01, ALLOC-02, ALLOC-03, ALLOC-04, ALLOC-05, ALLOC-06, ALLOC-07]
**Depends on:** Phase 20
**Plans:** 2/2 plans complete

Plans:
- [x] 21-01-PLAN.md — SMP default + codegen .new(alloc) + string interpolation + runtime tests
- [x] 21-02-PLAN.md — Documentation and example module updates
