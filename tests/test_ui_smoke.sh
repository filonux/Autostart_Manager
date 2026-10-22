#!/bin/bash
# Real Zenity under Xvfb: the main menu must render in both UI languages.
# Set REQUIRE_UI_SMOKE=1 (CI does) to turn a missing dependency into a failure.
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

skip_or_fail() {
    if [[ "${REQUIRE_UI_SMOKE:-0}" == 1 ]]; then
        printf 'FAIL: %s\n' "$1"; echo "1 tests: 0 passed, 1 failed"; exit 1
    fi
    printf 'SKIP: %s\n' "$1"; exit 0
}

command -v zenity >/dev/null 2>&1 || skip_or_fail 'zenity is not installed.'
command -v xvfb-run >/dev/null 2>&1 || skip_or_fail 'xvfb-run is not installed.'

# As root the app asks for confirmation first, so run it unprivileged.
as_user=()
if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || skip_or_fail 'runuser is not installed.'
    as_user=(runuser -u nobody --)
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOME_FAKE="$TMP/home"; mkdir -p "$BIN" "$HOME_FAKE/.config/autostart"
chmod 777 "$TMP" "$HOME_FAKE"

cat > "$HOME_FAKE/.config/autostart/smoke.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Smoke Test
Exec=/usr/bin/true
Hidden=false
X-GNOME-Autostart-enabled=true
DESK

for tool in systemctl crontab; do
    printf '#!/bin/bash\nexit 0\n' > "$BIN/$tool"
done
chmod +x "$BIN"/*

# Test double for zenity: logs the call, polls the screen until the dialog is
# drawn (no fixed delay, so slow machines do not cause false failures), then
# closes it as a timeout would. --timeout must come before "--" because
# everything after it is list data.
cat > "$TMP/zenity" <<'WRAP'
#!/bin/bash
set -u
[[ "${1:-}" == --version ]] && exec /usr/bin/zenity --version
printf '%s\n' "$*" >> "${ZEN_LOG:?}"
/usr/bin/zenity --timeout=30 "$@" &
zenity_pid=$!
if command -v import >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
        sleep 0.3
        kill -0 "$zenity_pid" 2>/dev/null || break
        import -display "$DISPLAY" -window root "${ZEN_SHOT:?}.png" 2>/dev/null || continue
        deviation=$(identify -format '%[fx:standard_deviation]' "$ZEN_SHOT.png" 2>/dev/null) || continue
        if awk -v d="$deviation" 'BEGIN { exit !(d > 0.001) }'; then
            cp -f "$ZEN_SHOT.png" "$ZEN_SHOT.content.png"
            break
        fi
    done
fi
kill "$zenity_pid" 2>/dev/null
wait "$zenity_pid" 2>/dev/null
exit 5
WRAP
chmod +x "$TMP/zenity"

run_case() {
    local lang="$1" expected_title="$2" expected_switch="$3"
    local log="$TMP/zenity-$lang.log" shot="$TMP/ui-$lang" rc shots_ok=none
    : > "$log"; chmod 666 "$log"

    timeout -k 2 60 "${as_user[@]}" env \
        HOME="$HOME_FAKE" XDG_CURRENT_DESKTOP=X-Cinnamon \
        PATH="$TMP:$BIN:$PATH" AUTOSTART_MANAGER_LANG="$lang" \
        ZEN_LOG="$log" ZEN_SHOT="$shot" \
        xvfb-run -a bash "$SCRIPT" >"$TMP/out-$lang.txt" 2>&1
    rc=$?

    check "$lang: script exits normally when the dialog closes" "$rc" 0
    check "$lang: main menu title is rendered" \
        "$(grep -c -- "--title=$expected_title" "$log")" 1
    check "$lang: language switch label is rendered" \
        "$(grep -cF -- "$expected_switch" "$log")" 1

    if command -v identify >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then
        [[ -s "$shot.content.png" ]] && shots_ok=content
        check "$lang: screen capture shows the rendered dialog" "$shots_ok" content
    elif [[ "${REQUIRE_UI_SMOKE:-0}" == 1 ]]; then
        check "$lang: ImageMagick is available for the screen capture" missing available
    fi
}

run_case en '⚙ Autostart Manager' '🌐 Switch language (EN ⇄ ES)'
run_case es '⚙ Gestor de arranque automático' '🌐 Cambiar idioma (ES ⇄ EN)'

echo "$((pass + fail)) tests: $pass passed, $fail failed"
(( fail == 0 ))
