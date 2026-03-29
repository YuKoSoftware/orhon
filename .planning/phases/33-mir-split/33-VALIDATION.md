---
phase: 33
slug: mir-split
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-29
---

# Phase 33 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + shell integration tests |
| **Config file** | `build.zig` (test step) + `testall.sh` |
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
| 33-01-01 | 01 | 1 | SPLIT-03 | unit + integration | `zig build test && ./testall.sh` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. No new test framework needed — MIR tests use Zig built-in `test` blocks and will move with their code.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Generated Zig output is byte-identical | SPLIT-02 | Diff check not in automated suite | Compare `orhon build` output before/after split |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
