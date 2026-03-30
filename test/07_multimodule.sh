#!/usr/bin/env bash
# 07_multimodule.sh — Multi-module project builds
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Multi-module project"

cd "$TESTDIR"
"$ORHON" init multimod >/dev/null 2>&1 || true
cd "$TESTDIR/multimod"

cat > src/utils.orh <<'ORHON'
module utils
pub func double(n: i32) i32 {
    return n + n
}
ORHON

cat > src/main.orh <<'ORHON'
module main
#name    = "multimod"
#version = Version(1, 0, 0)
#build   = exe
import std::console
import utils
func main() void {
    console.println("multi-module works")
}
ORHON

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built: bin/multimod"; then pass "multi-module builds"
else fail "multi-module builds" "$OUTPUT"; fi

BINOUT=$(./bin/multimod 2>&1 || true)
if echo "$BINOUT" | grep -q "multi-module works"; then pass "multi-module runs"
else fail "multi-module runs" "$BINOUT"; fi

section "Multi-target: exe + dynamic lib"

cd "$TESTDIR"
"$ORHON" init dynlink >/dev/null 2>&1 || true
cd "$TESTDIR/dynlink"

# Create a dynamic lib module
cat > src/mathlib.orh <<'ORHON'
module mathlib
#name    = "mathlib"
#build   = dynamic
pub func add(a: i32, b: i32) i32 {
    return a + b
}
ORHON

# Create an exe that imports the dynamic lib
cat > src/main.orh <<'ORHON'
module main
#name    = "dynlink"
#build   = exe
import std::console
import mathlib
func main() void {
    console.println("dynlink ok")
}
ORHON

# Remove example module (not needed)
rm -rf src/example

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built:.*dynlink"; then pass "multi-target: exe built"
else fail "multi-target: exe built" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "Built:.*libmathlib.so"; then pass "multi-target: dynamic lib built"
else fail "multi-target: dynamic lib built" "$OUTPUT"; fi

if [ -f bin/libmathlib.so ]; then pass "multi-target: .so exists"
else fail "multi-target: .so exists"; fi

if [ -f bin/mathlib.orh ]; then pass "multi-target: interface file generated"
else fail "multi-target: interface file generated"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "multi-target: no memory leaks"
else fail "multi-target: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

section "Multi-target: exe + static lib"

cd "$TESTDIR"
"$ORHON" init statlink >/dev/null 2>&1 || true
cd "$TESTDIR/statlink"

# Create a static lib module
cat > src/utils.orh <<'ORHON'
module utils
#name    = "utils"
#build   = static
pub func triple(n: i32) i32 {
    return n * 3
}
ORHON

# Create an exe that imports the static lib
cat > src/main.orh <<'ORHON'
module main
#name    = "statlink"
#build   = exe
import std::console
import utils
func main() void {
    console.println("statlink ok")
}
ORHON

rm -rf src/example

OUTPUT=$("$ORHON" build 2>&1 || true)
if echo "$OUTPUT" | grep -q "Built:.*statlink"; then pass "static-link: exe built"
else fail "static-link: exe built" "$OUTPUT"; fi

if echo "$OUTPUT" | grep -q "Built:.*libutils.a"; then pass "static-link: static lib built"
else fail "static-link: static lib built" "$OUTPUT"; fi

if [ -f bin/libutils.a ]; then pass "static-link: .a exists"
else fail "static-link: .a exists"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "static-link: no memory leaks"
else fail "static-link: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

section "Multi-file module with Zig sidecar"

# BLD-01: A module with multiple .orh files AND a Zig sidecar must build
# without 'file exists in two modules' error in the generated build.zig.

cd "$TESTDIR"
mkdir -p sidecarmod/src
cd "$TESTDIR/sidecarmod"

# Anchor file — declares the static lib with a bridge function
cat > src/mylib.orh <<'ORHON'
module mylib
#name  = "mylib"
#build = static

pub bridge func addC(a: i32, b: i32) i32

pub func triple(n: i32) i32 {
    return n * 3
}
ORHON

# Second file in the same module — makes it a multi-file module
cat > src/extras.orh <<'ORHON'
module mylib

pub func double(n: i32) i32 {
    return n + n
}
ORHON

# Zig sidecar implementing the bridge function
cat > src/mylib.zig <<'ZIG'
pub export fn addC(a: i32, b: i32) i32 {
    return a + b;
}
ZIG

# Exe that imports the multi-file+sidecar lib
cat > src/main.orh <<'ORHON'
module main
#name  = "sidecarmod"
#build = exe
import mylib

func main() void {
    const _t: i32 = mylib.triple(4)
    const _d: i32 = mylib.double(5)
}
ORHON

OUTPUT=$(timeout 90 "$ORHON" build 2>&1 || true)
# Check for BLD-01: no "file exists in two modules" error
if echo "$OUTPUT" | grep -q "file exists in"; then fail "multi-file sidecar: no file-exists conflict" "$OUTPUT"
elif echo "$OUTPUT" | grep -q "Built:.*sidecarmod\|Built:.*libmylib"; then pass "multi-file sidecar: builds without conflict"
else fail "multi-file sidecar: builds without conflict" "$OUTPUT"; fi

if ! echo "$OUTPUT" | grep -q "^error(gpa)"; then pass "multi-file sidecar: no memory leaks"
else fail "multi-file sidecar: no memory leaks" "$(echo "$OUTPUT" | grep 'error(gpa)')"; fi

report_results
