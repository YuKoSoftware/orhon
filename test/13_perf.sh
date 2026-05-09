#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

GOLDEN_ROOT="$(dirname "$0")/fixtures/golden"
LOG="$(dirname "$0")/perf.log"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PERF_FIXTURES=(
    basic control structs enums errors matching generics comptime
    slicing cleanup handles interpolation ownership borrow tuples functions
)

section "Perf baseline"

# Read the last complete run block from perf.log into PREV_TIMES.
# Each run is a group of lines separated by a blank line.
declare -A PREV_TIMES
if [ -f "$LOG" ]; then
    prev_block="$(awk '
        /[^[:space:]]/ { block = block $0 "\n"; next }
        block != ""    { last = block; block = "" }
        END            { if (block != "") last = block; printf "%s", last }
    ' "$LOG")"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(awk '{print $2}' <<< "$line")
        ms_raw=$(awk '{print $3}' <<< "$line")
        PREV_TIMES["$name"]="${ms_raw%ms}"
    done <<< "$prev_block"
fi

# Rotate log: keep only the most recent previous run for baseline comparison.
# New data appended below will become the second run; next invocation will
# again keep only the last block, so the file holds at most 2 runs.
if [ -f "$LOG" ] && [ -n "$prev_block" ]; then
    printf "%s\n\n" "$prev_block" > "$LOG"
fi

perf_line() {
    local name=$1 ms=$2
    local prev="${PREV_TIMES[$name]:-}"
    local note="(no baseline)"
    if [[ -n "$prev" ]]; then
        local delta=$(( ms - prev ))
        if (( delta >= 0 )); then
            note="(was ${prev}ms, +${delta}ms)"
        else
            note="(was ${prev}ms, -$(( -delta ))ms)"
        fi
    fi
    printf "  PERF  %-20s %5dms  %s\n" "$name" "$ms" "$note"
}

for name in "${PERF_FIXTURES[@]}"; do
    fixture_tmp="$TESTDIR/$name"
    cp -r "$GOLDEN_ROOT/$name" "$fixture_tmp"
    rm -rf "$fixture_tmp/.orh-cache" 2>/dev/null || true

    t0=$(date +%s%N)
    (cd "$fixture_tmp" && "$ORHON" build >/dev/null 2>&1 || true)
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))

    perf_line "$name" "$ms"
    printf "%s  %-20s %dms\n" "$TIMESTAMP" "$name" "$ms" >> "$LOG"
done

printf "\n" >> "$LOG"
