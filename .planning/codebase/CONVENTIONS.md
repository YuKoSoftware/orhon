# Coding Conventions

**Analysis Date:** 2026-03-24

## Naming Patterns

**Files:**
- `snake_case.zig` for all source files: `codegen.zig`, `zig_runner.zig`, `thread_safety.zig`
- Subdirectories use `snake_case/` as well: `src/peg/`, `src/std/`

**Structs and Types:**
- `PascalCase` for public structs and enums: `Reporter`, `CodeGen`, `MirAnnotator`, `TypeClass`, `OwnershipScope`
- `PascalCase` for type aliases: `const RT = types.ResolvedType;`

**Functions:**
- `camelCase` for all methods and free functions: `init`, `deinit`, `hasErrors`, `typeToZig`, `classifyType`, `resolveFileLoc`
- Verb-first naming for methods: `checkNode`, `checkExpr`, `collectTopLevel`, `generateFunc`, `emitLine`
- Private helper functions use the same `camelCase`, just without `pub`

**Variables and Fields:**
- `snake_case` for fields and local variables: `file_offsets`, `active_borrows`, `decl_table`, `is_debug`
- Boolean fields start with `is_`, `has_`: `is_pub`, `is_compt`, `is_thread`, `has_bridges`

**Constants:**
- `SCREAMING_SNAKE_CASE` for module-level string/array constants: `BUILTIN_TYPES`, `COMPILER_FUNCS`, `CACHE_DIR`
- Namespace constants inside structs also `SCREAMING_SNAKE_CASE`: `K.Type.ERROR`, `K.Ptr.VAR_REF`

**Enum Variants:**
- `snake_case` for enum variants: `.owned`, `.moved`, `.error_union`, `.null_union`, `.kw_func`, `.lparen`
- Exception: token kinds and node kinds use `snake_case` consistently throughout

## File Structure

**File header comment (mandatory for every source file):**
```zig
// filename.zig — short description
// Additional context lines if needed.
```
Examples from codebase:
- `// errors.zig — Orhon compiler error formatting`
- `// codegen.zig — Zig Code Generation pass (pass 11)`
- `// mir.zig — MIR (Mid-level Intermediate Representation) pass (pass 10)`

**Section separators (two styles used):**
```zig
// ============================================================
// SECTION NAME
// ============================================================
```
Used in `parser.zig`, `codegen.zig`, `main.zig` for major logical sections.

```zig
// ── Section Name ─────────────────────────────────────────────
```
Used in `mir.zig` for finer-grained sections within a file.

**Tests are always at the bottom of the file**, separated by:
```zig
// ── Tests ───────────────────────────────────────────────────
```
or a `// ====` separator.

## Import Organization

**Order (consistent throughout):**
1. `const std = @import("std");` — always first
2. Local module imports by dependency order: `parser`, `lexer`, then higher-level passes
3. Aliased imports immediately after: `const RT = @import("types.zig").ResolvedType;`
4. Module-level `const K = @import("constants.zig");` pattern for shared string constants

**Path aliases:**
- No path aliases used — all imports use relative paths
- `@import("../lexer.zig")` from subdirectories (e.g. `src/peg/`)

## Constructor Pattern

**All structs use `.init()` / `.deinit()` pair:**
```zig
pub fn init(allocator: std.mem.Allocator, ...) StructName {
    return .{
        .field = value,
        ...
    };
}

pub fn deinit(self: *StructName) void {
    // free owned memory
}
```
Every struct that owns allocations has both `init` and `deinit`. No exceptions observed.

**Test helper variant — `initForTest`:**
```zig
pub fn initForTest(allocator: std.mem.Allocator, reporter: *errors.Reporter, decls: *declarations.DeclTable) SemanticContext {
    return .{ .allocator = allocator, .reporter = reporter, .decls = decls, .locs = null, .file_offsets = &.{} };
}
```
Pattern used in `sema.zig` to provide minimal context for unit tests without full pipeline setup.

## Error Handling

**Strategy:** Errors bubble up via Zig's `!` return type. No panics in business logic.

**Recursive functions use `anyerror!` explicitly:**
```zig
fn checkNode(self: *OwnershipChecker, node: *parser.Node, scope: *OwnershipScope) anyerror!void { ... }
fn collectTopLevel(self: *DeclCollector, node: *parser.Node) anyerror!void { ... }
fn generateImport(self: *CodeGen, node: *parser.Node) anyerror!void { ... }
```
Non-recursive functions use inferred `!ReturnType`.

**Error reporting uses `Reporter` (never direct stderr in passes):**
```zig
const msg = try std.fmt.allocPrint(self.allocator, "error: '{s}'", .{name});
defer self.allocator.free(msg);
try self.reporter.report(.{ .message = msg, .loc = loc });
```
The `Reporter` owns all strings — allocate with `allocPrint`, always `defer free` before `report()`.

**Fatal pre-Reporter errors use `errors.fatal()`:**
```zig
errors.fatal("could not open file: {s}", .{path});  // noreturn
```

## Memory Management

**Defer cleanup is mandatory at call site:**
```zig
var reporter = Reporter.init(alloc, .debug);
defer reporter.deinit();

var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
```

**Arena allocators for AST nodes** — entire tree freed in one call via `arena.deinit()`.

**`std.ArrayListUnmanaged` preferred over `std.ArrayList`** — caller supplies allocator explicitly at each operation. Used throughout for growable slices: `errors`, `warnings`, `output`, `active_borrows`.

**`std.StringHashMap` for name→value maps** — e.g. `funcs`, `structs`, `enums` in `DeclTable`.

**Embedded file content uses `@embedFile`** — never inline multi-line strings.

## Comments

**Doc comments (`///`) on:**
- Public types and their fields
- Non-obvious functions
- Enum variants when the name is not self-explanatory

**Regular comments (`//`) for:**
- Inline clarification
- Section headers
- Pass numbers: `// Ownership & Move Analysis pass (pass 6)`

**Field-level inline comments** used extensively in large structs to document purpose:
```zig
in_test_block: bool,     // inside a test { } block — assert uses std.testing.expect
destruct_counter: usize, // unique index for destructuring temp vars
warned_rawptr: bool,     // RawPtr/VolatilePtr warning printed once per module
```

**No stale comments** — comments are kept in sync with code. Update or remove when changing code.

## Exported vs Internal

**`pub` on:**
- Types and structs intended for use across modules
- `init`, `deinit`, and primary entry-point methods
- Constants needed elsewhere

**Private (no `pub`) on:**
- Internal helper functions: `emit`, `emitFmt`, `emitIndent`, `checkStatement`, `lookupFieldType`
- Section-internal logic

## Module Design

**One struct per "pass" per file** — each compiler pass has a single named struct as its entry point:
- `errors.zig` → `Reporter`
- `declarations.zig` → `DeclCollector`, `DeclTable`
- `ownership.zig` → `OwnershipChecker`, `OwnershipScope`
- `codegen.zig` → `CodeGen`
- `mir.zig` → `MirAnnotator`, `MirLowerer`, `UnionRegistry`

**Shared data types in dedicated files:**
- `types.zig` — `ResolvedType`, `Primitive`, `OwnershipState`
- `constants.zig` — shared string constants (`K.Type.*`, `K.Ptr.*`)
- `parser.zig` — AST node types only (no parsing logic)

---

*Convention analysis: 2026-03-24*
