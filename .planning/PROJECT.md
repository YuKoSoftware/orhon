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

- [x] Const auto-borrow — `const` values pass as `const &` instead of implicit copy — Phase 8
- [x] Ptr syntax simplification — remove `.cast()` and `Ptr(T, &x)`, use type annotation + `&` — Phase 9
- [ ] Update Tamga companion project for new Ptr syntax
- [ ] Ensure testall.sh passes all 11 stages after changes

### Out of Scope

- Zig IR layer architecture refactor — deferred (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- MIR residual AST accesses — architectural cleanup deferred
- PEG syntax doc generator — deferred
- New language features beyond the two simplifications — this milestone is focused

## Current Milestone: v0.11 Language Simplification

**Goal:** Simplify language semantics with two breaking changes before wider adoption.

**Target features:**
- Const auto-borrow — `const` values auto-pass as `const &` instead of implicit copy
- Ptr syntax simplification — remove `.cast()` and `Ptr(T, &x)`, use `const p: Ptr(T) = &x`
- Update Tamga companion project for new Ptr syntax

## Context

v0.10 achieved a clean test suite (236/236 pass) and fixed all known bugs. Two design decisions were made during v0.10 review that change language semantics:

1. **Const auto-borrow:** The current `is_const` flag in ownership.zig skips move marking, making all const non-primitive values implicitly copyable with no size limit. This was a quick fix for BUG-03 but creates hidden performance traps — a 4KB const struct silently copies on every by-value pass. The fix: auto-borrow const values as `const &` instead of copying. Affects `src/ownership.zig`, `src/codegen.zig`, `src/mir.zig`.

2. **Ptr syntax simplification:** `Ptr(i32).cast(&x)` is verbose — the type already carries the safety level. New syntax: `const p: Ptr(T) = &x`. Remove `ptr_cast_expr` and `ptr_expr` PEG rules. Pointer construction becomes type-directed coercion in codegen. Affects `src/orhon.peg`, `src/peg/builder.zig`, `src/codegen.zig`, `src/mir.zig`, example module, tester fixtures, docs.

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
*Last updated: 2026-03-25 after Phase 9 completion*
