# Phase 20: Tamga Build Verification - Research

**Researched:** 2026-03-27
**Domain:** Orhon compiler — codegen, build system, keyword parsing
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** All 9 open Tamga bugs are in-scope. No deferrals.
  1. Multi-type null union collapses to optional (`?A` instead of tagged union)
  2. `cast(EnumType, int)` emits `@intCast` instead of `@enumFromInt`
  3. Empty struct construction `TypeName()` generates invalid Zig (should be `TypeName{}`)
  4. Multi-file module with Zig sidecar: "file exists in two modules"
  5. `size` is a reserved keyword in bridge func parameters
  6. `const &BridgeStruct` passes by value instead of by pointer
  7. Sidecar `export fn` should emit `pub export fn`
  8. Cross-module `@cImport` type identity (shared C import module)
  9. No mechanism to compile C/C++ source files in modules (`#csource` directive)

- **D-02:** Verify by building Tamga from its repo with the newly-built compiler. Success = `orhon build` completes without errors in the Tamga project directory.
- **D-03:** The compiler's existing test suite (`./testall.sh`) must also pass — no regressions.
- **D-04:** Remove ALL workarounds from Tamga source files after fixing each compiler bug.

### Claude's Discretion

No discretion areas documented.

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| REQ-20 | Fix all 9 open compiler bugs so Tamga builds end-to-end with `orhon build`; remove all workarounds from Tamga source files | Each bug has been investigated below with root cause, exact fix location, and workaround-removal target |
</phase_requirements>

---

## Summary

Phase 20 is a targeted bug-fix phase: fix 9 compiler bugs discovered during Tamga development, then remove the workarounds from Tamga source. The bugs span three compiler subsystems: `codegen.zig` (Bugs 1, 2, 3, 6, 7), `zig_runner.zig` (Bugs 4, 8, 9), and `orhon.peg` / PEG keyword handling (Bug 5).

**Bug 4 is already fixed** (confirmed in debug session: `tamga-compiler-bugs.md`). The fix added lib-to-lib `addImport` and topological sort to `buildZigContentMulti`. The debug session also surfaced a *separate* cross-bridge file-path import issue that needs Tamga-side changes (not a compiler bug).

**Bug 5 (`size` keyword) appears to be already fixed** in `orhon.peg`: `param_name` rule (line 118) already includes `'size'`. This needs verification by trying to compile a bridge func with `size` as a param name.

**Bug 7 (`export fn` missing `pub`)** is specific to hand-written sidecars that use `export fn` without `pub` — the VMA sidecar (`tamga_vma.zig`) has this. The Tamga `main.zig` already has `pub export fn` (correctly fixed). The compiler copies sidecars verbatim; the fix is in the Tamga sidecar files themselves, or in a compiler-side post-processing step.

**Primary recommendation:** Work bug-by-bug in this order: 5 (verify/close), 4 (verify/close), 7 (Tamga sidecar fix), 3 (codegen), 2 (codegen), 1 (codegen), 6 (MIR), 8 (zig_runner), 9 (zig_runner + grammar). Tackle Tamga workaround removal after each compiler fix is confirmed.

---

## Standard Stack

No new libraries needed. All fixes are in existing compiler source files.

| File | Bug(s) Fixed | Role |
|------|-------------|------|
| `src/codegen.zig` | 1, 2, 3, 6, 7 | Code generation pass — typeToZig, cast codegen, struct init, bridge param coercion |
| `src/zig_runner.zig` | 8, 9 | Build.zig generation — shared cImport modules, `#csource`/`#object` directives |
| `src/orhon.peg` + `src/peg/builder.zig` | 5, 9 | Grammar and metadata parsing |
| `src/main.zig` | 9 | Metadata collection that feeds zig_runner |
| Tamga source files | 1-9 workarounds | Workaround removal targets |

---

## Architecture Patterns

### Bug 1: Multi-type null union — `typeToZig` fix

**Location:** `src/codegen.zig` `typeToZig()` — lines 3908–3963

**Current behavior:** When `has_null == true` and `non_special_count > 1`, the code already has the correct path (lines 3934–3951): builds `?(union(enum) { _A: A, _B: B, ... })`. This was recently added.

**Verification needed:** Confirm that both `typeToZig` AND the *return statement codegen* for such a union are correct. The bug report says `return .{ ._null = null }` is generated — this is the MIR return coercion path, not just the type string. When a function returns `null` into a `?(union(enum) { ... })`, the codegen must emit `null` (not `.{ ._null = null }`).

**Key question:** The `typeToZig` fix for the type STRING is in place. The remaining issue may be in how `return NoEvent(empty: false)` vs `return null` is generated when the union is nullable. Since the workaround uses `NoEvent` (not null), this needs a new test fixture, not just Tamga.

**Pattern:**
```zig
// typeToZig already handles this — verify the return statement path
// In pollEvent, returning a union variant into ?(union(enum) {...}) should emit:
// return .{ ._NoEvent = .{} };  (not return .{ ._null = null };)
```

### Bug 2: `cast(EnumType, int)` — `isEnumTypeName` scope

**Location:** `src/codegen.zig` `isEnumTypeName()` — line 206

**Current behavior:** `isEnumTypeName` checks `self.decls.enums.contains(name)` — only the **current module's** enums. If the enum is declared in the same module, this works. If the enum is cross-module (e.g., `tamga_sdl3.Scancode` in a different module), it won't be found.

**For Tamga specifically:** The `cast(Scancode, raw_int)` call is inside `tamga_sdl3.orh` itself, where `Scancode` is declared. So it should work once the workaround is removed and real `Scancode` typed fields are used.

**However:** The AST path vs MIR path for cast both call `isEnumTypeName(args[0].ast)` — the MIR version passes `cf.args[0]` (a `*parser.Node`). When the call expression uses a type from another module (e.g., `tamga_sdl3.Scancode`), `args[0]` may be a `field_expr` node, not a `type_named` node, causing `isEnumTypeName` to return `false`.

**Fix:** Either extend `isEnumTypeName` to handle scoped type names (lookup the module's decl table via `all_decls`), or document that cross-module enum casts are the limitation.

**For Tamga workaround removal:** Since `cast(Scancode, x)` will be intra-module (inside `tamga_sdl3.orh`), this should work without cross-module lookup. Verify by testing.

### Bug 3: Empty struct construction — call_expr vs struct init

**Location:** `src/codegen.zig` — wherever call_expr nodes targeting zero-field structs are emitted

**Pattern:** `TypeName()` in Orhon (no args) should emit `TypeName{}` in Zig when `TypeName` is a struct with zero fields. Currently it emits `TypeName()`.

**Where to fix:** Search for where call_expr with zero arguments is generated. The fix needs to: (1) detect that the callee is a struct type (not a function), and (2) detect that the struct has zero fields. Use `self.decls.structs.contains(name)` + check field count.

**Important:** Only apply this for **zero-field** structs. If a struct has fields but all have defaults, `TypeName()` is still a function call (constructor). The discriminant is: `call_expr` with zero args where the callee is a known struct with zero declared fields.

**Zig target:**
```zig
// NoEvent() → NoEvent{}
// In the generated .zig file
return NoEvent{};
```

### Bug 4: Multi-file module with Zig sidecar — ALREADY FIXED

**Status:** Fixed in debug session `tamga-compiler-bugs.md`. Root cause was missing `addImport` for lib-to-lib dependencies in `buildZigContentMulti`. The fix added topological sort and lib-to-lib `addImport` emission.

**Separate issue surfaced:** After the Bug 4 fix, a new error appeared: "file exists in modules 'tamga_vma' and 'root'" for `tamga_vk3d_bridge.zig`. This is caused by `tamga_vk3d.zig` (the hand-written sidecar) having `const vma = @import("tamga_vma_bridge")` — a direct file-path-style import inside the bridge file. The debug session concluded this requires changes to Tamga's bridge file structure, not a compiler fix.

**Current build.zig:** The cached `build.zig` shows `bridge_tamga_vk3d.addImport("tamga_vma_bridge", bridge_tamga_vma)` is already emitted — so named module resolution IS wired. The conflict must be that `tamga_vk3d.zig` is registered both as part of `lib_tamga_vk3d` (its root_source_file) AND as `tamga_vk3d_bridge.zig` (a bridge copy). The bridge copy at `tamga_vk3d_bridge.zig` imports `tamga_vma_bridge`, and if Zig sees `tamga_vk3d_bridge.zig` in two module contexts, that's the conflict.

**What needs investigation:** Whether this "second cross-bridge issue" has been resolved or still blocks Tamga build.

### Bug 5: `size` keyword in bridge func params — LIKELY ALREADY FIXED

**Status:** `orhon.peg` line 118 already lists `'size'` in `param_name`:
```
param_name <- IDENTIFIER / 'var' / 'const' / 'cast' / 'copy' / 'move' / 'swap' / 'assert' / 'size' / 'align' / 'typename' / 'typeid' / 'typeof'
```
`bridge_func` uses `param_list` → `param` → `param_name`, so this fix is already in place.

**Verify:** Compile a bridge func with `size` as a parameter name. If it parses correctly, mark closed and remove Tamga workaround (`byte_size`/`byte_count` → `size`).

### Bug 6: `const &BridgeStruct` passes by value — MIR coercion gap

**Location:** `src/mir.zig` `annotateCallCoercions()` — lines 468–514

**Root cause (confirmed by code inspection):** The comment in `annotateCallCoercions` at line 468 explicitly states: "Const auto-borrow is limited to same-module direct calls (c.callee is an identifier). Cross-module calls (field_expr callee) are excluded."

When calling `renderer.draw(mesh, matrix)`, the callee is a `field_expr` (`renderer.draw`). The `is_direct_call` check returns `false`. No `value_to_const_ref` coercion is emitted for `mesh` even though the bridge parameter is `const &Mesh`.

**Fix approach:** For bridge function calls specifically, the coercion must be injected differently. Options:
1. **Bridge-aware parameter inspection:** When the call is a field_expr on a bridge struct, look up the bridge function signature and apply `value_to_const_ref` for `const &` params explicitly.
2. **Extend `resolveCallSig`** to return bridge struct method signatures and detect `const &` param types, then annotate coercions for those params even in cross-module/field_expr context.

**Key constraint:** The fix must not break the general cross-module exclusion (which prevents double-borrow for struct methods where `value_to_const_ref` would conflict with existing `*const T` promotion).

**Tamga workaround:** `tamga_vk3d.orh` has `bridge func draw(self: &Renderer, mesh: Mesh, ...)` — `mesh` is passed by value to avoid the bug. After fix, change to `mesh: const &Mesh` and confirm `&mesh` is emitted at call sites.

### Bug 7: `export fn` → `pub export fn` in sidecars

**Location:** Tamga sidecar files — `src/TamgaVMA/tamga_vma.zig`

**Confirmed:** `tamga_vma.zig` lines 426, 445, 450, 464, 470 all use `export fn` without `pub`. The compiler copies sidecars verbatim. The generated re-export in Orhon codegen is:
```zig
pub const vma_create = @import("tamga_vma_bridge").vma_create;
```
This requires `vma_create` to be `pub` in the bridge, but `export fn vma_create(...)` without `pub` is not publicly accessible as a module member.

**Fix approach (two options):**
1. **Tamga sidecar fix:** Change all `export fn` to `pub export fn` in `tamga_vma.zig`. Simple and correct.
2. **Compiler post-processing:** During sidecar copy in `main.zig`, regex-replace `export fn ` with `pub export fn `. Fragile — not recommended.

**Recommendation:** Fix the Tamga sidecar (`tamga_vma.zig`) — change all 5 `export fn` declarations to `pub export fn`. This is the correct and clean approach.

**Note:** `main.zig` already has `pub export fn` — already correct. `tamga_sdl3.zig` and `tamga_vk3d.zig` do not use `export fn` at all (they use regular `pub fn`), so only `tamga_vma.zig` needs fixing.

### Bug 8: Cross-module `@cImport` type identity

**Location:** `src/zig_runner.zig` — build.zig generation

**Root cause:** Each Zig sidecar that `@cInclude`s the same header creates an independent `@cImport` unit. Zig types from different `@cImport` units are structurally incompatible even if they originate from the same header. VkBuffer from `tamga_vma.zig`'s `@cImport` != VkBuffer from `tamga_vk3d.zig`'s `@cImport`.

**Fix approach:** Generate a shared C import module in `build.zig` for all modules that `#linkC` the same library. Sidecars reference this shared module instead of their own `@cImport`.

**Complexity:** This requires:
1. Detecting which modules share C libraries (from `#linkC` metadata)
2. Generating a shared `{libname}_c.zig` file that contains the `@cImport`
3. Modifying each sidecar to `@import` the shared module instead of doing its own `@cImport`

**Problem:** Sidecars are hand-written files — the compiler cannot modify them to replace `@cImport`. The compiler can generate a shared module and `addImport` it to both bridge modules, but the sidecars must explicitly use `@import("vulkan_c")` instead of their own `const c = @cImport(...)`.

**Practical fix for Tamga:** Change `tamga_vma.zig` and `tamga_vk3d.zig` to both use `const c = @import("vulkan_c")`. The compiler generates `vulkan_c.zig` (a shared `@cImport` wrapper) and wires it via `addImport`. This eliminates type incompatibility at the boundary.

**Current workaround:** `@ptrCast` at every cross-module Vulkan handle boundary in `tamga_vk3d.zig`. After fix, these casts can be removed.

### Bug 9: `#csource` directive for C/C++ source files

**Location:** `src/orhon.peg` (grammar), `src/peg/builder.zig` (metadata), `src/main.zig` (metadata collection), `src/zig_runner.zig` (build.zig generation)

**Zig 0.15 pattern** for adding C/C++ sources to a Zig build target:
```zig
lib_tamga_vma.root_module.addCSourceFiles(.{
    .files = &.{"../../src/TamgaVMA/vma_impl.cpp"},
    .flags = &.{"-std=c++17"},
});
lib_tamga_vma.linkLibCpp();
```

**Current workaround:** Pre-compile `vma_impl.cpp` separately with `zig c++`, then add `addObjectFile` pointing to `vma_impl.o`. The cached `build.zig` shows:
```zig
lib_tamga_vma.addObjectFile(.{ .cwd_relative = "../../src/TamgaVMA/libs/vma_impl.o" });
lib_tamga_vma.linkLibCpp();
```
This is a manual patch applied after `orhon build` overwrites `build.zig`.

**Design choice:** `#csource "path"` vs `#object "path"` — source vs pre-compiled object. Source is cleaner (single build step) but requires compiler flags. Object is simpler to implement. Both should be supported.

**Implementation path:**
1. Add `#csource "path"` to `metadata_body` rule in `orhon.peg` — already handled by the generic `IDENTIFIER '=' expr` fallback or as a named alternative
2. Collect `csource` metadata in `main.zig` alongside `linkC` collection
3. Pass `c_source_files` to `buildZigContent*` functions in `zig_runner.zig`
4. Emit `addCSourceFiles` in the generated `build.zig` for the target lib/exe

**Note:** The pre-compiled `vma_impl.o` exists in `libs/`. The `#csource` directive should reference the `.cpp` source and let the build system compile it. The `.o` pre-compilation workaround can then be removed.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Null union type string | Custom null-union printer | Fix `typeToZig()` existing multi-null branch |
| Enum detection in cast | New IR pass | Extend existing `isEnumTypeName` + `all_decls` lookup |
| C/C++ build integration | Custom build runner | Zig's `addCSourceFiles` / `addObjectFile` API |
| Shared `@cImport` | Runtime type casting | Shared module via `b.createModule` + `addImport` |

---

## Bug Status Summary

| # | Bug | Status | Fix File | Complexity |
|---|-----|--------|----------|------------|
| 1 | Multi-type null union | Open — typeToZig string fixed; return-stmt coercion needs verification | `codegen.zig` | Medium |
| 2 | `cast(Enum, int)` → @intCast | Open — intra-module likely works; verify by removing workaround | `codegen.zig` isEnumTypeName | Low |
| 3 | Empty struct `TypeName()` → `TypeName{}` | Open | `codegen.zig` call_expr path | Low |
| 4 | "file exists in two modules" | FIXED in debug session | `zig_runner.zig` | Done |
| 5 | `size` keyword in params | LIKELY FIXED in orhon.peg | `orhon.peg` param_name | Verify only |
| 6 | `const &BridgeStruct` by value | Open — MIR cross-module coercion gap | `mir.zig` | Medium |
| 7 | `export fn` not `pub export fn` | Open — Tamga VMA sidecar fix | `tamga_vma.zig` | Low |
| 8 | Cross-module @cImport types | Open — requires shared module gen + sidecar changes | `zig_runner.zig` + Tamga sidecars | High |
| 9 | No `#csource` directive | Open — full pipeline addition | peg + builder + main + zig_runner | Medium |

---

## Common Pitfalls

### Pitfall 1: Bug 1 — Return Statement Coercion vs Type String

**What goes wrong:** `typeToZig` for `?(union(enum) {...})` is correct, but the **return statement** for `return NoEvent(empty: false)` inside the `?(union(enum) {...})` return type requires wrapping as `.{ ._NoEvent = NoEvent{...} }` — not just the type change.

**Why it happens:** `typeToZig` and return-value codegen are separate code paths. Fixing the type string doesn't fix how union variant values are wrapped in returns.

**How to avoid:** When removing the `NoEvent` workaround and restoring the `null`-based union, test that the generated Zig for every `return` branch in `pollEvent()` is valid.

### Pitfall 2: Bug 4 — Cross-bridge Import Conflict Resurfaces

**What goes wrong:** The debug session noted a SECOND "file exists in modules" error — "tamga_vma and root" for `tamga_vk3d_bridge.zig`. This was declared out-of-scope for the debug session but may reblock Tamga build.

**Root cause:** `tamga_vk3d.zig` does `const vma = @import("tamga_vma_bridge")` at the top — a file-relative import. When this file is registered as both `lib_tamga_vk3d`'s root and as `tamga_vk3d_bridge`, Zig may still see conflicting module membership.

**How to avoid:** After fixing Bug 4 (already done), attempt Tamga build and observe whether this second error appears. If it does, the fix is to ensure `tamga_vk3d.zig` (the bridge) is registered only once — as the bridge module, not as the lib root. The lib root should be the generated `tamga_vk3d.zig` (codegen output), not the hand-written sidecar.

### Pitfall 3: Bug 6 — Double-borrow on Bridge Struct Self

**What goes wrong:** When fixing Bug 6, over-aggressive `value_to_const_ref` injection at call sites where `self` is already a reference causes double-borrow (`&&value`).

**Why it happens:** The existing exclusion for cross-module calls prevents this, but a targeted bridge-struct fix must skip `self` params (which are already `&T`).

**How to avoid:** Only inject `value_to_const_ref` for non-self bridge params typed as `const &T` where the arg is a value (not already a reference).

### Pitfall 4: Bug 9 — `#csource` Path Resolution

**What goes wrong:** The `vma_impl.cpp` is at `../../src/TamgaVMA/vma_impl.cpp` relative to the generated cache dir. Relative paths in `addCSourceFiles` must be correct relative to the build root.

**How to avoid:** Use the same path-resolution approach as `addObjectFile` in the existing manual patch: `{ .cwd_relative = "../../src/TamgaVMA/vma_impl.cpp" }`. Or use `b.path(...)` if building from the project root.

---

## Code Examples

### Correct Zig for `?(union(enum) {...})` return

```zig
// Source: Zig 0.15 union + optional semantics
// For pollEvent returning ?(union(enum) { _NoEvent: NoEvent, _QuitEvent: QuitEvent, ... })

// Return a specific variant:
return .{ ._QuitEvent = .{ .timestamp = ts } };

// Return null (no event):
return null;

// NOT: return .{ ._null = null };  -- invalid
```

### Correct Zig for `pub export fn` in sidecar

```zig
// Source: tamga_vma.zig — correct form after fix
pub export fn vma_create(
    instance: *anyopaque,
    physical_device: *anyopaque,
    device: *anyopaque,
    out_ctx: **VmaContext,
) c.VkResult { ... }
```

### Correct Zig for `addCSourceFiles` in build.zig

```zig
// Source: Zig 0.15 Build API
lib_tamga_vma.root_module.addCSourceFiles(.{
    .files = &.{"../../src/TamgaVMA/vma_impl.cpp"},
    .flags = &.{"-std=c++17"},
});
lib_tamga_vma.linkLibCpp();
```

### Shared `@cImport` pattern for cross-module type identity

```zig
// vulkan_c.zig (generated by compiler):
pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});
// Re-export types so sidecars use: const c = @import("vulkan_c");
pub usingnamespace c;

// In tamga_vma.zig and tamga_vk3d.zig after fix:
const c = @import("vulkan_c");
// Now c.VkBuffer is the same type in both modules
```

### Empty struct initialization in generated Zig

```zig
// Before fix (wrong):
return NoEvent();

// After fix (correct):
return NoEvent{};
```

---

## Workaround Removal Map

| Workaround | File | Bug | After Fix |
|-----------|------|-----|-----------|
| `NoEvent` sentinel struct + `pub empty: bool` field | `tamga_sdl3.orh` | Bugs 1 + 3 | Replace with `(null | QuitEvent | ...)` union; use `null` check |
| `scancode: u32` / `button: u8` raw integer fields | `tamga_sdl3.orh` | Bug 2 | Change to `scancode: Scancode` / `button: MouseButton` |
| `byte_size`/`byte_count` param names | `tamga_vma.orh` | Bug 5 | Rename back to `size` |
| `mesh: Mesh` by-value in `draw`/`destroyMesh` | `tamga_vk3d.orh` | Bug 6 | Change to `mesh: const &Mesh` |
| `export fn` without `pub` | `tamga_vma.zig` | Bug 7 | Add `pub` to all 5 export fn declarations |
| Manual `@ptrCast` at Vulkan type boundaries | `tamga_vk3d.zig` | Bug 8 | Remove after shared vulkan_c module |
| Manual `build.zig` patch for `vma_impl.o` / `linkLibCpp` | `build.zig` (generated) | Bug 9 | Add `#csource "vma_impl.cpp"` to `tamga_vma.orh` |
| `kd.scancode == 41` raw integer comparison | `test_sdl3.orh`, `test_vulkan.orh` | Bug 2 | Use `kd.scancode == tamga_sdl3.Scancode.Escape` |

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Zig 0.15.2+ | Compiler backend | Verify at runtime | — | None — blocking |
| SDL3 | Tamga SDL3 module | System lib | — | Cannot test SDL3 code path |
| Vulkan | Tamga VK3D + VMA | System lib | — | Cannot test Vulkan code path |

**Note:** Full Tamga build requires SDL3 and Vulkan. These are runtime system libraries; their presence is not checked by `./testall.sh`. The verification step (D-02) requires these libraries to be installed on the build machine.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell integration tests |
| Config file | None — `zig build test` discovers test blocks |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| REQ-20 | Bug 1: multi-type null union type string | unit | `zig build test` (codegen unit tests) | New test needed |
| REQ-20 | Bug 2: cast(Enum, int) → @enumFromInt | unit | `zig build test` | New test needed |
| REQ-20 | Bug 3: empty struct TypeName() → TypeName{} | unit | `zig build test` | New test needed |
| REQ-20 | Bug 4: lib-to-lib addImport (ALREADY FIXED) | unit | `zig build test` | Exists (added in debug session) |
| REQ-20 | Bug 5: size keyword in bridge params | integration | `bash test/05_compile.sh` | Via fixture if needed |
| REQ-20 | Bug 6: const &BridgeStruct coercion | unit | `zig build test` | New test needed |
| REQ-20 | Bug 7: export fn → pub export fn | manual | Tamga build | N/A |
| REQ-20 | Bug 8: shared @cImport module generation | integration | Tamga build | N/A |
| REQ-20 | Bug 9: #csource emission in build.zig | unit | `zig build test` | New test needed |
| REQ-20 | No regressions | full suite | `./testall.sh` | Exists |
| REQ-20 | Tamga end-to-end build | e2e | `cd tamga; orhon build` | N/A — manual |

### Sampling Rate

- **Per task commit:** `zig build test` (unit tests only, fast)
- **Per wave merge:** `./testall.sh` (full suite, ~2min)
- **Phase gate:** Full suite green + Tamga builds end-to-end before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] Unit tests for Bug 1 (multi-null union typeToZig + return coercion)
- [ ] Unit tests for Bug 2 (isEnumTypeName with enum decls present)
- [ ] Unit tests for Bug 3 (zero-field struct call_expr detection)
- [ ] Unit tests for Bug 6 (bridge struct const & coercion via field_expr)
- [ ] Unit tests for Bug 9 (buildZigContent with csource metadata)

---

## Project Constraints (from CLAUDE.md)

- **Zig 0.15.2+** — all fixes must use current Zig APIs. `addCSourceFiles` signature is Zig 0.15 form.
- **No hacky workarounds** — clean fixes only. No post-processing sidecar files with regex.
- **`./testall.sh` is the gate** — all 11 stages must pass after fixes.
- **PEG grammar is source of truth** — for Bug 9/5, update `orhon.peg` first, then builder.
- **Reporter owns message strings** — `defer allocator.free(msg)` pattern in any new error paths.
- **Recursive functions need `anyerror!`** — any new recursive codegen helpers must use this.
- **No orphan files** — any new generated files (e.g., `vulkan_c.zig`) must be created in the cache dir and cleaned up properly.
- **Keep example module up to date** — if any new language feature lands (e.g., `#csource`), it doesn't need example coverage (build directives are module metadata, not language syntax).

---

## Open Questions

1. **Is Bug 1 actually incomplete?**
   - What we know: `typeToZig` already generates `?(union(enum) {...})` for multi-type null unions (code at lines 3934-3951)
   - What's unclear: Whether the return-value codegen (wrapping a variant into the nullable union) is correct. The workaround uses `NoEvent` so the null path was never exercised post-fix.
   - Recommendation: Create a minimal test fixture with `func f() (null | A | B)` and verify the generated Zig compiles.

2. **Is Bug 4 fully closed or does the cross-bridge import conflict remain?**
   - What we know: Debug session fixed the specific "root and tamga_sdl3" conflict. The cached `build.zig` looks correct. Debug session noted a separate cross-bridge issue.
   - What's unclear: Whether running `orhon build` fresh in the Tamga directory triggers the second conflict ("tamga_vma and root" for tamga_vk3d_bridge.zig).
   - Recommendation: First task of the phase: run `orhon build` in Tamga and observe which errors remain.

3. **Is Bug 5 fully closed?**
   - What we know: `param_name` in `orhon.peg` includes `'size'`.
   - What's unclear: Whether this was added before or after the Tamga bug was filed. May already be fixed.
   - Recommendation: First task: try `bridge func f(size: u64)` in a test fixture. If it parses, close the bug.

4. **Bug 8 scope — sidecar modification required?**
   - What we know: The shared `@cImport` fix requires sidecars to use `@import("vulkan_c")` instead of their own `@cImport`. This is a Tamga sidecar change, not just a compiler change.
   - What's unclear: Whether the compiler should auto-generate a `vulkan_c.zig` file and inject its path into sidecar modules, or whether this is a manual Tamga convention change.
   - Recommendation: Treat Bug 8 as two sub-tasks: (a) compiler generates shared cImport module and wires it via `addImport`, (b) Tamga sidecars updated to use it.

---

## Sources

### Primary (HIGH confidence)
- `src/codegen.zig` — direct source inspection of `typeToZig`, `isEnumTypeName`, `generateBridgeReExport`, cast codegen paths
- `src/mir.zig` — direct inspection of `annotateCallCoercions`, const auto-borrow exclusion comment
- `src/orhon.peg` — direct inspection of `param_name` rule
- `src/zig_runner.zig` — direct inspection of `buildZigContentMulti`, `#linkC` handling
- `/home/yunus/Projects/orhon/tamga_framework/docs/bugs.md` — authoritative bug documentation
- `.planning/debug/tamga-compiler-bugs.md` — confirmed Bug 4 fix + second conflict status
- `/home/yunus/Projects/orhon/tamga_framework/.orh-cache/generated/build.zig` — actual generated output post-fix

### Secondary (MEDIUM confidence)
- Tamga source files (`tamga_sdl3.orh`, `tamga_vma.orh`, `tamga_vk3d.orh`, `main.orh`) — workaround patterns confirmed by reading source
- Tamga sidecar files (`tamga_vma.zig`, `tamga_vk3d.zig`, `tamga_sdl3.zig`) — export fn patterns confirmed

---

## Metadata

**Confidence breakdown:**
- Bug analysis: HIGH — based on direct source code inspection
- Fix locations: HIGH — exact file + line confirmed for most bugs
- Fix complexity: MEDIUM — some bugs (1, 6, 8) have subtle edge cases not fully explored
- Workaround removal: HIGH — all workarounds identified from Tamga source

**Research date:** 2026-03-27
**Valid until:** This phase — bugs and workarounds are static facts about current source
