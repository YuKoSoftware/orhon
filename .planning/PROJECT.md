# Orhon Compiler

## What This Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig. Written in Zig 0.15.x, it targets developers who want Rust-level safety with Zig-level simplicity. The compiler implements a 12-pass pipeline from source to native binary, with ownership tracking, borrow checking, thread safety analysis, and incremental compilation. Currently at v0.10.0.

## Core Value

A clean, correct compiler with zero workarounds — every bug fixed, every error propagated, every code path honest.

## Requirements

### Validated

- ✓ 12-pass compilation pipeline (lexer → PEG parser → module resolution → declarations → type resolution → ownership → borrowing → thread safety → error propagation → MIR → codegen → Zig compiler) — existing
- ✓ PEG grammar-driven parser with error recovery — existing (v0.9.3)
- ✓ Ownership and move semantics with compile-time checking — existing
- ✓ Borrow checker (immutable many / mutable one) — existing
- ✓ Thread safety analysis — existing
- ✓ Error propagation analysis — existing
- ✓ MIR self-contained annotation and lowering — existing (v0.9.4–v0.9.7)
- ✓ Pure 1:1 Zig codegen with no runtime libraries — existing (v0.9.6–v0.9.7)
- ✓ Native error/null types (anyerror!T, ?T) — existing (v0.9.7)
- ✓ Incremental compilation with caching — existing
- ✓ Bridge system for Zig interop — existing
- ✓ CLI: build, run, test, init, debug, fmt — existing
- ✓ Cross-compilation support — existing
- ✓ Example module (living language manual) — existing
- ✓ Stdlib bridge modules (collections, strings, allocators, I/O, etc.) — existing
- ✓ LSP language server — existing
- ✓ Fuzz testing harness — existing
- ✓ Cross-module const & argument passing in codegen — Phase 1
- ✓ Qualified generic type validation across modules — Phase 1
- ✓ Const struct by-value passing without false move errors — Phase 1
- ✓ Working `orhon test` command with correct output — Phase 1
- ✓ String interpolation temp buffer cleanup via MIR defer injection — Phase 2
- ✓ OOM error propagation in codegen (no more `catch unreachable` on allocPrint) — Phase 2
- ✓ Stdlib `catch {}` sweep: 103 instances classified and fixed/documented — Phase 2
- ✓ `Ptr(T).cast(addr)` method-style pointer constructors — Phase 2
- ✓ LSP per-request arena memory (no unbounded growth) — Phase 3
- ✓ LSP header buffer hardening (4096 bytes, truncation detection) — Phase 3
- ✓ LSP content-length guard (64 MiB cap, rejects oversized payloads) — Phase 3

### Active

- [x] Fix tester module codegen — stages 09+10 (100 tests) must pass — Phase 4
- [x] Fix cross-module struct ref-passing (BUG-01) — Phase 4
- [x] Fix qualified generic type validation (BUG-02) — Phase 4
- [x] Sweep remaining `catch unreachable` in codegen.zig — Phase 5 (4 compiler-side replaced with @panic)
- [x] Sweep remaining `catch {}` in stdlib sidecars — Phase 5 (data-loss sites fixed, fire-and-forget I/O retained)
- [x] Align version numbers to v0.10.0 — Phase 6
- [x] Complete example module with missing language features — Phase 6
- [x] Fix string interpolation memory leak (BUG-05) — Phase 6 (defer-free pattern)
- [ ] Ensure testall.sh passes all 11 stages cleanly

### Out of Scope

- Zig IR layer architecture refactor — deferred (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- New language features — this milestone is stabilization and completeness only
- Tamga companion project modifications — read-only reference
- MIR residual AST accesses — architectural cleanup deferred
- PEG syntax doc generator — deferred

## Current Milestone: v0.10 Test Suite & Code Quality

**Goal:** Fix the 100 failing runtime tests, sweep remaining error suppression, and bring the example module + version numbers up to date.

**Target features:**
- Fix tester module codegen failure (stages 09 + 10)
- Fix cross-module struct ref-passing and qualified generic validation
- Sweep remaining `catch unreachable` (15) and `catch {}` (28)
- Align version numbers
- Complete example module coverage
- Fix string interpolation memory leak

## Context

The v0.9 milestone addressed the worst bugs (ownership const-as-move, `orhon test`, 103 stdlib `catch {}`, LSP hardening) but left the test suite partially broken — stages 09 (language) and 10 (runtime) fail with 100 tests blocked. Root cause is cross-module codegen generating invalid Zig (`type 'i32' has no members`). Additionally, 15 `catch unreachable` remain in codegen and 28 `catch {}` persist in 6 stdlib sidecars (collections, console, tui, fs, stream, system).

Key areas of concern:
- `src/codegen.zig` (3738 lines) — 15 remaining `catch unreachable`, cross-module field access bugs
- Stdlib sidecars — 28 remaining `catch {}` across 6 files
- Version drift — build.zig=0.9.3, build.zig.zon=0.8.3, PROJECT.md=v0.9.7
- Example module missing: RawPtr/VolatilePtr, #bitsize, any generics, typeOf(), include vs import
- String interpolation temp buffers never freed (BUG-05)

## Constraints

- **Language**: Zig 0.15.2+ — all compiler code is Zig, targets Codeberg for references
- **Architecture**: No runtime libraries — all stdlib through bridge modules, native Zig types only
- **Testing**: `./testall.sh` is the gate — 11 test stages must pass
- **Quality**: No hacky workarounds — clean fixes only
- **Compatibility**: Changes must not break existing `.orh` programs or the example module

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Fix bugs before architecture work | Correctness before performance/elegance | — Pending |
| Scope to TODO.md bugs only | Clear boundary, avoid scope creep | — Pending |
| Clean up stdlib error handling | 103 catch {} is a safety hazard for a "safe" language compiler | ✓ Phase 2 — Category A documented, Category B fixed |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd:transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd:complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-03-25 after Phase 6 completion*
