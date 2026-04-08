#!/usr/bin/env bash
# testall.sh — Run the complete Orhon test suite
# Each test file is independently runnable: bash test/03_cli.sh
# This script runs them all in pipeline order and aggregates results.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/test_log.txt"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_STAGES=()

# Tee all output to log file
exec > >(tee "$LOG_FILE") 2>&1

run_test() {
    local script="$1"
    local name
    name="$(basename "$script" .sh)"

    if bash "$script"; then
        return 0
    else
        local exit_code=$?
        FAILED_STAGES+=("$name")
        return "$exit_code"
    fi
}

# Count pass/fail from a test script's output
count_results() {
    local output="$1"
    local p f
    p=$(echo "$output" | grep -c "PASS" || true)
    f=$(echo "$output" | grep -c "FAIL" || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
}

TESTS=(
    "$SCRIPT_DIR/test/01_unit.sh"
    "$SCRIPT_DIR/test/02_build.sh"
    "$SCRIPT_DIR/test/03_cli.sh"
    "$SCRIPT_DIR/test/04_init.sh"
    "$SCRIPT_DIR/test/05_compile.sh"
    "$SCRIPT_DIR/test/06_library.sh"
    "$SCRIPT_DIR/test/07_multimodule.sh"
    "$SCRIPT_DIR/test/08_codegen.sh"
    "$SCRIPT_DIR/test/09_language.sh"
    "$SCRIPT_DIR/test/10_runtime.sh"
    "$SCRIPT_DIR/test/11_errors.sh"
)

for test_script in "${TESTS[@]}"; do
    OUTPUT=$(bash "$test_script" 2>&1)
    EXIT_CODE=$?
    echo "$OUTPUT"
    count_results "$OUTPUT"

    # Stage 01 and 02 are critical — abort if they fail
    STAGE=$(basename "$test_script" .sh)
    if [ "$EXIT_CODE" -ne 0 ]; then
        FAILED_STAGES+=("$STAGE")
        if [[ "$STAGE" == "01_unit" || "$STAGE" == "02_build" ]]; then
            printf "\n\033[31m%s failed — aborting.\033[0m\n" "$STAGE"
            break
        fi
    fi
done

# ── Final summary ────────────────────────────────────────────

printf "\n\033[1m════════════════════════════════════════\033[0m\n"
if [ "${#FAILED_STAGES[@]}" -eq 0 ]; then
    printf "\033[32m  All %d tests passed\033[0m\n" "$TOTAL_PASS"
else
    printf "\033[31m  %d passed, %d failed\033[0m\n" "$TOTAL_PASS" "$TOTAL_FAIL"
    printf "\033[31m  Failed stages: %s\033[0m\n" "${FAILED_STAGES[*]}"
fi
printf "\033[1m════════════════════════════════════════\033[0m\n"

[ "${#FAILED_STAGES[@]}" -eq 0 ]
