# String Rename & Magic Removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename type `String` → `str`, rename stdlib module `str` → `string`, remove all magic string method dispatch and auto-imports, add `equals()` to the string library, add compile error for `==`/`!=` on `str`.

**Architecture:** Pure rename + magic removal. The `str` primitive still maps to `[]const u8`. All string utility functions live in `std::string` with no compiler awareness. String interpolation and match desugaring stay (language concerns, not stdlib magic). `mirIsString()` stays for interpolation/match codegen.

**Tech Stack:** Zig 0.15.2+, Orhon compiler

---

### Task 1: Rename stdlib file `str.zig` → `string.zig` and add `equals()`

**Files:**
- Rename: `src/std/str.zig` → `src/std/string.zig`
- Modify: `src/std/string.zig` (add `equals` function, update header comment)

- [ ] **Step 1: Rename the file**

```bash
git mv src/std/str.zig src/std/string.zig
```

- [ ] **Step 2: Update header comment and add `equals` function**

In `src/std/string.zig`, change line 1-2:
```zig
// string.zig — string utilities for std::string
// Operates on []const u8 (Orhon str type). All functions are pure — no side effects.
```

Add `equals` function at the top of the file (after the `alloc` line, before `// ── Search ──`):

```zig
// ── Comparison ──

/// Compare two strings for content equality.
pub fn equals(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
```

- [ ] **Step 3: Add test for `equals`**

Add at the end of the test section in `src/std/string.zig`:

```zig
test "equals" {
    try std.testing.expect(equals("hello", "hello"));
    try std.testing.expect(!equals("hello", "world"));
    try std.testing.expect(!equals("hello", "hell"));
    try std.testing.expect(equals("", ""));
}
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: All tests pass including the new `equals` test

- [ ] **Step 5: Commit**

```bash
git add src/std/string.zig
git commit -m "rename: std/str.zig → std/string.zig, add equals()"
```

---

### Task 2: Update `std_bundle.zig` and `pipeline.zig` for file rename

**Files:**
- Modify: `src/std_bundle.zig` — embed path and name change
- Modify: `src/pipeline.zig` — generated file name change

- [ ] **Step 1: Update `std_bundle.zig`**

In `src/std_bundle.zig`, change:
- Line 16: `pub const STR_ZIG = @embedFile("std/str.zig");` → `pub const STRING_ZIG = @embedFile("std/string.zig");`
- Line 66: `.{ .name = "str.zig", .content = STR_ZIG },` → `.{ .name = "string.zig", .content = STRING_ZIG },`

- [ ] **Step 2: Update `pipeline.zig`**

In `src/pipeline.zig`, change line 27:
- `const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_str.zig", .{});` → `const file = try std.fs.cwd().createFile(cache.GENERATED_DIR ++ "/_orhon_string.zig", .{});`
- Line 29: `try file.writeAll(_std_bundle.STR_ZIG);` → `try file.writeAll(_std_bundle.STRING_ZIG);`

- [ ] **Step 3: Commit**

```bash
git add src/std_bundle.zig src/pipeline.zig
git commit -m "rename: _orhon_str.zig → _orhon_string.zig in bundle and pipeline"
```

---

### Task 3: Update `zig_runner_multi.zig` for module name change

**Files:**
- Modify: `src/zig_runner/zig_runner_multi.zig` — all `_orhon_str` → `_orhon_string`, `str_mod` → `string_mod`

- [ ] **Step 1: Rename module references**

In `src/zig_runner/zig_runner_multi.zig`:
- Line 45: `\\    const str_mod = b.createModule(.{` → `\\    const string_mod = b.createModule(.{`
- Line 46: `\\        .root_source_file = b.path("_orhon_str.zig"),` → `\\        .root_source_file = b.path("_orhon_string.zig"),`
- All occurrences of `addImport("_orhon_str", str_mod)` → `addImport("_orhon_string", string_mod)` (lines ~213, ~262, ~354, ~451)

- [ ] **Step 2: Commit**

```bash
git add src/zig_runner/zig_runner_multi.zig
git commit -m "rename: str_mod → string_mod in generated build.zig"
```

---

### Task 4: Rename type `String` → `str` in core type system

**Files:**
- Modify: `src/types.zig` — `fromName` map, `toName` switch
- Modify: `src/constants.zig` — `STRING` constant
- Modify: `src/builtins.zig` — `primitiveToZig` map and test

- [ ] **Step 1: Update `types.zig`**

In `src/types.zig`:
- Line 59: `.{ "String", .string },` → `.{ "str", .string },`
- Line 89: `.string => "String",` → `.string => "str",`
- Line 475 (test): `try std.testing.expect(isPrimitiveName("String"));` → `try std.testing.expect(isPrimitiveName("str"));`

- [ ] **Step 2: Update `constants.zig`**

Line 8: `pub const STRING = "String";` → `pub const STRING = "str";`

- [ ] **Step 3: Update `builtins.zig`**

- Line 155: `.{ "String", "[]const u8" },` → `.{ "str", "[]const u8" },`
- Line 222 (test): `try std.testing.expectEqualStrings("[]const u8", primitiveToZig("String"));` → `try std.testing.expectEqualStrings("[]const u8", primitiveToZig("str"));`

- [ ] **Step 4: Run unit tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/types.zig src/constants.zig src/builtins.zig
git commit -m "rename: type String → str in core type system"
```

---

### Task 5: Remove magic — auto-import, method dispatch, split destructuring

**Files:**
- Modify: `src/codegen/codegen.zig` — remove `str_import_alias`, `str_is_included`, auto-import block, import tracking
- Modify: `src/codegen/codegen_exprs.zig` — remove method rewriting (lines 325-347), remove string `==`/`!=` rewriting (lines 187-194), remove split/splitAt destructuring (lines 796-842)

- [ ] **Step 1: Remove fields and auto-import from `codegen.zig`**

In `src/codegen/codegen.zig`:
- Remove line 46: `str_import_alias: ?[]const u8 = null,`
- Remove line 47: `str_is_included: bool = false,`
- Remove lines 298-302 (the auto-import block):
  ```zig
  // Auto-import str if not explicitly imported — needed for string method dispatch
  if (self.str_import_alias == null and !self.str_is_included) {
      self.str_import_alias = "str";
      try self.emit("const str = @import(\"_orhon_str\");\n");
  }
  ```
- Remove lines 366-373 (import alias tracking for "str"):
  ```zig
  // Track import aliases for str and collections
  if (std.mem.eql(u8, imp.path, "str")) {
      if (imp.is_include) {
          self.str_is_included = true;
      } else {
          self.str_import_alias = imp.alias orelse "str";
      }
  }
  ```
  Keep the comment but change it to just `// Track import aliases for collections` since the str tracking is gone.

- [ ] **Step 2: Remove method dispatch rewriting from `codegen_exprs.zig`**

Remove lines 325-347 (the entire string method rewriting block):
```zig
// String method rewriting: s.method(args) → _str.method(s, args)
if (callee_is_field) {
    const method = callee_mir.name orelse "";
    const obj_mir = callee_mir.children[0]; // field_access.children[0] = object
    const is_handle = obj_mir.type_class == .thread_handle;
    if (!is_handle and (mirIsString(obj_mir) or
        std.mem.eql(u8, method, "toString") or
        std.mem.eql(u8, method, "join")))
    {
        if (cg.str_is_included) {
            try cg.emitFmt("{s}(", .{method});
        } else {
            const prefix = cg.str_import_alias orelse "str";
            try cg.emitFmt("{s}.{s}(", .{ prefix, method });
        }
        try cg.generateExprMir(obj_mir);
        for (call_args) |arg| {
            try cg.emit(", ");
            try cg.generateExprMir(arg);
        }
        try cg.emit(")");
        return;
    }
}
```

- [ ] **Step 3: Remove string `==`/`!=` → `std.mem.eql` rewriting from `codegen_exprs.zig`**

Remove lines 187-194:
```zig
} else if ((is_eq or is_ne) and (mirIsString(m.lhs()) or mirIsString(m.rhs()))) {
    // String comparison → std.mem.eql
    if (is_ne) try cg.emit("!");
    try cg.emit("std.mem.eql(u8, ");
    try cg.generateExprMir(m.lhs());
    try cg.emit(", ");
    try cg.generateExprMir(m.rhs());
    try cg.emit(")");
```

- [ ] **Step 4: Remove split/splitAt destructuring from `codegen_exprs.zig`**

Remove lines 796-842 (the entire `// String split destructuring` block inside `generateDestructMir`), starting from the comment `// String split destructuring` through the closing `}` before `// Normal tuple destructuring`.

- [ ] **Step 5: Commit**

```bash
git add src/codegen/codegen.zig src/codegen/codegen_exprs.zig
git commit -m "remove: string magic — auto-import, method dispatch, ==, split destructuring"
```

---

### Task 6: Add compile error for `==`/`!=` on `str`

**Files:**
- Modify: `src/resolver_exprs.zig` — add check in `binary_expr` handling

- [ ] **Step 1: Add string equality compile error**

In `src/resolver_exprs.zig`, expand the `.binary_expr` handler (lines 92-98). After resolving left and right, check if both are strings and the operator is `==` or `!=`:

```zig
.binary_expr => |b| {
    const left = try resolveExpr(self, b.left, scope);
    const right = try resolveExpr(self, b.right, scope);
    // Reject == and != on str — use string.equals() instead
    if (b.op == .eq or b.op == .ne) {
        const l_is_str = left == .primitive and left.primitive == .string;
        const r_is_str = right == .primitive and right.primitive == .string;
        if (l_is_str or r_is_str) {
            try self.ctx.reporter.reportFmt(self.ctx.nodeLoc(node),
                "cannot use '{s}' on str — use string.equals() for content comparison",
                .{if (b.op == .eq) "==" else "!="});
        }
    }
    if (b.op.isLogical() or b.op.isComparison()) return RT{ .primitive = .bool };
    if (b.op == .concat) return left;
    return left;
},
```

- [ ] **Step 2: Commit**

```bash
git add src/resolver_exprs.zig
git commit -m "error: reject == and != on str — use string.equals()"
```

---

### Task 7: Update `String` → `str` across resolver, MIR, codegen, supporting files

**Files:**
- Modify: `src/resolver_validation.zig` — error messages and comments
- Modify: `src/codegen/codegen_exprs.zig` — `"String"` fallback strings
- Modify: `src/codegen/codegen_match.zig` — `"String"` in primitives list
- Modify: `src/codegen/codegen.zig` — comment about `_String` union tag
- Modify: `src/zig_module.zig` — `[]const u8` → `"String"` mappings become `"str"`
- Modify: `src/mir/mir_registry.zig` — test strings
- Modify: `src/lsp/lsp_utils.zig` — `"String"` in keyword list
- Modify: `src/lsp/lsp_edit.zig` — `"String"` in type list, test strings
- Modify: `src/lsp/lsp_view.zig` — test strings
- Modify: `src/ownership.zig` — test `isPrimitiveName("String")` → `"str"`
- Modify: `src/borrow.zig` — test `.type_named = "String"` → `"str"`
- Modify: `src/syntaxgen.zig` — all `String` type references in embedded grammar

- [ ] **Step 1: Update `resolver_validation.zig`**

All error messages and comments: `'String'` → `'str'`, `str.fromBytes()` → `string.fromBytes()`, `str.toBytes()` → `string.toBytes()`:
- Line 216: comment `e.g. i32 vs String` → `e.g. i32 vs str`
- Line 221: comment `Block []u8 → String` → `Block []u8 → str`
- Line 226: `"cannot assign '[]u8' to 'String' — use str.fromBytes()..."` → `"cannot assign '[]u8' to 'str' — use string.fromBytes()..."`
- Line 239: comment `String is not []u8` → `str is not []u8`
- Line 254: comment `Reject []u8 passed as String` → `Reject []u8 passed as str`
- Line 258: `"cannot pass '[]u8' as 'String'..."` → `"cannot pass '[]u8' as 'str' — use string.fromBytes()..."`
- Line 263: comment `Reject String passed as []u8` → `Reject str passed as []u8`
- Line 267: `"cannot pass 'String' as '[]u8'..."` → `"cannot pass 'str' as '[]u8' — use string.toBytes()..."`

- [ ] **Step 2: Update codegen files**

In `src/codegen/codegen_exprs.zig`:
- Line 28: `orelse "String"` → `orelse "str"`
- Line 44: `std.mem.eql(u8, n, "String")` → `std.mem.eql(u8, n, "str")`
- Line 81: `orelse "String"` → `orelse "str"`

In `src/codegen/codegen_match.zig`:
- Line 886: `"bool", "String", "void",` → `"bool", "str", "void",`

In `src/codegen/codegen.zig`:
- Line 582: comment `_String: []const u8` → `_str: []const u8`

- [ ] **Step 3: Update `zig_module.zig`**

- Line 105: `try out.append(allocator, "String");` → `try out.append(allocator, "str");`
- Line 329: `"pub const {s}: String = {s}"` → `"pub const {s}: str = {s}"`
- Line 840-841 (test): `"[]const u8 maps to String"` → `"[]const u8 maps to str"`, `"String"` → `"str"`
- Line 877: `"NullUnion(String)"` → `"NullUnion(str)"`
- Line 878: `"ErrorUnion(String)"` → `"ErrorUnion(str)"`
- Line 879: `"const& String"` → `"const& str"`
- Line 976: `"pub const NAME: String = \"hello\""` → `"pub const NAME: str = \"hello\""`

- [ ] **Step 4: Update MIR, LSP, analysis files**

In `src/mir/mir_registry.zig` (tests):
- All `"String"` → `"str"` in test data

In `src/lsp/lsp_utils.zig`:
- Line 329: `"String"` → `"str"` in keyword list
- Line 388: `"name of a type as String"` → `"name of a type as str"`

In `src/lsp/lsp_edit.zig`:
- Line 136: `"String"` → `"str"` in type list
- Line 579/581 (tests): `"msg: String"` → `"msg: str"`, update function signature strings

In `src/lsp/lsp_view.zig`:
- Line 470/472 (tests): same as lsp_edit.zig — update test signature strings

In `src/ownership.zig`:
- Line 341: `isPrimitiveName("String")` → `isPrimitiveName("str")`

In `src/borrow.zig`:
- Line 688: `.type_named = "String"` → `.type_named = "str"`

- [ ] **Step 5: Update `syntaxgen.zig`**

All `String` type references in the embedded grammar become `str`. There are ~15 occurrences across lines 72, 80, 113, 138, 166, 169, 205, 212, 475. Replace all occurrences of `String` used as a type name with `str`.

Also update line 417: `\\### String interpolation` stays as-is (this is a section title about the feature, not a type name).

- [ ] **Step 6: Update remaining comments**

In `src/resolver.zig` line 510: `// String iteration produces u8 characters` → `// str iteration produces u8 characters`

In `src/declarations.zig` line 701: `"String", "i32", "File"` → `"str", "i32", "File"` (or just update the comment text)

In `src/propagation.zig` line 280: `result.String` → `result.str`

In `src/mir/mir_annotator.zig` line 98: `String` → `str` in comment

In `src/std/fs.zig` line 2: `(Orhon String)` → `(Orhon str)`

In `src/std/sort.zig` line 40: `// ── String sorting ──` stays (describes the concept, not the type)

- [ ] **Step 7: Run unit tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "rename: String → str across resolver, MIR, codegen, LSP, zig_module"
```

---

### Task 8: Update test fixtures — `String` → `str`, remove magic method calls

**Files:**
- Modify: `test/fixtures/tester.orh` — all `String` → `str`, add `import std::string`, change `s.method()` → `string.method(s)`
- Modify: `test/fixtures/tester_main.orh` — `String` → `str`
- Modify: `test/fixtures/fail_types.orh` — `String` → `str`
- Modify: `test/fixtures/fail_structs.orh` — `String` → `str`
- Modify: `test/fixtures/fail_did_you_mean.orh` — `String` → `str`
- Modify: `test/fixtures/fail_functions.orh` — `String` → `str`
- Modify: `test/fixtures/fail_ownership.orh` — `String` → `str`
- Modify: `test/fixtures/fail_match.orh` — `String` → `str`

- [ ] **Step 1: Update `tester.orh`**

Replace all `String` type annotations with `str` (53 occurrences).

Add `import std::string` at the top of the module (after the `module tester` line).

Convert all magic method calls to explicit library calls:
- `s.toUpper()` → `string.toUpper(s)`
- `s.toLower()` → `string.toLower(s)`
- `s.contains("x")` → `string.contains(s, "x")`
- `s.replace("a", "b")` → `string.replace(s, "a", "b")`
- `s.repeat(3)` → `string.repeat(s, 3)`
- `s.parseInt()` → `string.parseInt(s)`
- `s.parseFloat()` → `string.parseFloat(s)`
- `x.toString()` → `string.toString(x)`
- `msg.contains("x")` → `string.contains(msg, "x")`

Convert string equality (line 1269):
- `if(a == "hello")` → `if(string.equals(a, "hello"))`

Note: `arr.splitAt(3)` on line 925 is array destructuring, NOT string — leave it alone.

Note: `h.join()` on line 1377 is a thread handle join, NOT string — leave it alone.

- [ ] **Step 2: Update other fixture files**

Replace `String` → `str` in all other fixture files:
- `fail_types.orh`: line 82
- `tester_main.orh`: lines 116, 123
- `fail_structs.orh`: lines 10, 17
- `fail_did_you_mean.orh`: lines 9, 14
- `fail_functions.orh`: line 13
- `fail_ownership.orh`: line 10
- `fail_match.orh`: lines 18, 33

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/
git commit -m "fixtures: String → str, magic methods → string.method() calls"
```

---

### Task 9: Update example module templates

**Files:**
- Modify: `src/templates/example/strings.orh` — `String` → `str`, add import, convert method calls
- Modify: `src/templates/example/example.orh` — `String` → `str`
- Modify: `src/templates/example/advanced.orh` — `String` → `str`
- Modify: `src/templates/example/error_handling.orh` — `String` → `str`
- Modify: `src/templates/example/data_types.orh` — `String` → `str`
- Modify: `src/templates/example/control_flow.orh` — `String` → `str`
- Modify: `src/templates/project.orh` — if it references `String`

- [ ] **Step 1: Update `strings.orh`**

Add `import std::string` after the `module example` line.

Replace all `String` type annotations with `str`.

Convert all magic method calls to `string.method(s, ...)` pattern (same as tester.orh).

- [ ] **Step 2: Update other template files**

Replace `String` → `str` in: `example.orh`, `advanced.orh`, `error_handling.orh`, `data_types.orh`, `control_flow.orh`.

- [ ] **Step 3: Commit**

```bash
git add src/templates/
git commit -m "templates: String → str, magic methods → string.method() calls"
```

---

### Task 10: Update error test expectations and add `str ==` error test

**Files:**
- Modify: `test/11_errors.sh` — update any expected error messages that reference `String`
- Modify: `test/fixtures/` — add a fixture for `str ==` compile error if needed

- [ ] **Step 1: Check error tests for `String` references**

Search `test/11_errors.sh` for `String` in expected error messages and update to `str`.

- [ ] **Step 2: Add error test for `str ==`**

If there isn't already a fixture testing `str ==`, create a small test case in the appropriate error fixture (or add to `test/11_errors.sh` inline) that verifies `a == "hello"` on a `str` variable produces the expected error: `cannot use '==' on str — use string.equals()`.

- [ ] **Step 3: Run full test suite**

Run: `./testall.sh`
Expected: All tests pass (307 or more)

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: update error expectations for str rename, add str == error test"
```

---

### Task 11: Update documentation

**Files:**
- Modify: `docs/02-types.md` — if it references `String`
- Modify: `docs/09-memory.md` — if it references `String`
- Modify: `docs/14-zig-bridge.md` — if it references `String`
- Modify: `docs/COMPILER.md` — if it references `String`
- Modify: `CLAUDE.md` — if it references `String`

- [ ] **Step 1: Search and update all docs**

Search all `.md` files in `docs/` and project root for `String` used as a type name. Replace with `str`. Update any references to `std::str` → `std::string`.

- [ ] **Step 2: Update `docs/TODO.md`**

Mark the string rename task as done and add a brief note.

- [ ] **Step 3: Run full test suite one more time**

Run: `./testall.sh`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add docs/ CLAUDE.md
git commit -m "docs: String → str, std::str → std::string across all documentation"
```

---

### Task 12: Update codegen import path for `string` module

**Files:**
- Modify: `src/codegen/codegen.zig` — update import tracking to recognize `"string"` instead of `"str"`

- [ ] **Step 1: Update import path recognition**

Since we removed the auto-import and method dispatch in Task 5, the remaining import tracking for `"str"` was already removed. But we need to ensure the `import std::string` in user code generates the correct Zig import: `const string = @import("_orhon_string");`.

The zig-as-module system handles this automatically — when the user writes `import std::string`, the compiler sees a `.zig` file named `string.zig` in the std cache dir, auto-converts it, and generates the import with the module name `_orhon_string`. The `std_bundle.zig` writes it as `string.zig` (Task 2), and the build system registers it as `_orhon_string` (Task 3).

Verify this works by checking that `import std::string` correctly resolves. No code changes needed if the pipeline already handles this correctly — this is a verification step.

- [ ] **Step 2: Run full test suite**

Run: `./testall.sh`
Expected: All tests pass

- [ ] **Step 3: Final commit if any fixups needed**

```bash
git add -A
git commit -m "fix: string module import path fixups"
```
