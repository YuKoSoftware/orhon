#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"
require_orhon
setup_tmpdir
trap cleanup_tmpdir EXIT
GOLDEN_ROOT="$(dirname "$0")/fixtures/golden"

section "Golden file fixtures"

run_golden() {
    local name=$1
    local project_dir="$GOLDEN_ROOT/$name"
    local ast_tmp="$TESTDIR/$name.ast"
    local mir_tmp="$TESTDIR/$name.mir"

    # AST golden — clear cache so semantic passes always run
    rm -rf "$project_dir/.orh-cache" 2>/dev/null || true
    (cd "$project_dir" && ORHON_DUMP_AST=1 "$ORHON" build 2>"$ast_tmp" || true)
    if git diff --no-index "$project_dir/$name.ast.golden" "$ast_tmp" >/dev/null 2>&1; then
        pass "golden $name.ast"
    else
        fail "golden $name.ast" "$(git diff --no-index "$project_dir/$name.ast.golden" "$ast_tmp" 2>&1 | head -15)"
    fi

    # MIR golden — clear cache so semantic passes always run
    rm -rf "$project_dir/.orh-cache" 2>/dev/null || true
    (cd "$project_dir" && ORHON_DUMP_MIR=1 "$ORHON" build 2>"$mir_tmp" || true)
    if git diff --no-index "$project_dir/$name.mir.golden" "$mir_tmp" >/dev/null 2>&1; then
        pass "golden $name.mir"
    else
        fail "golden $name.mir" "$(git diff --no-index "$project_dir/$name.mir.golden" "$mir_tmp" 2>&1 | head -15)"
    fi
}

run_golden basic
run_golden control
run_golden structs

report_results
