#!/usr/bin/env bash
# 10_runtime.sh — Runtime correctness (tester binary output)
source "$(dirname "$0")/helpers.sh"
require_kodr
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Runtime correctness"

cd "$TESTDIR"
mkdir -p comptest/src
cp "$FIXTURES/tester_main.kodr" comptest/src/main.kodr
cp "$FIXTURES/tester.kodr" comptest/src/tester.kodr
cd "$TESTDIR/comptest"

"$KODR" build >/dev/null 2>&1
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

for TEST_NAME in \
    add sub factorial is_positive compound sum_to match match_default \
    break_continue abs compt_func struct_instantiation default_fields \
    default_override static_method mutable_method error_ok error_fail \
    null_some null_none null_reassign enum_usage enum_method nested_scopes \
    tuple tuple_destruct slice_for for_index for_range while_continue \
    cast_int cast_float cast_float_to_int func_ptr func_ptr_var \
    fixed_array array_index slice_expr raw_ptr safe_ptr typeid_same \
    typeid_diff match_range match_string list list_len map set \
    bitfield wrap sat overflow alloc_default alloc_debug alloc_arena \
    alloc_page alloc_one alloc_slice; do
    if echo "$BINOUT" | grep -q "PASS $TEST_NAME"; then pass "runtime: $TEST_NAME"
    else fail "runtime: $TEST_NAME"; fi
done

report_results
