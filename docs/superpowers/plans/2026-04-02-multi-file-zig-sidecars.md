# Multi-file Zig Sidecars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow bridge sidecar `.zig` files to `@import` additional `.zig` files from the project source directory.

**Architecture:** Add a `scanSidecarImports()` function to `cache.zig` that recursively scans `.zig` content for `@import("...zig")` patterns and returns a list of referenced files. Both copy sites (module.zig and pipeline.zig) call this function after reading sidecar content, validate paths are within the source directory, check for collisions, and copy the extra files to `generated/`.

**Tech Stack:** Zig 0.15.2+, no new dependencies.

---

### Task 1: Add `scanSidecarImports()` to `cache.zig`

**Files:**
- Modify: `src/cache.zig`

- [ ] **Step 1: Write the failing test**

Add a test block at the end of `src/cache.zig`:

```zig
test "scanSidecarImports — finds direct @import" {
    const content = 
        \\const pipeline = @import("pipeline.zig");
        \\const std = @import("std");
        \\const helpers = @import("utils/helpers.zig");
    ;
    var results = std.ArrayListUnmanaged([]const u8){};
    defer results.deinit(std.testing.allocator);
    try scanZigImports(content, &results, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    // Should skip @import("std") — only .zig file imports
    try std.testing.expect(std.mem.eql(u8, results.items[0], "pipeline.zig"));
    try std.testing.expect(std.mem.eql(u8, results.items[1], "utils/helpers.zig"));
    for (results.items) |item| std.testing.allocator.free(item);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `scanZigImports` not defined.

- [ ] **Step 3: Implement `scanZigImports()`**

Add this function to `src/cache.zig`, above the test block:

```zig
/// Scan Zig source content for @import("...zig") patterns.
/// Returns a list of relative .zig file paths (caller owns the strings).
/// Skips non-file imports like @import("std") or @import("module_name").
pub fn scanZigImports(
    content: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const needle = "@import(\"";
    var pos: usize = 0;
    while (pos < content.len) {
        const idx = std.mem.indexOfPos(u8, content, pos, needle) orelse break;
        const path_start = idx + needle.len;
        const path_end = std.mem.indexOfPos(u8, content, path_start, "\"") orelse break;
        const path = content[path_start..path_end];
        pos = path_end + 1;
        // Only collect .zig file imports
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        try out.append(allocator, try allocator.dupe(u8, path));
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/cache.zig
git commit -m "feat: add scanZigImports() for multi-file sidecar discovery"
```

---

### Task 2: Add `copySidecarImports()` to `cache.zig`

**Files:**
- Modify: `src/cache.zig`

This function does the recursive discovery, validation, and copying. It takes the sidecar source path, the project source directory, a reporter for errors, and an allocator. It returns the list of extra files copied (for collision tracking by the caller).

- [ ] **Step 1: Write the failing test**

```zig
test "copySidecarImports — rejects path escaping source dir" {
    // Create a temp directory structure
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Write a sidecar that imports outside its directory
    try tmp.dir.writeFile(.{ .sub_path = "src/mod.zig", .data = 
        \\const x = @import("../../escape.zig");
    });
    const src_path = try tmp.dir.realpathAlloc(std.testing.allocator, "src");
    defer std.testing.allocator.free(src_path);
    const sidecar_path = try tmp.dir.realpathAlloc(std.testing.allocator, "src/mod.zig");
    defer std.testing.allocator.free(sidecar_path);

    var reporter = @import("errors.zig").Reporter.init(std.testing.allocator, .debug);
    defer reporter.deinit();

    var copied = std.StringHashMapUnmanaged([]const u8){};
    defer copied.deinit(std.testing.allocator);

    try copySidecarImports(std.testing.allocator, sidecar_path, src_path, "mod", &reporter, &copied);
    try std.testing.expect(reporter.hasErrors());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `copySidecarImports` not defined.

- [ ] **Step 3: Implement `copySidecarImports()`**

```zig
/// Recursively discover, validate, and copy @import'd .zig files from a sidecar.
/// - `sidecar_src`: absolute path to the sidecar .zig file
/// - `source_dir`: project source directory (boundary check)
/// - `mod_name`: module name (for error messages)
/// - `reporter`: error reporter
/// - `copied`: shared map of destination path → source path (for collision detection across modules)
///
/// Copies discovered files to GENERATED_DIR, preserving relative paths from the sidecar.
pub fn copySidecarImports(
    allocator: std.mem.Allocator,
    sidecar_src: []const u8,
    source_dir: []const u8,
    mod_name: []const u8,
    reporter: *@import("errors.zig").Reporter,
    copied: *std.StringHashMapUnmanaged([]const u8),
) !void {
    var visited = std.StringHashMapUnmanaged(void){};
    defer {
        var it = visited.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        visited.deinit(allocator);
    }
    try copySidecarImportsInner(allocator, sidecar_src, source_dir, mod_name, reporter, copied, &visited);
}

fn copySidecarImportsInner(
    allocator: std.mem.Allocator,
    zig_file: []const u8,
    source_dir: []const u8,
    mod_name: []const u8,
    reporter: *@import("errors.zig").Reporter,
    copied: *std.StringHashMapUnmanaged([]const u8),
    visited: *std.StringHashMapUnmanaged(void),
) !void {
    // Read the file content
    const content = std.fs.cwd().readFileAlloc(allocator, zig_file, 1024 * 1024) catch return;
    defer allocator.free(content);

    // Find all .zig imports
    var imports = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (imports.items) |item| allocator.free(item);
        imports.deinit(allocator);
    }
    try scanZigImports(content, &imports, allocator);

    const zig_dir = std.fs.path.dirname(zig_file) orelse ".";

    for (imports.items) |rel_path| {
        // Resolve to absolute path
        const abs_path = try std.fs.path.resolve(allocator, &.{ zig_dir, rel_path });
        defer allocator.free(abs_path);

        // Cycle detection
        if (visited.contains(abs_path)) continue;

        // Source boundary check — must start with source_dir
        const real_source = std.fs.cwd().realpathAlloc(allocator, source_dir) catch continue;
        defer allocator.free(real_source);
        const real_import = std.fs.cwd().realpathAlloc(allocator, abs_path) catch {
            // File doesn't exist
            try reporter.reportFmt(null, "bridge '{s}': sidecar import '{s}' not found", .{ mod_name, rel_path });
            continue;
        };
        defer allocator.free(real_import);

        if (!std.mem.startsWith(u8, real_import, real_source)) {
            try reporter.reportFmt(null, "bridge '{s}': sidecar import '{s}' escapes project source directory", .{ mod_name, rel_path });
            continue;
        }

        // Destination path in generated dir
        const dst_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ GENERATED_DIR, rel_path });
        defer allocator.free(dst_path);

        // Collision detection
        if (copied.get(rel_path)) |existing_mod| {
            if (!std.mem.eql(u8, existing_mod, mod_name)) {
                try reporter.reportFmt(null, "bridge '{s}': sidecar import '{s}' collides with import from module '{s}'", .{ mod_name, rel_path, existing_mod });
                continue;
            }
        }

        // Ensure subdirectories exist
        if (std.fs.path.dirname(dst_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }

        // Copy the file
        try std.fs.cwd().copyFile(abs_path, std.fs.cwd(), dst_path, .{});

        // Track as visited and copied
        const owned_abs = try allocator.dupe(u8, abs_path);
        try visited.put(allocator, owned_abs, {});
        const owned_rel = try allocator.dupe(u8, rel_path);
        const owned_mod = try allocator.dupe(u8, mod_name);
        try copied.put(allocator, owned_rel, owned_mod);

        // Recurse into this file
        try copySidecarImportsInner(allocator, abs_path, source_dir, mod_name, reporter, copied, visited);
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/cache.zig
git commit -m "feat: add copySidecarImports() for recursive sidecar discovery and copying"
```

---

### Task 3: Wire into pipeline.zig (root module sidecar copy)

**Files:**
- Modify: `src/pipeline.zig`

- [ ] **Step 1: Add a shared collision map at the top of the pipeline loop**

In `src/pipeline.zig`, the per-module loop starts around line 270. Before the loop, add:

```zig
// Track sidecar import destinations for collision detection
var sidecar_copied = std.StringHashMapUnmanaged([]const u8){};
defer {
    var it = sidecar_copied.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    sidecar_copied.deinit(allocator);
}
```

- [ ] **Step 2: Call `copySidecarImports` after the existing sidecar copy block**

In `src/pipeline.zig`, after the sidecar is written to `generated/` (after line 396, the `try dst_file.writeAll(result.items);` block), add:

```zig
// Copy any additional .zig files imported by the sidecar
const sidecar_dir = std.fs.path.dirname(sidecar_src) orelse ".";
_ = sidecar_dir;
try cache.copySidecarImports(allocator, sidecar_src, cli.source_dir, mod_name, reporter, &sidecar_copied);
```

- [ ] **Step 3: Run `./testall.sh` to verify no regressions**

Run: `./testall.sh`
Expected: All existing tests pass (no sidecars currently use multi-file imports).

- [ ] **Step 4: Commit**

```bash
git add src/pipeline.zig
git commit -m "feat: wire copySidecarImports into pipeline root module sidecar copy"
```

---

### Task 4: Wire into module.zig (import-time sidecar copy)

**Files:**
- Modify: `src/module.zig`

- [ ] **Step 1: Add collision map to the Resolver struct**

In `src/module.zig`, the `Resolver` struct (around line 80-100) needs a field to track collisions across modules. Add:

```zig
sidecar_copied: std.StringHashMapUnmanaged([]const u8),
```

Initialize it in `init()`:
```zig
.sidecar_copied = .{},
```

Clean it up in `deinit()`:
```zig
{
    var it = self.sidecar_copied.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.sidecar_copied.deinit(self.allocator);
}
```

- [ ] **Step 2: Call `copySidecarImports` after the existing sidecar copy at line 579**

After the `try std.fs.cwd().copyFile(...)` at line 579, add:

```zig
// Copy any additional .zig files imported by the sidecar
try cache.copySidecarImports(self.allocator, sidecar_src, source_dir, decl.path, self.reporter, &self.sidecar_copied);
```

Note: `source_dir` here needs to be the project source directory. The import-time copy path already has `scope_dir` available. For stdlib sidecars (from `.orh-cache/std/`), multi-file imports don't apply — those are embedded. For user module sidecars, the source directory is derived from the sidecar path. Check whether this code path handles user-project imports or only stdlib. If only stdlib, this call can be skipped with a comment explaining why.

- [ ] **Step 3: Run `./testall.sh` to verify no regressions**

Run: `./testall.sh`
Expected: All existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/module.zig
git commit -m "feat: wire copySidecarImports into module.zig import-time sidecar copy"
```

---

### Task 5: Add integration test

**Files:**
- Create: `test/fixtures/multizig/multizig.orh`
- Create: `test/fixtures/multizig/multizig.zig`
- Create: `test/fixtures/multizig/helper.zig`
- Modify: `test/08_codegen.sh` or `test/09_language.sh`

- [ ] **Step 1: Create test fixture — Orhon bridge module**

`test/fixtures/multizig/multizig.orh`:
```orhon
module multizig
#build = lib

bridge func helper_add(a: i32, b: i32) -> i32
```

- [ ] **Step 2: Create test fixture — main sidecar that imports helper**

`test/fixtures/multizig/multizig.zig`:
```zig
const helper = @import("helper.zig");

export fn helper_add(a: i32, b: i32) i32 {
    return helper.add(a, b);
}
```

- [ ] **Step 3: Create test fixture — helper zig file**

`test/fixtures/multizig/helper.zig`:
```zig
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}
```

- [ ] **Step 4: Add test case to the appropriate test script**

Add a test to `test/08_codegen.sh` (or whichever test script handles codegen quality checks for bridge modules) that builds the multizig fixture and verifies `helper.zig` was copied to `generated/`:

```bash
# Multi-file sidecar: helper.zig should be copied alongside the sidecar
echo -n "  multi-file sidecar copy... "
cd "$FIXTURE_DIR/multizig"
$ORHON build 2>"$ERR_FILE" && [ -f .orh-cache/generated/helper.zig ] && echo "ok" || fail "helper.zig not copied"
cd "$BASE_DIR"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/08_codegen.sh` (or the relevant test script)
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/multizig/ test/08_codegen.sh
git commit -m "test: add integration test for multi-file zig sidecars"
```

---

### Task 6: Add negative test for path escape

**Files:**
- Create: `test/fixtures/multizig_escape/multizig_escape.orh`
- Create: `test/fixtures/multizig_escape/multizig_escape.zig`
- Modify: `test/11_errors.sh`

- [ ] **Step 1: Create fixture that imports outside source dir**

`test/fixtures/multizig_escape/multizig_escape.orh`:
```orhon
module multizig_escape
#build = lib

bridge func bad_func() -> i32
```

`test/fixtures/multizig_escape/multizig_escape.zig`:
```zig
const x = @import("../../escape.zig");

export fn bad_func() i32 {
    return 0;
}
```

- [ ] **Step 2: Add error test**

In `test/11_errors.sh`, add a test that expects compilation to fail with the "escapes project source directory" error:

```bash
# Multi-file sidecar: reject imports escaping source directory
expect_error "multizig_escape" "escapes project source directory"
```

- [ ] **Step 3: Run the test**

Run: `bash test/11_errors.sh`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add test/fixtures/multizig_escape/ test/11_errors.sh
git commit -m "test: add negative test for sidecar import escaping source dir"
```

---

### Task 7: Run full test suite and clean up

- [ ] **Step 1: Run full test suite**

Run: `./testall.sh`
Expected: All tests pass, including the two new tests.

- [ ] **Step 2: Commit any final cleanup**

If any adjustments were needed, commit them.
