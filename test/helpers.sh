#!/usr/bin/env bash
# helpers.sh — Shared test utilities for Orhon test suite
# Source this from individual test scripts.

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORHON="$REPO_DIR/zig-out/bin/orhon"
FIXTURES="$REPO_DIR/test/fixtures"
TESTDIR=""

# ── Counters ─────────────────────────────────────────────────
PASSED=0
FAILED=0
TOTAL=0

# ── Output ───────────────────────────────────────────────────
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

# ── Temp directory ───────────────────────────────────────────
setup_tmpdir() {
    TESTDIR="$(mktemp -d /tmp/orhon-test-XXXXXX)"
}

cleanup_tmpdir() {
    [ -n "$TESTDIR" ] && rm -rf "$TESTDIR"
}

# ── Results ──────────────────────────────────────────────────
report_results() {
    if [ "$FAILED" -eq 0 ]; then
        printf "\033[32m  %d/%d passed\033[0m\n" "$PASSED" "$TOTAL"
    else
        printf "\033[31m  %d/%d failed\033[0m\n" "$FAILED" "$TOTAL"
    fi
    return "$FAILED"
}

# ── Require orhon binary ────────────────────────────────────
require_orhon() {
    if [ ! -x "$ORHON" ]; then
        printf "\033[31mOrhon binary not found at %s — run 02_build.sh first.\033[0m\n" "$ORHON"
        exit 1
    fi
}
