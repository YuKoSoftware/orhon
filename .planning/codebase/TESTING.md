# Testing Patterns

**Analysis Date:** 2026-03-24

## Test Framework

**Runner:**
- Zig's built-in `test` blocks — no external framework
- Config: `build.zig` — `test_step` collects per-file test executables

**Assertion Library:**
- `std.testing` — `expect`, `expectEqual`, `expectEqualStrings`

**Run Commands:**
```bash
zig build test          # Run all unit tests (test/01_unit.sh)
./testall.sh            # Full pipeline: unit + integration + language tests
bash test/01_unit.sh    # Unit tests only
bash test/09_language.sh  # Language feature codegen tests
bash test/10_runtime.sh   # Runtime correctness (binary output)
bash test/11_errors.sh    # Negative tests (expected compile failures)
```

## Test File Organization

**Location:** Co-located — `test` blocks live in the same `.zig` file as the code they test.

**Naming:** Descriptive strings: `test "reporter collects errors"`, `test "ownership - use after move detected"`, `test "classifyType - primitives"`

**Pattern:** Tests are grouped at the bottom of each file, often under a `// ── Tests ──` or `// ====` separator comment.

**Files with tests (registered in `build.zig`):**
- `src/main.zig`
- `src/lexer.zig`
- `src/parser.zig`
- `src/module.zig`
- `src/declarations.zig`
- `src/resolver.zig`
- `src/ownership.zig`
- `src/borrow.zig`
- `src/thread_safety.zig`
- `src/propagation.zig`
- `src/mir.zig`
- `src/codegen.zig`
- `src/zig_runner.zig`
- `src/types.zig`
- `src/errors.zig`
- `src/builtins.zig`
- `src/cache.zig`
- `src/formatter.zig`
- `src/lsp.zig`
- `src/peg.zig`

## Test Structure

**Suite Organization:**
```zig
test "module - descriptive name" {
    const alloc = std.testing.allocator;
    // Setup
    var reporter = errors.Reporter.init(alloc, .debug);
    defer reporter.deinit();
    var decl_table = declarations.DeclTable.init(alloc);
    defer decl_table.deinit();
    const ctx = sema.SemanticContext.initForTest(alloc, &reporter, &decl_table);

    // Exercise
    var checker = OwnershipChecker.init(alloc, &ctx);
    // ... invoke behavior ...

    // Assert
    try std.testing.expect(!reporter.hasErrors());
}
```

**Patterns:**
- Always use `std.testing.allocator` — detects memory leaks
- Always `defer deinit()` every struct initialized in a test
- Use `SemanticContext.initForTest()` (`src/sema.zig`) to create minimal context without full pipeline
- Use `std.heap.ArenaAllocator` for AST nodes built inline in tests

## Mocking

**Framework:** None — no mocking library. Tests use real implementations with minimal inputs.

**How to isolate behavior:**
- Build minimal AST nodes manually with an arena allocator
- Use `errors.Reporter` to capture pass output instead of checking return values
- Check `reporter.hasErrors()` / `reporter.hasWarnings()` as the primary assertion mechanism for error cases

**Example — building AST for a test:**
```zig
var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
const a = arena.allocator();

const ret_type = try a.create(parser.Node);
ret_type.* = .{ .type_named = "void" };

const func_node = try a.create(parser.Node);
func_node.* = .{ .func_decl = .{
    .name = "myFunc",
    .params = &.{},
    .return_type = ret_type,
    .body = undefined,
    .is_compt = false,
    .is_pub = true,
    .is_bridge = false,
    .is_thread = false,
}};
```

**What NOT to mock:**
- `Reporter` — always use real `Reporter.init(alloc, .debug)`
- `DeclTable` — always use real `DeclTable.init(alloc)`
- `SemanticContext` — use `initForTest` which provides real struct with null locs

## Fixtures and Factories

**Test Data:**
- AST nodes built inline per test — no shared fixture files for unit tests
- Integration test fixtures live in `test/fixtures/*.orh` — real Orhon source used by shell test scripts

**Location of integration fixtures:**
- `test/fixtures/` — `.orh` source files for compile, codegen, error, and language tests

**`SemanticContext.initForTest` factory** in `src/sema.zig`:
```zig
pub fn initForTest(allocator: std.mem.Allocator, reporter: *errors.Reporter, decls: *declarations.DeclTable) SemanticContext {
    return .{ .allocator = allocator, .reporter = reporter, .decls = decls, .locs = null, .file_offsets = &.{} };
}
```
Use this in every test that needs a `SemanticContext` — it sets `locs = null` and `file_offsets = &.{}`.

## Coverage

**Requirements:** No enforced coverage target.

**View Coverage:**
```bash
zig build test  # passes/fails only — no coverage report built-in
```

## Test Types

**Unit Tests (in-file `test` blocks):**
- Scope: individual functions and structs in isolation
- Input: manually constructed minimal data (raw values, small ASTs)
- Assertion: `std.testing.expect*` and `reporter.hasErrors()`
- Examples: `src/errors.zig`, `src/builtins.zig`, `src/mir.zig`, `src/ownership.zig`

**Shell Integration Tests (`test/*.sh`):**
- Scope: full compiler pipeline — CLI through binary output
- Input: real `.orh` programs in `test/fixtures/`
- Assertion: exit codes, stdout/stderr text matching, file existence
- Pipeline order enforced: `01_unit` through `11_errors`

**Language Feature Tests (`test/09_language.sh`):**
- Uses an `example` module (fixture) as a living language manual
- The example module must compile and cover all implemented features

**Runtime Correctness Tests (`test/10_runtime.sh`):**
- Runs compiled Orhon binary and checks stdout output
- Uses a `tester` module fixture

**Negative Tests (`test/11_errors.sh`):**
- Expects compilation to fail with specific error messages
- Validates that invalid programs are rejected correctly

## Common Patterns

**Error case testing:**
```zig
// Exercise code that should produce an error
var id = parser.Node{ .identifier = "s" };
try checker.checkExpr(&id, &scope, false);

// Assert error was recorded
try std.testing.expect(reporter.hasErrors());
```

**Success case testing:**
```zig
try checker.checkExpr(&id, &scope, false);
try std.testing.expect(!reporter.hasErrors());
```

**Equality testing:**
```zig
// Strings
try std.testing.expectEqualStrings("[]const u8", try gen.typeToZig(&str_type));

// Counts
try std.testing.expectEqual(@as(usize, 1), reg.entries.items.len);

// Enum values (use expect with ==, not expectEqual)
try std.testing.expect(node.* == .var_decl);
```

**Async Testing:** Not used — all passes are synchronous.

---

*Testing analysis: 2026-03-24*
