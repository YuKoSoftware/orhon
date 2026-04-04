# Orhon Compiler — Language Mechanics Review Plan

## Overview

- **Total chunks**: 23 (organized by language feature)
- **Coverage**: all 75 NodeKind variants, all grammar rules
- **Ordering**: foundational (literals, identifiers) to composite (generics, interop)

Each chunk traces a language feature end-to-end through every compiler pass it touches. Not every feature touches every pass.

---

## Chunk 1: Module Declaration and Program Structure

**Purpose**: `module <name>` declaration, program node, file structure.

**Spec docs**: `docs/01-basics.md`, `docs/11-modules.md`

**Grammar rules**: `program`, `module_decl`, `error_skip`, `TERM`, `_`, `EOF`, `NL`

**NodeKind**: `program`, `module_decl`

**Verify**:
| Pass | Check |
|------|-------|
| Lexer | `kw_module`, `identifier`, `newline` tokens |
| Parser | `program` wraps module_decl + body. `module_decl` captures name |
| Module Resolution (3) | Files grouped by module name. Anchor file detected. Circular import detection |
| Codegen (11) | File header comment, `const std = @import("std")` |

**Complexity**: Small

---

## Chunk 2: Literals (Integer, Float, String, Bool, Null, Void)

**Purpose**: All literal value expressions.

**Spec docs**: `docs/02-types.md`

**Grammar rules**: `int_literal`, `float_literal`, `string_literal`, `bool_literal`, `null_literal`, `void_literal`, `INT_LITERAL`, `FLOAT_LITERAL`, `STRING_LITERAL`

**NodeKind**: `int_literal`, `float_literal`, `string_literal`, `bool_literal`, `null_literal`

**Verify**:
| Pass | Check |
|------|-------|
| Lexer | Decimal, hex, binary, octal, underscore separators. Float with decimal. String escapes. Keywords for true/false/null/void |
| Parser | Correct NodeKind per literal, text stored in payload |
| Resolver (5) | Numeric literals without type annotation produce error. Bool/string/null infer correctly |
| MIR (10) | `MirKind.literal` with correct `LiteralKind` |
| Codegen (11) | Integers verbatim. Strings escaped. `true`/`false`/`null` as Zig keywords |

**Complexity**: Medium

---

## Chunk 3: Identifiers and Variable Declarations

**Purpose**: `var`, `const`, destructuring, scoping, no shadowing.

**Spec docs**: `docs/03-variables.md`, `docs/01-basics.md`

**Grammar rules**: `const_decl`, `var_decl`, `destruct_tail`, `identifier_expr`

**NodeKind**: `var_decl`, `destruct_decl`, `identifier`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | `var_decl` with name, optional type, value. Mutability set correctly |
| Declarations (4) | Module-level `const` in DeclTable. Module-level `var` rejected |
| Resolver (5) | Type inferred from RHS. No shadowing. Numeric literals without annotation rejected |
| Ownership (6) | `var` non-primitives tracked as `.owned`. Primitives copy. `const` auto-borrows |
| MIR (10) | `MirKind.var_decl` with `is_const`, `type_annotation` |
| Codegen (11) | `const`/`var` emitted. Destructuring as temp + field extraction |

**Complexity**: Medium

---

## Chunk 4: Operators

**Purpose**: Binary, unary, compound assignment, precedence tower.

**Spec docs**: `docs/04-operators.md`

**Grammar rules**: `expr`, `range_expr`, `or_expr`, `and_expr`, `not_expr`, `compare_expr`, `bitor_expr`, `bitxor_expr`, `bitand_expr`, `shift_expr`, `add_expr`, `mul_expr`, `unary_expr`, `assign_expr`

**NodeKind**: `binary_expr`, `unary_expr`, `assignment`, `range_expr`

**Verify**:
| Pass | Check |
|------|-------|
| Lexer | All operator tokens present |
| Parser | Precedence tower nests correctly. `is`/`is not` in compare_expr |
| Resolver (5) | Both sides same numeric type. `++` only on strings/arrays. `is`/`is not` only on unions |
| Codegen (11) | `and`/`or`/`not` → Zig equivalents. `++` → Zig concat. Compound assignment emits correctly |

**Complexity**: Medium

---

## Chunk 5: Function Declarations and Calls

**Purpose**: `func`, params, return types, named args, defaults, first-class functions, `pub`.

**Spec docs**: `docs/05-functions.md`

**Grammar rules**: `func_decl`, `param_list`, `param`, `pub_decl`, `call_access`, `named_arg_list`, `func_type`

**NodeKind**: `func_decl`, `param`, `call_expr`, `type_func`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | FuncDecl with name, params, return_type, body, is_pub. Named args in CallExpr |
| Declarations (4) | FuncSig in DeclTable with param types and return type |
| Resolver (5) | Param/return types resolved. Default values type-checked. Return value matches declared type |
| Ownership (6) | Non-primitive params create owned entries. Move semantics on call args |
| MIR (10) | `MirKind.func` with `is_pub`, `is_compt`. `MirKind.call` with `arg_names` |
| Codegen (11) | `pub fn name(params) RetType { body }`. Named args reordered. Function types as `*const fn(T) R` |

**Complexity**: Large

---

## Chunk 6: Control Flow — if/elif/else

**Purpose**: Conditional branching, type narrowing after `is` checks.

**Spec docs**: `docs/07-control-flow.md`

**Grammar rules**: `if_stmt`, `elif_chain`

**NodeKind**: `if_stmt`, `block`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | `elif` chains produce nested `if_stmt` in else_block |
| Resolver (5) | Condition must be `bool` |
| Ownership (6) | Both branches analyzed for moves |
| Propagation (9) | Type narrowing after `is Error`/`is null` with early return |
| MIR (10) | `IfNarrowing` for `is` checks |
| Codegen (11) | Type narrowing emits payload extraction |

**Complexity**: Medium

---

## Chunk 7: Control Flow — while and for loops

**Purpose**: `while`, `for` iteration, captures, index variables, range, `break`, `continue`.

**Spec docs**: `docs/07-control-flow.md`

**Grammar rules**: `while_stmt`, `for_stmt`, `for_captures`, `break_stmt`, `continue_stmt`

**NodeKind**: `while_stmt`, `for_stmt`, `break_stmt`, `continue_stmt`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | WhileStmt with condition, continue_expr, body. ForStmt with captures, index_var |
| Resolver (5) | break/continue only inside loops. Capture types inferred from iterable |
| Codegen (11) | While: `while (cond) : (cont) {}`. For over slice: `for (arr) |val|`. Range: correct Zig pattern. Index: `for (arr, 0..) |val, i|` |

**Complexity**: Large

---

## Chunk 8: Control Flow — match (Pattern Matching)

**Purpose**: `match expr { pattern => body }`. Literals, ranges, guards, `else`, exhaustiveness.

**Spec docs**: `docs/07-control-flow.md`

**Grammar rules**: `match_stmt`, `match_arm`, `match_pattern`, `parenthesized_pattern`

**NodeKind**: `match_stmt`, `match_arm`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | Parenthesized patterns: range `(1..10)` vs guard `(x if x > 0)` vs grouped |
| Resolver (5) | Exhaustiveness for enums. Guard is bool. Pattern types match scrutinee |
| Codegen (11) | Integer → Zig `switch`. String → if-else chain with `std.mem.eql`. Range → range checks. Enum → tagged union switch. Guard → if-else with binding |

**Complexity**: Very Large (dedicated `codegen_match.zig`)

---

## Chunk 9: Struct Declarations

**Purpose**: Fields, methods, defaults, `self` conventions, `pub`, static, `.new()` constructors.

**Spec docs**: `docs/10-structs-enums.md`

**Grammar rules**: `struct_decl`, `struct_body`, `struct_member`, `field_decl`, `blueprint_list`

**NodeKind**: `struct_decl`, `field_decl`, `struct_type`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | StructDecl with type_params, members, blueprints. FieldDecl with default_value |
| Declarations (4) | StructSig with FieldSig array and conforms_to blueprints |
| Resolver (5) | Self param matches struct name. Blueprint conformance validated |
| Ownership (6) | Structs are atomic — no partial field moves |
| Codegen (11) | `const Name = struct { fields, methods }`. Named instantiation: `.{ .field = val }` |

**Complexity**: Large

---

## Chunk 10: Enum Declarations

**Purpose**: Simple enums, data-carrying (tagged unions), explicit values, methods.

**Spec docs**: `docs/10-structs-enums.md`

**Grammar rules**: `enum_decl`, `enum_body`, `enum_member`, `enum_variant`

**NodeKind**: `enum_decl`, `enum_variant`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | EnumDecl with backing_type. EnumVariant with optional fields/value |
| Declarations (4) | EnumSig with backing_type and variants |
| Codegen (11) | Simple → Zig `enum(u8)`. Data-carrying → Zig `union(enum(u32))` |

**Complexity**: Large

---

## Chunk 11: Blueprint Declarations

**Purpose**: `blueprint Name { func signatures }`. Struct conformance, compile-time checking, pure erasure.

**Spec docs**: `docs/10-structs-enums.md`, `src/templates/example/blueprints.orh`

**Grammar rules**: `blueprint_decl`, `blueprint_body`, `blueprint_method`

**NodeKind**: `blueprint_decl`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | Methods are signature-only (no body) |
| Declarations (4) | BlueprintSig with BlueprintMethodSig array |
| Resolver (5) | Conforming structs checked: all methods present with correct signatures |
| Codegen (11) | Blueprint erased — no Zig output |

**Complexity**: Medium

---

## Chunk 12: Type System

**Purpose**: All type annotations — primitives, unions, tuples, slices, arrays, function types, generics, pointers, aliases.

**Spec docs**: `docs/02-types.md`

**Grammar rules**: `type`, `borrow_type`, `ref_type`, `paren_type`, `slice_type`, `array_type`, `func_type`, `generic_type`, `generic_arg_list`, `scoped_type`, `scoped_generic_type`, `named_type`, `keyword_type`

**NodeKind**: `type_primitive`, `type_slice`, `type_array`, `type_ptr`, `type_union`, `type_tuple_named`, `type_tuple_anon`, `type_func`, `type_generic`, `type_named`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | `paren_type` dispatches: `()` → void, `(name: T)` → named tuple, `(T|U)` → union, `(T)` → grouped |
| Resolver (5) | Unknown types produce "did you mean?" suggestions. `any` resolved per usage. Duplicate union types rejected |
| MIR (10) | TypeClass classification: error_union, null_union, arbitrary_union, string, plain |
| Codegen (11) | `str` → `[]const u8`. `(Error|T)` → `anyerror!T`. `(null|T)` → `?T`. `const& T` → `*const T`. `mut& T` → `*T` |

**Complexity**: Very Large

---

## Chunk 13: Error and Null Handling

**Purpose**: `(Error|T)`, `Error("msg")`, `is Error`/`is null`, `.value` unwrap, `throw`, propagation.

**Spec docs**: `docs/08-error-handling.md`

**Grammar rules**: `error_literal`, `throw_stmt`

**NodeKind**: `error_literal`, `throw_stmt`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | error_literal with message. throw_stmt with variable |
| Resolver (5) | Return type must be error union for `throw`. `.value` only after narrowing |
| Propagation (9) | Unhandled error/null unions produce compile error. `throw`/`is` check/match marks as handled |
| MIR (10) | IfNarrowing for `is` checks. Coercion.error_wrap/.null_wrap |
| Codegen (11) | `Error("msg")` → `error.msg`. `is Error` → result check pattern. `throw` → `catch |err| return err` |

**Complexity**: Very Large

---

## Chunk 14: Ownership and Borrowing

**Purpose**: Single-owner model, move/copy, `const&`/`mut&`, auto-borrow, NLL, `@copy`/`@move`/`@swap`.

**Spec docs**: `docs/09-memory.md`

**Grammar rules**: `unary_expr` (`const&`/`mut&` prefix)

**NodeKind**: `mut_borrow_expr`, `const_borrow_expr`

**Verify**:
| Pass | Check |
|------|-------|
| Ownership (6) | Primitives copy. Non-primitive `var` moves on assignment. `const` auto-borrows. Use-after-move detected. No partial field moves |
| Borrow (7) | `const&` many. `mut&` exclusive. No simultaneous `const&` + `mut&`. NLL via `buildLastUseMap()`. Functions cannot return references |
| MIR (10) | Coercion.value_to_const_ref for auto-borrow |
| Codegen (11) | `const&` → `*const T`. `mut&` → `*T`. Auto-borrow inserts `&` |

**Complexity**: Very Large

---

## Chunk 15: Compiler Functions (@builtins)

**Purpose**: `@cast`, `@copy`, `@move`, `@swap`, `@assert`, `@size`, `@align`, `@typename`, `@typeid`, `@typeOf`, `@hasField`, `@hasDecl`, `@fieldType`, `@fieldNames`, `@splitAt`, `@wrap`, `@sat`, `@overflow`.

**Spec docs**: `docs/05-functions.md`, `docs/04-operators.md`

**Grammar rules**: `compiler_func`, `compiler_func_name`

**NodeKind**: `compiler_func`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | CompilerFunc with name (without @) and args |
| Resolver (5) | Argument types validated per function |
| Ownership (6) | `@copy` keeps original. `@move` marks original dead |
| Codegen (11) | Each builtin maps to correct Zig intrinsic/pattern |

**Complexity**: Very Large (18 builtins)

---

## Chunk 16: compt (Compile-Time Evaluation)

**Purpose**: `compt func`, type-generating compt, value compt, generic structs.

**Spec docs**: `docs/05-functions.md`, `docs/02-types.md`

**Grammar rules**: `compt_decl`, `struct_expr`

**NodeKind**: `func_decl` (with `context: .compt`), `struct_type`

**Verify**:
| Pass | Check |
|------|-------|
| Declarations (4) | FuncSig.context = .compt. Compt type aliases in DeclTable.types |
| Resolver (5) | Generic type args resolved. Each unique arg set → distinct type |
| Codegen (11) | Type-generating → `fn Name(comptime T: type) type { return struct { ... }; }`. Value → `inline fn`. `@This()` replacement inside generic struct body |

**Complexity**: Very Large

---

## Chunk 17: Import System and Visibility

**Purpose**: `import` (namespaced), `use` (flat), `std::`, aliases, C headers, `pub`.

**Spec docs**: `docs/11-modules.md`

**Grammar rules**: `import_decl`, `import_path`

**NodeKind**: `import_decl`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | ImportDecl with path, scope, alias, is_c_header, is_include |
| Module Resolution (3) | Import graph, circular detection, `std::` resolved to embedded stdlib |
| Resolver (5) | `use` enables unqualified lookup. Scoped access `module.Symbol` |
| Codegen (11) | `import` → `@import("name.zig")`. `use` → re-export. C header → `@cImport(@cInclude(...))` |

**Complexity**: Large

---

## Chunk 18: Metadata and Project Configuration

**Purpose**: `#build`, `#name`, `#version`, `#dep`, `#description`.

**Spec docs**: `docs/11-modules.md`, `docs/13-build-cli.md`

**Grammar rules**: `metadata`, `metadata_body`

**NodeKind**: `metadata`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | Metadata with field enum, value, extra |
| Module Resolution (3) | Only in anchor files. Build type determines compilation mode |
| Codegen (11) | No direct Zig. Affects build.zig generation |

**Complexity**: Small

---

## Chunk 19: Postfix Expressions

**Purpose**: `obj.field`, `obj.method(args)`, `arr[i]`, `arr[a..b]`, `f(args)`.

**Spec docs**: `docs/06-collections.md`, `docs/10-structs-enums.md`

**Grammar rules**: `postfix_expr`, `method_call`, `field_access`, `slice_access`, `index_access`, `call_access`

**NodeKind**: `field_expr`, `index_expr`, `slice_expr`, `call_expr`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | PEG ordering: method_call before field_access, slice_access before index_access |
| Resolver (5) | Field access validated against struct/enum. Index type checked |
| Ownership (6) | Index on moved array rejected |
| Codegen (11) | Field: `obj.field`. Index: `obj[i]`. Slice: `obj[a..b]`. Method: correct self passing |

**Complexity**: Medium

---

## Chunk 20: Testing and Doc Comments

**Purpose**: `test "desc" { body }`, `@assert` in tests, `///` doc comments.

**Spec docs**: `docs/15-testing.md`

**Grammar rules**: `test_decl`, `doc_block`, `DOC_COMMENT`

**NodeKind**: `test_decl`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | TestDecl with description and body. Doc comments merged from consecutive `///` lines |
| Resolver (5) | Test body type-checked. No return type |
| Codegen (11) | `test "desc" { }`. `@assert` → `try std.testing.expect()` in test context. Doc comments → Zig `///` |

**Complexity**: Small

---

## Chunk 21: String Interpolation

**Purpose**: `"hello @{name}!"` → `allocPrint` with format specifiers, `defer free`.

**Spec docs**: `docs/02-types.md`

**Grammar rules**: `string_literal` (lexer detects `@{expr}`)

**NodeKind**: `interpolated_string`

**Verify**:
| Pass | Check |
|------|-------|
| Lexer | `@{` detected inside string. String split into parts |
| Parser | InterpolatedString with parts (literal/expr) |
| Resolver (5) | Embedded expressions must be formattable |
| MIR (10) | `MirKind.interpolation` with `interp_parts` |
| Codegen (11) | `allocPrint(allocator, "hello {s}!", .{name})`. Format specifiers: `{s}` strings, `{d}` ints. `defer free` emitted |

**Complexity**: Medium

---

## Chunk 22: Array and Tuple Literals

**Purpose**: `[1, 2, 3]`, `(name: val, ...)`, `(1, 0, 0)`.

**Spec docs**: `docs/06-collections.md`, `docs/02-types.md`

**Grammar rules**: `array_literal`, `tuple_literal`, `anon_tuple_literal`

**NodeKind**: `array_literal`, `tuple_literal`

**Verify**:
| Pass | Check |
|------|-------|
| Parser | array_literal as element list. tuple_literal with is_named and field_names |
| Resolver (5) | Array elements must match type. Named tuple types nominal |
| MIR (10) | Coercion.array_to_slice when assigned to slice type |
| Codegen (11) | Array: `[_]i32{ 1, 2, 3 }`. Named tuple: `.{ .name = val }` |

**Complexity**: Medium

---

## Chunk 23: Defer Statement

**Purpose**: `defer { block }`, LIFO ordering, scope-level.

**Spec docs**: `docs/07-control-flow.md`

**Grammar rules**: `defer_stmt`

**NodeKind**: `defer_stmt`

**Verify**:
| Pass | Check |
|------|-------|
| MIR (10) | `MirKind.defer_stmt`. `MirKind.injected_defer` for compiler-generated defers |
| Codegen (11) | `defer { body; }`. LIFO preserved |

**Complexity**: Small

---

## Summary

| # | Feature | Complexity | Key Passes |
|---|---------|------------|------------|
| 1 | Module/Program | Small | 2, 3, 11 |
| 2 | Literals | Medium | 1, 2, 5, 11 |
| 3 | Variables | Medium | 2, 4, 5, 6, 11 |
| 4 | Operators | Medium | 1, 2, 5, 11 |
| 5 | Functions | Large | 2, 4, 5, 6, 10, 11 |
| 6 | if/elif/else | Medium | 2, 5, 6, 9, 10, 11 |
| 7 | while/for | Large | 2, 5, 11 |
| 8 | match | Very Large | 2, 5, 11 |
| 9 | Structs | Large | 2, 4, 5, 6, 7, 11 |
| 10 | Enums | Large | 2, 4, 11 |
| 11 | Blueprints | Medium | 2, 4, 5, 11 |
| 12 | Type System | Very Large | 2, 5, 10, 11 |
| 13 | Error/Null | Very Large | 2, 5, 9, 10, 11 |
| 14 | Ownership/Borrow | Very Large | 6, 7, 10, 11 |
| 15 | Compiler Functions | Very Large | 2, 5, 6, 11 |
| 16 | compt | Very Large | 4, 5, 11 |
| 17 | Imports | Large | 2, 3, 5, 11 |
| 18 | Metadata | Small | 2, 3 |
| 19 | Postfix Expressions | Medium | 2, 5, 6, 11 |
| 20 | Testing/DocComments | Small | 2, 5, 11 |
| 21 | String Interpolation | Medium | 1, 2, 5, 10, 11 |
| 22 | Array/Tuple Literals | Medium | 2, 5, 10, 11 |
| 23 | Defer | Small | 10, 11 |

## NodeKind Coverage

All 75 NodeKind variants are covered:

| NodeKind | Chunk |
|----------|-------|
| `program`, `module_decl` | 1 |
| `int_literal`, `float_literal`, `string_literal`, `bool_literal`, `null_literal` | 2 |
| `var_decl`, `destruct_decl`, `identifier` | 3 |
| `binary_expr`, `unary_expr`, `assignment`, `range_expr` | 4 |
| `func_decl`, `param`, `call_expr`, `type_func` | 5 |
| `if_stmt`, `block` | 6 |
| `while_stmt`, `for_stmt`, `break_stmt`, `continue_stmt` | 7 |
| `match_stmt`, `match_arm` | 8 |
| `struct_decl`, `field_decl`, `struct_type` | 9 |
| `enum_decl`, `enum_variant` | 10 |
| `blueprint_decl` | 11 |
| `type_primitive`, `type_slice`, `type_array`, `type_ptr`, `type_union`, `type_tuple_named`, `type_tuple_anon`, `type_func`, `type_generic`, `type_named` | 12 |
| `error_literal`, `throw_stmt` | 13 |
| `mut_borrow_expr`, `const_borrow_expr` | 14 |
| `compiler_func` | 15 |
| `import_decl` | 17 |
| `metadata` | 18 |
| `field_expr`, `index_expr`, `slice_expr` | 19 |
| `test_decl` | 20 |
| `interpolated_string` | 21 |
| `array_literal`, `tuple_literal` | 22 |
| `defer_stmt` | 23 |

## Recommended Review Order

1. Chunks 1–4 — foundations (modules, literals, variables, operators)
2. Chunk 19 — postfix expressions (field, index, slice)
3. Chunks 22, 21 — array/tuple literals, interpolation
4. Chunk 5 — functions
5. Chunk 12 — type system
6. Chunks 6–8 — control flow (if, loops, match)
7. Chunk 23 — defer
8. Chunks 9–11 — structs, enums, blueprints
9. Chunks 13–14 — error/null handling, ownership/borrow
10. Chunks 15–16 — compiler functions, compt
11. Chunks 17–18 — imports, metadata
12. Chunk 20 — testing/doc comments
