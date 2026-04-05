# Test Coverage Review Plan

## Status: COMPLETE (all 15 chunks done)

## Overview

- **Current test count**: 298 (511 unit test blocks + 11 shell integration scripts)
- **Files with unit tests**: 63 of 97 `.zig` files
- **Files without unit tests**: 34 `.zig` files
- **Integration tests**: `test/01_unit.sh` through `test/11_errors.sh` (1617 lines total)
- **Test fixtures**: 30+ `.orh` files in `test/fixtures/`
- **Snapshot tests**: 4 codegen snapshots in `test/snapshots/`

## What to Review

For each chunk, the agent should:
1. Read the source files and their existing tests
2. Identify untested public functions and code paths
3. Check for missing edge cases and negative tests
4. Verify test-spec alignment (tests match language spec in `docs/`)
5. Report findings — do NOT write tests, only list gaps

## Chunks

### Chunk 1 — Lexer & Token Map ✅

**Source**: `src/lexer.zig`, `src/peg/token_map.zig`
**Existing tests**: Both have test blocks

**Review focus**:
- All token kinds have at least one lexing test
- Edge cases: empty input, max-length identifiers, nested string escapes
- Numeric literal formats: hex, binary, octal, float with exponent
- Error tokens: unterminated strings, invalid escapes

**Added**: 12 tests — invalid prefix literals, unterminated strings (newline + EOF), EOF in escape, `mut` as identifier, column tracking, number before `..` and `.x`, `@`/`#`/`%=` tokens

---

### Chunk 2 — PEG Engine & Grammar ✅

**Source**: `src/peg.zig`, `src/peg/engine.zig`, `src/peg/grammar.zig`, `src/peg/capture.zig`
**Existing tests**: All have test blocks

**Review focus**:
- Engine: memoization correctness, backtracking, left recursion handling
- Grammar: every grammar rule exercised, ambiguous rule detection
- Capture: tree construction, nested captures, empty captures

**Added**: 13 tests — positive lookahead (match, fail, non-consumption), token_text matching, repeat1, unknown rule, matchAll partial, memoization (success + failure), grammar `&`/`!` prefix nodes, empty grammar, token_text node

**Deferred gaps** (covered indirectly by integration tests):
- capture.zig `evalSequence` backtracking — partial children discarded on failure
- capture.zig `evalChoice` backtracking — same issue
- capture.zig `captureProgram` rejection of partial match
- engine.zig `getError` with empty token stream
- engine.zig zero-length match guard in `evalRepeat`

---

### Chunk 3 — AST Builder ✅

**Source**: `src/peg/builder.zig`, `src/peg/builder_decls.zig`, `src/peg/builder_exprs.zig`, `src/peg/builder_stmts.zig`, `src/peg/builder_types.zig`
**Existing tests**: Only `builder.zig` has tests; 4 satellites have none

**Review focus**:
- Every `NodeKind` has a builder path that's tested
- Missing builder satellites coverage (decls, exprs, stmts, types)
- Malformed capture trees produce clean errors not crashes

**Added**: 7 tests — string interpolation, postfix index, `is` type check, match guard, union type, enum decl

**Deferred gaps** (covered by integration tests):
- `buildExprOrAssignment` compound assignment operators
- `buildElifChain` deep nesting
- `buildDestructDecl` name-splitting
- `buildFor` index variable pop-last convention
- `collectCallArgs` named vs positional arguments
- Malformed capture tree error paths

---

### Chunk 4 — Parser & Module Resolution ✅

**Source**: `src/parser.zig`, `src/module.zig`, `src/module_parse.zig`, `src/scope.zig`
**Existing tests**: `module.zig` and `scope.zig` have tests; `parser.zig` and `module_parse.zig` do not

**Review focus**:
- AST node creation and field access
- Module resolution: circular imports, missing modules, multi-file modules
- File offset resolution (resolveFileLoc)
- Scope push/pop, variable shadowing

**Added**: 13 tests — Operator.parse (all 27 + unknown), Operator.toZig round-trip, isComparison, MetadataField.parse, parseBuildType, formatExpectedSet (1 and 2 items), readModuleName (comment, no module), extractVersion (wrong count)

**Deferred gaps**:
- Circular import integration test fixture (no `fail_circular.orh`)
- `module_parse.zig` parse error formatting branches (4 distinct message formats)
- `formatExpectedSet` with 3+ items (Oxford comma)
- Unknown import scope / unknown `#build` type negative tests

---

### Chunk 5 — Declarations & Type Resolution ✅

**Source**: `src/declarations.zig`, `src/interface.zig`, `src/sema.zig`, `src/resolver.zig`, `src/resolver_exprs.zig`, `src/resolver_validation.zig`
**Existing tests**: `declarations.zig` and `resolver.zig` have tests; 4 files have none

**Review focus**:
- All declaration kinds collected (func, struct, enum, const, var, blueprint)
- Generic type resolution, type aliases, union types
- Cross-module imports resolved correctly
- Validation: duplicate names, type mismatches, invalid constructs

**Added**: 47 tests:
- `interface.zig` (17): formatType for all 12 type variants (primitive, named, slice, array, ptr const/mut, union, generic, func, tuple named/anon, unknown fallback), emitInterfaceDecl for pub func, private func skip, pub struct, pub enum, pub var
- `declarations.zig` (6): blueprint collection, type alias registration, struct methods map, field name conflict, duplicate field name, hasDecl
- `resolver.zig` (24): typesCompatible (7 cases: same primitive, mismatch, numeric/float literal, int-to-int, float-to-float, union member, func_ptr, type param), typesMatchWithSubstitution (4 cases: blueprint→struct, non-self, primitive, ptr), inferCaptureType (string→u8, slice→elem), isTypeParam (positive + negative), isLiteralCompatible, error paths (any-as-field, any-return-no-param, duplicate else, else-not-last, variable shadowing, reference-type-in-var)

**Deferred gaps**:
- `resolver_exprs.zig` / `resolver_validation.zig` — satellites with no test blocks (covered indirectly through hub tests)
- `++` on numeric types, arithmetic on strings, named args on non-struct — expression-level errors covered by Zig backend
- `sema.zig` — 36-line thin struct, implicitly tested by every resolver test

---

### Chunk 6 — Ownership & Borrow Checking ✅

**Source**: `src/ownership.zig`, `src/ownership_checks.zig`, `src/borrow.zig`, `src/borrow_checks.zig`, `src/propagation.zig`
**Existing tests**: `ownership.zig` (15), `borrow.zig` (22), `propagation.zig` (11) have tests; `*_checks.zig` satellites have none

**Review focus**:
- Move semantics: use-after-move, double move, move in loop
- Borrow rules: mut& exclusion, const& coexistence, borrow lifetime
- Error propagation: throw narrowing, error union validation
- Cross-reference with `test/fixtures/fail_ownership.orh` and `fail_borrow.orh`

**Added**: 6 tests:
- `ownership.zig` (3): return marks non-primitive as moved, throw use-after-move detection, inferIterableElemPrimitive (range, array, call, identifier primitiveness)
- `borrow.zig` (3): isMutableBorrowType (null, const_ref, mut_ref, non-ptr), lookupStructMethod (found + not found), removeLastBorrow (found + non-existent)

**Deferred gaps**:
- `ownership_checks.zig` / `borrow_checks.zig` — satellites with no test blocks, covered through hub file tests that call delegated methods
- `propagation.zig` — already has 11 tests covering core paths; remaining gaps (throw on non-union, nested unsafe unwrap, blockHasEarlyExit) are low-risk

---

### Chunk 7 — MIR Annotation & Lowering ✅

**Source**: `src/mir/mir.zig`, `src/mir/mir_types.zig`, `src/mir/mir_node.zig`, `src/mir/mir_annotator.zig`, `src/mir/mir_annotator_nodes.zig`, `src/mir/mir_lowerer.zig`, `src/mir/mir_registry.zig`
**Existing tests**: `mir_types.zig` (3), `mir_annotator.zig` (13), `mir_registry.zig` (2) have tests; 4 files have none

**Review focus**:
- Every NodeKind annotated by MIR
- TypeClass coverage: all variants exercised
- NodeMap population completeness
- Union registry: flattening, dedup, tag generation

**Added**: 18 tests:
- `mir_node.zig` (11): child accessors — body, condition, thenBlock, elseBlock (present/absent), lhs/rhs, callArgs/getCallee, params (with body, empty), defaultChild (field_def, non-field, empty), matchArms/pattern, guard (present/absent)
- `mir_types.zig` (2): classifyType for ptr, classifyType for unknown/inferred
- `mir_annotator.zig` (5): isNonPrimitiveType (primitive, unknown, named, generic value/non-value), typesMatch (primitive, named, generic, cross-category), detectCoercion for array_to_slice, numeric literal to union, float literal to union, null literal to null-containing union

**Deferred gaps**:
- `mir_lowerer.zig` — all functions are private; testable only through `lower()` which requires full pipeline setup. Covered by integration tests.
- `mir_annotator_nodes.zig` — satellite with no test blocks; covered through hub tests and integration tests.
- `arb_union_cross` / `arb_union_inferred` runtime tests — exist in tester.orh but cause cross-module union codegen bug. Cannot add to tester_main.orh until bug is fixed.

---

### Chunk 8 — Code Generation ✅

**Source**: `src/codegen/codegen.zig`, `src/codegen/codegen_decls.zig`, `src/codegen/codegen_exprs.zig`, `src/codegen/codegen_stmts.zig`, `src/codegen/codegen_match.zig`
**Existing tests**: Only `codegen.zig` has 1 test; 4 satellites have none
**Snapshot tests**: `test/snapshots/` (4 scenarios)

**Review focus**:
- Generated Zig compiles for all language constructs
- Match codegen: enum match, string match, range match, guard match, union match
- Snapshot test coverage vs actual language features
- Missing snapshots for newer features (blueprints, unions, generics)

**Added**: 19 tests:
- `codegen.zig` (10): typeToZig for Error, error union (Error|T), null union (null|T), ptr const/mut, array, generic, tuple named, Self in struct; sanitizeErrorName (5 edge cases); extractValueType for error/null unions and non-union
- `codegen_exprs.zig` (2): matchesKind (int/float/string/bool/negatives), findMemberByKind (found/not found/null)
- `codegen_match.zig` (7): isResultValueField (value/primitives/unknown, with decl table), mapWrappingOp/mapSaturatingOp/mapOverflowBuiltin (all ops + null for unsupported), mirContainsIdentifier (leaf/nested/not found), hasGuardedArm (with/without guard)

**Deferred gaps**:
- `codegen_decls.zig` / `codegen_stmts.zig` — statement/decl generators require full CodeGen setup; covered by integration + snapshot tests
- Snapshot expansion for match guards, generics, compiler functions — low priority, runtime tests cover correctness

---

### Chunk 9 — Pipeline & CLI ✅

**Source**: `src/pipeline.zig`, `src/pipeline_passes.zig`, `src/pipeline_build.zig`, `src/cli.zig`, `src/main.zig`, `src/init.zig`, `src/commands.zig`
**Existing tests**: `pipeline_build.zig` (5) and `cli.zig` (1) have tests; 5 files have none
**Shell tests**: `test/03_cli.sh`, `test/04_init.sh`, `test/05_compile.sh`

**Review focus**:
- CLI flag combinations tested
- Pipeline pass ordering and error gating
- Incremental compilation: cache hit/miss paths
- Init scaffolding: all files created, correct content

**Added**: 3 tests:
- `cli.zig` (2): toZigTriple (all 8 targets), folderName (all 8 targets)
- `test/03_cli.sh` (1): `orhon version` prints version number

**Deferred gaps**:
- `pipeline.zig` — 400+ line orchestrator, tested end-to-end by compile/library/multimodule shell tests
- `mergeZonConfigs()` — C interop config merging, no test (niche feature)
- `commands.zig` — `analysis`, `gendoc`, `build -zig` untested (secondary commands)
- `init.zig` — name validation for special characters not tested

---

### Chunk 10 — Zig Runner & Build ✅

**Source**: `src/zig_runner/zig_runner.zig`, `src/zig_runner/zig_runner_build.zig`, `src/zig_runner/zig_runner_discovery.zig`, `src/zig_runner/zig_runner_multi.zig`
**Existing tests**: `zig_runner.zig` (2), `zig_runner_discovery.zig` (1), `zig_runner_multi.zig` (13) have tests; `zig_runner_build.zig` had none
**Shell tests**: `test/06_library.sh`, `test/07_multimodule.sh`

**Review focus**:
- Build script generation for all target types (exe, lib, staticlib, dynlib)
- Multi-module linking order
- Zig discovery: PATH fallback, adjacent binary
- Cross-compilation targets

**Added**: 12 tests:
- `zig_runner_build.zig` (12): sanitizeHeaderStem (basic, with path, hpp, no extension, multiple dots), emitLinkLibs (two libs, empty), emitIncludePath, emitCSourceFiles (cpp with flags, c without flags, empty, needs_cpp flag)

**Deferred gaps**:
- `reformatNoMember` — private method on ZigRunner, can't unit test directly
- `generateSharedCImportFiles` — filesystem dependency, tested indirectly through multi-module integration
- C interop end-to-end — requires system C libraries, covered by unit tests on generated content

---

### Chunk 11 — Zig Module Interop & Cache ✅

**Source**: `src/zig_module.zig`, `src/cache.zig`, `src/std_bundle.zig`
**Existing tests**: `zig_module.zig` (37) and `cache.zig` (12) have tests; `std_bundle.zig` has none

**Review focus**:
- Zig-to-Orhon type mapping completeness
- `.zon` dependency file parsing
- Cache invalidation: timestamp comparison, dependency graph changes
- Stdlib bundle extraction and versioning

**Added**: 6 tests:
- `zig_module.zig` (3): extractConst negated number literal, pub var skipped, enum skipped
- `cache.zig` (3): hashInterface with field type change (f32→f64 detected), hashInterface with slice type (deterministic), hashInterface with named type change (Widget→Gadget detected)

**Deferred gaps**:
- `std_bundle.zig` — no tests, but skip-if-exists behavior is simple I/O; covered by init integration test
- `loadWarnings`/`saveWarnings`, `loadHashes`/`saveHashes` roundtrips — filesystem-dependent, covered by compile integration tests
- `scanZigImports` — filesystem-dependent, covered indirectly by multi-module tests
- `moduleNeedsRecompile` — complex but tested end-to-end by incremental compile tests

---

### Chunk 12 — Tools (Formatter, Docgen, Fuzz) ✅

**Source**: `src/formatter.zig`, `src/docgen.zig`, `src/syntaxgen.zig`, `src/zig_docgen.zig`, `src/fuzz.zig`
**Existing tests**: `formatter.zig` (5), `syntaxgen.zig` (1), `zig_docgen.zig` (1) have tests; `docgen.zig` and `fuzz.zig` have none

**Review focus**:
- Formatter idempotency (format twice = same result)
- Docgen: all declaration kinds produce output
- Fuzz: coverage of parser error paths

**Added**: 10 tests:
- `formatter.zig` (4): empty input, no trailing newline → adds one, blank line after imports block, idempotency (format twice = same)
- `zig_docgen.zig` (6): extractDecls pub fn, non-pub skipped, pub const, getDocComment single line, multi-line, no doc comment

**Deferred gaps**:
- `docgen.zig` — zero tests; AST traversal + type rendering for project API docs. Low usage priority.
- `fuzz.zig` — standalone binary, not run by test suite. Compile-only smoke test would suffice.
- `syntaxgen.zig` — test only checks file creation, not content. Static string, low risk.
- `orhon fmt` / `orhon gendoc` CLI integration — noted in TODO under "Untested CLI commands"

---

### Chunk 13 — LSP Server ✅

**Source**: `src/lsp/lsp.zig`, `src/lsp/lsp_types.zig`, `src/lsp/lsp_json.zig`, `src/lsp/lsp_analysis.zig`, `src/lsp/lsp_nav.zig`, `src/lsp/lsp_edit.zig`, `src/lsp/lsp_view.zig`, `src/lsp/lsp_semantic.zig`, `src/lsp/lsp_utils.zig`
**Existing tests**: 7 of 9 files have tests (21 total); `lsp_types.zig` and `lsp_nav.zig` have none

**Review focus**:
- LSP method dispatch coverage
- Hover, completion, goto-definition, rename
- Diagnostic publishing on parse/type errors
- Malformed JSON-RPC handling

**Added**: 18 tests:
- `lsp_utils.zig` (10): pathToUri, getDotContext (with/without dot), getDotPrefix (with/without), getModuleName (found/not found/empty), getImportedModules (two imports, no imports), getLinePrefix
- `lsp_json.zig` (5): jsonStr, jsonInt, jsonBool, jsonObj nested, extractTextDocumentUri (found + missing)
- `lsp_semantic.zig` (3): classifyToken operators, hash as keyword, punctuation has no type

**Bug found**: `handleFoldingRange` uses fixed 256-entry brace stack with no bounds check — logged in TODO.

**Deferred gaps**:
- `lsp_types.zig` / `lsp_nav.zig` — no tests; types file is pure data structs, nav handlers need full LSP context
- `lsp_analysis.zig` — `extractSymbols`, `formatType` untested; drives all LSP features but requires full pipeline
- `lsp_edit.zig` — completion/rename handlers need mock doc store
- `lsp_view.zig` — foldingRange, inlayHint, signatureHelp untested
- Zero LSP integration tests (no stdin/stdout test harness)

---

### Chunk 14 — Integration Tests & Fixtures ✅

**Source**: `test/03_cli.sh` through `test/11_errors.sh`, `test/fixtures/*.orh`, `test/snapshots/`
**No Zig source** — pure test infrastructure review

**Review focus**:
- Shell test coverage vs compiler features
- Missing negative test fixtures (compare `fail_*.orh` list against error categories)
- Snapshot staleness: do expected outputs match current codegen?
- Runtime test (`test/10_runtime.sh`) coverage of tester.orh features
- Language test (`test/09_language.sh`) coverage of example module features

**Added**: 2 missing runtime test verifications added to `test/10_runtime.sh`:
- `const_borrow_arg` and `negative_literal_args` — existed in tester_main.orh but were not checked by the test loop

**Deferred gaps**:
- 10 uncalled tester functions (color_to_int, do_side_effect, etc.) — helper functions, not standalone tests
- 12 error categories lack negative fixtures — noted in TODO under "Missing negative test fixtures"
- Snapshot expansion for enums, unions, generics — low priority, runtime tests cover correctness

---

### Chunk 15 — Stdlib Unit Tests ✅

**Source**: All `src/std/*.zig` files (29 files)
**Existing tests**: 26 of 29 files have tests; `console.zig`, `ptr.zig`, `simd.zig` do not

**Review focus**:
- API surface coverage: every pub function tested
- Edge cases: empty inputs, OOM paths, boundary values
- Parser modules (regex, yaml, toml, xml, csv, ini): malformed input handling
- Network modules (http, net): error path coverage
- Thread safety in concurrent modules

**Added**: 15 tests:
- `math.zig` (7): pow, log/exp roundtrip, log2, log10, sin/cos identity, pi/e constants, inf
- `sort.zig` (4): floatAsc, floatDesc, strAsc, reverse
- `collections.zig` (4): List set/remove, List pop, Map keys/values, Map remove

**Deferred gaps**:
- `console.zig`, `ptr.zig`, `simd.zig` — zero tests; console is I/O-dependent, ptr/simd need runtime verification
- `thread.zig` — zero tests; concurrency primitives hard to unit test deterministically
- `collections.zig` — withAlloc variants untested
- Parser modules (csv, ini, toml, yaml, xml) — no malformed input tests
- `tui.zig` — terminal I/O functions untested (require terminal)

---

## Files Without Any Unit Tests (34 total)

These need the most attention:

**Core compiler** (likely tested indirectly via integration):
- `parser.zig`, `module_parse.zig`, `sema.zig`
- `resolver_exprs.zig`, `resolver_validation.zig`
- `ownership_checks.zig`, `borrow_checks.zig`
- `mir.zig`, `mir_node.zig`, `mir_annotator_nodes.zig`, `mir_lowerer.zig`
- `codegen_decls.zig`, `codegen_exprs.zig`, `codegen_stmts.zig`, `codegen_match.zig`
- `pipeline.zig`, `pipeline_passes.zig`

**Tools & infra** (may need direct tests):
- `main.zig`, `init.zig`, `commands.zig`, `constants.zig`
- `interface.zig`, `docgen.zig`, `fuzz.zig`
- `std_bundle.zig`, `zig_runner_build.zig`
- `lsp_types.zig`, `lsp_nav.zig`

**Stdlib** (should have tests):
- `console.zig`, `ptr.zig`, `simd.zig`, `thread.zig`

**Satellites** (tested through hub files):
- `builder_decls.zig`, `builder_exprs.zig`, `builder_stmts.zig`, `builder_types.zig`
