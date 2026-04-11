# Cross-Module Type Mapping for Sibling Zig Modules

**Status:** Approved
**Date:** 2026-04-11
**Fixes:** GAP-001 (tamga compiler-gaps.md)

## Problem

When the Zig-to-Orhon module converter (`zig_module.zig`) encounters a function whose parameter or return type references a type from another sibling Zig module, `mapTypeEx()` rejects the type and silently skips the entire function.

Two patterns produce `.field_access` AST nodes in type positions:

1. **Inline import:** `@import("tamga_sdl3_bridge").WindowHandle`
2. **Alias:** `const sdl = @import("tamga_sdl3_bridge"); ... fn create(w: sdl.WindowHandle)`

Both hit the `.field_access` case in `mapTypeEx()` (line 143-146), which unconditionally returns `false`. The function is then dropped from the generated `.orh` module.

The import detection side already works — `scanZigImports()` finds sibling `.zig` files and injects `import` statements into the `.orh` output. The type mapping just never uses this information.

## Solution: Import-Aware mapTypeEx with Alias Map

### Data Structure

```
ImportAliasMap {
    map: StringHashMap([]const u8)   // "sdl" → "tamga_sdl3_bridge"
    sibling_modules: [][]const u8     // known sibling module names
}
```

Built once per module inside `generateModule()` by:
1. Receiving the sibling module list (from `scanZigImports()`)
2. Scanning AST root declarations for `const X = @import("Y.zig")` patterns
3. Mapping each alias identifier to its module name stem

### mapTypeEx .field_access Resolution

Replace the unconditional `return false` with:

1. Decompose `.field_access` into LHS + RHS
2. Extract RHS token text — this is the type name (e.g., `WindowHandle`)
3. Resolve LHS:
   - **If identifier** (e.g., `sdl`): look up in alias map → get module name
   - **If builtin call** (`@import("X.zig")`): extract string literal, strip `.zig` suffix
4. Check if resolved module name is in the sibling list
5. If yes: emit `module_name.TypeName` into output buffer, return `true`
6. If no: return `false` (unchanged behavior for `std.mem.Allocator` etc.)

### Call Chain Threading

The alias map flows through the existing call chain as a single optional parameter:

```
discoverAndConvert()                    — moves scanZigImports() before generateModule()
  → generateModule(..., sibling_imports)  — builds ImportAliasMap, passes down
    → extractFn(..., import_aliases)       — passes through
      → extractFnInnerEx(..., import_aliases) — passes through
        → mapTypeEx(..., import_aliases)     — uses for .field_access resolution
```

- `mapType()` (public API): unchanged, passes `null` — no behavior change for non-module callers
- All recursive `mapTypeEx()` calls (optional, error_union, pointer) pass the aliases through

### Signature Changes

```zig
// mapTypeEx gains one parameter
fn mapTypeEx(tree, node, allocator, out, self_replacement, import_aliases: ?*const ImportAliasMap) anyerror!bool

// generateModule gains one parameter
pub fn generateModule(mod_name, tree, allocator, sibling_imports: []const []const u8) anyerror!?[]const u8

// extractFn, extractFnInner, extractFnInnerEx gain one parameter each
pub fn extractFn(tree, node, allocator, import_aliases: ?*const ImportAliasMap) anyerror!?[]const u8
fn extractFnInner(tree, node, struct_name, prefix, allocator, import_aliases) anyerror!?[]const u8
fn extractFnInnerEx(tree, node, struct_name, prefix, allocator, self_replacement, allow_unmappable_as_any, import_aliases) anyerror!?[]const u8
```

## Scope

**In scope:**
- `.field_access` resolution for sibling Zig module types (alias + inline @import)
- Threading import context through the call chain
- Works in all recursive type positions (optional, error union, pointer wrapping a cross-module type)

**Not in scope:**
- Deeply nested qualified names (`a.b.c.Type`) — only one level of module qualification
- Non-sibling imports (stdlib types remain unmappable)
- Struct field type mapping (could extend later with same approach)

## Expected Result

Given this Zig code:
```zig
const sdl = @import("tamga_sdl3_bridge");
pub fn create(window_handle: sdl.WindowHandle, debug_mode: bool) anyerror!Renderer { ... }
```

The generated `.orh` becomes:
```
import tamga_sdl3_bridge

pub bridge func create(window_handle: tamga_sdl3_bridge.WindowHandle, debug_mode: bool) (Error | Renderer)
```

Instead of silently dropping the function.
