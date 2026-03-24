#!/usr/bin/env bash
# 09_language.sh — Language feature verification via example + tester modules
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Language features (example module)"

cd "$TESTDIR"
"$ORHON" init langtest >/dev/null 2>&1 || true
cd "$TESTDIR/langtest"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/langtest"; then
    pass "example module compiles (all features)"
else
    fail "example module compiles (all features)" "$OUTPUT"
fi

GEN_EXAMPLE=".orh-cache/generated/example.zig"

if grep -q "inline fn" "$GEN_EXAMPLE"; then pass "compt func generates inline fn"
else fail "compt func generates inline fn"; fi

if grep -q "inline fn double" "$GEN_EXAMPLE"; then pass "compt func double generates inline fn"
else fail "compt func double generates inline fn"; fi

if grep -q '++' "$GEN_EXAMPLE"; then pass "++ concatenation in output"
else fail "++ concatenation in output"; fi

if grep -q "x: f" "$GEN_EXAMPLE" && grep -q "y: f" "$GEN_EXAMPLE"; then
    pass "struct fields"
else
    fail "struct fields"
fi

BINOUT=$(./bin/langtest 2>&1 || true)
if echo "$BINOUT" | grep -q "hello orhon"; then pass "langtest binary runs"
else fail "langtest binary runs" "$BINOUT"; fi

section "Tester module codegen"

cd "$TESTDIR"
mkdir -p comptest/src
cp "$FIXTURES/tester_main.orh" comptest/src/main.orh
cp "$FIXTURES/tester.orh" comptest/src/tester.orh
cd "$TESTDIR/comptest"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/comptest"; then
    pass "tester module compiles"
else
    fail "tester module compiles" "$OUTPUT"
fi

GEN_TESTER=".orh-cache/generated/tester.zig"

if [ -f "$GEN_TESTER" ]; then pass "tester.zig generated"
else fail "tester.zig generated"; fi

if grep -q "inline fn" "$GEN_TESTER" 2>/dev/null; then pass "compt func codegen"
else fail "compt func codegen"; fi

if grep -q "switch" "$GEN_TESTER" 2>/dev/null; then pass "match → switch codegen"
else fail "match → switch codegen"; fi

if grep -q "defer" "$GEN_TESTER" 2>/dev/null; then pass "defer codegen"
else fail "defer codegen"; fi

if grep -q "break" "$GEN_TESTER" 2>/dev/null; then pass "break codegen"
else fail "break codegen"; fi

if grep -q "continue" "$GEN_TESTER" 2>/dev/null; then pass "continue codegen"
else fail "continue codegen"; fi

if grep -q "++" "$GEN_TESTER" 2>/dev/null; then pass "++ concat codegen"
else fail "++ concat codegen"; fi

if grep -q "x: f32" "$GEN_TESTER" 2>/dev/null; then pass "struct fields codegen"
else fail "struct fields codegen"; fi

if grep -q "while" "$GEN_TESTER" 2>/dev/null; then pass "while loop codegen"
else fail "while loop codegen"; fi

if grep -q " for " "$GEN_TESTER" 2>/dev/null; then pass "for loop codegen"
else fail "for loop codegen"; fi

if grep -q "std.testing.expect" "$GEN_TESTER" 2>/dev/null; then pass "@assert codegen"
else fail "@assert codegen"; fi

if grep -q "OrhonNullable" "$GEN_TESTER" 2>/dev/null; then pass "null union codegen"
else fail "null union codegen"; fi

if grep -q ".none" "$GEN_TESTER" 2>/dev/null; then pass "null → .none codegen"
else fail "null → .none codegen"; fi

if grep -q ".some" "$GEN_TESTER" 2>/dev/null; then pass "value → .some codegen"
else fail "value → .some codegen"; fi

report_results
