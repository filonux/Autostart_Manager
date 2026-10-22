#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
for tool in zenity systemctl crontab pgrep xdg-open pkexec; do
    cat > "$BIN/$tool" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$BIN/$tool"
done
cat > "$BIN/timeout" <<'SH'
#!/bin/bash
shift
"$@"
SH
chmod +x "$BIN/timeout"
export PATH="$BIN:$PATH" HOME="$TMP/home" AUTOSTART_MANAGER_TEST=1 LANG=C.UTF-8
export LC_ALL=C.UTF-8

pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"

# Every catalog key exists in both languages and is non-empty.
es_keys=$(printf '%s\n' "${!MSG_ES[@]}" | sort)
en_keys=$(printf '%s\n' "${!MSG_EN[@]}" | sort)
check 'Spanish/English key sets are identical' "$(comm -3 <(printf '%s\n' "$es_keys") <(printf '%s\n' "$en_keys") | wc -l)" 0
empty=0
for key in $es_keys; do
    [[ -n "${MSG_ES[$key]}" && -n "${MSG_EN[$key]}" ]] || empty=$((empty+1))
done
check 'No translation is empty' "$empty" 0

# A key used with `msg` but missing from the catalogs prints an empty message.
undefined_keys=$(python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
defined = set(re.findall(r'^MSG_ES\[([a-z0-9_]+)\]=', text, re.M))
used = set()
for line in text.splitlines():
    if not line.lstrip().startswith('#'):
        used.update(re.findall(r'\bmsg\s+([a-z][a-z0-9_]*)\b', line))
print(' '.join(sorted(used - defined)))
PY
)
check 'Every msg key referenced in the script is defined' "$undefined_keys" ''

# Placeholders and basic markup must remain structurally equivalent.
# Use shell parameter expansion instead of grep pipelines: it is deterministic,
# preserves literal '\\n' tokens, and cannot block on SIGPIPE/locale edge cases.
count_literal() {
    local text="$1" token="$2" count=0 rest="$1" next
    while :; do
        next="${rest#*"$token"}"
        [[ "$next" == "$rest" ]] && break
        rest="$next"
        count=$((count + 1))
    done
    printf '%s' "$count"
}
contract_fail=0
for key in $es_keys; do
    for token in '%s' '%d' '%q' '<b>' '</b>'; do
        a=$(count_literal "${MSG_ES[$key]}" "$token")
        b=$(count_literal "${MSG_EN[$key]}" "$token")
        [[ "$a" == "$b" ]] || contract_fail=$((contract_fail+1))
    done
    a=$(count_literal "${MSG_ES[$key]}" '\\n')
    b=$(count_literal "${MSG_EN[$key]}" '\\n')
    [[ "$a" == "$b" ]] || contract_fail=$((contract_fail+1))
done
check 'Translation structural contracts match' "$contract_fail" 0

# Exercise the real formatter for representative placeholder contracts. The
# exhaustive structural check above already covers every catalog entry; running
# every message through printf added substantial runtime without increasing
# failure detection.
format_fail=0
for key in help_usage invalid_lang pkexec_unexpected checklist_text; do
    es_n=$(count_literal "${MSG_ES[$key]}" '%s')
    en_n=$(count_literal "${MSG_EN[$key]}" '%s')
    args=()
    for ((i=0;i<es_n;i++)); do args+=("SENTINEL_$i"); done
    LANG_UI=es msg "$key" "${args[@]}" >/dev/null 2>&1 || format_fail=$((format_fail+1))
    LANG_UI=en msg "$key" "${args[@]}" >/dev/null 2>&1 || format_fail=$((format_fail+1))
    [[ "$es_n" == "$en_n" ]] || format_fail=$((format_fail+1))
done
check 'Representative translated printf formats are callable' "$format_fail" 0
hardcoded=$(grep -nE -- '--(title|text|ok-label|cancel-label|column)="[^$]' "$SCRIPT" | grep -vcE '^[^:]+:[[:space:]]*#' || true)
check 'Zenity user-facing strings are catalogued' "$hardcoded" 0
spanish_utf8=$(python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
print(1 if any(ch in s for ch in 'áéíóúñ¿¡') else 0)
PY
)
check 'Spanish catalog contains native UTF-8 orthography' "$spanish_utf8" 1

# The visible language must never alter control values embedded in messages.
check 'English mode is selected by explicit LANG_UI=en' "$(LANG_UI=en msg enabled)" '✅ Enabled'
check 'Spanish mode is selected by explicit LANG_UI=es' "$(LANG_UI=es msg enabled)" '✅ Activado'
check 'English uses correct application terminology' "$(LANG_UI=en msg main_title)" '⚙ Autostart Manager'
check 'Spanish uses correct application terminology' "$(LANG_UI=es msg main_title)" '⚙ Gestor de arranque automático'
check 'Spanish user-service terminology is technically accurate' "$(AUTOSTART_MANAGER_LANG=es bash -c 'source "$1"; msg session_service' _ "$SCRIPT")" 'Servicio de usuario'
check 'English checklist instruction names the actual OK button' "$(LANG_UI=en msg checklist_text F 1 1 | grep -o 'OK applies the changes; Cancel goes back to the categories.')" 'OK applies the changes; Cancel goes back to the categories.'
check 'Spanish checklist instruction names the actual Aceptar button' "$(LANG_UI=es msg checklist_text F 1 1 | grep -o 'Aceptar aplica los cambios; Cancelar vuelve a las categorías.')" 'Aceptar aplica los cambios; Cancelar vuelve a las categorías.'

# The pressed extra button is recognised by the label Zenity prints, so the four labels of a
# checklist must differ from each other, also after the ASCII folding used in non-UTF-8 locales.
label_clash=0
for lang in es en; do
    raw=() folded=()
    for key in find_filter open_btn btn_ok btn_cancel; do
        raw+=("$(LANG_UI=$lang msg "$key")")
        folded+=("$(ascii_safe "${raw[-1]}")")
    done
    label_clash=$(( label_clash + $(printf '%s\n' "${raw[@]}" | sort | uniq -d | wc -l) \
        + $(printf '%s\n' "${folded[@]}" | sort | uniq -d | wc -l) + $(printf '%s\n' "${folded[@]}" | grep -vc '[A-Za-z]' || true) ))
done
check 'Checklist button labels stay distinct and readable in both languages, also ASCII-folded' "$label_clash" 0

# Locale resolution: only locales whose language component is exactly es are Spanish.
locale_cases=(
  'es|es'
  'ES_es.UTF-8|es'
  'es_ES.UTF-8@traditional|es'
  'es.UTF-8|es'
  'es@euro|es'
  'en_US.UTF-8|en'
  'en_GB|en'
  'de_DE.UTF-8|en'
  'ca_ES.UTF-8|en'
  'POSIX|en'
  'C.UTF-8|en'
)
locale_fail=0
for pair in "${locale_cases[@]}"; do
    IFS='|' read -r loc expected <<< "$pair"
    [[ "$(detect_language "$loc")" == "$expected" ]] || { printf '  locale mismatch: %s\n' "$loc"; locale_fail=$((locale_fail+1)); }
done
check 'Locale detection is exact and case-insensitive' "$locale_fail" 0

# CLI language selection is a black-box contract.
help_en=$(LC_ALL=C.UTF-8 AUTOSTART_MANAGER_LANG=es bash "$SCRIPT" --lang en --help)
help_es=$(LC_ALL=C.UTF-8 AUTOSTART_MANAGER_LANG=en bash "$SCRIPT" --lang es --help)
check '--lang en overrides environment language' "$(head -n1 <<< "$help_en")" 'Graphical autostart manager for Linux desktops.'
check '--lang es overrides environment language' "$(head -n1 <<< "$help_es")" 'Gestor gráfico de arranque automático para escritorios Linux.'
check 'invalid --lang value exits 2' "$(LC_ALL=C.UTF-8 bash "$SCRIPT" --lang xx --help >/dev/null 2>&1; echo $?)" 2
check 'missing --lang argument exits 2' "$(LC_ALL=C.UTF-8 bash "$SCRIPT" --lang --help >/dev/null 2>&1; echo $?)" 2
check 'unset locale still defaults to English' "$(env -u LANG -u LC_ALL -u LC_MESSAGES AUTOSTART_MANAGER_LANG=en bash "$SCRIPT" --help | head -n1)" 'Graphical autostart manager for Linux desktops.'

# No English catalog entry may accidentally contain the Spanish labels most likely to leak.
leaks=$(grep -Eic "MSG_EN\[[^]]+\]='[^']*(Categoría|Crítico|Activado|Desactivado|Salir|arranque|Programas de Inicio|Tareas Programadas)" "$SCRIPT" || true)
check 'English catalog has no obvious Spanish UI leakage' "$leaks" 0
spanish_comments=$(python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import re
import sys
text=Path(sys.argv[1]).read_text(encoding="utf-8")
words=(
    "para|que|con|este|esta|cuando|debe|usar|desde|como|solo|si|se|por|sin|"
    "arranque|tarea|sistema|usuario|cambios|servicios|pestaña|elementos|archivo|abrir|volver|lista|idioma|crítico|"
    "aplica|mostrar|activar|desactivar|comprobación|recolecta|traduce|categorías|aviso|mensaje|devuelve|según"
)
pat=re.compile(r"\b(?:"+words+r")\b", re.IGNORECASE)
hits=[line for line in text.splitlines() if line.lstrip().startswith("#") and not line.lstrip().startswith("#!") and pat.search(line)]
print(len(hits))
PY
)
check 'Production comments are fully translated to English' "$spanish_comments" 0
check 'English README matches the actual checklist action' "$(grep -cF 'Press **OK**' "$ROOT_DIR/README.md" || true)" 1
check 'Spanish README matches the actual checklist action' "$(grep -cF 'Pulsa **Aceptar**' "$ROOT_DIR/README.es.md" || true)" 1
check 'English README does not claim system autostart uses pkexec' "$(python3 - "$ROOT_DIR/README.md" <<'PY2'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text(encoding='utf-8')
print(sum(1 for line in text.splitlines() if 'system autostart' in line.lower() and 'pkexec' in line.lower()))
PY2
)" 0
check 'Spanish README does not claim system autostart uses pkexec' "$(python3 - "$ROOT_DIR/README.es.md" <<'PY2'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text(encoding='utf-8')
print(sum(1 for line in text.splitlines() if 'autostart del sistema' in line.lower() and 'pkexec' in line.lower()))
PY2
)" 0

# A result dialog's text must not open by repeating its title (title "All good", text "All good. ...").
repeats_title() {   # TITLE-WITH-PICTOGRAPH TEXT -> 1 if TEXT starts with the title words
    local title="${1#* }"
    [[ "${2,,}" == "${title,,}"* ]] && printf 1 || printf 0
}
repeats=0
for pair in all_ok_title:all_ok_text applied_title:applied_text failure_title:failure_text info_title:no_selection; do
    repeats=$(( repeats + $(repeats_title "${MSG_ES[${pair%%:*}]}" "${MSG_ES[${pair#*:}]}") + $(repeats_title "${MSG_EN[${pair%%:*}]}" "${MSG_EN[${pair#*:}]}") ))
done
check 'Result dialog texts do not repeat their title' "$repeats" 0

# The interface is distribution-neutral: no message or category label names a distribution.
named=$(
    printf '%s\n' "${MSG_ES[@]}" "${MSG_EN[@]}"
    for lang in es en; do LANG_UI=$lang init_categories; printf '%s\n' "${CATEGORY_LABEL[@]}" "${CATEGORY_SHORT[@]}"; done
)
check 'Interface texts name no specific distribution' "$(grep -ciE 'mint|ubuntu|debian|fedora|arch linux|opensuse' <<< "$named" || true)" 0

# Without --text Zenity shows its own default text in the system language (a Spanish interface
# showed "Select items from the list below."), so every dialog call passes its own.
dialog_calls=$(python3 - "$SCRIPT" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read().replace('\\\n', ' ')
calls = re.findall(r'\bzen\s+(--(?:list|entry|question|info|warning|error)\b[^\n]*)', s)
print(len(calls), sum('--text=' not in c for c in calls))
PY
)
check 'Dialog calls are found in the script' "$(( ${dialog_calls% *} >= 16 ))" 1
check 'Every dialog call passes its own text' "${dialog_calls#* }" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
