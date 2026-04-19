#!/usr/bin/env bash
# 08_codegen.sh — Generated Zig quality checks
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Generated Zig quality"

cd "$TESTDIR"
"$ORHON" init gentest >/dev/null 2>&1 || true
cd "$TESTDIR/gentest"
"$ORHON" build >/dev/null 2>&1 || true

MAIN_ZIG=".orh-cache/generated/gentest.zig"
EXAMPLE_ZIG=".orh-cache/generated/example.zig"

# ── Basic structure ───────────────────────────────────────────

if grep -q "// generated from module gentest" "$MAIN_ZIG"; then
    pass "module header comment"
else
    fail "module header comment"
fi

if grep -q 'const std = @import("std")' "$MAIN_ZIG"; then
    pass "imports std"
else
    fail "imports std"
fi

if grep -q 'const console = @import("console")' "$MAIN_ZIG"; then
    pass "imports console"
else
    fail "imports console"
fi

# ── Example module codegen ────────────────────────────────────

if grep -q "const Point" "$EXAMPLE_ZIG"; then
    pass "struct definitions"
else
    fail "struct definitions"
fi

if grep -q "fn add" "$EXAMPLE_ZIG"; then
    pass "function definitions"
else
    fail "function definitions"
fi

# ── Specific codegen patterns ────────────────────────────────

if grep -q "fn double(comptime" "$EXAMPLE_ZIG"; then pass "compt func → comptime params"
else fail "compt func → comptime params"; fi

if grep -q "pub fn main" "$MAIN_ZIG"; then pass "main is pub"
else fail "main is pub"; fi

# ── Bare call discard ────────────────────────────────────────

# Build a project with a bare call to a non-void function
cd "$TESTDIR"
mkdir -p discardtest/src
cat > discardtest/src/discardtest.orh <<'ORHON'
module discardtest
#version = (1, 0, 0)
#build   = exe
import std::console
func compute() i32 {
    return 42
}
func main() void {
    compute()
    console.println("ok")
}
ORHON
cd discardtest
"$ORHON" build >/dev/null 2>&1 || true

if grep -q '_ = ' .orh-cache/generated/discardtest.zig; then pass "bare call discards return value"
else fail "bare call discards return value"; fi

# ── Interpolation error propagation ─────────────────────────────

# Verify codegen.zig emits safe error propagation for interpolation allocPrint calls.
# generateInterpolatedStringMirFromStore must use 'catch |err| return err' instead
# of 'catch unreachable' (consolidated into one function after B10 MirStore migration).

CODEGEN_SRC="$REPO_DIR/src/codegen/codegen.zig"
CODEGEN_MATCH="$REPO_DIR/src/codegen/codegen_match.zig"

# MIR interpolation functions are in codegen_match.zig
INTERP_SAFE_COUNT=$(grep -c 'catch |err| return err' "$CODEGEN_MATCH" 2>/dev/null || echo 0)
if [ "$INTERP_SAFE_COUNT" -ge 1 ]; then
    pass "interpolation propagates OOM (no catch unreachable)"
else
    fail "interpolation propagates OOM (no catch unreachable)"
fi

# ── Codegen snapshot tests ───────────────────────────────────

section "Codegen snapshots"

snapshot_test() {
    local name="$1"
    local projdir="$TESTDIR/snaptest_${name}"
    mkdir -p "$projdir/src"
    cp "$REPO_DIR/test/snapshots/snap_${name}.orh" "$projdir/src/snap_${name}.orh"
    cp "$REPO_DIR/test/snapshots/snap_${name}_main.orh" "$projdir/src/snaptest_${name}.orh"
    cd "$projdir"
    "$ORHON" build >/dev/null 2>&1 || true

    local generated=".orh-cache/generated/snap_${name}.zig"
    local expected="$REPO_DIR/test/snapshots/expected/snap_${name}.zig"

    if [ ! -f "$generated" ]; then
        fail "snapshot: $name" "generated file not found"
        return
    fi

    local diff_out
    diff_out=$(git diff --no-index "$expected" "$generated" 2>&1) || true
    if [ -z "$diff_out" ]; then
        pass "snapshot: $name"
    else
        fail "snapshot: $name" "codegen output differs from expected"
        echo "$diff_out" | head -20
    fi
}

snapshot_test "basics"
snapshot_test "structs"
snapshot_test "control"
snapshot_test "errors"

report_results
