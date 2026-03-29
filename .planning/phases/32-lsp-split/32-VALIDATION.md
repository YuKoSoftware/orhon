---
phase: 32
slug: lsp-split
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-29
---

# Phase 32 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + shell integration tests |
| **Config file** | `build.zig` (test step) + `test/*.sh` (integration) |
| **Quick run command** | `zig build test` |
| **Full suite command** | `./testall.sh` |
| **Estimated runtime** | ~60 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build test`
- **After every plan wave:** Run `./testall.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 60 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 32-01-01 | 01 | 1 | SPLIT-01 | unit+integration | `./testall.sh` | ✅ | ⬜ pending |
| 32-01-02 | 01 | 1 | SPLIT-02 | unit+integration | `./testall.sh` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. The `./testall.sh` suite (266 tests across 11 stages) is the zero-behavior-change gate. No new test framework or stubs needed.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| No file exceeds ~600 lines | SPLIT-01 | Line count check | `wc -l src/lsp*.zig` — verify all under 600 |
| 8+ files created | SPLIT-01 | File count check | `ls src/lsp*.zig \| wc -l` — verify >= 8 |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
