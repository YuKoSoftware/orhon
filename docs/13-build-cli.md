# Build System & CLI

Fully integrated into the compiler. No build files ever.

```
orhon build                          // debug build, native platform
orhon build -linux_x64 -fast         // Linux x86-64, max speed
orhon build -linux_arm -small        // Linux ARM64, min binary size
orhon build -win_x64                 // Windows x86-64
orhon build -mac_arm                 // macOS Apple Silicon
orhon build -wasm                    // WebAssembly target
orhon build -linux_x64 -win_x64     // multi-target (outputs to bin/<target>/)
orhon build -zig                     // emit Zig source project to bin/zig/
orhon run                            // build and run
orhon test                           // run all test blocks
orhon build -verbose                 // show raw Zig compiler output
orhon init <name>                    // create a new project in ./<name>/
orhon init                           // init in current dir, use folder name as project name
orhon addtopath                      // add orhon to PATH in your shell profile
orhon debug                          // dump project info: source dir, modules found, files
orhon analysis                       // dump parse tree analysis for debugging
orhon fmt                            // format all .orh files in the project
orhon gendoc                         // generate all docs (api + std + syntax)
orhon gendoc -api                    // project API docs only (docs/api/)
orhon gendoc -std                    // stdlib reference only (docs/std/)
orhon gendoc -syntax                 // syntax reference only (docs/syntax.md)
orhon lsp                            // start language server (JSON-RPC over stdio)
orhon which                          // print path to the orhon binary
orhon version                        // print compiler version
```

---

## Zig Output Suppression

Orhon fully controls what the user sees. The Zig compiler runs silently under the hood — its output is captured and never shown to the user under normal operation.

If Zig compilation succeeds — all Zig output is suppressed. The user only sees Orhon's own output.

If Zig compilation fails due to a codegen bug — Orhon reformats the error in its own clean format. Raw Zig errors are never shown unless `-verbose` flag is explicitly passed.

```
// normal mode — user never sees Zig output
orhon build

// verbose mode — raw Zig output visible
orhon build -verbose
```

In a correctly implemented compiler, Zig errors should never reach the user — all issues are caught by Orhon's analysis passes before code generation. The `-verbose` flag exists purely for debugging the compiler itself during development.

---

## Generated Zig Output — One File per Module

Each Orhon module compiles to exactly one Zig source file. Orhon is essentially a transpiler — its entire job is producing a valid Zig project from Orhon source (see [[COMPILER]] for the full pipeline). Everything after that is Zig's responsibility.

```
.orh source files
    ↓ Orhon compiler (all passes in memory)
.orh-cache/generated/*.zig    ← Orhon's responsibility ends here
    ↓ Zig compiler
zig-cache/                     ← Zig's responsibility (object files, binary)
    ↓
final binary
```

Orhon never deals with object files — that is entirely Zig's concern. Zig has its own cache (`zig-cache/`) where it manages compiled objects and incremental compilation at the binary level.

All generated files live in `.orh-cache/generated/` and should never be edited manually.

```
bin/
    <module_name>        // final binary — named from the module name

.orh-cache/
    generated/
        math.zig        // generated from module math
        player.zig      // generated from module player
        utils.zig       // generated from module utils
        myproj.zig      // generated from module myproj (primary exe module)
        build.zig       // generated Zig build file
    timestamps          // flat text — maps .orh files to last modification time
    deps.graph          // flat text — module dependency graph
```

`timestamps` format:
```
src/player.orh  1710234567
src/utils.orh   1710234123
src/myproj.orh  1710234890
```

`deps.graph` format:
```
myproj → player, math, utils
player → math
math →
utils →
```

Both are plain text — human readable, easy to delete, never committed to version control. `.orh-cache` belongs in `.gitignore`.

Example generated `math.zig`:
```zig
// generated from module math — do not edit
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn divide(a: i32, b: i32) i32 {
    if (b == 0) { /* error handling */ }
    return @divTrunc(a, b);
}
```

Example generated `myproj.zig`:
```zig
// generated from module myproj — do not edit
const std = @import("std");
const math = @import("math.zig");
const player = @import("player.zig");

pub fn main() void {
    const result = math.divide(10, 2);
}
```

---

## Language Server (LSP)

Orhon ships a built-in LSP server for editor integration. Start it with `orhon lsp` —
it communicates over JSON-RPC via stdin/stdout.

### Supported Features

| Feature | Description |
|---------|-------------|
| Diagnostics | Real-time errors and warnings as you type |
| Hover | Type info and definition details on hover |
| Go-to-Definition | Navigate to symbol definitions |
| Find References | Find all usages of a symbol |
| Document Highlight | Highlight all occurrences in current file |
| Completion | Autocomplete with optional snippet support |
| Signature Help | Show function signatures while typing |
| Rename | Refactor symbol names across files |
| Code Actions | Quick fixes for diagnostics |
| Document Symbols | List symbols in current file |
| Workspace Symbols | Search symbols across the project |
| Semantic Tokens | Enhanced syntax highlighting |
| Inlay Hints | Display inferred types (off by default) |
| Folding Ranges | Code folding support |
| Formatting | Format code via LSP |

### How It Works

The LSP runs passes 1–9 (lexer through error propagation) on file changes and caches
results. Passes 10–12 (MIR, codegen, Zig compilation) are not run — no binary is
produced during editing.

### VS Code Extension

Install from the VS Code marketplace (publisher: YuKoSoftware) or build from
`editors/vscode/`.

**Settings:**
- `orhon.lsp.enabled` — enable/disable the language server (default: true)
- `orhon.lsp.path` — path to the `orhon` binary (default: `"orhon"`)
- `orhon.inlayHints.enabled` — show inferred type hints (default: false)
- `orhon.completion.snippets` — insert parameter snippets on completion (default: false)

The extension auto-detects the `orhon` binary from `~/.local/bin`, `/usr/local/bin`,
or `/usr/bin` if not configured explicitly.

---

## Incremental Compilation

Checked at Module Resolution — unchanged modules skip all passes and reuse cached `.zig` files. Works at two levels:
- **Orhon level** — unchanged modules skip passes 4-12 entirely, cached `.zig` file reused
- **Zig level** — Zig's own incremental compilation handles object files and binary caching independently
- Only changed modules and their dependents regenerate `.zig` files
- Orhon cache stored in `.orh-cache/`, Zig cache in `zig-cache/` — separate concerns, no overlap
