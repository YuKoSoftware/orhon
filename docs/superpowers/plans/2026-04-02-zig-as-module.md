# Zig-as-Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bridge system with automatic Zig module conversion — any `.zig` file in `src/` becomes a regular Orhon module.

**Architecture:** A new `src/zig_module.zig` uses `std.zig.Ast` to parse `.zig` files, extract `pub` declarations, map Zig types to Orhon types, and write generated `.orh` files to `.orh-cache/zig_modules/`. The pipeline discovers these as regular modules. Codegen emits re-exports for zig-backed modules. The `bridge` keyword and all bridge-specific code is removed.

**Tech Stack:** Zig 0.15.2+ (`std.zig.Ast` for parsing)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/zig_module.zig` | **Create** | Zig file discovery, `std.zig.Ast` parsing, type mapping, `.orh` generation |
| `src/pipeline.zig` | Modify | Add early step calling `zig_module.discoverAndConvert()` before module resolution |
| `src/module.zig` | Modify | Add `is_zig_module` flag to Module struct, replace `has_bridges`/`sidecar_path` |
| `src/module_parse.zig` | Modify | Remove bridge detection (lines 338-374), remove sidecar validation |
| `src/parser.zig` | Modify | Remove `is_bridge` from StructDecl/VarDecl, remove `.bridge` from FuncContext |
| `src/peg/orhon.peg` | Modify | Remove `bridge_decl`, `bridge_func`, `bridge_const`, `bridge_struct` rules |
| `src/peg/builder_bridge.zig` | **Delete** | Entire file — bridge AST building |
| `src/peg/builder.zig` | Modify | Remove bridge builder imports/dispatch |
| `src/peg/builder_decls.zig` | Modify | Remove bridge references |
| `src/peg/token_map.zig` | Modify | Remove `bridge` token |
| `src/declarations.zig` | Modify | Remove `is_bridge` checks, remove #cimport-requires-bridge validation |
| `src/codegen/codegen_decls.zig` | Modify | Replace per-decl `is_bridge` checks with per-module `is_zig_module` check |
| `src/pipeline_passes.zig` | Modify | Remove `copySidecar()`, remove sidecar-related params |
| `src/cache.zig` | Modify | Remove `copySidecarImports()` and `copySidecarImportsInner()` |
| `src/zig_runner/zig_runner_multi.zig` | Modify | Rename `bridge_` → `zig_` in named module generation |
| `src/std_bundle.zig` | Modify | Remove all `*_ORH` constants for pure-bridge stdlib modules |
| `src/std/*.orh` | **Delete 26** | All pure-bridge `.orh` files (keep `linear.orh`) |
| `src/std/console.zig` | Modify | Move `printColored`/`printColoredLn` from `.orh` to native Zig |
| `src/resolver.zig` | Modify | Remove `is_bridge` references |
| `src/mir/mir_annotator.zig` | Modify | Remove `.bridge` context handling |
| `src/mir/mir_annotator_nodes.zig` | Modify | Remove `.bridge` references |
| `src/mir/mir_node.zig` | Modify | Remove bridge-related MIR kinds if any |
| `src/mir/mir_lowerer.zig` | Modify | Remove `.bridge`/`is_bridge` handling |
| `src/pipeline_build.zig` | Modify | Remove bridge-related test helpers |

---

### Task 1: Create `zig_module.zig` — type mapper

The foundation. Build the Zig-to-Orhon type mapping function that converts Zig type AST nodes to Orhon type strings. This is the core of the converter.

**Files:**
- Create: `src/zig_module.zig`

- [ ] **Step 1: Create `zig_module.zig` with type mapping**

```zig
// zig_module.zig — Zig-to-Orhon automatic module converter
// Discovers .zig files in src/, parses with std.zig.Ast,
// extracts pub declarations, maps types, generates .orh modules.

const std = @import("std");
const Ast = std.zig.Ast;

/// Map a Zig type token/expression to an Orhon type string.
/// Returns null if the type is not representable in Orhon.
pub fn mapType(tree: Ast, node: Ast.Node.Index, buf: *std.ArrayList(u8)) !?void {
    const tags = tree.nodes.items(.tag);
    const tag = tags[node];
    const data = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);

    switch (tag) {
        // Identifier: u8, i32, f64, bool, void, usize, String, etc.
        .identifier => {
            const token = main_tokens[node];
            const name = tree.tokenSlice(token);
            // Map []const u8 is handled by .ptr_type_sentinel / .ptr_type below
            // Primitives and user types pass through as-is
            try buf.appendSlice(name);
        },
        // *T or *const T
        .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range => {
            // Check if it's a slice type: []const u8 → String
            // or pointer: *T → mut& T, *const T → const& T
            const ptr_data = data[node];
            const child = ptr_data.rhs;
            if (child == 0) return null; // can't resolve

            // Check for []const u8 → String
            const source = tree.getNodeSource(node);
            if (std.mem.startsWith(u8, source, "[]const u8")) {
                try buf.appendSlice("String");
                return;
            }
            if (std.mem.startsWith(u8, source, "[]const ")) {
                // Other const slices — not mappable yet
                return null;
            }
            if (std.mem.startsWith(u8, source, "[]")) {
                // Mutable slices — not mappable yet
                return null;
            }

            // Pointer types: *const T → const& T, *T → mut& T
            if (std.mem.startsWith(u8, source, "*const ")) {
                try buf.appendSlice("const& ");
                return try mapType(tree, child, buf) orelse return null;
            }
            if (std.mem.startsWith(u8, source, "*")) {
                try buf.appendSlice("mut& ");
                return try mapType(tree, child, buf) orelse return null;
            }
            return null;
        },
        // ?T → NullUnion(T)
        .optional_type => {
            const child = data[node].lhs;
            try buf.appendSlice("NullUnion(");
            try mapType(tree, child, buf) orelse return null;
            try buf.appendSlice(")");
        },
        // anyerror!T → ErrorUnion(T)
        .error_union => {
            const child = data[node].rhs;
            try buf.appendSlice("ErrorUnion(");
            try mapType(tree, child, buf) orelse return null;
            try buf.appendSlice(")");
        },
        // Builtin call like @TypeOf, @Vector — skip
        .builtin_call, .builtin_call_two => return null,
        // Anything else — not mappable
        else => return null,
    }
}
```

Note: The actual `std.zig.Ast` API uses node tags and token indices. The exact field names and tag names need to match Zig 0.15's `std.zig.Ast` — look up the real API in the Zig stdlib source at `lib/std/zig/Ast.zig`. The structure above shows the intent; implementation must use the real AST node tags (e.g., `@"if"`, `.fn_proto`, `.container_decl`, etc.) and data layout.

- [ ] **Step 2: Write unit tests for type mapping**

```zig
test "mapType — primitives" {
    // Parse a minimal Zig file and test type extraction
    // Test: i32, u8, f64, bool, void, usize all pass through
}

test "mapType — []const u8 → String" {
    // Parse: pub fn foo() []const u8
    // Verify return type maps to "String"
}

test "mapType — optional → NullUnion" {
    // Parse: pub fn foo() ?i32
    // Verify maps to "NullUnion(i32)"
}

test "mapType — error union → ErrorUnion" {
    // Parse: pub fn foo() anyerror!void
    // Verify maps to "ErrorUnion(void)"
}

test "mapType — pointer types" {
    // *i32 → mut& i32
    // *const u8 → const& u8
}

test "mapType — unmappable returns null" {
    // std.mem.Allocator, anytype, comptime → null
}
```

- [ ] **Step 3: Build and run tests**

Run: `zig build test 2>&1 | head -20`
Expected: All type mapper tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/zig_module.zig
git commit -m "feat: add zig_module.zig with Zig-to-Orhon type mapper"
```

---

### Task 2: Add declaration extraction to `zig_module.zig`

Walk `std.zig.Ast` top-level nodes to extract `pub fn`, `pub const`, and `pub const Struct = struct { ... }` declarations. Build Orhon module text.

**Files:**
- Modify: `src/zig_module.zig`

- [ ] **Step 1: Add `pub fn` extraction**

Write a function `extractDeclarations(tree: Ast, allocator: Allocator) ![]const u8` that:
- Iterates root-level declaration nodes
- For each `pub fn`: extract name, parameter names+types (via `mapType`), return type
- Skip if any param type or return type is unmappable (mapType returns null)
- Skip `pub fn` with `anytype` or `comptime` params (except `comptime T: type` which maps to `compt T: type`)
- Build Orhon text: `pub func name(param: Type) RetType`
- Handle `self: *Self` → `self: mut& StructName` for methods (needed in Task 3)

- [ ] **Step 2: Add `pub const` extraction**

For each `pub const NAME = value`:
- If value is a string literal → `pub const NAME: String`
- If value is an integer literal → `pub const NAME: i64` (or detect type from context)
- If value is a struct definition → handled in step 3
- Skip complex expressions

- [ ] **Step 3: Add `pub const Struct = struct { ... }` extraction**

For each `pub const StructName = struct { ... }`:
- Extract struct name
- Walk struct members for `pub fn` methods
- Map `self: *StructName` → `self: mut& StructName`
- Map `self: StructName` → `self: StructName` (value self)
- Map `self: *const StructName` → `self: const& StructName`
- Generate Orhon struct with methods:
  ```
  pub struct StructName {
      pub func method(self: mut& StructName, arg: Type) RetType
  }
  ```

- [ ] **Step 4: Add module text generation**

Write `generateModule(mod_name: []const u8, tree: Ast, allocator: Allocator) ![]const u8` that:
- Emits `module {mod_name}` header
- Calls extraction for functions, constants, structs
- Returns complete `.orh` file content as string

- [ ] **Step 5: Write tests for declaration extraction**

```zig
test "extract pub fn" {
    const source = "pub fn add(a: i32, b: i32) i32 { return a + b; }";
    // Parse, extract, verify Orhon output contains "pub func add(a: i32, b: i32) i32"
}

test "extract pub const" {
    const source = "pub const RED = \"\\x1b[31m\";";
    // Verify: "pub const RED: String"
}

test "extract pub struct with methods" {
    const source =
        \\pub const SMP = struct {
        \\    pub fn create() SMP { return .{}; }
        \\    pub fn deinit(self: *SMP) void { _ = self; }
        \\};
    ;
    // Verify: struct SMP with create() and deinit(self: mut& SMP)
}

test "skip non-pub declarations" {
    const source = "fn helper() void {} pub fn visible() void {}";
    // Verify: only "visible" appears in output
}

test "skip incompatible signatures" {
    const source = "pub fn generic(x: anytype) void { _ = x; }";
    // Verify: function is skipped, no output for it
}

test "compt mapping" {
    const source = "pub fn make(comptime T: type, val: T) T { return val; }";
    // Verify: "pub func make(compt T: type, val: T) T"
}

test "skip underscore-prefixed files" {
    // Test that discoverZigFiles skips _helpers.zig
}
```

- [ ] **Step 6: Build and run tests**

Run: `zig build test 2>&1 | head -20`
Expected: All extraction tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/zig_module.zig
git commit -m "feat: add declaration extraction and module generation to zig_module"
```

---

### Task 3: Add file discovery and cache writing

Add the entry point that scans `src/` for `.zig` files, converts each one, and writes `.orh` to cache.

**Files:**
- Modify: `src/zig_module.zig`
- Modify: `src/cache.zig` (add `ZIG_MODULES_DIR` constant)

- [ ] **Step 1: Add `ZIG_MODULES_DIR` to cache.zig**

In `src/cache.zig`, add alongside existing constants:
```zig
pub const ZIG_MODULES_DIR = CACHE_DIR ++ "/zig_modules";
```

- [ ] **Step 2: Add file discovery function**

```zig
/// Discover .zig files in source directory (recursive).
/// Skips files starting with '_' (private convention).
/// Returns list of (file_path, module_name) pairs.
pub fn discoverZigFiles(allocator: std.mem.Allocator, source_dir: []const u8) ![]ZigModuleEntry {
    // Open source_dir, iterate recursively
    // For each .zig file:
    //   - Skip if filename starts with '_'
    //   - Module name = filename stem (e.g., "mylib.zig" → "mylib")
    //   - Add to result list
    // Return owned slice
}

pub const ZigModuleEntry = struct {
    file_path: []const u8,  // relative path: "src/mylib.zig"
    module_name: []const u8, // "mylib"
};
```

- [ ] **Step 3: Add `discoverAndConvert()` entry point**

```zig
/// Main entry point: discover .zig files, parse, convert, write .orh to cache.
/// Returns list of generated module names for the pipeline to pick up.
pub fn discoverAndConvert(allocator: std.mem.Allocator, source_dir: []const u8) ![]const []const u8 {
    const entries = try discoverZigFiles(allocator, source_dir);
    defer { /* free entries */ }

    // Ensure output directory exists
    std.fs.cwd().makePath(cache.ZIG_MODULES_DIR) catch {};

    var module_names = std.ArrayList([]const u8).init(allocator);

    for (entries) |entry| {
        // Read .zig file
        const source = try std.fs.cwd().readFileAlloc(allocator, entry.file_path, 10 * 1024 * 1024);
        defer allocator.free(source);

        // Parse with std.zig.Ast
        var tree = try std.zig.Ast.parse(allocator, source, .zig);
        defer tree.deinit(allocator);

        // Generate .orh content
        const orh_content = try generateModule(entry.module_name, tree, allocator);
        defer allocator.free(orh_content);

        // Write to cache
        const orh_path = try std.fmt.allocPrint(allocator, "{s}/{s}.orh", .{ cache.ZIG_MODULES_DIR, entry.module_name });
        defer allocator.free(orh_path);
        const file = try std.fs.cwd().createFile(orh_path, .{});
        defer file.close();
        try file.writeAll(orh_content);

        try module_names.append(try allocator.dupe(u8, entry.module_name));
    }

    return module_names.toOwnedSlice();
}
```

- [ ] **Step 4: Write tests**

```zig
test "discoverZigFiles skips underscore" {
    // Create temp dir with test.zig and _helper.zig
    // Verify only test.zig is returned
}

test "discoverAndConvert end-to-end" {
    // Create temp dir with a simple .zig file
    // Run discoverAndConvert
    // Read generated .orh from cache dir
    // Verify module declaration and function signatures
}
```

- [ ] **Step 5: Build and run tests**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/zig_module.zig src/cache.zig
git commit -m "feat: add zig file discovery and cache writing to zig_module"
```

---

### Task 4: Wire `zig_module` into pipeline + module system

Add the `is_zig_module` flag, call the converter early in the pipeline, and make the module resolver pick up generated `.orh` files.

**Files:**
- Modify: `src/module.zig` — add `is_zig_module` field, add `zig_source_path` field
- Modify: `src/pipeline.zig` — call `zig_module.discoverAndConvert()` early
- Modify: `src/module_parse.zig` — no sidecar validation for zig modules

- [ ] **Step 1: Add `is_zig_module` and `zig_source_path` to Module struct**

In `src/module.zig`, modify the Module struct (line ~81):

```zig
pub const Module = struct {
    name: []const u8,
    files: [][]const u8,
    imports: [][]const u8,
    imports_owned: bool,
    is_root: bool,
    build_type: BuildType,
    ast: ?*parser.Node,
    ast_arena: ?std.heap.ArenaAllocator,
    locs: ?parser.LocMap,
    file_offsets: []FileOffset,
    has_bridges: bool = false,        // KEEP for now — remove in Task 7
    sidecar_path: ?[]const u8 = null, // KEEP for now — remove in Task 7
    is_zig_module: bool = false,      // NEW: true if auto-generated from .zig file
    zig_source_path: ?[]const u8 = null, // NEW: path to original .zig file
};
```

- [ ] **Step 2: Add pipeline call**

In `src/pipeline.zig`, after `_std_bundle.ensureStdFiles()` and before `mod_resolver.scanDirectory()`, add:

```zig
const zig_module = @import("zig_module.zig");

// ── Zig Module Discovery ─────────────────────────────
// Discover .zig files in src/, parse them, generate .orh into cache
const zig_modules = try zig_module.discoverAndConvert(allocator, cli.source_dir);
defer {
    for (zig_modules) |name| allocator.free(name);
    allocator.free(zig_modules);
}
```

- [ ] **Step 3: Make module resolver scan zig_modules cache dir**

After `mod_resolver.scanDirectory(cli.source_dir)`, add:

```zig
// Also scan generated zig module .orh files
const zig_mod_dir = cache.ZIG_MODULES_DIR;
std.fs.cwd().access(zig_mod_dir, .{}) catch |_| {};
if (std.fs.cwd().access(zig_mod_dir, .{})) |_| {
    try mod_resolver.scanDirectory(zig_mod_dir);
    // Mark discovered zig modules
    for (zig_modules) |name| {
        if (mod_resolver.modules.getPtr(name)) |mod_ptr| {
            mod_ptr.is_zig_module = true;
            // Store original .zig path for build.zig generation
            mod_ptr.zig_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.zig", .{ cli.source_dir, name });
        }
    }
} else |_| {}
```

- [ ] **Step 4: Build and verify compilation**

Run: `zig build 2>&1 | head -20`
Expected: Compiles cleanly. No functional change yet (no .zig files in test fixtures).

- [ ] **Step 5: Commit**

```bash
git add src/module.zig src/pipeline.zig
git commit -m "feat: wire zig_module discovery into pipeline and module system"
```

---

### Task 5: Modify codegen for zig-backed modules

Change codegen to emit re-exports for entire zig-backed modules instead of per-declaration bridge checks.

**Files:**
- Modify: `src/codegen/codegen_decls.zig` — add module-level zig re-export path

- [ ] **Step 1: Add `is_zig_module` and `module_name` to CodeGen**

Check if `CodeGen` already has `module_name` (it likely does from `generate(ast, mod_name)`). Add `is_zig_module: bool = false` field.

In `src/codegen/codegen.zig`, add field:
```zig
is_zig_module: bool = false,
```

In `src/pipeline_passes.zig` `runSemanticAndCodegen()`, after `cg.mir_root = mir_root`, add:
```zig
cg.is_zig_module = is_zig_module; // passed as new parameter
```

- [ ] **Step 2: Modify `generateFuncMir` for zig module re-export**

In `src/codegen/codegen_decls.zig`, change the bridge check (line ~41):

Before:
```zig
if (m.is_bridge) return cg.generateBridgeReExport(func_name, m.is_pub);
```

After:
```zig
if (cg.is_zig_module) return cg.generateZigReExport(func_name, m.is_pub);
```

- [ ] **Step 3: Rename `generateBridgeReExport` → `generateZigReExport`**

In `src/codegen/codegen_decls.zig` (line ~28):

```zig
pub fn generateZigReExport(cg: *CodeGen, name: []const u8, is_pub: bool) anyerror!void {
    const vis = if (is_pub) "pub " else "";
    try cg.emitLineFmt("{s}const {s} = @import(\"{s}_zig\").{s};", .{ vis, name, cg.module_name, name });
}
```

Note the naming change: `_bridge` → `_zig`.

- [ ] **Step 4: Update all other `is_bridge` checks in codegen_decls.zig**

Change lines ~289 and ~474:
```zig
// Before:
if (m.is_bridge) return cg.generateBridgeReExport(struct_name, m.is_pub);
// After:
if (cg.is_zig_module) return cg.generateZigReExport(struct_name, m.is_pub);
```

Same for the top-level const check:
```zig
// Before:
if (m.is_bridge) return cg.generateBridgeReExport(name, m.is_pub);
// After:
if (cg.is_zig_module) return cg.generateZigReExport(name, m.is_pub);
```

- [ ] **Step 5: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: Compiles cleanly.

- [ ] **Step 6: Commit**

```bash
git add src/codegen/codegen_decls.zig src/codegen/codegen.zig src/pipeline_passes.zig
git commit -m "feat: codegen emits re-exports for zig-backed modules"
```

---

### Task 6: Update build.zig generation

Change named module wiring from `bridge_` to `zig_` prefix and use `zig_source_path` instead of sidecar path.

**Files:**
- Modify: `src/zig_runner/zig_runner_multi.zig` — rename bridge → zig
- Modify: `src/zig_runner/zig_runner.zig` — same renames if present
- Modify: `src/pipeline.zig` — pass `is_zig_module`/`zig_source_path` to build targets

- [ ] **Step 1: Update MultiTarget struct**

Check `zig_runner_multi.zig` or `zig_runner.zig` for the `MultiTarget` struct. Replace `has_bridges: bool` with `is_zig_module: bool` and add `zig_source_path: ?[]const u8`.

- [ ] **Step 2: Rename bridge module creation in build.zig generation**

In `zig_runner_multi.zig`, change the bridge module creation (lines ~143-168):

Before:
```zig
const bridge_{name} = b.createModule(.{{
    .root_source_file = b.path("{name}_bridge.zig"),
```

After:
```zig
const zig_{name} = b.createModule(.{{
    .root_source_file = b.path("{name}.zig"),
```

Note: The .zig file is now referenced directly (copied to generated dir), not as `_bridge.zig`.

- [ ] **Step 3: Update all `addImport` references**

Change all occurrences of `bridge_{name}` to `zig_{name}` in module import wiring.

Change `@import("{name}_bridge")` references to `@import("{name}_zig")` — this must match what codegen emits in `generateZigReExport`.

- [ ] **Step 4: Update pipeline to pass zig module info to build targets**

In `src/pipeline.zig`, where `multi_targets` are constructed, pass `is_zig_module` and `zig_source_path` from the Module struct.

- [ ] **Step 5: Copy .zig source to generated dir**

In `pipeline_passes.zig` or `pipeline.zig`, for zig-backed modules, copy the `.zig` file to `.orh-cache/generated/{name}.zig` (replacing the old sidecar copy logic). This is simpler than the old `copySidecar` — just a file copy, no `export fn` fixup needed.

- [ ] **Step 6: Build and verify**

Run: `zig build 2>&1 | head -20`
Expected: Compiles cleanly.

- [ ] **Step 7: Commit**

```bash
git add src/zig_runner/zig_runner_multi.zig src/zig_runner/zig_runner.zig src/pipeline.zig src/pipeline_passes.zig
git commit -m "feat: build.zig generation uses zig modules instead of bridge sidecars"
```

---

### Task 7: Integration test — user .zig module

Create a test fixture with a `.zig` file and verify the full pipeline works.

**Files:**
- Create: `test/fixtures/zig_module/src/zigtest.zig`
- Create: `test/fixtures/zig_module/src/zigtest_app.orh` (anchor that imports zigtest)
- Modify: `test/09_language.sh` or `test/10_runtime.sh` — add zig module test

- [ ] **Step 1: Create test fixture `.zig` file**

```zig
// test/fixtures/zig_module/src/zigtest.zig
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn greet() []const u8 {
    return "hello from zig";
}

pub const MAGIC: i32 = 42;

pub const Calculator = struct {
    value: i32,

    pub fn create() Calculator {
        return .{ .value = 0 };
    }

    pub fn addValue(self: *Calculator, x: i32) void {
        self.value += x;
    }

    pub fn getResult(self: *const Calculator) i32 {
        return self.value;
    }
};

// Should be skipped — not pub
fn helper() void {}

// Should be skipped — incompatible type
pub fn allocate(alloc: std.mem.Allocator) void { _ = alloc; }
```

- [ ] **Step 2: Create Orhon anchor that uses the zig module**

```orhon
// test/fixtures/zig_module/src/zigtest_app.orh
module zigtest_app
#build = exe

import zigtest

func main() {
    var result: i32 = zigtest.add(10, 32)
    console.println(zigtest.greet())
}
```

- [ ] **Step 3: Add test to test suite**

Add a test in the appropriate test script that:
- Runs `orhon build` on the fixture
- Verifies compilation succeeds
- Runs the binary and checks output

- [ ] **Step 4: Run test**

Run: `./testall.sh 2>&1 | tail -10`
Expected: New test passes, all existing tests still pass.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/zig_module/ test/09_language.sh
git commit -m "test: add zig-as-module integration test"
```

---

### Task 8: Convert stdlib — remove `.orh` bridge files

Convert the 26 pure-bridge stdlib modules to zig-only. Move console.orh helper functions to console.zig. Keep linear.orh as-is (pure Orhon).

**Files:**
- Delete: 26 `.orh` files from `src/std/` (all except `linear.orh` and `console.orh`)
- Delete: `src/std/console.orh` after moving helpers to `console.zig`
- Modify: `src/std/console.zig` — add `printColored` and `printColoredLn` as native Zig
- Modify: `src/std_bundle.zig` — remove `*_ORH` embed constants for deleted files
- Modify: `src/std_bundle.zig` — update `ensureStdFiles()` to not write deleted `.orh` files

- [ ] **Step 1: Move console helper functions to Zig**

In `src/std/console.zig`, add at the end:

```zig
pub fn printColored(color: []const u8, msg: []const u8) void {
    print(color);
    print(msg);
    print(RESET);
}

pub fn printColoredLn(color: []const u8, msg: []const u8) void {
    println(color ++ msg ++ RESET);
}
```

Wait — Zig doesn't have `++` for runtime string concatenation. The Orhon `++` operator compiles to `std.mem.concat` or similar. For the Zig side, use sequential prints:

```zig
pub fn printColored(color: []const u8, msg: []const u8) void {
    print(color);
    print(msg);
    print(RESET);
}

pub fn printColoredLn(color: []const u8, msg: []const u8) void {
    print(color);
    print(msg);
    println(RESET);
}
```

- [ ] **Step 2: Delete 27 `.orh` files**

Delete all `.orh` files from `src/std/`:
```bash
rm src/std/allocator.orh src/std/async.orh src/std/collections.orh src/std/compression.orh src/std/console.orh src/std/crypto.orh src/std/csv.orh src/std/encoding.orh src/std/fs.orh src/std/http.orh src/std/ini.orh src/std/json.orh src/std/math.orh src/std/net.orh src/std/random.orh src/std/regex.orh src/std/simd.orh src/std/sort.orh src/std/stream.orh src/std/str.orh src/std/system.orh src/std/testing.orh src/std/time.orh src/std/toml.orh src/std/tui.orh src/std/xml.orh src/std/yaml.orh
```

Keep `src/std/linear.orh` — it's pure Orhon, no bridges.

- [ ] **Step 3: Update `std_bundle.zig`**

Remove all `*_ORH` embed constants. Keep all `*_ZIG` constants.
Update `ensureStdFiles()` to only write `.zig` files (the converter generates `.orh` from them).

For `linear.orh` — keep its embed and write, since it's a pure Orhon module (no `.zig` to convert from).

- [ ] **Step 4: Update stdlib zig_module discovery**

The stdlib `.zig` files are embedded and written to `.orh-cache/std/`. The zig_module converter needs to also scan this directory (or the pipeline needs to run conversion on the extracted std `.zig` files).

Add to the pipeline after `ensureStdFiles()`:
```zig
// Convert stdlib .zig files to Orhon modules
const std_zig_modules = try zig_module.discoverAndConvert(allocator, cache.STD_DIR);
defer { /* free */ }
```

- [ ] **Step 5: Build and run full test suite**

Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass — stdlib works through zig_module conversion.

- [ ] **Step 6: Commit**

```bash
git add -A src/std/ src/std_bundle.zig src/pipeline.zig
git commit -m "refactor: convert stdlib to zig-only modules, remove bridge .orh files"
```

---

### Task 9: Remove bridge keyword and grammar

Remove `bridge` from the language entirely — grammar, parser, PEG builder, token map.

**Files:**
- Modify: `src/peg/orhon.peg` — remove `bridge_decl`, `bridge_func`, `bridge_const`, `bridge_struct`, `bridge_struct_body` rules; remove `bridge_decl` from `top_level_decl` and `pub_decl`
- Delete: `src/peg/builder_bridge.zig` — entire file
- Modify: `src/peg/builder.zig` — remove bridge builder import and dispatch
- Modify: `src/peg/builder_decls.zig` — remove bridge references
- Modify: `src/peg/token_map.zig` — remove `bridge` token
- Modify: `src/parser.zig` — remove `is_bridge` from StructDecl and VarDecl, remove `.bridge` from FuncContext

- [ ] **Step 1: Remove grammar rules from `orhon.peg`**

Remove lines 199-213 (the bridge rules section). Remove `bridge_decl` from `top_level_decl` alternatives and `pub_decl` alternatives.

- [ ] **Step 2: Remove `.bridge` from FuncContext**

In `src/parser.zig` (line ~174):
```zig
pub const FuncContext = enum {
    normal,
    compt,
    thread,
};
```

Remove `bridge` variant entirely.

- [ ] **Step 3: Remove `is_bridge` from StructDecl and VarDecl**

In `src/parser.zig`:
- `StructDecl` (line ~194): remove `is_bridge: bool = false`
- `VarDecl` (line ~229): remove `is_bridge: bool = false`

- [ ] **Step 4: Delete `builder_bridge.zig`**

```bash
rm src/peg/builder_bridge.zig
```

- [ ] **Step 5: Remove bridge references from `builder.zig` and `builder_decls.zig`**

In `builder.zig`: remove `@import("builder_bridge.zig")` and any bridge dispatch calls.
In `builder_decls.zig`: remove `.bridge` references.

- [ ] **Step 6: Remove `bridge` from token_map**

In `src/peg/token_map.zig`: remove the entry for the `bridge` keyword.

- [ ] **Step 7: Fix all compilation errors**

The parser changes will cascade. Fix every file that references `.bridge`, `is_bridge`, or `FuncContext.bridge`:
- `src/resolver.zig` — remove `is_bridge` references
- `src/declarations.zig` — remove bridge checks, remove #cimport-requires-bridge validation
- `src/mir/mir_annotator.zig` — remove `.bridge` handling
- `src/mir/mir_annotator_nodes.zig` — remove `.bridge` references
- `src/mir/mir_lowerer.zig` — remove `.bridge`/`is_bridge` handling
- `src/mir/mir_node.zig` — remove bridge MIR kinds if any
- `src/pipeline_build.zig` — remove bridge-related helpers

- [ ] **Step 8: Build and verify**

Run: `zig build 2>&1 | head -30`
Expected: Compiles cleanly. Fix any remaining references.

- [ ] **Step 9: Commit**

```bash
git add -A src/peg/ src/parser.zig src/resolver.zig src/declarations.zig src/mir/ src/pipeline_build.zig
git commit -m "refactor: remove bridge keyword from grammar, parser, and all passes"
```

---

### Task 10: Remove bridge infrastructure from pipeline and cache

Remove `copySidecar()`, `copySidecarImports()`, `has_bridges`, `sidecar_path`, and all bridge-specific pipeline logic.

**Files:**
- Modify: `src/module.zig` — remove `has_bridges` and `sidecar_path` fields
- Modify: `src/module_parse.zig` — remove bridge detection (lines 338-374)
- Modify: `src/pipeline_passes.zig` — remove `copySidecar()` function
- Modify: `src/pipeline.zig` — remove `sidecar_copied` map and `copySidecar` call
- Modify: `src/cache.zig` — remove `copySidecarImports()`, `copySidecarImportsInner()`, `scanZigImports()`
- Modify: `src/codegen/codegen_decls.zig` — remove `generateBridgeReExport()` (now dead code)

- [ ] **Step 1: Remove Module struct bridge fields**

In `src/module.zig`, remove:
```zig
has_bridges: bool = false,
sidecar_path: ?[]const u8 = null,
```

- [ ] **Step 2: Remove bridge detection from module_parse.zig**

Remove the entire block at lines 338-374 that scans for bridge declarations and validates sidecar.

- [ ] **Step 3: Remove `copySidecar()` from pipeline_passes.zig**

Delete the entire function (lines ~90-134).

- [ ] **Step 4: Remove sidecar infrastructure from pipeline.zig**

Remove `sidecar_copied` map declaration, initialization, and the `copySidecar()` call.

- [ ] **Step 5: Remove `copySidecarImports` from cache.zig**

Delete `copySidecarImports()`, `copySidecarImportsInner()`, and `scanZigImports()` — approximately 100 lines.

- [ ] **Step 6: Remove dead `generateBridgeReExport`**

In `codegen_decls.zig`, delete the old function (if not already renamed in Task 5).

- [ ] **Step 7: Fix all compilation errors from removed fields**

Search for `has_bridges`, `sidecar_path`, `copySidecar` across the codebase and fix all references:
- `zig_runner_multi.zig` — replace `has_bridges` with `is_zig_module` in MultiTarget
- `pipeline.zig` — remove `has_bridges` references in multi-target/single-target build sections

- [ ] **Step 8: Build and run full test suite**

Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass with bridge system fully removed.

- [ ] **Step 9: Commit**

```bash
git add -A src/
git commit -m "refactor: remove bridge infrastructure — copySidecar, has_bridges, sidecar_path"
```

---

### Task 11: Update #cimport to work without bridges

Currently `#cimport` requires bridge declarations. With bridges gone, `#cimport` should work in any module that has a `.zig` file (zig-backed module) since C interop goes through Zig.

**Files:**
- Modify: `src/declarations.zig` — change #cimport validation
- Modify: `src/zig_runner/zig_runner_multi.zig` — wire C includes/libs to zig modules

- [ ] **Step 1: Update #cimport validation**

In `src/declarations.zig`, the validation that rejects `#cimport` without bridge declarations needs to either:
- Be removed entirely (allow #cimport in any module — the Zig build system handles it)
- Or check `is_zig_module` instead of `has_bridge`

The simplest correct change: remove the bridge requirement. `#cimport` is a build directive, not a bridge feature. The generated build.zig handles C linking regardless.

- [ ] **Step 2: Verify C interop still works**

If there are test fixtures using `#cimport`, run them:
Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/declarations.zig src/zig_runner/zig_runner_multi.zig
git commit -m "refactor: decouple #cimport from bridge system"
```

---

### Task 12: Update documentation and clean up

Update all documentation references to bridges. Update CLAUDE.md, language spec docs, example module.

**Files:**
- Modify: `docs/14-zig-bridge.md` — rewrite as "Zig Module Integration"
- Modify: `docs/TODO.md` — mark zig-as-module as done
- Modify: `CLAUDE.md` — update architecture sections referencing bridges
- Modify: `src/templates/example*.orh` — remove any bridge examples, add zig module example

- [ ] **Step 1: Rewrite bridge documentation**

Rewrite `docs/14-zig-bridge.md` to document the new system:
- How to add a `.zig` module (just put a `.zig` file in `src/`)
- Underscore convention for private files
- Type mapping reference table
- What gets skipped and why
- How to fix incompatible signatures

- [ ] **Step 2: Update TODO.md**

Mark the zig-as-module task as done. Update architectural decisions table.

- [ ] **Step 3: Update CLAUDE.md**

Update all references to bridges, sidecars, `has_bridges`, bridge codegen pattern.

- [ ] **Step 4: Run final test suite**

Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass. No bridge references remain.

- [ ] **Step 5: Commit**

```bash
git add docs/ CLAUDE.md src/templates/
git commit -m "docs: update documentation for zig-as-module system"
```

---

### Task 13: Final cleanup and dead code removal

Remove `collectAssigned()`/`getRootIdent()` AST-path remnants from codegen_decls.zig (pre-existing dead code from TODO).

**Files:**
- Modify: `src/codegen/codegen_decls.zig`

- [ ] **Step 1: Remove dead functions**

Find and delete `collectAssigned()` and `getRootIdent()` — these are AST-path remnants identified in TODO.md.

- [ ] **Step 2: Build and test**

Run: `./testall.sh 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/codegen/codegen_decls.zig
git commit -m "cleanup: remove dead collectAssigned/getRootIdent AST-path remnants"
```

---

## Execution Order

Tasks 1-3 are the new converter (can be built and tested in isolation).
Task 4 wires it into the pipeline.
Task 5-6 make codegen and build.zig work with zig modules.
Task 7 is the integration test proving it works end-to-end.
Task 8 converts the stdlib (big but mechanical).
Tasks 9-10 remove the bridge system (cascading deletions).
Task 11 fixes #cimport.
Task 12-13 are documentation and cleanup.

**Critical path:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13

All tasks are sequential — each builds on the previous. The bridge system stays functional until Task 9-10, so existing tests keep passing throughout.
