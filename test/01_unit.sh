#!/usr/bin/env bash
# 01_unit.sh — Zig unit tests (compiler internals)
source "$(dirname "$0")/helpers.sh"

section "Zig unit tests"

cd "$REPO_DIR"
if zig build test 2>&1; then
    pass "zig build test"
else
    fail "zig build test"
fi

report_results
