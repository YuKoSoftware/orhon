#!/usr/bin/env bash
# 11_errors.sh — Negative tests (expected compilation failures)
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Negative tests (expected failures)"

# build outside a project
cd "$TESTDIR"
mkdir -p noproject && cd noproject
if ! "$ORHON" build 2>/dev/null; then pass "fails outside a project"
else fail "fails outside a project"; fi

# missing module declaration
cd "$TESTDIR"
mkdir -p neg_module/src
cp "$FIXTURES/fail_missing_module.orh" neg_module/src/main.orh
cd neg_module
NEG_OUT=$("$ORHON" build 2>&1 || true)
if [ $? -ne 0 ] || echo "$NEG_OUT" | grep -qi "module\|error"; then
    pass "rejects missing module declaration"
else
    fail "rejects missing module declaration" "$NEG_OUT"
fi

# missing import
cd "$TESTDIR"
mkdir -p neg_import/src
cp "$FIXTURES/fail_missing_import.orh" neg_import/src/main.orh
cd neg_import
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "not found\|error"; then
    pass "rejects missing import"
else
    fail "rejects missing import" "$NEG_OUT"
fi

# missing anchor file
cd "$TESTDIR"
mkdir -p neg_anchor/src
cat > neg_anchor/src/main.orh <<'ORHON'
module main
#name    = "neg_anchor"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
}
ORHON
cp "$FIXTURES/fail_no_anchor.orh" neg_anchor/src/misnamed.orh
cd neg_anchor
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "no anchor file"; then
    pass "rejects missing anchor file"
else
    fail "rejects missing anchor file" "$NEG_OUT"
fi

# missing bridge sidecar
cd "$TESTDIR"
mkdir -p neg_bridge/src
cat > neg_bridge/src/main.orh <<'ORHON'
module main
#name    = "neg_bridge"
#version = Version(1, 0, 0)
#build   = exe
bridge func do_thing() void
func main() void {
}
ORHON
cd neg_bridge
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "sidecar\|bridge"; then
    pass "rejects missing bridge sidecar"
else
    fail "rejects missing bridge sidecar" "$NEG_OUT"
fi

# missing import error
cd "$TESTDIR"
"$ORHON" init badimport >/dev/null 2>&1
cat > "$TESTDIR/badimport/src/main.orh" <<'ORHON'
module main
#name    = "badimport"
#version = Version(1, 0, 0)
#build   = exe
import nonexistent
func main() void {
}
ORHON
cd "$TESTDIR/badimport"
BADIMPORT_OUT=$("$ORHON" build 2>&1 || true)
if echo "$BADIMPORT_OUT" | grep -qi "not found"; then pass "missing import error"
else fail "missing import error" "$BADIMPORT_OUT"; fi

# missing module error
cd "$TESTDIR"
"$ORHON" init nomodule >/dev/null 2>&1
echo "func main() void {}" > "$TESTDIR/nomodule/src/main.orh"
cd "$TESTDIR/nomodule"
NOMOD_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NOMOD_OUT" | grep -qi "missing module\|no module\|module"; then
    pass "missing module error"
else
    fail "missing module error" "$NOMOD_OUT"
fi

# missing anchor file error
cd "$TESTDIR"
"$ORHON" init noanchor >/dev/null 2>&1
cat > "$TESTDIR/noanchor/src/wrong_name.orh" <<'ORHON'
module utils
pub func helper() i32 {
    return 42
}
ORHON
cd "$TESTDIR/noanchor"
ANCHOR_OUT=$("$ORHON" build 2>&1 || true)
if echo "$ANCHOR_OUT" | grep -qi "no anchor file"; then pass "missing anchor file error"
else fail "missing anchor file error" "$ANCHOR_OUT"; fi

# unjoined thread error
cd "$TESTDIR"
mkdir -p neg_thread/src
cat > neg_thread/src/main.orh <<'ORHON'
module main
#name    = "neg_thread"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32

thread worker(x: i32) Handle(i32) {
    return Handle(x * 2)
}

func main() void {
    const h: Handle(i32) = worker(42)
}
ORHON
cd neg_thread
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "must be joined"; then pass "rejects unjoined thread"
else fail "rejects unjoined thread" "$NEG_OUT"; fi

# use after splitAt error
cd "$TESTDIR"
mkdir -p neg_split/src
cat > neg_split/src/main.orh <<'ORHON'
module main
#name    = "neg_split"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32
func main() void {
    const arr: [4]i32 = [1, 2, 3, 4]
    const left, right = arr.splitAt(2)
    const x: i32 = arr[0]
}
ORHON
cd neg_split
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "moved\|use of"; then pass "rejects use after splitAt"
else fail "rejects use after splitAt" "$NEG_OUT"; fi

# return type mismatch
cd "$TESTDIR"
mkdir -p neg_rettype/src
cat > neg_rettype/src/main.orh <<'ORHON'
module main
#name    = "neg_rettype"
#version = Version(1, 0, 0)
#build   = exe
func foo() i32 {
    return "hello"
}
func main() void {
}
ORHON
cd neg_rettype
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "return type mismatch"; then pass "rejects return type mismatch"
else fail "rejects return type mismatch" "$NEG_OUT"; fi

# non-bool if condition
cd "$TESTDIR"
mkdir -p neg_ifcond/src
cat > neg_ifcond/src/main.orh <<'ORHON'
module main
#name    = "neg_ifcond"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    if(42) { }
}
ORHON
cd neg_ifcond
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "condition must be bool"; then pass "rejects non-bool if condition"
else fail "rejects non-bool if condition" "$NEG_OUT"; fi

# non-bool while condition
cd "$TESTDIR"
mkdir -p neg_whilecond/src
cat > neg_whilecond/src/main.orh <<'ORHON'
module main
#name    = "neg_whilecond"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    while(42) { }
}
ORHON
cd neg_whilecond
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "condition must be bool"; then pass "rejects non-bool while condition"
else fail "rejects non-bool while condition" "$NEG_OUT"; fi

# break outside loop
cd "$TESTDIR"
mkdir -p neg_break/src
cat > neg_break/src/main.orh <<'ORHON'
module main
#name    = "neg_break"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    break
}
ORHON
cd neg_break
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "break.*outside"; then pass "rejects break outside loop"
else fail "rejects break outside loop" "$NEG_OUT"; fi

# continue outside loop
cd "$TESTDIR"
mkdir -p neg_continue/src
cat > neg_continue/src/main.orh <<'ORHON'
module main
#name    = "neg_continue"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    continue
}
ORHON
cd neg_continue
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "continue.*outside"; then pass "rejects continue outside loop"
else fail "rejects continue outside loop" "$NEG_OUT"; fi

# var &T rejected (use &T instead)
cd "$TESTDIR"
mkdir -p neg_varref/src
cat > neg_varref/src/main.orh <<'ORHON'
module main
#name    = "neg_varref"
#version = Version(1, 0, 0)
#build   = exe
struct Foo {
    x: i32
    func set(self: var &Foo, v: i32) void {
        self.x = v
    }
}
func main() void { }
ORHON
cd neg_varref
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "var &T.*not valid"; then pass "rejects var &T (use &T)"
else fail "rejects var &T (use &T)" "$NEG_OUT"; fi

# type mismatch on assignment (string to int)
cd "$TESTDIR"
mkdir -p neg_typemismatch/src
cat > neg_typemismatch/src/main.orh <<'ORHON'
module main
#name    = "neg_typemismatch"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    var x: i32 = "hello"
}
ORHON
cd neg_typemismatch
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "type mismatch"; then pass "rejects type mismatch on assignment"
else fail "rejects type mismatch on assignment" "$NEG_OUT"; fi

# duplicate variable in same scope
cd "$TESTDIR"
mkdir -p neg_dupvar/src
cat > neg_dupvar/src/main.orh <<'ORHON'
module main
#name    = "neg_dupvar"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    const x: i32 = 1
    const x: i32 = 2
}
ORHON
cd neg_dupvar
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "already declared"; then pass "rejects duplicate variable"
else fail "rejects duplicate variable" "$NEG_OUT"; fi

# default param before required param
cd "$TESTDIR"
mkdir -p neg_default_order/src
cat > neg_default_order/src/main.orh <<'ORHON'
module main
#name    = "neg_default_order"
#version = Version(1, 0, 0)
#build   = exe
func foo(a: i32 = 5, b: i32) i32 {
    return a + b
}
func main() void { }
ORHON
cd neg_default_order
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "defaults.*must.*after\|required.*param"; then pass "rejects default before required param"
else fail "rejects default before required param" "$NEG_OUT"; fi

# []u8 → String coercion rejected
cd "$TESTDIR"
mkdir -p neg_u8str/src
cat > neg_u8str/src/main.orh <<'ORHON'
module main
#name    = "neg_u8str"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32
func greet(s: String) void { }
func main() void {
    var buf: [5]u8 = [104, 101, 108, 108, 111]
    const slice: []u8 = buf[0..5]
    greet(slice)
}
ORHON
cd neg_u8str
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "cannot pass.*u8.*String\|fromBytes"; then pass "rejects []u8 as String"
else fail "rejects []u8 as String" "$NEG_OUT"; fi

# duplicate anchor file
cd "$TESTDIR"
mkdir -p neg_dup_anchor/src/sub
cat > neg_dup_anchor/src/main.orh <<'ORHON'
module main
#name    = "neg_dup"
#version = Version(1, 0, 0)
#build   = exe
func main() void { }
ORHON
cat > neg_dup_anchor/src/example.orh <<'ORHON'
module example
func foo() i32 { return 1 }
ORHON
cat > neg_dup_anchor/src/sub/example.orh <<'ORHON'
module example
func bar() i32 { return 2 }
ORHON
cd neg_dup_anchor
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "anchor"; then pass "rejects duplicate anchor files"
else fail "rejects duplicate anchor files" "$NEG_OUT"; fi

# mutable ref across bridge
cd "$TESTDIR"
mkdir -p neg_bridge_ref/src
cat > neg_bridge_ref/src/main.orh <<'ORHON'
module main
#name    = "neg_bridge"
#version = Version(1, 0, 0)
#build   = exe
bridge func modify(data: &i32) void
func main() void { }
ORHON
cat > neg_bridge_ref/src/main.zig <<'ZIG'
pub fn modify(data: *i32) void { data.* = 0; }
ZIG
cd neg_bridge_ref
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "mutable reference.*not allowed.*bridge"; then pass "rejects mutable ref across bridge"
else fail "rejects mutable ref across bridge" "$NEG_OUT"; fi

# Version() outside metadata
cd "$TESTDIR"
mkdir -p neg_version/src
cat > neg_version/src/main.orh <<'ORHON'
module main
#name    = "neg_version"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32
func main() void {
    const v = Version(2, 0, 0)
}
ORHON
cd neg_version
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "Version.*metadata"; then pass "rejects Version() in function body"
else fail "rejects Version() in function body" "$NEG_OUT"; fi

# ── Fixture-based category tests ─────────────────────────────
# Each fixture tests one compiler pass with multiple error cases.
# Helper: run a fixture as a project and check for expected error
run_fixture() {
    local name="$1" fixture="$2" pattern="$3" label="$4"
    cd "$TESTDIR"
    mkdir -p "$name/src"
    cp "$FIXTURES/$fixture" "$name/src/main.orh"
    cd "$name"
    NEG_OUT=$("$ORHON" build 2>&1 || true)
    if echo "$NEG_OUT" | grep -qi "$pattern"; then pass "$label"
    else fail "$label" "$NEG_OUT"; fi
}

# syntax (parser) errors
run_fixture neg_syntax fail_syntax.orh "module-level.*var.*not allowed" "fixture: rejects module-level var"

# type resolution errors
run_fixture neg_types fail_types.orh "unknown type" "fixture: catches unknown types"
run_fixture neg_types2 fail_types.orh "already declared" "fixture: catches duplicate variable"
run_fixture neg_types3 fail_types.orh "return type mismatch" "fixture: catches return type mismatch"
run_fixture neg_types4 fail_types.orh "condition must be bool" "fixture: catches non-bool condition"
run_fixture neg_types5 fail_types.orh "type mismatch" "fixture: catches type mismatch"
run_fixture neg_types6 fail_types.orh "break.*outside\|continue.*outside" "fixture: catches break/continue outside loop"

# ownership errors
run_fixture neg_own fail_ownership.orh "use of moved value\|moved" "fixture: catches use after move"

# thread safety errors
run_fixture neg_thread2 fail_threads.orh "must be joined" "fixture: catches unjoined thread"

# borrow errors
run_fixture neg_borrow fail_borrow.orh "cannot borrow\|already borrowed" "fixture: catches borrow conflict"
# propagation errors
run_fixture neg_prop fail_propagation.orh "unhandled.*union\|cannot propagate" "fixture: catches unhandled error union"
run_fixture neg_unwrap fail_propagation.orh "unsafe unwrap" "fixture: catches unsafe union unwrap"
run_fixture neg_callnonfunc fail_types.orh "not callable" "fixture: rejects calling non-function"
run_fixture neg_indexbool fail_types.orh "cannot index" "fixture: rejects indexing non-indexable"
run_fixture neg_matcharm fail_types.orh "not a member" "fixture: rejects invalid match arm type"

# struct errors
run_fixture neg_struct_dup fail_structs.orh "duplicate field" "fixture: catches duplicate struct field"

# enum errors
run_fixture neg_enum_dup fail_enums.orh "duplicate variant" "fixture: catches duplicate enum variant"

# function errors (first error in file: default before required)
run_fixture neg_func fail_functions.orh "defaults.*must.*after\|required.*param" "fixture: catches default before required param"

# scope errors (module-level var fires first since it's a parser error)
run_fixture neg_scope fail_scope.orh "module-level.*var.*not allowed\|already declared" "fixture: catches scope errors"

# match errors
run_fixture neg_match fail_match.orh "not a member" "fixture: catches invalid match arm"

# old ptr syntax rejected
cd "$TESTDIR"
mkdir -p neg_ptr_cast/src
cp "$FIXTURES/fail_ptr_cast.orh" neg_ptr_cast/src/main.orh
cd neg_ptr_cast
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "error\|parse\|unexpected"; then
    pass "rejects old Ptr(T).cast() syntax"
else
    fail "rejects old Ptr(T).cast() syntax" "$NEG_OUT"
fi

report_results
