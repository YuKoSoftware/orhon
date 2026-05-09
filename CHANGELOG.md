# Changelog

All notable changes to the Orhon compiler.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.53.62] — 2026-05-09

### Changed
- Phase 6a complete: codegen `typeToZig` rewritten to use `MirEntry.type_id` + `zigOfRT`

## [0.53.61] — 2026-05-09

### Changed
- Phase 6a — codegen `typeToZig` rewrite: migrated from `parser.Node` to `MirEntry.type_id`.
  - Simplified `typeToZig` from 57-line special-case function to 9-line bridge.
  - Migrated 10 of 12 production call sites to `MirEntry.type_id` + `zigOfRT`.
  - 2 call sites (return type, enum backing) use simplified `resolveTypeNode` bridge.
  - Added `extractValueTypeRT`, removed `extractValueType` parser.Node version.
  - Added `zigOfRT` tests for array and tuple_named.
  - Fix: handle `any` ~ `.named("any")` RT representation (not `.primitive`).
  - Fix: `@TypeOf` in type alias position uses `generateExprMir`, not `typeToZig`.
  - Fix: param/field fallback to AST path when `type_id == .none`.
  - Kept `ast_reverse_map`, `getAstNode`, `exprToString` (for Phase 6b).

### Added
- Phase 6a plan in TODO.md: define 10 sub-phases (6a–6j) to remove pointer-based `parser.Node`
  tagged-union AST (~694 references across 20+ files) and complete migration to index-based
  SoA storage.

## [0.53.60] — 2026-05-09

### Added
- M26: Dependency manager considerations documented in `docs/future.md`. Covers design decisions
  (git vs registry, manifest format, version resolution, lock file, Zig integration), 6-phase
  implementation plan, and relationship to Zig's package manager.

### Changed
- Phase 6 plan in TODO.md: define 10 sub-phases (6a–6j) to remove the pointer-based `parser.Node`
  tagged-union AST (~694 references across 20+ files) and complete the migration to index-based
  SoA storage.
- TODO.md status updated: Phase 5 marked complete (all M1-M26 done), phase dependency graph
  updated to include Phase 6.

## [0.53.59] — 2026-05-09

### Changed
- M21: Stdlib extraction made lazy — stdlib modules now processed from in-memory content
  (no upfront disk I/O). Pipeline uses `getStdModules()`/`getStdContent()`/`discoverAndConvertEmbedded()`
  for in-memory processing. `ensureStdFiles()` kept for gendoc compat.

## [0.53.58] — 2026-05-05

### Fixed
- E9005 cascade: stdlib zig-backed modules emitted empty function bodies instead of re-exports.
  Root cause: `discoverAndConvert` wrote `_zig.zig` sidecars to `.orh-cache/generated/` before
  the directory existed. Fix: `makePath` before file writes in `zig_module.zig`.
- zig_runner double-free: stderr `OutputTooLarge` path could double-free `stdout` allocation
  via errdefer. Added `stdout_freed` flag guard.
- Pipeline source-dir-not-found errors now go through `reporter.reportFmt` instead of
  `std.debug.print`.
- M15: Deduplicated init.zig template list (single comptime array replaces 8 `@embedFile` consts).

### Added
- Verbosity/quiet flag system: `-q` (quiet), `-vv` (very_verbose), `ORHON_VERBOSE` env var
  accepting `0/quiet`, `1/normal`, `2/verbose`, `3/very_verbose`.
- Error code `E5009` (`source_dir_not_found`) for pipeline file-not-found diagnostics.

### Changed
- M19: Replaced 3 POSIX `STDOUT_FILENO`/`STDIN_FILENO` hardcoded handles with portable
  `std.fs.File.stdout()` / `std.fs.File.stdin()` in `main.zig` and `lsp.zig`.
- M18: Zig runner stdout/stderr capture replaced with chunked 4KB streaming reads, cap
  lowered from 10MB to 1MB.
- M23: `orhon analysis` command hidden from user help (remains functional via CLI lookup).
- M24: Updated `orhon analysis` description in docs to "PEG grammar validation".
- M25: Added note to testing doc distinguishing Orhon `test` blocks from compiler test suite.
- zig_runner: `show_zig_output: bool` → `verbosity: Verbosity` field; raw Zig output gated on level≥2; "Built:"/test output suppressed in quiet mode.

## [0.53.57] — 2026-05-04

### Fixed
- ERR-02 test in `11_errors.sh` pointing to deleted fixture (now uses `fail_types.orh`)
- LSP test blocks (39 tests) now reachable via `zig build test` via `src/lsp_test.zig` wrapper

### Added
- CHANGELOG.md (41 version entries documenting full development history)
- .editorconfig for consistent editor settings across contributors

### Changed
- Stale `.orh-cache/` directories cleaned from test fixtures at start of each `testall.sh` run

## [0.53.56] — 2026-05-03

### Fixed
- E9005: `typeToZig cannot lower non-identifier call expression` fully resolved.
  Type constructors (`collections.List(i32)`) and `@tuple(...)` in generic args now
  work correctly in type alias positions. All 5 E9005 occurrences eliminated.

## [0.53.55] — 2026-05-03

### Fixed
- Stdlib `.zig` import rewriting replaced naive text substitution with AST-based
  rewrite, eliminating silent corruption of Zig source.
- E9005 root cause identified: two stacked bugs in resolver type constructor
  handling and `@tuple` resolution. Partial fix applied.

### Changed
- Stdlib extraction uses `XxHash3` freshness checks instead of re-extracting on
  every build.

## [0.53.53] — 2026-05-03

### Added
- Cross-module reverse index for O(1) "did you mean?" suggestions. Unknown
  identifier hints now complete in constant time regardless of module count.

## [0.53.52] — 2026-05-03

### Fixed
- Module dependency cycle detection converted from recursive DFS to iterative
  with explicit stack, eliminating stack-overflow risk on deep import graphs.
  Cycle error messages now show the full path (`A → B → C → A`).

## [0.53.50] — 2026-05-03

### Changed
- Union type helpers (`unionContainsError`, `unionContainsNull`, `unionInnerType`)
  are now O(1) instead of linear scan. Affects all error-handling and null-check
  code paths.

## [0.53.49] — 2026-05-02

### Changed
- Per-module arena split into interface arena (whole-build lifetime for type
  signatures) and body arena (per-module scratch). Reduces peak memory during
  compilation.
- Resolver gains dedicated scratch arena for expression-level type allocations,
  reset per function.

## [0.53.48] — 2026-05-02

### Added
- Cyclic type alias detection (`A: type = B; B: type = A`) now emits diagnostic
  E2087 instead of silently returning an unknown type.

### Fixed
- Scope pointer stability: `lookupPtr` now reserves capacity before obtaining
  pointers, preventing use-after-realloc in scope operations.
- `popFrame` on empty scope stack now fails fast with assertion instead of
  silently swallowing the error.

## [0.53.46] — 2026-05-02

### Changed
- Scope implementation replaced per-frame `StringHashMap` + parent chain with
  single flat `ArrayList(Binding)` and start-index stack. Lower allocation
  overhead per block, faster lookups.

## [0.53.45] — 2026-05-02

### Added
- `for`-loop capture type inference now handles generic collections (`List(T)`,
  `Set(T)`, `Map(K,V)`) and user-defined single-arg generics without hardcoded
  stdlib names. Follows the zero-magic rule.

## [0.53.44] — 2026-05-02

### Added
- Type alias chains (`A: type = B; B: type = i64`) now resolve transitively
  (depth limit 32). `A` resolves to `i64`, not `B`.

### Fixed
- Local (function-scoped) type aliases now resolve to their target types instead
  of `.inferred`, fixing type mismatch silent-passes.

## [0.53.40] — 2026-04-27

### Added
- String interpolation (`"Hello, @{name}!"`) now supports arbitrary expressions
  inside `@{}`: `@{x + 1}`, `@{obj.field}`, `@{f(a, b)}`. Previously only bare
  identifiers were accepted.

## [0.53.39] — 2026-04-27

### Changed
- Lexer state machine extended with `LexerMode` supporting nested sub-expression
  tokenization inside `@{}` string interpolation segments. Foundation for I2-I5.

## [0.53.38] — 2026-04-27

### Added
- Per-command help: `orhon help build`, `orhon help run`, etc. `-help` anywhere
  in arguments dispatches to the relevant command help.

## [0.53.37] — 2026-04-27

### Added
- CI workflow on GitHub Actions: `./testall.sh` runs on push/PR to main via
  `mlugg/setup-zig@v1` with Zig 0.15.2.
- Versioning policy documented in `docs/versioning.md`.

## [0.53.36] — 2026-04-27

### Added
- `orhon addtopath` now creates a backup before editing, writes atomically via
  tmp→rename, and supports `-dry-run` to preview changes without writing.
  Already-in-PATH detection honours dry-run mode.

## [0.53.35] — 2026-04-27

### Added
- `orhon init -update` migration: re-writes example files when the stamped
  version differs from the running compiler version. User files are never
  touched.

## [0.53.34] — 2026-04-27

### Added
- `orhon check` command: runs passes 1-8 only (no MIR, no codegen, no Zig
  invocation). Fast path for syntax and type checking without full compilation.

## [0.53.33] — 2026-04-27

### Added
- `orhon.project` manifest format replacing inline `#build` directives. Supports
  single-target (`#build` top-level) and multi-target (`#target name` sections).

### Changed
- `#build` and `#version` directives in `.orh` files are now hard errors (E1013).

## [0.53.32] — 2026-04-27

### Changed
- CLI parser rewritten with table-driven comptime flag specifications. Flags
  normalized to single-dash space-separated format (`-werror`, `-diag-format`,
  `-color`, `-line-length`).

## [0.53.31] — 2026-04-26

### Changed
- Codegen `pre_stmts` replaced with stack-of-frames structure for interpolation
  hoisting. Codegen is fully ready for `@{}` expression support (I1-I5).

## [0.53.30] — 2026-04-26

### Added
- Source-location mapping from generated Zig output back to `.orh` files. Zig
  compiler errors now show `.orh` file locations instead of requiring manual
  reverse-mapping from `.orh-cache/generated/` paths.

## [0.53.28] — 2026-04-26

### Changed
- Unused import detection now uses resolver data (set lookup) instead of file
  I/O and substring matching. Faster and more accurate.

## [0.53.27] — 2026-04-26

### Changed
- `typeToZig` rewritten as a pure function over `ResolvedType` instead of
  dual AST-walking paths. Removed `anyopaque` fallbacks that silently masked
  codegen bugs.

## [0.53.25] — 2026-04-26

### Added
- Transitive cache invalidation: changing a module now recompiles all transitive
  dependents. Diamond-graph deduplication prevents redundant recompilation.

### Fixed
- Cache dependency map was loaded but never written, causing `dep_interface_changed`
  to always be false. Incremental cache now correctly tracks interface changes.

### Changed
- `writeZonCache` now writes to `.tmp` then atomically renames, preventing
  partial cache corruption.

## [0.53.23] — 2026-04-26

### Added
- `ModuleCompile` struct with per-module arena, laying the foundation for
  parallel compilation. Full pipeline now structured for per-module execution.

## [0.53.22] — 2026-04-26

### Added
- Property-based pipeline tests: `zig ast-check` validation and formatter
  idempotence checks across all golden fixtures (`test/14_props.sh`).

## [0.53.21] — 2026-04-26

### Added
- Performance baseline tests (`test/13_perf.sh`): times `orhon build` for all
  golden fixtures and reports per-fixture wall-time deltas vs. previous run.

## [0.53.17] — 2026-04-25

### Added
- Zig-based test runner (`test/runner.zig`) for negative test fixtures. Compiles
  each `fail_*.orh` fixture and matches diagnostic output against `//> [Exxxx]`
  inline annotations. Run via `zig build test-diag`.

## [0.53.14] — 2026-04-25

### Added
- Internal compiler error (ICE) handler: pipeline failures now print a
  human-readable message with issue-report URL and exit code 70 instead of
  leaking Zig stack traces.

## [0.53.13] — 2026-04-25

### Changed
- Source file contents are now cached in the reporter for faster diagnostic
  rendering. Source lines are read once and reused across all diagnostics.

## [0.53.12] — 2026-04-25

### Changed
- Reporter memory model: `reportFmt`/`warnFmt`/`noteFmt` now use single-allocation
  format path, eliminating double-allocation per diagnostic. `reportOwned` added
  for pre-allocated heap messages.

## [0.53.11] — 2026-04-25

### Added
- Warning gradient: diagnostics now carry `Severity` (`.err`, `.warning`, `.note`,
  `.hint`). Notes and hints attach to parent diagnostics.
- `-Werror` CLI flag: treats all warnings as hard errors.

## [0.53.10] — 2026-04-25

### Added
- `--color=auto|always|never` CLI flag. `NO_COLOR` environment variable respected.
  TTY detection gates ANSI escape codes automatically.

## [0.53.8] — 2026-04-25

### Added
- `--diag-format=json|human|short` CLI flag. JSON output mode for machine-readable
  diagnostics suitable for LSP, CI, and editor integration.

## [0.53.7] — 2026-04-25

### Added
- Error code catalog: 102 stable error codes (`[E0101]`, `[E2048]`, etc.) shown
  in every diagnostic. Error codes are the first argument to all reporter calls.

## [0.53.6] — 2026-04-24

### Added
- Real type parameter binder model: `ResolvedType` gains `.type_param` variant
  with explicit binder reference. Foundation for constraint checks (`T: Eq`) and
  better generic error messages.

## [0.53.5] — 2026-04-24

### Added
- Uniform shadowing detection: function parameters, `for` captures, and `match`
  arm bindings now check for shadowing in addition to `var` and `destruct`
  declarations.

## [0.53.4] — 2026-04-24

### Changed
- Resolver is now stateless: mutable per-instance fields (`current_node`,
  `loop_depth`, `current_return_type`, etc.) packed into `ResolveCtx` passed by
  value. Unblocks per-function and per-module parallelism.

## [0.53.0] — 2026-04-20

### Added
- Golden-file snapshot testing infrastructure: canonical `.orh` inputs produce
  `.ast.golden` and `.mir.golden` sidecars covering all language feature categories
  (compt, blueprints, generics, handles, interpolation, slicing, defer,
  ownership, borrow).
- AST and MIR pretty-printers for debug dumping.

### Changed
- Compiler architecture documentation (`docs/COMPILER.md`) updated to reflect
  new index-based AST/MIR storage.

## [0.51.8] — 2026-04-19

### Added
- Index-based AST storage (`AstStore`) replacing pointer-based tree. Uses
  struct-of-arrays pattern for cache-friendly traversal.
- Index-based MIR storage (`MirStore`) with `TypeStore` interned type
  representation and `StringPool` interned identifiers.
- Typed wrappers (`ast_typed.zig`, `mir_typed.zig`) providing structured access
  to SoA data per node kind.
- Codegen fully migrated to read from `MirStore` via `MirNodeIndex`.

### Removed
- Old pointer-based `parser.Node` tree, `MirNode` god struct, `MirAnnotator`,
  `MirLowerer`, and dual-output parity harness. All consumers now read from
  `AstStore` and `MirStore`.

## [0.50.0] — 2026-04-14

### Fixed
- **CB1**: Borrow checker method collision — two structs with same-named methods
  no longer use wrong `self` mutability.
- **CB2**: NLL borrow scope tracking — borrows crossing block boundaries now
  drop at correct scopes instead of the parent block's last use map.
- **CB3**: Generic type parameter detection — short-uppercase-named user types
  (`Vec3`, `Iter`, `Cell`) no longer silently classified as type parameters.
  Type-param identity now tied to explicit binder (`func foo<T>`).
- **CB4**: Error propagation reachability — `if`/`match`/`for`/`while` bodies
  returning unions are now visible to the propagation pass. Assignment tracking
  handles expression RHS beyond bare identifiers.
- **CB5**: Interface hash truncation — `[256][]const u8` fixed buffer replaced
  with growable list, eliminating false cache hits from symbol-dense interfaces.
- **CB6**: Parser error recovery — PEG grammar gains `^sync` markers at
  `func_decl`/`struct_decl`/statement boundaries. Parser records diagnostic and
  resumes at next sync point instead of aborting on first mismatch.
