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

BIN="$TMP/bin"; HOME="$TMP/home"; mkdir -p "$BIN" "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/demo.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Demo
Exec=/usr/bin/true
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOP

cat > "$BIN/zenity" <<'SH2'
#!/bin/bash
exit 0
SH2
chmod +x "$BIN/zenity"

for tool in pgrep systemctl crontab; do
    cat > "$BIN/$tool" <<'SH2'
#!/bin/bash
exit 0
SH2
    chmod +x "$BIN/$tool"
done

export PATH="$BIN:$PATH" HOME AUTOSTART_MANAGER_TEST=1 AUTOSTART_MANAGER_LANG=es LANG=C.UTF-8 LC_ALL=C.UTF-8
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
init_categories
ARR_KIND=(user_autostart)
ARR_RAW=("$HOME/.config/autostart/demo.desktop")
ARR_STATUS=(TRUE)
ARR_STATUS_LABEL=("$(msg enabled)")
ARR_TYPE=("$(msg user_type)")
ARR_NAME=(Demo)
ARR_SRC=("$HOME/.config/autostart/demo.desktop")
ARR_MODE=('')
refresh_count=0
dirty_refreshes=0
ITEMS_DIRTY=0
refresh_items() {
    ((refresh_count++))
    if (( ITEMS_DIRTY )); then
        ((dirty_refreshes++))
        ITEMS_DIRTY=0
    fi
}

menu_calls="$TMP/menu.log"; : > "$menu_calls"
zen() {
    printf '%s\n' "$*" >> "$menu_calls"
    if [[ " $* " == *' --list '* ]]; then
        local n=0
        [[ -f "$TMP/menu-n" ]] && n=$(cat "$TMP/menu-n")
        n=$((n + 1)); printf '%s' "$n" > "$TMP/menu-n"
        case "$n" in
            1|2|3) printf 'L'; return 0;;
            *) return 1;;
        esac
    fi
    return 0
}

LANG_UI=es
main_loop >/dev/null 2>&1 || true

first=$(sed -n '1p' "$menu_calls")
second=$(sed -n '2p' "$menu_calls")
third=$(sed -n '3p' "$menu_calls")
count=$(grep -c -- '--list' "$menu_calls" || true)

check 'GUI switch action is present in Spanish' "$(printf '%s' "$first" | grep -oF '🌐 Cambiar idioma (ES ⇄ EN)' || true)" '🌐 Cambiar idioma (ES ⇄ EN)'
check 'GUI switch instruction is explicit Spanish selection' "$(printf '%s' "$first" | grep -oF 'Selecciona y pulsa Aceptar' || true)" 'Selecciona y pulsa Aceptar'
check 'GUI switch action is present in English' "$(printf '%s' "$second" | grep -oF '🌐 Switch language (EN ⇄ ES)' || true)" '🌐 Switch language (EN ⇄ ES)'
check 'GUI switch instruction is explicit English selection' "$(printf '%s' "$second" | grep -oF 'Select, then press OK' || true)" 'Select, then press OK'
check 'second switch returns to Spanish' "$(printf '%s' "$third" | grep -oF '🌐 Cambiar idioma (ES ⇄ EN)' || true)" '🌐 Cambiar idioma (ES ⇄ EN)'
check 'GUI action does not advertise a fake keyboard shortcut' "$(grep -Eihc 'press L|pulsa L|tecla L' "$SCRIPT" "$ROOT_DIR/README.md" "$ROOT_DIR/README.es.md" 2>/dev/null | awk '{sum += $1} END {print sum+0}')" 0
check 'GUI switch rebuilds the menu after each selection' "$count" 4
check 'language switch invalidates the live inventory' "$ITEMS_DIRTY" 0
check 'language switch forced three localized inventory refreshes' "$dirty_refreshes" 3

# main_loop reads the Zenity major version once and sizes the 7-row, one-line menu for it.
cat > "$BIN/zenity" <<'EOF'
#!/bin/bash
[[ "${1:-}" == --version ]] && echo 4.0.1
exit 0
EOF
: > "$menu_calls"; ZEN_MAJOR=3
main_loop >/dev/null 2>&1 || true
check 'main loop detects the Zenity major version' "$ZEN_MAJOR" 4
check 'main menu height fits its rows for the detected Zenity' \
    "$(grep -o -m1 -- '--height=[0-9]*' "$menu_calls")" "--height=$(( FIT_GTK4[0] + FIT_GTK4[1] + 7 * FIT_GTK4[2] ))"

# The main menu must dispatch both category tabs and global search to the real screen handler.
menu_select_log="$TMP/menu-select.log"; : > "$menu_select_log"; : > "$TMP/menu-select-n"
show_category_checklist() { printf '%s\n' "$1" >> "$menu_select_log"; }
zen() {
    if [[ " $* " == *' --list '* ]]; then
        n=$(cat "$TMP/menu-select-n" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$TMP/menu-select-n"
        case "$n" in 1) printf '4';; 2) printf '0';; *) return 1;; esac
        return 0
    fi
    return 0
}
main_loop >/dev/null 2>&1 || true
check 'main menu opens selected category and global search' "$(tr '\n' '|' < "$menu_select_log")" '4|ALL|'
unset -f show_category_checklist

# Cancellation/close must not toggle the language.
zen() { return 1; }
LANG_UI=en
main_loop >/dev/null 2>&1 || true
check 'closing the main menu does not change language' "$LANG_UI" en

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
