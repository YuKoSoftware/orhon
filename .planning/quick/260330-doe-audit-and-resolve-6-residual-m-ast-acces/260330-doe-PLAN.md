---
phase: quick-260330-doe
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - src/codegen/codegen.zig
  - src/codegen/codegen_decls.zig
  - src/codegen/codegen_stmts.zig
  - src/codegen/codegen_exprs.zig
  - src/codegen/codegen_match.zig
  - src/mir/mir_node.zig
  - docs/TODO.md
autonomous: true
requirements: []
must_haves:
  truths:
    - "current_func_node AST field is eliminated — current_func_mir used everywhere"
    - "nodeLoc calls use a convenience wrapper accepting MirNode"
    - "type_expr/passthrough and typeToZig accesses are documented as permanent architectural boundary"
    - "All tests pass — no codegen regression"
  artifacts:
    - path: "src/codegen/codegen.zig"
      provides: "nodeLocMir convenience, current_func_node removed or dead"
    - path: "src/mir/mir_node.zig"
      provides: "MirNode unchanged (ast back-pointer retained for type trees)"
    - path: "docs/TODO.md"
      provides: "Updated MIR residual AST section with decision"
  key_links:
    - from: "src/codegen/codegen_decls.zig"
      to: "src/codegen/codegen.zig"
      via: "current_func_mir set instead of current_func_node"
      pattern: "current_func_mir = m"
---

<objective>
Audit and resolve the residual m.ast accesses in codegen. Migrate what can be migrated
(current_func_node tracking, nodeLoc indirection), document what stays as a permanent
architectural boundary (typeToZig/generateExpr on structural type trees).

Purpose: Clean separation between MIR-path and AST-path in codegen. Reduce the AST
back-pointer surface area to the minimum necessary.

Output: Fewer m.ast accesses, documented architectural boundary, updated TODO.md.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@docs/TODO.md
@src/codegen/codegen.zig
@src/codegen/codegen_decls.zig
@src/codegen/codegen_stmts.zig
@src/codegen/codegen_exprs.zig
@src/codegen/codegen_match.zig
@src/mir/mir_node.zig

## Audit Results — All m.ast Access Sites (10 call sites, 4 categories)

### Category 1: Source location queries (2 sites) — MIGRATE
- `codegen_stmts.zig:85` — `cg.nodeLoc(m.ast)` for var-not-reassigned warning
- `codegen_exprs.zig:248` — `cg.nodeLoc(m.ast)` for Version() misuse error

These just extract the AST pointer from MirNode to pass to `nodeLoc(*parser.Node)`.
Add a `nodeLocMir(*MirNode)` convenience that does `nodeLoc(m.ast)` internally,
so callers no longer reach into `.ast` directly.

### Category 2: current_func_node tracking (2 sites) — MIGRATE
- `codegen_decls.zig:110` — `cg.current_func_node = m.ast` (regular func_decl)
- `codegen_decls.zig:210` — `cg.current_func_node = m.ast` (test_def body func)

`current_func_node` is only used as fallback in `funcReturnTypeClass()` and
`funcReturnMembers()` when `current_func_mir` is null. These two sites should
set `current_func_mir = m` instead. The MirNode already carries `resolved_type`
and `type_class`. After migration, `current_func_node` field + its fallback
branches can be removed.

### Category 3: type_expr / passthrough (2 sites) — DOCUMENT AS BOUNDARY
- `codegen_exprs.zig:618` — `cg.generateExpr(m.ast)` for `.type_expr`
- `codegen_exprs.zig:619` — `cg.generateExpr(m.ast)` for `.passthrough`

These delegate to the AST-path `generateExpr` which walks the full AST type tree
(type_named, type_slice, type_array, type_union, type_ptr, type_func, etc.).
Duplicating this recursive tree structure into MirNode would be massive effort
for zero benefit — type trees are structural (syntax-to-syntax) translations.
Document as permanent boundary.

### Category 4: typeToZig / isEnumTypeName on child .ast (4 sites) — DOCUMENT AS BOUNDARY
- `codegen_stmts.zig:61` — `cg.typeToZig(m.value().ast)` for type alias value
- `codegen_decls.zig:816` — `cg.typeToZig(m.value().ast)` for top-level type alias
- `codegen_match.zig:583` — `cg.typeToZig(args[0].ast)` for cast() target type
- `codegen_match.zig:585` — `cg.isEnumTypeName(args[0].ast)` for cast() enum check

All go through `typeToZig(*parser.Node)` which recursively walks the AST type
tree (type_named, type_slice, type_array, type_union, type_ptr...). Same reason
as Category 3 — structural type trees stay on AST.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Migrate current_func_node to current_func_mir and add nodeLocMir</name>
  <files>
    src/codegen/codegen.zig
    src/codegen/codegen_decls.zig
    src/codegen/codegen_stmts.zig
    src/codegen/codegen_exprs.zig
  </files>
  <action>
**1a. Add `nodeLocMir` convenience method to CodeGen (codegen.zig):**

After the existing `nodeLoc` method (~line 184), add:

```zig
/// Source location from MirNode — convenience wrapper over nodeLoc.
pub fn nodeLocMir(self: *const CodeGen, m: *const mir.MirNode) ?errors.SourceLoc {
    return self.nodeLoc(m.ast);
}
```

**1b. Replace `cg.nodeLoc(m.ast)` with `cg.nodeLocMir(m)` at:**
- `codegen_stmts.zig:85`
- `codegen_exprs.zig:248`

**1c. Migrate current_func_node to current_func_mir in MIR-path func codegen:**

In `codegen_decls.zig`, at the two sites where `cg.current_func_node = m.ast`:
- Line 109-110: Change from saving/restoring `current_func_node` to saving/restoring `current_func_mir`. Set `cg.current_func_mir = m` instead of `cg.current_func_node = m.ast`.
- Line 209-210: Same change for test_def body function.
- Update the corresponding `defer` blocks to restore `current_func_mir` instead of `current_func_node`.

**1d. Remove the `current_func_node` field and its fallback branches (codegen.zig):**

- Remove `current_func_node: ?*parser.Node = null` field (~line 54).
- In `funcReturnTypeClass()` (~line 92-98): Remove the `if (self.current_func_node)` fallback block (lines 95-97). Keep only the `current_func_mir` check.
- In `funcReturnMembers()` (~line 101-112): Remove the `if (self.current_func_node)` fallback block (lines 106-110). Keep only the `current_func_mir` check.

**Important:** There are also `current_func_node` usages in the AST-path code at
codegen_decls.zig lines 354-355 and 459-460 which set `cg.current_func_node = node`
(taking a `*parser.Node`). These are in the legacy AST-path functions `generateFunc`
and `generateTestDef`, NOT the MIR-path functions. Check if these AST-path functions
are still called. If they are, keep `current_func_node` but make it ONLY used by the
AST path, and document it as AST-path-only. If they are dead code, remove them.

To check: grep for `generateFunc(` and `generateTestDef(` call sites (not the MIR
variants `generateFuncMir` and `generateTestDefMir`).
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -30</automated>
  </verify>
  <done>
    - `nodeLocMir` convenience exists, callers use it instead of `m.ast` directly
    - MIR-path func codegen sets `current_func_mir` instead of `current_func_node`
    - `current_func_node` either removed entirely or documented as AST-path-only
    - Compiler builds without errors
  </done>
</task>

<task type="auto">
  <name>Task 2: Document architectural boundary and update TODO.md</name>
  <files>
    src/mir/mir_node.zig
    src/codegen/codegen_exprs.zig
    docs/TODO.md
  </files>
  <action>
**2a. Update MirNode doc comment (mir_node.zig line 17-19):**

Replace the existing doc comment on the `ast` field with a more precise boundary description:

```zig
/// Original AST node — retained for two permanent uses:
/// 1. typeToZig() walks the recursive AST type tree (type_named, type_slice,
///    type_array, type_union, type_ptr, etc.) for structural syntax-to-syntax
///    translation. Duplicating this tree into MirNode adds complexity with no
///    benefit — type trees are purely structural.
/// 2. type_expr and passthrough MirKinds delegate to AST-path generateExpr()
///    for the same reason.
/// Source locations also read through ast, via nodeLocMir().
```

**2b. Add inline comments at the 6 remaining m.ast sites:**

At each of the 6 remaining `.ast` accesses (Categories 3+4), ensure there is a clear
comment explaining why AST is used. The existing comments at codegen_exprs.zig:618-619
are good. Add similar comments at:
- `codegen_stmts.zig:61` — `// type trees are structural — typeToZig walks AST`
- `codegen_decls.zig:816` — `// type trees are structural — typeToZig walks AST`
- `codegen_match.zig:583` — `// type trees are structural — typeToZig walks AST`
- `codegen_match.zig:585` — `// type trees are structural — isEnumTypeName reads AST`

**2c. Update docs/TODO.md MIR residual AST section (around line 97-101):**

Replace the current entry with a resolved version:

```
### ~~MIR — residual AST accesses~~ RESOLVED (v0.10.25)

~~6 `m.ast` reads remain in codegen.~~ Audited and resolved. 4 accesses migrated
to MIR (current_func_node → current_func_mir, nodeLoc → nodeLocMir). 6 accesses
remain as a **permanent architectural boundary**: `typeToZig()` and `generateExpr()`
for type_expr/passthrough nodes walk the recursive AST type tree (type_named,
type_slice, type_array, type_union, type_ptr). Duplicating this structural tree
into MirNode adds complexity with zero benefit — type trees are syntax-to-syntax
translations. MirNode.ast back-pointer is retained for this purpose.
```

Move this entry to the Done section at the bottom of the file.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -20</automated>
  </verify>
  <done>
    - MirNode.ast field has precise boundary documentation
    - All remaining m.ast sites have inline comments explaining why
    - TODO.md entry moved to Done with resolution summary
    - All 11 test stages pass
  </done>
</task>

</tasks>

<verification>
1. `zig build` succeeds — no compile errors from field removal / method changes
2. `./testall.sh` passes all 11 stages — no codegen regressions
3. `grep -c 'm\.ast' src/codegen/*.zig` shows reduced count (from 10 to 6)
4. `grep 'current_func_node' src/codegen/*.zig` shows zero hits (or AST-path-only)
5. `grep 'nodeLocMir' src/codegen/*.zig` shows the 2 migrated call sites
</verification>

<success_criteria>
- 4 m.ast accesses migrated away (2 nodeLoc, 2 current_func_node)
- 6 m.ast accesses documented as permanent boundary with inline comments
- current_func_node eliminated from MIR path (or removed entirely)
- MirNode.ast doc comment explains the boundary precisely
- TODO.md entry marked resolved and moved to Done
- All tests pass
</success_criteria>

<output>
After completion, create `.planning/quick/260330-doe-audit-and-resolve-6-residual-m-ast-acces/260330-doe-SUMMARY.md`
</output>
