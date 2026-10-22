#!/bin/bash
# Repository hygiene: text files must be clean for diffs, editors and CI.
# LICENSE.txt is kept byte-for-byte as supplied (its hash is pinned elsewhere).
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

files=()
while IFS= read -r -d '' file; do
    files+=("$file")
done < <(cd "$ROOT_DIR" && find . -path ./.git -prune -o -type f \
    \( -name '*.sh' -o -name '*.md' -o -name '*.yml' -o -name '*.yaml' -o -name '*.txt' \
       -o -name '*.desktop' \) ! -name LICENSE.txt -printf '%P\0' | sort -z)

offenders() {   # offenders <predicate>: print the files for which the predicate succeeds
    local file
    for file in "${files[@]}"; do
        if (cd "$ROOT_DIR" && "$@" "$file") >/dev/null 2>&1; then printf '%s ' "$file"; fi
    done
}
has_trailing_blank() { grep -Eq '[[:blank:]]$' "$1"; }
has_cr()             { grep -q $'\r' "$1"; }
has_bom()            { [[ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]; }
lacks_final_newline() { [[ -s "$1" && -n "$(tail -c 1 "$1")" ]]; }
ends_with_blank_line() { [[ "$(tail -c 2 "$1" | od -An -c | tr -s ' ')" == ' \n \n' ]]; }
not_utf8()           { ! iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; }

check 'hygiene scan covers the project text files' "$(( ${#files[@]} >= 25 ))" 1
check 'no trailing spaces or tabs at end of line' "$(offenders has_trailing_blank)" ''
check 'no carriage returns (LF line endings only)' "$(offenders has_cr)" ''
check 'no UTF-8 byte order mark' "$(offenders has_bom)" ''
check 'every text file ends with a newline' "$(offenders lacks_final_newline)" ''
check 'no blank line at the end of a file' "$(offenders ends_with_blank_line)" ''
check 'every text file is valid UTF-8' "$(offenders not_utf8)" ''

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
