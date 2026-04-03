# Pointer Removal + std::ptr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Ptr/RawPtr/VolatilePtr from compiler builtins and @deref from compiler functions, provide the same functionality as pure Zig structs in std::ptr.

**Architecture:** Pure removal from compiler (builtins, types, codegen, MIR, resolver, LSP, cache) + addition of src/std/ptr.zig embedded via std_bundle.zig. The borrow system is unchanged. CoreType keeps only .handle.

**Tech Stack:** Zig 0.15.2+, Orhon compiler pipeline, shell test scripts.

---

### Task 1: Remove pointer types from builtins.zig

**Files:**
- Modify: `src/builtins.zig:8-33` (BUILTIN_TYPES, BT constants, isPtrType)
- Modify: `src/builtins.zig:56` (@deref in COMPILER_FUNCS)
- Modify: `src/builtins.zig:80` (deref in CompilerFunc enum)
- Modify: `src/builtins.zig:102` (deref in fromName map)
- Modify: `src/builtins.zig:191-201` (unit tests)

- [ ] **Step 1: Remove Ptr/RawPtr/VolatilePtr from BUILTIN_TYPES**

In `src/builtins.zig`, change the BUILTIN_TYPES array from:

```zig
pub const BUILTIN_TYPES = [_][]const u8{
    "Ptr",
    "RawPtr",
    "VolatilePtr",
    "Handle",
    "Error",
    "Vector",
};
```

to:

```zig
pub const BUILTIN_TYPES = [_][]const u8{
    "Handle",
    "Error",
    "Vector",
};
```

- [ ] **Step 2: Remove pointer BT constants and isPtrType**

Remove these from the BT struct:

```zig
    pub const PTR = "Ptr";
    pub const RAW_PTR = "RawPtr";
    pub const VOLATILE_PTR = "VolatilePtr";
```

Delete the entire `isPtrType()` function (lines 28-33):

```zig
/// Returns true if name is a pointer wrapper type (Ptr, RawPtr, or VolatilePtr).
pub fn isPtrType(name: []const u8) bool {
    return std.mem.eql(u8, name, BT.PTR) or
        std.mem.eql(u8, name, BT.RAW_PTR) or
        std.mem.eql(u8, name, BT.VOLATILE_PTR);
}
```

- [ ] **Step 3: Remove @deref from compiler functions**

Remove `"deref"` from the `COMPILER_FUNCS` array (line 56).

Remove `deref` from the `CompilerFunc` enum (line 80).

Remove `deref` from the `fromName` static map entry (line 102):
```zig
            .{ "deref", .deref },
```

- [ ] **Step 4: Update unit tests**

In the `test "builtin type detection"` block, remove:
```zig
    try std.testing.expect(isBuiltinType("Ptr"));
```

(Keep tests for Error, Vector, etc.)

- [ ] **Step 5: Run unit tests**

Run: `zig build test 2>&1 | head -50`
Expected: Compilation errors in other files that reference removed symbols. That's expected — we fix those next.

- [ ] **Step 6: Commit**

```bash
git add src/builtins.zig
git commit -m "refactor: remove Ptr/RawPtr/VolatilePtr and @deref from builtins"
```

---

### Task 2: Remove pointer variants from types.zig

**Files:**
- Modify: `src/types.zig:199-209` (CoreType.Kind enum)
- Modify: `src/types.zig:257-263` (isCoreType helper)
- Modify: `src/types.zig:265-271` (coreInner helper)
- Modify: `src/types.zig:287-292` (name() method)
- Modify: `src/types.zig:350-367` (resolveTypeNode)
- Modify: `src/types.zig:506-508` (unit test)

- [ ] **Step 1: Remove pointer variants from CoreType.Kind**

In `src/types.zig`, change CoreType.Kind from:

```zig
        pub const Kind = enum {
            handle, // Handle(T) → _OrhonHandle(T)
            safe_ptr, // Ptr(T) → *T
            raw_ptr, // RawPtr(T) → [*]T
            volatile_ptr, // VolatilePtr(T) → *volatile T
        };
```

to:

```zig
        pub const Kind = enum {
            handle, // Handle(T) → _OrhonHandle(T)
        };
```

- [ ] **Step 2: Update name() method**

Change the `.core_type` branch in `name()` (around line 287) from:

```zig
            .core_type => |ct| switch (ct.kind) {
                .handle => "Handle(T)",
                .safe_ptr => "Ptr(T)",
                .raw_ptr => "RawPtr(T)",
                .volatile_ptr => "VolatilePtr(T)",
            },
```

to:

```zig
            .core_type => |ct| switch (ct.kind) {
                .handle => "Handle(T)",
            },
```

- [ ] **Step 3: Update resolveTypeNode()**

In `resolveTypeNode()` (around line 350), change the core_kind detection from:

```zig
    const core_kind: ?ResolvedType.CoreType.Kind = if (std.mem.eql(u8, g.name, builtins.BT.HANDLE))
        .handle
    else if (std.mem.eql(u8, g.name, builtins.BT.PTR))
        .safe_ptr
    else if (std.mem.eql(u8, g.name, builtins.BT.RAW_PTR))
        .raw_ptr
    else if (std.mem.eql(u8, g.name, builtins.BT.VOLATILE_PTR))
        .volatile_ptr
    else
        null;
```

to:

```zig
    const core_kind: ?ResolvedType.CoreType.Kind = if (std.mem.eql(u8, g.name, builtins.BT.HANDLE))
        .handle
    else
        null;
```

- [ ] **Step 4: Update unit test**

In the test block around line 506-508, remove the pointer-specific assertion:

```zig
    try std.testing.expect(!handle.isCoreType(.safe_ptr));
```

The `isCoreType` and `coreInner` helper methods still work — they only reference `.core_type` which still exists for Handle. No changes needed there.

- [ ] **Step 5: Commit**

```bash
git add src/types.zig
git commit -m "refactor: remove pointer variants from CoreType — only Handle remains"
```

---

### Task 3: Remove pointer codegen from codegen.zig

**Files:**
- Modify: `src/codegen/codegen.zig:30` (warned_rawptr field)
- Modify: `src/codegen/codegen.zig:153` (warned_rawptr init)
- Modify: `src/codegen/codegen.zig:494` (generatePtrCoercionMir delegation)
- Modify: `src/codegen/codegen.zig:618-635` (typeToZig pointer branches)
- Modify: `src/codegen/codegen.zig:754-763` (PtrCoercionInfo, getPtrCoercionTarget)

- [ ] **Step 1: Remove warned_rawptr field**

In `src/codegen/codegen.zig`, remove the field declaration (line 30):

```zig
    warned_rawptr: bool,     // RawPtr/VolatilePtr warning printed once per module
```

And its initialization (line 153):

```zig
            .warned_rawptr = false,
```

- [ ] **Step 2: Remove typeToZig pointer branches**

Remove these three `else if` branches from `typeToZig()` (lines 618-635):

```zig
                } else if (std.mem.eql(u8, g.name, builtins.BT.PTR)) {
                    // Ptr(T) → *const T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("*const {s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.RAW_PTR)) {
                    // RawPtr(T) → [*]T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]{s}", .{inner});
                    }
                } else if (std.mem.eql(u8, g.name, builtins.BT.VOLATILE_PTR)) {
                    // VolatilePtr(T) → [*]volatile T
                    if (g.args.len > 0) {
                        const inner = try self.typeToZig(g.args[0]);
                        break :blk try self.allocTypeStr("[*]volatile {s}", .{inner});
                    }
```

Keep the Handle and Vector branches — they stay.

- [ ] **Step 3: Remove generatePtrCoercionMir delegation**

Remove the delegation method (line 494):

```zig
    pub fn generatePtrCoercionMir(self: *CodeGen, kind: []const u8, type_node: *parser.Node, val_m: *mir.MirNode) anyerror!void { return match_impl.generatePtrCoercionMir(self, kind, type_node, val_m); }
```

- [ ] **Step 4: Remove PtrCoercionInfo and getPtrCoercionTarget**

Remove lines 754-763:

```zig
/// Check if a type annotation is a pointer wrapper type (Ptr/RawPtr/VolatilePtr) with an inner type.
/// Returns the wrapper name and inner type arg, or null if not a pointer coercion target.
pub const PtrCoercionInfo = struct { name: []const u8, inner_type: *parser.Node };
pub fn getPtrCoercionTarget(type_annotation: ?*parser.Node) ?PtrCoercionInfo {
    const t = type_annotation orelse return null;
    if (t.* != .type_generic) return null;
    if (t.type_generic.args.len == 0) return null;
    if (!builtins.isPtrType(t.type_generic.name)) return null;
    return .{ .name = t.type_generic.name, .inner_type = t.type_generic.args[0] };
}
```

- [ ] **Step 5: Commit**

```bash
git add src/codegen/codegen.zig
git commit -m "refactor: remove pointer codegen from codegen.zig"
```

---

### Task 4: Remove pointer codegen from satellite files

**Files:**
- Modify: `src/codegen/codegen_match.zig:519-561` (generatePtrCoercionMir)
- Modify: `src/codegen/codegen_match.zig:730-740` (@deref handler)
- Modify: `src/codegen/codegen_decls.zig:455-459` (pointer coercion call site)
- Modify: `src/codegen/codegen_stmts.zig:236-241` (pointer coercion call site)

- [ ] **Step 1: Remove generatePtrCoercionMir from codegen_match.zig**

Delete the entire function (lines 519-561) from `src/codegen/codegen_match.zig`:

```zig
/// Type-directed pointer coercion for the MIR path.
/// Called from generateTopLevelDeclMir and generateStmtDeclMir when type annotation is Ptr/RawPtr/VolatilePtr.
/// type_node is the first type argument (e.g. i32 from Ptr(i32)); val_m is the value MIR node.
pub fn generatePtrCoercionMir(cg: *CodeGen, kind: []const u8, type_node: *parser.Node, val_m: *mir.MirNode) anyerror!void {
    // ... entire function body ...
}
```

- [ ] **Step 2: Remove @deref handler from generateCompilerFuncMir**

In `src/codegen/codegen_match.zig`, remove the `.deref` arm from the switch in `generateCompilerFuncMir` (lines 730-740):

```zig
        .deref => {
            // @deref(ptr) → ptr.* (Ptr) or ptr[0] (RawPtr)
            if (args.len > 0) {
                try cg.generateExprMir(args[0]);
                if (args[0].type_class == .raw_ptr) {
                    try cg.emit("[0]");
                } else {
                    try cg.emit(".*");
                }
            }
        },
```

- [ ] **Step 3: Remove pointer coercion from codegen_decls.zig**

In `src/codegen/codegen_decls.zig`, replace lines 454-460:

```zig
        // Native ?T and anyerror!T — Zig handles coercion, no wrapping needed
        if (codegen.getPtrCoercionTarget(m.type_annotation)) |ptr| {
            try cg.generatePtrCoercionMir(ptr.name, ptr.inner_type, m.value());
        } else {
            try cg.generateExprMir(m.value());
        }
```

with:

```zig
        try cg.generateExprMir(m.value());
```

- [ ] **Step 4: Remove pointer coercion from codegen_stmts.zig**

In `src/codegen/codegen_stmts.zig`, replace lines 236-241:

```zig
        if (codegen.getPtrCoercionTarget(m.type_annotation)) |ptr| {
            try cg.generatePtrCoercionMir(ptr.name, ptr.inner_type, val_m);
        } else {
            try cg.generateExprMir(val_m);
        }
```

with:

```zig
        try cg.generateExprMir(val_m);
```

Keep the surrounding `type_ctx` save/restore logic in codegen_stmts.zig — that serves other purposes.

- [ ] **Step 5: Commit**

```bash
git add src/codegen/codegen_match.zig src/codegen/codegen_decls.zig src/codegen/codegen_stmts.zig
git commit -m "refactor: remove pointer coercion and @deref from codegen satellites"
```

---

### Task 5: Remove pointer types from MIR, resolver, LSP, cache

**Files:**
- Modify: `src/mir/mir_types.zig:20-21` (TypeClass enum)
- Modify: `src/mir/mir_types.zig:36-46` (classifyType pointer branches)
- Modify: `src/mir/mir_types.zig:101-111` (pointer test block)
- Modify: `src/mir/mir_annotator.zig:194` (core_type comparison)
- Modify: `src/resolver.zig:475-483` (typesMatchWithSubstitution core_type branch)
- Modify: `src/resolver.zig:537-548` (typesCompatible core_type checks)
- Modify: `src/resolver.zig:573-580` (coreTypeName function)
- Modify: `src/lsp/lsp_analysis.zig:56-66` (formatType core_type branch)
- Modify: `src/cache.zig:571-575` (hashResolvedType core_type branch)

- [ ] **Step 1: Update MIR TypeClass enum**

In `src/mir/mir_types.zig`, remove `.raw_ptr` and `.safe_ptr` from the TypeClass enum:

```zig
pub const TypeClass = enum {
    plain,
    error_union,
    null_union,
    arbitrary_union,
    string,
    thread_handle,
};
```

- [ ] **Step 2: Update classifyType() in mir_types.zig**

Remove the pointer classification branches. In the `.generic` arm, change from:

```zig
        .generic => |g| {
            if (std.mem.eql(u8, g.name, builtins.BT.RAW_PTR) or std.mem.eql(u8, g.name, builtins.BT.VOLATILE_PTR))
                return .raw_ptr;
            if (std.mem.eql(u8, g.name, builtins.BT.PTR))
                return .safe_ptr;
            if (std.mem.eql(u8, g.name, builtins.BT.HANDLE))
                return .thread_handle;
            return .plain;
        },
```

to:

```zig
        .generic => |g| {
            if (std.mem.eql(u8, g.name, builtins.BT.HANDLE))
                return .thread_handle;
            return .plain;
        },
```

In the `.core_type` arm, change from:

```zig
        .core_type => |ct| switch (ct.kind) {
            .raw_ptr, .volatile_ptr => .raw_ptr,
            .safe_ptr => .safe_ptr,
            .handle => .thread_handle,
        },
```

to:

```zig
        .core_type => |ct| switch (ct.kind) {
            .handle => .thread_handle,
        },
```

- [ ] **Step 3: Update pointer test block in mir_types.zig**

Change the test from:

```zig
test "classifyType - pointers and named" {
    try std.testing.expectEqual(TypeClass.raw_ptr, classifyType(RT{ .generic = .{
        .name = "RawPtr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.safe_ptr, classifyType(RT{ .generic = .{
        .name = "Ptr",
        .args = &.{},
    } }));
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .named = "MyStruct" }));
}
```

to:

```zig
test "classifyType - named types" {
    try std.testing.expectEqual(TypeClass.plain, classifyType(RT{ .named = "MyStruct" }));
}
```

- [ ] **Step 4: Update mir_annotator.zig**

The `.core_type` comparison at line 194 stays as-is — it handles Handle too:

```zig
        if (a == .core_type and b == .core_type) return a.core_type.kind == b.core_type.kind;
```

No change needed.

- [ ] **Step 5: Update resolver.zig coreTypeName()**

Change `coreTypeName()` from:

```zig
pub fn coreTypeName(kind: types.ResolvedType.CoreType.Kind) []const u8 {
    return switch (kind) {
        .handle => "Handle",
        .safe_ptr => "Ptr",
        .raw_ptr => "RawPtr",
        .volatile_ptr => "VolatilePtr",
    };
}
```

to:

```zig
pub fn coreTypeName(kind: types.ResolvedType.CoreType.Kind) []const u8 {
    return switch (kind) {
        .handle => "Handle",
    };
}
```

The `typesCompatible` core_type checks (lines 537-548) and `typesMatchWithSubstitution` core_type branch (lines 475-483) stay as-is — they handle CoreType generically and still work for Handle.

- [ ] **Step 6: Update lsp_analysis.zig formatType()**

Change the `.core_type` branch from:

```zig
        .core_type => |ct| blk: {
            const inner_s = try formatType(allocator, ct.inner.*);
            defer allocator.free(inner_s);
            const wrapper = switch (ct.kind) {
                .handle => "Handle",
                .safe_ptr => "Ptr",
                .raw_ptr => "RawPtr",
                .volatile_ptr => "VolatilePtr",
            };
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ wrapper, inner_s });
        },
```

to:

```zig
        .core_type => |ct| blk: {
            const inner_s = try formatType(allocator, ct.inner.*);
            defer allocator.free(inner_s);
            const wrapper = switch (ct.kind) {
                .handle => "Handle",
            };
            break :blk std.fmt.allocPrint(allocator, "{s}({s})", .{ wrapper, inner_s });
        },
```

- [ ] **Step 7: Verify cache.zig**

The `hashResolvedType` function in `src/cache.zig:571-575` handles `.core_type` generically — it hashes the kind enum value and inner type. No change needed since it doesn't reference specific Kind variants.

- [ ] **Step 8: Compile and run unit tests**

Run: `zig build test 2>&1 | head -50`
Expected: PASS — all pointer references should be gone from the compiler.

- [ ] **Step 9: Commit**

```bash
git add src/mir/mir_types.zig src/resolver.zig src/lsp/lsp_analysis.zig
git commit -m "refactor: remove pointer types from MIR, resolver, and LSP"
```

---

### Task 6: Create std::ptr module

**Files:**
- Create: `src/std/ptr.zig`
- Modify: `src/std_bundle.zig:37` (add embed)
- Modify: `src/std_bundle.zig:87` (add to files array)

- [ ] **Step 1: Create src/std/ptr.zig**

Create the file `src/std/ptr.zig`:

```zig
// ptr.zig — Pointer wrapper types for Orhon std::ptr
//
// Ptr(T)         — safe single-value pointer, from borrows only
// RawPtr(T)      — unsafe indexable pointer, borrows or integer addresses
// VolatilePtr(T) — unsafe volatile pointer, hardware registers

const std = @import("std");

/// Safe single-value pointer. Wraps a Zig pointer obtained from a borrow.
/// Cannot be constructed from a raw integer address.
pub fn Ptr(comptime T: type) type {
    return struct {
        raw: *T,

        const Self = @This();

        /// Create a safe pointer from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = ref };
        }

        /// Read the pointed-to value.
        pub fn read(self: Self) T {
            return self.raw.*;
        }

        /// Write a value through the pointer.
        pub fn write(self: Self, val: T) void {
            self.raw.* = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}

/// Unsafe indexable pointer. Supports offset-based access and construction
/// from raw integer addresses. For FFI, C interop, and array-style access.
pub fn RawPtr(comptime T: type) type {
    return struct {
        raw: [*]T,

        const Self = @This();

        /// Create from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = @as([*]T, @ptrCast(ref)) };
        }

        /// Create from a raw integer address.
        pub fn fromAddress(addr: usize) Self {
            return .{ .raw = @as([*]T, @ptrFromInt(addr)) };
        }

        /// Read the value at offset n.
        pub fn at(self: Self, n: usize) T {
            return self.raw[n];
        }

        /// Write a value at offset n.
        pub fn set(self: Self, n: usize, val: T) void {
            self.raw[n] = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}

/// Unsafe volatile pointer. Every read and write is volatile — the compiler
/// never caches or reorders accesses. For memory-mapped hardware registers.
pub fn VolatilePtr(comptime T: type) type {
    return struct {
        raw: *volatile T,

        const Self = @This();

        /// Create from a borrow (mut& or const&).
        pub fn new(ref: *T) Self {
            return .{ .raw = @as(*volatile T, @ptrCast(ref)) };
        }

        /// Create from a raw integer address.
        pub fn fromAddress(addr: usize) Self {
            return .{ .raw = @as(*volatile T, @ptrFromInt(addr)) };
        }

        /// Volatile read.
        pub fn read(self: Self) T {
            return self.raw.*;
        }

        /// Volatile write.
        pub fn write(self: Self, val: T) void {
            self.raw.* = val;
        }

        /// Get the raw memory address as usize.
        pub fn address(self: Self) usize {
            return @intFromPtr(self.raw);
        }
    };
}
```

- [ ] **Step 2: Add ptr.zig to std_bundle.zig**

In `src/std_bundle.zig`, add the embed constant after the LINEAR_ORH line (line 37):

```zig
const PTR_ZIG      = @embedFile("std/ptr.zig");
```

Add the file entry to the `files` array in `ensureStdFiles()`, before the closing `};` of the array (after the linear.orh entry around line 87):

```zig
        .{ .name = "ptr.zig",        .content = PTR_ZIG },
```

- [ ] **Step 3: Build the compiler**

Run: `zig build 2>&1 | head -20`
Expected: PASS — compiler builds with ptr.zig embedded.

- [ ] **Step 4: Commit**

```bash
git add src/std/ptr.zig src/std_bundle.zig
git commit -m "feat: add std::ptr module — Ptr, RawPtr, VolatilePtr as Zig structs"
```

---

### Task 7: Update tests

**Files:**
- Modify: `test/fixtures/tester.orh:694-715` (remove pointer test functions)
- Delete: `test/fixtures/fail_ptr_cast.orh`
- Modify: `test/10_runtime.sh:39` (remove raw_ptr safe_ptr from test list)
- Modify: `test/11_errors.sh:429-440` (remove ptr_cast error test)

- [ ] **Step 1: Remove pointer test functions from tester.orh**

In `test/fixtures/tester.orh`, delete lines 694-715 (the `raw_ptr_read`, `raw_ptr_index`, `safe_ptr_read` functions and the `test "safe ptr"` block):

```orh
pub func raw_ptr_read() i32 {
    var x: i32 = 99
    const raw: RawPtr(i32) = mut& x
    x = raw[0]
    return x
}

pub func raw_ptr_index() i32 {
    const arr: [3]i32 = [1, 2, 3]
    const raw: RawPtr(i32) = mut& arr
    return raw[1]
}

pub func safe_ptr_read() i32 {
    const x: i32 = 77
    const p: Ptr(i32) = mut& x
    return @deref(p)
}

test "safe ptr" {
    @assert(safe_ptr_read() == 77)
}
```

- [ ] **Step 2: Delete fail_ptr_cast.orh**

```bash
rm test/fixtures/fail_ptr_cast.orh
```

- [ ] **Step 3: Remove pointer tests from 10_runtime.sh**

In `test/10_runtime.sh`, on line 39, change:

```bash
    fixed_array array_index slice_expr raw_ptr safe_ptr typeid_same \
```

to:

```bash
    fixed_array array_index slice_expr typeid_same \
```

- [ ] **Step 4: Remove ptr_cast error test from 11_errors.sh**

In `test/11_errors.sh`, delete lines 429-440 (the entire "old ptr syntax rejected" block):

```bash
# old ptr syntax rejected
cd "$TESTDIR"
mkdir -p neg_ptr_cast/src
cp "$FIXTURES/fail_ptr_cast.orh" neg_ptr_cast/src/neg_ptr_cast.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_ptr_cast/' neg_ptr_cast/src/neg_ptr_cast.orh
cd neg_ptr_cast
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "error\|parse\|unexpected"; then
    pass "rejects old Ptr(T).cast() syntax"
else
    fail "rejects old Ptr(T).cast() syntax" "$NEG_OUT"
fi
```

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/tester.orh test/10_runtime.sh test/11_errors.sh
git rm test/fixtures/fail_ptr_cast.orh
git commit -m "test: remove old pointer builtin tests"
```

---

### Task 8: Update example module and docs

**Files:**
- Modify: `src/templates/example/data_types.orh:81-102` (pointer examples)
- Modify: `docs/09-memory.md:100-162` (Pointers section)
- Modify: `docs/TODO.md:25-51` (pointer redesign item)

- [ ] **Step 1: Update example module**

In `src/templates/example/data_types.orh`, replace the pointer section (lines 81-102) with:

```orh
// ─── Pointers ───────────────────────────────────────────────────────────

// Pointers are provided by std::ptr — not a language builtin.
// Use borrows (const& / mut&) for safe reference passing.
// Use std::ptr when you need explicit pointer control.
//
// import std::ptr
//
// var x: i32 = 10
// var p: ptr.Ptr(i32) = ptr.Ptr(i32).new(mut& x)
// const val: i32 = p.read()
// p.write(42)
```

- [ ] **Step 2: Update docs/09-memory.md**

Replace the Pointers section (lines 100-162) with:

```markdown
## Pointers

Orhon does not have pointer types as language builtins. The borrow system (`const&` / `mut&`) handles safe reference passing — this covers the vast majority of use cases.

For explicit pointer control (FFI, hardware access, pointer arithmetic), use `std::ptr`:

```
import std::ptr

var x: i32 = 10
var p: ptr.Ptr(i32) = ptr.Ptr(i32).new(mut& x)
const val: i32 = p.read()
p.write(42)
```

See [[std-ptr]] for full API documentation.

### Pointer Rules
- Use borrows (`const&` / `mut&`) for passing references — this is the normal path
- Use `std::ptr` only when you need to hold an address explicitly
- `Ptr(T)` — safe single-value pointer, constructed from borrows only
- `RawPtr(T)` — unsafe, indexable, allows integer addresses (FFI/hardware)
- `VolatilePtr(T)` — unsafe, volatile reads/writes (hardware registers)
- Self-referential structures use array indices instead of pointers — faster and safer
```

- [ ] **Step 3: Update docs/TODO.md**

Remove the pointer redesign section (lines 25-51, from `### Pointer redesign` through `- **Blocked on:** implementation planning`).

Add a brief completed note in its place or at the top of the file:

```markdown
### ~~Pointer redesign~~ — done (v0.17.0)
Ptr/RawPtr/VolatilePtr moved from compiler builtins to `std::ptr`. @deref removed.
```

- [ ] **Step 4: Commit**

```bash
git add src/templates/example/data_types.orh docs/09-memory.md docs/TODO.md
git commit -m "docs: update pointer documentation — builtins → std::ptr"
```

---

### Task 9: Clear cache and run full test suite

**Files:** None (verification only)

- [ ] **Step 1: Clear the build cache**

The old cache may have stale generated files with pointer types:

```bash
rm -rf .orh-cache
```

- [ ] **Step 2: Build the compiler**

```bash
zig build 2>&1 | head -20
```

Expected: Clean build, no errors.

- [ ] **Step 3: Run the full test suite**

```bash
./testall.sh
```

Expected: All tests pass. The removed pointer tests should no longer appear. New std::ptr module should be available via `import std::ptr`.

- [ ] **Step 4: Fix any failures**

If any tests fail, read the output carefully. Common issues:
- Stale references to `isPtrType`, `BT.PTR`, `getPtrCoercionTarget` — grep and remove
- MIR type_class `.raw_ptr`/`.safe_ptr` referenced somewhere — change to `.plain`
- Test expectations for pointer functions still present — remove from test lists

- [ ] **Step 5: Final commit if fixes were needed**

```bash
git add -A
git commit -m "fix: resolve remaining pointer removal issues"
```
