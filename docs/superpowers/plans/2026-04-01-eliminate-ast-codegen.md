# Eliminate AST-Path Expression Codegen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the last 2 MIR→AST crossovers in codegen so `generateExpr` (AST-path expression dispatcher) and all AST-only codegen functions become dead code and can be deleted.

**Architecture:** Two crossovers exist where MIR-path codegen falls back to AST nodes: struct field defaults (`codegen_decls.zig`) and function param defaults (`codegen_match.zig`). Both store `?*parser.Node` AST pointers that get passed to `generateExpr`. Fix both by lowering default value expressions to MirNode children in the MIR lowerer, then emit via `generateExprMir`. Once no MIR-path code calls `generateExpr`, delete the entire AST-path expression codegen (~750 lines).

**Tech Stack:** Zig 0.15.2, existing MIR lowerer + codegen infrastructure.

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `src/mir/mir_lowerer.zig` | Modify | Lower default values to MirNode children for `.param` and `.field_decl` |
| `src/mir/mir_node.zig` | Modify | Remove `default_value` AST field, add `defaultChild()` accessor |
| `src/codegen/codegen_decls.zig` | Modify | Use `generateExprMir` for struct field defaults |
| `src/codegen/codegen_match.zig` | Modify | Rewrite `fillDefaultArgsMir` to use MIR params; delete AST-only functions |
| `src/codegen/codegen_stmts.zig` | Modify | Delete `generateExpr` and all AST-only helpers |
| `src/codegen/codegen_exprs.zig` | Modify | Delete `generateInterpolatedString` (AST-path) |
| `src/codegen/codegen.zig` | Modify | Delete AST-only hub wrappers, `emitTypePath`, `isStringExpr` |

---

### Task 1: Lower field_decl defaults to MirNode children

**Files:**
- Modify: `src/mir/mir_lowerer.zig:99-101` (struct_decl case) and `:569-574` (field_decl populateData)
- Modify: `src/mir/mir_node.zig:77-78` (default_value field)

Currently `field_decl` in `lowerNode()` has no case — struct members are lowered via `lowerSlice(s.members)` which calls `lowerNode` for each, but `field_decl` falls through without creating children. The `populateData()` case copies the AST pointer to `m.default_value`.

- [ ] **Step 1: Add `.field_decl` case to `lowerNode()` in mir_lowerer.zig**

In `lowerNode()`, add a case before the `populateData()` call handles it. The field_decl needs its default value lowered as a child:

```zig
// In lowerNode(), inside the switch(node.*) block, after .struct_decl case:
.field_decl => |f| {
    if (f.default_value) |dv| {
        var children = std.ArrayListUnmanaged(*MirNode){};
        try children.append(self.allocator, try self.lowerNode(dv));
        mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
    }
},
```

- [ ] **Step 2: Remove `default_value` copy from `populateData()` in mir_lowerer.zig**

In `populateData()`, remove line 573 (`m.default_value = f.default_value;`):

```zig
.field_decl => |f| {
    m.name = f.name;
    m.is_pub = f.is_pub;
    m.type_annotation = f.type_annotation;
    // default_value is now a lowered child, not an AST pointer
},
```

- [ ] **Step 3: Add `defaultChild()` accessor to mir_node.zig**

Add after the existing `params()` accessor:

```zig
/// First child as default value (for field_def and param kinds with defaults).
pub fn defaultChild(self: *const MirNode) ?*MirNode {
    if (self.kind == .field_def or self.kind == .param) {
        if (self.kind == .field_def) return if (self.children.len > 0) self.children[0] else null;
        // param: children[0] is the default value (if present)
        if (self.kind == .param) return if (self.children.len > 0) self.children[0] else null;
    }
    return null;
}
```

- [ ] **Step 4: Remove `default_value` field from mir_node.zig**

Remove lines 77-78:

```zig
/// Default value AST node (for field_decl).
default_value: ?*parser.Node = null,
```

- [ ] **Step 5: Fix any remaining references to `default_value` on MirNode**

Search for `default_value` in `src/mir/` and `src/codegen/` — should only be in `codegen_decls.zig:379` at this point. We'll fix that in Task 2.

- [ ] **Step 6: Run `zig build test` to verify MIR lowering compiles**

Run: `zig build test`
Expected: Compilation errors in codegen_decls.zig (we haven't updated the consumer yet). That's OK — proceed to Task 2.

---

### Task 2: Switch struct field default codegen to MIR path

**Files:**
- Modify: `src/codegen/codegen_decls.zig:375-383` (field_def case in generateStructMir)

- [ ] **Step 1: Replace `generateExpr(dv)` with `generateExprMir` using the new child**

Change the field_def case in `generateStructMir`:

```zig
.field_def => {
    const fname = child.name orelse continue;
    try cg.emitIndent();
    try cg.emitFmt("{s}: {s}", .{ fname, try cg.typeToZig(child.type_annotation orelse continue) });
    if (child.defaultChild()) |dv_mir| {
        try cg.emit(" = ");
        try cg.generateExprMir(dv_mir);
    }
    try cg.emit(",\n");
},
```

- [ ] **Step 2: Run `zig build test`**

Run: `zig build test`
Expected: PASS (no compilation errors)

- [ ] **Step 3: Run `./testall.sh`**

Run: `./testall.sh`
Expected: All 297 tests pass. This validates struct field defaults still generate correct Zig.

- [ ] **Step 4: Commit**

```bash
git add src/mir/mir_lowerer.zig src/mir/mir_node.zig src/codegen/codegen_decls.zig
git commit -m "refactor: lower field_decl defaults to MirNode children, eliminate AST crossover"
```

---

### Task 3: Lower param defaults to MirNode children

**Files:**
- Modify: `src/mir/mir_lowerer.zig:90-97` (func_decl case) and `:565-568` (param populateData)

Currently the `.param` case in `lowerNode()` has no explicit handler — it falls through to `populateData()`. And `.func_decl` lowers params via `lowerNode(param)` but the param nodes get no children.

- [ ] **Step 1: Add `.param` case to `lowerNode()` in mir_lowerer.zig**

Add a case for `.param` that lowers the default value as a child:

```zig
.param => |p| {
    if (p.default_value) |dv| {
        var children = std.ArrayListUnmanaged(*MirNode){};
        try children.append(self.allocator, try self.lowerNode(dv));
        mir_node_ptr.children = try children.toOwnedSlice(self.allocator);
    }
},
```

- [ ] **Step 2: Run `zig build test`**

Run: `zig build test`
Expected: PASS — param MirNodes now have default children, but no consumer reads them yet.

---

### Task 4: Rewrite `fillDefaultArgsMir` to use MIR params

**Files:**
- Modify: `src/codegen/codegen_match.zig:888-932` (fillDefaultArgsMir)

The current function looks up `FuncSig.param_nodes` (AST) from the DeclTable. Rewrite to find the function's MirNode from `cg.mir_root` and iterate its param children.

- [ ] **Step 1: Rewrite `fillDefaultArgsMir`**

Replace the entire function body:

```zig
/// MIR-path fill default arguments.
pub fn fillDefaultArgsMir(cg: *CodeGen, callee_mir: *const mir.MirNode, actual_arg_count: usize) anyerror!void {
    // Resolve function name from callee MirNode
    const func_name: []const u8 = if (callee_mir.kind == .identifier)
        callee_mir.name orelse return
    else if (callee_mir.kind == .field_access)
        callee_mir.name orelse return
    else
        return;

    // Find the function's MirNode from the MIR root to get param defaults
    const func_mir = findFuncMir(cg, func_name) orelse return;
    const mir_params = func_mir.params();
    if (actual_arg_count >= mir_params.len) return;

    var wrote_any = actual_arg_count > 0;
    for (mir_params[actual_arg_count..]) |param_m| {
        if (param_m.defaultChild()) |dv_mir| {
            if (wrote_any) try cg.emit(", ");
            try cg.generateExprMir(dv_mir);
            wrote_any = true;
        }
    }
}

/// Find a function's MirNode by name in the MIR root or cross-module MIR roots.
fn findFuncMir(cg: *CodeGen, func_name: []const u8) ?*mir.MirNode {
    if (cg.mir_root) |root| {
        for (root.children) |child| {
            if (child.kind == .func and child.name != null and
                std.mem.eql(u8, child.name.?, func_name)) return child;
        }
    }
    return null;
}
```

- [ ] **Step 2: Run `zig build test`**

Run: `zig build test`
Expected: PASS

- [ ] **Step 3: Run `./testall.sh`**

Run: `./testall.sh`
Expected: All 297 tests pass. This validates function param defaults still generate correct Zig.

- [ ] **Step 4: Commit**

```bash
git add src/mir/mir_lowerer.zig src/codegen/codegen_match.zig
git commit -m "refactor: lower param defaults to MirNode children, eliminate last AST crossover in fillDefaultArgsMir"
```

---

### Task 5: Delete AST-only codegen functions

**Files:**
- Modify: `src/codegen/codegen_stmts.zig` — delete `generateExpr` (lines 255-778)
- Modify: `src/codegen/codegen_match.zig` — delete AST-only functions
- Modify: `src/codegen/codegen_exprs.zig` — delete `generateInterpolatedString`
- Modify: `src/codegen/codegen.zig` — delete AST-only hub wrappers

Now that no MIR-path code calls `generateExpr`, all AST-path expression codegen is unreachable dead code.

- [ ] **Step 1: Delete `generateExpr` from codegen_stmts.zig**

Delete the entire `pub fn generateExpr(cg: *CodeGen, node: *parser.Node) anyerror!void` function (lines 255-778, ~524 lines).

- [ ] **Step 2: Delete AST-only functions from codegen_match.zig**

Delete these functions (all take `*parser.Node` args, only called from `generateExpr`):

- `generateWrappingExpr` (line 750)
- `generateSaturatingExpr` (line 763)
- `generateOverflowExpr` (line 822)
- `generateCompilerFunc` (line 934)
- `generatePtrCoercion` (line 1042)
- `fillDefaultArgs` (line 1086)
- `generateCollectionExpr` (line 1139)

- [ ] **Step 3: Delete `generateInterpolatedString` from codegen_exprs.zig**

Delete `pub fn generateInterpolatedString(cg: *CodeGen, interp: parser.InterpolatedString) anyerror!void` (line 743, ~80 lines). This is the AST-path version; the MIR-path `generateInterpolatedStringMir` in codegen_match.zig remains.

- [ ] **Step 4: Delete AST-only hub wrappers from codegen.zig**

Delete these hub wrappers:

```zig
// DELETE:
pub fn generateExpr(...)           // line 532
pub fn generateInterpolatedString(...)  // line 552
pub fn generateWrappingExpr(...)   // line 580
pub fn generateSaturatingExpr(...) // line 582
pub fn generateOverflowExpr(...)   // line 584
pub fn generateCompilerFunc(...)   // line 594
pub fn generatePtrCoercion(...)    // line 596
pub fn fillDefaultArgs(...)        // line 598
pub fn generateCollectionExpr(...) // line 600
```

- [ ] **Step 5: Delete `emitTypePath` from codegen.zig**

Delete `pub fn emitTypePath(self: *CodeGen, node: *parser.Node)` (lines 248-260). Only called from `generateExpr`. The MIR counterpart `emitTypeMirPath` (line 264) remains.

- [ ] **Step 6: Delete `isStringExpr` from codegen.zig**

Delete `pub fn isStringExpr(self: *const CodeGen, node: *parser.Node)` (lines 335-339). Only called from `generateExpr` via codegen_stmts.zig. The MIR equivalent `mirIsString` remains.

- [ ] **Step 7: Run `zig build test`**

Run: `zig build test`
Expected: PASS — if any compilation errors about undefined references, track down the remaining caller and fix.

- [ ] **Step 8: Run `./testall.sh`**

Run: `./testall.sh`
Expected: All 297 tests pass. No behavioral change — we only removed unreachable code.

- [ ] **Step 9: Commit**

```bash
git add src/codegen/codegen_stmts.zig src/codegen/codegen_match.zig src/codegen/codegen_exprs.zig src/codegen/codegen.zig
git commit -m "refactor: delete AST-path expression codegen — all codegen now uses MIR exclusively"
```

---

### Task 6: Update TODO and verify

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Remove the completed simplification item from TODO.md**

The "Compiler simplifications" section currently has:
```markdown
- Lower default parameter values to MIR to eliminate last `generateExpr` AST
  dependency (`fillDefaultArgsMir`).
```

Remove it. If the section is now empty, remove the section header too.

- [ ] **Step 2: Run final `./testall.sh`**

Run: `./testall.sh`
Expected: All 297 tests pass.

- [ ] **Step 3: Commit**

```bash
git add docs/TODO.md
git commit -m "docs: remove completed compiler simplification from TODO"
```
