# Phase 22: `throw` Statement — Validation Plan

**Phase:** 22-throw-statement
**Source:** Derived from 22-RESEARCH.md Validation Architecture section

---

## Test Framework

| Property | Value |
|----------|-------|
| Framework | Zig built-in `test` blocks + shell integration tests |
| Config file | `build.zig` (unit tests); `test/` scripts (integration) |
| Quick run command | `zig build test` |
| Full suite command | `./testall.sh` |

---

## Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | Status |
|--------|----------|-----------|-------------------|--------|
| ERR-01 | `throw x` propagates error and returns early from enclosing function | integration (codegen + runtime) | `./testall.sh` (test/10_runtime.sh via tester binary) | Wave 0 — add to `error_handling.orh` |
| ERR-02 | After `throw x`, `x` narrows to `T` — no `.value` needed | integration (codegen output check) | `./testall.sh` (test/09_language.sh grep on generated .zig) | Wave 0 — add grep check to `09_language.sh` |
| ERR-03 | `throw` in a non-error-returning function produces compile error | negative test | `./testall.sh` (test/11_errors.sh) | Wave 0 — add `fail_throw.orh` fixture |
| ERR-04 | Example module and docs updated with `throw` usage | compilation + visual | `./testall.sh` (test/09_language.sh — example compiles) | Wave 0 — add throw example to `error_handling.orh` |

---

## Sampling Rate

- **Per task commit:** `zig build test` (unit tests only — fast)
- **Per wave merge:** `./testall.sh` (all 11 stages)
- **Phase gate:** Full suite green before `/gsd:verify-work`

---

## Wave 0 Gaps (test scaffolding required before or alongside implementation)

- [ ] `test/fixtures/fail_throw.orh` — negative test fixture for ERR-03
  - Case 1: `throw` inside a function with no return type (void)
  - Case 2: `throw` on a non-error-union variable (null union or plain type)
- [ ] `src/templates/example/error_handling.orh` — add `throw` usage example covering ERR-01, ERR-02, ERR-04
- [ ] `test/09_language.sh` — add grep check that generated `.zig` contains `if (` and `|_err| return _err` pattern (ERR-02 codegen verification)
- [ ] `test/11_errors.sh` — add section running `fail_throw.orh` and asserting expected compile error messages (ERR-03 negative test)
- [ ] Zig unit test for `buildThrowStmt` in `src/peg/builder.zig` (optional but fast; catches capture logic errors early)

---

## Expected Codegen Output (for grep checks in test/09_language.sh)

After `throw result`:
```zig
if (result) |_| {} else |_err| return _err;
```

After `throw result` + subsequent `return result` (narrowed):
```zig
return result catch unreachable;
```

Grep pattern for ERR-02 check:
```bash
grep -q "|_err| return _err" .orh-cache/generated/example.zig
```

---

## Expected Error Messages (for test/11_errors.sh assertions)

| Scenario | Expected message fragment |
|----------|--------------------------|
| `throw` in void function | `'throw' used in function that does not return an error union` |
| `throw` on null union variable | `'throw' requires an error union variable` |
| `throw` on plain (non-union) variable | `'throw' requires an error union variable` |
