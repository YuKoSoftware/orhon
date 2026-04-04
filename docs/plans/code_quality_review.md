# Code Quality Review Plan

## Status: In Progress (chunks 1-7 done, 8-15 remaining)

## Completed Chunks

### Chunk 1 — Core Infrastructure ✅
- src/types.zig (520 lines)
- src/constants.zig (29 lines)
- src/errors.zig (367 lines)
- src/builtins.zig (129 lines)
- src/cache.zig (873 lines)

### Chunk 2 — Parsing Layer ✅
- src/lexer.zig (931 lines)
- src/parser.zig (528 lines)
- src/orhon.peg
- src/peg.zig (448 lines)
- src/peg/engine.zig (515 lines)
- src/peg/grammar.zig (585 lines)
- src/peg/capture.zig (335 lines)
- src/peg/token_map.zig (145 lines)
- src/peg/builder.zig (609 lines)
- src/peg/builder_decls.zig (508 lines)
- src/peg/builder_exprs.zig (399 lines)

### Chunk 3 — Module Resolution & Semantic Analysis ✅
- src/module.zig (622 lines)
- src/module_parse.zig (443 lines)
- src/declarations.zig (703 lines)
- src/resolver.zig (1181 lines)
- src/resolver_exprs.zig (405 lines)
- src/resolver_validation.zig (349 lines)
- src/sema.zig (36 lines)
- src/scope.zig (111 lines)

### Chunk 4 — Ownership/Borrow/Analysis ✅
- src/ownership.zig (766 lines)
- src/ownership_checks.zig (285 lines)
- src/borrow.zig (892 lines)
- src/borrow_checks.zig (189 lines)
- src/propagation.zig (806 lines)

### Chunk 5 — MIR & Codegen ✅
- src/mir/mir.zig (15 lines)
- src/mir/mir_types.zig (85 lines)
- src/mir/mir_node.zig (241 lines)
- src/mir/mir_annotator.zig (719 lines)
- src/mir/mir_annotator_nodes.zig (369 lines)
- src/mir/mir_lowerer.zig (698 lines)
- src/mir/mir_registry.zig (108 lines)
- src/codegen/codegen.zig (820 lines)
- src/codegen/codegen_decls.zig (388 lines)
- src/codegen/codegen_exprs.zig (657 lines)
- src/codegen/codegen_match.zig (870 lines)

### Chunk 6 — Pipeline, CLI, Runner, Tools ✅
- src/pipeline.zig (809 lines)
- src/pipeline_build.zig (254 lines)
- src/pipeline_passes.zig (162 lines)
- src/cli.zig (259 lines)
- src/main.zig (131 lines)
- src/init.zig (109 lines)
- src/zig_runner/zig_runner.zig (393 lines)
- src/zig_runner/zig_runner_build.zig (161 lines)
- src/zig_runner/zig_runner_discovery.zig (59 lines)
- src/zig_runner/zig_runner_multi.zig (704 lines)
- src/formatter.zig (207 lines)
- src/docgen.zig (405 lines)
- src/syntaxgen.zig (522 lines)
- src/zig_docgen.zig (377 lines)
- src/std_bundle.zig (95 lines)

## Remaining Chunks

### Chunk 7 — Missed from earlier chunks
- src/codegen/codegen_stmts.zig (249 lines)
- src/peg/builder_stmts.zig (227 lines)
- src/peg/builder_types.zig (185 lines)
- src/commands.zig (359 lines)
- src/interface.zig (273 lines)
- src/fuzz.zig (133 lines)
- src/zig_module.zig (1397 lines)

### Chunk 8 — LSP Hub + Types
- src/lsp/lsp.zig (467 lines)
- src/lsp/lsp_types.zig (170 lines)
- src/lsp/lsp_json.zig (289 lines)

### Chunk 9 — LSP Features
- src/lsp/lsp_analysis.zig (593 lines)
- src/lsp/lsp_edit.zig (595 lines)
- src/lsp/lsp_nav.zig (285 lines)
- src/lsp/lsp_view.zig (486 lines)
- src/lsp/lsp_semantic.zig (137 lines)
- src/lsp/lsp_utils.zig (435 lines)

### Chunk 10 — Stdlib: Data Structures & Strings
- src/std/collections.zig (264 lines)
- src/std/string.zig (383 lines)
- src/std/sort.zig (79 lines)
- src/std/bitfield.zig (142 lines)
- src/std/ptr.zig (107 lines)

### Chunk 11 — Stdlib: Serialization
- src/std/json.zig (294 lines)
- src/std/xml.zig (363 lines)
- src/std/yaml.zig (508 lines)
- src/std/toml.zig (373 lines)
- src/std/csv.zig (157 lines)
- src/std/ini.zig (207 lines)

### Chunk 12 — Stdlib: IO & Network
- src/std/fs.zig (189 lines)
- src/std/http.zig (191 lines)
- src/std/net.zig (114 lines)
- src/std/stream.zig (114 lines)
- src/std/console.zig (87 lines)
- src/std/tui.zig (723 lines)

### Chunk 13 — Stdlib: Math, Crypto, System
- src/std/math.zig (168 lines)
- src/std/crypto.zig (201 lines)
- src/std/random.zig (78 lines)
- src/std/simd.zig (105 lines)
- src/std/encoding.zig (103 lines)
- src/std/compression.zig (98 lines)

### Chunk 14 — Stdlib: Concurrency & Testing
- src/std/thread.zig (137 lines)
- src/std/allocator.zig (170 lines)
- src/std/system.zig (199 lines)
- src/std/time.zig (205 lines)
- src/std/testing.zig (73 lines)
- src/std/regex.zig (478 lines)

### Chunk 15 — Templates & Orh Files
- src/std/linear.orh (312 lines)
- src/templates/project.orh (11 lines)
- src/templates/example/example.orh (284 lines)
- src/templates/example/control_flow.orh (214 lines)
- src/templates/example/data_types.orh (180 lines)
- src/templates/example/error_handling.orh (101 lines)
- src/templates/example/strings.orh (113 lines)
- src/templates/example/advanced.orh (214 lines)
- src/templates/example/blueprints.orh (39 lines)
