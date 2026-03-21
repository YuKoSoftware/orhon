# Kodr — Known Bugs

Bugs discovered during testing. Fix before v1.

---

## Borrow Checker

- ~~**Mutable+immutable overlap not caught**~~ — FIXED v0.3.2. `const_decl` was hardcoding immutable; now checks type annotation.

## Error Propagation

- **Unhandled error unions not caught in some patterns** — calling a function that returns `(Error | T)` and storing the result without checking or propagating does not always trigger an error. The propagation checker should reject unhandled error unions when the enclosing function cannot propagate.
