# Orhon Compiler

## What This Is

Orhon is a compiled, memory-safe programming language that transpiles to Zig. Written in Zig 0.15.x, it targets developers who want Rust-level safety with Zig-level simplicity. The compiler implements a 12-pass pipeline from source to native binary, with ownership tracking, borrow checking, thread safety analysis, and incremental compilation. Currently at v0.16.

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
- ✓ Tamga build verification — 9 compiler bugs fixed (null union, elif, enumFromInt, zero-field struct, bridge borrow, shared cImport, #csource) — v0.14 Phase 20
- ✓ Bridge .zig files as named Zig modules (createModule/addImport) — v0.14 Phase 19
- ✓ Flexible allocators — .new(alloc) with 3 modes (default SMP, inline, external) — v0.14 Phase 21
- ✓ String interpolation uses SMP allocator — v0.14 Phase 21
- ✓ `throw` statement for error propagation (propagate + type narrowing) — v0.15 Phase 22
- ✓ Pattern guards in match (`(x if x > 0)` parenthesized guard syntax) — v0.15 Phase 23
- ✓ `#cimport` unified C import directive (`#cimport = { name: "...", include: "..." }`) — v0.15 Phase 24
- ✓ Bridge `const &` pointer pass, error-union value params, sidecar `pub export fn` — v0.16 Phase 25
- ✓ Cross-module `is` tagged union check, Async(T) compile error, negative literal parsing — v0.16 Phase 26
- ✓ Build system: sidecar pub-fixup loop, cimport include paths, linkSystemLibrary — v0.16 Phase 27
- ✓ Cross-compilation target fix, -fast cache cleanup, Async(T) removal, TODO.md cleanup — v0.16 Phase 28

### Active

(No active milestone — planning next)

## Current State

**Version:** v0.16 (shipped 2026-03-28)
**Tests:** 262 across 11 stages
**Milestones shipped:** v0.10, v0.11, v0.12, v0.13, v0.14, v0.15, v0.16

v0.16 Bug Fixes complete — all 13 known bugs fixed across codegen, parser, and build system. Zero known workarounds remaining. Tamga framework builds clean. 262 tests pass.

### Out of Scope

- Zig IR layer architecture refactor — deferred (large scope, separate concern)
- Dependency-parallel module compilation — deferred (optimization, not correctness)
- MIR optimization and caching (SSA, inlining, DCE) — deferred (optimization)
- MIR residual AST accesses — architectural cleanup deferred
- PEG syntax doc generator — deferred

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
| Named bridge modules via build system | createModule/addImport eliminates file-path imports and duplicate module errors | ✓ v0.14 Phase 19 — cross-bridge imports work |
| Shared cImport wrapper modules | Derive module name from header stem + _c suffix | ✓ v0.14 Phase 20 — predictable, no extra metadata |
| struct_methods qualified keys | 'StructName.method' keys avoid cross-bridge method name collisions | ✓ v0.14 Phase 20 — clean collision avoidance |
| `throw` not `try` for error propagation | Less noisy, less hidden control flow than try-prefix | ✓ v0.15 Phase 22 — clean statement form |
| Parenthesized guard syntax `(x if expr)` | Parens contain the compound construct, consistent with syntax containment rule | ✓ v0.15 Phase 23 — clean, explicit |
| `#cimport = { name, include, source }` syntax | Consistent with `#key = value` metadata pattern | ✓ v0.15 Phase 24 — visual consistency |
| Hard remove of old C directives | Only consumer is Tamga (controlled), no deprecation period needed | ✓ v0.15 Phase 24 — clean break |
| `is_bridge` flag on FuncSig | Prevents incorrect const auto-borrow on bridge calls | ✓ v0.16 Phase 25 — clean bridge/non-bridge separation |
| Sidecar pub fixup via read-modify-write | Prepend `pub ` to export fn when missing, scanner advances past needle | ✓ v0.16 Phase 25 — no infinite loop |
| Remove Async(T) entirely | Dead language construct, never implemented — clean removal over deprecation | ✓ v0.16 Phase 28 — no dead code |

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
*Last updated: 2026-03-28 after v0.16 Bug Fixes milestone shipped*
