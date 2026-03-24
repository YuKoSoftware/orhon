# Phase 3: LSP Hardening — Research

**Researched:** 2026-03-24
**Domain:** Zig LSP server memory safety — arena allocators, dynamic buffers, request bounds
**Confidence:** HIGH

## Summary

Phase 3 addresses three targeted hardening concerns in `src/lsp.zig`. The problems are
well-scoped: one memory-growth issue (runAnalysis leaks per-request allocations into the
long-lived allocator), one buffer-truncation issue (1024-byte fixed header line buffer),
and one OOM-safety issue (no upper bound on content-length before allocating the body).

All three fixes are surgical, localised to `readMessage()` and `runAnalysis()`, and require
no cross-file changes. The Zig 0.15 ArenaAllocator API is already used extensively in the
codebase (codegen.zig, declarations.zig, mir.zig, module.zig) so the pattern is established.

The critical subtlety for LSP-01 is that `runAnalysis()` returns an `AnalysisResult` whose
slices (`diagnostics`, `symbols`) contain heap-allocated strings. These results must survive
the analysis arena — they must be duplicated into the long-lived allocator before the arena
is freed, or the arena must not be freed until the caller is done with them. The existing
`freeDiagnostics` / `freeSymbols` functions already expect the long-lived allocator, so the
correct approach is: run analysis in a scratch arena, but dupe the returned slices and all
their string fields into the long-lived allocator before returning from `runAnalysis()`.

**Primary recommendation:** Introduce a per-request `ArenaAllocator` inside `runAnalysis()`
for all intermediate allocations (passes 4–9, reporter, mod_resolver, etc.), dupe the final
`diagnostics` and `symbols` arrays into the passed-in `allocator` before returning, and free
the arena on function exit. Separately: replace the 1024-byte stack buffer in `readMessage()`
with a compile-time constant `MAX_HEADER_LINE = 4096` and add a `MAX_CONTENT_LENGTH` guard
before calling `readAlloc`.

## Project Constraints (from CLAUDE.md)

- All compiler source is Zig 0.15.2+ — no third-party dependencies
- `./testall.sh` is the gate — 11 test stages must all pass
- No hacky workarounds — clean fixes only
- New functionality should come with focused tests
- Each doc file has one specific purpose — do not create new docs unless needed
- Recursive functions need `anyerror!` not `!`

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| LSP-01 | Wrap `runAnalysis()` in per-request ArenaAllocator to prevent unbounded memory growth | ArenaAllocator init/deinit pattern, result-duplication strategy |
| LSP-02 | Replace fixed 1024-byte header line buffer in `readMessage()` with dynamic allocation or larger compile-time constant | Zig 0.15 Reader API, stack vs heap tradeoffs for short-lived buffers |
| LSP-03 | Add upper bound on content-length header to prevent OOM from malicious or oversized requests | Guard pattern before `readAlloc`, appropriate limit value |
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `std.heap.ArenaAllocator` | Zig 0.15.2 | Per-request scratch allocation pool; freed atomically | Already used in codegen, declarations, mir, module |
| `std.mem.Allocator` | Zig 0.15.2 | Long-lived allocator passed in from `serve()` | Unchanged — still used for results that outlive analysis |

### Supporting

None required — this is a refactor within existing stdlib usage.

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Compile-time constant `MAX_HEADER_LINE = 4096` | Dynamic alloc with `ArrayList` | Dynamic is technically unlimited but adds allocator param to a function that currently needs none for headers; a 4096-byte stack buffer is more than sufficient for any real LSP header |
| Dup results into long-lived allocator | Keep arena alive and return arena alongside result | Keeping the arena alive leaks state — caller must manage two lifetimes; dup-and-free is cleaner |

## Architecture Patterns

### LSP-01: Per-request Arena in runAnalysis()

**What:** Create an `ArenaAllocator` at the top of `runAnalysis()`, backed by the passed-in
`allocator`. Pass `arena.allocator()` to all internal operations (reporter, mod_resolver,
passes 4–9, intermediate symbol arrays). Before returning, dupe the final `diagnostics` and
`symbols` slices — and all their inner strings — into the original `allocator`.

**When to use:** Any function that is called in a loop, does significant allocation, and whose
callers free its return value with separate `free` calls on known fields.

**Pattern already established in this codebase:**

```zig
// Source: src/codegen.zig:3722, src/declarations.zig:405
var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
const a = arena.allocator();
```

**Adapted for runAnalysis:**

```zig
fn runAnalysis(allocator: std.mem.Allocator, project_root: []const u8) !AnalysisResult {
    // Scratch arena for all analysis passes — freed before return
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    // ... existing logic but using `a` for all internal allocations ...

    // Dupe results into the long-lived allocator before arena is freed
    const diags = try dupeDiagnostics(allocator, raw_diags);
    const syms  = try dupeSymbols(allocator, raw_syms);
    return .{ .diagnostics = diags, .symbols = syms };
}
```

**Key invariant:** `freeDiagnostics(allocator, ...)` and `freeSymbols(allocator, ...)` in
`serve()` use the long-lived `allocator`, so duped results must be allocated with that
same `allocator`.

### LSP-02: Replace Fixed 1024-byte Header Buffer

**Current code (src/lsp.zig:36):**

```zig
var line_buf: [1024]u8 = undefined;
```

**Problem:** If a header line exceeds 1023 bytes (possible with very long file URIs in
Content-Type or future headers), the inner while loop silently truncates the line — it stops
reading at `line_buf.len` but does not consume the remaining bytes, leaving the stream in a
corrupt state.

**Fix:** Increase to a compile-time constant:

```zig
const MAX_HEADER_LINE: usize = 4096;
// ...
var line_buf: [MAX_HEADER_LINE]u8 = undefined;
```

4096 bytes is sufficient for any plausible LSP header (LSP spec is text-based, headers are
short by protocol design). A stack buffer remains appropriate here — no heap allocation
needed, function is called per-message.

**Alternative: detect truncation** — add a truncation check after the inner while loop and
return `error.HeaderTooLong` if `line_len == line_buf.len` and the stream byte was not `\r`.
This prevents silent corruption regardless of buffer size.

### LSP-03: Content-Length Upper Bound Guard

**Current code (src/lsp.zig:59):**

```zig
return reader.readAlloc(allocator, content_length) catch return error.EndOfStream;
```

**Problem:** A header claiming `Content-Length: 10000000000` causes `allocator.alloc` to
attempt a multi-GB allocation. `std.heap.GeneralPurposeAllocator` may return `OutOfMemory`
(propagated as an error) but the attempt may still trigger OOM-kill on memory-constrained
systems or leak partially-committed pages.

**Fix:** Add a guard before `readAlloc`:

```zig
const MAX_CONTENT_LENGTH: usize = 64 * 1024 * 1024; // 64 MiB
// ...
if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader;
return reader.readAlloc(allocator, content_length) catch return error.EndOfStream;
```

**Limit rationale:** The LSP spec has no hard limit on message size, but real editors send
JSON payloads well under 1 MiB even for large files. 64 MiB provides ample headroom for
pathological cases while still preventing runaway allocation. The constant should be
defined at module scope (or near `readMessage`) so it is easily auditable.

### Anti-Patterns to Avoid

- **Passing arena allocator to `toDiagnostics` / `extractSymbols` without duping results:**
  `toDiagnostics` allocates `d.uri` and `d.message` strings. If those are allocated in the
  scratch arena and returned as `AnalysisResult.diagnostics`, they become dangling pointers
  after `arena.deinit()`. Always dupe strings into the long-lived allocator before the arena
  is freed.

- **Using `arena.reset(.free_all)` in a loop instead of deinit:** `reset` is appropriate
  when the arena is a loop-level variable. Here the arena is a function-local variable;
  `defer arena.deinit()` is the correct pattern, consistent with the rest of the codebase.

- **Changing `serve()`'s allocator parameter:** The long-lived allocator in `serve()` must
  remain unchanged. Only `runAnalysis()` gets the scratch arena internally.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Bulk-free analysis allocations | Manual tracking of every allocation to free | `std.heap.ArenaAllocator` | Impossible to get right manually across passes 4–9; codebase already uses this pattern |
| Dynamic header line buffer | Custom `ArrayList`-based line reader | Larger compile-time constant | Heap allocation unnecessary for bounded headers; constant is simpler, safer |

**Key insight:** ArenaAllocator is the Zig idiom for scoped allocation. The codebase already
demonstrates this pattern in five separate files — the planner just needs to apply it to
`runAnalysis()`.

## Common Pitfalls

### Pitfall 1: Arena-allocated strings returned as AnalysisResult fields

**What goes wrong:** `toDiagnostics(a, ...)` and `dupeSymbols` allocate strings. If `a` is
the scratch arena allocator, those strings are freed when the arena is deinitialized.
Callers in `runAndPublishWithDiags` then use dangling pointers.

**Why it happens:** `runAnalysis` returns `AnalysisResult` which is a struct of slices, not
a resource holder — the caller owns the slices and frees them later.

**How to avoid:** Call `toDiagnostics(allocator, ...)` and `extractSymbols` with the
long-lived `allocator`, not the scratch arena's allocator. Only intermediate pass objects
(reporter, mod_resolver, dc, tr, oc, bc, tc, prop_checker, order slice) use the scratch arena.

**Warning signs:** Zig's `std.testing.allocator` (GeneralPurposeAllocator in debug mode)
will detect use-after-free and double-free in tests if the duplication boundary is wrong.

### Pitfall 2: Header stream corruption on truncation

**What goes wrong:** The inner while loop in `readMessage` exits when `line_len == line_buf.len`
without consuming the rest of the line. The next call to `takeByte` reads mid-header, not
at a line start, corrupting the header parse state for subsequent messages.

**Why it happens:** The loop condition is `line_len < line_buf.len`, so when the buffer fills
up the loop exits silently as if the line ended.

**How to avoid:** Either size the buffer large enough (4096 covers all real cases), or add an
explicit check: if `line_len == line_buf.len` and the next byte is not `\r`, return
`error.HeaderTooLong`.

### Pitfall 3: content_length == 0 check placed after the new guard

**What goes wrong:** The guard `if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader`
must come after `content_length` is parsed but it naturally reads before the existing
`if (content_length == 0) return error.InvalidHeader` check.

**How to avoid:** Place both checks together after the header-reading loop for clarity:

```zig
if (content_length == 0) return error.InvalidHeader;
if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader;
```

## Code Examples

### Existing ArenaAllocator pattern (already in codebase)

```zig
// Source: src/codegen.zig:3722
var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
const a = arena.allocator();
```

### readMessage with MAX_HEADER_LINE and MAX_CONTENT_LENGTH guards

```zig
// Proposed pattern for src/lsp.zig readMessage()
const MAX_HEADER_LINE: usize = 4096;
const MAX_CONTENT_LENGTH: usize = 64 * 1024 * 1024; // 64 MiB

fn readMessage(reader: *Io.Reader, allocator: std.mem.Allocator) ![]u8 {
    var content_length: usize = 0;

    while (true) {
        var line_buf: [MAX_HEADER_LINE]u8 = undefined;
        var line_len: usize = 0;

        while (line_len < line_buf.len) {
            const byte = reader.takeByte() catch return error.EndOfStream;
            if (byte == '\r') {
                _ = reader.takeByte() catch return error.EndOfStream;
                break;
            }
            line_buf[line_len] = byte;
            line_len += 1;
        }

        const line = line_buf[0..line_len];
        if (line.len == 0) break;

        const prefix = "Content-Length: ";
        if (std.mem.startsWith(u8, line, prefix)) {
            content_length = std.fmt.parseInt(usize, line[prefix.len..], 10) catch return error.InvalidHeader;
        }
    }

    if (content_length == 0) return error.InvalidHeader;
    if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader;
    return reader.readAlloc(allocator, content_length) catch return error.EndOfStream;
}
```

### Duplication helpers for AnalysisResult

```zig
// Allocate diagnostics into long-lived allocator — called just before arena deinit
fn dupeDiagnostics(allocator: std.mem.Allocator, src: []Diagnostic) ![]Diagnostic {
    const out = try allocator.alloc(Diagnostic, src.len);
    for (src, 0..) |d, i| {
        out[i] = .{
            .uri     = try allocator.dupe(u8, d.uri),
            .message = try allocator.dupe(u8, d.message),
            .line    = d.line,
            .col     = d.col,
            .severity = d.severity,
        };
    }
    return out;
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| One global allocator for all LSP operations | Per-request arena for analysis, long-lived allocator for results | This phase | Prevents accumulation of orphaned analysis allocations |
| Fixed 1024-byte stack buffer | Larger compile-time constant (4096) | This phase | Eliminates header truncation risk |
| Unbounded content-length allocation | Upper bound check before alloc | This phase | Prevents OOM from malformed requests |

## Open Questions

1. **Should `toDiagnostics` allocate into the long-lived allocator or into the arena?**
   - What we know: Currently called as `toDiagnostics(allocator, ...)` where `allocator` is
     the long-lived one passed to `runAnalysis`. Results are freed by `freeDiagnostics` in
     `serve()` with the same `allocator`.
   - What's unclear: If the arena wraps the long-lived allocator, and we pass
     `arena.allocator()` to `toDiagnostics`, the strings get arena-allocated and are freed
     when the arena deinits — before the caller uses them.
   - Recommendation: Keep `toDiagnostics(allocator, ...)` and `extractSymbols(..., allocator, ...)`
     using the original long-lived `allocator` for their string allocations. Only the pass
     objects (dc, tr, oc, etc.) use the scratch arena.

2. **What is `Diagnostic.severity` type?**
   - Not blocking — `dupeDiagnostics` copies the full struct; planner can verify field list
     from `src/lsp.zig:193`.

## Environment Availability

Step 2.6: SKIPPED (no external dependencies — all changes are within Zig source, no new tools or services required).

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks |
| Config file | none (uses `zig build test`) |
| Quick run command | `zig build test 2>&1 \| grep -A3 "lsp\|FAIL\|PASS"` |
| Full suite command | `./testall.sh` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| LSP-01 | `runAnalysis()` arena is freed — no allocation growth across calls | unit | `zig build test 2>&1 \| grep "lsp"` | ❌ Wave 0 |
| LSP-02 | Header lines up to 4095 bytes parse correctly; no truncation | unit | `zig build test 2>&1 \| grep "lsp"` | ❌ Wave 0 |
| LSP-03 | Content-Length exceeding limit returns `error.InvalidHeader` | unit | `zig build test 2>&1 \| grep "lsp"` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `zig build test 2>&1 | grep -E "FAIL|error|lsp"`
- **Per wave merge:** `./testall.sh`
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] Test in `src/lsp.zig` — `readMessage` with long header line (>1024, <=4096) — covers LSP-02
- [ ] Test in `src/lsp.zig` — `readMessage` with oversized content-length — covers LSP-03
- [ ] Test in `src/lsp.zig` — arena deinit does not corrupt returned diagnostics/symbols — covers LSP-01 (can use `std.testing.allocator` which detects leaks + dangling pointers)

Existing test `"readMessage parses LSP header"` (line 3150) already passes — new tests extend it.

## Sources

### Primary (HIGH confidence)

- `/usr/lib/zig/std/heap/arena_allocator.zig` — ArenaAllocator.init, deinit, reset, allocator() API verified directly from Zig 0.15.2 stdlib
- `/usr/lib/zig/std/Io/Reader.zig` — readAlloc(allocator, len), takeByte() signatures verified from Zig 0.15.2 stdlib
- `src/lsp.zig` (lines 29–60, 440–593, 1241–1294, 3150–3156) — current implementation read directly

### Secondary (MEDIUM confidence)

- `src/codegen.zig:3722`, `src/declarations.zig:405–407`, `src/mir.zig:827` — existing ArenaAllocator usage patterns in this codebase, confirmed by direct read

### Tertiary (LOW confidence)

- None — all claims verified from source or stdlib

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — ArenaAllocator API verified from Zig 0.15.2 stdlib source
- Architecture: HIGH — current code read directly; patterns observed in 5 other codebase files
- Pitfalls: HIGH — string lifetime pitfall derived from direct reading of freeDiagnostics/freeSymbols callers

**Research date:** 2026-03-24
**Valid until:** 2026-06-24 (stable Zig stdlib API; 90-day validity)
