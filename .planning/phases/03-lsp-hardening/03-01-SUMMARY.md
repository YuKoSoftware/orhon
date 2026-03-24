---
phase: 03-lsp-hardening
plan: 01
subsystem: lsp
tags: [lsp, json-rpc, transport, hardening, security]

# Dependency graph
requires: []
provides:
  - readMessage with MAX_HEADER_LINE (4096-byte header buffer, up from 1024)
  - readMessage with MAX_CONTENT_LENGTH guard (64 MiB cap)
  - HeaderTooLong error for truncated header lines
  - InvalidHeader guard for oversized content-length
  - Unit tests for oversized content-length rejection and valid content-length acceptance
affects: [03-02-lsp-hardening]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Compile-time constants for transport limits (MAX_HEADER_LINE, MAX_CONTENT_LENGTH)
    - Guard-before-allocate pattern for bounded allocation

key-files:
  created: []
  modified:
    - src/lsp.zig

key-decisions:
  - "MAX_HEADER_LINE = 4096 chosen to cover all realistic LSP header values with room to spare"
  - "MAX_CONTENT_LENGTH = 64 MiB chosen as practical upper bound for LSP payloads"
  - "HeaderTooLong error is a safety net; enlarging from 1024 to 4096 is the primary fix for LSP-02"

patterns-established:
  - "Transport hardening: validate before allocate — check content_length before readAlloc"

requirements-completed: [LSP-02, LSP-03]

# Metrics
duration: 8min
completed: 2026-03-24
---

# Phase 3 Plan 1: LSP readMessage Hardening Summary

**readMessage hardened with 4096-byte header buffer, HeaderTooLong truncation detection, and 64 MiB content-length cap preventing OOM from malicious payloads**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-03-24T18:00:00Z
- **Completed:** 2026-03-24T18:08:00Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- Added `MAX_HEADER_LINE = 4096` and `MAX_CONTENT_LENGTH = 64 MiB` compile-time constants
- Replaced hard-coded 1024-byte header buffer with `MAX_HEADER_LINE` (fixes LSP-02)
- Added `HeaderTooLong` error when header line fills the buffer without a CR terminator
- Added `content_length > MAX_CONTENT_LENGTH` guard before `readAlloc` (fixes LSP-03)
- Added two new unit tests covering oversized content-length rejection and valid payload acceptance

## Task Commits

Each task was committed atomically:

1. **Task 1: Add readMessage hardening constants and guards** - `2164509` (feat)
2. **Task 2: Add unit tests for readMessage hardening** - `edb3a45` (test)

## Files Created/Modified

- `src/lsp.zig` - Added constants, updated header buffer size, added guards, added two unit tests

## Decisions Made

- `MAX_HEADER_LINE = 4096`: Real LSP headers for complex workspace configurations can exceed 1024 bytes. 4096 is generous without being wasteful in stack space.
- `MAX_CONTENT_LENGTH = 64 MiB`: Practical upper bound — any single LSP message exceeding this is almost certainly malformed or malicious.
- `HeaderTooLong` error: Added as explicit safety net. The primary fix (1024 → 4096) prevents most real-world truncation, but the error ensures the buffer-full case is caught cleanly rather than silently parsing corrupt data.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. Existing test failures in stages 09_language and 10_runtime are pre-existing and unrelated to LSP transport changes (confirmed by running `testall.sh` on a clean checkout of the same commit).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Transport layer is hardened; ready for plan 03-02
- No regressions introduced; all zig build test passes

---
*Phase: 03-lsp-hardening*
*Completed: 2026-03-24*
