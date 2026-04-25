#!/usr/bin/env bash
# 03_cli.sh — CLI argument handling and help output
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "CLI basics"

HELP_OUT=$("$ORHON" help 2>&1 || true)
if echo "$HELP_OUT" | grep -q "The Orhon programming language compiler"; then
    pass "orhon help shows usage"
else
    fail "orhon help shows usage"
fi

if ! "$ORHON" 2>/dev/null; then
    pass "orhon (no args) exits non-zero"
else
    fail "orhon (no args) exits non-zero"
fi

if ! "$ORHON" foobar 2>/dev/null; then
    pass "orhon <unknown> exits non-zero"
else
    fail "orhon <unknown> exits non-zero"
fi

cd "$TESTDIR" && mkdir -p inplace_test && cd inplace_test
if "$ORHON" init >/dev/null 2>&1 && [ -f src/inplace_test.orh ]; then
    pass "orhon init (no name) inits in current dir"
else
    fail "orhon init (no name) inits in current dir"
fi

# orhon version prints a version string
VERSION_OUT=$("$ORHON" version 2>&1 || true)
if echo "$VERSION_OUT" | grep -qE "[0-9]+\.[0-9]+"; then
    pass "orhon version prints version"
else
    fail "orhon version prints version"
fi

section "CLI commands"

# orhon analysis on a valid fixture
ANALYSIS_OUT=$("$ORHON" analysis "$FIXTURES/runtime/blueprint_basic.orh" 2>&1 || true)
if echo "$ANALYSIS_OUT" | grep -q "PASS"; then
    pass "orhon analysis on valid file"
else
    fail "orhon analysis on valid file" "$ANALYSIS_OUT"
fi

# orhon gendoc -syntax produces docs/syntax.md
cd "$TESTDIR"
"$ORHON" init gendoc_proj >/dev/null 2>&1
cd gendoc_proj
mkdir -p docs
"$ORHON" gendoc -syntax >/dev/null 2>&1
if [ -f docs/syntax.md ]; then
    pass "orhon gendoc -syntax produces syntax.md"
else
    fail "orhon gendoc -syntax produces syntax.md"
fi

# orhon build -zig emits Zig source project
cd "$TESTDIR"
"$ORHON" init zigproj >/dev/null 2>&1
cd zigproj
"$ORHON" build -zig >/dev/null 2>&1
if [ -d bin/zig ]; then
    pass "orhon build -zig creates bin/zig/"
else
    fail "orhon build -zig creates bin/zig/"
fi

report_results
