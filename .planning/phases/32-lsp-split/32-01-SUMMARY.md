---
phase: 32-lsp-split
plan: 01
subsystem: lsp
tags: [refactor, split, lsp]
dependency_graph:
  requires: []
  provides: [lsp_types, lsp_json, lsp_utils, lsp_analysis]
  affects: [lsp]
tech_stack:
  added: []
  patterns: [module-split, convenience-aliases]
key_files:
  created:
    - src/lsp_types.zig
    - src/lsp_json.zig
    - src/lsp_utils.zig
    - src/lsp_analysis.zig
  modified:
    - src/lsp.zig
    - build.zig
decisions:
  - "Convenience aliases in lsp.zig for all moved functions — avoids qualifying every call in serve() and handlers"
  - "lspLog in lsp_utils.zig (not lsp.zig) to avoid circular imports between lsp.zig and lsp_analysis.zig"
  - "formatType uses anyerror! return type (recursive function per CLAUDE.md gotcha)"
  - "extractSymbols and extractLocals use anyerror! return type (recursive functions)"
metrics:
  duration: 19m
  completed: "2026-03-29T06:59:14Z"
  tasks: 2
  files: 6
---

# Phase 32 Plan 01: LSP Foundation Module Extraction Summary

Split lsp.zig (3303 lines) into 4 foundation modules plus a reduced lsp.zig (1937 lines) retaining serve loop, transport, dispatch, and handler functions.

## Results

| File | Lines | Content |
|------|-------|---------|
| src/lsp_types.zig | 170 | Shared types: Diagnostic, SymbolInfo, SymbolKind, AnalysisResult, CompletionItemKind, SemanticTokenType, SemanticModifier, SemanticToken, TokenClassification, ParamLabels, CallContext, TrimResult, PublishResult, MAX_PARAMS, MAX_HEADER_LINE, MAX_CONTENT_LENGTH |
| src/lsp_json.zig | 282 | JSON helpers (jsonStr/jsonObj/jsonInt/jsonArray/jsonBool/jsonId), serialization (writeJsonValue/appendJsonString/appendInt), response builders (buildInitializeResult, buildEmptyResponse, buildEmptyArrayResponse, buildDiagnosticsMsg, buildHoverResponse, buildDefinitionResponse, buildDocumentSymbolsResponse) |
| src/lsp_utils.zig | 437 | lspLog, URI helpers (getDocSource, uriToPath, pathToUri, findProjectRoot), text utilities (getWordAtPosition, isIdentChar, getDotContext, getLinePrefix, getDotPrefix, getModuleName, getImportedModules, isVisibleModule), symbol lookup (findSymbolByName, findVisibleSymbolByName, findSymbolInContext, isOnModuleLine, isModuleName, builtinDetail) |
| src/lsp_analysis.zig | 633 | Type formatting (formatType, formatFuncSig, formatStructSig, formatEnumSig), analysis pipeline (runAnalysis, extractSymbols, extractLocals, toDiagnostics, makeDiag), helpers (nodeTypeStr, nodeLocInfo, makeUri) |
| src/lsp.zig | 1937 | serve() loop, readMessage/writeMessage transport, runAndPublishWithDiags, all handler functions (hover, definition, completion, references, rename, signatureHelp, formatting, workspaceSymbol, inlayHint, codeAction, documentHighlight, foldingRange, semanticTokens) |

## Import Dependency Graph (no cycles)

```
lsp_types.zig  (leaf — no lsp_* imports)
    ^
    |
lsp_json.zig   (imports lsp_types)
    ^
    |
lsp_utils.zig  (imports lsp_types)
    ^
    |
lsp_analysis.zig (imports lsp_types, lsp_utils)
    ^
    |
lsp.zig        (imports all 4 lsp_* modules)
```

## Task Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | 8709498 | Extract lsp_types.zig and lsp_json.zig (leaf modules) |
| 2 | 72002c6 | Extract lsp_utils.zig and lsp_analysis.zig (mid-level modules) |

## Test Distribution

Tests moved to their owning modules:
- lsp_json.zig: appendJsonString test (1)
- lsp_utils.zig: uriToPath (2), findProjectRoot (1), getWordAtPosition (2), isIdentChar (1) = 6 tests
- lsp_analysis.zig: runAnalysis arena (1), runAnalysis accumulation (1) = 2 tests
- lsp.zig retains: readMessage (3), findCallContext (3), containsIgnoreCase (1), extractParamLabels (3), classifyToken (1) = 11 tests

Total: 20 unit tests across 5 files (unchanged from before).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] formatType needs anyerror! return type**
- **Found during:** Task 2
- **Issue:** formatType is recursive and per CLAUDE.md gotcha, recursive functions need `anyerror!` not `!`
- **Fix:** Changed return type to `anyerror![]u8` in lsp_analysis.zig
- **Files modified:** src/lsp_analysis.zig

**2. [Rule 1 - Bug] extractSymbols and extractLocals need anyerror!**
- **Found during:** Task 2
- **Issue:** These functions are recursive (extractLocals calls itself for nested blocks)
- **Fix:** Changed return types to `anyerror!void` in lsp_analysis.zig
- **Files modified:** src/lsp_analysis.zig

## Known Stubs

None - plan executed as a pure refactor with no new functionality.

## Decisions Made

1. **Convenience aliases over qualified names**: lsp.zig uses `const runAnalysis = lsp_analysis.runAnalysis;` pattern for all moved functions, keeping handler code unchanged and readable.
2. **lspLog in lsp_utils**: Per research recommendation, lspLog lives in lsp_utils.zig to avoid circular imports (lsp_analysis needs lspLog, lsp.zig needs lsp_analysis).
3. **SemanticModifier as struct with pub consts**: The original used `const` inside a struct for bit flags. Made fields `pub` in lsp_types.zig so they're accessible from lsp.zig.

## Self-Check: PASSED

- All 4 new files exist
- Both task commits found (8709498, 72002c6)
- SUMMARY.md exists
- All 266 tests pass
