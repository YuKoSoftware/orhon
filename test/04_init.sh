#!/usr/bin/env bash
# 04_init.sh — Project scaffolding (kodr init, embedded std)
source "$(dirname "$0")/helpers.sh"
require_kodr
setup_tmpdir
trap cleanup_tmpdir EXIT

section "kodr init"

cd "$TESTDIR"
OUTPUT=$("$KODR" init testproj 2>&1)

if echo "$OUTPUT" | grep -q "Created project 'testproj'"; then
    pass "prints success message"
else
    fail "prints success message" "$OUTPUT"
fi

if [ -d testproj/src ]; then pass "creates src/ directory"
else fail "creates src/ directory"; fi

if [ -f testproj/src/main.kodr ]; then pass "creates main.kodr"
else fail "creates main.kodr"; fi

if [ -f testproj/src/example.kodr ]; then pass "creates example.kodr"
else fail "creates example.kodr"; fi

if [ -f testproj/src/control_flow.kodr ]; then pass "creates control_flow.kodr"
else fail "creates control_flow.kodr"; fi

if head -1 testproj/src/main.kodr | grep -q "^module main$"; then
    pass "main.kodr has 'module main'"
else
    fail "main.kodr has 'module main'"
fi

if grep -q '#name    = "testproj"' testproj/src/main.kodr; then
    pass "main.kodr has project name"
else
    fail "main.kodr has project name"
fi

if head -1 testproj/src/example.kodr | grep -q "^module example$"; then
    pass "example.kodr has 'module example'"
else
    fail "example.kodr has 'module example'"
fi

if "$KODR" init testproj 2>&1 | grep -q "Created project"; then
    pass "init on existing dir succeeds"
else
    fail "init on existing dir succeeds"
fi

section "embedded std (auto-extracted on build)"

cd "$TESTDIR/testproj"
"$KODR" build >/dev/null 2>&1 || true

if [ -f .kodr-cache/std/console.kodr ]; then pass "build extracts std/console.kodr"
else fail "build extracts std/console.kodr"; fi

if [ -f .kodr-cache/std/console.zig ]; then pass "build extracts std/console.zig"
else fail "build extracts std/console.zig"; fi

if grep -q "pub fn print" .kodr-cache/std/console.zig; then
    pass "console.zig contains print function"
else
    fail "console.zig contains print function"
fi

report_results
