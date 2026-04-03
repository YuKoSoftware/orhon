# Module Naming Redesign — Remove `module main`

**Date:** 2026-03-31
**Version target:** v0.14.0

## Problem

The current convention uses `module main` as the entry point module for executable projects. This creates naming collisions — `func main()` inside `module main` requires grammar-level workarounds (`kw_main` keyword, `func_name <- IDENTIFIER / 'main'`) to avoid conflicts. It's also not ergonomic: the module name carries no project identity.

## Design

### Core Rule: Project Name = Primary Module Name

The primary executable module is identified by its module name matching the **project folder name**. No more `module main`.

- `orhon init myproj` → creates `src/myproj.orh` with `module myproj`
- `orhon init` (no name, in-place) → uses current folder name as module name
- The anchor file of this module must contain `func main()`

**Example — before:**
```
myproj/
  src/
    main.orh        ← module main, #build = exe
```

**Example — after:**
```
myproj/
  src/
    myproj.orh      ← module myproj, #build = exe
```

### Primary Module Detection

A module is the **primary** module when:

1. It has `#build = exe`
2. Its module name matches the project's top-level folder name
3. Its anchor file is directly in `src/` (not nested in a subdirectory)

`orhon run` always runs the primary module's binary. Other `#build = exe` modules produce executables but are not the `orhon run` target.

### Project Layout Rules

- The **primary exe module's anchor file must be in `src/` top-level** — not in a subdirectory. This gives a predictable, obvious location for the project entry point.
- **No other `#build = exe` anchor files are allowed in `src/` top-level.** Secondary executable modules must place their anchor files in subdirectories.
- Library modules (`#build = static|dynamic` or no `#build`) are unrestricted — they can live anywhere.

```
myproj/
  src/
    myproj.orh          ← primary exe (only #build = exe allowed at top level)
    utils.orh           ← module utils (library, fine here)
    tools/
      codegen_tool.orh  ← module codegen_tool, #build = exe (allowed, nested)
```

If a non-primary `#build = exe` anchor file is found directly in `src/`, the compiler reports:
`"only the primary module '{primary}' may use #build = exe in src/ — move '{other}' to a subdirectory"`

### `main` as Reserved Entry Point Name

`main` stops being a keyword in the grammar. Instead, the compiler enforces semantic rules:

- **`func main()`** — valid only inside the anchor file of a `#build = exe` module
- **`main` as any other identifier** — variable, struct, enum, module name → compile error
- **Every `#build = exe` module** must have exactly one `func main()` in its anchor file

This replaces the current `kw_main` token kind and grammar special-casing with a clean semantic check.

### `orhon run` Behavior

- Runs the **primary** module's binary (module name == folder name)
- If no primary module exists (e.g., library-only project) → error: "no primary executable module"
- Non-primary exe modules still compile to binaries in `bin/`, users run them directly

## Changes Required

### Grammar (`src/peg/orhon.peg`)

Remove `'main'` alternatives from three rules:

```peg
# Before:
module_decl <- doc_block? 'module' (IDENTIFIER / 'main') NL
scoped_name <- (IDENTIFIER / 'main') '::' IDENTIFIER
func_name   <- IDENTIFIER / 'main'

# After:
module_decl <- doc_block? 'module' IDENTIFIER NL
scoped_name <- IDENTIFIER '::' IDENTIFIER
func_name   <- IDENTIFIER
```

### Lexer (`src/lexer.zig`)

- Remove `kw_main` from `TokenKind` enum
- Remove `"main"` → `.kw_main` from keyword table
- `main` becomes a regular `.identifier` token

### PEG token map (`src/peg/token_map.zig`)

- Remove `"main"` → `.kw_main` mapping

### PEG builder (`src/peg/builder_decls.zig`)

- Remove `.kw_main` fallback in function name extraction (line 72, 93)
- `main` will now arrive as `.identifier` naturally

### LSP semantic tokens (`src/lsp/lsp_semantic.zig`)

- Remove `.kw_main` from keyword token list

### Semantic validation (new checks)

Add validation in the appropriate pass (declarations or sema):

1. **`main` is reserved** — if any declaration (variable, struct, enum, module) uses the name `main`, report an error: `"'main' is reserved for the executable entry point"`
2. **exe modules need `func main()`** — if a module has `#build = exe` but no `func main()` in its anchor file, report an error: `"executable module '{name}' requires func main() in anchor file"`
3. **`func main()` only in exe modules** — if a non-exe module declares `func main()`, report an error: `"func main() is only allowed in executable modules"`
4. **Primary exe must be in `src/` top-level** — if the primary module's anchor file is in a subdirectory, report an error: `"primary module '{name}' anchor file must be directly in src/"`
5. **No other `#build = exe` in `src/` top-level** — if a non-primary module has `#build = exe` and its anchor file is directly in `src/`, report an error: `"only the primary module '{primary}' may use #build = exe in src/ — move '{other}' to a subdirectory"`

### Init scaffolding (`src/init.zig`)

- Template file renamed: `src/templates/main.orh` → `src/templates/project.orh`
- Template content changes `module main` → `module {s}` (uses project name placeholder, which already exists for `#name`)
- Output file: `src/{project_name}.orh` instead of `src/main.orh`
- Update success messages to show new file name

Template becomes:
```orh
module {s}

#name    = "{s}"
#version = (1, 0, 0)
#build   = exe

import std::console

func main() void {
    console.println("hello orhon !")
}
```

Note: template now has two `{s}` placeholders (module name and `#name`), both replaced with the project name. The split-write approach needs to handle multiple placeholders.

### Codegen (`src/codegen/codegen_decls.zig`)

- Keep the existing `func main()` → forced `pub` logic (lines 131, 375) — this is correct and still needed
- No other changes; codegen doesn't care about module naming

### Pipeline (`src/pipeline.zig`)

- Primary module detection: compare module name against project folder name
- `orhon run` target: use the primary module's binary, not "first exe found"
- Default fallback `"main"` at line 403 → derive from folder name instead

### Zig runner tests

- Update test strings that use `"main"` as module name to use project-style names

### Test fixtures

- All test fixtures using `module main` → update to use project-appropriate names
- `orhon init` tests → verify new file naming

### Documentation

- Update `docs/` files referencing `module main`
- Update example module if it references `module main` patterns

## What Does NOT Change

- `func main()` remains the entry point function name — Zig requires `pub fn main()`
- `#build = exe|static|dynamic` metadata system unchanged
- Multi-target builds unchanged — multiple `#build` modules still work
- Module resolution, anchor file rules, dependency ordering all unchanged
- `#name` still controls the output binary name, falling back to module name

## Migration

Existing projects with `module main` will get a compile error. The fix is straightforward:

1. Rename `src/main.orh` → `src/{project_folder_name}.orh`
2. Change `module main` → `module {project_folder_name}`

This is a breaking change, appropriate for a minor version bump.
