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

if grep -q "= 4" "$GEN_EXAMPLE" && grep -q "= 44" "$GEN_EXAMPLE"; then
    pass "enum explicit values in generated code"
else
    fail "enum explicit values in generated code"
fi

if grep -q "const Speed = i32" "$GEN_EXAMPLE"; then pass "type alias generates const = type"
else fail "type alias generates const = type"; fi

if grep -q "|_err| return _err" "$GEN_EXAMPLE"; then pass "throw generates error propagation pattern"
else fail "throw generates error propagation pattern"; fi

if grep -q "catch unreachable" "$GEN_EXAMPLE"; then pass "throw narrowing uses catch unreachable"
else fail "throw narrowing uses catch unreachable"; fi

BINOUT=$(./bin/langtest 2>&1 || true)
if echo "$BINOUT" | grep -q "hello orhon"; then pass "langtest binary runs"
else fail "langtest binary runs" "$BINOUT"; fi

section "Tester module codegen"

cd "$TESTDIR"
mkdir -p comptest/src
cp "$FIXTURES/tester_main.orh" comptest/src/comptest.orh
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

if grep -q "?i32" "$GEN_TESTER" 2>/dev/null; then pass "null union codegen (?T)"
else fail "null union codegen (?T)"; fi

if grep -q "== null" "$GEN_TESTER" 2>/dev/null; then pass "null → == null codegen"
else fail "null → == null codegen"; fi

if grep -qF '.?' "$GEN_TESTER" 2>/dev/null; then pass "value → .? codegen"
else fail "value → .? codegen"; fi

if grep -q "@TypeOf" "$GEN_TESTER" 2>/dev/null; then pass "qualified is → @TypeOf codegen"
else fail "qualified is → @TypeOf codegen"; fi

section "Blueprint features"

cd "$TESTDIR"
mkdir -p bptest/src
cp "$FIXTURES/blueprint_main.orh" bptest/src/bptest.orh
cp "$FIXTURES/blueprint_basic.orh" bptest/src/tester.orh
cd bptest

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/bptest"; then
    pass "basic blueprint compiles"
else
    fail "basic blueprint compiles" "$OUTPUT"
fi

GEN_TESTER=".orh-cache/generated/tester.zig"
if [ -f "$GEN_TESTER" ]; then
    # Verify blueprint is erased — no trace in generated Zig
    if grep -q "blueprint" "$GEN_TESTER"; then
        fail "blueprint erased from codegen"
    else
        pass "blueprint erased from codegen"
    fi
    # Verify struct and method are present
    if grep -q "fn eq" "$GEN_TESTER"; then
        pass "blueprint method present in struct codegen"
    else
        fail "blueprint method present in struct codegen"
    fi
else
    fail "tester.zig generated for blueprint test"
fi

cd "$TESTDIR"
mkdir -p bpmulti/src
cp "$FIXTURES/blueprint_main.orh" bpmulti/src/bpmulti.orh
sed -i '1s/^module bptest$/module bpmulti/' bpmulti/src/bpmulti.orh
sed -i 's/#name    = "bptest"/#name    = "bpmulti"/' bpmulti/src/bpmulti.orh
cp "$FIXTURES/blueprint_multiple.orh" bpmulti/src/tester.orh
cd bpmulti

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/bpmulti"; then
    pass "multiple blueprints compile"
else
    fail "multiple blueprints compile" "$OUTPUT"
fi

# union flattening
cd "$TESTDIR"
mkdir -p union_flat/src
cp "$FIXTURES/union_flatten.orh" union_flat/src/union_flat.orh
cd union_flat
FLAT_OUT=$("$ORHON" build 2>&1 || true)
if echo "$FLAT_OUT" | grep -q "Built:"; then
    pass "union flattening compiles"
else
    fail "union flattening compiles" "$FLAT_OUT"
fi

section "Multi-file sidecar"

cd "$TESTDIR"
mkdir -p multizig/src
cp "$FIXTURES/multizig_main.orh" multizig/src/multizig.orh
cp "$FIXTURES/multizig.zig" multizig/src/multizig.zig
cp "$FIXTURES/multizig_helper.zig" multizig/src/helper.zig
cd "$TESTDIR/multizig"

OUTPUT=$("$ORHON" build 2>&1 || true)
if [ -f ".orh-cache/generated/helper.zig" ]; then
    pass "multi-file sidecar copies helper.zig"
else
    fail "multi-file sidecar copies helper.zig" "$OUTPUT"
fi

section "User .zig module"

cd "$TESTDIR"
cp -r "$FIXTURES/zig_module" "$TESTDIR/zig_module"
cd "$TESTDIR/zig_module"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/zig_module"; then
    pass "zig module project compiles"
else
    fail "zig module project compiles" "$OUTPUT"
fi

# Verify the auto-generated .orh was created in cache
if [ -f ".orh-cache/zig_modules/zigmath.orh" ]; then
    pass "zigmath.orh auto-generated from .zig"
else
    fail "zigmath.orh auto-generated from .zig"
fi

# Verify the generated .orh contains expected declarations
GEN_ORH=".orh-cache/zig_modules/zigmath.orh"
if grep -q "pub func add" "$GEN_ORH" 2>/dev/null; then pass "generated .orh has add function"
else fail "generated .orh has add function"; fi

if grep -q "pub func mul" "$GEN_ORH" 2>/dev/null; then pass "generated .orh has mul function"
else fail "generated .orh has mul function"; fi

# Private helper function should NOT appear
if grep -q "helper" "$GEN_ORH" 2>/dev/null; then fail "private fn excluded from generated .orh"
else pass "private fn excluded from generated .orh"; fi

# Verify the zig source was copied to generated dir
if [ -f ".orh-cache/generated/zigmath_zig.zig" ]; then
    pass "zigmath.zig copied to generated dir"
else
    fail "zigmath.zig copied to generated dir"
fi

# Run the binary and check output
BINOUT=$(./bin/zig_module 2>&1 || true)
if echo "$BINOUT" | grep -q "PASS zig_module_add"; then pass "runtime: zig_module_add"
else fail "runtime: zig_module_add" "$BINOUT"; fi

if echo "$BINOUT" | grep -q "PASS zig_module_mul"; then pass "runtime: zig_module_mul"
else fail "runtime: zig_module_mul" "$BINOUT"; fi

if echo "$BINOUT" | grep -q "ZIGMOD:DONE"; then pass "zig module binary ran to completion"
else fail "zig module binary ran to completion" "$BINOUT"; fi

section "Zon C library (.zon config)"

cd "$TESTDIR"
cp -r "$FIXTURES/zon_clib" "$TESTDIR/zon_clib"
cd "$TESTDIR/zon_clib"

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/zon_clib"; then
    pass "zon clib project compiles"
else
    fail "zon clib project compiles" "$OUTPUT"
fi

BINOUT=$(./bin/zon_clib 2>&1 || true)
if echo "$BINOUT" | grep -q "zon works"; then
    pass "zon clib binary runs correctly"
else
    fail "zon clib binary runs correctly" "$BINOUT"
fi

report_results
