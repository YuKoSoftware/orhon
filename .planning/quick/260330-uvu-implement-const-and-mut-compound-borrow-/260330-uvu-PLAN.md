---
phase: quick-260330-uvu
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  # Lexer/Parser/PEG layer
  - src/lexer.zig
  - src/parser.zig
  - src/peg/orhon.peg
  - src/peg/builder_exprs.zig
  - src/peg/builder_types.zig
  - src/peg/token_map.zig
  # Constants
  - src/constants.zig
  # Semantic passes
  - src/resolver.zig
  - src/ownership.zig
  - src/borrow.zig
  - src/thread_safety.zig
  # MIR layer
  - src/mir/mir_annotator.zig
  - src/mir/mir_lowerer.zig
  - src/mir/mir_types.zig
  # Codegen
  - src/codegen/codegen.zig
  - src/codegen/codegen_exprs.zig
  - src/codegen/codegen_stmts.zig
  - src/codegen/codegen_match.zig
  # .orh files (syntax migration)
  - src/std/linear.orh
  - src/std/tui.orh
  - src/std/stream.orh
  - src/std/net.orh
  - src/std/allocator.orh
  - src/templates/example/example.orh
  - src/templates/example/advanced.orh
  - test/fixtures/tester.orh
  - test/fixtures/tester_main.orh
  - test/fixtures/fail_borrow.orh
  - test/fixtures/fail_threads.orh
  # Docs
  - docs/09-memory.md
  - docs/10-structs-enums.md
  - docs/12-concurrency.md
  - docs/14-zig-bridge.md
  - docs/COMPILER.md
  - docs/TODO.md
autonomous: true
requirements: []
must_haves:
  truths:
    - "const& T parses as an immutable borrow type"
    - "mut& T parses as a mutable borrow type"
    - "const& x parses as an immutable borrow expression"
    - "mut& x parses as a mutable borrow expression"
    - "Bare & only appears in bitwise AND expressions"
    - "All existing borrow-related tests pass with new syntax"
    - "All .orh files use new const&/mut& syntax"
  artifacts:
    - path: "src/lexer.zig"
      provides: "const_borrow and mut_borrow compound tokens"
      contains: "const_borrow"
    - path: "src/parser.zig"
      provides: "mut_borrow_expr AST node (replaces borrow_expr)"
      contains: "mut_borrow_expr"
    - path: "src/peg/orhon.peg"
      provides: "Updated grammar with const& and mut& rules"
      contains: "mut&"
  key_links:
    - from: "src/lexer.zig"
      to: "src/peg/token_map.zig"
      via: "compound token enum + literal map entry"
      pattern: "const_borrow.*mut_borrow"
    - from: "src/peg/orhon.peg"
      to: "src/peg/builder_exprs.zig"
      via: "unary_expr rule matches compound tokens"
      pattern: "const_borrow|mut_borrow"
    - from: "src/parser.zig"
      to: "src/borrow.zig"
      via: "mut_borrow_expr and const_borrow_expr node kinds"
      pattern: "mut_borrow_expr"
---

<objective>
Implement const& and mut& compound borrow tokens across the entire compiler pipeline.

Purpose: Replace the two-token `const &` and bare `&` borrow syntax with single compound tokens `const&` (immutable borrow) and `mut&` (mutable borrow). This makes borrow intent explicit — every reference must state its access mode, and bare `&` reverts to only meaning bitwise AND.

Output: Updated lexer, grammar, AST nodes, all semantic passes, codegen, all .orh files, and docs using the new syntax.
</objective>

<execution_context>
@/home/yunus/.claude/get-shit-done/workflows/execute-plan.md
@/home/yunus/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@CLAUDE.md
@src/lexer.zig
@src/parser.zig
@src/peg/orhon.peg
@src/peg/builder_exprs.zig
@src/peg/builder_types.zig
@src/peg/token_map.zig
@src/constants.zig
</context>

<tasks>

<task type="auto">
  <name>Task 1: Add compound tokens and update lexer, PEG grammar, AST nodes, and builders</name>
  <files>src/lexer.zig, src/parser.zig, src/peg/orhon.peg, src/peg/builder_exprs.zig, src/peg/builder_types.zig, src/peg/token_map.zig, src/constants.zig</files>
  <action>
**Lexer (src/lexer.zig):**
- Add two new token kinds to TokenKind enum: `const_borrow` (for `const&`) and `mut_borrow` (for `mut&`).
- In `lexIdentOrKeyword()`: after the identifier text is extracted and matched against KEYWORDS, add a lookahead check. If the keyword is `kw_const` and the very next character (no whitespace skip) is `&`, consume the `&` and return token kind `const_borrow` with text `"const&"`. This must happen BEFORE returning the keyword token.
- Add a new keyword entry `"mut"` that does NOT map to a standalone keyword. Instead, in `lexIdentOrKeyword()`, if the text is `"mut"` and the very next char is `&`, consume the `&` and return `mut_borrow` with text `"mut&"`. If the text is `"mut"` and the next char is NOT `&`, return it as an `identifier` (mut is not a standalone keyword). Do NOT add `kw_mut` to the KEYWORDS map — `mut` alone stays an identifier.
- The existing `ampersand` token kind stays — bare `&` still exists for bitwise AND.
- Add unit tests: `"const&x"` produces `[const_borrow, identifier]`, `"mut&x"` produces `[mut_borrow, identifier]`, `"const &x"` produces `[kw_const, ampersand, identifier]` (no longer compound — space breaks it), `"a & b"` produces `[identifier, ampersand, identifier]` (bitwise AND unchanged).

**Parser AST (src/parser.zig):**
- Rename `borrow_expr` to `mut_borrow_expr` in both the NodeKind enum and the Node union. Keep `const_borrow_expr` as-is.
- Both remain: `*Node` (pointer to the inner expression).

**PEG grammar (src/peg/orhon.peg):**
- In `unary_expr`: replace `'const' '&' unary_expr` with `'const&' unary_expr`. Replace `'&' unary_expr` with `'mut&' unary_expr`. Keep `'&'` in `bitand_expr` for bitwise AND.
- In `borrow_type`: replace `'const' '&' type` with `'const&' type`.
- In `ref_type`: replace `'&' type` with `'mut&' type`. Update the comment from `# &T — mutable reference` to `# mut& T — mutable reference`.
- Update the `borrow_type` comment from `# const &T — immutable reference` to `# const& T — immutable reference`.
- In the KEYWORDS section comment at bottom, add `const&` and `mut&` to the reserved tokens list.

**Token map (src/peg/token_map.zig):**
- Add `"const&"` mapping to `.const_borrow` in LITERAL_MAP.
- Add `"mut&"` mapping to `.mut_borrow` in LITERAL_MAP.
- Keep `"&"` mapping to `.ampersand` — still needed for bitwise AND.

**Builder exprs (src/peg/builder_exprs.zig):**
- In `buildUnaryExpr()`: update the `kw_const` check to check for `const_borrow` token kind instead. When matched, create `.const_borrow_expr` node (unchanged).
- Replace the `ampersand` check with a `mut_borrow` token kind check. When matched, create `.mut_borrow_expr` node (renamed from `.borrow_expr`).

**Builder types (src/peg/builder_types.zig):**
- `buildBorrowType()`: update comment. The grammar now matches `'const&'` as a single token. The function still produces `.type_ptr = .{ .kind = "const &", .elem = inner }`. The `kind` string stays `"const &"` for now (internal representation, used by constants.zig).
- `buildRefType()`: update comment. The grammar now matches `'mut&'` as a single token. The function still produces `.type_ptr = .{ .kind = "var &", .elem = inner }`. The `kind` string stays `"var &"` for now.

**Constants (src/constants.zig):**
- Keep `CONST_REF = "const &"` and `VAR_REF = "var &"` unchanged — these are internal type representation strings used across many passes, not surface syntax.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build test 2>&1 | tail -20</automated>
  </verify>
  <done>New compound tokens const_borrow and mut_borrow recognized by lexer, PEG grammar updated, builders produce correct AST nodes, all unit tests pass.</done>
</task>

<task type="auto">
  <name>Task 2: Update all semantic passes, MIR, codegen, and error messages</name>
  <files>src/resolver.zig, src/ownership.zig, src/borrow.zig, src/thread_safety.zig, src/mir/mir_annotator.zig, src/mir/mir_lowerer.zig, src/mir/mir_types.zig, src/codegen/codegen.zig, src/codegen/codegen_exprs.zig, src/codegen/codegen_stmts.zig, src/codegen/codegen_match.zig</files>
  <action>
This is a mechanical rename: every occurrence of `.borrow_expr` in the Zig source must become `.mut_borrow_expr`. The AST node was renamed in Task 1.

**All files — rename `.borrow_expr` to `.mut_borrow_expr`:**

- `src/resolver.zig`: lines ~631 — `.borrow_expr => |b|` becomes `.mut_borrow_expr => |b|`
- `src/ownership.zig`: lines ~374, ~402 — `.borrow_expr` becomes `.mut_borrow_expr`
- `src/borrow.zig`: all occurrences (~94, 96, 111, 113, 127, 170, 172, 191) — `.borrow_expr` becomes `.mut_borrow_expr`. Also rename in unit test construction: `parser.Node{ .borrow_expr = ... }` becomes `parser.Node{ .mut_borrow_expr = ... }`.
- `src/thread_safety.zig`: lines ~253, 273, 428, 494, and unit tests (~675, 798, 864, 981) — all `.borrow_expr` to `.mut_borrow_expr`.
- `src/mir/mir_lowerer.zig`: lines ~232, 705 — `.borrow_expr` to `.mut_borrow_expr`.
- `src/mir/mir_annotator.zig`: lines ~293 — `.borrow_expr` to `.mut_borrow_expr`.
- `src/codegen/codegen_stmts.zig`: lines ~296 — `.borrow_expr` to `.mut_borrow_expr`.
- `src/codegen/codegen_match.zig`: lines ~956, 973 — `.borrow_expr` to `.mut_borrow_expr`.

**Update error messages to use new syntax:**

- `src/borrow.zig`: Change `"consider borrowing with const &"` to `"consider borrowing with const&"` (3 occurrences around lines 297, 302, 321).
- `src/borrow.zig`: Update comments at top and throughout: `const &T` → `const& T`, `var &T` → `mut& T`, `&x` → `mut& x`, `const &x` → `const& x`.
- `src/resolver.zig`: line ~231, change error message `"mutable reference '&{s}' not allowed across bridge — use 'const &{s}' or pass by value"` to `"mutable reference 'mut& {s}' not allowed across bridge — use 'const& {s}' or pass by value"`.
- `src/thread_safety.zig`: Update any comments referencing old syntax.
- `src/mir/mir_types.zig`: line ~55 comment `// T → &T for const & parameters` update to `// T → const& T for const& parameters`.

**Do NOT change:**
- The `K.Ptr.CONST_REF` / `K.Ptr.VAR_REF` string values in constants.zig — these are internal type representation strings.
- The codegen emit of `"&"` for Zig pointer output — that's Zig syntax, not Orhon syntax.
- Any `value_to_const_ref` coercion names — those are internal identifiers.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build test 2>&1 | tail -20</automated>
  </verify>
  <done>All semantic passes, MIR, and codegen use mut_borrow_expr. Error messages reference const& and mut& syntax. Unit tests pass.</done>
</task>

<task type="auto">
  <name>Task 3: Migrate all .orh files, docs, and test fixtures to const&/mut& syntax</name>
  <files>src/std/linear.orh, src/std/tui.orh, src/std/stream.orh, src/std/net.orh, src/std/allocator.orh, src/templates/example/example.orh, src/templates/example/advanced.orh, test/fixtures/tester.orh, test/fixtures/tester_main.orh, test/fixtures/fail_borrow.orh, test/fixtures/fail_threads.orh, docs/09-memory.md, docs/10-structs-enums.md, docs/12-concurrency.md, docs/14-zig-bridge.md, docs/COMPILER.md, docs/TODO.md</files>
  <action>
**Syntax migration rules for all .orh files:**

1. `const &T` (type position, e.g., `self: const &Player`) → `const& Player` — note the space moves: `const &X` becomes `const& X`.
2. `&T` (type position, e.g., `self: &Game`) → `mut& Game` — bare `&` in type position becomes `mut&`.
3. `const &expr` (expression position, e.g., `const &target`) → `const& target`.
4. `&expr` (expression position, e.g., `&p`) → `mut& p` — but only in borrow contexts, NOT bitwise AND.

**Distinguishing borrow from bitwise AND:** In .orh files, `&` as borrow appears:
- In type annotations: `param: &T` → `param: mut& T`
- As expression prefix: `&variable` → `mut& variable`
- Bitwise AND appears as infix: `a & b` — leave these alone.

**Files to update:**

stdlib .orh files (type annotations only — `const &` → `const&`, `&` → `mut&`):
- `src/std/linear.orh`: ~37 occurrences of `const &Vec2`, `const &Vec3`, `const &Vec4`, `const &Mat4`, `const &Quat` → `const& Vec2`, etc.
- `src/std/tui.orh`: `&Screen`, `&Key`, `&Size` → `mut& Screen`, `mut& Key`, `mut& Size`
- `src/std/stream.orh`: `&Buffer` → `mut& Buffer`
- `src/std/net.orh`: `&Connection`, `&Listener` → `mut& Connection`, `mut& Listener`
- `src/std/allocator.orh`: `&SMP`, `&Arena`, `&Page` → `mut& SMP`, `mut& Arena`, `mut& Page`

Example module:
- `src/templates/example/example.orh`: Update all borrow syntax in comments AND code. `const &Player` → `const& Player`, `const &Box` → `const& Box`, `&Game` → `mut& Game`. Update the comments explaining borrow syntax.
- `src/templates/example/advanced.orh`: Update borrow syntax in comments and code.

Test fixtures:
- `test/fixtures/tester.orh`: `const &Counter` → `const& Counter`, `const &Direction` → `const& Direction`, `const &BorrowTarget` → `const& BorrowTarget`, `const &target` → `const& target`. Update comments.
- `test/fixtures/tester_main.orh`: Update borrow syntax comments.
- `test/fixtures/fail_borrow.orh`: `const &Point` → `const& Point`, `&p` → `mut& p`. Update error message comments.
- `test/fixtures/fail_threads.orh`: `const &i32` → `const& i32`.

**Documentation updates:**

- `docs/09-memory.md`: All syntax examples: `const &T` → `const& T`, `&T` → `mut& T`, `const &x` → `const& x`, `&x` → `mut& x`. Update the borrowing rules table/list.
- `docs/10-structs-enums.md`: `const &Player` → `const& Player`, `&Player` → `mut& Player`, `const &Stack` → `const& Stack`, `&Stack` → `mut& Stack`, `const &Animal` → `const& Animal`, `const &Shape` → `const& Shape`. Update the self-parameter summary line: "No self = static, const& T = immutable, mut& T = mutable, T = consuming".
- `docs/12-concurrency.md`: `const &i32` → `const& i32`, `&i32` → `mut& i32`.
- `docs/14-zig-bridge.md`: Update the direction table: `const &T` → `const& T`, `&T` → `mut& T`. Update all bridge examples. Update error message example.
- `docs/COMPILER.md`: `const &T` → `const& T`.
- `docs/TODO.md`: Update historical references (mark them as old syntax where appropriate, update the feature descriptions).

**Also check these docs for borrow references:** Run grep on all docs/*.md for `const &` or `: &` patterns and update any others found.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -30</automated>
  </verify>
  <done>All .orh files use const& and mut& syntax. All docs updated. ./testall.sh passes — the full 11-stage pipeline validates the new syntax end to end.</done>
</task>

</tasks>

<verification>
1. `zig build test` — all unit tests pass (lexer compound tokens, borrow checker, thread safety, MIR annotator)
2. `./testall.sh` — full 11-stage test pipeline passes
3. `grep -r 'const &' src/ test/ --include='*.orh'` — returns zero matches (all migrated)
4. `grep -rn '\.borrow_expr' src/ --include='*.zig'` — returns zero matches (all renamed to mut_borrow_expr)
5. `grep -r ': &[A-Z]' src/ test/ --include='*.orh'` — returns zero matches (all bare & in type position migrated to mut&)
</verification>

<success_criteria>
- const& and mut& are compound tokens in the lexer
- PEG grammar matches 'const&' and 'mut&' as single tokens
- borrow_expr renamed to mut_borrow_expr throughout all passes
- All .orh files (stdlib, examples, test fixtures) use new syntax
- All docs reflect new syntax
- Bare & only appears in bitwise AND contexts
- ./testall.sh passes with zero failures
</success_criteria>

<output>
After completion, create `.planning/quick/260330-uvu-implement-const-and-mut-compound-borrow-/260330-uvu-01-SUMMARY.md`
</output>
