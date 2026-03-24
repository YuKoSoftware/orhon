---
phase: 03-lsp-hardening
verified: 2026-03-24T19:00:00Z
status: passed
score: 7/7 must-haves verified
re_verification: false
---

# Phase 3: LSP Hardening Verification Report

**Phase Goal:** The language server runs without unbounded memory growth and rejects oversized input safely
**Verified:** 2026-03-24T19:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| #  | Truth                                                                                    | Status     | Evidence                                                                                            |
|----|------------------------------------------------------------------------------------------|------------|-----------------------------------------------------------------------------------------------------|
| 1  | Header lines up to 4095 bytes parse correctly without truncation                         | VERIFIED   | `line_buf: [MAX_HEADER_LINE]u8` at line 39; `MAX_HEADER_LINE = 4096` at line 29                    |
| 2  | Content-Length exceeding 64 MiB returns error.InvalidHeader                              | VERIFIED   | Guard at line 63: `if (content_length > MAX_CONTENT_LENGTH) return error.InvalidHeader`            |
| 3  | Existing readMessage test still passes                                                   | VERIFIED   | `zig build test` exits 0; test at line 3162 present and unmodified                                 |
| 4  | A long editing session does not cause unbounded LSP memory growth                        | VERIFIED   | `var scratch = std.heap.ArenaAllocator.init(allocator); defer scratch.deinit()` at lines 466-467   |
| 5  | Memory used by the analysis pipeline is released after each request                      | VERIFIED   | All 8 pass objects (reporter, mod_resolver, dc, tr, oc, bc, tc, prop_checker) use `a` (scratch)   |
| 6  | Returned diagnostics and symbols survive arena deinitialization                          | VERIFIED   | All `toDiagnostics(allocator, ...)` and `extractSymbols(allocator, ...)` use the long-lived alloc  |
| 7  | freeDiagnostics and freeSymbols still work correctly with the long-lived allocator       | VERIFIED   | Tests at lines 3274 and 3291 call freeDiagnostics/freeSymbols; `zig build test` exits 0           |

**Score:** 7/7 truths verified

### Required Artifacts

| Artifact      | Expected                                                          | Status     | Details                                                                                       |
|---------------|-------------------------------------------------------------------|------------|-----------------------------------------------------------------------------------------------|
| `src/lsp.zig` | readMessage with MAX_HEADER_LINE and MAX_CONTENT_LENGTH guards    | VERIFIED   | Constants at lines 29-30, buffer at line 39, HeaderTooLong at line 51, guard at line 63      |
| `src/lsp.zig` | runAnalysis with per-request ArenaAllocator and unit tests        | VERIFIED   | ArenaAllocator at lines 466-468, arena used for all 8 pass objects (lines 473-588)            |

### Key Link Verification

**Plan 03-01 key links:**

| From           | To                   | Via                                | Status   | Details                                                              |
|----------------|----------------------|------------------------------------|----------|----------------------------------------------------------------------|
| `readMessage`  | `MAX_CONTENT_LENGTH` | guard check before readAlloc       | WIRED    | Line 63: `if (content_length > MAX_CONTENT_LENGTH) return error...` |
| `readMessage`  | `MAX_HEADER_LINE`    | buffer declaration                 | WIRED    | Line 39: `var line_buf: [MAX_HEADER_LINE]u8 = undefined`            |
| `readMessage`  | `HeaderTooLong`      | buffer-full truncation detection   | WIRED    | Line 51: `if (line_len == line_buf.len) return error.HeaderTooLong` |

**Plan 03-02 key links:**

| From              | To                         | Via                               | Status   | Details                                                              |
|-------------------|----------------------------|-----------------------------------|----------|----------------------------------------------------------------------|
| `runAnalysis`     | `std.heap.ArenaAllocator`  | scratch arena for passes 4-9     | WIRED    | Lines 466-468: `var scratch = std.heap.ArenaAllocator.init(alloc)`  |
| `toDiagnostics`   | `allocator`                | long-lived allocator, not scratch | WIRED    | All 5 call sites (lines 482, 487, 494, 520, 593) use `allocator`   |
| `extractSymbols`  | `allocator`                | long-lived allocator, not scratch | WIRED    | Both call sites (lines 546, 558) use `allocator`                    |

### Data-Flow Trace (Level 4)

These artifacts are transport/memory management functions, not data-rendering components. Level 4 data-flow trace is not applicable — no dynamic data is rendered to a UI. The relevant data flow (diagnostics from reporter, symbols from AST) is verified through the key link checks and unit tests above.

### Behavioral Spot-Checks

| Behavior                                              | Command                                          | Result                          | Status  |
|-------------------------------------------------------|--------------------------------------------------|---------------------------------|---------|
| All unit tests pass including new LSP hardening tests | `zig build test`                                 | Exit code 0, 0 FAIL lines       | PASS    |
| readMessage rejects 100 MiB content-length            | Covered by unit test at line 3170                | Test passes with `zig build test`| PASS   |
| readMessage accepts valid 2-byte payload              | Covered by unit test at line 3178                | Test passes with `zig build test`| PASS   |
| runAnalysis arena does not leak or corrupt data       | Covered by unit test at line 3274                | Test passes with `zig build test`| PASS   |
| runAnalysis can be called twice without accumulation  | Covered by unit test at line 3291                | Test passes with `zig build test`| PASS   |

### Requirements Coverage

| Requirement | Source Plan | Description                                                                          | Status    | Evidence                                                                      |
|-------------|-------------|--------------------------------------------------------------------------------------|-----------|-------------------------------------------------------------------------------|
| LSP-01      | 03-02       | Wrap runAnalysis() in per-request ArenaAllocator to prevent unbounded memory growth  | SATISFIED | ArenaAllocator at lines 466-468; 8 pass objects use scratch arena             |
| LSP-02      | 03-01       | Replace fixed 1024-byte header buffer with larger compile-time constant              | SATISFIED | `MAX_HEADER_LINE = 4096` at line 29; buffer at line 39 uses constant          |
| LSP-03      | 03-01       | Add upper bound on content-length to prevent OOM                                     | SATISFIED | `MAX_CONTENT_LENGTH = 64 MiB` at line 30; guard at line 63                   |

No orphaned requirements — all three LSP phase requirements (LSP-01, LSP-02, LSP-03) are claimed by plans and verified in the codebase.

### Anti-Patterns Found

No blockers or warnings found.

- The `all_symbols` ArrayList backing buffer is correctly freed after dupe (line 600: `all_symbols.deinit(allocator)`). This was a pre-existing leak caught by the unit tests and fixed in commit `b12f11b`.
- No `TODO`, `FIXME`, placeholder comments, or stub return values in the modified code paths.
- No `return null`, `return {}`, or `return []` in newly added code.

### Human Verification Required

#### 1. Long Editing Session Memory Stability

**Test:** Open VS Code with the Orhon extension active. Edit `.orh` files continuously for 10+ minutes, triggering repeated analysis cycles. Monitor the `orhon lsp` process RSS using `watch -n5 'ps -o pid,rss,vsz -p $(pgrep orhon)'`.

**Expected:** RSS remains stable or grows only marginally (within a few MB) across hundreds of analysis cycles. No monotonic growth pattern.

**Why human:** Automated tests use `std.testing.allocator` which detects leaks at the end of a single call, but cannot measure RSS growth across many calls in a live VS Code session with real project files and incremental edits.

### Gaps Summary

No gaps. All must-haves from both plans are verified against actual code. Commit hashes from both SUMMARYs (`2164509`, `edb3a45`, `fc3176d`, `b12f11b`) were confirmed present in the repository. `zig build test` exits 0 with no FAIL lines.

---

_Verified: 2026-03-24T19:00:00Z_
_Verifier: Claude (gsd-verifier)_
