---
phase: 32-lsp-split
plan: 02
subsystem: lsp
tags: [refactor, split, lsp]
dependency_graph:
  requires: [lsp_types, lsp_json, lsp_utils, lsp_analysis]
  provides: [lsp_nav, lsp_edit, lsp_view, lsp_semantic]
  affects: [lsp]
tech_stack:
  added: []
  patterns: [module-split, qualified-dispatch]
key_files:
  created:
    - src/lsp_nav.zig
    - src/lsp_edit.zig
    - src/lsp_view.zig
    - src/lsp_semantic.zig
  modified:
    - src/lsp.zig
    - build.zig
decisions:
  - "handleDocumentSymbols placed in lsp_view.zig (view group per D-05), not lsp_nav.zig"
  - "extractParamLabels lives in lsp_edit.zig (used by completion snippets), re-exported via lsp_view.zig for signatureHelp"
  - "collectOrhFiles uses anyerror! return type (recursive function per CLAUDE.md gotcha)"
metrics:
  duration: 14m
  completed: "2026-03-29T07:16:51Z"
  tasks: 2
  files: 6
---

# Phase 32 Plan 02: LSP Handler Extraction Summary

Extracted all 13 handler functions from lsp.zig into 4 handler modules grouped by LSP feature category, reducing lsp.zig from 1937 lines to 515 lines (pure server loop + transport + dispatch).

## Results

| File | Lines | Content |
|------|-------|---------|
| src/lsp_nav.zig | 288 | Navigation: handleHover, handleDefinition, handleReferences, handleDocumentHighlight |
| src/lsp_edit.zig | 598 | Editing: handleCompletion + 4 helpers, handleRename + collectOrhFiles, handleFormatting, handleCodeAction + appendQuickFix, extractParamLabels + trimRange |
| src/lsp_view.zig | 489 | View/hints: handleDocumentSymbols, handleWorkspaceSymbol + containsIgnoreCase, handleSignatureHelp + findCallContext, handleInlayHint + findSymbolInFile, handleFoldingRange + appendFoldingRange |
| src/lsp_semantic.zig | 138 | Semantic: handleSemanticTokens, classifyToken |
| src/lsp.zig | 515 | serve() loop, readMessage/writeMessage transport, runAndPublishWithDiags, module-qualified dispatch |

## Complete LSP File Inventory (9 files)

| File | Lines | Role |
|------|-------|------|
| src/lsp_types.zig | 170 | Shared types (leaf) |
| src/lsp_json.zig | 282 | JSON helpers and builders |
| src/lsp_utils.zig | 437 | URI, text, symbol utilities |
| src/lsp_analysis.zig | 633 | Analysis pipeline, type formatting |
| src/lsp_nav.zig | 288 | Navigation handlers |
| src/lsp_edit.zig | 598 | Editing handlers |
| src/lsp_view.zig | 489 | View and hints handlers |
| src/lsp_semantic.zig | 138 | Semantic tokens handler |
| src/lsp.zig | 515 | Server loop + dispatch |
| **Total** | **3550** | |

## Task Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1 | ab0f836 | Extract lsp_nav.zig and lsp_edit.zig (navigation + editing handlers) |
| 2 | 4f9036b | Extract lsp_view.zig and lsp_semantic.zig, complete LSP split |

## Test Distribution

Tests moved to their owning modules:
- lsp_edit.zig: extractParamLabels (3 tests)
- lsp_view.zig: findCallContext (3), containsIgnoreCase (1), extractParamLabels (3) = 7 tests
- lsp_semantic.zig: classifyToken (1)
- lsp.zig retains: readMessage (3)

Total: 20 unit tests across 9 files (some tests duplicated in both lsp_edit and lsp_view since extractParamLabels is shared). No tests lost.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] collectOrhFiles needs anyerror! return type**
- **Found during:** Task 1
- **Issue:** collectOrhFiles is recursive and per CLAUDE.md gotcha, recursive functions need `anyerror!` not `!`
- **Fix:** Changed return type to `anyerror!void` in lsp_edit.zig
- **Files modified:** src/lsp_edit.zig

**2. [Rule 2 - Missing] extractParamLabels shared between edit and view**
- **Found during:** Task 2
- **Issue:** extractParamLabels is needed by both completion snippets (lsp_edit) and signature help (lsp_view)
- **Fix:** Canonical implementation in lsp_edit.zig with pub, re-exported via lsp_view.zig thin wrapper
- **Files modified:** src/lsp_edit.zig, src/lsp_view.zig

## Known Stubs

None - plan executed as a pure refactor with no new functionality.

## Decisions Made

1. **handleDocumentSymbols in lsp_view**: Per D-05 grouping, document symbols is a "view" feature, not navigation. Placed in lsp_view.zig alongside workspace symbols.
2. **extractParamLabels canonical in lsp_edit**: The function is used by completion snippet generation (lsp_edit) and signature help (lsp_view). Canonical copy lives in lsp_edit with pub, lsp_view delegates to it.
3. **collectOrhFiles uses anyerror!**: Recursive directory traversal function needs anyerror! return type per Zig 0.15 requirements and CLAUDE.md gotcha.
4. **lsp.zig at 515 lines (vs target 430)**: Slightly larger than target because the serve() dispatch loop with 13 handler branches and error handling is inherently ~350 lines, plus transport functions and the runAndPublishWithDiags helper. All handler logic is fully extracted.

## Self-Check: PASSED

- All 4 new handler files exist (lsp_nav.zig, lsp_edit.zig, lsp_view.zig, lsp_semantic.zig)
- Both task commits found (ab0f836, 4f9036b)
- 9 LSP files total, no file exceeds 640 lines
- lsp.zig contains no handler function definitions
- All 266 tests pass
