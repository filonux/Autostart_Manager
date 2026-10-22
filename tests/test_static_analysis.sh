#!/bin/bash
# Static analysis: syntax of every shell file and the pinned ShellCheck gate.
# REQUIRE_SHELLCHECK=1 (CI) turns a missing or mismatched ShellCheck into a failure.
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LINT="$ROOT_DIR/tests/lint.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

shopt -s nullglob
shell_files=("$ROOT_DIR"/script/*.sh "$ROOT_DIR"/tests/*.sh)
syntax_errors=0
for file in "${shell_files[@]}"; do
    bash -n "$file" 2>/dev/null || { printf 'syntax error: %s\n' "$file"; ((syntax_errors++)); }
done
check 'shell file discovery covers the script, the suites and the lint gate' "$(( ${#shell_files[@]} >= 18 ))" 1
check 'every shell file passes bash -n' "$syntax_errors" 0

printf 'if then fi (\n' > "$TMP/broken.sh"
loop_status=0
for file in "$ROOT_DIR/script/Autostart_Manager.sh" "$TMP/broken.sh"; do
    bash -n "$file" 2>/dev/null || loop_status=1
done
check 'per-file bash -n loop catches a syntax error in a later file' "$loop_status" 1

lint_status=0
bash "$LINT" >"$TMP/lint.out" 2>&1 || lint_status=$?
case "$lint_status" in
    0) check 'ShellCheck is clean on the production script and every suite' "$lint_status" 0 ;;
    2) if [[ "${REQUIRE_SHELLCHECK:-0}" == 1 ]]; then
           check 'pinned ShellCheck is available' unavailable available
           cat "$TMP/lint.out"
       else
           printf 'SKIP: pinned ShellCheck is not available (%s)\n' "$(head -n 1 "$TMP/lint.out")"
       fi ;;
    *) check 'ShellCheck reports no findings on the production script and every suite' "$lint_status" 0
       cat "$TMP/lint.out" ;;
esac

if (( lint_status != 2 )); then
    mkdir -p "$TMP/root/script"
    # shellcheck disable=SC2016  # the unquoted expansion is the intended finding
    printf '#!/bin/bash\necho $unquoted\n' > "$TMP/root/script/bad.sh"
    negative_status=0
    LINT_ROOT="$TMP/root" bash "$LINT" >/dev/null 2>&1 || negative_status=$?
    check 'lint gate fails when ShellCheck reports a finding' "$negative_status" 1

    # The repository has no .shellcheckrc: the exclusions live in lint.sh and apply to the suites only.
    mkdir -p "$TMP/root_tests/tests"
    # shellcheck disable=SC2016  # the unquoted expansion is the intended finding
    printf '#!/bin/bash\necho $unquoted\n' > "$TMP/root_tests/tests/bad.sh"
    negative_status=0
    LINT_ROOT="$TMP/root_tests" bash "$LINT" >/dev/null 2>&1 || negative_status=$?
    check 'lint gate still fails on a real finding inside a suite' "$negative_status" 1

    mkdir -p "$TMP/root_strict/script"
    printf '#!/bin/bash\nunused=1\n' > "$TMP/root_strict/script/unused.sh"
    negative_status=0
    LINT_ROOT="$TMP/root_strict" bash "$LINT" >/dev/null 2>&1 || negative_status=$?
    check 'lint gate applies no exclusions to the production script' "$negative_status" 1

    mkdir -p "$TMP/root_rc/script"
    printf 'disable=SC2086\n' > "$TMP/root_rc/.shellcheckrc"
    # shellcheck disable=SC2016  # the unquoted expansion is the intended finding
    printf '#!/bin/bash\necho $unquoted\n' > "$TMP/root_rc/script/bad.sh"
    negative_status=0
    LINT_ROOT="$TMP/root_rc" bash "$LINT" >/dev/null 2>&1 || negative_status=$?
    check 'lint gate ignores a .shellcheckrc that would hide findings' "$negative_status" 1
fi

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
