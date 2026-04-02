# Unify build.zig Generation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate `buildZigContent()` by routing all build.zig generation through `buildZigContentMulti()`, with single-target projects becoming a single-element `MultiTarget` array.

**Architecture:** Delete `buildZigContent()` (~430 lines). Fix `buildZigContentMulti()` to generate test steps for library-only builds (currently skipped — only exe targets get tests). Collapse `generateBuildZig()`/`generateBuildZigWithTests()` into a single method that constructs a `MultiTarget` and calls `buildZigContentMulti()`. Migrate unit tests.

**Tech Stack:** Zig 0.15.2+, no new dependencies.

---

### Task 1: Fix multi-target test step generation for library-only builds

The multi path only generates a test step when there's an exe target. Single-target library builds (static/dynamic) must also have test steps. This fix must land first so the unification produces correct output for library builds.

**Files:**
- Modify: `src/zig_runner/zig_runner_multi.zig:540-614`

- [ ] **Step 1: Update test step generation to fall back to first target**

In `src/zig_runner/zig_runner_multi.zig`, the test step block at line 540 currently loops through targets looking for an exe. After the loop, if no exe was found, it should fall back to the first target.

Change the block from:

```zig
    // Test step — use the first exe target's module for tests
    for (targets) |t| {
        if (std.mem.eql(u8, t.build_type, "exe")) {
            // ... generate test chunk ...
            break;
        }
    }
```

To using a chosen target variable:

```zig
    // Test step — prefer first exe target, fall back to first target for lib-only builds
    var test_target: ?MultiTarget = null;
    for (targets) |t| {
        if (std.mem.eql(u8, t.build_type, "exe")) {
            test_target = t;
            break;
        }
    }
    if (test_target == null and targets.len > 0) test_target = targets[0];

    if (test_target) |t| {
        // ... existing test chunk generation using `t` ...
    }
```

The body of the `if (test_target) |t|` block is identical to the existing code that was inside the `if (std.mem.eql(u8, t.build_type, "exe"))` block (lines 543-613), just with the outer `for` loop removed.

Important: keep the `unit_tests.root_module.addImport("_orhon_str", str_mod)` and `_orhon_collections` wiring that the existing exe test path has. Also keep all bridge imports, extra bridge imports, shared module imports, and the `run_tests`/`test_step` setup.

- [ ] **Step 2: Run build and tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All unit tests pass (existing multi tests still work).

Run: `./testall.sh 2>&1 | tail -5`
Expected: All 297 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/zig_runner/zig_runner_multi.zig
git commit -m "fix: generate test step for library-only multi-target builds"
```

---

### Task 2: Migrate single-target unit tests to use `buildZigContentMulti`

Before deleting `buildZigContent`, add equivalent tests that call `buildZigContentMulti` with single-element `MultiTarget` arrays. This proves the multi path handles single targets correctly.

**Files:**
- Modify: `src/zig_runner/zig_runner_multi.zig` (add tests at end of file)

- [ ] **Step 1: Add single-target exe test**

Add at the end of `zig_runner_multi.zig`:

```zig
test "buildZigContentMulti - single exe basic" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "myapp", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addRunArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"myapp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"myapp.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}
```

- [ ] **Step 2: Add single-target static lib test**

```zig
test "buildZigContentMulti - single static lib" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "mylib", .project_name = "mylib", .build_type = "static", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .static") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}
```

- [ ] **Step 3: Add single-target dynamic lib test**

```zig
test "buildZigContentMulti - single dynamic lib" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "mylib", .project_name = "mylib", .build_type = "dynamic", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "addLibrary") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, ".linkage = .dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "installArtifact") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "addExecutable") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "b.step(\"test\"") != null);
}
```

- [ ] **Step 4: Add project name and cimport tests**

```zig
test "buildZigContentMulti - project name in exe artifact" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "myapp", .project_name = "calculator", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"calculator\"") != null);
}

test "buildZigContentMulti - cimport link libs emit linkSystemLibrary and linkLibC" {
    const alloc = std.testing.allocator;
    const libs = [_][]const u8{"SDL3"};
    const targets = [_]MultiTarget{
        .{ .module_name = "myapp", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{}, .link_libs = @constCast(&libs) },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary(\"SDL3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC()") != null);
}

test "buildZigContentMulti - no cimport link libs means no linkLibC" {
    const alloc = std.testing.allocator;
    const targets = [_]MultiTarget{
        .{ .module_name = "myapp", .project_name = "myapp", .build_type = "exe", .lib_imports = &.{} },
    };
    const content = try buildZigContentMulti(alloc, &targets, &.{});
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "linkSystemLibrary") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "linkLibC") == null);
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test 2>&1 | tail -5`
Expected: All unit tests pass (new tests verify multi handles single targets).

- [ ] **Step 6: Commit**

```bash
git add src/zig_runner/zig_runner_multi.zig
git commit -m "test: add single-target tests for buildZigContentMulti"
```

---

### Task 3: Delete `buildZigContent()` and its tests

**Files:**
- Modify: `src/zig_runner/zig_runner_build.zig` — delete `buildZigContent()` (lines 34-429) and its 7 tests (lines 560-624)

- [ ] **Step 1: Delete the function and tests**

Remove `buildZigContent()` (the `pub fn buildZigContent(...)` function from line 34 through the closing `return buf.toOwnedSlice(allocator);` + `}` at line 429).

Remove all 7 test blocks at the bottom of the file:
- `"buildZigContent - exe"` (lines 560-572)
- `"buildZigContent - static"` (lines 574-586)
- `"buildZigContent - dynamic"` (lines 588-598)
- `"buildZigContent - project name in exe artifact"` (lines 600-605)
- `"buildZigContent - cimport link libs emit linkSystemLibrary and linkLibC"` (lines 607-615)
- `"buildZigContent - no cimport link libs means no linkLibC"` (lines 617-624)

Also remove the comment on line 92 that references `buildZigContentMulti`:
```
    // Same logic as buildZigContentMulti so single-target projects get proper type identity.
```

The file should now contain only: `StemResult`, `sanitizeHeaderStem()`, `emitLinkLibs()`, `emitIncludePath()`, `generateSharedCImportFiles()`, `emitCSourceFiles()`. Update the file header comment to reflect:

```zig
// zig_runner_build.zig — Shared build.zig generation helpers
// Contains sanitization, emit helpers, and @cImport file generation.
```

- [ ] **Step 2: Verify build (expect errors from callers)**

Run: `zig build 2>&1 | head -20`
Expected: Compilation error in `zig_runner.zig` referencing the deleted function.

- [ ] **Step 3: Commit (partial — will fix callers in next task)**

Do NOT commit yet — the build is broken. Continue to Task 4.

---

### Task 4: Update `zig_runner.zig` hub

**Files:**
- Modify: `src/zig_runner/zig_runner.zig`

- [ ] **Step 1: Remove `buildZigContent` re-export (line 17)**

Delete:
```zig
pub const buildZigContent = _zig_runner_build.buildZigContent;
```

- [ ] **Step 2: Collapse `generateBuildZig` and `generateBuildZigWithTests` into one method**

Replace the two methods (lines 360-408) with a single method that constructs a `MultiTarget` and calls `buildZigContentMulti`:

```zig
    /// Generate the build.zig file for a single-target project.
    /// Constructs a MultiTarget and routes through the unified multi-target path.
    pub fn generateBuildZig(
        self: *ZigRunner,
        module_name: []const u8,
        build_type: []const u8,
        project_name: []const u8,
        project_version: ?[3]u64,
        link_libs: []const []const u8,
        bridge_modules: []const []const u8,
        shared_modules: []const []const u8,
        c_includes: []const []const u8,
        c_source_files: []const []const u8,
        needs_cpp: bool,
        source_dir: ?[]const u8,
    ) !void {
        const target = MultiTarget{
            .module_name = module_name,
            .project_name = project_name,
            .build_type = build_type,
            .lib_imports = &.{},
            .mod_imports = shared_modules,
            .version = project_version,
            .link_libs = link_libs,
            .c_includes = c_includes,
            .c_source_files = c_source_files,
            .needs_cpp = needs_cpp,
            .has_bridges = false,
            .source_dir = source_dir,
        };
        const targets = [1]MultiTarget{target};
        const content = try _zig_runner_multi.buildZigContentMulti(self.allocator, &targets, bridge_modules);
        defer self.allocator.free(content);
        try cache.writeGeneratedZig("build", content, self.allocator);

        // Generate shared @cImport wrapper files on disk
        if (c_includes.len > 0) {
            try _zig_runner_build.generateSharedCImportFiles(self.allocator, &targets);
        }
    }
```

Key mapping decisions:
- `bridge_modules` → `extra_bridge_modules` param (all bridges are "extra" since the target has `has_bridges = false`)
- `shared_modules` → `mod_imports` on the target
- `has_bridges = false` — bridges are registered via `extra_bridge_modules`, not per-target flag

- [ ] **Step 3: Build and test**

Run: `zig build 2>&1 | tail -5`
Expected: Clean build.

Run: `zig build test 2>&1 | tail -5`
Expected: All unit tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/zig_runner/zig_runner_build.zig src/zig_runner/zig_runner.zig
git commit -m "refactor: delete buildZigContent, route single-target through buildZigContentMulti"
```

---

### Task 5: Run full test suite and update docs

**Files:**
- Modify: `docs/TODO.md`

- [ ] **Step 1: Run full test suite**

Run: `./testall.sh`
Expected: All 297 tests pass. Pay special attention to:
- `test/05_compile.sh` — single-target exe/lib builds
- `test/06_library.sh` — static + dynamic library builds
- `test/07_multimodule.sh` — multi-module builds
- `test/08_codegen.sh` — generated Zig quality

- [ ] **Step 2: If tests fail, debug**

The most likely failure: single-target library builds missing something from the multi path. The `shared_modules` → `mod_imports` mapping or the `bridge_modules` → `extra_bridge_modules` mapping may need adjustment. Read the generated build.zig in `.orh-cache/generated/build.zig` and compare with what a working build.zig should look like.

- [ ] **Step 3: Mark simplification as done in TODO.md**

In `docs/TODO.md`, replace:
```
- Merge `buildZigContent()`/`buildZigContentMulti()` shared logic.
```
with:
```
- ~~Merge `buildZigContent()`/`buildZigContentMulti()` — done (v0.14.3, unified into `buildZigContentMulti`)~~
```

- [ ] **Step 4: Commit**

```bash
git add docs/TODO.md
git commit -m "docs: mark buildZigContent merge as done"
```
