---
type: quick
title: "Rename include keyword to use"
files_modified:
  - src/lexer.zig
  - src/orhon.peg
  - src/peg/token_map.zig
  - src/peg/builder.zig
  - src/lsp.zig
  - src/templates/example/example.orh
  - docs/COMPILER.md
  - docs/TODO.md
autonomous: true
---

<objective>
Rename the `include` keyword to `use` across the entire Orhon compiler. Semantics are identical — only the keyword name changes. `use mymodule` merges symbols into current scope (what `include mymodule` used to do). `import mymodule` remains unchanged.

Also remove the `cimport_key` grammar workaround in orhon.peg — since `include` will no longer be a keyword, `cimport_entry` can use plain `IDENTIFIER` for keys.
</objective>

<context>
@src/lexer.zig
@src/orhon.peg
@src/peg/token_map.zig
@src/peg/builder.zig
@src/lsp.zig
</context>

<tasks>

<task type="auto">
  <name>Task 1: Rename kw_include to kw_use in compiler source</name>
  <files>
    src/lexer.zig
    src/peg/token_map.zig
    src/peg/builder.zig
    src/lsp.zig
  </files>
  <action>
    **src/lexer.zig** (2 changes):
    - Line 28: rename `kw_include` to `kw_use` in the TokenKind enum
    - Line 134: change `"include"` to `"use"` and `.kw_include` to `.kw_use` in the keyword map entry

    **src/peg/token_map.zig** (1 change):
    - Line 25: change `.{ "include", .kw_include }` to `.{ "use", .kw_use }`

    **src/peg/builder.zig** (1 change):
    - Line 403: change `.kw_include` to `.kw_use` in the `is_include` check (the variable name `is_include` can stay — it refers to the semantic concept)
    - NOTE: Lines 452, 485, 492 reference `"include"` as a *cimport key string* (the key inside `#cimport = { include: "..." }`), NOT the keyword. Do NOT change these — `include:` remains a valid cimport key name.

    **src/lsp.zig** (2 changes):
    - Line 1196: change `"include"` to `"use"` and update description to `"(keyword) use a module (flat, dumps symbols into scope)"`
    - Line 3103: change `.kw_include` to `.kw_use`
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -20</automated>
  </verify>
  <done>All kw_include references renamed to kw_use, compiler builds cleanly</done>
</task>

<task type="auto">
  <name>Task 2: Update PEG grammar and remove cimport_key workaround</name>
  <files>src/orhon.peg</files>
  <action>
    **Line 59 — Remove `cimport_key` rule entirely:**
    Delete the rule:
    ```
    cimport_key
        <- 'include' / IDENTIFIER
    ```
    This workaround existed because `include` was a keyword and wouldn't match as IDENTIFIER. With `include` no longer a keyword, plain IDENTIFIER handles all cimport keys.

    **Line 62 — Update `cimport_entry` to use IDENTIFIER directly:**
    Change:
    ```
    cimport_entry
        <- cimport_key ':' _ expr
    ```
    To:
    ```
    cimport_entry
        <- IDENTIFIER ':' _ expr
    ```

    **Line 66 — Rename 'include' to 'use' in import_decl:**
    Change:
    ```
     / 'include' import_path NL
    ```
    To:
    ```
     / 'use' import_path NL
    ```

    **Line 600 — Update keyword comment list:**
    Change `include` to `use` in the keyword list comment.

    **builder.zig follow-up** — After removing `cimport_key` rule, update builder.zig:
    - The `cimport_entry` children structure changes: `cimport_key_cap` (which matched rule "cimport_key") becomes a plain IDENTIFIER capture. The `tokenText(ctx, child.children[0].start_pos)` call on line 475 should still work since it reads the token text at the start position regardless of rule name. Verify this by checking that `child.children[0]` still correctly captures the key token position.
    - If the capture tree child at index 0 previously had `rule = "cimport_key"` and the code doesn't filter by rule name, no builder change is needed for this part.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && zig build 2>&1 | head -20</automated>
  </verify>
  <done>PEG grammar uses 'use' keyword, cimport_key workaround removed, cimport_entry uses plain IDENTIFIER</done>
</task>

<task type="auto">
  <name>Task 3: Update example module, docs, and run full test suite</name>
  <files>
    src/templates/example/example.orh
    docs/COMPILER.md
    docs/TODO.md
  </files>
  <action>
    **src/templates/example/example.orh** (3 changes on lines 11-13):
    - Line 11: change comment from `// include —` to `// use —`
    - Line 12: update comment to reference `use` instead of `include`
    - Line 13: change `include std::collections` to `use std::collections`
    - Lines 55-58 reference `include:` as a *cimport key* — do NOT change these

    **docs/COMPILER.md** (2 changes):
    - Line 57: change `import`/`include` to `import`/`use`
    - Line 59: change `include std::collections` to `use std::collections`

    **docs/TODO.md** (2 changes):
    - Line 530: change section title from `` `include` vs `import` `` to `` `use` vs `import` ``
    - Line 532: change "No dedicated section explaining the difference. `include` brings names into current" — update `include` to `use`

    **Files that do NOT need changes:**
    - docs/14-zig-bridge.md — all `include` references are about the `include:` cimport key, not the keyword
    - docs/07-control-flow.md line 134 — "include a guard expression" is English prose, not about the keyword
    - docs/08-error-handling.md line 54 — "include `else`" is English prose, not about the keyword
    - test/fixtures/*.orh — no fixtures use the `include` keyword (grep confirmed)
    - Tamga framework — only uses `include:` as a cimport key, no keyword usage

    **Run full test suite** to verify nothing broke.
  </action>
  <verify>
    <automated>cd /home/yunus/Projects/orhon/orhon_compiler && ./testall.sh 2>&1 | tail -30</automated>
  </verify>
  <done>All docs and templates updated, full test suite passes with 0 failures</done>
</task>

</tasks>

<verification>
1. `zig build` compiles without errors
2. `./testall.sh` passes all 11 test stages
3. `grep -r "kw_include" src/` returns zero matches
4. `grep -rn "\"include\"" src/lexer.zig src/peg/token_map.zig src/lsp.zig` returns zero matches (only builder.zig should still have "include" for cimport key handling)
5. `grep "'include'" src/orhon.peg` returns zero matches
6. `grep "include" src/templates/example/example.orh` only shows cimport-related references (lines 55-58), not the keyword
</verification>

<success_criteria>
- `use` is a keyword; `include` is no longer a keyword
- `use mymodule` works identically to how `include mymodule` used to work
- `#cimport = { name: "lib", include: "header.h" }` still works (include is a plain identifier key now, not a keyword)
- `cimport_key` grammar rule is removed (no longer needed)
- All 11 test stages pass
- Example module and docs reference `use` not `include`
</success_criteria>
