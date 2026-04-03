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
cp "$FIXTURES/fail_missing_module.orh" neg_module/src/neg_module.orh
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
cp "$FIXTURES/fail_missing_import.orh" neg_import/src/neg_import.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_import/' neg_import/src/neg_import.orh
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
cat > neg_anchor/src/neg_anchor.orh <<'ORHON'
module neg_anchor
#name    = "neg_anchor"
#version = (1, 0, 0)
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

# missing import error
cd "$TESTDIR"
"$ORHON" init badimport >/dev/null 2>&1
cat > "$TESTDIR/badimport/src/badimport.orh" <<'ORHON'
module badimport
#name    = "badimport"
#version = (1, 0, 0)
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
echo "func main() void {}" > "$TESTDIR/nomodule/src/nomodule.orh"
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
rm -f "$TESTDIR/noanchor/src/noanchor.orh"
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

# use after @splitAt error
cd "$TESTDIR"
mkdir -p neg_split/src
cat > neg_split/src/neg_split.orh <<'ORHON'
module neg_split
#name    = "neg_split"
#version = (1, 0, 0)
#build   = exe
func main() void {
    const arr: [4]i32 = [1, 2, 3, 4]
    const left, right = @splitAt(arr, 2)
    const x: i32 = arr[0]
}
ORHON
cd neg_split
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "moved\|use of"; then pass "rejects use after @splitAt"
else fail "rejects use after @splitAt" "$NEG_OUT"; fi

# return type mismatch
cd "$TESTDIR"
mkdir -p neg_rettype/src
cat > neg_rettype/src/neg_rettype.orh <<'ORHON'
module neg_rettype
#name    = "neg_rettype"
#version = (1, 0, 0)
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
cat > neg_ifcond/src/neg_ifcond.orh <<'ORHON'
module neg_ifcond
#name    = "neg_ifcond"
#version = (1, 0, 0)
#build   = exe
func main() void {
    if(42) { }
}
ORHON
cd neg_ifcond
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "type mismatch.*condition"; then pass "rejects non-bool if condition"
else fail "rejects non-bool if condition" "$NEG_OUT"; fi

# non-bool while condition
cd "$TESTDIR"
mkdir -p neg_whilecond/src
cat > neg_whilecond/src/neg_whilecond.orh <<'ORHON'
module neg_whilecond
#name    = "neg_whilecond"
#version = (1, 0, 0)
#build   = exe
func main() void {
    while(42) { }
}
ORHON
cd neg_whilecond
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "type mismatch.*condition"; then pass "rejects non-bool while condition"
else fail "rejects non-bool while condition" "$NEG_OUT"; fi

# break outside loop
cd "$TESTDIR"
mkdir -p neg_break/src
cat > neg_break/src/neg_break.orh <<'ORHON'
module neg_break
#name    = "neg_break"
#version = (1, 0, 0)
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
cat > neg_continue/src/neg_continue.orh <<'ORHON'
module neg_continue
#name    = "neg_continue"
#version = (1, 0, 0)
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
cat > neg_varref/src/neg_varref.orh <<'ORHON'
module neg_varref
#name    = "neg_varref"
#version = (1, 0, 0)
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
cat > neg_typemismatch/src/neg_typemismatch.orh <<'ORHON'
module neg_typemismatch
#name    = "neg_typemismatch"
#version = (1, 0, 0)
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
cat > neg_dupvar/src/neg_dupvar.orh <<'ORHON'
module neg_dupvar
#name    = "neg_dupvar"
#version = (1, 0, 0)
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
cat > neg_default_order/src/neg_default_order.orh <<'ORHON'
module neg_default_order
#name    = "neg_default_order"
#version = (1, 0, 0)
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

# []u8 → str coercion rejected
cd "$TESTDIR"
mkdir -p neg_u8str/src
cat > neg_u8str/src/neg_u8str.orh <<'ORHON'
module neg_u8str
#name    = "neg_u8str"
#version = (1, 0, 0)
#build   = exe
func greet(s: str) void { }
func main() void {
    var buf: [5]u8 = [104, 101, 108, 108, 111]
    const slice: []u8 = buf[0..5]
    greet(slice)
}
ORHON
cd neg_u8str
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "cannot pass.*u8.*str\|fromBytes\|string\.fromBytes"; then pass "rejects []u8 as str"
else fail "rejects []u8 as str" "$NEG_OUT"; fi

# str == error (no magic equality)
cd "$TESTDIR"
mkdir -p neg_str_eq/src
cat > neg_str_eq/src/neg_str_eq.orh <<'ORHON'
module neg_str_eq
#name    = "neg_str_eq"
#version = (1, 0, 0)
#build   = exe
func main() void {
    const a: str = "hello"
    if(a == "hello") { }
}
ORHON
cd neg_str_eq
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "cannot use.*==.*str\|str.*=="; then pass "rejects == on str"
else fail "rejects == on str" "$NEG_OUT"; fi

# duplicate anchor file
cd "$TESTDIR"
mkdir -p neg_dup_anchor/src/sub
cat > neg_dup_anchor/src/neg_dup_anchor.orh <<'ORHON'
module neg_dup_anchor
#name    = "neg_dup"
#version = (1, 0, 0)
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

# ── Fixture-based category tests ─────────────────────────────
# Each fixture tests one compiler pass with multiple error cases.
# Helper: run a fixture as a project and check for expected error
run_fixture() {
    local name="$1" fixture="$2" pattern="$3" label="$4"
    cd "$TESTDIR"
    mkdir -p "$name/src"
    cp "$FIXTURES/$fixture" "$name/src/$name.orh"
    sed -i "1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module $name/" "$name/src/$name.orh"
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
run_fixture neg_types4 fail_types.orh "type mismatch.*condition" "fixture: catches non-bool condition"
run_fixture neg_types5 fail_types.orh "type mismatch" "fixture: catches type mismatch"
run_fixture neg_types6 fail_types.orh "break.*outside\|continue.*outside" "fixture: catches break/continue outside loop"

# ownership errors
run_fixture neg_own fail_ownership.orh "use of moved value\|moved" "fixture: catches use after move"

# borrow errors
run_fixture neg_borrow fail_borrow.orh "reference type not allowed in variable declaration" "fixture: catches borrow conflict"
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
run_fixture neg_enum_val fail_enum_value.orh "error" "fixture: rejects tagged union with explicit value"

# function errors (first error in file: default before required)
run_fixture neg_func fail_functions.orh "defaults.*must.*after\|required.*param" "fixture: catches default before required param"

# scope errors (module-level var fires first since it's a parser error)
run_fixture neg_scope fail_scope.orh "module-level.*var.*not allowed\|already declared" "fixture: catches scope errors"

# match errors
run_fixture neg_match fail_match.orh "not a member" "fixture: catches invalid match arm"
run_fixture neg_match_guard fail_match_guard.orh "match with guards requires" "fixture: catches guarded match without else"

# throw in void function
cd "$TESTDIR"
mkdir -p neg_throw/src
cp "$FIXTURES/fail_throw.orh" neg_throw/src/neg_throw.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_throw/' neg_throw/src/neg_throw.orh
cd neg_throw
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "throw\|error"; then
    pass "rejects throw in void function"
else
    fail "rejects throw in void function" "$NEG_OUT"
fi

# old C interop directives rejected (CIMP-04)
cd "$TESTDIR"
mkdir -p neg_linkc/src
cp "$FIXTURES/fail_old_linkc.orh" neg_linkc/src/neg_linkc.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_linkc/' neg_linkc/src/neg_linkc.orh
cd neg_linkc
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "error\|unexpected\|parse"; then
    pass "rejects old #linkC directive"
else
    fail "rejects old #linkC directive" "$NEG_OUT"
fi

# ── ERR quality tests ────────────────────────────────────────────

# did you mean suggestion (ERR-01)
cd "$TESTDIR"
mkdir -p neg_did_you_mean/src
cp "$FIXTURES/fail_did_you_mean.orh" neg_did_you_mean/src/neg_did_you_mean.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_did_you_mean/' neg_did_you_mean/src/neg_did_you_mean.orh
cd neg_did_you_mean
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -q "did you mean"; then
    pass "suggests 'did you mean' for typo identifier"
else
    fail "suggests 'did you mean' for typo identifier" "$NEG_OUT"
fi

# type mismatch display (ERR-02)
cd "$TESTDIR"
mkdir -p neg_type_display/src
cp "$FIXTURES/fail_type_mismatch_display.orh" neg_type_display/src/neg_type_display.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_type_display/' neg_type_display/src/neg_type_display.orh
cd neg_type_display
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -q "type mismatch.*expected bool"; then
    pass "type mismatch shows expected vs got format"
else
    fail "type mismatch shows expected vs got format" "$NEG_OUT"
fi

# ownership fix hint (ERR-03)
cd "$TESTDIR"
mkdir -p neg_ownership_hint/src
cp "$FIXTURES/fail_ownership.orh" neg_ownership_hint/src/neg_ownership_hint.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_ownership_hint/' neg_ownership_hint/src/neg_ownership_hint.orh
cd neg_ownership_hint
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -q "consider using @copy()"; then
    pass "move-after-use suggests copy()"
else
    fail "move-after-use suggests copy()" "$NEG_OUT"
fi

# borrow ref hint (ERR-03)
cd "$TESTDIR"
mkdir -p neg_borrow_hint/src
cp "$FIXTURES/fail_borrow.orh" neg_borrow_hint/src/neg_borrow_hint.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_borrow_hint/' neg_borrow_hint/src/neg_borrow_hint.orh
cd neg_borrow_hint
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -q "by value or as a function parameter"; then
    pass "borrow violation suggests function parameter"
else
    fail "borrow violation suggests function parameter" "$NEG_OUT"
fi

# introspection — wrong argument count / type
cd "$TESTDIR"
mkdir -p neg_introspect/src
cp "$FIXTURES/fail_introspection.orh" neg_introspect/src/neg_introspect.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_introspect/' neg_introspect/src/neg_introspect.orh
cd neg_introspect
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "@hasField\|error"; then
    pass "rejects bad introspection args"
else
    fail "rejects bad introspection args" "$NEG_OUT"
fi

# blueprint: missing method
cd "$TESTDIR"
mkdir -p neg_bp_missing/src
cp "$FIXTURES/fail_blueprint_missing_method.orh" neg_bp_missing/src/neg_bp_missing.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_bp_missing/' neg_bp_missing/src/neg_bp_missing.orh
cd neg_bp_missing
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "does not implement.*required by blueprint"; then
    pass "rejects missing blueprint method"
else
    fail "rejects missing blueprint method" "$NEG_OUT"
fi

# blueprint: wrong signature
cd "$TESTDIR"
mkdir -p neg_bp_sig/src
cp "$FIXTURES/fail_blueprint_wrong_sig.orh" neg_bp_sig/src/neg_bp_sig.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_bp_sig/' neg_bp_sig/src/neg_bp_sig.orh
cd neg_bp_sig
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "does not match blueprint\|parameter"; then
    pass "rejects wrong blueprint method signature"
else
    fail "rejects wrong blueprint method signature" "$NEG_OUT"
fi

# blueprint: unknown blueprint
cd "$TESTDIR"
mkdir -p neg_bp_unknown/src
cp "$FIXTURES/fail_blueprint_unknown.orh" neg_bp_unknown/src/neg_bp_unknown.orh
sed -i '1s/^module [a-zA-Z_][a-zA-Z0-9_]*/module neg_bp_unknown/' neg_bp_unknown/src/neg_bp_unknown.orh
cd neg_bp_unknown
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "unknown blueprint"; then
    pass "rejects unknown blueprint"
else
    fail "rejects unknown blueprint" "$NEG_OUT"
fi

# duplicate union member after flattening
run_fixture neg_union_dup fail_union_duplicate.orh "duplicate type.*union\|duplicate.*flattening\|DuplicateUnionMember" "fixture: rejects duplicate type in flattened union"


# ── module main rejection ────────────────────────────────────────
# module main is reserved — compiler must reject it
cd "$TESTDIR"
mkdir -p neg_modmain/src
cat > neg_modmain/src/neg_modmain.orh <<'ORHON'
module main
#name    = "neg_modmain"
#version = (1, 0, 0)
#build   = exe
func main() void { }
ORHON
cd neg_modmain
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "'main' is reserved"; then pass "rejects module main"
else fail "rejects module main" "$NEG_OUT"; fi

# func main() in library module rejected
cd "$TESTDIR"
mkdir -p neg_libmain/src
cat > neg_libmain/src/neg_libmain.orh <<'ORHON'
module neg_libmain
#name    = "neg_libmain"
#version = (1, 0, 0)
#build   = static
func main() void { }
ORHON
cd neg_libmain
NEG_OUT=$("$ORHON" build 2>&1 || true)
if echo "$NEG_OUT" | grep -qi "func main.*only allowed in executable"; then pass "rejects func main() in library"
else fail "rejects func main() in library" "$NEG_OUT"; fi


report_results
