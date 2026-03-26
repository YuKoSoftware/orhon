---
phase: 18
slug: type-alias-syntax
status: draft
nyquist_compliant: true
wave_0_complete: true
created: 2026-03-26
---

# Phase 18 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + shell integration tests |
| **Config file** | `build.zig` (test step defined) |
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
| 18-01-01 | 01 | 1 | TAMGA-04 | unit | `zig build test` | Existing infra | pending |
| 18-01-02 | 01 | 1 | TAMGA-04 | integration | `./testall.sh` | Existing infra | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. Zig `test` blocks and `./testall.sh` pipeline already handle unit and integration testing for parser, codegen, and language features.

---

## Manual-Only Verifications

All phase behaviors have automated verification.

---

## Validation Sign-Off

- [x] All tasks have automated verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 30s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
