# Milestones

## v0.11 Language Simplification (Shipped: 2026-03-25)

**Phases completed:** 4 phases, 5 plans, 5 tasks

**Key accomplishments:**

- Const auto-borrow: `const` non-primitive values auto-pass as `const &` at call sites — no more silent deep copies
- Ptr syntax simplified: `const p: Ptr(T) = &x` replaces verbose `.cast()` — type annotation drives pointer safety level
- Old `Ptr(T).cast(&x)` and `Ptr(T, &x)` syntax removed — compile error with clear message
- Tamga companion project and all fixtures updated for new semantics
- `.Error` fallback codegen fixed: correct Zig `if/else` pattern instead of `catch`
- 240/240 tests pass across all 11 stages

**Stats:** 35 files changed, 2812 insertions, 256 deletions
**Git range:** 51aceec..ffb8c0e (2026-03-25)

---
