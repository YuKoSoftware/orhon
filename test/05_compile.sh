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
cp "$FIXTURES/tester_main.orh" orhontest/src/main.orh
cp "$FIXTURES/tester.orh" orhontest/src/tester.orh
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
cat > failtest/src/main.orh <<'ORHON'
module main
#name    = "failtest"
#version = Version(1, 0, 0)
#build   = exe
func add(a: i32, b: i32) i32 {
    return a + b
}
test "wrong" {
    assert(add(2, 2) == 5)
}
func main() void { }
ORHON
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

if [ -f .orh-cache/generated/main.zig ]; then pass "generates main.zig"
else fail "generates main.zig"; fi

if [ -f .orh-cache/generated/example.zig ]; then pass "generates example.zig"
else fail "generates example.zig"; fi

if grep -q "pub fn print" .orh-cache/generated/console_bridge.zig && \
   grep -q "console_bridge\")" .orh-cache/generated/console.zig; then
    pass "sidecar preserved"
else
    fail "sidecar preserved"
fi

BINOUT=$(./bin/buildproj 2>&1)
if echo "$BINOUT" | grep -q "hello orhon"; then pass "binary runs"
else fail "binary runs" "$BINOUT"; fi

# Only the expected RawPtr warning from the example module — no other warnings
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

if echo "$OUTPUT" | grep -q "module 'main'"; then pass "finds main module"
else fail "finds main module" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "module 'example'"; then pass "finds example module"
else fail "finds example module" "$OUTPUT"; fi

# ── Incremental build ────────────────────────────────────────

section "Incremental build"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/buildproj"; then pass "rebuild succeeds"
else fail "rebuild succeeds" "$OUTPUT"; fi

if [ -f .orh-cache/hashes ]; then pass "cache hashes exist"
else fail "cache hashes exist"; fi

report_results
