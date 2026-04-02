# FuncDecl Context Enum Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three mutually exclusive boolean flags `is_compt`, `is_bridge`, `is_thread` on `FuncDecl` and `FuncSig` with a single `context: FuncContext` enum field.

**Architecture:** Add a `FuncContext` enum (`normal`, `compt`, `bridge`, `thread`) to `parser.zig`. Replace the three bools in `FuncDecl` (AST) and `FuncSig` (declarations). Update all 16 consumer files to use the enum. MirNode keeps its flat bools (it's a generic annotation struct spanning all node types) but derives them from the enum at the lowering boundary.

**Tech Stack:** Zig 0.15.2+, no new dependencies.

---

### Task 1: Add FuncContext enum and update FuncDecl in parser.zig

**Files:**
- Modify: `src/parser.zig:175-185`

- [ ] **Step 1: Add FuncContext enum and update FuncDecl**

In `src/parser.zig`, add the enum just above `FuncDecl` and replace the three bools:

```zig
pub const FuncContext = enum {
    normal,
    compt,
    bridge,
    thread,
};

pub const FuncDecl = struct {
    name: []const u8,
    params: []*Node,
    return_type: *Node,
    body: *Node,
    context: FuncContext,
    is_pub: bool,
    doc: ?[]const u8 = null,
};
```

This removes `is_compt`, `is_bridge`, `is_thread` and replaces them with the single `context` field.

- [ ] **Step 2: Run build to see all downstream breakages**

Run: `zig build 2>&1 | head -80`
Expected: Compilation errors in every file that references the removed fields. This confirms the scope.

- [ ] **Step 3: Commit**

```bash
git add src/parser.zig
git commit -m "refactor: add FuncContext enum, replace 3 bools in FuncDecl"
```

---

### Task 2: Update FuncSig in declarations.zig

**Files:**
- Modify: `src/declarations.zig:14-27`

- [ ] **Step 1: Replace FuncSig bools with context enum**

Replace the three bools in `FuncSig` with a single `context` field. Import `FuncContext` from parser:

```zig
pub const FuncSig = struct {
    name: []const u8,
    params: []ParamSig,
    param_nodes: []*parser.Node,
    return_type: types.ResolvedType,
    return_type_node: *parser.Node,
    context: parser.FuncContext,
    is_pub: bool,
};
```

This removes `is_compt`, `is_bridge`, `is_thread` and the doc comment on `is_bridge`.

- [ ] **Step 2: Commit**

```bash
git add src/declarations.zig
git commit -m "refactor: replace 3 bools in FuncSig with FuncContext"
```

---

### Task 3: Update PEG builders

**Files:**
- Modify: `src/peg/builder_decls.zig:264-273, 443-452`
- Modify: `src/peg/builder_bridge.zig:31-127`

- [ ] **Step 1: Update builder_decls.zig — buildFuncDecl**

At lines 264-273, replace the four bool fields with `context`:

```zig
return ctx.newNode(.{ .func_decl = .{
    .name = name,
    .params = params,
    .return_type = ret_type,
    .body = body,
    .context = .normal,
    .is_pub = false,
} });
```

- [ ] **Step 2: Update builder_decls.zig — buildBlueprintMethod**

At lines 443-452, the blueprint method builder:

```zig
return ctx.newNode(.{ .func_decl = .{
    .name = name,
    .params = try params_list.toOwnedSlice(ctx.alloc()),
    .return_type = return_type,
    .body = empty_body,
    .context = .bridge,
    .is_pub = true,
} });
```

- [ ] **Step 3: Update builder_bridge.zig — buildComptDecl**

At line 35, change:
```zig
// Old: if (node.* == .func_decl) node.func_decl.is_compt = true;
if (node.* == .func_decl) node.func_decl.context = .compt;
```

- [ ] **Step 4: Update builder_bridge.zig — buildBridgeFunc**

At lines 66-75:
```zig
return ctx.newNode(.{ .func_decl = .{
    .name = name,
    .params = try params_list.toOwnedSlice(ctx.alloc()),
    .return_type = ret_type,
    .body = try ctx.newNode(.{ .block = .{ .statements = &.{} } }),
    .context = .bridge,
    .is_pub = false,
} });
```

- [ ] **Step 5: Update builder_bridge.zig — buildThreadDecl**

At lines 117-126:
```zig
return ctx.newNode(.{ .func_decl = .{
    .name = name,
    .params = try params_list.toOwnedSlice(ctx.alloc()),
    .return_type = ret_type,
    .body = body,
    .context = .thread,
    .is_pub = false,
} });
```

- [ ] **Step 6: Commit**

```bash
git add src/peg/builder_decls.zig src/peg/builder_bridge.zig
git commit -m "refactor: update PEG builders to use FuncContext enum"
```

---

### Task 4: Update declarations.zig consumers

**Files:**
- Modify: `src/declarations.zig:228-311, 392-402, 531, tests`

- [ ] **Step 1: Update collectFunc — FuncSig construction (line 302-312)**

Replace the four flag copies with a single context copy:

```zig
const sig = FuncSig{
    .name = f.name,
    .params = try params.toOwnedSlice(self.allocator),
    .param_nodes = f.params,
    .return_type = return_type,
    .return_type_node = f.return_type,
    .context = f.context,
    .is_pub = f.is_pub,
};
```

- [ ] **Step 2: Update collectStruct — struct method FuncSig (lines 392-402)**

The struct method copies `is_bridge` from the parent struct, not from the func. Use a ternary:

```zig
const method_sig = FuncSig{
    .name = f.name,
    .params = try params.toOwnedSlice(self.allocator),
    .param_nodes = f.params,
    .return_type = try types.resolveTypeNode(self.table.typeAllocator(), f.return_type),
    .return_type_node = f.return_type,
    .context = if (s.is_bridge) .bridge else f.context,
    .is_pub = f.is_pub,
};
```

- [ ] **Step 3: Update bridge detection in collect() (lines 228-230)**

The `f.is_bridge` check on FuncDecl becomes:
```zig
.func_decl => |f| if (f.context == .bridge) { has_bridge = true; break; },
```
(The `.struct_decl` and `.const_decl` lines use `s.is_bridge` / `v.is_bridge` which are on StructDecl/VarDecl — those don't change.)

- [ ] **Step 4: Update all test blocks**

Every test that constructs a FuncDecl with the four bools needs updating. Replace patterns like:
```zig
.is_compt = false, .is_pub = false, .is_bridge = false, .is_thread = false,
```
with:
```zig
.context = .normal, .is_pub = false,
```

For bridge test cases, use `.context = .bridge`. Search for all `test` blocks in declarations.zig and update each one. Key test locations:
- Line ~570: "declaration collector - func" → `.context = .normal`
- Line ~662-667: "duplicate func error" → `.context = .normal`
- Line ~744: "bridge func" → `.context = .bridge`
- Line ~786: "#cimport without bridge" → `.context = .normal`
- Line ~833: "#cimport with bridge" → `.context = .bridge`

- [ ] **Step 5: Commit**

```bash
git add src/declarations.zig
git commit -m "refactor: update declarations.zig to use FuncContext"
```

---

### Task 5: Update resolver.zig

**Files:**
- Modify: `src/resolver.zig:194, 351, 742, tests`

- [ ] **Step 1: Update bridge param validation (line 194)**

```zig
// Old: if (f.is_bridge) {
if (f.context == .bridge) {
```

- [ ] **Step 2: Update bridge const handling (line 351)**

This checks `v.is_bridge` on a VarDecl — **no change needed** (VarDecl still has `is_bridge` bool).

- [ ] **Step 3: Update compt return type inference (line 742)**

```zig
// Old: if (sig.is_compt) return RT{ .named = name };
if (sig.context == .compt) return RT{ .named = name };
```

- [ ] **Step 4: Update test FuncSig initializations**

Lines ~1462 and ~1511: replace the three bools with `.context = .normal`.

- [ ] **Step 5: Commit**

```bash
git add src/resolver.zig
git commit -m "refactor: update resolver.zig to use FuncContext"
```

---

### Task 6: Update MIR lowerer and annotator

**Files:**
- Modify: `src/mir/mir_lowerer.zig:538-540, 648`
- Modify: `src/mir/mir_annotator.zig:385-386, tests`

MirNode keeps its flat bools (`is_bridge`, `is_thread`, `is_compt`) because it's a generic annotation struct. The lowerer translates from the enum to the bools.

- [ ] **Step 1: Update mir_lowerer.zig — populateData for func_decl (lines 538-540)**

Replace the three individual copies with enum-based assignment:

```zig
m.is_bridge = (f.context == .bridge);
m.is_thread = (f.context == .thread);
m.is_compt = (f.context == .compt);
```

- [ ] **Step 2: Update mir_lowerer.zig — other func_decl population (line 648)**

```zig
// Old: m.is_compt = f.is_compt;
m.is_compt = (f.context == .compt);
```

- [ ] **Step 3: Update mir_annotator.zig — bridge guard (line 385-386)**

```zig
// Old: if (is_direct_call and arg.* == .identifier and !sig.is_bridge) {
if (is_direct_call and arg.* == .identifier and sig.context != .bridge) {
```

- [ ] **Step 4: Update mir_annotator.zig test FuncSig initializations**

Lines ~797, ~911, ~983, ~1055: replace three bools with `.context = .normal`.
Lines ~1138, ~1224: replace with `.context = .bridge`.

- [ ] **Step 5: Commit**

```bash
git add src/mir/mir_lowerer.zig src/mir/mir_annotator.zig
git commit -m "refactor: update MIR lowerer/annotator for FuncContext"
```

---

### Task 7: Update codegen

**Files:**
- Modify: `src/codegen/codegen_decls.zig:97-137, 343-384`

Codegen reads from MirNode (which keeps its flat bools) and from FuncSig. The MirNode reads don't change. Only the FuncSig reads in the AST-path need updating.

- [ ] **Step 1: Update codegen_decls.zig AST-path (lines 343-384)**

```zig
// Line 343: Old: if (f.is_thread) return cg.generateThreadFunc(node, f);
if (f.context == .thread) return cg.generateThreadFunc(node, f);

// Line 346: Old: if (f.is_bridge) return cg.generateBridgeReExport(f.name, f.is_pub);
if (f.context == .bridge) return cg.generateBridgeReExport(f.name, f.is_pub);

// Line 351: Old: !f.is_bridge and ...
f.context != .bridge and ...

// Line 382: Old: const is_type_generic = f.is_compt and returns_type;
const is_type_generic = (f.context == .compt) and returns_type;

// Line 384: Old: if (f.is_compt and !is_type_generic) {
if (f.context == .compt and !is_type_generic) {
```

- [ ] **Step 2: Commit**

```bash
git add src/codegen/codegen_decls.zig
git commit -m "refactor: update codegen AST-path for FuncContext"
```

---

### Task 8: Update remaining consumer files

**Files:**
- Modify: `src/thread_safety.zig:240, tests`
- Modify: `src/propagation.zig:tests`
- Modify: `src/cache.zig:372, tests`
- Modify: `src/interface.zig:106`
- Modify: `src/module.zig:706-708`
- Modify: `src/pipeline.zig:1028-1041`

- [ ] **Step 1: Update thread_safety.zig (line 240)**

```zig
// Old: if (sig.is_thread) return .{ .name = callee_name, .sig = sig };
if (sig.context == .thread) return .{ .name = callee_name, .sig = sig };
```

Update all test FuncSig initializations (~731, ~785, ~851, ~966):
```zig
// Old: .is_compt = false, .is_pub = false, .is_thread = true,
.context = .thread, .is_pub = false,
```

- [ ] **Step 2: Update propagation.zig tests**

Update test FuncSig initializations (~588, ~731):
```zig
// Old: .is_compt = false, .is_pub = false, .is_thread = false,
.context = .normal, .is_pub = false,
```

- [ ] **Step 3: Update cache.zig (line 372)**

```zig
// Old: return XxHash3.hash(h, &[_]u8{ @intFromBool(sig.is_compt), @intFromBool(sig.is_thread) });
return XxHash3.hash(h, &[_]u8{@intFromEnum(sig.context)});
```

Update all test FuncSig initializations (~758, ~823, ~859). Replace the three/four bools with `.context = .normal` or `.context = .bridge` as appropriate.

Note: cache.zig tests that construct FuncSig with `is_bridge` — those become `.context = .bridge`.

- [ ] **Step 4: Update interface.zig (line 106)**

```zig
// Old: if (f.is_compt) try buf.appendSlice(alloc, "compt ");
if (f.context == .compt) try buf.appendSlice(alloc, "compt ");
```

This reads from `parser.FuncDecl`, not `FuncSig`.

- [ ] **Step 5: Update module.zig (line 706-708)**

```zig
// Old: .func_decl => |f| f.is_bridge,
.func_decl => |f| f.context == .bridge,
```

- [ ] **Step 6: Update pipeline.zig (lines 1028-1041)**

```zig
// Old: .func_decl => |f| { if (f.is_bridge) try names.append(...) }
.func_decl => |f| { if (f.context == .bridge) try names.append(...) }

// Old (line ~1041): if (m.* == .func_decl and m.func_decl.is_bridge)
if (m.* == .func_decl and m.func_decl.context == .bridge)
```

- [ ] **Step 7: Commit**

```bash
git add src/thread_safety.zig src/propagation.zig src/cache.zig src/interface.zig src/module.zig src/pipeline.zig
git commit -m "refactor: update remaining consumers for FuncContext"
```

---

### Task 9: Build and run full test suite

**Files:** None (verification only)

- [ ] **Step 1: Build**

Run: `zig build`
Expected: Clean build, no errors.

- [ ] **Step 2: Run full test suite**

Run: `./testall.sh`
Expected: All tests pass. If any fail, fix the issue — likely a missed flag reference.

- [ ] **Step 3: Grep for any remaining references to the old fields**

Run: `rg 'is_compt|is_bridge|is_thread' src/ --glob '*.zig'`

Remaining hits should only be:
- `VarDecl.is_bridge` (unchanged — VarDecl still has its own `is_bridge`)
- `StructDecl.is_bridge` (unchanged)
- `MirNode.is_bridge/is_thread/is_compt` (unchanged — flat annotation struct)
- `ForStmt.is_compt` (unchanged — separate struct)
- Any codegen reads from MirNode (unchanged)

No hits should reference `FuncDecl` or `FuncSig` fields.

- [ ] **Step 4: Update TODO.md — mark FuncDecl flags as done**

Add strikethrough to the item in `docs/TODO.md`:
```
- ~~`FuncDecl` flags → context enum. ... — done (v0.14.3, `parser.FuncContext`)~~
```

- [ ] **Step 5: Final commit**

```bash
git add docs/TODO.md
git commit -m "docs: mark FuncDecl context enum simplification as done"
```
