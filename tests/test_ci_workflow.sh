#!/bin/bash
# Contract for .github/workflows/quality.yml: supply chain, triggers, scope and gates.
# shellcheck disable=SC2016  # patterns are literal workflow text, not expansions
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW="$ROOT_DIR/.github/workflows/quality.yml"
LINT="$ROOT_DIR/tests/lint.sh"
CONTRIBUTING="$ROOT_DIR/.github/CONTRIBUTING.md"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}
count() { grep -Ec -- "$1" "$WORKFLOW" || true; }
fixed() { grep -Fc -- "$1" "$WORKFLOW" || true; }

check 'workflow file exists' "$([[ -s "$WORKFLOW" ]] && echo yes || echo no)" yes
check 'workflow runs on push, pull requests and manual dispatch' \
    "$(count '^  (push|pull_request|workflow_dispatch):$')" 3

# Triggers. A pull request is checked by its own trigger, so push is limited to one branch (unfiltered, a pull
# request from this repository runs the same commits twice) and that branch must be the one CONTRIBUTING.md asks
# pull requests to target. The `on:` block is read as text, so the contract holds without PyYAML.
trigger_lines() {   # trigger_lines NAME: the lines nested under that trigger of `on:`, comments and blanks dropped
    awk -v trigger="  $1:" '
        /^on:[[:space:]]*$/ { in_on = 1; next }
        in_on && /^[^[:space:]#]/ { exit }
        in_on && /^[[:space:]]*(#|$)/ { next }
        in_on && $0 == trigger { found = 1; next }
        in_on && found && /^  [^[:space:]]/ { exit }
        in_on && found { print }
    ' "$WORKFLOW"
}
target_branch=$(sed -n 's/^Target `\([^`]*\)`.*/\1/p' "$CONTRIBUTING")
push_branches=$(trigger_lines push | sed -n 's/^    branches: \[\(.*\)\]$/\1/p')
check 'contributing guide names one branch for pull requests to target' \
    "$([[ -n "$target_branch" && "$target_branch" != *[[:space:]]* ]] && echo yes || echo no)" yes
check 'push runs only on the branch that pull requests target' \
    "$push_branches/$(trigger_lines push | grep -c . || true)" "$target_branch/1"
check 'pull requests are checked whatever branch they target' "$(trigger_lines pull_request | grep -c . || true)" 0
check 'contributing guide says when the workflow runs' \
    "$(grep -Fc "on every pull request and on every push to \`$target_branch\`" "$CONTRIBUTING" || true)" 1
checkout_step=$(awk '/^      - name: Checkout$/ { in_step = 1; print; next } in_step && /^      - / { exit } in_step { print }' "$WORKFLOW")
check 'checkout does not leave the token in the cloned repository' \
    "$(grep -Fxc '        with:' <<< "$checkout_step" || true)/$(grep -Fxc '          persist-credentials: false' <<< "$checkout_step" || true)" 1/1
check 'workflow token is read-only' "$(fixed '  contents: read')$(count ': write')" 10
check 'every action is pinned to a full commit SHA' \
    "$(count '^\s+uses: ' )/$(count '^\s+uses: [^@ ]+@[0-9a-f]{40}( |$)')" 1/1
check 'only first-party GitHub actions are used' "$(count '^\s+uses: ' )/$(count '^\s+uses: actions/')" 1/1
check 'runner image is pinned to ubuntu-24.04' "$(fixed 'runs-on: ubuntu-24.04')$(fixed 'ubuntu-latest')" 10
check 'job has a timeout' "$(count '^    timeout-minutes: [0-9]+$')" 1
check 'superseded runs are cancelled' "$(fixed 'cancel-in-progress: true')" 1
check 'workflow has no tab characters' "$(grep -c $'\t' "$WORKFLOW" || true)" 0

check 'ShellCheck comes from the official release' \
    "$(fixed 'https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/')" 1
check 'ShellCheck archive checksum is pinned and verified' \
    "$(fixed 'SHELLCHECK_SHA256: 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198')/$(fixed 'sha256sum --check --status')" 1/1
workflow_version=$(sed -n 's/^      SHELLCHECK_VERSION: //p' "$WORKFLOW")
lint_version=$(sed -n 's/^EXPECTED_VERSION="${SHELLCHECK_VERSION:-\(.*\)}"$/\1/p' "$LINT")
check 'workflow and lint gate require the same ShellCheck version' "$workflow_version" "$lint_version"
check 'workflow runs the lint gate' "$(fixed 'run: bash ./tests/lint.sh')" 1
check 'workflow checks syntax file by file' \
    "$(fixed 'for file in script/*.sh tests/*.sh; do')/$(fixed 'bash -n "$file"')" 1/1
check 'workflow never passes several files to a single bash -n' \
    "$(count 'bash -n ')/$(fixed 'bash -n "$file"')" 1/1
check 'workflow runs every suite through run_all' "$(fixed 'run: bash ./tests/run_all.sh')" 1
check 'workflow requires ShellCheck and the real UI smoke test' \
    "$(fixed 'REQUIRE_SHELLCHECK: "1"')$(fixed 'REQUIRE_UI_SMOKE: "1"')" 11
check 'workflow installs the UI test dependencies' "$(fixed 'zenity xvfb imagemagick')" 1
check 'workflow installs the Python modules used by the icon and workflow tests' "$(fixed 'python3-pil python3-yaml')" 1
check 'workflow installs the font used by the layout measurements' "$(fixed 'fonts-dejavu-core')" 1
check 'workflow installs the desktop entry validator used by the install test' "$(fixed 'desktop-file-utils')" 1
check 'workflow requires the desktop entry validator' "$(fixed 'REQUIRE_DESKTOP_VALIDATE: "1"')" 1
check 'workflow requires the icon tests' "$(fixed 'REQUIRE_PILLOW: "1"')" 1

if python3 -c 'import yaml' 2>/dev/null; then
    parsed=$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
jobs = doc.get('jobs', {})
job = jobs.get('tests-and-shellcheck', {})
print(len(jobs), len(job.get('steps', [])), doc.get(True, doc.get('on')) is not None)
PY
)
    check 'workflow YAML parses with one job and its steps' "$parsed" '1 6 True'
else
    printf 'SKIP: PyYAML is not available; structural checks above still apply.\n'
fi

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
