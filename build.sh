#!/bin/bash

# Kodr — zig build runner
# Builds the project and dumps output to build_log.txt
# Usage: ./build.sh [flags]
#   flags: -x64 | -arm | -wasm | -release | -fast | -zig

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/build_log.txt"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# Pass any flags straight through to zig build
FLAGS="$@"

echo "Running zig build $FLAGS..."

{
    echo "========================================"
    echo "  Kodr Build"
    echo "  $TIMESTAMP"
    if [ -n "$FLAGS" ]; then
        echo "  Flags: $FLAGS"
    fi
    echo "========================================"
    echo ""

    zig build $FLAGS 2>&1

    EXIT_CODE=${PIPESTATUS[0]}

    echo ""
    echo "========================================"
    if [ $EXIT_CODE -eq 0 ]; then
        echo "  Result: SUCCESS"
    else
        echo "  Result: FAILED (exit code $EXIT_CODE)"
    fi
    echo "  Finished: $(date "+%Y-%m-%d %H:%M:%S")"
    echo "========================================"

} | tee "$LOG_FILE"

echo ""
echo "Output saved to: $LOG_FILE"
