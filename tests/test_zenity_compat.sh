#!/bin/bash
# Zenity option compatibility. Linux Mint 22 ships Zenity 3.44.2 (GTK 3) while most
# other distributions ship 4.x (GTK 4). An option missing from either makes Zenity
# exit with 255, so the user sees a bare fallback dialog (or nothing for lists).
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
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

# Options present in BOTH `zenity --help-all` tables: Zenity 3.44.2 (Linux Mint 22
# upstream repository) and Zenity 4.0.1 (Ubuntu 24.04), without the --help-*
# options and without --window-icon and --icon-name, which 4.x deprecated or renamed.
COMMON_OPTIONS='--about --add-calendar --add-combo --add-entry --add-list --add-password --attach
--auto-close --auto-kill --auto-scroll --calendar --cancel-label --checkbox --checklist --color
--color-selection --column --column-values --combo-values --confirm-overwrite --date-format --day
--default-cancel --directory --editable --ellipsize --entry --entry-text --error --extra-button
--file-filter --file-selection --filename --font --forms --forms-date-format --height --hide-column
--hide-header --hide-text --hide-value --imagelist --info --list --list-values --max-value
--mid-search --min-value --modal --month --multiple --no-cancel --no-markup --no-wrap --ok-label
--password --percentage --print-column --print-partial --progress --pulsate --question --radiolist
--save --scale --separator --show-header --show-palette --step --switch --text --text-info
--time-remaining --timeout --title --username --value --warning --width --year'

# Reads the `zen --...` calls of a script (continuation lines joined, quoted text ignored).
# MODE options: the options used by any call. MODE extra: the --extra-button arguments of the checklist call.
zen_calls() {
    python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding='utf-8').read().split('\n')
used, extra, i = set(), 0, 0
while i < len(lines):
    line = lines[i]
    if re.search(r'\bzen --', line) and not line.lstrip().startswith('#'):
        stmt = line
        while stmt.rstrip().endswith('\\') and i + 1 < len(lines):
            i += 1
            stmt = stmt.rstrip()[:-1] + ' ' + lines[i].strip()
        bare = re.sub(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'', '""', stmt)
        used |= set(re.findall(r'(?<![\w-])(--[a-z][a-z-]*)', bare))
        if '--checklist' in bare:
            extra += len(re.findall(r'(?<![\w-])--extra-button\b', bare))
    i += 1
print(' '.join(sorted(used)) if sys.argv[2] == 'options' else extra)
PY
}
used_options() { zen_calls "$1" options; }
unknown_options() {   # unknown_options <script>: used options missing from the common set
    local opt
    for opt in $(used_options "$1"); do
        grep -qxF -- "$opt" <<< "$(tr -s ' \n' '\n' <<< "$COMMON_OPTIONS")" || printf '%s ' "$opt"
    done
}

used=$(used_options "$SCRIPT")
check 'the dialog calls of the script are found' "$(( $(wc -w <<< "$used") >= 15 ))" 1
check 'every Zenity option used exists in Zenity 3.44 and 4.x' "$(unknown_options "$SCRIPT")" ''
check 'no dialog uses --icon (missing in Zenity 3.44, the version of Linux Mint 22)' "$(grep -c -- '--icon=' "$SCRIPT" || true)" 0
check 'no dialog uses the deprecated --window-icon or the renamed --icon-name' "$(grep -cE -- '--(window-icon|icon-name)' "$SCRIPT" || true)" 0
# The checklist learns which action was pressed from the label Zenity prints for an extra button.
check 'the checklist offers Search and Open as --extra-button, which both Zenity versions have' "$(zen_calls "$SCRIPT" extra)" 2

# The check must actually catch an unsupported option.
mutated="$TMP/mutated.sh"
sed '0,/zen --info /s//zen --info --icon="dialog-information" /' "$SCRIPT" > "$mutated"
check 'the compatibility check mutates the script' "$(cmp -s "$SCRIPT" "$mutated" && echo same || echo changed)" changed
check 'the compatibility check rejects --icon' "$(unknown_options "$mutated")" '--icon '

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
