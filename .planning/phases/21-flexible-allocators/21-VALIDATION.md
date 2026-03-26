---
phase: 21
slug: flexible-allocators
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-26
---

# Phase 21 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Zig built-in `test` blocks + shell integration tests |
| **Config file** | `build.zig` (test step), `testall.sh` (pipeline) |
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
| 21-01-01 | 01 | 1 | D-05,D-06 | unit | `zig build test` | ✅ | ⬜ pending |
| 21-01-02 | 01 | 1 | D-11,D-12 | unit+integration | `./testall.sh` | ✅ | ⬜ pending |
| 21-01-03 | 01 | 1 | D-13 | unit | `zig build test` | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Existing infrastructure covers all phase requirements. `zig build test` runs all Zig test blocks including `src/std/collections.zig` tests. `./testall.sh` runs the full 11-stage pipeline including codegen and runtime tests.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Custom allocator via bridge | D-08 | User-authored bridge pattern | Create a test bridge allocator struct, use with List(i32).new(custom.allocator()) |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
