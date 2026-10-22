#!/bin/bash
# Static analysis gate shared by local runs and CI:  bash tests/lint.sh
# SHELLCHECK_BIN selects the binary, SHELLCHECK_VERSION the required version.
# Exit codes: 0 clean, 1 findings, 2 ShellCheck missing or wrong version.
set -euo pipefail

ROOT_DIR="${LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
EXPECTED_VERSION="${SHELLCHECK_VERSION:-0.11.0}"
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"

if ! command -v "$SHELLCHECK_BIN" >/dev/null 2>&1; then
    printf 'ERROR: ShellCheck %s is required but "%s" was not found.\n' "$EXPECTED_VERSION" "$SHELLCHECK_BIN" >&2
    exit 2
fi
actual_version=$("$SHELLCHECK_BIN" --version | sed -n 's/^version: //p')
if [[ "$actual_version" != "$EXPECTED_VERSION" ]]; then
    printf 'ERROR: ShellCheck %s is required; found %s.\n' "$EXPECTED_VERSION" "$actual_version" >&2
    exit 2
fi

cd "$ROOT_DIR"
shopt -s nullglob
program=(script/*.sh)
suites=(tests/*.sh)
if (( ${#program[@]} + ${#suites[@]} == 0 )); then
    printf 'ERROR: no shell files found under %s.\n' "$ROOT_DIR" >&2
    exit 2
fi

# The repository ships no .shellcheckrc, so every option lives here. --norc makes a local or user-level
# configuration unable to change the result between machines and CI.
# The program is checked with no exclusions. The suites source it through a variable path and assign the
# variables it reads, which ShellCheck cannot follow, so only those structural findings are excluded there:
#   SC1091 not following a sourced file    SC2034 variable appears unused (it is read by the sourced program)
#   SC2154 variable referenced but not assigned (assigned by the sourced program)
#   SC2329 function never invoked (called through traps, overrides and test doubles)
status=0
if (( ${#program[@]} )); then
    "$SHELLCHECK_BIN" --norc --shell=bash "${program[@]}" || status=1
fi
if (( ${#suites[@]} )); then
    "$SHELLCHECK_BIN" --norc --shell=bash --exclude=SC1091,SC2034,SC2154,SC2329 "${suites[@]}" || status=1
fi
if (( status != 0 )); then
    exit 1
fi
printf 'ShellCheck %s: %d files clean.\n' "$actual_version" "$(( ${#program[@]} + ${#suites[@]} ))"
