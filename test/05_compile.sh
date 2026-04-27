#!/usr/bin/env bash
# 05_compile.sh — orhon build, run, test, incremental compilation
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

# ── orhon test command ────────────────────────────────────────

section "orhon test command"

cd "$TESTDIR"
mkdir -p orhontest/src
cp "$FIXTURES/runtime/tester_main.orh" orhontest/src/orhontest.orh
sed -i '1s/^module comptest$/module orhontest/' orhontest/src/orhontest.orh
cp "$FIXTURES/runtime/tester.orh" orhontest/src/tester.orh
printf '#name  = orhontest\n#build = exe\n' > orhontest/orhon.project
cd "$TESTDIR/orhontest"

TEST_OUT=$("$ORHON" test 2>&1 || true)
if echo "$TEST_OUT" | grep -q "all tests passed"; then
    pass "orhon test — all tests pass"
else
    fail "orhon test — all tests pass" "$TEST_OUT"
fi

if echo "$TEST_OUT" | grep -q "FAIL"; then
    fail "orhon test — no failures reported"
else
    pass "orhon test — no failures reported"
fi

# ── orhon test with failing test ──────────────────────────────

cd "$TESTDIR"
mkdir -p failtest/src
cat > failtest/src/failtest.orh <<'ORHON'
module failtest
func add(a: i32, b: i32) i32 {
    return a + b
}
test "wrong" {
    assert(add(2, 2) == 5)
}
func main() void { }
ORHON
printf '#name  = failtest\n#build = exe\n' > failtest/orhon.project
cd failtest
FAIL_OUT=$("$ORHON" test 2>&1 || true)
if echo "$FAIL_OUT" | grep -qi "fail\|FAIL\|error"; then pass "orhon test — detects failure"
else fail "orhon test — detects failure" "$FAIL_OUT"; fi

# ── orhon build ───────────────────────────────────────────────

section "orhon build"

cd "$TESTDIR"
"$ORHON" init buildproj >/dev/null 2>&1 || true
cd "$TESTDIR/buildproj"
OUTPUT=$("$ORHON" build 2>&1 || true)

if echo "$OUTPUT" | grep -q "Built: bin/buildproj"; then pass "reports success"
else fail "reports success" "$OUTPUT"; fi

if [ -x bin/buildproj ]; then pass "produces executable"
else fail "produces executable"; fi

if [ -f .orh-cache/generated/buildproj.zig ]; then pass "generates buildproj.zig"
else fail "generates buildproj.zig"; fi

if [ -f .orh-cache/generated/example.zig ]; then pass "generates example.zig"
else fail "generates example.zig"; fi

if grep -q "pub fn print" .orh-cache/generated/console_zig.zig && \
   grep -q "console_zig\")" .orh-cache/generated/console.zig; then
    pass "zig module wired"
else
    fail "zig module wired"
fi

BINOUT=$(./bin/buildproj 2>&1)
if echo "$BINOUT" | grep -q "hello orhon"; then pass "binary runs"
else fail "binary runs" "$BINOUT"; fi

# No unexpected warnings should appear (1 known: var-not-reassigned for thread handle)
WARN_COUNT=$(echo "$OUTPUT" | grep -c "WARNING" || true)
if [ "$WARN_COUNT" -le 1 ]; then pass "no unexpected warnings"
else fail "no unexpected warnings" "got $WARN_COUNT warnings"; fi


# ── orhon run ─────────────────────────────────────────────────

section "orhon run"

rm -rf .orh-cache bin
OUTPUT=$("$ORHON" run 2>&1 || true)

if echo "$OUTPUT" | grep -q "Built: bin/buildproj"; then pass "builds the project"
else fail "builds the project" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "hello orhon"; then pass "executes the binary"
else fail "executes the binary" "$OUTPUT"; fi

# ── orhon debug ───────────────────────────────────────────────

section "orhon debug"

OUTPUT=$("$ORHON" debug 2>&1 || true)

if echo "$OUTPUT" | grep -q "=== orhon debug ==="; then pass "shows header"
else fail "shows header" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "module 'buildproj'"; then pass "finds buildproj module"
else fail "finds buildproj module" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "module 'example'"; then pass "finds example module"
else fail "finds example module" "$OUTPUT"; fi

# ── Incremental build ────────────────────────────────────────

section "Incremental build"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/buildproj"; then pass "rebuild succeeds"
else fail "rebuild succeeds" "$OUTPUT"; fi

if [ -f .orh-cache/hashes ]; then pass "cache hashes exist"
else fail "cache hashes exist"; fi

# Verify unchanged modules are actually skipped by the incremental cache:
# capture mtimes of generated .zig files, rebuild with no changes, confirm unchanged.
BUILDPROJ_MTIME_BEFORE=$(stat -c '%Y' .orh-cache/generated/buildproj.zig 2>/dev/null || echo "0")
EXAMPLE_MTIME_BEFORE=$(stat -c '%Y' .orh-cache/generated/example.zig 2>/dev/null || echo "0")

# Sleep 1s so any regeneration would be visible in 1s-granularity mtimes.
sleep 1
"$ORHON" build >/dev/null 2>&1 || true

BUILDPROJ_MTIME_AFTER=$(stat -c '%Y' .orh-cache/generated/buildproj.zig 2>/dev/null || echo "0")
EXAMPLE_MTIME_AFTER=$(stat -c '%Y' .orh-cache/generated/example.zig 2>/dev/null || echo "0")

if [ "$BUILDPROJ_MTIME_BEFORE" = "$BUILDPROJ_MTIME_AFTER" ]; then
    pass "skips codegen for unchanged buildproj module"
else
    fail "skips codegen for unchanged buildproj module" \
        "buildproj.zig mtime changed from $BUILDPROJ_MTIME_BEFORE to $BUILDPROJ_MTIME_AFTER"
fi

if [ "$EXAMPLE_MTIME_BEFORE" = "$EXAMPLE_MTIME_AFTER" ]; then
    pass "skips codegen for unchanged example module"
else
    fail "skips codegen for unchanged example module" \
        "example.zig mtime changed from $EXAMPLE_MTIME_BEFORE to $EXAMPLE_MTIME_AFTER"
fi

# The incremental cache is hashed over lexed semantic tokens (comments and
# whitespace are skipped), so only a real source change should invalidate.
# Modify the greeting string so the hash actually changes.
sed -i 's/hello orhon !/hello cache test/' src/buildproj.orh
sleep 1
"$ORHON" build >/dev/null 2>&1 || true

BUILDPROJ_MTIME_TOUCHED=$(stat -c '%Y' .orh-cache/generated/buildproj.zig 2>/dev/null || echo "0")
EXAMPLE_MTIME_AFTER_TOUCH=$(stat -c '%Y' .orh-cache/generated/example.zig 2>/dev/null || echo "0")

if [ "$BUILDPROJ_MTIME_TOUCHED" != "$BUILDPROJ_MTIME_AFTER" ]; then
    pass "regenerates touched buildproj module"
else
    fail "regenerates touched buildproj module" \
        "buildproj.zig mtime unchanged after source touch"
fi

if [ "$EXAMPLE_MTIME_AFTER_TOUCH" = "$EXAMPLE_MTIME_AFTER" ]; then
    pass "still skips unchanged example module after sibling touch"
else
    fail "still skips unchanged example module after sibling touch" \
        "example.zig mtime changed from $EXAMPLE_MTIME_AFTER to $EXAMPLE_MTIME_AFTER_TOUCH"
fi

report_results
