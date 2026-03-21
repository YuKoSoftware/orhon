#!/usr/bin/env bash
# 11_errors.sh — Negative tests (expected compilation failures)
source "$(dirname "$0")/helpers.sh"
require_kodr
setup_tmpdir
trap cleanup_tmpdir EXIT

section "Negative tests (expected failures)"

# build outside a project
cd "$TESTDIR"
mkdir -p noproject && cd noproject
if ! "$KODR" build 2>/dev/null; then pass "fails outside a project"
else fail "fails outside a project"; fi

# missing module declaration
cd "$TESTDIR"
mkdir -p neg_module/src
cp "$FIXTURES/fail_missing_module.kodr" neg_module/src/main.kodr
cd neg_module
NEG_OUT=$("$KODR" build 2>&1 || true)
if [ $? -ne 0 ] || echo "$NEG_OUT" | grep -qi "module\|error"; then
    pass "rejects missing module declaration"
else
    fail "rejects missing module declaration" "$NEG_OUT"
fi

# missing import
cd "$TESTDIR"
mkdir -p neg_import/src
cp "$FIXTURES/fail_missing_import.kodr" neg_import/src/main.kodr
cd neg_import
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "not found\|error"; then
    pass "rejects missing import"
else
    fail "rejects missing import" "$NEG_OUT"
fi

# missing anchor file
cd "$TESTDIR"
mkdir -p neg_anchor/src
cat > neg_anchor/src/main.kodr <<'KODR'
module main
#name    = "neg_anchor"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
}
KODR
cp "$FIXTURES/fail_no_anchor.kodr" neg_anchor/src/misnamed.kodr
cd neg_anchor
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "no anchor file"; then
    pass "rejects missing anchor file"
else
    fail "rejects missing anchor file" "$NEG_OUT"
fi

# pub extern func must error (redundant)
cd "$TESTDIR"
mkdir -p neg_extern_pub/src
cat > neg_extern_pub/src/main.kodr <<'KODR'
module main
#name    = "neg_extern_pub"
#version = Version(1, 0, 0)
#build   = exe
pub extern func do_thing() void
func main() void {
}
KODR
cd neg_extern_pub
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "redundant\|pub extern"; then
    pass "rejects pub extern func (redundant)"
else
    fail "rejects pub extern func (redundant)" "$NEG_OUT"
fi

# missing extern sidecar
cd "$TESTDIR"
mkdir -p neg_extern/src
cat > neg_extern/src/main.kodr <<'KODR'
module main
#name    = "neg_extern"
#version = Version(1, 0, 0)
#build   = exe
extern func do_thing() void
func main() void {
}
KODR
cd neg_extern
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "sidecar\|extern"; then
    pass "rejects missing extern sidecar"
else
    fail "rejects missing extern sidecar" "$NEG_OUT"
fi

# missing import error
cd "$TESTDIR"
"$KODR" init badimport >/dev/null 2>&1
cat > "$TESTDIR/badimport/src/main.kodr" <<'KODR'
module main
#name    = "badimport"
#version = Version(1, 0, 0)
#build   = exe
import nonexistent
func main() void {
}
KODR
cd "$TESTDIR/badimport"
BADIMPORT_OUT=$("$KODR" build 2>&1 || true)
if echo "$BADIMPORT_OUT" | grep -qi "not found"; then pass "missing import error"
else fail "missing import error" "$BADIMPORT_OUT"; fi

# missing module error
cd "$TESTDIR"
"$KODR" init nomodule >/dev/null 2>&1
echo "func main() void {}" > "$TESTDIR/nomodule/src/main.kodr"
cd "$TESTDIR/nomodule"
NOMOD_OUT=$("$KODR" build 2>&1 || true)
if echo "$NOMOD_OUT" | grep -qi "missing module\|no module\|module"; then
    pass "missing module error"
else
    fail "missing module error" "$NOMOD_OUT"
fi

# missing anchor file error
cd "$TESTDIR"
"$KODR" init noanchor >/dev/null 2>&1
cat > "$TESTDIR/noanchor/src/wrong_name.kodr" <<'KODR'
module utils
pub func helper() i32 {
    return 42
}
KODR
cd "$TESTDIR/noanchor"
ANCHOR_OUT=$("$KODR" build 2>&1 || true)
if echo "$ANCHOR_OUT" | grep -qi "no anchor file"; then pass "missing anchor file error"
else fail "missing anchor file error" "$ANCHOR_OUT"; fi

# unjoined thread error
cd "$TESTDIR"
mkdir -p neg_thread/src
cat > neg_thread/src/main.kodr <<'KODR'
module main
#name    = "neg_thread"
#version = Version(1, 0, 0)
#build   = exe
#bitsize = 32
func main() void {
    thread(i32) worker {
        return 42
    }
}
KODR
cd neg_thread
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "must be joined"; then pass "rejects unjoined thread"
else fail "rejects unjoined thread" "$NEG_OUT"; fi

# use after splitAt error
cd "$TESTDIR"
mkdir -p neg_split/src
cat > neg_split/src/main.kodr <<'KODR'
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
KODR
cd neg_split
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "moved\|use of"; then pass "rejects use after splitAt"
else fail "rejects use after splitAt" "$NEG_OUT"; fi

# return type mismatch
cd "$TESTDIR"
mkdir -p neg_rettype/src
cat > neg_rettype/src/main.kodr <<'KODR'
module main
#name    = "neg_rettype"
#version = Version(1, 0, 0)
#build   = exe
func foo() i32 {
    return "hello"
}
func main() void {
}
KODR
cd neg_rettype
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "return type mismatch"; then pass "rejects return type mismatch"
else fail "rejects return type mismatch" "$NEG_OUT"; fi

# non-bool if condition
cd "$TESTDIR"
mkdir -p neg_ifcond/src
cat > neg_ifcond/src/main.kodr <<'KODR'
module main
#name    = "neg_ifcond"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    if(42) { }
}
KODR
cd neg_ifcond
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "condition must be bool"; then pass "rejects non-bool if condition"
else fail "rejects non-bool if condition" "$NEG_OUT"; fi

# non-bool while condition
cd "$TESTDIR"
mkdir -p neg_whilecond/src
cat > neg_whilecond/src/main.kodr <<'KODR'
module main
#name    = "neg_whilecond"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    while(42) { }
}
KODR
cd neg_whilecond
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "condition must be bool"; then pass "rejects non-bool while condition"
else fail "rejects non-bool while condition" "$NEG_OUT"; fi

# break outside loop
cd "$TESTDIR"
mkdir -p neg_break/src
cat > neg_break/src/main.kodr <<'KODR'
module main
#name    = "neg_break"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    break
}
KODR
cd neg_break
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "break.*outside"; then pass "rejects break outside loop"
else fail "rejects break outside loop" "$NEG_OUT"; fi

# continue outside loop
cd "$TESTDIR"
mkdir -p neg_continue/src
cat > neg_continue/src/main.kodr <<'KODR'
module main
#name    = "neg_continue"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    continue
}
KODR
cd neg_continue
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "continue.*outside"; then pass "rejects continue outside loop"
else fail "rejects continue outside loop" "$NEG_OUT"; fi

# var &T rejected (use &T instead)
cd "$TESTDIR"
mkdir -p neg_varref/src
cat > neg_varref/src/main.kodr <<'KODR'
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
KODR
cd neg_varref
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "var &T.*not valid"; then pass "rejects var &T (use &T)"
else fail "rejects var &T (use &T)" "$NEG_OUT"; fi

# type mismatch on assignment (string to int)
cd "$TESTDIR"
mkdir -p neg_typemismatch/src
cat > neg_typemismatch/src/main.kodr <<'KODR'
module main
#name    = "neg_typemismatch"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    var x: i32 = "hello"
}
KODR
cd neg_typemismatch
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "type mismatch"; then pass "rejects type mismatch on assignment"
else fail "rejects type mismatch on assignment" "$NEG_OUT"; fi

# duplicate variable in same scope
cd "$TESTDIR"
mkdir -p neg_dupvar/src
cat > neg_dupvar/src/main.kodr <<'KODR'
module main
#name    = "neg_dupvar"
#version = Version(1, 0, 0)
#build   = exe
func main() void {
    const x: i32 = 1
    const x: i32 = 2
}
KODR
cd neg_dupvar
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "already declared"; then pass "rejects duplicate variable"
else fail "rejects duplicate variable" "$NEG_OUT"; fi

# default param before required param
cd "$TESTDIR"
mkdir -p neg_default_order/src
cat > neg_default_order/src/main.kodr <<'KODR'
module main
#name    = "neg_default_order"
#version = Version(1, 0, 0)
#build   = exe
func foo(a: i32 = 5, b: i32) i32 {
    return a + b
}
func main() void { }
KODR
cd neg_default_order
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "defaults.*must.*after\|required.*param"; then pass "rejects default before required param"
else fail "rejects default before required param" "$NEG_OUT"; fi

# []u8 → String coercion rejected
cd "$TESTDIR"
mkdir -p neg_u8str/src
cat > neg_u8str/src/main.kodr <<'KODR'
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
KODR
cd neg_u8str
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "cannot pass.*u8.*String\|fromBytes"; then pass "rejects []u8 as String"
else fail "rejects []u8 as String" "$NEG_OUT"; fi

# duplicate anchor file
cd "$TESTDIR"
mkdir -p neg_dup_anchor/src/sub
cat > neg_dup_anchor/src/main.kodr <<'KODR'
module main
#name    = "neg_dup"
#version = Version(1, 0, 0)
#build   = exe
func main() void { }
KODR
cat > neg_dup_anchor/src/example.kodr <<'KODR'
module example
func foo() i32 { return 1 }
KODR
cat > neg_dup_anchor/src/sub/example.kodr <<'KODR'
module example
func bar() i32 { return 2 }
KODR
cd neg_dup_anchor
NEG_OUT=$("$KODR" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "anchor"; then pass "rejects duplicate anchor files"
else fail "rejects duplicate anchor files" "$NEG_OUT"; fi

# ── Fixture-based category tests ─────────────────────────────
# Each fixture tests one compiler pass with multiple error cases.
# Helper: run a fixture as a project and check for expected error
run_fixture() {
    local name="$1" fixture="$2" pattern="$3" label="$4"
    cd "$TESTDIR"
    mkdir -p "$name/src"
    cp "$FIXTURES/$fixture" "$name/src/main.kodr"
    cd "$name"
    NEG_OUT=$("$KODR" build 2>&1 || true)
    if echo "$NEG_OUT" | grep -qi "$pattern"; then pass "$label"
    else fail "$label" "$NEG_OUT"; fi
}

# syntax (parser) errors
run_fixture neg_syntax fail_syntax.kodr "module-level.*var.*not allowed" "fixture: rejects module-level var"

# type resolution errors
run_fixture neg_types fail_types.kodr "unknown type" "fixture: catches unknown types"
run_fixture neg_types2 fail_types.kodr "already declared" "fixture: catches duplicate variable"
run_fixture neg_types3 fail_types.kodr "return type mismatch" "fixture: catches return type mismatch"
run_fixture neg_types4 fail_types.kodr "condition must be bool" "fixture: catches non-bool condition"
run_fixture neg_types5 fail_types.kodr "type mismatch" "fixture: catches type mismatch"
run_fixture neg_types6 fail_types.kodr "break.*outside\|continue.*outside" "fixture: catches break/continue outside loop"

# ownership errors
run_fixture neg_own fail_ownership.kodr "use of moved value\|moved" "fixture: catches use after move"

# thread safety errors
run_fixture neg_thread2 fail_threads.kodr "must be joined" "fixture: catches unjoined thread"

# borrow errors
run_fixture neg_borrow fail_borrow.kodr "cannot borrow\|already borrowed" "fixture: catches borrow conflict"
# propagation errors
run_fixture neg_prop fail_propagation.kodr "unhandled.*union\|cannot propagate" "fixture: catches unhandled error union"
run_fixture neg_unwrap fail_propagation.kodr "unsafe unwrap" "fixture: catches unsafe union unwrap"

report_results
