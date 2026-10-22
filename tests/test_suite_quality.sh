#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
command -v timeout >/dev/null 2>&1 || { echo 'FAIL: timeout is required by the quality runner.' >&2; exit 1; }

check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

cd /tmp || exit 1
# Focused suites must not duplicate test case names; duplicate names are a maintenance smell
# because they make reports ambiguous even when the underlying assertions differ.
dup_names=$(python3 - "$ROOT_DIR/tests" <<'PY'
from pathlib import Path
import re, sys, collections
root=Path(sys.argv[1])
seen=collections.defaultdict(list)
for p in sorted(root.glob('test_*.sh')):
    for name in re.findall(r"check\s+'([^']+)'", p.read_text(encoding='utf-8') or ''):
        seen[name].append(p.name)
print('\n'.join(f"{name}|{','.join(files)}" for name,files in seen.items() if len(files)>1))
PY
)
check 'test case names are unique across suites' "$(printf '%s' "$dup_names" | grep -c . || true)" 0

SUITES=(
    test_translation_quality.sh
    test_quality_regression.sh
    test_hardening.sh
    test_function_contracts.sh
    test_icon.sh
    test_language_invariance.sh
    test_ui_aesthetic.sh
    test_user_simulation.sh
    test_language_switch.sh
    test_navigation_language.sh
    test_ui_smoke.sh
    test_package_integrity.sh
    test_readme_links.sh
    test_documents.sh
    test_static_analysis.sh
    test_ci_workflow.sh
    test_hygiene.sh
    test_compat.sh
    test_zenity_compat.sh
    test_install.sh
    test_uninstall.sh
)
if (( $(printf '%s\n' "${SUITES[@]}" | sort | uniq -d | wc -l) != 0 )); then
    echo 'FAIL: quality suite manifest contains duplicate files.' >&2
    exit 1
fi
(cd "$ROOT_DIR" && printf '%s\n' tests/test_*.sh | sed 's#^tests/##' | grep -Fxv "$(basename "$0")" | sort) > "$TMP/discovered.txt"
printf '%s\n' "${SUITES[@]}" | sort > "$TMP/declared.txt"
mapfile -t DISCOVERED < "$TMP/discovered.txt"
mapfile -t DECLARED < "$TMP/declared.txt"
if [[ "${DISCOVERED[*]}" != "${DECLARED[*]}" ]]; then
    printf 'FAIL: quality suite manifest does not match discovered test suites.\n' >&2
    exit 1
fi
check 'quality suite manifest exactly covers all focused suites' 0 0

for target in "$ROOT_DIR/script/Autostart_Manager.sh" "$ROOT_DIR/tests/run_all.sh" "$ROOT_DIR"/tests/test_*.sh; do
    bash -n "$target" >/dev/null || { echo "FAIL: syntax error in $target" >&2; exit 1; }
done
check 'all production and test scripts pass bash -n' 0 0
check 'run_all lists every focused suite' "$(cd "$ROOT_DIR" && tests/run_all.sh --list | grep -c '^test_.*\.sh$')" 22
check 'run_all accepts a filtered suite' "$(cd "$ROOT_DIR" && tests/run_all.sh test_icon.sh >/dev/null; echo $?)" 0
check 'run_all rejects an unknown suite' "$(cd "$ROOT_DIR" && tests/run_all.sh does_not_exist.sh >/dev/null 2>&1; echo $?)" 2

REQUESTED_SUITES=()
RUN_MUTATIONS=1
[[ "${TEST_SUITE_QUALITY_SKIP_MUTATIONS:-0}" == 1 ]] && RUN_MUTATIONS=0
if (( $# )); then
    RUN_MUTATIONS=0
    if [[ "$1" == --list ]]; then
        printf '%s\n' "${SUITES[@]}"
        exit 0
    fi
    for requested in "$@"; do
        requested="${requested#tests/}"
        requested="${requested%.sh}.sh"
        found=0
        for suite in "${SUITES[@]}"; do
            if [[ "$suite" == "$requested" ]]; then
                REQUESTED_SUITES+=("$suite")
                found=1
                break
            fi
        done
        if (( ! found )); then
            printf 'FAIL: unknown test suite: %s\n' "$requested" >&2
            printf 'Use --list to show available suites.\n' >&2
            exit 2
        fi
    done
else
    REQUESTED_SUITES=("${SUITES[@]}")
fi

suite_fail=0
BASE_PATH="$PATH"
BASE_HOME="${HOME:-/tmp}"
export ROOT_DIR BASE_PATH BASE_HOME TMP
if [[ "${TEST_SUITE_QUALITY_SKIP_NESTED:-0}" != 1 ]]; then
python3 - "${REQUESTED_SUITES[@]}" <<'PY'
import os
import signal
import subprocess
import sys
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
base_env = {
    "PATH": os.environ["BASE_PATH"],
    "HOME": os.environ["BASE_HOME"],
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "PYTHONUNBUFFERED": "1",
}
try:
    limit = int(os.environ.get("AUTOSTART_MANAGER_TEST_TIMEOUT", ""))
except ValueError:
    limit = 0
if limit < 1:
    limit = 60
for suite in sys.argv[1:]:
    print(f"\n=== {suite} ===", flush=True)
    log = Path(os.environ["TMP"]) / f"quality-{suite}.log"
    with log.open("w", encoding="utf-8") as stream:
        proc = subprocess.Popen(
            ["bash", str(root / "tests" / suite)],
            cwd="/tmp",
            env=base_env,
            stdin=subprocess.DEVNULL,
            stdout=stream,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            rc = proc.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            rc = 124
            print(f"FAIL: {suite} timed out after {limit} seconds.", flush=True)
        stream.flush()
    if log.exists():
        print(log.read_text(encoding="utf-8"), end="")
    log.unlink(missing_ok=True)
    if rc != 0:
        suite_fail = 1
PY
else
    check 'focused test execution delegated to run_all' 0 0
fi
if (( RUN_MUTATIONS )); then
    check 'all focused test suites pass' "$suite_fail" 0
else
    check 'all selected test suites pass' "$suite_fail" 0
fi

# Replace NEEDLE (which must occur exactly once; \n means a newline) with REPLACEMENT in FILE.
apply_mutation() {
    python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle,replacement=sys.argv[2:]; needle=needle.replace(r"\n", "\n"); replacement=replacement.replace(r"\n", "\n")
if s.count(needle) != 1: raise SystemExit(2)
p.write_text(s.replace(needle,replacement,1))
PY
}

# A mutant runs on a copy of the project with everything a suite may read (program, documents, .github,
# assets, the lint gate) and only the suite under test. A mutation counts when the suite passes on the
# unmodified copy, the pattern occurs exactly once and the suite fails on the mutant (a time-out is reported,
# not hidden).
MUTANT_LIMIT="${AUTOSTART_MANAGER_TEST_TIMEOUT:-120}"
[[ "$MUTANT_LIMIT" =~ ^[1-9][0-9]*$ ]] || MUTANT_LIMIT=120
declare -A SUITE_CLEAN=()

mutant_project() {   # mutant_project SUITE: fresh copy in $TMP/project
    local mroot="$TMP/project"
    rm -rf "$mroot"; mkdir -p "$mroot/tests"
    cp -r "$ROOT_DIR/script" "$ROOT_DIR/.github" "$ROOT_DIR/assets" "$mroot/"
    cp "$ROOT_DIR/README.md" "$ROOT_DIR/README.es.md" "$ROOT_DIR/LICENSE.txt" "$mroot/"
    cp "$ROOT_DIR/tests/lint.sh" "$ROOT_DIR/tests/$1" "$mroot/tests/"
    return 0
}

run_in_mutant() {   # run_in_mutant SUITE: exit status of the suite on $TMP/project (124: time limit)
    (cd "$TMP/project" && timeout -k 2 "$MUTANT_LIMIT" bash "tests/$1" >/dev/null 2>&1)
}

suite_is_clean() {   # suite_is_clean SUITE: the unmodified copy must pass; checked once per suite
    local test="$1" rc
    if [[ -z "${SUITE_CLEAN[$test]:-}" ]]; then
        mutant_project "$test"; run_in_mutant "$test"; rc=$?
        SUITE_CLEAN[$test]=$(( rc == 0 ))
        check "$test passes on the unmodified project copy" "$rc" 0
    fi
    (( SUITE_CLEAN[$test] ))
}

mutate_file_and_expect_fail() {   # LABEL SUITE FILE NEEDLE REPLACEMENT
    local label="$1" test="$2" file="$3" rc
    if ! suite_is_clean "$test"; then
        check "mutation detected: $label" "unverified: $test fails without it" caught
        return
    fi
    mutant_project "$test"
    if ! apply_mutation "$TMP/project/$file" "$4" "$5"; then
        check "mutation pattern occurs once: $label" missing once
        return
    fi
    run_in_mutant "$test"; rc=$?
    (( rc == 124 )) && printf 'NOTE: "%s" was caught only by the %s s time limit\n' "$label" "$MUTANT_LIMIT"
    check "mutation detected: $label" "$([[ $rc -ne 0 ]] && echo caught || echo missed)" caught
}
mutate_and_expect_fail() { mutate_file_and_expect_fail "$1" "$2" script/Autostart_Manager.sh "$3" "$4"; }
mutate_doc_and_expect_fail() { mutate_file_and_expect_fail "$@"; }

# shellcheck disable=SC2016  # mutation patterns are literal source text, not expansions
if (( RUN_MUTATIONS )); then
mutate_and_expect_fail 'English title leaks Spanish' test_translation_quality.sh "MSG_EN[main_title]='⚙ Autostart Manager'" "MSG_EN[main_title]='⚙ Gestor de arranque automático'"
mutate_and_expect_fail 'interface names a distribution' test_translation_quality.sh "[5]='System Services')" "[5]='Linux Mint Services')"
mutate_and_expect_fail 'Scriptya ICON metadata points nowhere' test_icon.sh '# ICON: ../assets/autostart-manager.png' '# ICON: ../assets/missing.png'
mutate_and_expect_fail 'Scriptya metadata loses its place after the shebang' test_icon.sh '#!/bin/bash\n# MENU: Autostart Manager' '#!/bin/bash\n#\n# MENU: Autostart Manager'
mutate_and_expect_fail 'result dialog text repeats its title' test_translation_quality.sh "MSG_EN[all_ok_text]='The changes were applied" "MSG_EN[all_ok_text]='All good. The changes were applied"
mutate_and_expect_fail 'list dialog loses its own text' test_translation_quality.sh ' --text="$browse_text"' ''
mutate_and_expect_fail 'atomic commit loses directory-target protection' test_quality_regression.sh 'mv -fT -- "$tmp" "$target"' 'mv -f -- "$tmp" "$target"'
mutate_and_expect_fail 'desktop mutation loses stale-file comparison' test_hardening.sh 'if [[ "$actual_hash" != "$expected_hash" ]]; then' 'if false; then'
mutate_and_expect_fail 'desktop validator loses Application Type restriction' test_quality_regression.sh 'type_value == "" || type_value != "Application"' 'false'
mutate_and_expect_fail 'Zenity option sanitization crosses the data sentinel' test_quality_regression.sh 'if (( ! after_options )); then' 'if true; then'
mutate_and_expect_fail 'privileged editor trusts user PATH' test_quality_regression.sh 'path="$dir/$e"' 'path="$(command -v -- "$e")"'
mutate_and_expect_fail 'install up-to-date check ignores file content' test_install.sh '! -L "$f" && "$(file_sha256 "$f")" == "${INST_HASH[$f]}"' '! -L "$f"'
mutate_and_expect_fail 'uninstall removes files modified since installation' test_uninstall.sh '[[ "$UNINSTALL_STATE" != purge && "$(file_sha256 "$f")" != "${INST_OLD_HASH[$f]}" ]]' 'false'
mutate_and_expect_fail 'uninstall deletes the crontab backup without asking' test_uninstall.sh 'purge) answer=y ;;' 'purge|keep) answer=y ;;'
mutate_and_expect_fail 'content hash keeps the backslash mark of sha256sum' test_hardening.sh '"${out#\\}"' '"$out"'
mutate_and_expect_fail 'list height loses its 340 px floor' test_function_contracts.sh '(( h < 340 )) && h=340' '(( h < 0 )) && h=0'
mutate_and_expect_fail 'list height loses its 600 px ceiling' test_function_contracts.sh '(( h > 600 )) && h=600' '(( h > 60000 )) && h=60000'
mutate_and_expect_fail 'list height ignores the lines of dialog text' test_function_contracts.sh 'm[1] * (${#nl} + 1)' 'm[1]'
mutate_and_expect_fail 'list height ignores the Zenity version' test_function_contracts.sh '(( ZEN_MAJOR >= 4 )) && m=("${FIT_GTK4[@]}")' '(( ZEN_MAJOR >= 400 )) && m=("${FIT_GTK4[@]}")'
mutate_and_expect_fail 'checklist height uses the menu row height' test_function_contracts.sh '[[ "${3:-}" == check ]] && row="${m[3]}"' '[[ "${3:-}" == chec ]] && row="${m[3]}"'
mutate_and_expect_fail 'Zenity version detection discards the answer' test_function_contracts.sh 'ZEN_MAJOR="${BASH_REMATCH[1]}"' 'ZEN_MAJOR=3'
mutate_and_expect_fail 'main menu skips the Zenity version detection' test_language_switch.sh 'main_loop() {\n    detect_zenity_major\n' 'main_loop() {\n'
mutate_and_expect_fail 'main menu goes back to a fixed height' test_language_switch.sh '--height="$(fit_height "$menu_text" $(( ${#rows[@]} / 3 )))"' '--height=360'
# Constants below a measured minimum (PLAN.txt 14.16): each shrink exceeds the smallest measured slack of its constant.
mutate_and_expect_fail 'Zenity 3.x list base is 12 px below the measured minimum' test_function_contracts.sh 'ZEN_MAJOR=3\n\n# Zenity 3.x needs a display' 'FIT_GTK3[0]=$(( FIT_GTK3[0] - 12 ))\nZEN_MAJOR=3\n\n# Zenity 3.x needs a display'
mutate_and_expect_fail 'Zenity 3.x menu row is 3 px below the measured minimum' test_function_contracts.sh 'ZEN_MAJOR=3\n\n# Zenity 3.x needs a display' 'FIT_GTK3[2]=$(( FIT_GTK3[2] - 3 ))\nZEN_MAJOR=3\n\n# Zenity 3.x needs a display'
mutate_and_expect_fail 'Zenity 4.x checklist row is 2 px below the measured minimum' test_function_contracts.sh 'ZEN_MAJOR=3\n\n# Zenity 3.x needs a display' 'FIT_GTK4[3]=$(( FIT_GTK4[3] - 2 ))\nZEN_MAJOR=3\n\n# Zenity 3.x needs a display'
mutate_and_expect_fail 'Zenity 4.x text line is 3 px below the measured minimum' test_function_contracts.sh 'ZEN_MAJOR=3\n\n# Zenity 3.x needs a display' 'FIT_GTK4[1]=$(( FIT_GTK4[1] - 3 ))\nZEN_MAJOR=3\n\n# Zenity 3.x needs a display'

# README contract (tests/test_readme_links.sh).
R=test_readme_links.sh
mutate_doc_and_expect_fail 'README gains a tenth section' $R README.md '## License' '## Roadmap\n\nPlanned work does not belong in this README.\n\n## License'
mutate_doc_and_expect_fail 'README names a distribution' $R README.md 'Everything that starts with your Linux session' 'Everything that starts with your Linux Mint session'
mutate_doc_and_expect_fail 'README icon is not 140 px wide' $R README.md 'width="140"' 'width="128"'
mutate_doc_and_expect_fail 'README Bash minimum is below the script guard' $R README.md '| `bash` | 4.4 or newer' '| `bash` | 4.3 or newer'
mutate_doc_and_expect_fail 'README Zenity row loses 4.x' $R README.md '3.44 (GTK 3) or 4.x (GTK 4); tested' '3.44 (GTK 3); tested'
mutate_doc_and_expect_fail 'README drops the tested distribution release' $R README.md 'Ubuntu 24.04' 'Ubuntu'
mutate_doc_and_expect_fail 'script Bash guard drifts from the README' $R script/Autostart_Manager.sh 'BASH_VERSINFO[1] < 4) ))' 'BASH_VERSINFO[1] < 3) ))'
script_version=$(sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$ROOT_DIR/script/Autostart_Manager.sh")
mutate_doc_and_expect_fail 'README names another version than the script' $R README.md "**Autostart Manager $script_version**" '**Autostart Manager 0.0.1**'
mutate_doc_and_expect_fail 'README Scriptya section drops a header key' $R README.md '`MENU`, `DESCRIPTION` and `ICON`' '`DESCRIPTION` and `ICON`'
mutate_doc_and_expect_fail 'README languages lose structural parity' $R README.es.md '- **Se adapta sin quejarse**: sin `systemd` o sin `crontab`, esas secciones simplemente salen vacías.\n' ''
mutate_doc_and_expect_fail 'README carries a provisional marker' $R README.md 'Made by **[Filonux]' 'TODO Made by **[Filonux]'
mutate_doc_and_expect_fail 'README claims the language choice is saved' $R README.md 'The choice is not saved' 'The choice is saved'
mutate_doc_and_expect_fail 'README names the open button by the title of its list' $R README.md '**Open / view source**' '**Open / view item**'
mutate_doc_and_expect_fail 'README Language section loses its cross-link' $R README.es.md 'El README en inglés es [README.md](README.md).' 'El README en inglés es README.md.'
mutate_doc_and_expect_fail 'README documents a command with a typo' $R README.md './script/Autostart_Manager.sh --uninstall --purge' './script/Autostart_Manager.sh --uninstal --purge'
mutate_doc_and_expect_fail 'README links a missing license file' $R README.md '(LICENSE.txt)' '(LICENSE.md)'
mutate_doc_and_expect_fail 'README clone instructions enter the wrong directory' $R README.md 'cd Autostart_Manager\nchmod' 'cd autostart_manager\nchmod'
mutate_doc_and_expect_fail 'README shows a screenshot of the other language' $R README.md 'assets/screenshots/EN/2-AutostartManager-startupapps-en.png' 'assets/screenshots/ES/2-AutostartManager-programasinicio-es.png'
mutate_doc_and_expect_fail 'README links a screenshot that does not exist' $R README.md 'assets/screenshots/EN/3-AutostartManager-background-en.png' 'assets/screenshots/EN/3-AutostartManager-background-xx.png'
mutate_doc_and_expect_fail 'README declares the wrong screenshot size' $R README.md 'width="1173" height="626"' 'width="1173" height="630"'
mutate_doc_and_expect_fail 'README falls back to a GitHub attachment' $R README.es.md 'src="assets/screenshots/ES/6-AutostartManager-todascategorias-es.png"' 'src="https://github.com/user-attachments/assets/c3d9e6b2-befe-40a3-b8e9-9ead39667a8b"'
mutate_doc_and_expect_fail 'README opens with an icon from a folder that does not exist' $R README.md 'src="assets/autostart-manager.png"' 'src="icons/autostart-manager.png"'
mutate_doc_and_expect_fail 'README forgets the alternative icons' $R README.md ' `icon1.png` to `icon4.png` in `assets/` are alternatives: decline the header icon and browse to the one you prefer.' ''

# Documents audited by tests/test_documents.sh.
P=test_documents.sh
mutate_doc_and_expect_fail 'issue template names a desktop as the target' $P .github/ISSUE_TEMPLATE/custom.md '(for example, GNOME on Wayland)' 'Cinnamon / X11 / Wayland'
mutate_doc_and_expect_fail 'contributing guide names a distribution' $P .github/CONTRIBUTING.md 'On a local Debian or Ubuntu based system' 'On a local Debian/Ubuntu/Mint system'

# Workflow contract (tests/test_ci_workflow.sh): the pull request target is named in CONTRIBUTING.md and in the push filter.
W=test_ci_workflow.sh
Y=.github/workflows/quality.yml
mutate_doc_and_expect_fail 'workflow runs on every push, so a pull request is checked twice' $W $Y '  push:\n    branches: [Filonux-Box]\n' '  push:\n'
mutate_doc_and_expect_fail 'workflow push filter names a branch that pull requests do not target' $W $Y 'branches: [Filonux-Box]' 'branches: [main]'
mutate_doc_and_expect_fail 'contributing guide asks for pull requests against another branch' $W .github/CONTRIBUTING.md 'Target `Filonux-Box`, the default branch.' 'Target `main`, the default branch.'
mutate_doc_and_expect_fail 'contributing guide stops saying when the workflow runs' $W .github/CONTRIBUTING.md ', on every pull request and on every push to `Filonux-Box`. A branch without' '. A branch without'
mutate_doc_and_expect_fail 'workflow filters pull requests by branch' $W $Y '  pull_request:\n' '  pull_request:\n    branches: [main]\n'
mutate_doc_and_expect_fail 'checkout keeps the token in the cloned repository' $W $Y 'persist-credentials: false' 'persist-credentials: true'
fi

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
