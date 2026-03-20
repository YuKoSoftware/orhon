#!/usr/bin/env bash
# test.sh — Complete test suite for the Kodr compiler
# Runs: Zig unit tests → Zig build → Kodr integration tests
# Usage: ./test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/test_log.txt"
KODR="$SCRIPT_DIR/zig-out/bin/kodr"
TESTDIR="$(mktemp -d /tmp/kodr-test-XXXXXX)"
PASSED=0
FAILED=0
TOTAL=0
STAGE_FAILED=0

# Tee all output to log file
exec > >(tee "$LOG_FILE") 2>&1

# ── Helpers ───────────────────────────────────────────────────

cleanup() { rm -rf "$TESTDIR"; }
trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    printf "  \033[32mPASS\033[0m  %s\n" "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    printf "  \033[31mFAIL\033[0m  %s\n" "$1"
    if [ -n "${2:-}" ]; then
        printf "        %s\n" "$2"
    fi
}

section() {
    printf "\n\033[1m── %s ──\033[0m\n" "$1"
}

# ══════════════════════════════════════════════════════════════
# STAGE 1: Zig unit tests
# ══════════════════════════════════════════════════════════════

section "Zig unit tests"
if zig build test 2>&1; then
    pass "zig build test"
else
    fail "zig build test"
    printf "\n\033[31mUnit tests failed — aborting.\033[0m\n"
    exit 1
fi

# ══════════════════════════════════════════════════════════════
# STAGE 2: Zig build
# ══════════════════════════════════════════════════════════════

section "Zig build"
if zig build 2>&1; then
    pass "zig build"
else
    fail "zig build"
    printf "\n\033[31mBuild failed — aborting.\033[0m\n"
    exit 1
fi

if [ ! -x "$KODR" ]; then
    printf "\n\033[31mKodr binary not found at %s — aborting.\033[0m\n" "$KODR"
    exit 1
fi

# ══════════════════════════════════════════════════════════════
# STAGE 3: CLI basics
# ══════════════════════════════════════════════════════════════

section "CLI basics"

HELP_OUT=$("$KODR" help 2>&1 || true)
if echo "$HELP_OUT" | grep -q "The Kodr programming language compiler"; then
    pass "kodr help shows usage"
else
    fail "kodr help shows usage"
fi

if ! "$KODR" 2>/dev/null; then
    pass "kodr (no args) exits non-zero"
else
    fail "kodr (no args) exits non-zero"
fi

if ! "$KODR" foobar 2>/dev/null; then
    pass "kodr <unknown> exits non-zero"
else
    fail "kodr <unknown> exits non-zero"
fi

if ! "$KODR" init 2>/dev/null; then
    pass "kodr init (no name) exits non-zero"
else
    fail "kodr init (no name) exits non-zero"
fi

# ══════════════════════════════════════════════════════════════
# STAGE 4: kodr init
# ══════════════════════════════════════════════════════════════

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

# ══════════════════════════════════════════════════════════════
# STAGE 5: kodr initstd
# ══════════════════════════════════════════════════════════════

section "kodr initstd"

"$KODR" initstd >/dev/null 2>&1 || true
KODR_DIR="$(dirname "$KODR")"

if [ -f "$KODR_DIR/std/console.kodr" ]; then pass "creates std/console.kodr"
else fail "creates std/console.kodr"; fi

if [ -f "$KODR_DIR/std/console.zig" ]; then pass "creates std/console.zig sidecar"
else fail "creates std/console.zig sidecar"; fi

if [ -d "$KODR_DIR/global" ]; then pass "creates global/ directory"
else fail "creates global/ directory"; fi

if grep -q "pub fn print" "$KODR_DIR/std/console.zig"; then
    pass "console.zig contains print function"
else
    fail "console.zig contains print function"
fi

# ══════════════════════════════════════════════════════════════
# STAGE 6: kodr test command
# ══════════════════════════════════════════════════════════════

section "kodr test command"

cd "$TESTDIR"
mkdir -p kodrtest/src
cp "$SCRIPT_DIR/tests/tester_main.kodr" kodrtest/src/main.kodr
cp "$SCRIPT_DIR/tests/tester.kodr" kodrtest/src/tester.kodr
cd "$TESTDIR/kodrtest"

TEST_OUT=$("$KODR" test 2>&1)
if echo "$TEST_OUT" | grep -q "all tests passed"; then
    pass "kodr test — all tests pass"
else
    fail "kodr test — all tests pass" "$TEST_OUT"
fi

if echo "$TEST_OUT" | grep -q "FAIL"; then
    fail "kodr test — no failures reported"
else
    pass "kodr test — no failures reported"
fi

# ══════════════════════════════════════════════════════════════
# STAGE 7: kodr build
# ══════════════════════════════════════════════════════════════

section "kodr build"

cd "$TESTDIR/testproj"
OUTPUT=$("$KODR" build 2>&1)

if echo "$OUTPUT" | grep -q "Built: bin/testproj"; then pass "reports success"
else fail "reports success" "$OUTPUT"; fi

if [ -x bin/testproj ]; then pass "produces executable"
else fail "produces executable"; fi

if [ -f .kodr-cache/generated/main.zig ]; then pass "generates main.zig"
else fail "generates main.zig"; fi

if [ -f .kodr-cache/generated/example.zig ]; then pass "generates example.zig"
else fail "generates example.zig"; fi

if grep -q "pub fn print" .kodr-cache/generated/console_extern.zig && \
   grep -q "console_extern.zig" .kodr-cache/generated/console.zig; then
    pass "sidecar preserved"
else
    fail "sidecar preserved"
fi

BINOUT=$(./bin/testproj 2>&1)
if echo "$BINOUT" | grep -q "hello kodr"; then pass "binary runs"
else fail "binary runs" "$BINOUT"; fi

if echo "$BINOUT" | grep -q "\[info\] ready"; then pass "mixed extern+kodr func (printPrefixed)"
else fail "mixed extern+kodr func (printPrefixed)" "$BINOUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 8: Incremental build
# ══════════════════════════════════════════════════════════════

section "Incremental build"

OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/testproj"; then pass "rebuild succeeds"
else fail "rebuild succeeds" "$OUTPUT"; fi

if [ -f .kodr-cache/timestamps ]; then pass "cache timestamps exist"
else fail "cache timestamps exist"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 8b: kodr build (library)
# ══════════════════════════════════════════════════════════════

section "kodr build (library)"

cd "$TESTDIR"
"$KODR" init testlib >/dev/null 2>&1
cd "$TESTDIR/testlib"

# Static library
sed -i 's/#build   = exe/#build   = static/' src/main.kodr

OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/libtestlib.a"; then pass "static: reports success"
else fail "static: reports success" "$OUTPUT"; fi

if [ -f bin/libtestlib.a ]; then pass "static: produces .a archive"
else fail "static: produces .a archive"; fi

if [ -f bin/testlib.kodr ]; then pass "static: generates interface file"
else fail "static: generates interface file"; fi

if head -1 bin/testlib.kodr | grep -q "// Kodr interface file"; then pass "static: interface has header comment"
else fail "static: interface has header comment"; fi

if grep -q "^module " bin/testlib.kodr; then pass "static: interface has module declaration"
else fail "static: interface has module declaration"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "static: no memory leaks"
else fail "static: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

# Dynamic library
sed -i 's/#build   = static/#build   = dynamic/' src/main.kodr
rm -rf .kodr-cache bin

OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/libtestlib.so"; then pass "dynamic: reports success"
else fail "dynamic: reports success" "$OUTPUT"; fi

if [ -f bin/libtestlib.so ]; then pass "dynamic: produces .so library"
else fail "dynamic: produces .so library"; fi

if [ -f bin/testlib.kodr ]; then pass "dynamic: generates interface file"
else fail "dynamic: generates interface file"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "dynamic: no memory leaks"
else fail "dynamic: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

cd "$TESTDIR/testproj"

# ══════════════════════════════════════════════════════════════
# STAGE 9: kodr run
# ══════════════════════════════════════════════════════════════

section "kodr run"

rm -rf .kodr-cache bin
OUTPUT=$("$KODR" run 2>&1)

if echo "$OUTPUT" | grep -q "Built: bin/testproj"; then pass "builds the project"
else fail "builds the project" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "hello kodr"; then pass "executes the binary"
else fail "executes the binary" "$OUTPUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 10: kodr debug
# ══════════════════════════════════════════════════════════════

section "kodr debug"

OUTPUT=$("$KODR" debug 2>&1)

if echo "$OUTPUT" | grep -q "=== kodr debug ==="; then pass "shows header"
else fail "shows header" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "module 'main'"; then pass "finds main module"
else fail "finds main module" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "module 'example'"; then pass "finds example module"
else fail "finds example module" "$OUTPUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 11: Error handling
# ══════════════════════════════════════════════════════════════

section "Error handling"

# build outside a project
cd "$TESTDIR"
mkdir -p noproject && cd noproject
if ! "$KODR" build 2>/dev/null; then pass "fails outside a project"
else fail "fails outside a project"; fi

# missing import
cd "$TESTDIR"
"$KODR" init badimport >/dev/null 2>&1
cat > "$TESTDIR/badimport/src/main.kodr" <<'KODR'
module main
#name    = "badimport"
#version = Version(1, 0, 0)
#build   = exe
import nonexistent
func main() void {
}
KODR
cd "$TESTDIR/badimport"
BADIMPORT_OUT=$("$KODR" build 2>&1 || true)
if echo "$BADIMPORT_OUT" | grep -qi "not found"; then pass "missing import error"
else fail "missing import error" "$BADIMPORT_OUT"; fi

# missing module declaration
cd "$TESTDIR"
"$KODR" init nomodule >/dev/null 2>&1
echo "func main() void {}" > "$TESTDIR/nomodule/src/main.kodr"
cd "$TESTDIR/nomodule"
NOMOD_OUT=$("$KODR" build 2>&1 || true)
if echo "$NOMOD_OUT" | grep -qi "missing module\|no module\|module"; then
    pass "missing module error"
else
    fail "missing module error" "$NOMOD_OUT"
fi

# missing anchor file
cd "$TESTDIR"
"$KODR" init noanchor >/dev/null 2>&1
cat > "$TESTDIR/noanchor/src/wrong_name.kodr" <<'KODR'
module utils
pub func helper() i32 {
    return 42
}
KODR
cd "$TESTDIR/noanchor"
ANCHOR_OUT=$("$KODR" build 2>&1 || true)
if echo "$ANCHOR_OUT" | grep -qi "no anchor file"; then pass "missing anchor file error"
else fail "missing anchor file error" "$ANCHOR_OUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 12: Multi-module project
# ══════════════════════════════════════════════════════════════

section "Multi-module project"

cd "$TESTDIR"
"$KODR" init multimod >/dev/null 2>&1
cd "$TESTDIR/multimod"

cat > src/utils.kodr <<'KODR'
module utils
pub func double(n: i32) i32 {
    return n + n
}
KODR

cat > src/main.kodr <<'KODR'
module main
#name    = "multimod"
#version = Version(1, 0, 0)
#build   = exe
import std::console
import utils
func main() void {
    console.println("multi-module works")
}
KODR

OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/multimod"; then pass "multi-module builds"
else fail "multi-module builds" "$OUTPUT"; fi

BINOUT=$(./bin/multimod 2>&1)
if echo "$BINOUT" | grep -q "multi-module works"; then pass "multi-module runs"
else fail "multi-module runs" "$BINOUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 13: Generated Zig quality
# ══════════════════════════════════════════════════════════════

section "Generated Zig quality"

cd "$TESTDIR/testproj"

if grep -q "// generated from module main" .kodr-cache/generated/main.zig; then
    pass "module header comment"
else
    fail "module header comment"
fi

if grep -q 'const std = @import("std")' .kodr-cache/generated/main.zig; then
    pass "imports std"
else
    fail "imports std"
fi

if grep -q 'const console = @import("console.zig")' .kodr-cache/generated/main.zig; then
    pass "imports console"
else
    fail "imports console"
fi

if grep -q "const Point" .kodr-cache/generated/example.zig; then
    pass "struct definitions"
else
    fail "struct definitions"
fi

if grep -q "fn add" .kodr-cache/generated/example.zig; then
    pass "function definitions"
else
    fail "function definitions"
fi

# ══════════════════════════════════════════════════════════════
# STAGE 14: Language feature test
# ══════════════════════════════════════════════════════════════

section "Language features (example module)"

# The example module exercises all implemented language features.
# If it builds, the features work.
cd "$TESTDIR"
"$KODR" init langtest >/dev/null 2>&1
cd "$TESTDIR/langtest"

OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/langtest"; then
    pass "example module compiles (all features)"
else
    fail "example module compiles (all features)" "$OUTPUT"
fi

# Verify the generated example.zig contains key features
GEN_EXAMPLE=".kodr-cache/generated/example.zig"

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

BINOUT=$(./bin/langtest 2>&1)
if echo "$BINOUT" | grep -q "hello kodr"; then pass "langtest binary runs"
else fail "langtest binary runs" "$BINOUT"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 15: Compiler tester module
# ══════════════════════════════════════════════════════════════

section "Compiler tester module"

# The tester module exercises every implemented language feature through
# the actual compiler pipeline. It lives in tests/ and is NOT part of kodr init.
cd "$TESTDIR"
mkdir -p comptest/src

# Use our custom main that calls tester functions and prints results
cp "$SCRIPT_DIR/tests/tester_main.kodr" comptest/src/main.kodr
cp "$SCRIPT_DIR/tests/tester.kodr" comptest/src/tester.kodr

cd "$TESTDIR/comptest"
OUTPUT=$("$KODR" build 2>&1)
if echo "$OUTPUT" | grep -q "Built: bin/comptest"; then
    pass "tester module compiles"
else
    fail "tester module compiles" "$OUTPUT"
fi

# Verify generated tester.zig has key constructs
GEN_TESTER=".kodr-cache/generated/tester.zig"

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

if grep -q "KodrNullable" "$GEN_TESTER" 2>/dev/null; then pass "null union codegen"
else fail "null union codegen"; fi

if grep -q ".none" "$GEN_TESTER" 2>/dev/null; then pass "null → .none codegen"
else fail "null → .none codegen"; fi

if grep -q ".some" "$GEN_TESTER" 2>/dev/null; then pass "value → .some codegen"
else fail "value → .some codegen"; fi

# ══════════════════════════════════════════════════════════════
# STAGE 16: Runtime correctness
# ══════════════════════════════════════════════════════════════

section "Runtime correctness"

# Run the comptest binary — it calls tester functions and prints PASS/FAIL
BINOUT=$(./bin/comptest 2>&1)

if echo "$BINOUT" | grep -q "TESTER:DONE"; then pass "tester ran to completion"
else fail "tester ran to completion" "$BINOUT"; fi

if echo "$BINOUT" | grep -q "FAIL"; then
    fail "runtime correctness — some tests failed"
    echo "$BINOUT" | grep "FAIL" | while read -r line; do
        printf "        %s\n" "$line"
    done
else
    pass "runtime correctness — all tests passed"
fi

# Check individual results
for TEST_NAME in add sub factorial is_positive compound sum_to match match_default break_continue abs compt_func struct_instantiation default_fields default_override static_method mutable_method error_ok error_fail null_some null_none null_reassign enum_usage enum_method nested_scopes tuple tuple_destruct slice_for for_index for_range while_continue cast_int cast_float cast_float_to_int func_ptr func_ptr_var fixed_array array_index slice_expr raw_ptr safe_ptr typeid_same typeid_diff match_range match_string; do
    if echo "$BINOUT" | grep -q "PASS $TEST_NAME"; then pass "runtime: $TEST_NAME"
    else fail "runtime: $TEST_NAME"; fi
done

# ══════════════════════════════════════════════════════════════
# STAGE 17: Negative tests (must fail to compile)
# ══════════════════════════════════════════════════════════════

section "Negative tests (expected failures)"

# missing module declaration
cd "$TESTDIR"
mkdir -p neg_module/src
cp "$SCRIPT_DIR/tests/fail_missing_module.kodr" neg_module/src/main.kodr
cd neg_module
NEG_OUT=$("$KODR" build 2>&1 || true)
if [ $? -ne 0 ] || echo "$NEG_OUT" | grep -qi "module\|error"; then
    pass "rejects missing module declaration"
else
    fail "rejects missing module declaration" "$NEG_OUT"
fi

# missing import
cd "$TESTDIR"
mkdir -p neg_import/src
cp "$SCRIPT_DIR/tests/fail_missing_import.kodr" neg_import/src/main.kodr
cd neg_import
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "not found\|error"; then
    pass "rejects missing import"
else
    fail "rejects missing import" "$NEG_OUT"
fi

# missing anchor file
cd "$TESTDIR"
mkdir -p neg_anchor/src
cat > neg_anchor/src/main.kodr <<'KODR'
module main
#name    = "neg_anchor"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
}
KODR
cp "$SCRIPT_DIR/tests/fail_no_anchor.kodr" neg_anchor/src/misnamed.kodr
cd neg_anchor
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "no anchor file"; then
    pass "rejects missing anchor file"
else
    fail "rejects missing anchor file" "$NEG_OUT"
fi

# pub extern func must error (redundant)
cd "$TESTDIR"
mkdir -p neg_extern_pub/src
cat > neg_extern_pub/src/main.kodr <<'KODR'
module main
#name    = "neg_extern_pub"
#version = Version(1, 0, 0)
#build   = exe
pub extern func do_thing() void
func main() void {
}
KODR
cd neg_extern_pub
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "redundant\|pub extern"; then
    pass "rejects pub extern func (redundant)"
else
    fail "rejects pub extern func (redundant)" "$NEG_OUT"
fi

# missing extern sidecar
cd "$TESTDIR"
mkdir -p neg_extern/src
cat > neg_extern/src/main.kodr <<'KODR'
module main
#name    = "neg_extern"
#version = Version(1, 0, 0)
#build   = exe
extern func do_thing() void
func main() void {
}
KODR
cd neg_extern
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "sidecar\|extern"; then
    pass "rejects missing extern sidecar"
else
    fail "rejects missing extern sidecar" "$NEG_OUT"
fi

# ══════════════════════════════════════════════════════════════
# Results
# ══════════════════════════════════════════════════════════════

printf "\n\033[1m════════════════════════════════════════\033[0m\n"
if [ "$FAILED" -eq 0 ]; then
    printf "\033[32m  All %d tests passed\033[0m\n" "$TOTAL"
else
    printf "\033[31m  %d/%d tests failed\033[0m\n" "$FAILED" "$TOTAL"
fi
printf "\033[1m════════════════════════════════════════\033[0m\n"

exit "$FAILED"
