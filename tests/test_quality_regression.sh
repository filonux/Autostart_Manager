#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; ETC="$TMP/etc/xdg/autostart"; HOME_FAKE="$TMP/home"
mkdir -p "$BIN" "$ETC" "$HOME_FAKE/.config/autostart"

pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

# Print the exit status of a command (for use inside check).
rc_of() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

cat > "$BIN/zenity" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${ZEN_LOG:?}"
case "${ZEN_RESULT:-0}" in
  output) printf '%s' "${ZEN_OUTPUT:-}"; exit 0 ;;
  255) exit 255 ;;
  *) exit "${ZEN_RESULT:-0}" ;;
esac
SH
cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${1:-}" == "--user" && "${2:-}" == "list-unit-files" ]]; then
    cat "${USER_UNITS:?}"; exit 0
fi
if [[ "${1:-}" == "list-unit-files" ]]; then
    cat "${SYSTEM_UNITS:?}"; exit 0
fi
if [[ "${1:-}" == "--user" && "${2:-}" == "show" ]]; then
    printf '%s\n' "${UNIT_PATH:-}"; exit 0
fi
if [[ "${FAIL_UNIT:-}" == "${@: -1}" ]]; then
    printf 'simulated failure for %s\n' "${@: -1}" >&2; exit 7
fi
exit 0
SH
cat > "$BIN/crontab" <<'SH'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "${CRON_LOG:?}"
if [[ "${1:-}" == '-l' ]]; then
    if [[ "${RACE_MODE:-0}" == 1 ]]; then
        n=$(cat "${RACE_COUNT_FILE:?}" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$RACE_COUNT_FILE"
        if (( n > 1 )); then cat "${CRON_RACE_FILE:?}"; else cat "${CRON_FILE:?}"; fi
    else
        cat "${CRON_FILE:?}"
    fi
    exit 0
fi
if [[ -f "${1:-}" ]]; then cp "$1" "${CRON_FILE:?}"; exit 0; fi
exit 0
SH
cat > "$BIN/pkexec" <<'SH'
#!/bin/bash
printf 'pkexec %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${PKEXEC_RC:-}" =~ ^[0-9]+$ ]]; then exit "$PKEXEC_RC"; fi
exec "${@: -2}"
SH
cat > "$BIN/timeout" <<'SH'
#!/bin/bash
printf 'timeout %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${FORCE_TIMEOUT_RC:-}" =~ ^[0-9]+$ ]]; then exit "$FORCE_TIMEOUT_RC"; fi
shift
exec "$@"
SH
cat > "$BIN/grep" <<'SH'
#!/bin/bash
LC_ALL=C.UTF-8 exec /usr/bin/grep "$@"
SH
cat > "$BIN/pgrep" <<'SH'
#!/bin/bash
exit "${PGREP_RC:-0}"
SH
cat > "$BIN/xdg-open" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$BIN"/*

export PATH="$BIN:$PATH" HOME="$HOME_FAKE" AUTOSTART_MANAGER_TEST=1
export XDG_CONFIG_HOME="$HOME_FAKE/.config" XDG_CONFIG_DIRS="$TMP/etc/xdg"
export XDG_RUNTIME_DIR="$TMP/runtime"
mkdir -m 700 "$XDG_RUNTIME_DIR"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export -n LC_ALL
export ZEN_LOG="$TMP/zen.log" SYSTEM_LOG="$TMP/system.log" CRON_LOG="$TMP/cron.log"
export USER_UNITS="$TMP/user.units" SYSTEM_UNITS="$TMP/system.units" CRON_FILE="$TMP/crontab"
export RACE_COUNT_FILE="$TMP/race.count" CRON_RACE_FILE="$TMP/crontab.race"
: > "$ZEN_LOG"; : > "$SYSTEM_LOG"; : > "$CRON_LOG"
: > "$USER_UNITS"; : > "$SYSTEM_UNITS"; : > "$CRON_FILE"

# Use the real production XDG lookup with a hermetic fixture root.
FIXTURE_SCRIPT="$TMP/Autostart_Manager.sh"
sed -e "s#/usr/bin/pkexec#$BIN/pkexec#g" "$SCRIPT" > "$FIXTURE_SCRIPT"

# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
# shellcheck disable=SC2329  # test double, called by the sourced script
pkexec_path() { printf '%s\n' "$BIN/pkexec"; }

check 'CLI works without TERM and without a TTY' "$(env -u TERM -u COLUMNS -u LINES bash "$SCRIPT" --version </dev/null >/dev/null 2>&1; echo $?)" 0
check 'CLI tolerates an unknown TERM value' "$(TERM=unknown COLUMNS=0 LINES=0 bash "$SCRIPT" --help </dev/null >/dev/null 2>&1; echo $?)" 0

# Desktop-entry name resolution.
cat > "$TMP/names.desktop" <<'EOF2'
[Desktop Entry]
Name=Generic Name
Name[en]=English Name
Name[en_GB]=British Name
Name[es]=Nombre Español
Name[es_ES]=Nombre de España
X-Name[es]=DEBE IGNORARSE
EOF2
cat > "$TMP/names-modifier.desktop" <<'EOF2'
[Desktop Entry]
Name=Generic Name
Name[es]=Nombre base
Name[es_ES]=Nombre regional
Name[es@traditional]=Nombre con modificador
Name[es_ES@traditional]=Nombre regional con modificador
EOF2
name_in_locale() {
    local lc="$1" ui="$2" file="$3"
    # shellcheck disable=SC2016  # the inner script is single-quoted on purpose
    env LANG=C.UTF-8 AUTOSTART_MANAGER_TEST=1 \
        bash -c 'source "$1"; LC_ALL="$3"; LC_MESSAGES="$3"; LANG="$3"; LANG_UI="$2"; get_desktop_name "$4"' _ "$SCRIPT" "$ui" "$lc" "$file" 2>/dev/null
}
check 'desktop name prefers selected regional English' "$(name_in_locale en_GB en "$TMP/names.desktop")" 'British Name'
check 'desktop name follows selected UI language over locale' "$(name_in_locale es_ES en "$TMP/names.desktop")" 'English Name'
cat > "$TMP/names-en-regional.desktop" <<'EOF'
[Desktop Entry]
Name=Default
Name[en_GB]=British Name
Name[en]=English Name
Name[es]=Nombre Español
EOF
check 'desktop English UI falls back from regional name to base language' "$(name_in_locale es_ES en "$TMP/names-en-regional.desktop")" 'English Name'

check 'desktop name prefers selected Spanish regional fallback' "$(name_in_locale en_GB es "$TMP/names.desktop")" 'Nombre Español'
check 'desktop name uses generic fallback when localized name missing' "$(name_in_locale C.UTF-8 es "$(printf '[Desktop Entry]\nName=Generic\n' > "$TMP/generic.desktop"; printf '%s' "$TMP/generic.desktop")")" 'Generic'
check 'desktop name ignores X-Name lookalike keys' "$(name_in_locale es_ES es "$TMP/names.desktop")" 'Nombre de España'
check 'desktop name follows full locale modifier fallback' "$(name_in_locale es_ES@traditional es "$TMP/names-modifier.desktop")" 'Nombre regional con modificador'
check 'desktop name preserves locale modifier after stripping encoding' "$(name_in_locale es_ES.UTF-8@traditional es "$TMP/names-modifier.desktop")" 'Nombre regional con modificador'
check 'desktop name falls from regional locale to modifier fallback' "$(name_in_locale es_MX@traditional es "$TMP/names-modifier.desktop")" 'Nombre con modificador'
check 'desktop name falls to base language' "$(name_in_locale es_MX es "$TMP/names-modifier.desktop")" 'Nombre base'

# Desktop activation semantics.
for pair in \
  'Hidden=true|FALSE' \
  'Hidden=false|TRUE' \
  'X-GNOME-Autostart-enabled=false|FALSE' \
  'X-GNOME-Autostart-enabled=true|TRUE' \
  '[Desktop Entry]|TRUE'; do
    IFS='|' read -r line expected <<< "$pair"
    printf '[Desktop Entry]\n%s\n' "$line" > "$TMP/state.desktop"
    check "desktop state: $line" "$(is_desktop_enabled "$TMP/state.desktop")" "$expected"
done

# User desktop mutation preserves unrelated fields.
cat > "$TMP/user.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Exec=/usr/bin/demo --flag
Name=Demo
Hidden=false
X-GNOME-Autostart-enabled=false
X-Custom=preserve
EOF2
ARR_KIND=(user_autostart); ARR_RAW=("$TMP/user.desktop"); ARR_STATUS=(TRUE)
set_item_state 0 FALSE
check 'user disable changes only activation state' "$(grep -E '^(Exec|Name|X-Custom)=' "$TMP/user.desktop" | tr '\n' '|')" 'Exec=/usr/bin/demo --flag|Name=Demo|X-Custom=preserve|'
check 'user disable sets Hidden=true' "$(grep '^Hidden=' "$TMP/user.desktop")" 'Hidden=true'
set_item_state 0 TRUE
check 'user enable restores both known activation flags' "$(grep -E '^(Hidden|X-GNOME-Autostart-enabled)=' "$TMP/user.desktop" | tr '\n' '|')" 'Hidden=false|X-GNOME-Autostart-enabled=true|'

# System autostart behavior, including full-copy restoration for a disabled system default.
cat > "$ETC/system.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=true
X-GNOME-Autostart-enabled=false
X-Custom=preserve
EOF2
# shellcheck disable=SC1090
HOME="$HOME_FAKE" source "$FIXTURE_SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
ARR_KIND=(system_autostart); ARR_RAW=("$ETC/system.desktop"); ARR_STATUS=(FALSE); ARR_MODE=()
set_item_state 0 TRUE
check 'system re-enable copies executable content' "$(grep -E '^(Exec|X-Custom)=' "$HOME_FAKE/.config/autostart/system.desktop" | tr '\n' '|')" 'Exec=/usr/bin/system-app|X-Custom=preserve|'
check 'system re-enable enables copied entry' "$(grep -E '^(Hidden|X-GNOME-Autostart-enabled)=' "$HOME_FAKE/.config/autostart/system.desktop" | tr '\n' '|')" 'Hidden=false|X-GNOME-Autostart-enabled=true|'
set_item_state 0 FALSE
check 'system disable preserves generated full override safely' "$(grep -E '^(Exec|Hidden|X-AutostartManager-Generated)=' "$HOME_FAKE/.config/autostart/system.desktop" | tr '\n' '|')" 'Exec=/usr/bin/system-app|Hidden=true|X-AutostartManager-Generated=true|'

cat > "$ETC/enabled.desktop" <<'EOF2'
[Desktop Entry]
Exec=/usr/bin/enabled-app
Hidden=false
EOF2
ARR_RAW=("$ETC/enabled.desktop"); ARR_STATUS=(TRUE)
cat > "$HOME_FAKE/.config/autostart/enabled.desktop" <<'EOF2'
[Desktop Entry]
Hidden=true
EOF2
set_item_state 0 TRUE
check 'system enable removes override when system default is enabled' "$(rc_of test ! -e "$HOME_FAKE/.config/autostart/enabled.desktop")" 0

# XDG_CONFIG_DIRS is ordered by precedence: first absolute directory wins.
XDG_HIGH="$TMP/xdg-high" XDG_LOW="$TMP/xdg-low"
mkdir -p "$XDG_HIGH/autostart" "$XDG_LOW/autostart"
cat > "$XDG_HIGH/autostart/duplicate.desktop" <<'EOF2'
[Desktop Entry]
Name=High Priority
Exec=/usr/bin/high
Hidden=false
EOF2
cat > "$XDG_LOW/autostart/duplicate.desktop" <<'EOF2'
[Desktop Entry]
Name=Low Priority
Exec=/usr/bin/low
Hidden=false
EOF2
newline_xdg="$TMP/etc/xdg"$'\n'"with-newline"
mkdir -p "$newline_xdg/autostart"
cat > "$newline_xdg/autostart/newline-path.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Newline Path
Exec=/usr/bin/true
EOF2
XDG_CONFIG_DIRS="$newline_xdg" collect_items
newline_path_file="$newline_xdg/autostart/newline-path.desktop"
newline_found=0
for raw in "${ARR_RAW[@]}"; do
    [[ "$raw" == "$newline_path_file" ]] && newline_found=1
done
check 'inventory preserves XDG_CONFIG_DIRS paths containing newlines' "$newline_found" 1
XDG_CONFIG_DIRS="$XDG_HIGH:$XDG_LOW"; collect_items
check 'system inventory uses highest-priority duplicate' "$(for i in "${!ARR_RAW[@]}"; do [[ "${ARR_KIND[$i]}" == system_autostart && "$(basename -- "${ARR_RAW[$i]}")" == duplicate.desktop ]] && printf '%s' "${ARR_RAW[$i]}"; done)" "$XDG_HIGH/autostart/duplicate.desktop"

# Desktop environment applicability.
cat > "$TMP/env.desktop" <<'EOF2'
[Desktop Entry]
OnlyShowIn=GNOME;KDE;
EOF2
LANG_UI=en; XDG_CURRENT_DESKTOP=X-Cinnamon; check 'OnlyShowIn mismatch is annotated' "$(desktop_env_note "$TMP/env.desktop")" '  [not applicable to X-Cinnamon: OnlyShowIn=GNOME;KDE;]'
LANG_UI=en; XDG_CURRENT_DESKTOP='GNOME:X-Cinnamon'; check 'OnlyShowIn match is not annotated' "$(desktop_env_note "$TMP/env.desktop")" ''
cat > "$TMP/not.desktop" <<'EOF2'
[Desktop Entry]
NotShowIn=X-Cinnamon;
EOF2
LANG_UI=es; XDG_CURRENT_DESKTOP=X-Cinnamon; check 'NotShowIn match is annotated in Spanish' "$(desktop_env_note "$TMP/not.desktop")" '  [no se aplica a X-Cinnamon: NotShowIn=X-Cinnamon;]'

# Inventory integration must discover every real mechanism and preserve the category split.
INVENTORY_HOME="$TMP/inventory-home"; rm -rf "$INVENTORY_HOME" "$ETC"; mkdir -p "$INVENTORY_HOME/.config/autostart" "$ETC"
cat > "$INVENTORY_HOME/.config/autostart/user.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=User Only
Exec=/usr/bin/user-app
Hidden=false
EOF2
cat > "$ETC/system-inventory.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=System Entry
Exec=/usr/bin/system-app
Hidden=true
EOF2
printf '%s\n' 'session.service enabled' 'session.socket disabled' > "$USER_UNITS"
printf '%s\n' 'NetworkManager.service enabled' 'thirdparty.service disabled' > "$SYSTEM_UNITS"
cat > "$CRON_FILE" <<'CRON'
SHELL=/bin/bash
# comment
*/5 * * * * /usr/bin/cron-app --foo && echo ok
CRON
HOME="$INVENTORY_HOME"
# shellcheck source=/dev/null  # the fixture script is generated at run time
source "$FIXTURE_SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
HAS_SYSTEMD=1; HAS_CRONTAB=1; LANG_UI=en; XDG_CURRENT_DESKTOP=X-Cinnamon; collect_items
check 'inventory discovers user autostart' "$(printf '%s\n' "${ARR_KIND[@]}" | grep -c '^user_autostart$')" 1
check 'inventory discovers system autostart' "$(printf '%s\n' "${ARR_KIND[@]}" | grep -c '^system_autostart$')" 1
check 'inventory discovers both user systemd service and socket' "$(printf '%s\n' "${ARR_KIND[@]}" | grep -c '^systemd_user$')" 2
check 'inventory discovers both system systemd units' "$(printf '%s\n' "${ARR_KIND[@]}" | grep -c '^systemd_system$')" 2
check 'inventory discovers cron task' "$(printf '%s\n' "${ARR_KIND[@]}" | grep -c '^cron_user$')" 1

# Empty or missing autostart directories must not create a literal *.desktop row.
empty_xdg="$TMP/empty-xdg"
empty_home="$TMP/empty-home"
mkdir -p "$empty_xdg/autostart" "$empty_home/.config"
old_home="$HOME"; old_cfg="$XDG_CONFIG_HOME"; old_dirs="$XDG_CONFIG_DIRS"
HOME="$empty_home"; XDG_CONFIG_HOME="$empty_home/.config"; XDG_CONFIG_DIRS="$empty_xdg"
collect_items
HOME="$old_home"; XDG_CONFIG_HOME="$old_cfg"; XDG_CONFIG_DIRS="$old_dirs"
check 'empty autostart trees produce no literal desktop row' "$(printf '%s\n' "${ARR_RAW[@]}" | grep -c '\.desktop$' || true)" 0
check 'inventory keeps NetworkManager in the System Services category' "$(for i in "${!ARR_RAW[@]}"; do [[ "${ARR_RAW[$i]}" == NetworkManager.service ]] && item_category "$i"; done)" 5
check 'inventory keeps third-party system unit in application category' "$(for i in "${!ARR_RAW[@]}"; do [[ "${ARR_RAW[$i]}" == thirdparty.service ]] && item_category "$i"; done)" 4
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
HOME="$HOME_FAKE"
LANG_UI=en; init_categories

# Cron parser and round-trip behavior.
printf 'MAILTO=user@example.org\n# comment\n  #DISABLED#   0 1 * * * /usr/bin/disabled\n0 2 * * * /usr/bin/job && echo ok' > "$CRON_FILE"
HAS_CRONTAB=1
collect_items
cron_ids=(); cron_state=(); cron_name=();
for i in "${!ARR_KIND[@]}"; do
    [[ "${ARR_KIND[$i]}" == cron_user ]] || continue
    cron_ids+=("${ARR_RAW[$i]}"); cron_state+=("${ARR_STATUS[$i]}"); cron_name+=("${ARR_NAME[$i]}")
done
check 'cron parser ignores variables and comments' "${#cron_ids[@]}" 2
check 'cron parser tracks physical line numbers' "${cron_ids[*]}" '3 4'
check 'cron parser identifies disabled/enabled state' "${cron_state[*]}" 'FALSE TRUE'
ARR_KIND=(cron_user); ARR_RAW=(3); ARR_STATUS=(FALSE); set_item_state 0 TRUE
check 'cron enable removes marker while preserving task spacing' "$(sed -n '3p' "$CRON_FILE")" '  0 1 * * * /usr/bin/disabled'
printf '   5 6 * * * /usr/bin/indented\n' > "$CRON_FILE"
ARR_KIND=(cron_user); ARR_RAW=(1); ARR_STATUS=(TRUE); ARR_MODE=('   5 6 * * * /usr/bin/indented')
set_item_state 0 FALSE; ARR_MODE=(); set_item_state 0 TRUE
check 'cron enable preserves multiple original leading spaces' "$(sed -n '1p' "$CRON_FILE")" '   5 6 * * * /usr/bin/indented'
: > "$RACE_COUNT_FILE"
printf '9 9 * * * /usr/bin/original\n' > "$CRON_FILE"
printf '9 9 * * * /usr/bin/changed\n' > "$CRON_RACE_FILE"
ARR_KIND=(cron_user); ARR_RAW=(1); ARR_STATUS=(TRUE); ARR_MODE=('9 9 * * * /usr/bin/original')
RACE_MODE=1; export RACE_MODE=1; set_item_state 0 FALSE; race_rc=$?; export RACE_MODE=0
check 'cron TOCTOU change aborts before reinstall' "$race_rc" 1
LANG_UI=es check 'cron TOCTOU reports changed snapshot' "${LAST_ERR[0]:-}" "$(msg cron_changed)"
check 'cron TOCTOU leaves newer crontab untouched' "$(cat "$CRON_FILE")" '9 9 * * * /usr/bin/original'
# with_lock must not redirect the caller's stderr while opening its lock file.
ERR_PROBE=0
probe_stderr() { printf 'LOCK_PROBE_ERROR\n' >&2; return 1; }
capture_err with_lock probe_stderr; ERR_PROBE=$?
check 'with_lock preserves stderr diagnostics' "$CAPTURED_ERR" 'LOCK_PROBE_ERROR'
check 'with_lock preserves failure status' "$ERR_PROBE" 1

FLOCK_LOG="$TMP/flock-use.log"
cat > "$BIN/flock" <<'EOF2'
#!/bin/bash
printf 'used\n' >> "${FLOCK_LOG:?}"
exit 0
EOF2
chmod +x "$BIN/flock"; hash -r
bad_runtime="$TMP/runtime-bad"
mkdir -m 755 "$bad_runtime"
FLOCK_LOG="$FLOCK_LOG" XDG_RUNTIME_DIR="$bad_runtime" with_lock true
check 'with_lock ignores a runtime directory that is not 0700' "$(test -s "$FLOCK_LOG" && echo used || echo unused)" unused
rm -f "$BIN/flock"; hash -r
cat > "$BIN/flock" <<'EOF2'
#!/bin/bash
printf 'used\n' >> "${FLOCK_LOG:?}"
exit 0
EOF2
chmod +x "$BIN/flock"; hash -r
secure_runtime="$TMP/runtime-good"
mkdir -m 700 "$secure_runtime"
: > "$FLOCK_LOG"
FLOCK_LOG="$FLOCK_LOG" XDG_RUNTIME_DIR="$secure_runtime" with_lock true
check 'with_lock ignores caller PATH for flock' "$(test -s "$FLOCK_LOG" && echo used || echo unused)" unused
rm -f "$BIN/flock"; hash -r
: > "$SYSTEM_LOG"
PRIV_TIMEOUT_BIN="" run_privileged_batch <<< $'true' >/dev/null 2>&1
check 'privileged batch ignores caller PATH for timeout' "$(grep -c '^timeout ' "$SYSTEM_LOG" || true)" 0
cat > "$BIN/sync" <<'EOF2'
#!/bin/bash
printf 'used\n' >> "${SYNC_PATH_LOG:?}"
exit 0
EOF2
chmod +x "$BIN/sync"; hash -r
SYNC_PATH_LOG="$TMP/sync-path.log"
: > "$SYNC_PATH_LOG"
printf 'data\n' > "$TMP/sync-path-target"
PATH="$BIN:$PATH" atomic_sync_file "$TMP/sync-path-target" >/dev/null 2>&1
check 'atomic sync ignores caller PATH' "$(test -s "$SYNC_PATH_LOG" && echo used || echo unused)" unused
atomic_src="$TMP/atomic-path-src"; atomic_dst="$TMP/atomic-path-dst"
printf 'new\n' > "$atomic_src"
printf 'old\n' > "$atomic_dst"
: > "$SYNC_PATH_LOG"
PATH="$BIN:$PATH" ATOMIC_SYNC_BIN="" atomic_install "$atomic_src" "$atomic_dst" >/dev/null 2>&1
check 'atomic install ignores caller PATH for directory sync' "$(test -s "$SYNC_PATH_LOG" && echo used || echo unused)" unused
rm -f "$BIN/sync"; hash -r

# Filtering/escaping contracts.
check 'Pango escaping handles repeated ampersands safely' "$(esc_markup 'A && B < C > D & E')" 'A &amp;&amp; B &lt; C &gt; D &amp; E'
check 'ASCII fallback preserves printable shell syntax' "$(NEED_ASCII_ZENITY=1 ascii_safe 'echo "á" && ñ < x > y')" 'echo "a" && n < x > y'
: > "$ZEN_LOG"; export ZEN_RESULT=output ZEN_OUTPUT=ok NEED_ASCII_ZENITY=1
LANG_UI=en; out=$(zen --list --title='Té' -- "--title=á && x" 'normal ñ'); rc=$?
check 'ASCII zenity sanitization does not alter list data after --' "$(head -n1 "$ZEN_LOG")" '--ok-label=OK --cancel-label=Cancel --list --title=Te -- --title=á && x normal ñ'
malicious_dir="$TMP/malicious-bin"; mkdir -p "$malicious_dir"
printf '#!/bin/bash\nexit 0\n' > "$malicious_dir/xed"; chmod +x "$malicious_dir/xed"
old_path=$PATH; PATH="$malicious_dir:$PATH"; root_editor=$(pick_editor_root 2>/dev/null) || root_editor=""; PATH=$old_path
check 'privileged editor uses only trusted system paths' "$([[ -z "$root_editor" || "$root_editor" == /usr/local/bin/* || "$root_editor" == /usr/bin/* || "$root_editor" == /bin/* ]] && echo 1 || echo 0)" 1
check 'privileged editor is not user-controlled xed' "$([[ "$root_editor" != "$malicious_dir/xed" ]] && echo 1 || echo 0)" 1
check 'privileged editor does not fall back to xdg-open' "$([[ "$root_editor" == */xdg-open ]] && echo unsafe || echo safe)" safe

# Missing pkexec must be diagnosed before launching a background editor.
pkexec_missing_err="$TMP/pkexec-missing.err"
old_pkexec_path=$(declare -f pkexec_path)
pkexec_path() { printf '%s\n' "$TMP/no-pkexec"; }
edit_file_root "$TMP/protected.desktop" 2>"$pkexec_missing_err"; edit_pk_rc=$?
eval "$old_pkexec_path"
check 'edit_file_root rejects missing pkexec' "$edit_pk_rc" 1
check 'edit_file_root reports missing pkexec' "$(grep -F -c 'pkexec' "$pkexec_missing_err")" 1

# A trusted symlink must not resolve into a user-writable directory.
trusted_link_dir="$TMP/trusted-link"; mkdir -p "$trusted_link_dir"; chmod 755 "$trusted_link_dir"
resolved_writable_dir="$TMP/resolved-writable"; mkdir -p "$resolved_writable_dir"; chmod 777 "$resolved_writable_dir"
resolved_writable_file="$resolved_writable_dir/editor"
printf '#!/bin/sh\nexit 0\n' > "$resolved_writable_file"; chmod 755 "$resolved_writable_file"
if [[ "$EUID" -eq 0 ]]; then chown 0:0 "$trusted_link_dir" "$resolved_writable_dir" "$resolved_writable_file"; chmod 777 "$resolved_writable_dir"; fi
ln -s "$resolved_writable_file" "$trusted_link_dir/editor"
check 'trusted system file rejects resolved paths under writable parents' "$(is_trusted_system_file "$trusted_link_dir/editor" >/dev/null 2>&1; echo $?)" 1

# shellcheck disable=SC2016  # the grep pattern is literal source text
check 'pick_editor_root delegates trust validation' "$(sed -n '/^pick_editor_root()/,/^}$/p' "$SCRIPT" | grep -F -c 'is_trusted_system_file "$path"')" 1
# The trust check alone would also reject a user-controlled editor, so only the source shows that PATH is never consulted.
check 'pick_editor_root never resolves editors through PATH' "$(sed -n '/^pick_editor_root()/,/^}$/p' "$SCRIPT" | grep -F -c 'command -v')" 0
untrusted_dir="$TMP/untrusted-system"
mkdir -p "$untrusted_dir"
untrusted_file="$untrusted_dir/entry.desktop"
printf '[Desktop Entry]\nName=Untrusted\nExec=/usr/bin/true\n' > "$untrusted_file"
if [[ "$EUID" -eq 0 ]]; then
    chown 65534:65534 "$untrusted_dir" "$untrusted_file"
fi
chmod 600 "$untrusted_file"
check 'system source trust rejects non-root-owned paths' "$(is_trusted_system_file "$untrusted_file" >/dev/null 2>&1; echo $?)" 1
untrusted_link="$untrusted_dir/link.desktop"
ln -s /usr/bin/true "$untrusted_link"
check 'system source trust rejects user-path symlinks' "$(is_trusted_system_file "$untrusted_link" >/dev/null 2>&1; echo $?)" 1
check 'system source trust accepts root-owned system files' "$(is_trusted_system_file /usr/bin/true >/dev/null 2>&1; echo $?)" 0
cat > "$BIN/mv" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${MV_LOG:?}"
if [[ "${ATOMIC_RACE:-0}" == 1 ]]; then
    target="${@: -1}"
    rm -f -- "$target"
    mkdir -p -- "$target"
fi
exec /usr/bin/mv "$@"
SH
chmod +x "$BIN/mv"; hash -r; : > "$TMP/mv.log"; export MV_LOG="$TMP/mv.log"
printf 'old\n' > "$TMP/atomic-target"; printf 'new\n' > "$TMP/atomic-source"
export ATOMIC_RACE=1; atomic_install "$TMP/atomic-source" "$TMP/atomic-target" >/dev/null 2>&1; atomic_rc=$?; export ATOMIC_RACE=0
check 'atomic install aborts when target becomes directory during commit' "$atomic_rc" 1
check 'atomic install does not move source into raced directory' "$(test ! -e "$TMP/atomic-target/atomic-source" && echo 1 || echo 0)" 1
check 'atomic install invokes mv with directory-target protection' "$(grep -c -- '-fT' "$MV_LOG" 2>/dev/null || true)" 1
rm -f "$BIN/mv" "$MV_LOG"; hash -r

# Atomic writes must preserve existing permissions and never follow a target symlink.
cat > "$BIN/mv" <<'SH'
#!/bin/bash
exec /usr/bin/mv "$@"
SH
chmod +x "$BIN/mv"; hash -r
printf 'old\n' > "$TMP/atomic-mode.desktop"; chmod 640 "$TMP/atomic-mode.desktop"
atomic_write "$TMP/atomic-mode.desktop" $'new\n'; rc=$?
check 'atomic write updates file content' "$(cat "$TMP/atomic-mode.desktop")" 'new'
# shellcheck disable=SC2016  # the grep pattern is literal source text
check 'persistent override deletion uses atomic_remove' "$(sed -n '/^system_autostart_apply()/,/^}$/p' "$SCRIPT" | grep -F -c 'atomic_remove "$override"')" 1
check 'atomic write preserves existing mode' "$(stat -c '%a' "$TMP/atomic-mode.desktop")" 640
printf 'sentinel\n' > "$TMP/sentinel"; ln -s "$TMP/sentinel" "$TMP/atomic-link.desktop"
atomic_write "$TMP/atomic-link.desktop" $'changed\n'; rc=$?
check 'atomic write rejects symlink target in the regression scenario' "$rc" 1
check 'atomic write does not follow symlink target' "$(cat "$TMP/sentinel")" 'sentinel'

# Hostile filenames remain data: spaces, quotes, a leading dash and a newline.
mkdir -p "$TMP/user files"
printf -v WEIRD_DESKTOP '%s/--strange \"quoted\"\nentry.desktop' "$TMP/user files"
cat > "$WEIRD_DESKTOP" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Strange
Exec=/usr/bin/example
Hidden=false
X-GNOME-Autostart-enabled=true
EOF2
ARR_KIND=(user_autostart); ARR_RAW=("$WEIRD_DESKTOP"); ARR_STATUS=(TRUE); ARR_MODE=('')
set_item_state 0 FALSE
set_item_state 0 TRUE
check 'hostile desktop filename survives state changes' "$(desktop_key "$WEIRD_DESKTOP" Hidden)$(desktop_key "$WEIRD_DESKTOP" X-GNOME-Autostart-enabled)" 'falsetrue'
BAD_DESKTOP="$TMP/malformed.desktop"; printf '%s\n' 'Exec=/usr/bin/bad' > "$BAD_DESKTOP"
ARR_KIND=(user_autostart); ARR_RAW=("$BAD_DESKTOP"); ARR_STATUS=(TRUE); ARR_MODE=()
set_item_state 0 FALSE >/dev/null 2>&1; rc=$?
check 'malformed desktop entry is rejected without modification' "$rc/$(cat "$BAD_DESKTOP")" $'1/Exec=/usr/bin/bad'
cat > "$TMP/bad-exec-code.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Invalid field code
Exec=/usr/bin/example %x
EOF2
check 'desktop validator rejects unknown Exec field codes' "$(desktop_validate "$TMP/bad-exec-code.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/good-exec-percent.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Literal percent
Exec=/usr/bin/example 100%%
EOF2
check 'desktop validator accepts escaped literal percent in Exec' "$(desktop_validate "$TMP/good-exec-percent.desktop" >/dev/null 2>&1; echo $?)" 0
cat > "$TMP/bad-exec-trailing-backslash.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Trailing backslash
Exec=/usr/bin/example \
EOF2
check 'desktop validator rejects a trailing Exec backslash' "$(desktop_validate "$TMP/bad-exec-trailing-backslash.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/bad-exec-quoted-code.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Quoted field code
Exec=/usr/bin/example "%f"
EOF2
check 'desktop validator rejects Exec field codes inside quoted arguments' "$(desktop_validate "$TMP/bad-exec-quoted-code.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/bad-exec-multiple-files.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Multiple file codes
Exec=/usr/bin/example %f %u
EOF2
check 'desktop validator rejects multiple file Exec field codes' "$(desktop_validate "$TMP/bad-exec-multiple-files.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/bad-exec-embedded-list.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Embedded file list code
Exec=/usr/bin/example --file=%F
EOF2
check 'desktop validator rejects non-standalone list Exec field codes' "$(desktop_validate "$TMP/bad-exec-embedded-list.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/good-exec-embedded-single-file.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Embedded single file code
Exec=/usr/bin/example --file=%f.txt
EOF2
check 'desktop validator accepts embedded single-file Exec field codes' "$(desktop_validate "$TMP/good-exec-embedded-single-file.desktop" >/dev/null 2>&1; echo $?)" 0
cat > "$TMP/good-exec-embedded-single-url.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Embedded single URL code
Exec=/usr/bin/example url=%u-suffix
EOF2
check 'desktop validator accepts embedded single-URL Exec field codes' "$(desktop_validate "$TMP/good-exec-embedded-single-url.desktop" >/dev/null 2>&1; echo $?)" 0
cat > "$TMP/bad-exec-embedded-icon.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Embedded icon code
Exec=/usr/bin/example --icon=%i
EOF2
check 'desktop validator rejects non-standalone icon Exec field code' "$(desktop_validate "$TMP/bad-exec-embedded-icon.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/empty-type.desktop" <<'EOF2'
[Desktop Entry]
Type=
Name=Empty Type
Exec=/usr/bin/example
EOF2
check 'desktop validator rejects an empty required Type value' "$(desktop_validate "$TMP/empty-type.desktop" >/dev/null 2>&1; echo $?)" 1
for invalid_type in Garbage Link Directory; do
cat > "$TMP/invalid-type-$invalid_type.desktop" <<EOF2
[Desktop Entry]
Type=$invalid_type
Name=Invalid type
Exec=/usr/bin/example
EOF2
check "desktop validator rejects Type=$invalid_type" "$(desktop_validate "$TMP/invalid-type-$invalid_type.desktop" >/dev/null 2>&1; echo $?)" 1
done
for invalid_bool in 'Hidden=maybe' 'X-GNOME-Autostart-enabled=yes' 'DBusActivatable=nope'; do
key=${invalid_bool%%=*}
cat > "$TMP/invalid-bool-$key.desktop" <<EOF2
[Desktop Entry]
Type=Application
Name=Invalid boolean
Exec=/usr/bin/example
$invalid_bool
EOF2
check "desktop validator rejects $invalid_bool" "$(desktop_validate "$TMP/invalid-bool-$key.desktop" >/dev/null 2>&1; echo $?)" 1
done
cat > "$TMP/empty-name.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=
Exec=/usr/bin/example
EOF2
check 'desktop validator rejects an empty required Name value' "$(desktop_validate "$TMP/empty-name.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/missing-type.desktop" <<'EOF2'
[Desktop Entry]
Name=Missing Type
Exec=/usr/bin/example
EOF2
check 'desktop validator rejects a missing required Type key' "$(desktop_validate "$TMP/missing-type.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/missing-name.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Exec=/usr/bin/example
EOF2
check 'desktop validator rejects a missing required Name key' "$(desktop_validate "$TMP/missing-name.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/missing-exec.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Missing Exec
EOF2
check 'desktop validator rejects an Application without Exec' "$(desktop_validate "$TMP/missing-exec.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/dbus-no-exec.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=D-Bus App
DBusActivatable=true
EOF2
check 'desktop validator allows missing Exec for DBusActivatable=true' "$(desktop_validate "$TMP/dbus-no-exec.desktop" >/dev/null 2>&1; echo $?)" 0
cat > "$TMP/empty-exec.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Empty Exec
Exec=
EOF2
check 'desktop validator rejects an empty Exec value' "$(desktop_validate "$TMP/empty-exec.desktop" >/dev/null 2>&1; echo $?)" 1
check 'desktop validator rejects an empty quoted Exec command' "$(cat > "$TMP/empty-quoted-exec.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Empty quoted command
Exec=""
EOF2
desktop_validate "$TMP/empty-quoted-exec.desktop" >/dev/null 2>&1; echo $?)" 1
check 'desktop validator rejects a whitespace-only quoted Exec command' "$(cat > "$TMP/empty-whitespace-exec.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Whitespace quoted command
Exec="   "
EOF2
desktop_validate "$TMP/empty-whitespace-exec.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/desktop-both-showin-valid.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Both ShowIn
OnlyShowIn=Cinnamon;GNOME;
NotShowIn=KDE;XFCE;
Exec=/usr/bin/example
EOF2
check 'desktop validator allows distinct OnlyShowIn and NotShowIn entries' "$(desktop_validate "$TMP/desktop-both-showin-valid.desktop" >/dev/null 2>&1; echo $?)" 0
cat > "$TMP/desktop-both-showin-overlap.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Overlapping ShowIn
OnlyShowIn=Cinnamon;GNOME;
NotShowIn=KDE;GNOME;
Exec=/usr/bin/example
EOF2
check 'desktop validator rejects the same desktop in OnlyShowIn and NotShowIn' "$(desktop_validate "$TMP/desktop-both-showin-overlap.desktop" >/dev/null 2>&1; echo $?)" 1

# Critical classification is based on internal kind/name, not the translated label.
ARR_KIND=(user_autostart user_autostart)
ARR_RAW=(/tmp/polkit-gnome-authentication-agent-1.desktop /tmp/demo.desktop)
ARR_NAME=('PolicyKit Authentication Agent' 'Demo Application')
check 'PolicyKit autostart is critical' "$(item_is_critical 0; echo $?)" 0
check 'ordinary autostart is not critical' "$(item_is_critical 1; echo $?)" 1

check 'criticality ignores a misleading non-critical filename' "$(is_critical_autostart 'ordinary.desktop' 'PolicyKit Authentication Agent'; echo $?)" 0
check 'criticality survives a translated display name' "$(is_critical_autostart 'polkit-gnome-authentication-agent-1.desktop' 'Aplicación normal'; echo $?)" 0
check 'criticality decodes escaped display names' "$(is_critical_autostart 'ordinary.desktop' $'PolicyKit\\ Authentication\\ Agent'; echo $?)" 0
cat > "$TMP/action-name-not-critical.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Ordinary Backup
Exec=/usr/bin/true

[Desktop Action Authenticate]
Name=PolicyKit Authentication Agent
Exec=/usr/bin/true
EOF2
check 'criticality ignores PolicyKit names outside the main group' "$(is_critical_autostart 'ordinary.desktop' 'Ordinary Backup' "$TMP/action-name-not-critical.desktop"; echo $?)" 1
cat > "$TMP/indented-critical-name.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
 Name=PolicyKit Authentication Agent
Exec=/usr/bin/true
EOF2
check 'criticality accepts indented main-group Name keys' "$(is_critical_autostart 'ordinary.desktop' 'Ordinary' "$TMP/indented-critical-name.desktop"; echo $?)" 0
cat > "$TMP/spanish-policy-agent.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Background Component
Name[en]=Background Component
Name[es]=Agente de autenticación de PolicyKit
Exec=/usr/bin/true
EOF2
ARR_KIND=(user_autostart); ARR_RAW=("$TMP/spanish-policy-agent.desktop"); ARR_NAME=('Background Component')
FIXTURE_CRIT_SYS="$TMP/system-localized-critical.sh"
cp "$SCRIPT" "$FIXTURE_CRIT_SYS"
mkdir -p "$TMP/etc/xdg/autostart"
cat > "$TMP/etc/xdg/autostart/localized.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=Background Component
Name[en]=Background Component
Name[es]=Agente de autenticación de PolicyKit
Exec=/usr/bin/true
EOF2
# shellcheck disable=SC1090
HOME="$HOME_FAKE" source "$FIXTURE_CRIT_SYS"
ARR_KIND=(system_autostart); ARR_RAW=("$TMP/etc/xdg/autostart/localized.desktop"); ARR_NAME=('Background Component'); ARR_STATUS=(TRUE); LANG_UI=en

ZEN_RESULT=0
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
SYSTEMCTL_BIN="$BIN/systemctl"
pkexec_path() { printf '%s\n' "$BIN/pkexec"; }
PRIV_TIMEOUT_BIN="$BIN/timeout"
SYSTEMCTL_BIN="$BIN/systemctl"
PRIV_SYSTEMCTL_BIN="$BIN/systemctl"

# Systemd state mapping is exhaustive for supported states.
for pair in enabled enabled-runtime disabled static generated indirect masked masked-runtime; do
    systemd_unit_status "$pair" st mode; rc=$?
    check "systemd state accepted: $pair" "$rc" 0
done
check 'static systemd units use mask mode' "$(systemd_unit_status static st mode; printf '%s/%s' "$st" "$mode")" 'TRUE/mask'
check 'masked systemd units use unmask path on enable' "$(systemd_unit_status masked st mode; printf '%s/%s' "$st" "$mode")" 'FALSE/mask'
check 'normal enabled systemd units use enable mode' "$(systemd_unit_status enabled st mode; printf '%s/%s' "$st" "$mode")" 'TRUE/enable'
for pair in alias transient bad unknown; do
    systemd_unit_status "$pair" st mode >/dev/null 2>&1; rc=$?
    check "systemd state rejected: $pair" "$rc" 1
done

# Batched systemd system changes: one authentication boundary, correct verbs, per-unit result.
: > "$SYSTEM_LOG"
cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${FAIL_UNIT:-}" == "${@: -1}" ]]; then
    printf 'simulated failure for %s\n' "${@: -1}" >&2; exit 7
fi
exit 0
SH
chmod +x "$BIN/systemctl"
ARR_KIND=(systemd_system systemd_system systemd_system)
ARR_RAW=(alpha.service beta.service gamma.service)
ARR_MODE=(enable mask mask)
ARR_STATUS=(TRUE TRUE TRUE)
ARR_NAME=(Alpha Beta Gamma)
declare -A results=() errors=()
SELECTED_IDS=([0]=1 [2]=1)
export FAIL_UNIT=beta.service
sys_batch=(0 1 2); apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1; rc=$?
check 'systemd batch command itself completes after partial unit failure' "$rc" 0
check 'systemd batch marks failed unit' "${results[beta.service]:-MISSING}" 'FAIL'
check 'systemd batch marks successful unit' "${results[alpha.service]:-MISSING}/${results[gamma.service]:-MISSING}" 'OK/OK'
check 'systemd batch makes one pkexec call' "$(grep -c '^pkexec ' "$SYSTEM_LOG")" 1
check 'systemd batch makes one timeout call' "$(grep -c '^timeout ' "$SYSTEM_LOG")" 1
check 'systemd batch applies enable/mask/unmask semantics' "$(grep '^systemctl ' "$SYSTEM_LOG" | tail -n3 | sed 's/^systemctl //' | tr '\n' '|')" 'enable -- alpha.service|mask -- beta.service|unmask -- gamma.service|'
check 'systemd batch retains per-unit failure' "${errors[beta.service]:-MISSING}" 'simulated failure for beta.service'

cat > "$BIN/tr" <<'SH'
#!/bin/bash
printf 'used\n' >> "${PRIV_FILTER_PATH_LOG:?}"
exec /usr/bin/tr "$@"
SH
cat > "$BIN/sed" <<'SH'
#!/bin/bash
printf 'used\n' >> "${PRIV_FILTER_PATH_LOG:?}"
exec /usr/bin/sed "$@"
SH
chmod +x "$BIN/tr" "$BIN/sed"
PRIV_FILTER_PATH_LOG="$TMP/priv-filter-path.log"; export PRIV_FILTER_PATH_LOG
: > "$PRIV_FILTER_PATH_LOG"; : > "$SYSTEM_LOG"
SELECTED_IDS=([0]=1); ARR_KIND=(systemd_system); ARR_RAW=(path-safe.service); ARR_MODE=(enable); ARR_STATUS=(TRUE)
sys_batch=(0); declare -A results=() errors=()
apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1 || true
check 'privileged batch ignores caller PATH for output filters' "$(test -s "$PRIV_FILTER_PATH_LOG" && echo used || echo unused)" unused
rm -f "$BIN/tr" "$BIN/sed"; hash -r

PATH_TEST_BIN="$TMP/path-test-bin"; mkdir -p "$PATH_TEST_BIN"
cat > "$PATH_TEST_BIN/systemctl" <<'SH'
#!/bin/bash
printf 'used\n' >> "${PRIV_SYSTEMCTL_PATH_LOG:?}"
exit 0
SH
chmod +x "$PATH_TEST_BIN/systemctl"
PRIV_SYSTEMCTL_PATH_LOG="$TMP/priv-systemctl-path.log"; export PRIV_SYSTEMCTL_PATH_LOG
old_path=$PATH
PRIV_SYSTEMCTL_BIN=""; PATH="$PATH_TEST_BIN:$BIN:$PATH"
check 'privileged systemctl path ignores caller PATH' "$(privileged_systemctl_path)" '/usr/bin/systemctl'
PATH=$old_path
SYSTEMCTL_BIN="$BIN/systemctl"
PRIV_SYSTEMCTL_BIN="$BIN/systemctl"
hash -r

# The trusted systemctl resolver must also ignore caller PATH.
SYSTEMCTL_PATH_LOG="$TMP/systemctl-path.log"; export SYSTEMCTL_PATH_LOG
: > "$SYSTEMCTL_PATH_LOG"
old_path=$PATH
PATH="$PATH_TEST_BIN:$BIN:$PATH"
SYSTEMCTL_BIN=""
trusted_systemctl="$(trusted_systemctl_path)"
check 'normal systemctl path ignores caller PATH' "$trusted_systemctl" '/usr/bin/systemctl'
check 'normal systemctl path does not execute caller PATH helper' "$(rc_of test ! -s "$SYSTEMCTL_PATH_LOG")" 0
PATH=$old_path
SYSTEMCTL_BIN="$BIN/systemctl"
unset SELECTED_IDS FAIL_UNIT results errors

# Runtime systemd modes must map to the corresponding --runtime verbs.
: > "$SYSTEM_LOG"
ARR_KIND=(systemd_system systemd_system); ARR_RAW=(runtime.service runtime-mask.service); ARR_MODE=(enable-runtime mask-runtime); ARR_STATUS=(TRUE FALSE); ARR_NAME=(Runtime RuntimeMask)
declare -A results=() errors=(); sys_batch=(0 1); SELECTED_IDS=([0]=1 [1]=1)
apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1; rc=$?
check 'systemd runtime enable/unmask batch succeeds' "$rc" 0
check 'systemd runtime enable and unmask use --runtime' "$(grep '^systemctl ' "$SYSTEM_LOG" | sed 's/^systemctl //' | tr '\n' '|')" 'enable --runtime -- runtime.service|unmask --runtime -- runtime-mask.service|'
: > "$SYSTEM_LOG"; SELECTED_IDS=()
apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1; rc=$?
check 'systemd runtime disable/mask batch succeeds' "$rc" 0
check 'systemd runtime disable and mask use --runtime' "$(grep '^systemctl ' "$SYSTEM_LOG" | sed 's/^systemctl //' | tr '\n' '|')" 'disable --runtime -- runtime.service|mask --runtime -- runtime-mask.service|'

# The per-user systemd path must preserve runtime state too.
: > "$SYSTEM_LOG"
ARR_KIND=(systemd_user); ARR_RAW=(runtime-user.service); ARR_MODE=(enable-runtime); ARR_STATUS=(FALSE); SELECTED_IDS=()
set_item_state 0 TRUE; rc=$?
check 'user systemd runtime enable succeeds' "$rc" 0
check 'user systemd runtime enable uses --runtime' "$(grep '^systemctl ' "$SYSTEM_LOG" | tail -n1 | sed 's/^systemctl //')" '--user enable --runtime -- runtime-user.service'
: > "$SYSTEM_LOG"; ARR_MODE=(mask-runtime); ARR_STATUS=(TRUE)
set_item_state 0 FALSE; rc=$?
check 'user systemd runtime mask succeeds' "$rc" 0
check 'user systemd runtime mask uses --runtime' "$(grep '^systemctl ' "$SYSTEM_LOG" | tail -n1 | sed 's/^systemctl //')" '--user mask --runtime -- runtime-user.service'

# Unit names are data: shell metacharacters must never become executable syntax.
sentinel="$TMP/unit-injection"; rm -f "$sentinel"
# shellcheck disable=SC2016  # the unit name must contain a literal $(...)
evil_unit='evil$(touch "'"$sentinel"'").service'
: > "$SYSTEM_LOG"; ARR_RAW=("$evil_unit"); ARR_MODE=(enable); ARR_STATUS=(FALSE); SELECTED_IDS=([0]=1); sys_batch=(0); declare -A results=() errors=()
apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1; rc=$?
check 'systemd unit metacharacters do not execute shell code' "$(rc_of test ! -e "$sentinel")" 0
# shellcheck disable=SC2016  # the grep pattern is a literal $(...)
check 'systemd unit metacharacters remain a single argument' "$(grep -F -c -- 'evil$(touch' "$SYSTEM_LOG" || true)" 1
unset SELECTED_IDS results errors

# No pkexec is a distinct failure mode with a localized explanation.
rm -f "$BIN/pkexec"
ARR_KIND=(systemd_system); ARR_RAW=(alpha.service); ARR_MODE=(enable); SELECTED_IDS=()
sys_batch=(0); LANG_UI=es apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1 || true
check 'missing pkexec has Spanish diagnosis' "$(grep -c 'No se encontró.*pkexec' <<< "$PKEXEC_BATCH_ERROR")" 1
cat > "$BIN/pkexec" <<'SH'
#!/bin/bash
printf 'pkexec %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${PKEXEC_RC:-}" =~ ^[0-9]+$ ]]; then exit "$PKEXEC_RC"; fi
exec "${@: -2}"
SH
chmod +x "$BIN/pkexec"

# Privileged batch failures must retain localized diagnostics for timeout, cancellation, auth failure, and unexpected errors.
ARR_KIND=(systemd_system); ARR_RAW=(alpha.service); ARR_MODE=(enable); ARR_STATUS=(TRUE); ARR_NAME=(Alpha); sys_batch=(0)
declare -A results=() errors=()
for spec in '124|en|Authentication timed out' '126|en|administrator password dialog was cancelled' '127|en|Authentication failed or the required permission' '42|en|unexpected error (code 42)'; do
    IFS='|' read -r test_rc lang expected <<< "$spec"
    : > "$SYSTEM_LOG"
    PKEXEC_BATCH_ERROR=""; PGREP_RC=0; FORCE_TIMEOUT_RC=
    if [[ "$test_rc" == 124 ]]; then FORCE_TIMEOUT_RC=124; PKEXEC_RC=0; else FORCE_TIMEOUT_RC=; PKEXEC_RC="$test_rc"; fi
    export PKEXEC_RC FORCE_TIMEOUT_RC PGREP_RC
    LANG_UI="$lang" apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1 || true
    check "pkexec rc $test_rc has English diagnostic" "$(grep -F -c -- "$expected" <<< "$PKEXEC_BATCH_ERROR")" 1
done
: > "$SYSTEM_LOG"; PKEXEC_BATCH_ERROR=""; PGREP_RC=1; FORCE_TIMEOUT_RC=; PKEXEC_RC=127
export PKEXEC_RC FORCE_TIMEOUT_RC PGREP_RC
LANG_UI=es apply_systemd_system_batch sys_batch results errors >/dev/null 2>&1 || true
check 'pkexec auth failure without agent includes Spanish agent diagnosis' "$(grep -F -c 'No se detectó ningún agente gráfico de autenticación de PolicyKit' <<< "$PKEXEC_BATCH_ERROR")" 1
unset PKEXEC_RC FORCE_TIMEOUT_RC PGREP_RC results errors

# Zenity wrapper: success, parser fallback, and argument sanitization.
: > "$ZEN_LOG"; export ZEN_RESULT=output ZEN_OUTPUT='ok' NEED_ASCII_ZENITY=0
LANG_UI=en; out=$(zen --info --title='Té' --text='á & < >' --column='Nombre' -- 'fila ñ &'); rc=$?
check 'zen wrapper preserves UTF-8 user text' "$out/$rc/$(head -n1 "$ZEN_LOG")" "ok/0/--ok-label=OK --info --title=Té --text=á & < > --column=Nombre -- fila ñ &"

# Buttons without an explicit label follow the interface language, not the system locale.
zen_argv() {   # zen_argv <ui> <ascii 0|1> <zen args...>: first argv line Zenity received
    local ui="$1" ascii="$2"; shift 2
    : > "$ZEN_LOG"
    LANG_UI="$ui" NEED_ASCII_ZENITY="$ascii" zen "$@" >/dev/null
    head -n1 "$ZEN_LOG"
}
check 'zen labels the default buttons in Spanish' "$(zen_argv es 0 --list --column=C -- row)" '--ok-label=Aceptar --cancel-label=Cancelar --list --column=C -- row'
check 'zen labels the default buttons in English' "$(zen_argv en 0 --list --column=C -- row)" '--ok-label=OK --cancel-label=Cancel --list --column=C -- row'
check 'zen keeps explicit labels and fills only the missing one' "$(zen_argv es 0 --list --cancel-label=Salir -- row)/$(zen_argv es 0 --entry --ok-label=Ir --cancel-label=Salir)" '--ok-label=Aceptar --list --cancel-label=Salir -- row/--entry --ok-label=Ir --cancel-label=Salir'
check 'zen gives message dialogs only an OK label' "$(zen_argv es 0 --warning --text=x)" '--ok-label=Aceptar --warning --text=x'
check 'zen labels an unlabeled question Yes/No in the interface language' "$(zen_argv es 0 --question --text=x)/$(zen_argv en 0 --question --text=x)" '--ok-label=Sí --cancel-label=No --question --text=x/--ok-label=Yes --cancel-label=No --question --text=x'
check 'zen ASCII fallback also sanitizes the default labels' "$(zen_argv es 1 --question --text=x)" '--ok-label=Si --cancel-label=No --question --text=x'
check 'zen ignores label-looking row data after --' "$(zen_argv en 0 --list -- --ok-label=x --cancel-label=y)" '--ok-label=OK --cancel-label=Cancel --list -- --ok-label=x --cancel-label=y'
cat > "$BIN/zenity" <<'SH'
#!/bin/bash
c="${ZEN_COUNT_FILE:?}"; n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); printf '%s' "$n" > "$c"
if (( n == 1 )); then exit 255; fi
printf '%s' fallback
exit 0
SH
chmod +x "$BIN/zenity"
: > "$TMP/zen-count"; export ZEN_COUNT_FILE="$TMP/zen-count" NEED_ASCII_ZENITY=0
out=$(zen --question --text='hello'); rc=$?
check 'zen wrapper retries parser failure and succeeds' "$out/$rc/$(cat "$ZEN_COUNT_FILE")" 'fallback/0/2'

# Opening items must dispatch by mechanism and target the real source.
open_log="$TMP/open.log"; : > "$open_log"
edit_file() { printf 'edit:%s\n' "$1" >> "$open_log"; }
smart_edit() { printf 'smart:%s\n' "$1" >> "$open_log"; }
mkdir -p "$HOME_FAKE/.config/autostart"
cat > "$HOME_FAKE/.config/autostart/open-demo.desktop" <<'EOF2'
[Desktop Entry]
Name=Open Demo
Exec=/usr/bin/open-demo
EOF2
export UNIT_PATH="$TMP/systemd-source.service"
printf '%s\n' 'unit' > "$UNIT_PATH"
cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${SYSTEM_LOG:?}"
if [[ "${1:-}" == '--user' && "${2:-}" == 'show' ]] || [[ "${1:-}" == 'show' ]]; then
    printf '%s\n' "${UNIT_PATH:?}"; exit 0
fi
exit 0
SH
chmod +x "$BIN/systemctl"
ARR_KIND=(user_autostart system_autostart systemd_user systemd_system cron_user)
ARR_RAW=("$HOME_FAKE/.config/autostart/open-demo.desktop" "$ETC/open-demo.desktop" user.service system.service 1)
ARR_NAME=(User System UserUnit SystemUnit Cron)
open_item 0 >/dev/null 2>&1; open_item 1 >/dev/null 2>&1; open_item 2 >/dev/null 2>&1; open_item 3 >/dev/null 2>&1
check 'open item dispatches user autostart and system override' "$(tr '\n' '|' < "$open_log")" "edit:$HOME_FAKE/.config/autostart/open-demo.desktop|edit:$HOME_FAKE/.config/autostart/open-demo.desktop|smart:$TMP/systemd-source.service|smart:$TMP/systemd-source.service|"
# A unit name beginning with '-' must reach systemctl after an explicit end-of-options marker.
OPEN_SYSTEMCTL_LOG="$TMP/open-systemctl.log"; export OPEN_SYSTEMCTL_LOG; : > "$OPEN_SYSTEMCTL_LOG"
cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
printf '<%s>\n' "$@" >> "${OPEN_SYSTEMCTL_LOG:?}"
printf '%s\n' "${UNIT_PATH:?}"
exit 0
SH
chmod +x "$BIN/systemctl"
SYSTEMCTL_BIN="$BIN/systemctl"
ARR_KIND=(systemd_user); ARR_RAW=(--help.service); ARR_NAME=(HostileUnit)
open_item 0 >/dev/null 2>&1
check 'open systemd unit passes -- before hostile unit name' "$(sed ':a;N;$!ba;s/\n/|/g' "$OPEN_SYSTEMCTL_LOG")" '<--user>|<show>|<-p>|<FragmentPath>|<--value>|<-->|<--help.service>'
ARR_KIND=(user_autostart system_autostart systemd_user systemd_system cron_user)
ARR_RAW=("$HOME_FAKE/.config/autostart/open-demo.desktop" "$ETC/open-demo.desktop" user.service system.service 1)
ARR_NAME=(User System UserUnit SystemUnit Cron)
open_log_before=$(wc -l < "$open_log")
open_item 4 >/dev/null 2>&1; check 'open cron item uses informational dialog path' "$?" 0
check 'open cron item does not invoke an editor' "$(wc -l < "$open_log")" "$open_log_before"

unset -f edit_file smart_edit

# UI apply path: a non-privileged desktop change must flow through the real checklist handler.
ui_calls="$TMP/ui-calls"; : > "$ui_calls"
zen() {
    local n; n=$(cat "$ui_calls" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$ui_calls"
    case "$n" in
        1) printf ''; return 0 ;;   # checklist: OK with the box cleared
        2) return 0 ;;              # result dialog
        *) return 1 ;;              # checklist: Cancel leaves the category
    esac
}
cat > "$TMP/ui-user.desktop" <<'EOF2'
[Desktop Entry]
Type=Application
Name=UI Test
Exec=/usr/bin/ui-test
Hidden=false
EOF2
LANG_UI=en; init_categories; ITEMS_DIRTY=0
ARR_TYPE=("👤 $(msg user_type)"); ARR_NAME=("UI Test"); ARR_STATUS=(TRUE); ARR_STATUS_LABEL=("$(msg enabled)")
ARR_SRC=("$TMP/ui-user.desktop"); ARR_KIND=(user_autostart); ARR_RAW=("$TMP/ui-user.desktop"); ARR_MODE=()
refresh_items() { :; }
show_category_checklist 1 >/dev/null 2>&1 || true
check 'UI checklist applies a selected user autostart change' "$(grep '^Hidden=' "$TMP/ui-user.desktop")" 'Hidden=true'
check 'UI checklist exits after user completes the action flow' "$(cat "$ui_calls")" 3

# UI critical confirmation: cancelling the warning must cancel the whole batch.
: > "$ui_calls"; : > "$SYSTEM_LOG"
zen() {
    local n; n=$(cat "$ui_calls" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$ui_calls"
    case "$n" in
        1) printf ''; return 0 ;;   # checklist: OK with the critical box cleared
        2) return 1 ;;              # critical confirmation: cancel
        *) return 1 ;;              # checklist: Cancel leaves the category
    esac
}
LANG_UI=en; ARR_TYPE=("⚙️ $(msg system_service)"); ARR_NAME=(NetworkManager.service); ARR_STATUS=(TRUE); ARR_STATUS_LABEL=("$(msg enabled)")
ARR_SRC=(NetworkManager.service); ARR_KIND=(systemd_system); ARR_RAW=(NetworkManager.service); ARR_MODE=(enable)
refresh_items() { :; }; ITEMS_DIRTY=0
show_category_checklist 5 >/dev/null 2>&1 || true
check 'UI critical confirmation cancellation preserves systemd state' "${ARR_STATUS[0]}" TRUE
check 'UI critical confirmation cancellation makes no privileged call' "$(grep -c '^pkexec ' "$SYSTEM_LOG" || true)" 0
check 'UI critical confirmation cancellation completes expected dialog flow' "$(cat "$ui_calls")" 3

# CI quality gate must pin and verify the ShellCheck release it executes.

# CLI must reject leftover positional/unknown arguments before checking Zenity.
cli_home="$TMP/cli-home"; mkdir -p "$cli_home"
cli_out=$(HOME="$cli_home" LANG=C LC_ALL=C AUTOSTART_MANAGER_TEST=1 bash "$SCRIPT" --unknown 2>&1); cli_rc=$?
check 'unknown CLI argument exits before GUI dependency check' "$cli_rc" 2
check 'unknown CLI argument reports a usage diagnostic' "$cli_out" 'Unrecognized argument: --unknown. Use --help to see usage.'

check 'root execution ignores caller PATH for startup tools' "$(flag="$TMP/path-hijack"; rm -f "$flag"; mkdir -p "$TMP/hijack"; cat > "$TMP/hijack/zenity" <<EOF2
#!/bin/bash
touch "$flag"
exit 0
EOF2
chmod +x "$TMP/hijack/zenity"; PATH="$TMP/hijack" /bin/bash "$SCRIPT" --help >/dev/null 2>&1; rc_of test ! -e "$flag")" 0
# The executable version and both READMEs must stay in sync.
app_version=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$SCRIPT")
version_output=$(AUTOSTART_MANAGER_TEST=1 bash "$SCRIPT" --version 2>/dev/null)
check 'version constant is present' "$( [[ -n "$app_version" ]] && echo 1 || echo 0 )" 1
check 'version command matches VERSION constant' "$version_output" "Autostart Manager $app_version"
check 'English README uses the script version' "$(grep -F -c "Autostart Manager $app_version" "$ROOT_DIR/README.md")" 1
check 'Spanish README uses the script version' "$(grep -F -c "Autostart Manager $app_version" "$ROOT_DIR/README.es.md")" 1

# Restore the production zen wrapper before the suite ends.
unset -f zen
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
pkexec_path() { printf '%s\n' "$BIN/pkexec"; }

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
