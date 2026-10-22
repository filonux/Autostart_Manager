#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$ROOT_DIR/tests"
TIMEOUT_SECONDS="${AUTOSTART_MANAGER_TEST_TIMEOUT:-120}"

[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || TIMEOUT_SECONDS=120
command -v timeout >/dev/null 2>&1 || {
    printf 'ERROR: timeout is required to run the test suite.\n' >&2
    exit 1
}

mapfile -t ALL_SUITES < <(cd "$TEST_DIR" && printf '%s\n' test_*.sh | sort)

normalize_suite() {
    local name="$1"
    name="${name#tests/}"
    name="${name%.sh}.sh"
    printf '%s\n' "$name"
}

if (( $# == 1 )) && [[ "$1" == --list ]]; then
    printf '%s\n' "${ALL_SUITES[@]}"
    exit 0
fi

RUN_SUITES=()
if (( $# == 0 )); then
    RUN_SUITES=("${ALL_SUITES[@]}")
else
    for requested in "$@"; do
        suite=$(normalize_suite "$requested")
        found=0
        for available in "${ALL_SUITES[@]}"; do
            if [[ "$available" == "$suite" ]]; then
                RUN_SUITES+=("$available")
                found=1
                break
            fi
        done
        if (( ! found )); then
            printf 'ERROR: unknown test suite: %s\n' "$requested" >&2
            printf 'Use --list to show available suites.\n' >&2
            exit 2
        fi
    done
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CONFIG_DIRS="$tmp_dir/etc/xdg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CONFIG_DIRS"

passed=0
failed=0
assertions=0
printf 'Running %d test suite(s)...\n' "${#RUN_SUITES[@]}"

for suite in "${RUN_SUITES[@]}"; do
    log="$tmp_dir/$suite.log"
    printf '\n=== %s ===\n' "$suite"
    suite_env=()
    [[ "$suite" == test_suite_quality.sh ]] && suite_env=(TEST_SUITE_QUALITY_SKIP_NESTED=1)
    if timeout --signal=TERM --kill-after=5s "${TIMEOUT_SECONDS}s" env "${suite_env[@]}" bash "$TEST_DIR/$suite" >"$log" 2>&1; then
        passed=$((passed + 1))
        result='PASS'
    else
        rc=$?
        failed=$((failed + 1))
        result="FAIL (rc=$rc)"
    fi
    printf '%s\n' "$(cat "$log")"
    stat_line=$(grep -E '^[0-9]+ tests: [0-9]+ passed, [0-9]+ failed$' "$log" | tail -n 1 || true)
    if [[ -n "$stat_line" ]]; then
        suite_assertions=${stat_line%% tests:*}
        assertions=$((assertions + suite_assertions))
    fi
    printf '%s: %s\n' "$result" "$suite"
done

printf '\nSummary: %d/%d suites passed; %d failed; %d reported assertions.\n' \
    "$passed" "${#RUN_SUITES[@]}" "$failed" "$assertions"
(( failed == 0 ))
