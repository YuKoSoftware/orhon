#!/usr/bin/env bash
# 06_library.sh — Static and dynamic library builds
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Static library"

cd "$TESTDIR"
"$ORHON" init testlib >/dev/null 2>&1 || true
cd "$TESTDIR/testlib"

sed -i 's/#build   = exe/#build   = static/' src/main.orh

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/libtestlib.a"; then pass "static: reports success"
else fail "static: reports success" "$OUTPUT"; fi

if [ -f bin/libtestlib.a ]; then pass "static: produces .a archive"
else fail "static: produces .a archive"; fi

if [ -f bin/testlib.orh ]; then pass "static: generates interface file"
else fail "static: generates interface file"; fi

if head -1 bin/testlib.orh | grep -q "// Orhon interface file"; then pass "static: interface has header comment"
else fail "static: interface has header comment"; fi

if grep -q "^module " bin/testlib.orh; then pass "static: interface has module declaration"
else fail "static: interface has module declaration"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "static: no memory leaks"
else fail "static: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

section "Dynamic library"

sed -i 's/#build   = static/#build   = dynamic/' src/main.orh
rm -rf .orh-cache bin

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/libtestlib.so"; then pass "dynamic: reports success"
else fail "dynamic: reports success" "$OUTPUT"; fi

if [ -f bin/libtestlib.so ]; then pass "dynamic: produces .so library"
else fail "dynamic: produces .so library"; fi

if [ -f bin/testlib.orh ]; then pass "dynamic: generates interface file"
else fail "dynamic: generates interface file"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "dynamic: no memory leaks"
else fail "dynamic: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

section "Interface file import"

# Build a minimal library with a pub function
cd "$TESTDIR"
mkdir -p ifacelib/src
cat > ifacelib/src/ifacelib.orh <<'ORHON'
module ifacelib
#name    = "ifacelib"
#version = Version(1, 0, 0)
#build   = static
pub func add(a: i32, b: i32) i32 {
    return a + b
}
ORHON
cd ifacelib
"$ORHON" build >/dev/null 2>&1 || true

if [ -f bin/ifacelib.orh ]; then pass "iface: library interface generated"
else fail "iface: library interface generated"; fi

# Verify the interface file can be parsed by another project
cd "$TESTDIR"
mkdir -p ifaceuser/src
cat > ifaceuser/src/main.orh <<'ORHON'
module main
#name    = "ifaceuser"
#version = Version(1, 0, 0)
#build   = exe
import ifacelib
func main() void {
}
ORHON
cp "$TESTDIR/ifacelib/bin/ifacelib.orh" ifaceuser/src/ifacelib.orh
cd ifaceuser
IFACE_OUT=$("$ORHON" build 2>&1 || true)
if echo "$IFACE_OUT" | grep -q "Built:"; then pass "iface: consumer project builds"
else fail "iface: consumer project builds" "$IFACE_OUT"; fi

report_results
