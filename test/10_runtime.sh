#!/usr/bin/env bash
# 10_runtime.sh — Runtime correctness (tester binary output)
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Runtime correctness"

cd "$TESTDIR"
mkdir -p comptest/src
cp "$FIXTURES/tester_main.orh" comptest/src/main.orh
cp "$FIXTURES/tester.orh" comptest/src/tester.orh
cd "$TESTDIR/comptest"

"$ORHON" build >/dev/null 2>&1 || true
BINOUT=$(./bin/comptest 2>&1 || true)

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
    null_some null_none null_inferred null_reassign enum_usage enum_method nested_scopes \
    arithmetic comparisons logical bitwise defer greeting concat \
    tuple tuple_destruct slice_for for_index for_range while_continue \
    cast_int cast_float cast_float_to_int func_ptr func_ptr_var \
    fixed_array array_index slice_expr raw_ptr safe_ptr typeid_same \
    typeid_diff match_range match_string list list_len map set map_iter set_iter \
    split_at split_list \
    wrap sat overflow alloc_default arb_union_return \
    arb_union_match arb_union_field arb_union_assign arb_union_three \
    arb_value_positive arb_value_negative arb_value_inside arb_value_match \
    str_upper str_lower str_replace str_repeat str_parse_int str_parse_float \
    default_param tostring_int tostring_bool \
    interpolation interpolation_int \
    string_eq string_ne string_eq_literal string_eq_param \
    thread thread_multi thread_params thread_void thread_done thread_join \
    map_get \
    bitfield_constructor bitfield_methods; do
    if echo "$BINOUT" | grep -q "PASS $TEST_NAME"; then pass "runtime: $TEST_NAME"
    else fail "runtime: $TEST_NAME"; fi
done

report_results
