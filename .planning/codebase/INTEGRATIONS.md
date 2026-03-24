# External Integrations

**Analysis Date:** 2026-03-24

## APIs & External Services

**None (compiler runtime):**
- The `orhon` compiler binary itself has no external API dependencies at runtime.
- All integrations described below are part of the **Orhon standard library** — bridge modules that Orhon programs (not the compiler) can use.

## Standard Library Bridge Modules

These live in `src/std/` as `.orh` (interface) + `.zig` (implementation) pairs. They are embedded into every new project via `orhon init`.

**HTTP Client (`src/std/http.zig`, `src/std/http.orh`):**
- Wraps `std.http.Client` (Zig stdlib)
- Operations: GET, POST, URL parsing/building
- No external HTTP library — pure Zig stdlib

**TCP Networking (`src/std/net.zig`, `src/std/net.orh`):**
- Wraps `std.net` (Zig stdlib)
- Operations: `tcpConnect`, `tcpListen`, send/recv/close
- No external networking library

**JSON (`src/std/json.zig`, `src/std/json.orh`):**
- Wraps `std.json` (Zig stdlib)
- Supports dot-path traversal for nested field access
- No external JSON library

**Cryptography (`src/std/crypto.zig`, `src/std/crypto.orh`):**
- Wraps `std.crypto` (Zig stdlib)
- Hash functions: SHA-256, SHA-512, MD5, Blake3
- HMAC-SHA256
- AES-GCM encrypt/decrypt
- No external crypto library

**Compression (`src/std/compression.zig`, `src/std/compression.orh`):**
- Wraps `std.compress.gzip` and `std.compress.zlib` (Zig stdlib)
- Operations: compress, decompress (gzip and zlib)
- No external compression library

**Filesystem (`src/std/fs.zig`, `src/std/fs.orh`):**
- Wraps `std.fs` (Zig stdlib)
- File read/write, directory operations

**System (`src/std/system.zig`, `src/std/system.orh`):**
- Wraps `std.process.Child`
- Spawn subprocesses, capture stdout/stderr, exit code

**TUI (`src/std/tui.zig`, `src/std/tui.orh`):**
- Wraps `std.posix` for terminal raw mode, cursor control, key input
- Targets POSIX systems

**SIMD (`src/std/simd.zig`, `src/std/simd.orh`):**
- Wraps Zig vector builtins (`@reduce`, `@splat`, `@shuffle`)
- F32/F64/I32 vector operations

**Regex (`src/std/regex.zig`, `src/std/regex.orh`):**
- Custom recursive backtracking engine — no external library
- Basic syntax: literals, `.`, character classes, anchors, quantifiers

**Other stdlib modules (pure Zig stdlib wrappers):**
- `src/std/collections.zig` — ArrayList, HashMap, Set
- `src/std/str.zig` — string operations
- `src/std/math.zig` — math functions
- `src/std/sort.zig` — sorting algorithms
- `src/std/time.zig` — time/date
- `src/std/random.zig` — random number generation
- `src/std/stream.zig` — reader/writer streams
- `src/std/encoding.zig` — base64, hex encoding
- `src/std/csv.zig` — CSV parsing/writing
- `src/std/ini.zig` — INI file parsing
- `src/std/toml.zig` — TOML parsing
- `src/std/yaml.zig` — YAML parsing
- `src/std/xml.zig` — XML parsing
- `src/std/allocator.zig` — allocator utilities
- `src/std/linear.orh` — linear algebra (no `.zig` sidecar present)
- `src/std/ziglib.zig` — bridge testbed/example

## Data Storage

**Databases:**
- None — no database driver in compiler or stdlib

**File Storage:**
- Local filesystem only — incremental cache in `.orh-cache/` (managed by `src/cache.zig`)
- Cache files: `.orh-cache/timestamps`, `.orh-cache/deps.graph`, `.orh-cache/generated/*.zig`

**Caching:**
- Custom file-based incremental compilation cache in `src/cache.zig`
- No in-memory or external cache service

## Authentication & Identity

**Auth Provider:**
- None — compiler has no authentication requirements

## Monitoring & Observability

**Error Tracking:**
- None — no external error tracking service

**Logs:**
- Compiler errors written to stderr via `src/errors.zig` (Reporter struct)
- Test output written to `test_log.txt` by `testall.sh`
- No structured logging framework

## CI/CD & Deployment

**Hosting:**
- Not applicable for a compiler binary
- VS Code extension targets VS Code Marketplace (publisher: `YuKoSoftware`)

**CI Pipeline:**
- None detected in repository (no `.github/`, `.gitlab-ci.yml`, etc.)

## Environment Configuration

**Required env vars:**
- None — compiler requires no environment variables at runtime

**Secrets location:**
- No secrets — open source compiler with no cloud service credentials

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

## Language Server Protocol (LSP)

**Transport:** JSON-RPC over stdio (`src/lsp.zig`)
**Client:** VS Code extension via `vscode-languageclient` ^9.0.1 (`editors/vscode/extension.js`)
**Protocol:** LSP (Language Server Protocol) — standard, no proprietary extensions
**Features:** diagnostics, hover, go-to-definition, completion, references, rename, signature help, formatting, document symbols, highlights, folding, inlay hints, code actions, workspace symbol search

## Zig Backend Integration

**Zig Compiler (external process):**
- Invoked as a subprocess by `src/zig_runner.zig`
- Discovery order: 1) same directory as `orhon` binary, 2) system PATH
- Inputs: generated `.zig` files in `.orh-cache/generated/`
- Outputs: native binaries in `zig-out/` or project `bin/`
- Commands used: `zig build`, `zig build-exe`, `zig build-lib`, `zig build-obj`, `zig test`

---

*Integration audit: 2026-03-24*
