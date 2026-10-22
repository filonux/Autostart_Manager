#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

run_case() {
    local lang="$1" outdir="$2" bin home
    bin="$TMP/bin-$lang"; home="$TMP/home-$lang"
    mkdir -p "$bin" "$home/.config/autostart"
    cat > "$home/.config/autostart/demo.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Generic Demo
Name[en]=Demo Application
Name[es]=Aplicación Demo
Exec=/usr/bin/true
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOP
    cat > "$home/.config/autostart/other.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Other Application
Exec=/usr/bin/true
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOP
    : > "$TMP/cron-$lang"
    : > "$TMP/xdg-$lang.log"

    for tool in zenity pgrep; do
        cat > "$bin/$tool" <<'SH'
#!/bin/bash
exit 0
SH
        chmod +x "$bin/$tool"
    done
    cat > "$bin/xdg-open" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "${OPEN_LOG:?}"
SH
    chmod +x "$bin/xdg-open"
    cat > "$bin/crontab" <<'SH'
#!/bin/bash
if [[ "${1:-}" == '-l' ]]; then cat "${CRON_FILE:?}"; exit 0; fi
exit 0
SH
    chmod +x "$bin/crontab"
    cat > "$bin/systemctl" <<'SH'
#!/bin/bash
if [[ "${1:-}" == '--user' && "${2:-}" == show ]]; then printf '%s\n' /dev/null; fi
SH
    chmod +x "$bin/systemctl"

    export PATH="$bin:$PATH" HOME="$home" OPEN_LOG="$TMP/xdg-$lang.log"
    export AUTOSTART_MANAGER_TEST=1 AUTOSTART_MANAGER_LANG="$lang" LANG=C.UTF-8 LC_ALL=C.UTF-8
    # shellcheck source=../script/Autostart_Manager.sh
    source "$SCRIPT"
    SYSTEMCTL_BIN="$bin/systemctl"
    init_categories

    ARR_KIND=(user_autostart user_autostart cron_user)
    ARR_RAW=("$home/.config/autostart/demo.desktop" "$home/.config/autostart/other.desktop" 1)
    ARR_STATUS=(TRUE TRUE TRUE)
    ARR_STATUS_LABEL=("$(msg enabled)" "$(msg enabled)" "$(msg enabled)")
    ARR_TYPE=("👤 $(msg user_type)" "👤 $(msg user_type)" "⏰ $(msg cron_task)")
    ARR_NAME=('Demo Application' 'Other Application' 'Every Hour')
    ARR_SRC=("$home/.config/autostart/demo.desktop" "$home/.config/autostart/other.desktop" 'crontab line 1')
    ARR_MODE=('' '' '')
    refresh_items() { :; }

    # Scripted user: Search, OK without changes, Open, then Cancel. An extra button prints its label and exits 1.
    zen() {
        local joined=" $* " n a
        local -a extras=()
        printf '%s\n' "$*" >> "$TMP/ui-$lang.log"
        if [[ "$joined" == *' --list --checklist '* ]]; then
            for a in "$@"; do [[ "$a" == --extra-button=* ]] && extras+=("${a#*=}"); done
            n=$(cat "$TMP/check-$lang" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$TMP/check-$lang"
            (( n == 2 )) && printf '%s' "$*" > "$TMP/filtered-$lang.log"
            case "$n" in
                1) printf '%s' "${extras[0]:-}"; return 1 ;;   # Search / filter
                2) printf '0'; return 0 ;;                     # OK, Demo still checked: nothing to apply
                3) printf '%s' "${extras[1]:-}"; return 1 ;;   # Open / view source
                *) return 1 ;;                                 # Cancel
            esac
        fi
        if [[ "$joined" == *' --entry '* ]]; then
            printf 'Demo'
            return 0
        fi
        if [[ "$joined" == *' --list '* ]]; then
            printf '0'
            return 0
        fi
        return 0
    }

    rm -f "$TMP/check-$lang" "$TMP/question-$lang" "$TMP/ui-$lang.log"
    : > "$TMP/checklist-$lang.log"
    show_category_checklist ALL >/dev/null 2>&1 || true

    mkdir -p "$outdir"
    cp "$TMP/ui-$lang.log" "$outdir/ui.log"
    cp "$OPEN_LOG" "$outdir/open.log"
}

run_case es "$TMP/es"
run_case en "$TMP/en"
open_es=$(sed -E 's#.*/\.config/autostart/#AUTOSTART/#' "$TMP/es/open.log")
open_en=$(sed -E 's#.*/\.config/autostart/#AUTOSTART/#' "$TMP/en/open.log")
check 'ES/EN search/filter/open selected the same source' "$open_es" "$open_en"
filtered_en=$(cat "$TMP/filtered-en.log" 2>/dev/null || true)
filtered_es=$(cat "$TMP/filtered-es.log" 2>/dev/null || true)
check 'filter flow keeps the matching item in both languages' "$([[ "$filtered_en" == *'Demo Application'* && "$filtered_en" != *'Other Application'* && "$filtered_es" == *'Demo Application'* && "$filtered_es" != *'Other Application'* ]] && echo 0 || echo 1)" 0


# The dialogs of the flow, as the program passed them to Zenity in each language.
ui_has() { grep -qF -- "$2" "$TMP/ui-$1.log" && echo 0 || echo 1; }
check 'combined view titles its checklist, filter entry and open list in Spanish' \
    "$(( $(ui_has es '--title=🔍 Todas las categorías') + $(ui_has es '--title=🔍 Filtrar «Todas las categorías»') + $(ui_has es '--title=📂 Abrir / ver elemento') ))" 0
check 'combined view titles its checklist, filter entry and open list in English' \
    "$(( $(ui_has en '--title=🔍 All categories') + $(ui_has en '--title=🔍 Filter "All categories"') + $(ui_has en '--title=📂 Open / view item') ))" 0
check 'checklist passes Search and Open as extra buttons in Spanish' \
    "$(( $(ui_has es '--extra-button=🔍 Buscar / filtrar') + $(ui_has es '--extra-button=📂 Abrir / ver origen') ))" 0
check 'checklist passes Search and Open as extra buttons in English' \
    "$(( $(ui_has en '--extra-button=🔍 Search / filter') + $(ui_has en '--extra-button=📂 Open / view source') ))" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
