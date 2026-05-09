#!/usr/bin/env bash
# 04_init.sh — Project scaffolding (orhon init, embedded std)
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "orhon init"

cd "$TESTDIR"
OUTPUT=$("$ORHON" init testproj 2>&1)

if echo "$OUTPUT" | grep -q "Created project 'testproj'"; then
    pass "prints success message"
else
    fail "prints success message" "$OUTPUT"
fi

if [ -d testproj/src ]; then pass "creates src/ directory"
else fail "creates src/ directory"; fi

if [ -f testproj/src/testproj.orh ]; then pass "creates testproj.orh"
else fail "creates testproj.orh"; fi

if [ -d testproj/src/example ]; then pass "creates src/example/ directory"
else fail "creates src/example/ directory"; fi

if [ -f testproj/src/example/example.orh ]; then pass "creates example/example.orh"
else fail "creates example/example.orh"; fi

if [ -f testproj/src/example/control_flow.orh ]; then pass "creates example/control_flow.orh"
else fail "creates example/control_flow.orh"; fi

if [ -f testproj/src/example/error_handling.orh ]; then pass "creates example/error_handling.orh"
else fail "creates example/error_handling.orh"; fi

if [ -f testproj/src/example/data_types.orh ]; then pass "creates example/data_types.orh"
else fail "creates example/data_types.orh"; fi

if [ -f testproj/src/example/strings.orh ]; then pass "creates example/strings.orh"
else fail "creates example/strings.orh"; fi

if [ -f testproj/src/example/advanced.orh ]; then pass "creates example/advanced.orh"
else fail "creates example/advanced.orh"; fi

if head -1 testproj/src/testproj.orh | grep -q "^module testproj$"; then
    pass "testproj.orh has 'module testproj'"
else
    fail "testproj.orh has 'module testproj'"
fi

if [ -f testproj/orhon.project ]; then
    pass "creates orhon.project manifest"
else
    fail "creates orhon.project manifest"
fi

if grep -q '#build   = exe' testproj/orhon.project; then
    pass "orhon.project has #build = exe"
else
    fail "orhon.project has #build = exe"
fi

if grep -q '#build' testproj/src/testproj.orh; then
    fail "testproj.orh should not have #build"
else
    pass "testproj.orh has no #build"
fi

if grep -q "^module example$" testproj/src/example/example.orh; then
    pass "example.orh has 'module example'"
else
    fail "example.orh has 'module example'"
fi

if "$ORHON" init testproj 2>&1 | grep -q "Created project"; then
    pass "init on existing dir succeeds"
else
    fail "init on existing dir succeeds"
fi

section "orhon init — name validation"

cd "$TESTDIR"
if "$ORHON" init "bad name!" 2>/dev/null; then
    fail "rejects invalid project name"
else
    pass "rejects invalid project name"
fi

section "embedded std (auto-extracted on build)"

cd "$TESTDIR/testproj"
"$ORHON" build >/dev/null 2>&1 || true

if [ -f .orh-cache/std/console.orh ]; then pass "build extracts std/console.orh"
else fail "build extracts std/console.orh"; fi

# Zig sidecar files are generated in .orh-cache/generated/ (lazy, in-memory processing)
if [ -f .orh-cache/generated/console_zig.zig ]; then pass "build generates std/console_zig.zig"
else fail "build generates std/console_zig.zig"; fi

# Verify the generated .orh has the expected stdlib declarations
if grep -q "pub func print" .orh-cache/std/console.orh; then
    pass "console.orh contains print function"
else
    fail "console.orh contains print function"
fi

section "orhon init -update"

# Set up a fresh project for update tests
mkdir -p "$TESTDIR/updatetest" && cd "$TESTDIR/updatetest"
"$ORHON" init >/dev/null 2>&1

if [ -f .orh-cache/init.stamp ]; then
    pass "init creates .orh-cache/init.stamp"
else
    fail "init creates .orh-cache/init.stamp"
fi

ORHON_VER=$("$ORHON" version 2>&1 | sed 's/orhon //')
STAMP_VER=$(cat .orh-cache/init.stamp)
if [ "$STAMP_VER" = "$ORHON_VER" ]; then
    pass "stamp contains current compiler version"
else
    fail "stamp contains current compiler version (got '$STAMP_VER', expected '$ORHON_VER')"
fi

# Named-project init should also write the stamp inside the new project dir
mkdir -p "$TESTDIR/namedstamptest"
cd "$TESTDIR/namedstamptest"
"$ORHON" init namedtest >/dev/null 2>&1

if [ -f namedtest/.orh-cache/init.stamp ]; then
    pass "named init creates stamp inside project dir"
else
    fail "named init creates stamp inside project dir"
fi

STAMP_VER=$(cat namedtest/.orh-cache/init.stamp)
ORHON_VER=$("$ORHON" version 2>&1 | sed 's/orhon //')
if [ "$STAMP_VER" = "$ORHON_VER" ]; then
    pass "named init stamp contains current version"
else
    fail "named init stamp contains current version (got '$STAMP_VER', expected '$ORHON_VER')"
fi

cd "$TESTDIR/updatetest"
OUTPUT=$("$ORHON" init -update 2>&1)
if echo "$OUTPUT" | grep -q "already up to date"; then
    pass "init -update prints 'already up to date' when stamp matches"
else
    fail "init -update prints 'already up to date' when stamp matches" "$OUTPUT"
fi

echo "0.0.0" > .orh-cache/init.stamp
OUTPUT=$("$ORHON" init -update 2>&1)
if echo "$OUTPUT" | grep -q "stamp updated"; then
    pass "init -update refreshes files when stamp is stale"
else
    fail "init -update refreshes files when stamp is stale" "$OUTPUT"
fi

if echo "$OUTPUT" | grep -q "updated  src/example/example.orh"; then
    pass "init -update reports each updated file"
else
    fail "init -update reports each updated file" "$OUTPUT"
fi

if [ -f src/example/example.orh ]; then
    pass "example files present after -update"
else
    fail "example files present after -update"
fi

cd "$TESTDIR"
if "$ORHON" init myproject -update 2>/dev/null; then
    fail "-update with name argument should be rejected"
else
    pass "-update with name argument is rejected"
fi

mkdir -p "$TESTDIR/notaproject" && cd "$TESTDIR/notaproject"
if "$ORHON" init -update 2>/dev/null; then
    fail "-update outside project dir should be rejected"
else
    pass "-update outside project dir is rejected"
fi

report_results
