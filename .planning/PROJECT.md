# Orhon Compiler

## What This Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig. Written in Zig 0.15.x, it targets developers who want Rust-level safety with Zig-level simplicity. The compiler implements a 12-pass pipeline from source to native binary, with ownership tracking, borrow checking, thread safety analysis, and incremental compilation. Currently at v0.10.2.

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
- ✓ Cross-module const & argument passing in codegen — v0.10 Phase 1
- ✓ Qualified generic type validation across modules — v0.10 Phase 1
- ✓ Const struct by-value passing without false move errors — v0.10 Phase 1
- ✓ Working `orhon test` command with correct output — v0.10 Phase 1
- ✓ String interpolation temp buffer cleanup via MIR defer injection — v0.10 Phase 2
- ✓ OOM error propagation in codegen (no more `catch unreachable` on allocPrint) — v0.10 Phase 2
- ✓ Stdlib `catch {}` sweep: 103 instances classified and fixed/documented — v0.10 Phase 2
- ✓ `Ptr(T).cast(addr)` method-style pointer constructors — v0.10 Phase 2
- ✓ LSP per-request arena memory (no unbounded growth) — v0.10 Phase 3
- ✓ LSP header buffer hardening (4096 bytes, truncation detection) — v0.10 Phase 3
- ✓ LSP content-length guard (64 MiB cap, rejects oversized payloads) — v0.10 Phase 3
- ✓ Const auto-borrow — `const` non-primitives auto-pass as `const &` at call sites — v0.11 Phase 8
- ✓ Ptr syntax simplification — type annotation + `&` replaces `.cast()` — v0.11 Phase 9
- ✓ Tamga companion project updated for v0.11 syntax changes — v0.11 Phase 10
- ✓ Full test suite gate 240/240 — v0.11 Phase 11
- ✓ Fuzz testing for lexer and parser — v0.12 Phase 12
- ✓ Tester module cross-module codegen fix — v0.12 Phase 13
- ✓ Intermittent unit test failure fix — v0.12 Phase 13
- ✓ Enum variants with explicit integer values (`A = 4` in typed enums) — v0.13 Phase 15
- ✓ `is` operator with module-qualified types (`ev is mod.Type`) — v0.13 Phase 16
- ✓ `void` accepted in error unions (`Error | void`) — v0.13 Phase 17
- ✓ `const Alias: type = T` type alias syntax — v0.13 Phase 18

### Active

(No active requirements — planning next milestone)

### Out of Scope

- Zig IR layer architecture refactor — deferred (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- MIR residual AST accesses — architectural cleanup deferred
- PEG syntax doc generator — deferred

## Current State

**Version:** v0.10.5
**Tests:** 253 across 11 stages
**Milestones shipped:** v0.10, v0.11, v0.12, v0.13

Phase 21 complete — Flexible allocators: collections accept optional allocator via `.new(alloc)`, three usage modes (default SMP, inline, external variable), default changed from page_allocator to SMP. Bridge `.allocator()` methods declared. 3 compiler fixes shipped (scoped type builder, qualified name resolver, transitive bridge wiring).

**Previous:** v0.13 Tamga Compatibility — shipped 2026-03-26

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
| `const Alias: type = T` for type aliases | Reuse existing const declaration, not new `pub type` keyword | ✓ v0.13 Phase 18 — consistent with `name: Type = value` pattern |
| Transparent (structural) type aliases | Speed == i32, not a distinct nominal type | ✓ v0.13 Phase 18 — simple, no special type comparisons needed |
| Allocator via .new(alloc), not generic param | Keeps generics pure (types only), allocator is runtime struct field | ✓ v0.14 Phase 21 — clean, Zig-idiomatic |
| SMP as default allocator, not page_allocator | SMP (GeneralPurposeAllocator) optimized for general use | ✓ v0.14 Phase 21 — correct default |

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
*Last updated: 2026-03-26 after Phase 21 (Flexible Allocators)*
