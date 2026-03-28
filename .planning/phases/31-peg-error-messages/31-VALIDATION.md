---
phase: 31
slug: peg-error-messages
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-28
---

# Phase 31 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + bash integration tests |
| **Config file** | `build.zig` (test step) + `test/11_errors.sh` |
| **Quick run command** | `zig build test` |
| **Full suite command** | `./testall.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `zig build test`
- **After every plan wave:** Run `./testall.sh`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 31-01-01 | 01 | 1 | PEG-01 | unit | `zig build test` | TBD | pending |
| 31-01-02 | 01 | 1 | PEG-01 | integration | `bash test/11_errors.sh` | yes | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements.*

---

## Manual-Only Verifications

*All phase behaviors have automated verification.*

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
