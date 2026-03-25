# Orhon Compiler

## What This Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig. Written in Zig 0.15.x, it targets developers who want Rust-level safety with Zig-level simplicity. The compiler implements a 12-pass pipeline from source to native binary, with ownership tracking, borrow checking, thread safety analysis, and incremental compilation. Currently at v0.11.0.

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
- ✓ Const auto-borrow — `const` non-primitives auto-pass as `const &` at call sites — v0.11 Phase 8
- ✓ Ptr syntax simplification — type annotation + `&` replaces `.cast()` — v0.11 Phase 9
- ✓ Tamga companion project updated for v0.11 syntax changes — v0.11 Phase 10
- ✓ Full test suite gate 240/240 — v0.11 Phase 11

### Active

(Next milestone requirements will be defined via `/gsd:new-milestone`)

### Out of Scope

- Zig IR layer architecture refactor — deferred (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- MIR residual AST accesses — architectural cleanup deferred
- PEG syntax doc generator — deferred
- New language features beyond the two simplifications — this milestone is focused

## Current Milestone: Planning next

**Previous:** v0.11 Language Simplification — shipped 2026-03-25

## Context

v0.11 shipped two breaking semantic changes: const auto-borrow (const values auto-pass as `const &` at call sites, eliminating silent deep copies) and ptr syntax simplification (type annotation + `&` replaces verbose `.cast()` syntax). All fixtures, Tamga companion project, and docs updated. 240/240 tests pass. 35 files changed, 2812 insertions, 256 deletions.

## Constraints

- **Language**: Zig 0.15.2+ — all compiler code is Zig, targets Codeberg for references
- **Architecture**: No runtime libraries — all stdlib through bridge modules, native Zig types only
- **Testing**: `./testall.sh` is the gate — 11 test stages must pass
- **Quality**: No hacky workarounds — clean fixes only
- **Compatibility**: Changes must not break existing `.orh` programs or the example module

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Fix bugs before architecture work | Correctness before performance/elegance | ✓ Good — all bugs fixed by v0.10 |
| Scope to TODO.md bugs only | Clear boundary, avoid scope creep | ✓ Good — kept milestones focused |
| Clean up stdlib error handling | 103 catch {} is a safety hazard for a "safe" language compiler | ✓ Phase 2 — Category A documented, Category B fixed |
| Const auto-borrow via MIR annotation | Re-derive const-ness from AST, avoid coupling to ownership checker | ✓ v0.11 Phase 8 — clean separation |
| Type-directed pointer coercion | Type annotation carries safety level, no need for `.cast()` syntax | ✓ v0.11 Phase 9 — simpler language surface |
| Breaking changes before wider adoption | No known external users, clean slate opportunity | ✓ v0.11 — both changes landed cleanly |

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
*Last updated: 2026-03-25 after v0.11 milestone archived*
