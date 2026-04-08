#!/usr/bin/env bash
# 04_init.sh — Project scaffolding (orhon init, embedded std)
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "orhon init"

cd "$TESTDIR"
OUTPUT=$("$ORHON" init testproj 2>&1)

if echo "$OUTPUT" | grep -q "Created project 'testproj'"; then
    pass "prints success message"
else
    fail "prints success message" "$OUTPUT"
fi

if [ -d testproj/src ]; then pass "creates src/ directory"
else fail "creates src/ directory"; fi

if [ -f testproj/src/testproj.orh ]; then pass "creates testproj.orh"
else fail "creates testproj.orh"; fi

if [ -d testproj/src/example ]; then pass "creates src/example/ directory"
else fail "creates src/example/ directory"; fi

if [ -f testproj/src/example/example.orh ]; then pass "creates example/example.orh"
else fail "creates example/example.orh"; fi

if [ -f testproj/src/example/control_flow.orh ]; then pass "creates example/control_flow.orh"
else fail "creates example/control_flow.orh"; fi

if [ -f testproj/src/example/error_handling.orh ]; then pass "creates example/error_handling.orh"
else fail "creates example/error_handling.orh"; fi

if [ -f testproj/src/example/data_types.orh ]; then pass "creates example/data_types.orh"
else fail "creates example/data_types.orh"; fi

if [ -f testproj/src/example/strings.orh ]; then pass "creates example/strings.orh"
else fail "creates example/strings.orh"; fi

if [ -f testproj/src/example/advanced.orh ]; then pass "creates example/advanced.orh"
else fail "creates example/advanced.orh"; fi

if head -1 testproj/src/testproj.orh | grep -q "^module testproj$"; then
    pass "testproj.orh has 'module testproj'"
else
    fail "testproj.orh has 'module testproj'"
fi

if grep -q '#build   = exe' testproj/src/testproj.orh; then
    pass "testproj.orh has #build = exe"
else
    fail "testproj.orh has #build = exe"
fi

if grep -q "^module example$" testproj/src/example/example.orh; then
    pass "example.orh has 'module example'"
else
    fail "example.orh has 'module example'"
fi

if "$ORHON" init testproj 2>&1 | grep -q "Created project"; then
    pass "init on existing dir succeeds"
else
    fail "init on existing dir succeeds"
fi

section "orhon init — name validation"

cd "$TESTDIR"
if "$ORHON" init "bad name!" 2>/dev/null; then
    fail "rejects invalid project name"
else
    pass "rejects invalid project name"
fi

section "embedded std (auto-extracted on build)"

cd "$TESTDIR/testproj"
"$ORHON" build >/dev/null 2>&1 || true

if [ -f .orh-cache/std/console.orh ]; then pass "build extracts std/console.orh"
else fail "build extracts std/console.orh"; fi

if [ -f .orh-cache/std/console.zig ]; then pass "build extracts std/console.zig"
else fail "build extracts std/console.zig"; fi

if grep -q "pub fn print" .orh-cache/std/console.zig; then
    pass "console.zig contains print function"
else
    fail "console.zig contains print function"
fi

report_results
