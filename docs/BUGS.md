# Kodr — Known Bugs

Bugs discovered during testing. Fix before v1.

---

## Borrow Checker

- ~~**Mutable+immutable overlap not caught**~~ — FIXED v0.3.2. `const_decl` was hardcoding immutable; now checks type annotation.

## Error Propagation

- ~~**Unhandled error unions not caught in some patterns**~~ — FIXED v0.3.3. `checkScopeExit` was skipping block-scope exits; now reports errors at all scope levels.

## Union Unwrap

- **`.value` requires explicit type annotation** — `const result: (null | i32) = find(5)` works with `.value`, but `const result = find(5)` (inferred) does not. Codegen can't track the union kind without the annotation. Use `.i32`/`.String` style for inferred variables until this is fixed.
