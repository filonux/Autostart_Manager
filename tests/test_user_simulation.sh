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
    local lang="$1" result_dir="$2"
    local bin="$TMP/bin-$lang" home="$TMP/home-$lang"
    local user_unit="$TMP/user-unit-$lang" system_state="$TMP/system-unit-$lang"
    local cron_file="$TMP/crontab-$lang" trace="$TMP/trace-$lang"
    local network_state="$TMP/network-unit-$lang"

    mkdir -p "$bin" "$home/.config/autostart" "$home/etc/xdg/autostart"

    cat > "$home/.config/autostart/demo.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Demo App
Name[en]=Demo Application
Name[es]=Aplicación Demo
Exec=/usr/bin/example --flag
Hidden=false
X-GNOME-Autostart-enabled=true
X-Custom=preserve
DESKTOP

    cat > "$home/etc/xdg/autostart/system.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=false
X-GNOME-Autostart-enabled=true
DESKTOP

    printf 'enabled\n' > "$user_unit"
    printf 'enabled\n' > "$system_state"
    printf 'enabled\n' > "$network_state"
    cat > "$cron_file" <<'CRON'
SHELL=/bin/bash
*/5 * * * * /usr/bin/example --foo && echo ok
CRON
    : > "$trace"

    cat > "$bin/systemctl" <<'SH2'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${TRACE:?}"
if [[ "${1:-}" == "--user" && "${2:-}" == "disable" ]]; then
    printf 'disabled\n' > "${USER_UNIT_STATE:?}"; exit 0
fi
if [[ "${1:-}" == "--user" && "${2:-}" == "enable" ]]; then
    printf 'enabled\n' > "${USER_UNIT_STATE:?}"; exit 0
fi
case "${1:-}" in
    enable|disable|mask|unmask)
        target="${@: -1}"
        case "$target" in
            NetworkManager.service) state_file="$NETWORK_STATE" ;;
            *) state_file="$SYSTEM_STATE" ;;
        esac
        case "${1:-}" in
            enable|unmask) printf 'enabled\n' > "$state_file" ;;
            disable|mask) printf 'disabled\n' > "$state_file" ;;
        esac
        exit 0
        ;;
esac
exit 0
SH2

    cat > "$bin/pkexec" <<'SH2'
#!/bin/bash
printf 'pkexec %s\n' "$*" >> "${TRACE:?}"
exec "$@"
SH2
    cat > "$bin/timeout" <<'SH2'
#!/bin/bash
printf 'timeout %s\n' "$*" >> "${TRACE:?}"
shift
exec "$@"
SH2
    cat > "$bin/crontab" <<'SH2'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "${TRACE:?}"
if [[ "${1:-}" == '-l' ]]; then cat "${CRON_FILE:?}"; exit 0; fi
if [[ -f "${1:-}" ]]; then cp "$1" "${CRON_FILE:?}"; exit 0; fi
exit 0
SH2
    for tool in pgrep zenity xdg-open; do
        cat > "$bin/$tool" <<'SH2'
#!/bin/bash
exit 0
SH2
    done
    chmod +x "$bin"/*

    export PATH="$bin:$PATH" HOME="$home" AUTOSTART_MANAGER_TEST=1
    export XDG_CURRENT_DESKTOP=X-Cinnamon TRACE="$trace"
    export USER_UNIT_STATE="$user_unit" SYSTEM_STATE="$system_state" NETWORK_STATE="$network_state" CRON_FILE="$cron_file"
    export AUTOSTART_MANAGER_LANG="$lang" LANG=C.UTF-8 LC_ALL=C.UTF-8

    # shellcheck source=../script/Autostart_Manager.sh
    source "$SCRIPT"
    pkexec_path() { printf '%s\n' "$bin/pkexec"; }
    PRIV_TIMEOUT_BIN="$bin/timeout"
    SYSTEMCTL_BIN="$bin/systemctl"
    PRIV_SYSTEMCTL_BIN="$bin/systemctl"
    init_categories

    ARR_KIND=(user_autostart systemd_user cron_user systemd_system systemd_system)
    ARR_RAW=(
        "$home/.config/autostart/demo.desktop"
        demo.service
        2
        demo.service
        NetworkManager.service
    )
    ARR_MODE=('' enable '' enable enable)
    ARR_STATUS=(TRUE TRUE TRUE TRUE TRUE)
    ARR_NAME=('Demo Application' 'Demo Session Service' 'Every 5 Minutes' 'Demo System Service' 'NetworkManager')
    ARR_SRC=(
        "$home/.config/autostart/demo.desktop"
        demo.service
        'crontab line 2'
        demo.service
        NetworkManager.service
    )

    # Cross-kind integration path: user desktop, user systemd, cron, and one
    # privileged systemd change all use the production mutation functions.
    set_item_state 0 FALSE || return 1
    set_item_state 1 FALSE || return 1
    set_item_state 2 FALSE || return 1

    SELECTED_IDS=()
    # shellcheck disable=SC2034  # passed by name (nameref) to apply_systemd_system_batch
    IDX=(3 4)
    declare -A SYS_RESULT SYS_ERROR
    SYS_RESULT=()
    # shellcheck disable=SC2034  # passed by name (nameref) to apply_systemd_system_batch
    SYS_ERROR=()
    apply_systemd_system_batch IDX SYS_RESULT SYS_ERROR || true
    [[ "${SYS_RESULT[demo.service]:-FAIL}" == OK ]] || return 1
    [[ "${SYS_RESULT[NetworkManager.service]:-FAIL}" == OK ]] || return 1

    # The critical decision must be based on the internal identity, never the
    # localized label presented to the user.
    ARR_KIND=(user_autostart systemd_system)
    ARR_RAW=(polkit-gnome-authentication-agent-1.desktop NetworkManager.service)
    ARR_NAME=('Nombre cualquiera' 'Servicio traducido')
    LANG_UI="$lang"
    item_is_critical 0 || return 1
    item_is_critical 1 || return 1

    # Reinitialize UI labels after changing language; machine state must stay
    # untouched by the presentation-layer switch.
    snapshot_before=$(printf '%s
' "$lang" "$(sha256sum "$cron_file" | cut -d' ' -f1)" "$(cat "$user_unit")" "$(cat "$system_state")" "$(cat "$network_state")")
    if [[ "$lang" == es ]]; then LANG_UI=en; else LANG_UI=es; fi
    init_categories
    snapshot_after=$(printf '%s
' "$lang" "$(sha256sum "$cron_file" | cut -d' ' -f1)" "$(cat "$user_unit")" "$(cat "$system_state")" "$(cat "$network_state")")
    [[ "$snapshot_before" == "$snapshot_after" ]] || return 1

    mkdir -p "$result_dir"
    cp "$home/.config/autostart/demo.desktop" "$result_dir/desktop"
    cp "$cron_file" "$result_dir/crontab"
    cp "$user_unit" "$result_dir/user-unit"
    cp "$system_state" "$result_dir/system-unit"
    cp "$network_state" "$result_dir/network-unit"
    cp "$trace" "$result_dir/trace"
}

mkdir -p "$TMP/result-en" "$TMP/result-es"
run_case en "$TMP/result-en"
rc_en=$?
run_case es "$TMP/result-es"
rc_es=$?
check 'English integration scenario completes successfully' "$rc_en" 0
check 'Spanish integration scenario completes successfully' "$rc_es" 0

for f in desktop crontab user-unit system-unit network-unit; do
    check "ES/EN persisted identical $f" "$(cmp -s "$TMP/result-es/$f" "$TMP/result-en/$f"; echo $?)" 0
done

normalized_es=$(sed -E 's#/tmp/[^ ]+#TMP#g' "$TMP/result-es/trace")
normalized_en=$(sed -E 's#/tmp/[^ ]+#TMP#g' "$TMP/result-en/trace")
check 'ES/EN integration uses identical privileged command trace' "$([[ "$normalized_es" == "$normalized_en" ]] && echo 0 || echo 1)" 0
check 'user autostart was actually disabled' "$(grep '^Hidden=' "$TMP/result-en/desktop" | cut -d= -f2)" true
check 'cron entry was actually disabled' "$(sed -n '2p' "$TMP/result-en/crontab" | cut -c1-11)" '#DISABLED# '
check 'user systemd unit was actually disabled' "$(cat "$TMP/result-en/user-unit")" disabled
check 'system systemd unit was actually disabled' "$(cat "$TMP/result-en/system-unit")" disabled
check 'NetworkManager systemd unit was actually disabled' "$(cat "$TMP/result-en/network-unit")" disabled
check 'system changes share one pkexec boundary' "$(grep -c '^pkexec ' "$TMP/result-en/trace")" 1

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
