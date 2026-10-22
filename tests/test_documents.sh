#!/bin/bash
set -uE -o pipefail
# Documentation audit: the README files and the .github documents describe a project for any Linux desktop.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
files = [root / 'README.md', root / 'README.es.md', *sorted((root / '.github').rglob('*.md'))]
for f in files:
    t = f.read_text(encoding='utf-8')
    m = re.search(r'(?i)\bmint\b|linux-?mint|cinnamon', t)
    assert not m, f'{f.relative_to(root)}: names a specific distribution or desktop: {m.group(0)!r}'
PY
check 'project documents name no distribution or desktop as the target' "$?" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
