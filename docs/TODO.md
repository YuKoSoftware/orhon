# Orhon — TODO

Master tracking file. Everything is organized into phases ordered by dependency. Each phase has explicit blockers and a brief rationale. Severity tags: 🔴 Critical · 🟠 High · 🟡 Medium · 🟢 Low. Deferred/future work lives in [[future]].

## Current status

- **Completed:** Phase 0 — Correctness blockers ✓ | Phase A — AST/SoA rebuild ✓ | Phase B — MIR rebuild ✓ | Phase C — Codegen migration ✓ | Phase D — Cleanup ✓
- **Active project:** Phase 1 (Semantic Layer Cleanup) — S1 done (v0.53.2), S2 done (v0.53.3), S3 done (2026-04-24), S4 done (v0.53.4), S5 done (v0.53.5, 2026-04-24), S6 done (v0.53.6, 2026-04-24); Phase 1 complete
- **Tracking source:** Audit findings from `2026-04-14` recorded as **CB#** (correctness blockers), **H#** (architectural walls), **M#** (medium cleanup). Preserved so each item is traceable to its audit origin.

## Phase dependency graph

```
Phase 0 (correctness) ──┬─> Phase R (rebuild) ──┬─> Phase 1 (semantic)
                        │                       ├─> Phase 2 (diagnostics + testing)
Phase 4 (CLI + config) ─┘                       ├─> Phase 3 (parallelism + LSP)
                                                └─> Phase 5 (medium/low sweep — opportunistic)
```

Phase 0 must precede Phase R — the correctness bugs would be baked into the new storage otherwise.
Phase 4 can run parallel to Phase R (no overlap with AST/MIR code).
Phase 1, 2, 3 are all post-rebuild and can overlap, with internal ordering documented below.
Phase 5 is opportunistic — pick up items as time permits.

---

## Phase 0 — Correctness blockers `~3-5 days` `BEFORE REBUILD`

Silent bugs shipping today. Each fix is small (50-200 lines). Must land before Phase R so the rebuild doesn't carry the bugs forward into new storage.

- [x] **CB1** 🔴 **Borrow checker method collision** — `src/borrow.zig:172-181` says "first struct that has a method with this name wins." Two structs with same-named methods collide → wrong `self` mutability used → silent miscompilation of borrow safety. Fix: thread `type_map` from pass 5 into the borrow checker, resolve method via receiver type.
- [x] **CB2** 🔴 **NLL is statement-of-current-block, not non-lexical** — `src/borrow.zig:64-80, 225-320`. `buildLastUseMap` records stmt indices relative to current block; recursing into nested blocks writes parent indices into the child's map. Borrows crossing block boundaries drop at wrong scopes. Fix: guard `dropExpiredBorrows` so it skips borrows whose `scope_depth < self.scope_depth` — outer-scope borrows are only expired by their own block's NLL pass. Regression test added.
- [x] **CB3** 🔴 **Generic type params detected via length≤4 uppercase heuristic** — `src/resolver.zig:712-724`. Any user struct named `Vec3`, `Iter`, `Cell`, `Node`, `List`, `Pair` silently classified as type parameter; `typesCompatible` returns true against anything → type checking silently disabled for short-uppercase-named types. Fix: tie type-param identity to binder (`func foo<T>`), introduce `.type_param` variant in `ResolvedType` with explicit binder reference.
- [x] **CB4** 🔴 **Propagation pass is value-flow blind** — `src/propagation.zig:128-197`. Only recurses into `.block`; unions returned from function calls inside if/match/for/while bodies are invisible. Assignment tracking only handles bare-identifier RHS. "All errors must be handled" guarantee is mostly aspirational once code nests. Fix: recurse `checkNode` over all statement-bearing variants; treat any subexpression yielding a union as creating a tracked temporary.
- [x] **CB5** 🔴 **Interface hash silently truncates at 256 symbols** — `src/cache.zig:407-414, 435-441, 471-477`. `[256][]const u8` fixed buffer drops symbols past cap → different interfaces hash equal → incremental cache skips rebuilds that should happen → stale binaries passing tests. Fix: replace `NameBuf` with `ArrayListUnmanaged([]const u8)`, no cap.
- [x] **CB6** 🔴 **Parser bails on first error; no recovery** — `src/peg/engine.zig`, `src/main.zig:130-136`. First PEG mismatch aborts the whole pipeline. Must land before or as part of Phase A so the new `AstStore` builder isn't baked with the old assumption. Fix: add `^sync` markers to `orhon.peg` at `func_decl`/`struct_decl`/statement boundaries; engine skips to next sync on failure, records diagnostic, resumes.
- [x] **CB-verify** Add regression tests for each CB# fix under `test/fixtures/` (one minimal repro per bug, assert the fix holds).

---

## Phase R — Architecture Rebuild (Index-Based SoA) `3-6 weeks` `DONE ✓`

Full rebuild of parser/AST and MIR storage from pointer-based trees to index-based struct-of-arrays. See [`docs/superpowers/specs/2026-04-14-orhon-arch-rebuild-design.md`](superpowers/specs/2026-04-14-orhon-arch-rebuild-design.md) for full design.

**Blockers:** Phase 0 must be complete before Phase A starts.
**Scope:** each chunk is one commit, `./testall.sh` green at every boundary.
**Bundled audit items:** H3a (source spans) lands in A8; H4d (golden files) expanded in D3.

### Phase A — Parser / AST rebuild `DONE` ✓ merged 2026-04-16, tagged `phase-a-complete`

- [x] **A1** Land `StringPool` utility with interning + tests
- [x] **A2** Scaffold `AstStore` types, `extraData` / `appendExtra` helpers, no population
- [x] **A3** Create `ast_typed.zig` — typed wrapper struct per `AstKind` with pack/unpack round-trip tests
- [x] **A4** PEG builder dual output — `src/peg/builder.zig` produces `AstStore` alongside `*parser.Node` tree, parity harness
- [x] **A5** Migrate `src/resolver.zig` to read `AstStore` (bridge via `reverse_map`)
- [x] **A6** Migrate `src/propagation.zig` to read `AstStore`
- [x] **A7** Migrate `src/declarations.zig` to read `AstStore`
- [x] **A8** Centralize `nodeLocFromIdx` in `SemanticContext` — source location resolution via `AstNodeIndex`
- [x] **A9** MIR temporary adapter — `MirAnnotator` + `MirLowerer` entry points read `AstStore`, internal `*parser.Node` bridge remains
- [x] **A10** Drop dual output — remove `buildASTWithStore`/`DualBuildResult` + parity harness
- [ ] **A11** Delete old pointer-based `parser.Node` type entirely — **deferred to Phase C** (codegen, borrow/ownership checkers, module system still depend on it)
- [x] **A12** Phase A merge — `testall.sh` green (361/361), merged to main, tagged `phase-a-complete`

### Phase B — MIR rebuild `1-2 weeks`

- [x] **B1** Land `TypeStore` with `TypeId` interning + tests — `src/type_store.zig`; 8 tests covering round-trip, dedup, named/primitive/special/slice/generic; 361/361 testall green
- [x] **B2** Scaffold `MirStore` types, helpers, no population — `src/mir_store.zig`; `MirNodeIndex`, `MirExtraIndex`, `MirEntry`, `MirData`, `MirStore` with `TypeStore`+`StringPool`; 7 tests; 361/361 green
- [x] **B3** Create `mir_typed.zig` — typed wrapper per `MirKind` with pack/unpack round-trip tests — all 32 MirKind variants covered; 12 tests one per data shape; 361/361 green
- [x] **B4** `MirBuilder` skeleton with fusion + internal phase separation (`classifyNode`, `inferCoercion`, `lowerNode`), emits `passthrough` only
- [x] **B5** Populate declarations cluster
- [x] **B6** Populate statements cluster
- [x] **B7** Populate expressions cluster
- [x] **B8** Populate types + members + injected
- [x] **B9** Delete parity harness — `MirBuilder` is the sole producer
- [x] **B10** Delete `MirAnnotator`, `MirAnnotator_nodes`, `MirLowerer`, old `MirNode`, `NodeMap`
  - Phase C progress (C1–C6 complete): all codegen signatures migrated to MirNodeIndex; bridge infra with synthetic fallback for nodes not yet in MirStore. B10 can now proceed.
- [x] **B11** Phase B merge — final `testall.sh`, merge to main, tag

### Phase B — pre-flight hygiene

Small items from the 2026-04-16 readiness audit. Do before or alongside B1.

- [x] **BH1** Add "pre-rebuild architecture" caveat banner to top of `docs/COMPILER.md` — the pipeline diagram is stale post-Phase A (no `AstStore`; still shows `*parser.Node` end-to-end). Full rewrite stays at D5; this is a signpost so readers don't treat the current doc as current.
- [x] **BH2** Audit codegen child access — 30 `.children[` accesses in 4 codegen files (`codegen.zig`×1, `codegen_decls.zig`×9, `codegen_stmts.zig`×2, `codegen_exprs.zig`×18); 19 more in `mir_node.zig`+`mir_lowerer.zig`. Scope is mechanical (~50 call sites across 6 files) — confirmed manageable at B9/B10.
- [x] **BH3** Baseline MirNode peak memory on Tamga (40 generated Zig files, full pipeline): **226 MB peak RSS** (2.83 s wall time). Orhon pipeline completes; Zig subprocess exits 1 on missing system headers (SDL3/Vulkan), so the number cleanly reflects MirNode + all passes 1–10.

### Phase B — risks to watch

Invariants to preserve during fusion. Tracked from the 2026-04-16 readiness audit; not blockers, but each one is a silent-miscompile risk if missed.

- [ ] **BR1** `MirNode.ast` back-pointer lifetime — `AstStore` must outlive `MirStore`. Already true (AstStore lives for the whole compilation per design). Document the contract explicitly in the `MirStore` scaffold at B2 so nothing in B5–B8 accidentally frees the AST early.
- [ ] **BR2** `var_types` two-layer fallback — `MirLowerer.resolveSourceUnionRT()` (`src/mir/mir_lowerer.zig:546`) falls back to `var_types` when a narrowed MirNode type hides the source union. Fused `MirBuilder` must copy `var_types` into builder state or the lookup silently returns the wrong union shape.
- [ ] **BR3** Interpolation counter threading — `interp_counter: u32` mutates during lowering. Thread through fused phases or refactor to a per-block counter. Aligns with P7's broader `pre_stmts` discipline — assert empty at function boundary.
- [ ] **BR4** Classify → coerce → lower ordering inside `MirBuilder` — narrowing extraction reads classification output; union-tag stamping runs after classification. Keep explicit internal phase separation (`classifyNode` / `inferCoercion` / `lowerNode`) in the fused builder to prevent invariant loss at B4.

### Phase C — Codegen migration `0.5-1 week`

> **Phase C complete (2026-04-19)** — all codegen signatures migrated to MirNodeIndex; 361/361 green.
> **Phase B complete (2026-04-19)** — MIR rebuild done; old infra deleted; 361/361 green on main.

**C-prep — semantic completion (do before C1):**
- [x] **CP1** Add `coercion_kind: u8` to `MirEntry` in `src/mir_store.zig`; add `coercionFromKind`/`coercionToKind` helpers + round-trip tests
- [x] **CP2** Implement `inferCoercion` in `src/mir_builder.zig` by porting from `src/mir/mir_annotator_nodes.zig`; update all `appendNode` call sites in builder satellites
- [x] **CP3** Extend `IfStmt.Record` in `src/mir_typed.zig` with `narrowing_extra: MirExtraIndex`; add `IfNarrowingExtra` + `NarrowBranchExtra` records
- [x] **CP4** Implement narrowing detection in `src/mir_builder_stmts.zig` `lowerIfStmt`, porting from `src/mir/mir_annotator_nodes.zig`
- [x] **CP5** Fix `mir_builder.build()` to iterate all top-level decls (program root was passthrough, MirStore was never populated); fix 3 latent sentinel/assert bugs exposed

**C1–C6 — codegen migration (one commit each, `testall.sh` green after each):**
- [x] **C1** `src/codegen/codegen.zig` — add `mir_store`, `mir_root_idx`, `mir_type_store`, `mir_builder_var_types` fields; `span_to_mir` reverse map; wire new fields from pipeline alongside old compat wiring
- [x] **C1b** `src/codegen/codegen.zig` + `src/mir_builder.zig` — `build()` returns Block (top-level list); `generate()` iterates from MirStore via span→old-MirNode bridge; `mir_typed` import added
- [x] **C2** `src/codegen/codegen_decls.zig` — all signatures migrated to MirNodeIndex + bridge
- [x] **C3** `src/codegen/codegen_exprs.zig` — all signatures migrated to MirNodeIndex + bridge
- [x] **C4** `src/codegen/codegen_stmts.zig` — all signatures migrated to MirNodeIndex + bridge
- [x] **C5** `src/codegen/codegen_match.zig` — all signatures migrated to MirNodeIndex + bridge
- [x] **C6** bridge infra in codegen.zig: synth fallback maps for nodes not in MirStore; 361/361 green
- [x] **C7** Phase C merge — 361/361 green, committed 2026-04-19 (v0.51.8)
> - `m.union_tag` on Binary nodes → MirStore Binary has no union_tag; must compute from var_types at call site

> **Phase D complete** (v0.53.0, 2026-04-20, 367/367 green). Phase 1 (Semantic Layer Cleanup) is next.

> **⬅ RESUME HERE: Phase 2** — Phase 1 complete (S6 done, v0.53.6, 2026-04-24). Next: diagnostics + testing overhaul.

### Phase D — Cleanup `0.5 week`

- [x] **D1** `AstStore` pretty-printer + debug dump
- [x] **D2** `MirStore` pretty-printer + debug dump
- [x] **D3** Golden-file fixtures for canonical `.orh` inputs (one `.ast.golden` + `.mir.golden` per fixture). **Bundle H4d here:** expand coverage to one snapshot per language feature category (~20 files covering compt, blueprints, generics, handles, interpolation, slicing, defer, ownership-edge, borrow-edge).
- [x] **D4** Dead code sweep (grep for removed types, delete orphaned helpers)
- [x] **D5** Update `docs/COMPILER.md` to reflect new architecture (also fixes F20 stale pipeline diagram)
- [x] **D6** Update this file — close obsolete entries, mark newly unblocked projects
- [x] **D7** Version bump, final `testall.sh`, merge

### Cross-phase invariants

- `./testall.sh` green at every commit
- One phase merged before next starts
- Incremental cache format NOT changed (avoid on-disk compatibility pressure)
- No MIR serialization work during the rebuild
- Branch per phase; PR + review before merge

### Unblocked by this project (future work)

- MIR serialization / incremental cache at MIR level
- Second backend (LLVM, C, native, WASM)
- MIR-level optimization passes (dead narrowing, match reachability, constant folding)
- SSA layer (`OrhonAir`) on same primitives
- Parallel compilation (prerequisite for Phase 3)
- Fast LSP with feature-gated passes (prerequisite for Phase 3)
- **Watch mode / continuous compile loop** — not currently tracked or scaffolded in `pipeline.zig`. Depends on P1 (`ModuleCompile` struct) so a single changed module can be re-compiled in isolation. File as a future project after Phase 3 completes.

---

## Phase 1 — Semantic Layer Cleanup `~2-3 weeks` `POST-REBUILD`

**Blockers:** Phase R must be complete. AST/MIR indices make the symbol table rewrite substantially easier.
**Internal ordering:** S1 (easy win, reduces noise) → S2 (Symbols) → S3 (resolver split, needs S2) → S4 (stateless, needs S3) → S5 (shadowing, independent) → S6 (type param model, needs S2).

- [x] **S1** 🟠 **Fold `K.Type.*` stringly-typed special types into `Primitive` enum** [H1c] — 88 `std.mem.eql` compares across 27 files for `ERROR`, `NULL`, `ANY`, `THIS`. Centralize in `types.Primitive` so every codegen site goes through `Primitive.fromName(s) → enum`, then single `switch` per emission point.
- [x] **S2** 🟠 **Replace `DeclTable`'s 7 parallel StringHashMaps with a unified `Symbols` table** [H1a, absorbs existing "DeclTable 7 maps" item] — `src/declarations.zig:84-193`. Every consumer re-glues the 7-way split (`hasDecl`, `validateType`, cross-module hint loops are O(modules × kinds × decls)). Replace with `StringHashMap(Symbol)` over a `SymbolKind` tagged union. Cross-module resolution becomes one hashmap lookup.
- [x] **S3** 🟠 **Split `resolver.zig` along pass 4/5 boundary** [H1b, absorbs existing item] — done 2026-04-24 — 2038 lines mixing declaration registration, type resolution, expression checking, scoping in one file. `var_decl` case does four passes worth of work. Split into (a) `Symbols` builder (extend DeclCollector from S2), (b) `TypeChecker` that walks expressions and produces `type_map`, (c) `Validator` for shadowing/exhaustiveness/reservedness.
- [x] **S4** 🟠 **Stateless resolver via `ResolveCtx` passed down** [H1e] — done v0.53.4, 2026-04-24 — `current_node`, `param_names`, `in_is_condition`, `loop_depth`, `type_decl_depth`, `current_return_type`, `in_generic_struct`, `in_anytype_arg` were mutable per-instance fields on `TypeResolver`. Blocks per-function/per-module parallelism. Packed into `ResolveCtx` value passed by copy down recursion.
- [x] **S5** 🟠 **Uniform shadowing detection for every binder** [H1d] — done v0.53.5, 2026-04-24 — `var_decl` and `destruct_decl` checked shadowing; function params, for captures, match arm bindings didn't. Added `is_func_root: bool` scope marker; single `defineUnique(scope, name, loc)` helper every binder calls.
- [x] **S6** 🟠 **Real type parameter binder model** [H1f, requires CB3 already landed] — done v0.53.6, 2026-04-24 — `ResolvedType` gains `.type_param` variant with explicit binder reference. Foundation for future constraint checks (`T: Eq`), better generic error messages, and explicit instantiation tracking. HKT remains out of scope.

---

## Phase 2 — Diagnostics + Testing Overhaul `~2 weeks` `POST-REBUILD`

**Blockers:** Phase R (Phase A delivers source spans via A8). Can overlap with Phase 1.
**Internal ordering:** T1 → T2 (T2 needs T1), T3 in parallel, T4 needs T3 landed, T5 uses T3+T4.
**Grouping rationale:** reporter rewrite and test runner rewrite are interdependent — tests want to assert on error codes, codes need the reporter to emit them.

### Sub-project 2a — Reporter rewrite

- [ ] **T1** 🟠 **Error code catalog (`src/error_codes.zig`)** [H3b / F3] — add `code: ?ErrorCode` field to `OrhonError`. Stable enum with never-reused retired codes. Tests assert on codes, not message text.
- [ ] **T2** 🟠 **JSON / machine-readable diagnostic output** [H3c / F4] — `Reporter.flush(writer, format)` where format is `.human | .json | .short`. Required by CI annotations, vim quickfix, emacs, non-LSP editors.
- [ ] **T3** 🟡 **`NO_COLOR` / TTY detection + `--color=auto|always|never`** [H3d / F5] — `src/errors.zig:134-194`. Detect `isatty(stderr)` + `NO_COLOR` env at reporter init, cache `use_color: bool`, gate every escape sequence.
- [ ] **T4** 🟡 **Warning gradient with notes** [F8] — add `Severity = .err | .warning | .note | .hint`; multi-location errors chain notes via `parent: ?usize`. Add `-Werror` flag.
- [ ] **T5** 🟡 **Fix reporter ownership convention** [F7] — `src/errors.zig:58-69`. Current design: callers allocate + report dupes + defer free → double allocation + easy leak. Migrate all manual `allocPrint` + `report` + `defer free` sites to `reportFmt`. Document new contract: `report()` takes ownership.
- [ ] **T6** 🟡 **Cache source file contents in reporter** [F6] — `src/errors.zig:198-219`. Per-diagnostic `readSourceLine` re-opens + reads entire file via page allocator, copies into static buffer (blocks concurrent reporting). Fix: `StringHashMap([]const u8)` cache per Reporter.
- [ ] **T7** 🟡 **Top-level `main()` ICE handler** [F24] — `src/main.zig:130-136`. Top-level `catch` that prints "internal compiler error — please report at <url>" with error tag + minimal repro hint, exits 70, instead of leaking Zig stack traces.

### Sub-project 2b — Test runner rewrite

- [ ] **T8** 🟠 **Zig-based test runner** [H4c / F14] — replace ~2000 lines of bash grep-on-output with `test/runner.zig` that compiles fixtures and asserts on JSON-formatted diagnostics with `code` + `loc.line`. Keep shell tests only for end-to-end CLI verification. Enables property-based tests.
- [ ] **T9** 🟡 **Fixture reorganization** [F15] — subdirs `fixtures/parse/`, `fixtures/borrow/`, `fixtures/runtime/`, `fixtures/codegen/`. Per-fixture `.expect` sidecar with expected exit code, error codes, stderr snippets.
- [ ] **T10** 🟡 **Expand snapshot coverage** — one snapshot per language feature category. Land on top of D3's golden-file infrastructure.
- [ ] **T11** 🟡 **Perf baseline tests** [F17] — `test/12_perf.sh` records wall time for canonical fixtures into `test/perf.log`, prints delta on each run. Essential for validating rebuild perf wins.
- [ ] **T12** 🟡 **Property-based pipeline tests** [existing TODO item, absorbed] — parse→pretty-print round-trip, type check idempotence, codegen `zig ast-check` validity. Depends on T8.

---

## Phase 3 — Parallelism + LSP + Codegen Quality `~2-3 weeks` `POST-REBUILD`

**Blockers:** Phase R. Best after Phases 1 and 2 (stateless resolver from S4, per-module compile struct depends on it).
**Internal ordering:** P1 foundational → P2 and P3 both depend on P1 → P4-P7 independent, do in parallel.

### Sub-project 3a — Parallelism foundation

- [ ] **P1** 🟠 **`ModuleCompile` struct with per-module arena** [H2d] — `src/pipeline.zig:299-476`. Every module currently mutates shared state; no isolation. Create a `ModuleCompile { arena, decls, output }` struct. Pipeline becomes (1) parse all modules into per-module arenas, (2) build global `Interface` snapshot, (3) parallel `compileOne(mod, &snapshot)` jobs, (4) merge outputs. Foundational for everything else in P3.
- [ ] **P2** 🟠 **Transitive cache invalidation** [H2e, absorbs existing "BuildGraph" item] — `src/pipeline.zig:337-368`, `cache.zig:188-225`. Only checks direct deps, not transitive. `moduleNeedsRecompile` is dead code. No atomic writes (no `tmp + rename`). Cycle detection reports one back-edge only. Additionally: `hashSemanticContent` **excludes doc comments** — latent cache lie if doc comments ever feed codegen (e.g., via `@compileError` messages, future docgen integration). Fix: compute transitive closure once after parsing, delete dead path, atomic ZON writes, full cycle path in error messages, include doc comments in semantic hash or prove they never affect codegen.
- [ ] **P3** 🟠 **LSP reuses pipeline via `runPasses(stop_after:)` entry point** [H3e / existing "LSP feature-gated passes" and "LSP incremental sync" items] — `src/lsp/*` is 3500 lines re-implementing parsing. No feature gating, no cancellation, no debouncing. Fix: `Pipeline.runPasses(modules, stop_after: Pass)` entry point; LSP reuses the per-module compile struct from P1. Gate passes by request type: completion→1-4, hover→1-5, diagnostics→1-9.

### Sub-project 3b — Codegen quality

- [ ] **P4** 🟠 **Rewrite `typeToZig` as pure function over `ResolvedType`** [H2a] — `src/codegen/codegen.zig:583-771, 719-768`. Two near-identical AST-walking implementations over `.type_union` and `.binary_expr` will drift. Allocates per-node strings with whole-codegen lifetime → quadratic memory on deeply nested generics. Fix: lower types to `ResolvedType` once in sema (already exists), `zigOf(ResolvedType)` becomes pure. Delete the `binary_expr` branch.
- [ ] **P5** 🟠 **Rewrite `checkUnusedImports` to use resolver data** [H2b] — `src/pipeline_passes.zig:120-130`. Currently substring-searches raw source for `"<alias>."` with all the false positives/negatives that implies. Re-reads files every build. Fix: when resolver resolves a qualified `mod.X`, mark import as used on the `AstStore` side. Delete the textual scan.
- [ ] **P6** 🟠 **Source-location propagation from generated Zig to `.orh`** [H2c] — all of `src/codegen/*.zig`. Zig errors currently show `.orh-cache/generated/foo.zig:412:9`; users reverse-map. Fix: populate `(generated_file, line) → (orh_file, line)` side-table during emit. `reformatZigErrors` becomes an exact lookup.
- [ ] **P7** 🟠 **`pre_stmts` interpolation hoisting as stack of frames** [H2g] — `src/codegen/codegen.zig:64`. Global mutable buffer; nested interpolation can clobber. No assertion empty at statement boundaries → silent data loss if new statement codegen forgets `flushPreStmts`. Fix: stack of frames, auto-flush at statement boundaries, assert empty at function boundary.

---

## Phase 4 — CLI + Config + Stability `~1-2 weeks` `INDEPENDENT`

**Blockers:** none. Can run parallel to Phase R (touches entirely different files).
**Internal ordering:** X1 → X2-X6 in parallel.

- [ ] **X1** 🟠 **Table-driven CLI parser** [H4a / F9] — `src/cli.zig:93-215`. 120-line `while` loop of string compares, mixed flag conventions, source-dir as fall-through positional (`orhon biuld` tries to compile a directory named "biuld"), no per-command help. Fix: per-command struct declaring flags as a comptime array; parser dispatches table-driven. Prerequisite for every new command.
- [ ] **X2** 🟠 **`orhon.zon` project manifest** [H4b / F10] — move `#version`/`#build` metadata out of `.orh` files. Holds targets, optimization level, future dependency list, LSP settings. Pre-1.0 is the time to design; post-1.0 every choice is a migration problem.
- [ ] **X3** 🟡 **`orhon init --update` migration** [F11] — templates are a living language manual but existing projects freeze at install time. Stamp templates with hash/version, `orhon init --update` diffs and refreshes unmodified files only.
- [ ] **X4** 🟡 **`orhon check` command** [F22] — passes 1-9 only, no MIR/codegen/Zig invocation. Standard in cargo/swift/go. CI speed-up + pre-commit hook material. Already implemented internally for LSP.
- [ ] **X5** 🟡 **Safer `addtopath`** [F21] — `src/commands.zig:212-314` edits shell rc files directly with no backup, no `--dry-run`, no Windows handling. Fix: write `<rc>.orhon-backup` before editing, print diff, support `--dry-run`; long-term suggest the user adds the export line themselves.
- [ ] **X6** 🟡 **Versioning policy doc + CI workflow** — pre-1.0 has no documented breaking-change policy; no `.github/workflows/` or equivalent (releases ship without recorded green run on clean machine). Write `docs/versioning.md`; land a minimal CI config.

---

## Phase 5 — Medium/Low Cleanup Sweep `opportunistic` `ANY TIME POST-REBUILD`

No dependencies. Pick up items as time permits, in any order. Grouped by subsystem for scannability.

### Semantic layer — medium

- [ ] **M1** 🟡 **Type aliases resolve to `.inferred`** — `src/resolver.zig:96-109`. `const Userid: type = i64` + passing a `string` where `Userid` is expected → checker sees `.inferred` and approves. Fix: resolve aliases to target during declaration, store resolved target in `decls.types`, use at use sites.
- [ ] **M2** 🟡 **`inferCaptureType` limited to range/str/slice/array** — `src/resolver.zig:700-710`. Iterating a `List(T)` or `Map(K,V)` yields `.inferred` because those are `.generic`. Needs a generic-aware iterator protocol (depends on S6).
- [ ] **M3** 🟡 **Scope is hashmap-per-frame with allocation per block** — `src/scope.zig`. Fix: single `vars: ArrayList(Binding)` + `frames: ArrayList(usize)` start-index stack. Pop frame by truncating. Good fit for the arena-allocated scope stack.
- [ ] **M4** 🟡 **Type arena never freed mid-compile** — `src/declarations.zig:97`. Grows monotonically. Fix: split into permanent arena (types stored in DeclTable signatures) and scratch arena (expression-level temporaries, reset per function).
- [ ] **M5** 🟡 **Linear scans in union helpers** — `src/types.zig:223-251`. `unionContainsError`, `unionContainsNull`, `unionInnerType`, `findDuplicateUnionMember` (O(n²)) called hot. Fix: store `is_error_union: bool` and `is_null_union: bool` on union variant at construction.
- [ ] **M6** 🟡 **`topologicalOrder` recursive DFS; single back-edge reported** — `src/module.zig:386-438`. Stack-overflow risk on adversarial inputs; bad cycle UX (prints `A → B` instead of `A → B → C → A`). Fix: iterative DFS with explicit stack, full cycle path recording.
- [ ] **M7** 🟡 **Cross-module "did you mean" loops are O(mod × kinds)** — `src/resolver_validation.zig:189-206`, mirrored in `src/resolver_exprs.zig:86-104`. Per unknown identifier. Fix: single global `name → (module, kind, is_pub)` reverse index built once after pass 4.
- [ ] **M8** 🟡 **`is_zig_module` path-based magic** — `src/declarations.zig:314, 365`, `src/resolver_validation.zig:166-169`, `src/pipeline_passes.zig:90-92`. Tests `std.mem.startsWith(u8, l.file, cache.ZIG_MODULES_DIR)`. Violates zero-magic rule loosely. Fix: explicit `Module.is_synthetic: bool` flag set at construction.

### Codegen layer — medium

- [ ] **M9** 🟡 **`codegen_match.zig` junk drawer split** [existing item, H2f, absorbed] — 1058 lines hosting match, intrinsics (`@cast`/`@overflow`/`@wrap`/`@sat`), interpolation, string matching. Split into `codegen_match.zig` (match only) + `codegen_intrinsics.zig` + `codegen_strings.zig`.
- [ ] **M10** 🟡 **`zig_runner_multi.zig` builds 700-line `build.zig` via `appendFmt`** — exactly the anti-pattern CLAUDE.md warns about. Literal `{`/`}` everywhere handled via `{{`/`}}` escaping, brittle. Cross-wire shared modules block at `:250-263` is O(N²) in shared module count. Additionally: `sorted_libs` topological sort silently emits the remainder "as-is" on a cycle (`:94-102`) instead of reporting an error; `lib_targets` map (`:54`) holds borrowed pointers aliasing `targets` with no lifetime documentation. Fix: `Writer` builder, no `appendFmt` of multiline strings; emit cross-wires only when `mod_imports` demand them; treat lib-graph cycle as a hard error with full cycle path; document `lib_targets` lifetime.
- [ ] **M11** 🟡 **Hardcoded type name strings in codegen** — `codegen.zig:586` (`K.Type.ERROR`→`anyerror`), `:613` (`"null"` compared as string), `:658` (`K.Type.VECTOR`→`@Vector`), `:587-592` (`THIS`/`SELF_DEPRECATED`→`@This()`). Folded into S1 long-term; short-term centralize in `types.Primitive`.
- [ ] **M12** 🟡 **Silent `else => "anyopaque"` fallbacks in `typeToZig`** — `src/codegen/codegen.zig:769, 710`. User-triggerable parser shape reaching unhandled type-node arm → silent `anyopaque` → confusing Zig error far from cause. Fix: replace with `reporter.report(...internal...)` and `error.CompileError`.
- [ ] **M13** 🟡 **`@panic` in `generateCompilerFuncMir`** — `src/codegen/codegen_match.zig:816`. Hard-crashes on malformed MIR. Fix: replace with internal-error report.
- [ ] **M14** 🟡 **Stdlib `.zig` import rewriting is text substitution** — `src/pipeline.zig:80-119`. Naive `@import("foo.zig")` → `"foo_zig"` replacement misses whitespace variations, multi-line imports. `readFileAlloc` per build even when nothing changed. Fix: structural rewrite via `zig_module.discoverAndConvert`'s AST output, cache-aware extraction.
- [ ] **M15** 🟡 **`init.zig` template list duplicated 3× with hardcoded count** — `src/init.zig:14-21, 75-84, 102`. Adding an example file touches two const blocks and a success-message count. Same pattern in `std_bundle.zig` ×30. Fix: comptime-walked tuple or `.{ name, content }` array.
- [ ] **M16** 🟡 **`writeZonCache` has no atomic rename** — `src/cache.zig:79-87`. Partial writes leave stale files. Fix: `tmp + rename` helper.
- [ ] **M17** 🟡 **Duplicate bootstrapping in `commands.zig`** — `runDebug` (`:96-143`), `runGendoc` (`:172-208`), `runPipeline`'s init phase, `lsp_analysis.zig`. ~80 lines of duplicated "set up reporter + resolver + scan" boilerplate. Fix: shared `bootstrapAnalysis(allocator) → struct { reporter, resolver }` helper.
- [ ] **M18** 🟡 **`readToEndAlloc(10MB)` for Zig subprocess stdout/stderr** — `src/zig_runner.zig:172-173`. Long Zig build hits OOM instead of graceful "build had a lot of output". Fix: streaming read or larger cap with explicit error.
- [ ] **M19** 🟡 **POSIX `STDOUT_FILENO` hardcoded** — `src/commands.zig:60-67` and similar. `File{ .handle = ... }` manual construction. Breaks Windows. Fix: `std.fs.File.stdout()`.
- [ ] **M20** 🟡 **Pipeline errors via `std.debug.print`** — `src/pipeline.zig:147-152`. Source-dir-not-found prints to stderr directly instead of `reporter.report`. Inconsistent error path.
- [ ] **M20b** 🟢 **`canonicalUnionRef` calls `typeToZig` twice per member** — once as sort key, once for output. Redundant work on every union emission. Trivially cacheable. Folds into P4 (`typeToZig` rewrite) naturally — will disappear when types are pre-lowered to `ResolvedType`.

### CLI / init / testing — medium-low

- [ ] **M21** 🟡 **`std_bundle` re-extracts 30 files on every build** [F13] — `src/std_bundle.zig:69-109`. Pollutes cache with files the user never imports. Embedded payload bloats orhon binary linearly with stdlib. Fix: lazy extraction driven by import graph; consider packed blob instead of 30× `@embedFile`.
- [ ] **M22** 🟢 **No verbosity / quiet flag** [F23] — `-q`, `-vv`, `ORHON_VERBOSE` env. Scripting/CI ergonomics.
- [ ] **M23** 🟢 **Hide `orhon analysis` from user help** [F18] — `src/cli.zig:243`. Developer-only debugging command listed alongside `build`/`run`/`test`. Move under `orhon -dev analysis` namespace.
- [ ] **M24** 🟢 **Stale doc: `orhon analysis` description** [F19] — `docs/13-build-cli.md:21` says "dump parse tree analysis" but actual command runs PEG grammar validation. Trivial fix.
- [ ] **M25** 🟢 **Clarify testing doc: user `test {}` blocks vs compiler test suite** [F25] — `docs/15-testing.md`. Conflates the two audiences.
- [ ] **M26** 🟢 **Dependency manager consideration** — not mentioned in `docs/future.md`. Will become urgent once external Orhon packages exist. Ties into X2 (`orhon.zon` manifest).
- [ ] **M27** 🟢 **Tree-sitter grammar** — listed `medium` in `docs/future.md`. Will become urgent once Orhon hits adoption (Neovim/Helix/Zed users demand it).
- [ ] **M28** 🟢 **Source mapping `.orh.map`** — mentioned in `docs/future.md` under "debugger integration" and "source mapping" but not tracked. Related to P6.

---

## Notes on absorbed items

These previously tracked items have been folded into audit-driven entries above:

| Old entry | Absorbed into |
|-----------|---------------|
| `MirNode` 20-field god struct | Resolved by Phase R (Phase B rebuild) |
| `DeclTable` 7 parallel StringHashMaps | S2 |
| `resolver.zig` 2038-line pass split | S3 |
| Implicit dep tracking / BuildGraph | P2 |
| `codegen_match.zig` junk drawer | M9 |
| LSP feature-gated passes | P3 |
| LSP incremental document sync | P3 |
| Property-based pipeline testing | T12 |

---

## Architectural Decisions (Settled)

| Decision | Rationale |
|----------|-----------|
| Fix bugs before architecture work | Correctness before performance/elegance |
| Pointers in std, not compiler | Borrows handle safe refs; std::ptr is the escape hatch |
| Transparent (structural) type aliases | `Speed == i32`, not a distinct nominal type |
| Allocator via `.withAlloc(alloc)`, not generic param | Keeps generics pure (types only) |
| SMP as default allocator | GeneralPurposeAllocator optimized for general use |
| Zig-as-module for Zig interop | `.zig` files auto-convert to Orhon modules |
| Explicit error propagation via `if/return` | No hidden control flow, no special keywords |
| Parenthesized guard syntax `(x if expr)` | Consistent with syntax containment rule |
| Hub + satellite split pattern | All large file splits use same pattern for consistency |
| `is` restricted to if/elif only | Narrowing only works in if/elif; `@typeOf` covers other contexts |
| `blueprint` for traits, not `impl` blocks | Everything visible at the definition site |
| No Zig IR layer in codegen | Direct string emission. MIR/SSA is the optimization target |
| Index-based SoA storage for parser and MIR | Future-proof, adopted from Zig's `Ast.zig` + Carbon's typed wrappers (Phase R) |

---

## Explicitly NOT Adding

| Feature | Why Not |
|---------|---------|
| Macros | `compt` covers the use cases without readability costs |
| Algebraic effects | Too complex. Union-based errors + Zig module I/O is sufficient |
| Row polymorphism / structural typing | Contradicts Orhon's nominal type system |
| Garbage collection | Contradicts systems language positioning. Explicit allocators |
| Exceptions | Union-based errors are better for compiled languages |
| Operator overloading | Leads to unreadable code. Named methods are clearer |
| Multiple inheritance | Composition via struct embedding is sufficient |
| Implicit conversions | Explicit `@cast()` is correct. Implicit conversions cause subtle bugs |
| Refinement types | Struct-validation pattern already covers this |
| Full Polonius borrow checker | Overkill. NLL gives 85% of the benefit for 30% of the work |
| Zig IR layer in codegen | Would model Zig semantics inside the compiler |
| Arena allocator pairing syntax | `.withAlloc(alloc)` already covers composed allocators via Zig module |
| `#derive` auto-generation | Blueprints require explicit implementation. No implicit anything |
| `#extern` / `#packed` struct layout | `.zig` modules already support these natively |
| `async` keyword | Wait for Zig's new async design, then map cleanly. `std::thread` + `thread.Atomic` covers parallelism |
| Compound `is` (`and`/`or`) | Narrowing can't handle multiple simultaneous type checks. Use nested ifs |
| `is` outside if/elif | `is` is a narrowing construct, not a general operator. Use `@typeOf` for type checks |
| `capture()` / closures | No anonymous functions. State passed as arguments — explicit, obvious |
