# Phase 36: PEG Builder Split - Context

**Gathered:** 2026-03-29
**Status:** Ready for planning

<domain>
## Phase Boundary

Split `src/peg/builder.zig` (1836 lines) into focused satellite files mirroring the codegen split pattern from Phase 29. No behavior change — all tests must pass. The dispatch table stays centralized, satellite files contain the builder functions grouped by category.

</domain>

<decisions>
## Implementation Decisions

### Split granularity
- **D-01:** Split into 6 files total: `builder_decls.zig`, `builder_bridge.zig`, `builder_stmts.zig`, `builder_exprs.zig`, `builder_types.zig` (5 satellites), plus `builder.zig` as the hub
- **D-02:** `builder.zig` retains: BuildContext struct, SyntaxError, buildAST/buildASTWithArena entry points, buildNode dispatch function, shared helpers (tokenText, findTokenInRange, buildAllChildren, collectExprsRecursive, collectCallArgs, collectParamsRecursive, buildTokenNode, buildChildrenByRule)
- **D-03:** No single satellite file should exceed ~510 lines (per success criteria)

### File boundaries
- **D-04:** `builder_decls.zig` (~507 lines): buildProgram, buildModuleDecl, buildImport, buildMetadata, buildFuncDecl, buildParam, buildConstDecl, buildVarDecl, buildStructDecl, collectStructParts, hasPubBefore, buildEnumDecl, collectEnumMembers, buildFieldDecl, buildEnumVariant, buildDestructDecl, buildDestructFromTail, buildBitfieldDecl, buildTestDecl, buildPubDecl, buildComptDecl
- **D-04b:** `builder_bridge.zig` (~140 lines): buildBridgeDecl, buildBridgeFunc, buildBridgeConst, buildBridgeStruct, buildThreadDecl, setPub
- **D-05:** `builder_stmts.zig` (~210 lines): buildBlock, buildReturn, buildThrowStmt, buildIf, buildElifChain, buildWhile, buildFor, buildDefer, buildMatch, buildMatchArm, buildExprOrAssignment
- **D-06:** `builder_exprs.zig` (~350 lines): buildIntLiteral, buildFloatLiteral, buildStringLiteral, buildBoolLiteral, buildIdentifier, buildErrorLiteral, buildCompilerFunc, buildArrayLiteral, buildGroupedExpr, buildTupleLiteral, buildStructExpr, buildBinaryExpr, buildCompareExpr, buildRangeExpr, buildNotExpr, buildUnaryExpr, buildPostfixExpr
- **D-07:** `builder_types.zig` (~170 lines): buildNamedType, buildKeywordType, buildScopedType, buildScopedGenericType, buildGenericType, collectGenericArgs, buildBorrowType, buildRefType, buildParenType, buildSliceType, buildArrayType, buildFuncType

### Dispatch pattern
- **D-08:** Mirror the codegen split pattern exactly: `builder.zig` imports satellites as `const decls_impl = @import("builder_decls.zig")` etc. The `buildNode` dispatch calls satellite functions directly (e.g., `return decls_impl.buildProgram(ctx, cap)`)
- **D-09:** All satellite functions take `*BuildContext` as first parameter — BuildContext stays in `builder.zig` and satellites import it

### Test placement
- **D-10:** Tests stay in `builder.zig` since they test the integrated behavior through buildAST entry points. Moving tests to satellites would require re-exporting BuildContext and test helpers.

### Claude's Discretion
- Exact line where helpers end and satellite boundary begins
- Whether buildDestructFromTail stays with buildDestructDecl in decls or goes to stmts (recommendation: keep with decls since it's part of destructuring declaration logic)
- Whether collectStructParts stays in decls or moves to hub (recommendation: keep with decls since buildStructDecl is the primary caller)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Split pattern reference
- `src/codegen.zig` — Hub file pattern: imports, struct, dispatch methods delegating to satellites
- `src/codegen_decls.zig` — Satellite file pattern: imports parent types, standalone functions
- `src/codegen_stmts.zig` — Second satellite example

### Source file being split
- `src/peg/builder.zig` — The file to split (1836 lines, 60+ builder functions)

### Phase 29 artifacts
- `.planning/phases/29-codegen-split/` — Prior codegen split for reference on approach and lessons learned

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- Codegen split pattern (Phase 29): `codegen.zig` + 4 satellites — proven pattern to replicate
- `build.zig` test registration: already handles `src/peg/builder.zig` — will need satellite files added

### Established Patterns
- Satellite files live in same directory as hub (`src/peg/builder_*.zig`)
- Hub file keeps struct + dispatch + shared helpers
- Satellites are standalone functions that receive the context struct as first parameter
- All files registered in `build.zig` test suite

### Integration Points
- `src/peg/builder.zig` is imported by `src/peg/engine.zig` and `src/module.zig` via `@import("capture.zig")` chain
- Only `BuildContext`, `buildAST`, `buildASTWithArena`, `SyntaxError`, and `BuildResult` are the public API — satellites don't need to be pub-exported from builder.zig

</code_context>

<specifics>
## Specific Ideas

No specific requirements — follow the codegen split pattern established in Phase 29.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 36-peg-builder-split*
*Context gathered: 2026-03-29*
