# Operator & Builtin Name Enums — Design Spec

## Goal

Replace scattered string literal comparisons for compiler functions and operators with centralized enums and constants. Eliminates fragile string matching, enables `switch` dispatch.

## Changes

### 1. CompilerFunc enum in builtins.zig

Add an enum with a `fromName()` converter:

```zig
pub const CompilerFunc = enum {
    typename, typeid, typeOf, cast, copy, move, swap,
    assert, size, align, hasField, hasDecl, fieldType, fieldNames,

    pub fn fromName(name: []const u8) ?CompilerFunc { ... }
};
```

Convert the two 14-way if-else chains in `codegen_match.zig` (`generateCompilerFuncMir` at line ~601 and `generateCompilerFunc` at line ~916) to `switch (CompilerFunc.fromName(name) orelse return) { ... }`.

### 2. Op string constants in constants.zig

Add grouped constants for operators used in cross-file comparisons:

```zig
pub const Op = struct {
    pub const AND = "and";
    pub const OR = "or";
    pub const NOT = "not";
    pub const EQ = "==";
    pub const NE = "!=";
    pub const LT = "<";
    pub const GT = ">";
    pub const LE = "<=";
    pub const GE = ">=";
    pub const CONCAT = "++";
    pub const RANGE = "..";
    pub const DIV = "/";
    pub const MOD = "%";
    pub const DIV_ASSIGN = "/=";
};
```

Replace raw string literals at ~20 comparison sites across resolver.zig, propagation.zig, codegen_exprs.zig, codegen_stmts.zig, codegen_match.zig.

## Files Changed

| File | Change |
|------|--------|
| `src/builtins.zig` | Add `CompilerFunc` enum with `fromName()` |
| `src/constants.zig` | Add `Op` string constant struct |
| `src/codegen/codegen_match.zig` | Convert 2 if-else chains to switch; use `Op.*` for operator comparisons |
| `src/codegen/codegen_exprs.zig` | Use `Op.*` constants (~6 sites) |
| `src/codegen/codegen_stmts.zig` | Use `Op.*` constants (~4 sites) |
| `src/resolver.zig` | Use `Op.*` constants (~10 sites) |
| `src/propagation.zig` | Use `Op.*` constants (~4 sites) |

## Not Changing

- AST node structures (operators stay as strings in `BinaryExpr.op`)
- `BUILTIN_TYPES` array or `isBuiltinType()` — already adequate
- `COMPILER_FUNCS` array or `isCompilerFunc()` — kept for validation; enum is for dispatch
