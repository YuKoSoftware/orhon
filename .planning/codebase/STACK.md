# Technology Stack

**Analysis Date:** 2026-03-24

## Languages

**Primary:**
- Zig 0.15.2+ — all compiler source (`src/*.zig`, `src/peg/*.zig`, `src/std/*.zig`)
- Orhon (`.orh`) — stdlib bridge declarations (`src/std/*.orh`), example module (`src/templates/`), test fixtures (`test/fixtures/`)

**Secondary:**
- JavaScript — VS Code extension client (`editors/vscode/extension.js`)
- Shell (bash) — test runner scripts (`test/*.sh`, `testall.sh`)

## Runtime

**Environment:**
- Native binary — no managed runtime; compiles to native via Zig backend
- Target platforms: linux_x64, linux_arm, win_x64, mac_x64, mac_arm, wasm32-freestanding

**Package Manager:**
- Zig build system (no external package manager; `build.zig.zon` declares no dependencies)
- Lockfile: not applicable (zero external Zig dependencies)
- VS Code extension: npm (`editors/vscode/package-lock.json` present)

## Frameworks

**Core:**
- Zig standard library only — no third-party Zig dependencies declared in `build.zig.zon`
- PEG parsing engine — custom implementation in `src/peg/` (grammar.zig, engine.zig, capture.zig, builder.zig, token_map.zig)

**Testing:**
- Zig built-in `test` blocks — run via `zig build test`
- Shell-based integration tests — `test/01_unit.sh` through `test/11_errors.sh`

**Build/Dev:**
- `zig build` — compiler and fuzz binary
- `zig build test` — all unit test blocks across all source files
- `zig build fuzz` — runs `src/fuzz.zig` random input fuzzer
- `./testall.sh` — full pipeline test suite

## Key Dependencies

**Critical:**
- Zig 0.15.2 (system-installed or co-located binary) — the single backend; all cross-compilation, linking, and optimization is delegated to Zig. Discovered at runtime via: 1) same directory as `orhon` binary, 2) global PATH. See `src/zig_runner.zig`.

**Infrastructure:**
- `std.http.Client` (Zig stdlib) — HTTP GET/POST in `src/std/http.zig`
- `std.net` (Zig stdlib) — TCP client/server in `src/std/net.zig`
- `std.json` (Zig stdlib) — JSON parse/build in `src/std/json.zig`
- `std.compress.gzip` (Zig stdlib) — compression in `src/std/compression.zig`
- `std.crypto` (Zig stdlib) — SHA256/512, MD5, Blake3, HMAC, AES-GCM in `src/std/crypto.zig`

**VS Code Extension:**
- `vscode-languageclient` ^9.0.1 — LSP client wrapper (`editors/vscode/`)
- `@vscode/vsce` ^3.0.0 (devDep) — extension packaging

## Configuration

**Environment:**
- No `.env` files — compiler has no runtime environment variable requirements
- Version is baked in at compile time via `build.zig` `addOptions` / `build_options` import
- Current version: `0.9.3` (defined in `build.zig`; `build.zig.zon` shows `0.8.3` and may be stale)

**Build:**
- `build.zig` — defines `exe`, `test`, and `fuzz` steps; injects version string as comptime option
- `build.zig.zon` — package manifest; minimum Zig version `0.15.2`; zero external dependencies

**Incremental Cache:**
- Stored in `.orh-cache/` (gitignored) — timestamps, dependency graph, generated `.zig` files
- Constants in `src/cache.zig`: `CACHE_DIR`, `GENERATED_DIR`, `TIMESTAMPS_FILE`, `DEPS_FILE`, `WARNINGS_FILE`

## Platform Requirements

**Development:**
- Zig 0.15.2+ installed globally
- No other toolchain dependencies for the compiler itself
- Node.js / npm required only for building the VS Code extension

**Production:**
- Self-contained native binary (`zig-out/bin/orhon`)
- Zig binary must be co-located with or accessible on PATH at runtime (for code generation step)
- Cross-compilation supported: linux_x64, linux_arm, win_x64, mac_x64, mac_arm, wasm

---

*Stack analysis: 2026-03-24*
