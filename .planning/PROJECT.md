# Orhon Compiler

## What This Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig. Written in Zig 0.15.x, it targets developers who want Rust-level safety with Zig-level simplicity. The compiler implements a 12-pass pipeline from source to native binary, with ownership tracking, borrow checking, thread safety analysis, and incremental compilation. Currently at v0.9.7.

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

### Active

- [ ] Fix all 9 known bugs in docs/TODO.md (4/9 complete after Phase 1)
- [ ] Improve code quality and remove workarounds
- [ ] Ensure testall.sh passes cleanly after all changes

### Out of Scope

- Zig IR layer architecture refactor — deferred to next milestone (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- New language features — this milestone is stabilization only
- Tamga companion project bugs — not pulling from external bug lists
- v1.0 release — this milestone prepares for it but doesn't ship it

## Context

The compiler has been through rapid development from v0.9.3 to v0.9.7, including a PEG parser migration, MIR self-containment, runtime library removal, and native type adoption. This velocity left behind bugs and code quality debt that need addressing before the next wave of architecture work.

Key areas of concern from codebase analysis:
- `src/codegen.zig` (3720 lines) — monolithic, has `catch unreachable` patterns
- Stdlib bridge modules — 103 instances of `catch {}` suppressing real errors
- Cross-module codegen bugs (struct ref-passing, qualified generics)
- Ownership checker incorrectly treats const values as moved
- Test runner (`orhon test`) reports 0 passed/failed instead of running
- String interpolation allocates temp buffers that are never freed

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
*Last updated: 2026-03-24 after Phase 2 completion*
