---
phase: 20-tamga-build-verification
plan: "01"
subsystem: codegen, mir, declarations, resolver
tags: [bug-fix, codegen, bridge-structs, elif, null-union, coercion]
dependency_graph:
  requires: []
  provides: [bridge-const-ref-coercion, elif-codegen, multi-null-union-fix]
  affects: [src/codegen.zig, src/mir.zig, src/declarations.zig, src/resolver.zig, src/peg/builder.zig]
tech_stack:
  added: []
  patterns: [struct_methods-qualified-keys, param-offset-for-self, resolver-struct-method-return-type]
key_files:
  created:
    - test/fixtures/multi_null_union.orh
    - test/fixtures/bridge_size_param.orh
  modified:
    - src/peg/builder.zig
    - src/codegen.zig
    - src/mir.zig
    - src/declarations.zig
    - src/resolver.zig
decisions:
  - "struct_methods map uses qualified 'StructName.method' keys to avoid collisions across bridge structs with same method names"
  - "param_offset skips 'self' param when matching call args to bridge method signature"
  - "resolver updated to resolve bridge static/instance method return types via struct_methods"
metrics:
  duration: "~3h"
  completed: "2026-03-27"
  tasks: 3
  files_modified: 5
---

# Phase 20 Plan 01: Tamga Compiler Bug Fixes Summary

**One-liner:** Fixed elif codegen (PEG builder gap), multi-null union null return, and bridge struct const & param coercion with struct_methods qualified-key registry.

## Completed Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Fix codegen bugs 1, 2, 3 + elif | e257a74 | peg/builder.zig, codegen.zig, mir.zig |
| 2 | Fix MIR bug 6 (bridge const & params) | a15c661 | declarations.zig, mir.zig, resolver.zig |
| 3 | Full regression test suite | — | testall.sh: 253/253 passed |

## Bugs Fixed

### Bug 1 — Multi-type null union `(null | A | B)` codegen
`return null` inside a `(null | A | B)` function was emitting `.{ ._null = null }` instead of plain `null`.

**Root cause:** `detectCoercion` in `mir.zig` applied `arbitrary_union_wrap` to `null_type` when the destination was a `union_type` containing null. The coercion was needed for non-null members but not for null itself (since `?(union(enum){...})` accepts `null` natively in Zig).

**Fix:** Added null exclusion check in `detectCoercion` — when `src == .null_type` and the destination union contains a null member, return no coercion.

### Bug 2 — `cast(EnumType, int)` generates `@intCast` instead of `@enumFromInt`
Already fixed in the codebase before this plan. Verified at codegen lines 3710-3714.

### Bug 3 — Empty struct `TypeName()` generates `TypeName()` instead of `TypeName{}`
Already fixed in the codebase before this plan. Verified at codegen lines 1923-1934.

### Bug 4 — elif/else if codegen generated `flag; 2;` instead of `else if (...)`
**Root cause:** `elif_chain` PEG rule had no handler in `peg/builder.zig`. It fell through to the transparent rule path which recursed into the first child (the `elif` keyword token), producing an identifier node with text "elif". The resulting AST was malformed — codegen emitted the elif keyword as an expression statement.

**Fix:** Added `buildElifChain` function that correctly builds `if_stmt` AST nodes for elif branches, with proper condition/then/else structure.

Additionally fixed the `if_stmt` codegen in `codegen.zig`: when `else_m.kind == .if_stmt`, call `generateStatementMir` instead of `generateBlockMir` to avoid wrapping elif in extra `{}` braces.

### Bug 5 — `size` keyword not allowed in bridge func parameters
Already fixed in `orhon.peg` (`param_name` rule at line 118 includes `'size'`). Verified via `test/fixtures/bridge_size_param.orh`.

### Bug 6 — `const &BridgeStruct` parameter passes by value instead of by pointer
`r.draw(m)` was generating `r.draw(m)` instead of `r.draw(&m)` when `draw` expects `const &Mesh`.

**Root cause:** Three layered issues:
1. Bridge struct methods were registered in `decls.funcs` by name, causing collisions when multiple bridge structs had methods with the same name. This led to error reporting that masked the actual registration.
2. `resolveCallSig` in `mir.zig` had no logic to look up bridge method signatures via qualified keys.
3. `annotateCallCoercions` matched call args against sig params without accounting for the implicit `self` parameter at index 0 in bridge method signatures.
4. The resolver couldn't resolve the return type of bridge method calls (`Renderer.create()` returned `inferred`), so `r`'s type was `inferred` instead of `named("Renderer")`, preventing the struct_methods lookup from working.

**Fix:**
- Added `struct_methods: std.StringHashMapUnmanaged(FuncSig)` to `DeclTable` in `declarations.zig`
- Registered bridge struct methods as `"StructName.method"` qualified keys (avoids name collisions)
- Updated `resolveCallSig` in `mir.zig` to look up `struct_methods` for instance method calls
- Added `param_offset` in `annotateCallCoercions` to skip `self` param when matching args
- Updated resolver's `call_expr` handling to resolve bridge method return types via `struct_methods`, fixing the `inferred` type problem for `r` after `var r = Renderer.create()`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] elif codegen was completely broken**
- **Found during:** Task 1 (Bug 1 investigation)
- **Issue:** elif chains produced malformed output — the keyword token itself was being emitted as an expression
- **Fix:** Added `buildElifChain` to `peg/builder.zig`, fixed `if_stmt` codegen in `codegen.zig`
- **Files modified:** `src/peg/builder.zig`, `src/codegen.zig`
- **Commit:** e257a74

**2. [Rule 1 - Bug] resolver returns `inferred` for bridge method call return types**
- **Found during:** Task 2 (debugging why `r.draw(m)` still generated without `&`)
- **Issue:** `var r = Renderer.create()` resolved `r`'s type as `.inferred` because the resolver's `call_expr` handler only checked `decls.funcs` for field_expr calls, not `struct_methods`. Without knowing `r`'s type is `Renderer`, MIR couldn't look up `Renderer.draw` in `struct_methods`.
- **Fix:** Updated resolver's `call_expr` to check `struct_methods` using `"StructName.method"` keys
- **Files modified:** `src/resolver.zig`
- **Commit:** a15c661

## Known Stubs

None — all fixes are fully wired.

## Self-Check: PASSED

Files created/verified:
- `test/fixtures/multi_null_union.orh` — exists
- `test/fixtures/bridge_size_param.orh` — exists

Commits verified:
- `e257a74` — exists (Task 1)
- `a15c661` — exists (Task 2)

Test suite: 253/253 passed
