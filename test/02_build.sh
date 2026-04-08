#!/usr/bin/env bash
# 02_build.sh — Compile the Orhon compiler
source "$(dirname "$0")/helpers.sh"

section "Zig build"

cd "$REPO_DIR"
if zig build 2>&1; then
    pass "zig build"
else
    fail "zig build"
    exit 1
fi

if [ -x "$ORHON" ]; then
    pass "orhon binary exists"
else
    fail "orhon binary exists"
fi

report_results
