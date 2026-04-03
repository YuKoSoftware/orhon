# Module Naming Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `module main` convention with project-name-based module naming, remove `kw_main` keyword, add semantic validation for `main` as reserved entry point name, enforce project layout rules.

**Architecture:** Remove `main` from keyword table so it becomes a regular identifier. Update PEG grammar to remove `'main'` alternatives. Add semantic checks in `module.zig` (layout rules, primary module detection) and `declarations.zig` (reserved name, exe entry point validation). Update `init.zig` to scaffold project-named modules. Update all tests and docs.

**Tech Stack:** Zig 0.15.2+, PEG grammar, shell test scripts

**Spec:** `docs/superpowers/specs/2026-03-31-module-naming-redesign.md`

---

### Task 1: Remove `kw_main` from Lexer and Token Map

**Files:**
- Modify: `src/lexer.zig:46` (remove `kw_main` from `TokenKind` enum)
- Modify: `src/lexer.zig:148` (remove `"main"` → `.kw_main` from keyword table)
- Modify: `src/peg/token_map.zig:42` (remove `"main"` → `.kw_main` mapping)

- [ ] **Step 1: Remove `kw_main` from `TokenKind` enum in `src/lexer.zig`**

Delete line 46:
```zig
    kw_main,
```

- [ ] **Step 2: Remove `"main"` from keyword table in `src/lexer.zig`**

Delete line 148:
```zig
    .{ "main",     .kw_main },
```

- [ ] **Step 3: Remove `"main"` from PEG token map in `src/peg/token_map.zig`**

Delete line 42:
```zig
    .{ "main", .kw_main },
```

- [ ] **Step 4: Fix all compile errors from removed `kw_main`**

The following files reference `.kw_main` and need updating:

**`src/peg/builder_decls.zig:72`** — remove the `kw_main` fallback in `buildModuleDecl`:
```zig
// Before:
    const name_pos = builder.findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .identifier) orelse
        builder.findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .kw_main) orelse
        return error.NoModuleName;

// After:
    const name_pos = builder.findTokenInRange(ctx, cap.start_pos + 1, cap.end_pos, .identifier) orelse
        return error.NoModuleName;
```

**`src/peg/builder_decls.zig:93`** — remove `.kw_main` from import path token check:
```zig
// Before:
        } else if (tok.kind == .identifier or tok.kind == .kw_main) {

// After:
        } else if (tok.kind == .identifier) {
```

**`src/lsp/lsp_semantic.zig:96`** — remove `.kw_main` from keyword list:
```zig
// Before:
        .kw_void, .kw_main, .kw_type,

// After:
        .kw_void, .kw_type,
```

- [ ] **Step 5: Update PEG engine test in `src/peg/engine.zig`**

The test at line 343 ("engine - match choice") tests matching `'main'` as a keyword token. Since `main` is now an identifier, update the test to use a different keyword or remove the `'main'` part:

```zig
test "engine - match choice" {
    const alloc = std.testing.allocator;
    const grammar_mod2 = @import("grammar.zig");

    const src = "name\n    <- IDENTIFIER / 'void'\n";
    var g = try grammar_mod2.parseGrammar(src, alloc);
    defer g.deinit();

    // Test with identifier
    const tokens1 = [_]Token{
        .{ .kind = .identifier, .text = "foo", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 4 },
    };
    var e1 = Engine.init(&g, &tokens1, alloc);
    defer e1.deinit();
    try std.testing.expect(e1.matchAll("name"));

    // Test with 'void' keyword
    const tokens2 = [_]Token{
        .{ .kind = .kw_void, .text = "void", .line = 1, .col = 1 },
        .{ .kind = .eof, .text = "", .line = 1, .col = 5 },
    };
    var e2 = Engine.init(&g, &tokens2, alloc);
    defer e2.deinit();
    try std.testing.expect(e2.matchAll("name"));
}
```

- [ ] **Step 6: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS — all unit tests pass with `kw_main` removed

- [ ] **Step 7: Commit**

```bash
git add src/lexer.zig src/peg/token_map.zig src/peg/builder_decls.zig src/peg/engine.zig src/lsp/lsp_semantic.zig
git commit -m "refactor: remove kw_main keyword — main is now a regular identifier"
```

---

### Task 2: Update PEG Grammar

**Files:**
- Modify: `src/peg/orhon.peg:45,67,115` (remove `'main'` alternatives)

- [ ] **Step 1: Update `module_decl` rule at line 45**

```peg
# Before:
module_decl
    <- doc_block? 'module' (IDENTIFIER / 'main') NL  {label: "module declaration"}

# After:
module_decl
    <- doc_block? 'module' IDENTIFIER NL  {label: "module declaration"}
```

- [ ] **Step 2: Update `import_path` rule at line 67**

```peg
# Before:
     / (IDENTIFIER / 'main') '::' IDENTIFIER   # scoped: std::console, global::utils

# After:
     / IDENTIFIER '::' IDENTIFIER   # scoped: std::console, global::utils
```

- [ ] **Step 3: Update `func_name` rule at line 115**

```peg
# Before:
func_name
    <- IDENTIFIER / 'main'

# After:
func_name
    <- IDENTIFIER
```

- [ ] **Step 4: Update the keyword comment at line 619**

```peg
# Before:
# any module test and or not main as break continue true false

# After:
# any module test and or not as break continue true false
```

- [ ] **Step 5: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/peg/orhon.peg
git commit -m "refactor: remove 'main' alternatives from PEG grammar"
```

---

### Task 3: Update Builder and Unit Tests for New Module Names

**Files:**
- Modify: `src/peg/builder.zig:440-488` (update test module names)
- Modify: `src/declarations.zig:633,680,718,760` (update test module names)
- Modify: `src/resolver.zig:1489,1500` (update test module names)
- Modify: `src/pipeline.zig:1095,1163` (update test module names)
- Modify: `src/lsp/lsp_utils.zig:421` (update test expectation)

- [ ] **Step 1: Update builder.zig tests**

In `src/peg/builder.zig`, update tests starting at line 440:

```zig
// Line 440 — change "module main\n" to "module myapp\n"
    var lex = lexer.Lexer.init("module myapp\n");
```

```zig
// Line 452 — update expectation
    try std.testing.expectEqualStrings("myapp", result.node.program.module.module_decl.name);
```

```zig
// Line 463 — change the multiline string test
    var lex = lexer.Lexer.init(
        \\module myapp
        \\
        \\func add(a: i32, b: i32) i32 {
        \\    return a + b
        \\}
        \\
    );
```

```zig
// Line 481 — update expectation
    try std.testing.expectEqualStrings("myapp", prog.module.module_decl.name);
```

- [ ] **Step 2: Update declarations.zig test module names**

At lines 633, 680, 718, 760 — change all `.name = "main"` in test `module_decl` nodes to `.name = "testmod"`:

```zig
// Each test creates a module_decl node — update all four:
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
```

- [ ] **Step 3: Update resolver.zig test module names**

At lines 1489 and 1500 — change `.name = "main"` to `.name = "testmod"`:

```zig
        .name = "testmod",
```
```zig
    module_node.* = .{ .module_decl = .{ .name = "testmod" } };
```

- [ ] **Step 4: Update pipeline.zig test module names**

At lines 1095 and 1163 — change `"main"` to `"testmod"`:

```zig
    try cg.generate(ast, "testmod");
```

- [ ] **Step 5: Update lsp_utils.zig test expectation**

At line 421:
```zig
// Before:
    try std.testing.expectEqualStrings("main", word.?);
// After (check what this test actually does — if it's testing word extraction at a cursor position, the expected word depends on the input):
```

Read the full test to determine the correct fix — if the test input contains "main" as text, update both input and expectation.

- [ ] **Step 6: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add src/peg/builder.zig src/declarations.zig src/resolver.zig src/pipeline.zig src/lsp/lsp_utils.zig
git commit -m "refactor: update unit tests to use project-named modules instead of module main"
```

---

### Task 4: Add Semantic Validation for `main` as Reserved Name

**Files:**
- Modify: `src/module.zig` (add primary module detection and layout validation)
- Modify: `src/declarations.zig` (add reserved name check and exe entry point validation)

- [ ] **Step 1: Add `module main` rejection in `src/module.zig`**

In `parseModules()`, after reading the module name (around line 620 area where module names are processed), add a check that rejects `module main`:

```zig
// After extracting mod_name from the parsed AST:
if (std.mem.eql(u8, mod_name, "main")) {
    const msg = try self.allocator.allocPrint(
        "'main' is reserved for the executable entry point — use your project name as the module name",
        .{},
    );
    defer self.allocator.free(msg);
    try self.reporter.report(.{ .message = msg });
}
```

Find the exact location by reading where `mod_name` is first extracted in `parseModules()`.

- [ ] **Step 2: Add layout validation in `src/module.zig`**

After all modules are parsed (end of `parseModules()`), add validation for exe layout rules. This needs the project folder name, which is derived from the current working directory:

```zig
// After all modules parsed, validate exe layout rules:
// 1. Find project folder name (cwd basename)
const cwd_path = try std.fs.cwd().realpathAlloc(self.allocator, ".");
defer self.allocator.free(cwd_path);
const folder_name = std.fs.path.basename(cwd_path);

// 2. Check: only one #build=exe in src/ top-level, and it must match folder name
var mod_it = self.modules.iterator();
while (mod_it.next()) |entry| {
    const mod = entry.value_ptr;
    if (!mod.is_root or mod.build_type != .exe) continue;

    // Check if anchor file is in src/ top-level (not nested)
    const anchor_file = mod.files[0]; // anchor is always first
    const anchor_dir = std.fs.path.dirname(anchor_file) orelse ".";
    const is_top_level = std.mem.eql(u8, anchor_dir, "src");

    if (is_top_level and !std.mem.eql(u8, mod.name, folder_name)) {
        const msg = try std.fmt.allocPrint(self.allocator,
            "only the primary module '{s}' may use #build = exe in src/ — move '{s}' to a subdirectory",
            .{ folder_name, mod.name });
        defer self.allocator.free(msg);
        try self.reporter.report(.{ .message = msg });
    }
}
```

- [ ] **Step 3: Add `func main()` validation in `src/declarations.zig`**

In `DeclCollector`, after collecting all declarations for a module, add checks:

1. If a non-function declaration uses the name `main`, report error
2. If a `func main()` appears in a non-exe module, report error
3. If an exe module has no `func main()` in its anchor, report error

Find the appropriate location in `collectTopLevel()` or the end of declaration collection where the module's build_type is known. The checks:

```zig
// Check: 'main' reserved for entry point
for (top_level) |node| {
    switch (node.*) {
        .var_decl => |v| {
            if (std.mem.eql(u8, v.name, "main")) {
                // report: "'main' is reserved for the executable entry point"
            }
        },
        .const_decl => |c| {
            if (std.mem.eql(u8, c.name, "main")) {
                // report: "'main' is reserved for the executable entry point"
            }
        },
        .struct_decl => |s| {
            if (std.mem.eql(u8, s.name, "main")) {
                // report: "'main' is reserved for the executable entry point"
            }
        },
        .enum_decl => |e| {
            if (std.mem.eql(u8, e.name, "main")) {
                // report: "'main' is reserved for the executable entry point"
            }
        },
        .func_decl => |f| {
            if (std.mem.eql(u8, f.name, "main") and !is_exe_module) {
                // report: "func main() is only allowed in executable modules"
            }
        },
        else => {},
    }
}

// Check: exe modules must have func main()
if (is_exe_module) {
    var has_main = false;
    for (top_level) |node| {
        if (node.* == .func_decl and std.mem.eql(u8, node.func_decl.name, "main")) {
            has_main = true;
            break;
        }
    }
    if (!has_main) {
        // report: "executable module '{name}' requires func main() in anchor file"
    }
}
```

Note: The exact integration point depends on how `build_type` is accessible in `declarations.zig`. The module's `build_type` is set in `module.zig` during `parseModules()`, so it's available on the `Module` struct. You may need to pass `build_type` through to the declaration collector, or perform these checks in `pipeline.zig` after both module resolution and declaration collection are complete.

- [ ] **Step 4: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/module.zig src/declarations.zig
git commit -m "feat: add semantic validation — main reserved, exe layout rules"
```

---

### Task 5: Update `orhon init` Scaffolding

**Files:**
- Rename: `src/templates/main.orh` → `src/templates/project.orh`
- Modify: `src/templates/project.orh` (update `module main` → `module {s}`)
- Modify: `src/init.zig` (new template name, project-named output file, two-placeholder handling)

- [ ] **Step 1: Rename and update the template**

Rename `src/templates/main.orh` to `src/templates/project.orh` and update content:

```orh
module {s}

#name    = "{s}"
#version = (1, 0, 0)
#build   = exe

import std::console

func main() void {
    console.println("hello orhon !")
}
```

Note: two `{s}` placeholders now — both get the project name.

- [ ] **Step 2: Update `src/init.zig` — template constant**

```zig
// Before:
const MAIN_ORH_TEMPLATE         = @embedFile("templates/main.orh");

// After:
const PROJECT_ORH_TEMPLATE      = @embedFile("templates/project.orh");
```

- [ ] **Step 3: Update `src/init.zig` — output file path**

Change the output file from `src/main.orh` to `src/{name}.orh`:

```zig
// Before (line 52):
    const main_orh_path = try std.fs.path.join(allocator, &.{ base, "src", "main.orh" });
    defer allocator.free(main_orh_path);

// After:
    const project_orh_name = try std.fmt.allocPrint(allocator, "{s}.orh", .{name});
    defer allocator.free(project_orh_name);
    const project_orh_path = try std.fs.path.join(allocator, &.{ base, "src", project_orh_name });
    defer allocator.free(project_orh_path);
```

- [ ] **Step 4: Update `src/init.zig` — template writing with multiple placeholders**

Replace the single-placeholder split-write with a loop that handles all `{s}` occurrences:

```zig
    if (std.fs.cwd().access(project_orh_path, .{})) |_| {
        // project file exists — don't overwrite
    } else |_| {
        const file = try std.fs.cwd().createFile(project_orh_path, .{});
        defer file.close();

        // Write template, replacing all {s} placeholders with project name
        const placeholder = "{s}";
        var remaining: []const u8 = PROJECT_ORH_TEMPLATE;
        while (std.mem.indexOf(u8, remaining, placeholder)) |pos| {
            try file.writeAll(remaining[0..pos]);
            try file.writeAll(name);
            remaining = remaining[pos + placeholder.len..];
        }
        try file.writeAll(remaining);
    }
```

- [ ] **Step 5: Update success messages at end of `initProject()`**

```zig
// Before:
    std.debug.print("  {s}/src/main.orh\n", .{base});

// After:
    std.debug.print("  {s}/src/{s}.orh\n", .{ base, name });
```

- [ ] **Step 6: Update the error hint in `pipeline.zig` line 52**

```zig
// Before:
        std.debug.print("  expected: {s}/main.orh\n", .{cli.source_dir});

// After:
        std.debug.print("  expected: {s}/<project_name>.orh with #build = exe\n", .{cli.source_dir});
```

- [ ] **Step 7: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add src/templates/project.orh src/init.zig src/pipeline.zig
git rm src/templates/main.orh
git commit -m "feat: orhon init scaffolds project-named module instead of module main"
```

---

### Task 6: Update Pipeline — Primary Module Detection and `orhon run`

**Files:**
- Modify: `src/pipeline.zig:403,495-544` (derive primary from folder name, not first-found)

- [ ] **Step 1: Add folder name detection at start of `runPipeline()`**

Near the top of `runPipeline()`, after the source dir check (around line 54), derive the project folder name:

```zig
    // Derive project folder name for primary module detection
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    const project_folder_name = std.fs.path.basename(cwd_path);
```

- [ ] **Step 2: Update exe binary name selection (multi-target path)**

In the multi-target section (lines 506-544), change `exe_binary_name` to prefer the primary module:

```zig
// Replace the existing logic at line 541-544:
            if (std.mem.eql(u8, build_type, "exe")) {
                // Primary module (name matches folder) gets priority for orhon run
                if (std.mem.eql(u8, mod.name, project_folder_name)) {
                    if (exe_binary_name) |old| allocator.free(old);
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                } else if (exe_binary_name == null) {
                    exe_binary_name = try allocator.dupe(u8, binary_name);
                }
            }
```

- [ ] **Step 3: Update test command fallback at line 403**

```zig
// Before:
        var last_binary_name: []const u8 = "main";

// After:
        var last_binary_name: []const u8 = project_folder_name;
```

- [ ] **Step 4: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline.zig
git commit -m "feat: primary module detection uses project folder name for orhon run"
```

---

### Task 7: Update Zig Runner Tests

**Files:**
- Modify: `src/zig_runner/zig_runner_build.zig:565,605,613,622` (test module names)
- Modify: `src/zig_runner/zig_runner_multi.zig:652,674,687,707,731,766,791` (test module names)

- [ ] **Step 1: Update `zig_runner_build.zig` test strings**

Change all `"main"` module names in test calls to `"myapp"`:

```zig
// Line 565:
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);

// Line 605:
    const content = try buildZigContent(alloc, "calculator", "exe", "calculator", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);

// Line 613:
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &libs, &.{}, &.{}, &.{}, &.{}, false, null);

// Line 622:
    const content = try buildZigContent(alloc, "myapp", "exe", "myapp", null, &.{}, &.{}, &.{}, &.{}, &.{}, false, null);
```

- [ ] **Step 2: Update `zig_runner_multi.zig` test strings**

Change all `.module_name = "main"` to `.module_name = "myapp"`:

```zig
// Lines 652, 674, 687, 707, 731, 766, 791 — each has:
        .{ .module_name = "myapp", .project_name = "myapp", .build_type = "exe", ... },
```

- [ ] **Step 3: Run unit tests**

Run: `zig build test 2>&1`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/zig_runner/zig_runner_build.zig src/zig_runner/zig_runner_multi.zig
git commit -m "refactor: update zig runner tests to use project-named modules"
```

---

### Task 8: Update Test Fixtures

**Files:**
- Modify: All 26 fixture files in `test/fixtures/` that use `module main`

- [ ] **Step 1: Rename fixture modules**

Each test fixture uses `module main` on line 1. Update them to use a test-appropriate module name. Since these are standalone test files run inside temp project directories, use the name the test script gives the project folder.

For **fail_* fixtures** — these are compiled inside temp dirs created by `test/11_errors.sh`. Check what folder name the test script uses (typically `test_project` or similar), and use that as the module name. If the test script creates a folder called `test_project`, the fixture should use `module test_project`.

Read `test/11_errors.sh` to determine the folder name used, then update all fixtures accordingly.

For **positive fixtures** (blueprint_main.orh, tester_main.orh, union_flatten.orh) — same approach: check which test script uses them and what project folder they land in.

Update all 26 files: change `module main` to the appropriate project-folder-matching module name.

- [ ] **Step 2: Run full test suite to verify**

Run: `./testall.sh 2>&1`
Expected: Some tests will fail because test scripts also need updating (Task 9). That's expected — verify only that fixture changes are syntactically correct.

- [ ] **Step 3: Commit**

```bash
git add test/fixtures/
git commit -m "refactor: update test fixtures to use project-named modules"
```

---

### Task 9: Update Test Scripts

**Files:**
- Modify: `test/04_init.sh` (check for project-named file instead of main.orh)
- Modify: `test/05_compile.sh` (update inline `module main` to project name)
- Modify: `test/06_library.sh` (update consumer project module name)
- Modify: `test/07_multimodule.sh` (update inline `module main` references)
- Modify: `test/08_codegen.sh` (update generated file checks and inline module)
- Modify: `test/11_errors.sh` (update all inline `module main` declarations)
- Modify: `test/snapshots/snap_*.orh` (update module names)

- [ ] **Step 1: Update `test/04_init.sh`**

Change checks from `main.orh` to project-named file. The test creates a project called `testproj`, so the primary module file should be `testproj.orh`:

```bash
# Before:
if head -1 testproj/src/main.orh | grep -q "^module main$"; then
    pass "main.orh has 'module main'"

# After:
if head -1 testproj/src/testproj.orh | grep -q "^module testproj$"; then
    pass "testproj.orh has 'module testproj'"
```

Also update the `creates main.orh` existence check:
```bash
# Before: checks for testproj/src/main.orh
# After: checks for testproj/src/testproj.orh
```

And update the in-place init test similarly — check what folder name it uses.

- [ ] **Step 2: Update `test/05_compile.sh`**

Find inline `module main` declarations and update to match the temp project folder name used by the script. Read the script to find the folder name.

- [ ] **Step 3: Update `test/06_library.sh`**

Update the consumer project's inline `module main` to match the consumer project's folder name.

- [ ] **Step 4: Update `test/07_multimodule.sh`**

Update all four inline `module main` declarations (lines 22, 59, 106, 171) to match the respective project folder names.

- [ ] **Step 5: Update `test/08_codegen.sh`**

Update the `"// generated from module main"` grep check (line 20) and the inline `module main` declaration (line 66).

- [ ] **Step 6: Update `test/11_errors.sh`**

This has ~20 inline `module main` declarations. Each test creates a temp project — update all to match their respective folder names.

- [ ] **Step 7: Update snapshot files**

Update `test/snapshots/snap_basics_main.orh`, `snap_structs_main.orh`, `snap_control_main.orh`, `snap_errors_main.orh` — change `module main` on line 1 to match the folder name used by the snapshot test.

- [ ] **Step 8: Add new negative tests**

Add tests in `test/11_errors.sh` for the new validation rules:

1. **Rejects `module main`** — create a project with `module main`, expect compile error
2. **Rejects non-primary exe in src/ top-level** — create a project with two `#build = exe` at src/ top-level, expect error
3. **Rejects `func main()` in library module** — create a lib module with `func main()`, expect error

Add corresponding fixture files if needed.

- [ ] **Step 9: Run full test suite**

Run: `./testall.sh 2>&1`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
git add test/
git commit -m "feat: update all tests for project-named modules, add negative tests for new rules"
```

---

### Task 10: Update Documentation

**Files:**
- Modify: `docs/11-modules.md` (11 references to `module main`)
- Modify: `docs/13-build-cli.md` (2 references to `module main`)

- [ ] **Step 1: Update `docs/11-modules.md`**

Replace all `module main` references with project-name examples. Update:
- Anchor file naming convention examples
- Project root definition examples
- Error case examples
- Metadata examples
- Add section explaining primary module detection rules

- [ ] **Step 2: Update `docs/13-build-cli.md`**

Update the generated code examples (2 references) to show project-named modules.

- [ ] **Step 3: Commit**

```bash
git add docs/11-modules.md docs/13-build-cli.md
git commit -m "docs: update module and build docs for project-named modules"
```

---

### Task 11: Version Bump and Final Verification

**Files:**
- Modify: `build.zig.zon:4` (bump version to 0.14.0)

- [ ] **Step 1: Run full test suite**

Run: `./testall.sh 2>&1`
Expected: All tests pass

- [ ] **Step 2: Bump version**

In `build.zig.zon`, change:
```zig
// Before:
    .version = "0.13.1",

// After:
    .version = "0.14.0",
```

This is a minor version bump — breaking change (module main removed).

- [ ] **Step 3: Run tests again after version bump**

Run: `./testall.sh 2>&1`
Expected: All tests pass

- [ ] **Step 4: Commit and push**

```bash
git add build.zig.zon
git commit -m "bump version to 0.14.0 — project-named modules"
git push
```
