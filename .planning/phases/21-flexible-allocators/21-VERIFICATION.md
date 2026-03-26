---
phase: 21-flexible-allocators
verified: 2026-03-26T00:00:00Z
status: passed
score: 6/6 must-haves verified
---

# Phase 21: Flexible Allocators Verification Report

**Phase Goal:** Collections accept optional allocator parameter — 3 modes: default SMP, inline instantiation, external variable. Users can build custom allocators via bridge. Default allocator changed from page_allocator to SMP.
**Verified:** 2026-03-26
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `List/Map/Set.new()` with no args uses SMP allocator instead of page_allocator | VERIFIED | `collections.zig:10` — `var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};` replaces old `const default_alloc = std.heap.page_allocator`; `page_allocator` absent from collections.zig entirely |
| 2 | `.new(alloc_expr)` with one arg emits `.{ .alloc = alloc_expr }` in generated Zig | VERIFIED | `codegen.zig:1851` (AST path) and `codegen.zig:2325` (MIR path) both emit `.{ .alloc = ` when `c.args.len == 1` and the object is a type node |
| 3 | String interpolation temp buffers use `std.heap.smp_allocator` in generated Zig | VERIFIED | `codegen.zig:1566, 2802, 2854, 3225, 3292, 3340` — all use `smp_allocator`; only the three thread-handle lines (~332, ~764, ~1014) retain `page_allocator` as out-of-scope per plan |
| 4 | User struct `.new(arg)` is NOT affected — only collection type nodes get the `.alloc` treatment | VERIFIED | AST path checks `is_type_node` (collection_expr, type_primitive, type_named, type_generic); MIR path checks `obj_mir.kind == .type_expr or .collection` — struct identifier nodes do not match |
| 5 | docs/09-memory.md documents all three allocator modes with code examples | VERIFIED | `docs/09-memory.md:216` — `## Allocators` section with Mode 1 (default SMP), Mode 2 (inline), Mode 3 (external variable), available allocators table, custom allocator note |
| 6 | Example module shows allocator usage that compiles | VERIFIED | `example.orh:9` — `import std::allocator`; `example.orh:13` — `include std::collections`; `example.orh:62` — `pub func allocator_demo()` with all three modes; full test suite (253 tests) passes |

**Score:** 6/6 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/std/collections.zig` | Global SMP singleton as default allocator for all collection types | VERIFIED | Line 10: `var _default_smp: std.heap.GeneralPurposeAllocator(.{}) = .{};`; all three structs (List, Map, Set) have `alloc: std.mem.Allocator = _default_smp.allocator()` at lines 17, 67, 122; no `page_allocator` present |
| `src/codegen.zig` | 1-arg .new() codegen path and smp_allocator for string interpolation | VERIFIED | AST path (lines 1842-1858) and MIR path (lines 2317-2333) both handle 0-arg and 1-arg .new(); string interpolation uses smp_allocator at 6 locations |
| `src/std/allocator.orh` | bridge func allocator() declarations for SMP, Arena, Page | VERIFIED | Lines 11, 19, 28: `bridge func allocator(self: &SMP) void`, `bridge func allocator(self: &Arena) void`, `bridge func allocator(self: &Page) void` |
| `test/fixtures/tester.orh` | Runtime test functions for allocator modes 2 and 3 | VERIFIED | `import std::allocator` at line 10; `test_alloc_arena()` at line 975; `test_alloc_external()` at line 986; both use `List(i32).new(alloc)` |
| `test/fixtures/tester_main.orh` | PASS/FAIL assertions for alloc_arena and alloc_external | VERIFIED | Lines 407-416: assertions for `test_alloc_arena() == 30` and `test_alloc_external() == 12` |
| `test/10_runtime.sh` | alloc_arena and alloc_external in assertion name list | VERIFIED | Line 42: `wrap sat overflow alloc_default alloc_arena alloc_external arb_union_return \` |
| `docs/09-memory.md` | Allocator documentation covering default SMP, inline, and external modes | VERIFIED | `## Allocators` section (line 216) with all three modes, code examples, and allocator table |
| `src/templates/example/example.orh` | Living code example of allocator usage | VERIFIED | `import std::allocator` + `include std::collections` at module scope; `pub func allocator_demo()` at line 62 demonstrating all three modes |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `src/std/collections.zig` | `std.heap.GeneralPurposeAllocator` | module-level var `_default_smp` | WIRED | Pattern `var _default_smp.*GeneralPurposeAllocator` found at line 10 |
| `src/codegen.zig` | `src/std/collections.zig` | `.new(alloc)` emits `.{ .alloc = expr }` setting alloc field | WIRED | Pattern `.alloc =` found at lines 1851 (AST) and 2325 (MIR) |
| `src/std/allocator.orh` | `src/std/allocator.zig` | bridge func allocator() declared | WIRED | Pattern `bridge func allocator` found at lines 11, 19, 28 |
| `src/peg/builder.zig` | scoped_type PEG rule | `buildScopedType` builder | WIRED | Lines 197-198: dispatch to `buildScopedType` and `buildScopedGenericType`; defined at lines 1401+ |
| `src/resolver.zig` | qualified type validation bypass | `is_qualified` dotted-name check | WIRED | Lines 808, 836-837: `indexOfScalar(u8, type_name, '.')` check bypasses unknown-type error for dotted names |
| `src/zig_runner.zig` | bridge modules wired to shared modules | `mod_{name}` registration for transitive bridge imports | WIRED | Fix creates `mod_allocator` and wires to all shared modules so `@import("allocator")` resolves inside tester.zig |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `test/fixtures/tester.orh::test_alloc_arena()` | return value (sum of list items) | `List(i32).new(arena.allocator())` with `items.add(10)`, `items.add(20)` | Yes — runtime test confirms 10+20=30 | FLOWING |
| `test/fixtures/tester.orh::test_alloc_external()` | return value (sum of list items) | `List(i32).new(a)` with `items.add(5)`, `items.add(7)` | Yes — runtime test confirms 5+7=12 | FLOWING |
| `src/templates/example/example.orh::allocator_demo()` | return value | three List instances with `.add()` then `.get(0)` | Yes — compiles and runs as part of test suite | FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| All 11 test stages pass including runtime allocator tests | `./testall.sh` | 253/253 passed | PASS |
| alloc_default, alloc_arena, alloc_external all PASS in runtime output | included in testall.sh stage 10 | confirmed via 253 total pass | PASS |
| Example module compiles as part of project build | included in testall.sh stage 05 | confirmed | PASS |

### Requirements Coverage

No `REQUIREMENTS.md` file exists in this project. Requirement IDs (ALLOC-01 through ALLOC-07) are defined exclusively within the phase planning documents. Coverage is mapped from the CONTEXT.md decisions and PLAN success criteria:

| Requirement ID | Source Plan | Mapped Decision / Description | Status | Evidence |
|----------------|-------------|-------------------------------|--------|----------|
| ALLOC-01 | 21-01 | Mode 1: `List(i32).new()` uses default SMP allocator | SATISFIED | `_default_smp` singleton in collections.zig; `alloc` field defaults to `_default_smp.allocator()` |
| ALLOC-02 | 21-01 | Mode 2: `List(i32).new(arena.allocator())` — inline allocator | SATISFIED | 1-arg `.new()` codegen path emits `.{ .alloc = expr }`; `test_alloc_arena` runtime test passes |
| ALLOC-03 | 21-01 | Mode 3: `var a = smp.allocator(); List(i32).new(a)` — external variable | SATISFIED | Same codegen path; `test_alloc_external` runtime test passes |
| ALLOC-04 | 21-01 | Allocator passed via `.new()` not as generic type param; user struct `.new(arg)` unaffected | SATISFIED | `is_type_node` guard in codegen AST path; struct identifier nodes bypass the `.alloc` emission |
| ALLOC-05 | 21-01 | String interpolation uses `smp_allocator` (consistent default across generated code) | SATISFIED | 6 locations in codegen.zig use `smp_allocator`; only thread-handle lines retain `page_allocator` (out of scope) |
| ALLOC-06 | 21-02 | docs/09-memory.md documents all three allocator modes | SATISFIED | `## Allocators` section with code examples for all three modes |
| ALLOC-07 | 21-02 | Example module covers allocator usage with compilable code | SATISFIED | `pub func allocator_demo()` in example.orh; compiles as part of build |

**Note on REQUIREMENTS.md:** This project does not maintain a REQUIREMENTS.md file. All seven requirement IDs appear in PLAN frontmatter and are accounted for via phase planning documents and CONTEXT.md decisions. No orphaned requirements detected.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `src/codegen.zig` | 2780, 2796 | `page_allocator` in doc comment strings | Info | Comments-only; active code at lines 2802, 2854 correctly uses `smp_allocator`. No functional impact. |

No blocker or warning anti-patterns found. The `page_allocator` references at lines 332, 764, and 1014 are intentional and in-scope for thread-handle state (explicitly excluded in both PLAN and SUMMARY).

### Human Verification Required

None. All behaviors are verifiable programmatically through the test suite.

### Gaps Summary

No gaps. All six observable truths are verified, all eight required artifacts exist with substantive implementation, all key links are wired, data flows through the runtime tests to produce correct results, and all 253 tests pass. All seven requirement IDs are satisfied.

The phase delivered exactly what it committed to:

1. `collections.zig` defaults to SMP via `GeneralPurposeAllocator` singleton — `page_allocator` fully removed from the collection system
2. Codegen emits `.{ .alloc = expr }` for 1-arg `.new()` on collection type nodes in both AST and MIR paths
3. String interpolation uses `smp_allocator` consistently across all codegen paths
4. Three compiler fixes were required and delivered: scoped_type PEG builder, qualified type resolver bypass, transitive bridge module wiring in zig_runner
5. Runtime tests for all three allocator modes (alloc_default=300, alloc_arena=30, alloc_external=12) pass
6. Documentation and example module updated with working, compilable code demonstrating all three modes

---

_Verified: 2026-03-26_
_Verifier: Claude (gsd-verifier)_
