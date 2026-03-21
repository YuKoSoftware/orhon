# Kodr — Known Bugs

Bugs discovered during testing. Fix before v1.

---

## Borrow Checker

- ~~**Mutable+immutable overlap not caught**~~ — FIXED v0.3.2. `const_decl` was hardcoding immutable; now checks type annotation.

## Error Propagation

- ~~**Unhandled error unions not caught in some patterns**~~ — FIXED v0.3.3. `checkScopeExit` was skipping block-scope exits; now reports errors at all scope levels.
