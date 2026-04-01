# ScopeBase(V) — Generic Scope Extraction

**Date:** 2026-04-01
**Status:** Design
**Scope:** Medium — cross-cutting but mechanical

---

## Problem

Three files implement nearly identical scope structs with `StringHashMap(V)` +
`?*Self` parent + `allocator` + init/deinit/lookup/define + parent-chain recursion:

| File | Scope Type | Value Type | Extra Methods |
|------|-----------|------------|---------------|
| `resolver.zig` | `Scope` | `ResolvedType` | — |
| `ownership.zig` | `OwnershipScope` | `VarState` | `defineTyped`, `setState` |
| `propagation.zig` | `PropagationScope` | `UnionVar` | `markHandled`, `isTracked`, `resetHandled` |

`PropagationScope` also carries `func_returns_error: bool` per scope frame.

## Design

### New file: `src/scope.zig`

Generic `ScopeBase(comptime V: type)` providing:

- `vars: StringHashMap(V)`, `parent: ?*Self`, `allocator: Allocator`
- `init(allocator, parent) -> Self`
- `deinit(self) -> void`
- `lookup(self, name) -> ?V` — immutable parent-chain walk
- `lookupPtr(self, name) -> ?*V` — mutable parent-chain walk
- `define(self, name, v) -> !void` — put into current scope

### Changes per file

**resolver.zig:**
`Scope` becomes a direct alias: `pub const Scope = ScopeBase(RT);`
No wrapper needed — `define(name, v)` and `lookup(name)` match the generic API exactly.

**ownership.zig:**
`OwnershipScope` wraps `ScopeBase(VarState)`:

```zig
pub const OwnershipScope = struct {
    base: ScopeBase(VarState),

    pub fn init(allocator: Allocator, parent: ?*OwnershipScope) OwnershipScope {
        return .{ .base = ScopeBase(VarState).init(
            allocator,
            if (parent) |p| &p.base else null,
        ) };
    }
    pub fn deinit(self: *OwnershipScope) void { self.base.deinit(); }
    pub fn define(self: *OwnershipScope, name: []const u8, is_primitive: bool) !void {
        try self.base.define(name, .{ .name = name, .state = .owned, .is_primitive = is_primitive, .is_const = false, .type_name = "" });
    }
    pub fn defineTyped(self: *OwnershipScope, name: []const u8, is_primitive: bool, type_name: []const u8, is_const: bool) !void {
        try self.base.define(name, .{ .name = name, .state = .owned, .is_primitive = is_primitive, .is_const = is_const, .type_name = type_name });
    }
    pub fn getState(self: *const OwnershipScope, name: []const u8) ?VarState {
        return self.base.lookup(name);
    }
    pub fn setState(self: *OwnershipScope, name: []const u8, state: types.OwnershipState) bool {
        if (self.base.lookupPtr(name)) |v| { v.state = state; return true; }
        return false;
    }
};
```

**propagation.zig:**
`PropagationScope` wraps `ScopeBase(UnionVar)` + extra `func_returns_error` field:

```zig
pub const PropagationScope = struct {
    base: ScopeBase(UnionVar),
    func_returns_error: bool,

    pub fn init(allocator: Allocator, parent: ?*PropagationScope, func_returns_error: bool) PropagationScope {
        return .{
            .base = ScopeBase(UnionVar).init(
                allocator,
                if (parent) |p| &p.base else null,
            ),
            .func_returns_error = func_returns_error,
        };
    }
    pub fn deinit(self: *PropagationScope) void { self.base.deinit(); }
    pub fn define(self: *PropagationScope, name: []const u8, is_error: bool, line: usize, col: usize) !void {
        try self.base.define(name, .{ .name = name, .handled = false, .is_error_union = is_error, .line = line, .col = col });
    }
    pub fn markHandled(self: *PropagationScope, name: []const u8) void {
        if (self.base.lookupPtr(name)) |v| { v.handled = true; }
    }
    pub fn isTracked(self: *const PropagationScope, name: []const u8) ?UnionVar {
        return self.base.lookup(name);
    }
    pub fn resetHandled(self: *PropagationScope, name: []const u8, is_error: bool) void {
        if (self.base.lookupPtr(name)) |v| { v.handled = false; v.is_error_union = is_error; }
    }
};
```

### What does NOT change

- Public API of each scope type — all callers keep using the same method names
- `VarState`, `UnionVar` struct definitions stay in their original files
- Checker structs (`OwnershipChecker`, `PropagationChecker`, `TypeResolver`) untouched
- All tests keep their existing call patterns

### Testing

- Existing unit tests in `resolver.zig`, `ownership.zig`, `propagation.zig` cover scope behavior
- Add unit tests in `scope.zig` for `ScopeBase` directly: init/define/lookup/parent chain/lookupPtr
- `./testall.sh` must pass

## Implementation order

1. Create `src/scope.zig` with `ScopeBase(V)` + unit tests
2. Swap `resolver.zig` `Scope` → alias for `ScopeBase(RT)`
3. Swap `ownership.zig` `OwnershipScope` → wrapper around `ScopeBase(VarState)`
4. Swap `propagation.zig` `PropagationScope` → wrapper around `ScopeBase(UnionVar)`
5. Run `./testall.sh`, verify all 297+ tests pass
