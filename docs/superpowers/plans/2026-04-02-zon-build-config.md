# Per-module `.zon` Build Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `#cimport` with paired `.zon` files for C build configuration — all C dependency info lives in the Zig ecosystem.

**Architecture:** `zig_module.zig` parses paired `.zon` files using `std.zig.Ast`, extracts build config (link, include, source, define), and passes it through the pipeline to `zig_runner_multi.zig` which emits the corresponding `build.zig` calls. The `#cimport` grammar, parser metadata, and pipeline extraction are then removed.

**Tech Stack:** Zig 0.15.2+ (`std.zig.Ast` for `.zon` parsing)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/zig_module.zig` | Modify | Add `.zon` parsing, `ZonConfig` struct, auto-detect adjacent C files |
| `src/pipeline.zig` | Modify | Replace `collectCimport` with zon config passthrough, remove `#cimport` extraction |
| `src/zig_runner/zig_runner_multi.zig` | Modify | Consume zon config instead of `#cimport` metadata on MultiTarget |
| `src/zig_runner/zig_runner.zig` | Modify | Pass zon config through to multi builder |
| `src/peg/orhon.peg` | Modify | Remove `#cimport` grammar rules |
| `src/peg/builder_decls.zig` | Modify | Remove `#cimport` builder code |
| `src/parser.zig` | Modify | Remove `cimport_include`, `cimport_source` from Metadata |
| `src/pipeline_build.zig` | Modify | Remove `splitCimportLibNames` |
| `src/templates/example/example.orh` | Modify | Replace #cimport docs with .zon docs |

---

### Task 1: Add `.zon` parser to `zig_module.zig`

Parse a `.zon` file and extract `ZonConfig` with link, include, source, define fields.

**Files:**
- Modify: `src/zig_module.zig`

- [ ] **Step 1: Add `ZonConfig` struct**

```zig
/// Build configuration extracted from a paired .zon file.
pub const ZonConfig = struct {
    link: []const []const u8 = &.{},
    include: []const []const u8 = &.{},
    source: []const []const u8 = &.{},
    define: []const []const u8 = &.{},

    pub fn deinit(self: *const ZonConfig, allocator: Allocator) void {
        for (self.link) |s| allocator.free(s);
        if (self.link.len > 0) allocator.free(self.link);
        for (self.include) |s| allocator.free(s);
        if (self.include.len > 0) allocator.free(self.include);
        for (self.source) |s| allocator.free(s);
        if (self.source.len > 0) allocator.free(self.source);
        for (self.define) |s| allocator.free(s);
        if (self.define.len > 0) allocator.free(self.define);
    }
};
```

- [ ] **Step 2: Implement `parseZonConfig`**

```zig
/// Parse a .zon file and extract build configuration.
/// Returns a default (empty) ZonConfig if parsing fails or no known fields found.
pub fn parseZonConfig(allocator: Allocator, zon_source: [:0]const u8) !ZonConfig {
    var tree = std.zig.Ast.parse(allocator, zon_source, .zon) catch return .{};
    defer tree.deinit(allocator);

    // .zon root is a struct init: .{ .field = .{ "a", "b" }, ... }
    // Walk the root node, find known field names, extract string tuples
    // ...
}
```

The `.zon` AST has a root struct init node. Each field is a `.struct_init_dot_two` or similar. For each field:
- Check field name against known names: "link", "include", "source", "define"
- Extract the tuple of string literals from the value
- Unknown fields: silently ignore

Read `/usr/lib/zig/std/zig/Ast.zig` to understand how `.zon` struct literals are represented. The root node will be a struct init with field names as identifiers and values as struct inits (tuples) containing string literals.

- [ ] **Step 3: Implement `extractStringTuple` helper**

```zig
/// Extract string literals from a .zon tuple value: .{ "a", "b", "c" }
fn extractStringTuple(tree: *const Ast, node: Node.Index, allocator: Allocator) ![]const []const u8 {
    // Walk the struct init children, collect string literal values
    // Unquote each string (strip surrounding ")
    // Return owned slice of owned strings
}
```

- [ ] **Step 4: Write unit tests**

```zig
test "parseZonConfig — full config" {
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "SDL2", "openssl" },
        \\    .include = .{ "vendor/" },
        \\    .source = .{ "vendor/stb.c" },
        \\    .define = .{ "USE_SDL" },
        \\}
    ;
    const config = try parseZonConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), config.link.len);
    try std.testing.expectEqualStrings("SDL2", config.link[0]);
    try std.testing.expectEqualStrings("openssl", config.link[1]);
    try std.testing.expectEqual(@as(usize, 1), config.include.len);
    try std.testing.expectEqual(@as(usize, 1), config.source.len);
    try std.testing.expectEqual(@as(usize, 1), config.define.len);
}

test "parseZonConfig — empty config" {
    const config = try parseZonConfig(std.testing.allocator, ".{}");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), config.link.len);
}

test "parseZonConfig — partial config" {
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "vulkan" },
        \\}
    ;
    const config = try parseZonConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config.link.len);
    try std.testing.expectEqualStrings("vulkan", config.link[0]);
    try std.testing.expectEqual(@as(usize, 0), config.source.len);
}

test "parseZonConfig — unknown fields ignored" {
    const source: [:0]const u8 =
        \\.{
        \\    .link = .{ "foo" },
        \\    .unknown = .{ "bar" },
        \\}
    ;
    const config = try parseZonConfig(std.testing.allocator, source);
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), config.link.len);
}
```

- [ ] **Step 5: Build and run tests**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/zig_module.zig
git commit -m "feat: add .zon config parser to zig_module"
```

---

### Task 2: Wire `.zon` config into discovery and pipeline

Read paired `.zon` files during module discovery, auto-detect adjacent C files, and pass the config through the pipeline to the build system.

**Files:**
- Modify: `src/zig_module.zig` — read `.zon` during discovery
- Modify: `src/module.zig` — add `zon_config` field to Module struct
- Modify: `src/pipeline.zig` — pass zon config to MultiTarget instead of collectCimport
- Modify: `src/zig_runner/zig_runner_multi.zig` — no changes needed if MultiTarget fields stay the same
- Modify: `src/zig_runner/zig_runner.zig` — no changes needed if params stay the same

- [ ] **Step 1: Update `ZigModuleEntry` to include zon config**

In `src/zig_module.zig`, add config to the entry struct:

```zig
pub const ZigModuleEntry = struct {
    file_path: []const u8,
    module_name: []const u8,
    config: ZonConfig = .{},
};
```

- [ ] **Step 2: Read `.zon` in `discoverAndConvert`**

After discovering a `.zig` file, check for a paired `.zon`:

```zig
// Check for paired .zon file
const zon_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zon", .{ dir_path, entry.module_name });
defer allocator.free(zon_path);
if (std.fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024)) |zon_source| {
    defer allocator.free(zon_source);
    const zon_z = try allocator.dupeZ(u8, zon_source);
    defer allocator.free(zon_z);
    entry.config = try parseZonConfig(allocator, zon_z);
} else |_| {}
```

Also return the entries (not just names) so the pipeline has access to configs.

- [ ] **Step 3: Auto-detect adjacent C files**

After reading the `.zon` (or if no `.zon` exists), scan the directory of the `.zig` file for `.c`/`.cpp`/`.cc`/`.cxx` files. Merge them into `config.source` (avoiding duplicates with any explicit `.source` entries).

```zig
// Auto-detect adjacent C/C++ source files
var auto_sources = std.ArrayList([]const u8).init(allocator);
// ... scan directory for .c/.cpp/.cc/.cxx files
// ... merge with config.source, dedup
```

- [ ] **Step 4: Add `zon_config` to Module struct**

In `src/module.zig`:

```zig
zon_config: ?*const zig_module.ZonConfig = null,
```

The pipeline stores a pointer to the zon config on the module after discovery.

- [ ] **Step 5: Update pipeline to pass zon config to MultiTarget**

In `src/pipeline.zig`, where MultiTarget is assembled (multi-target path), instead of calling `collectCimport()` on AST metadata, read the zon config from the module:

```zig
// Replace collectCimport with zon config
const zon = if (mod.zon_config) |c| c else &zig_module.ZonConfig{};
// ... populate link_libs, c_includes, c_sources from zon fields
```

Similarly for the single-target path.

- [ ] **Step 6: Build and run full test suite**

Run: `zig build 2>&1 | head -20`
Run: `./testall.sh 2>&1 | tail -10`
Expected: Compiles and all tests pass. At this point both `.zon` and `#cimport` paths coexist — zon takes precedence for zig modules.

- [ ] **Step 7: Commit**

```bash
git add src/zig_module.zig src/module.zig src/pipeline.zig
git commit -m "feat: wire .zon config into pipeline for zig modules"
```

---

### Task 3: Integration test — `.zig` + `.zon` + C source

Create a test fixture that uses a `.zon` file to compile C code.

**Files:**
- Create: `test/fixtures/zon_clib/src/zon_clib.orh`
- Create: `test/fixtures/zon_clib/src/mathlib.zig`
- Create: `test/fixtures/zon_clib/src/mathlib.zon`
- Create: `test/fixtures/zon_clib/src/native_add.c`
- Create: `test/fixtures/zon_clib/src/native_add.h`
- Modify: `test/09_language.sh` — add zon build config test

- [ ] **Step 1: Create C source files**

`test/fixtures/zon_clib/src/native_add.h`:
```c
#ifndef NATIVE_ADD_H
#define NATIVE_ADD_H
int native_add(int a, int b);
#endif
```

`test/fixtures/zon_clib/src/native_add.c`:
```c
#include "native_add.h"
int native_add(int a, int b) { return a + b; }
```

- [ ] **Step 2: Create Zig wrapper**

`test/fixtures/zon_clib/src/mathlib.zig`:
```zig
const c = @cImport(@cInclude("native_add.h"));

pub fn add(a: i32, b: i32) i32 {
    return c.native_add(a, b);
}
```

- [ ] **Step 3: Create `.zon` config**

`test/fixtures/zon_clib/src/mathlib.zon`:
```zig
.{
    .source = .{"src/native_add.c"},
    .include = .{"src/"},
}
```

- [ ] **Step 4: Create Orhon app**

`test/fixtures/zon_clib/src/zon_clib.orh`:
```
module zon_clib
#build = exe

import mathlib
import std::console

func main() {
    var result: i32 = mathlib.add(10, 32)
    console.println("zon works")
}
```

- [ ] **Step 5: Add test to test suite**

Add test to `test/09_language.sh` that:
- Copies fixture to temp dir
- Runs `orhon build`
- Verifies build succeeds
- Runs the binary and checks output contains "zon works"

- [ ] **Step 6: Run test suite**

Run: `./testall.sh 2>&1 | tail -10`
Expected: New test passes, all existing tests pass.

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/zon_clib/ test/09_language.sh
git commit -m "test: add zon build config integration test with C source"
```

---

### Task 4: Remove `#cimport` from grammar and parser

Remove the `#cimport` directive from the language.

**Files:**
- Modify: `src/peg/orhon.peg` — remove `cimport_block`, `cimport_entry` rules, remove `'cimport' '=' cimport_block` from `metadata_body`
- Modify: `src/peg/builder_decls.zig` — remove cimport builder code (~80 lines)
- Modify: `src/parser.zig` — remove `cimport_include` and `cimport_source` from Metadata struct

- [ ] **Step 1: Remove grammar rules**

In `src/peg/orhon.peg`, remove:
- The `'cimport' '=' cimport_block` alternative from `metadata_body`
- The `cimport_block` rule
- The `cimport_entry` rule

- [ ] **Step 2: Remove builder code**

In `src/peg/builder_decls.zig`, remove the cimport handling in `buildMetadata` (the block that checks `field == "cimport"` and navigates cimport_block captures).

- [ ] **Step 3: Remove parser fields**

In `src/parser.zig`, remove from Metadata struct:
```zig
cimport_include: ?[]const u8 = null,
cimport_source: ?[]const u8 = null,
```

- [ ] **Step 4: Fix cascading compilation errors**

The Metadata field removal will cause errors wherever `cimport_include` or `cimport_source` is accessed. Fix all references:
- `src/pipeline.zig` — the `collectCimport` helper reads these fields. Remove `collectCimport` entirely and its call sites.
- `src/pipeline_build.zig` — remove `splitCimportLibNames` if no longer used.
- `src/module_parse.zig` — check for any cimport references.
- `src/lsp/` — check for cimport completions or diagnostics.

- [ ] **Step 5: Remove collectCimport from pipeline**

Delete the `collectCimport` struct and all call sites in both multi-target and single-target build paths. The zon config from Task 2 now handles all C dependency information.

Also remove the `cimport_registry` duplicate detection map and all `link_lib_lists`, `c_include_lists`, `c_source_lists` accumulator lists that were populated by `collectCimport`.

- [ ] **Step 6: Remove `splitCimportLibNames` from pipeline_build.zig**

Delete the function and any tests for it.

- [ ] **Step 7: Update example module**

In `src/templates/example/example.orh`, replace the `#cimport` documentation with `.zon` documentation.

- [ ] **Step 8: Update error tests**

Check `test/11_errors.sh` for any `#cimport` negative tests. Remove or replace them.

- [ ] **Step 9: Build and run full test suite**

Run: `zig build 2>&1 | head -30`
Run: `./testall.sh 2>&1 | tail -10`
Expected: Compiles cleanly, all tests pass.

- [ ] **Step 10: Commit**

```bash
git add -A src/ test/
git commit -m "refactor: remove #cimport — replaced by per-module .zon config"
```

---

### Task 5: Update documentation

Update all docs referencing `#cimport`.

**Files:**
- Modify: `docs/14-zig-bridge.md` — add `.zon` config section
- Modify: `docs/TODO.md` — mark `.zon` build config as done
- Modify: `CLAUDE.md` — remove `#cimport` references
- Modify: `docs/11-modules.md` — remove `#cimport` if referenced
- Modify: `docs/COMPILER.md` — update build system description

- [ ] **Step 1: Add `.zon` section to zig module docs**

In `docs/14-zig-bridge.md`, expand the C Interop section with `.zon` config format and examples.

- [ ] **Step 2: Update TODO**

Mark the `.zon` build config task as done.

- [ ] **Step 3: Update CLAUDE.md**

Remove `#cimport` from any keyword lists, syntax examples, or feature descriptions.

- [ ] **Step 4: Grep for remaining `#cimport` or `cimport` references in docs**

Fix any remaining references.

- [ ] **Step 5: Run full test suite**

Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add docs/ CLAUDE.md
git commit -m "docs: update documentation for .zon build config"
```

---

## Execution Order

Tasks 1-2 build the new system (can coexist with `#cimport`).
Task 3 proves it works end-to-end.
Task 4 removes the old system.
Task 5 updates documentation.

**Critical path:** 1 → 2 → 3 → 4 → 5

All tasks are sequential. `#cimport` stays functional until Task 4, so existing tests pass throughout.
