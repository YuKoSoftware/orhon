# Compt Struct Introspection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 4 compile-time struct introspection compiler functions (`@hasField`, `@hasDecl`, `@fieldType`, `@fieldNames`) that map to Zig builtins.

**Architecture:** Each function follows the established compiler-function pipeline: register name in `builtins.zig` → add PEG grammar rule → add return type in resolver with argument validation → add Zig emission in codegen. All 4 functions accept a type or value as the first argument; when a value is passed, codegen wraps it in `@TypeOf(...)`.

**Tech Stack:** Zig 0.15.2+, PEG grammar, Orhon compiler pipeline (passes 1-12)

**Spec:** `docs/superpowers/specs/2026-03-31-compt-introspection-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/builtins.zig` | Modify | Register 4 new compiler function names |
| `src/peg/orhon.peg` | Modify | Add 4 entries to `compiler_func_name` rule |
| `src/resolver.zig` | Modify | Return types + argument count/type validation |
| `src/codegen/codegen_match.zig` | Modify | Zig builtin emission with `@TypeOf` wrapping |
| `test/fixtures/tester.orh` | Modify | Add introspection test functions |
| `test/fixtures/tester_main.orh` | Modify | Add runtime checks for introspection functions |
| `test/10_runtime.sh` | Modify | Register new test names in pass list |
| `docs/05-functions.md` | Modify | Document 4 new functions |

---

### Task 1: Register function names in builtins.zig

**Files:**
- Modify: `src/builtins.zig:20-31`

- [ ] **Step 1: Add 4 names to COMPILER_FUNCS array**

In `src/builtins.zig`, add the 4 new function names to the `COMPILER_FUNCS` array (after `"align"`):

```zig
pub const COMPILER_FUNCS = [_][]const u8{
    "typename",
    "typeid",
    "typeOf",
    "cast",
    "copy",
    "move",
    "swap",
    "assert",
    "size",
    "align",
    "hasField",
    "hasDecl",
    "fieldType",
    "fieldNames",
};
```

- [ ] **Step 2: Add unit test for new compiler functions**

In `src/builtins.zig`, extend the existing `"compiler func detection"` test block:

```zig
test "compiler func detection" {
    try std.testing.expect(isCompilerFunc("cast"));
    try std.testing.expect(isCompilerFunc("typeOf"));
    try std.testing.expect(!isCompilerFunc("print"));
    try std.testing.expect(isCompilerFunc("hasField"));
    try std.testing.expect(isCompilerFunc("hasDecl"));
    try std.testing.expect(isCompilerFunc("fieldType"));
    try std.testing.expect(isCompilerFunc("fieldNames"));
}
```

- [ ] **Step 3: Run unit tests**

Run: `zig build test 2>&1 | head -5`
Expected: All tests pass (including the new assertions).

- [ ] **Step 4: Commit**

```bash
git add src/builtins.zig
git commit -m "feat: register introspection compiler functions in builtins"
```

---

### Task 2: Add PEG grammar rules

**Files:**
- Modify: `src/peg/orhon.peg:416-419`

- [ ] **Step 1: Add 4 entries to compiler_func_name rule**

In `src/peg/orhon.peg`, extend the `compiler_func_name` rule. The existing rule is at lines 416-419:

```peg
compiler_func_name
    <- '@' 'cast' / '@' 'copy' / '@' 'move' / '@' 'swap'
     / '@' 'assert' / '@' 'size' / '@' 'align'
     / '@' 'typename' / '@' 'typeid' / '@' 'typeOf'
     / '@' 'hasField' / '@' 'hasDecl' / '@' 'fieldType' / '@' 'fieldNames'
```

- [ ] **Step 2: Update keyword comment block**

In `src/peg/orhon.peg` at lines 601-603, update the compiler function comment:

```peg
# Compiler functions use @ prefix: @cast @copy @move @swap @assert
# @size @align @typename @typeid @typeOf
# @hasField @hasDecl @fieldType @fieldNames
```

- [ ] **Step 3: Run unit tests to verify PEG grammar compiles**

Run: `zig build test 2>&1 | head -5`
Expected: All tests pass. The PEG grammar is loaded and validated at test time.

- [ ] **Step 4: Commit**

```bash
git add src/peg/orhon.peg
git commit -m "feat: add introspection functions to PEG grammar"
```

---

### Task 3: Add resolver return types and argument validation

**Files:**
- Modify: `src/resolver.zig:812-840`

The resolver's `.compiler_func` case (line 812) handles return type inference for compiler functions. We need to add return types and validate arguments for the 4 new functions.

- [ ] **Step 1: Add return type resolution and validation**

In `src/resolver.zig`, in the `.compiler_func => |cf|` case, after the existing `copy`/`move` block (line 838) and before `return RT.unknown;` (line 839), add:

```zig
                // Introspection functions
                if (std.mem.eql(u8, cf.name, "hasField") or std.mem.eql(u8, cf.name, "hasDecl")) {
                    if (cf.args.len != 2) {
                        const msg = try std.fmt.allocPrint(self.allocator, "@{s} takes exactly 2 arguments", .{cf.name});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    } else if (cf.args[1].* != .string_literal) {
                        const msg = try std.fmt.allocPrint(self.allocator, "@{s} requires a string literal as second argument", .{cf.name});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                    return RT{ .primitive = .bool };
                }
                if (std.mem.eql(u8, cf.name, "fieldType")) {
                    if (cf.args.len != 2) {
                        const msg = try std.fmt.allocPrint(self.allocator, "@fieldType takes exactly 2 arguments", .{});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    } else if (cf.args[1].* != .string_literal) {
                        const msg = try std.fmt.allocPrint(self.allocator, "@fieldType requires a string literal as second argument", .{});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                    return RT{ .primitive = .@"type" };
                }
                if (std.mem.eql(u8, cf.name, "fieldNames")) {
                    if (cf.args.len != 1) {
                        const msg = try std.fmt.allocPrint(self.allocator, "@fieldNames takes exactly 1 argument", .{});
                        defer self.allocator.free(msg);
                        try self.reporter.report(.{ .message = msg, .loc = self.nodeLoc(node) });
                    }
                    return RT.inferred;
                }
```

Note: `@fieldNames` returns a Zig comptime string slice — no Orhon type maps to this, so we use `RT.inferred`.

- [ ] **Step 2: Run unit tests**

Run: `zig build test 2>&1 | head -5`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/resolver.zig
git commit -m "feat: add resolver return types and validation for introspection functions"
```

---

### Task 4: Add codegen emission

**Files:**
- Modify: `src/codegen/codegen_match.zig:570-639`

- [ ] **Step 1: Add codegen for all 4 introspection functions**

In `src/codegen/codegen_match.zig`, in `generateCompilerFuncMir()`, before the final `else` block (line 636), add the 4 new function handlers. The key logic: check if the first argument's MIR kind is `.type_expr` — if yes, emit directly; if no, wrap in `@TypeOf(...)`.

Insert before `} else {` (line 636):

```zig
    } else if (std.mem.eql(u8, cf_name, "hasField")) {
        try cg.emit("@hasField(");
        if (args.len >= 1) {
            if (args[0].kind == .type_expr) {
                try cg.generateExprMir(args[0]);
            } else {
                try cg.emit("@TypeOf(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        }
        if (args.len >= 2) {
            try cg.emit(", ");
            try cg.generateExprMir(args[1]);
        }
        try cg.emit(")");
    } else if (std.mem.eql(u8, cf_name, "hasDecl")) {
        try cg.emit("@hasDecl(");
        if (args.len >= 1) {
            if (args[0].kind == .type_expr) {
                try cg.generateExprMir(args[0]);
            } else {
                try cg.emit("@TypeOf(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        }
        if (args.len >= 2) {
            try cg.emit(", ");
            try cg.generateExprMir(args[1]);
        }
        try cg.emit(")");
    } else if (std.mem.eql(u8, cf_name, "fieldType")) {
        try cg.emit("@FieldType(");
        if (args.len >= 1) {
            if (args[0].kind == .type_expr) {
                try cg.generateExprMir(args[0]);
            } else {
                try cg.emit("@TypeOf(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        }
        if (args.len >= 2) {
            try cg.emit(", ");
            try cg.generateExprMir(args[1]);
        }
        try cg.emit(")");
    } else if (std.mem.eql(u8, cf_name, "fieldNames")) {
        try cg.emit("std.meta.fieldNames(");
        if (args.len >= 1) {
            if (args[0].kind == .type_expr) {
                try cg.generateExprMir(args[0]);
            } else {
                try cg.emit("@TypeOf(");
                try cg.generateExprMir(args[0]);
                try cg.emit(")");
            }
        }
        try cg.emit(")");
    }
```

- [ ] **Step 2: Run unit tests**

Run: `zig build test 2>&1 | head -5`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/codegen/codegen_match.zig
git commit -m "feat: add codegen for introspection functions"
```

---

### Task 5: Add integration tests

**Files:**
- Modify: `test/fixtures/tester.orh`
- Modify: `test/fixtures/tester_main.orh`
- Modify: `test/10_runtime.sh`

- [ ] **Step 1: Add introspection test functions to tester.orh**

At the end of `test/fixtures/tester.orh` (before the last closing content), add:

```orhon
// ─── Struct Introspection ────────────────────────────────────

pub func test_has_field() i32 {
    if(@hasField(Vec2, "x")) {
        return 1
    }
    return 0
}

pub func test_has_field_missing() i32 {
    if(@hasField(Vec2, "z")) {
        return 0
    }
    return 1
}

pub func test_has_field_value() i32 {
    var v: Vec2 = Vec2(x: 1.0, y: 2.0)
    if(@hasField(v, "x")) {
        return 1
    }
    return 0
}

pub func test_has_decl() i32 {
    if(@hasDecl(Counter, "create")) {
        return 1
    }
    return 0
}

pub func test_has_decl_missing() i32 {
    if(@hasDecl(Vec2, "nonexistent")) {
        return 0
    }
    return 1
}

pub func test_field_type() i32 {
    // @fieldType(Vec2, "x") is f32, @size(f32) == 4
    if(@size(@fieldType(Vec2, "x")) == 4) {
        return 1
    }
    return 0
}

pub func test_field_names() i32 {
    // @fieldNames(Vec2) returns a comptime slice — .len == 2 (x, y)
    if(@fieldNames(Vec2).len == 2) {
        return 1
    }
    return 0
}
```

- [ ] **Step 2: Add runtime checks to tester_main.orh**

In `test/fixtures/tester_main.orh`, before the `console.println("TESTER:DONE")` line, add:

```orhon
    // Struct introspection
    if(tester.test_has_field() == 1) {
        console.println("PASS has_field")
    } else {
        console.println("FAIL has_field")
    }

    if(tester.test_has_field_missing() == 1) {
        console.println("PASS has_field_missing")
    } else {
        console.println("FAIL has_field_missing")
    }

    if(tester.test_has_field_value() == 1) {
        console.println("PASS has_field_value")
    } else {
        console.println("FAIL has_field_value")
    }

    if(tester.test_has_decl() == 1) {
        console.println("PASS has_decl")
    } else {
        console.println("FAIL has_decl")
    }

    if(tester.test_has_decl_missing() == 1) {
        console.println("PASS has_decl_missing")
    } else {
        console.println("FAIL has_decl_missing")
    }

    if(tester.test_field_type() == 1) {
        console.println("PASS field_type")
    } else {
        console.println("FAIL field_type")
    }

    if(tester.test_field_names() == 1) {
        console.println("PASS field_names")
    } else {
        console.println("FAIL field_names")
    }
```

- [ ] **Step 3: Register test names in test/10_runtime.sh**

In `test/10_runtime.sh`, add the new test names to the `for TEST_NAME in` list. After `empty_struct_construct` in the list, add:

```
    has_field has_field_missing has_field_value \
    has_decl has_decl_missing \
    field_type field_names \
```

- [ ] **Step 4: Build the compiler and run the full test suite**

Run: `zig build && ./testall.sh 2>&1 | tail -30`
Expected: All tests pass, including the 5 new runtime tests.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/tester.orh test/fixtures/tester_main.orh test/10_runtime.sh
git commit -m "test: add integration tests for introspection functions"
```

---

### Task 6: Add negative tests for validation errors

**Files:**
- Create: `test/fixtures/fail_introspection.orh`
- Modify: `test/11_errors.sh`

- [ ] **Step 1: Create negative test fixture**

Create `test/fixtures/fail_introspection.orh`:

```orhon
module main

#name    = "fail_introspection"
#version = (1, 0, 0)
#build   = exe

struct Point {
    x: f32
    y: f32
}

func main() void {
    // Wrong arg count — should fail with "@hasField takes exactly 2 arguments"
    const a: bool = @hasField(Point)
    // Non-string second arg — should fail with "@hasField requires a string literal"
    const b: bool = @hasField(Point, 42)
}
```

- [ ] **Step 2: Add error test to 11_errors.sh**

In `test/11_errors.sh`, at the end of the file (before any final cleanup), add:

```bash
# introspection — wrong argument count / type
cd "$TESTDIR"
mkdir -p neg_introspect/src
cp "$FIXTURES/fail_introspection.orh" neg_introspect/src/main.orh
cd neg_introspect
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "@hasField\|error"; then
    pass "rejects bad introspection args"
else
    fail "rejects bad introspection args" "$NEG_OUT"
fi
```

- [ ] **Step 3: Run the error test stage**

Run: `bash test/11_errors.sh 2>&1 | tail -10`
Expected: "rejects bad introspection args" passes.

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/fail_introspection.orh test/11_errors.sh
git commit -m "test: add negative tests for introspection argument validation"
```

---

### Task 7: Update documentation

**Files:**
- Modify: `docs/05-functions.md:124-193`

- [ ] **Step 1: Add introspection functions to the quick-reference list**

In `docs/05-functions.md`, in the compiler function quick-reference block (after `align(x)` on line 138), add:

```
hasField(T, "name")     // true if struct T has a field named "name"
hasDecl(T, "name")      // true if type T has a declaration (method, const) named "name"
fieldType(T, "name")    // returns the type of field "name" on struct T
fieldNames(T)           // returns comptime slice of all field names on struct T
```

- [ ] **Step 2: Add detailed sections for each function**

In `docs/05-functions.md`, after the `align` section (after line 193), add:

```markdown
### `hasField` — struct field check
Returns `true` if the struct type has a field with the given name. Works with types and values. Compile-time evaluation — zero runtime cost.
```
hasField(Point, "x")       // true
hasField(Point, "z")       // false
hasField(my_point, "x")    // true — value is auto-wrapped in typeOf
```

### `hasDecl` — declaration check
Returns `true` if the type has any declaration (method, compt function, constant) with the given name. Useful for conditional logic based on type capabilities.
```
hasDecl(Counter, "create")     // true — Counter has a create method
hasDecl(Vec2, "nonexistent")   // false
```

### `fieldType` — field type extraction
Returns the compile-time `type` of a named field on a struct. Can be stored in a `const` or used in compt code for type-level programming.
```
const XType: type = fieldType(Point, "x")   // f32
```

### `fieldNames` — all field names
Returns a compile-time slice of all field names on a struct. Primary use: iterating fields in compt for-loops for auto-derive patterns.
```
compt for(fieldNames(Point)) |name| {
    // name is a comptime string: "x", "y"
}
```
```

- [ ] **Step 3: Commit**

```bash
git add docs/05-functions.md
git commit -m "docs: document introspection compiler functions"
```

---

### Task 8: Run full test suite and verify

- [ ] **Step 1: Build the compiler**

Run: `zig build 2>&1`
Expected: Clean build with no errors.

- [ ] **Step 2: Run the full test suite**

Run: `./testall.sh 2>&1 | tail -40`
Expected: All tests pass (277 existing + 7 new runtime + 1 new error = 285 total approximately).

- [ ] **Step 3: Verify codegen output for introspection**

Run a quick check that the generated Zig contains the expected builtins:

```bash
cd /tmp && mkdir -p introtest/src && cd introtest
cat > src/main.orh << 'EOF'
module main
#name = "introtest"
#version = (1, 0, 0)
#build = exe

import std::console

struct Point {
    pub x: f32
    pub y: f32
}

func main() void {
    if(@hasField(Point, "x")) {
        console.println("field found")
    }
}
EOF
/path/to/orhon build 2>&1
grep -n "hasField\|@HasField\|@hasField" .orh-cache/generated/*.zig || echo "NOT FOUND"
```

Expected: The generated Zig should contain `@hasField(Point, "x")`.

- [ ] **Step 4: Final commit — version bump**

After all tests pass, this is a good place for a version bump if desired by the user.
