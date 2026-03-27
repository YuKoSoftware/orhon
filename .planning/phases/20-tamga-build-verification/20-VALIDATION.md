---
phase: 20
slug: tamga-build-verification
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-27
---

# Phase 20 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + bash integration tests |
| **Config file** | `testall.sh` (pipeline), individual `test/*.sh` scripts |
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
| 20-01-01 | 01 | 1 | REQ-20 | integration | `orhon build` in Tamga dir | N/A (external project) | ⬜ pending |
| 20-01-02 | 01 | 1 | REQ-20 | unit | `zig build test` | ✅ | ⬜ pending |
| 20-01-03 | 01 | 1 | REQ-20 | integration | `./testall.sh` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

*Existing infrastructure covers all phase requirements. The Tamga project at `/home/yunus/Projects/orhon/tamga_framework/` serves as the primary integration test target.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tamga builds end-to-end | REQ-20 | External project, not in test suite | Run `orhon build` in Tamga dir, verify clean build with no workarounds |
| Bridge module cross-imports | REQ-20 | Depends on Tamga module structure | Check generated build.zig has correct addImport for all bridge deps |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
