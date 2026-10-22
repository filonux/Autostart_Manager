#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
BIN="$TMP/bin"
HOME_FAKE="$TMP/home"
mkdir -p "$BIN" "$HOME_FAKE/.config/autostart"
chmod 755 "$TMP"
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

cat > "$BIN/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${TRACE:?}"
case " ${1:-} ${2:-} ${3:-} " in
  ' --user list-unit-files ')
    cat "${USER_UNITS:?}" ;;
  ' list-unit-files ')
    cat "${SYSTEM_UNITS:?}" ;;
  ' --user show ')
    printf '%s\n' /dev/null ;;
esac
SH
cat > "$BIN/crontab" <<'SH'
#!/bin/bash
printf 'crontab %s\n' "$*" >> "${TRACE:?}"
if [[ "${1:-}" == '-l' ]]; then cat "${CRONTAB_FILE:?}"; exit 0; fi
if [[ -n "${1:-}" && -f "$1" ]]; then cp "$1" "${CRONTAB_FILE:?}"; fi
exit 0
SH
cat > "$BIN/pkexec" <<'SH'
#!/bin/bash
printf 'pkexec %s\n' "$*" >> "${TRACE:?}"
"$@"
SH
cat > "$BIN/timeout" <<'SH'
#!/bin/bash
printf 'timeout %s\n' "$*" >> "${TRACE:?}"
shift
"$@"
SH
cat > "$BIN/zenity" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$BIN/pgrep" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export HOME="$HOME_FAKE"
export XDG_CONFIG_HOME="$HOME_FAKE/.config" XDG_CONFIG_DIRS="$TMP/etc/xdg"
export XDG_CURRENT_DESKTOP=X-Cinnamon
export SYSTEM_UNITS="$TMP/system.units"
export USER_UNITS="$TMP/user.units"
export CRONTAB_FILE="$TMP/crontab"
export TRACE="$TMP/trace"
export AUTOSTART_MANAGER_TEST=1
: > "$SYSTEM_UNITS"; : > "$USER_UNITS"; : > "$CRONTAB_FILE"; : > "$TRACE"

# Source once; compare behavior with only LANG_UI changed.
# shellcheck source=../script/Autostart_Manager.sh
LANG=C.UTF-8 AUTOSTART_MANAGER_LANG=en source "$SCRIPT"
pkexec_path() { printf '%s\n' "$BIN/pkexec"; }
PRIV_TIMEOUT_BIN="$BIN/timeout"
SYSTEMCTL_BIN="$BIN/systemctl"
PRIV_SYSTEMCTL_BIN="$BIN/systemctl"

fixture_inventory() {
    local lang="$1" out="$2" f
    LANG_UI="$lang"; init_categories
    f="$HOME_FAKE/.config/autostart/fixture.desktop"
    cat > "$f" <<'DESK'
[Desktop Entry]
Type=Application
Name=Default Name
Name[en]=English Name
Name[es]=Nombre Español
Exec=/usr/bin/example --flag
Hidden=false
X-GNOME-Autostart-enabled=true
DESK
    cat > "$TMP/crontab-$lang" <<'CRON'
SHELL=/bin/bash
# comment
*/5 * * * * /usr/bin/example --foo && echo ok
#DISABLED# 0 1 * * * /usr/bin/disabled
CRON
    cp "$TMP/crontab-$lang" "$CRONTAB_FILE"
    cat > "$USER_UNITS" <<'UNITS'
example.service enabled
example-static.service static
UNITS
    cat > "$SYSTEM_UNITS" <<'UNITS'
NetworkManager.service enabled
thirdparty.service disabled
UNITS
    collect_items
    {
        printf 'KIND\n'; printf '%s\n' "${ARR_KIND[@]}"
        printf 'RAW\n'; printf '%s\n' "${ARR_RAW[@]}"
        printf 'STATUS\n'; printf '%s\n' "${ARR_STATUS[@]}"
        printf 'MODE\n'; printf '%s\n' "${ARR_MODE[@]}"
        printf 'CATEGORY\n'
        local i; for i in "${!ARR_NAME[@]}"; do printf '%s=%s\n' "$i" "$(item_category "$i")"; done
    } > "$out"
}

fixture_inventory en "$TMP/inventory-en"
fixture_inventory es "$TMP/inventory-es"
check 'inventory machine state is language-invariant' "$(cmp -s "$TMP/inventory-en" "$TMP/inventory-es"; echo $?)" 0

# Display strings may differ, but internal kinds and raw identifiers must not.
LANG_UI=en; init_categories; collect_items
internal_en=$(for i in "${!ARR_NAME[@]}"; do printf '%s|%s|%s\n' "${ARR_KIND[$i]}" "${ARR_RAW[$i]}" "${ARR_MODE[$i]}"; done)
LANG_UI=es; init_categories; collect_items
internal_es=$(for i in "${!ARR_NAME[@]}"; do printf '%s|%s|%s\n' "${ARR_KIND[$i]}" "${ARR_RAW[$i]}" "${ARR_MODE[$i]}"; done)
check 'internal identifiers are identical across languages' "$([[ "$internal_en" == "$internal_es" ]] && echo 0 || echo 1)" 0

# Same requested state => same persisted file bytes.
make_user_fixture() {
    printf '[Desktop Entry]\nType=Application\nName=Same\nExec=/usr/bin/true\nHidden=false\nX-GNOME-Autostart-enabled=true\n' > "$1"
}
make_user_fixture "$TMP/user-en.desktop"
make_user_fixture "$TMP/user-es.desktop"
ARR_KIND=(user_autostart); ARR_MODE=(''); ARR_STATUS=(TRUE)
LANG_UI=en; ARR_RAW=("$TMP/user-en.desktop"); set_item_state 0 FALSE; rc_en=$?; bytes_en=$(sha256sum "$TMP/user-en.desktop" | cut -d' ' -f1)
LANG_UI=es; ARR_RAW=("$TMP/user-es.desktop"); set_item_state 0 FALSE; rc_es=$?; bytes_es=$(sha256sum "$TMP/user-es.desktop" | cut -d' ' -f1)
check 'user autostart disable result code is language-invariant' "$rc_en/$rc_es" '0/0'
check 'user autostart disable persisted state is byte-identical' "$([[ "$bytes_en" == "$bytes_es" ]] && echo 0 || echo 1)" 0

# Error paths must differ only in human-readable language, never status code.
ERR_ENV="$TMP/readonly-env"
mkdir -p "$ERR_ENV"
cat > "$ERR_ENV/readonly.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Same
Hidden=false
DESK
chmod 444 "$ERR_ENV/readonly.desktop"
# The write must be denied: a root-owned file for an unprivileged user when the
# suite runs as root, otherwise a read-only directory owned by the current user.
as_user=()
if (( EUID == 0 )); then
    chown root:root "$ERR_ENV/readonly.desktop"
    chmod 755 "$ERR_ENV"
    as_user=(runuser -u nobody --)
fi
cat > "$ERR_ENV/run.sh" <<'RUN'
#!/bin/bash
set -u
# shellcheck source=../script/Autostart_Manager.sh
source "${SCRIPT:?}"
ARR_KIND=(user_autostart); ARR_MODE=(''); ARR_STATUS=(TRUE); ARR_RAW=("${ERR_ENV:?}/readonly.desktop")
LANG_UI="${TEST_LANG:?}"
set_item_state 0 FALSE >/dev/null 2>&1; rc=$?
printf '%s\n' "$rc"
RUN
chmod 755 "$ERR_ENV/run.sh"
(( EUID == 0 )) || chmod 555 "$ERR_ENV"
rc_en=$("${as_user[@]}" env SCRIPT="$SCRIPT" ERR_ENV="$ERR_ENV" TEST_LANG=en HOME="$ERR_ENV" PATH="$BIN:$PATH" bash "$ERR_ENV/run.sh")
rc_es=$("${as_user[@]}" env SCRIPT="$SCRIPT" ERR_ENV="$ERR_ENV" TEST_LANG=es HOME="$ERR_ENV" PATH="$BIN:$PATH" bash "$ERR_ENV/run.sh")
chmod 755 "$ERR_ENV"
check 'same failure path keeps identical return code' "$rc_en/$rc_es" '1/1'

# Critical decisions are machine properties, not localized labels.
for lang in en es; do
    LANG_UI="$lang"; init_categories
    ARR_KIND=(user_autostart systemd_system user_autostart)
    ARR_RAW=(polkit-gnome-authentication-agent-1.desktop NetworkManager.service ordinary.desktop)
    ARR_NAME=('PolicyKit Agent' 'NetworkManager' 'Ordinary')
    expected=0
    item_is_critical 0 && ((expected+=1))
    item_is_critical 1 && ((expected+=1))
    item_is_critical 2 || true
    printf '%s:%s\n' "$lang" "$expected" >> "$TMP/critical"
done
check 'critical classification count identical across languages' "$(cut -d: -f2 "$TMP/critical" | sort -u | wc -l)" 1

# Critical classification must survive localized source names in either interface language.
cat > "$TMP/polkit.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=Ordinary Background Component
Name[en]=PolicyKit Authentication Agent
Name[es]=Agente de autenticación de PolicyKit
Exec=/usr/bin/true
DESK
ARR_KIND=(user_autostart); ARR_RAW=("$TMP/polkit.desktop"); ARR_NAME=('Ordinary Background Component')
LANG_UI=en; check 'localized critical source is critical in English UI' "$(item_is_critical 0; echo $?)" 0
LANG_UI=es; check 'localized critical source is critical in Spanish UI' "$(item_is_critical 0; echo $?)" 0

# User-systemd verb sequence is machine-identical across languages.
: > "$TRACE"
for lang in en es; do
    LANG_UI="$lang"; ARR_KIND=(systemd_user); ARR_RAW=(demo.service); ARR_MODE=(enable)
    set_item_state 0 FALSE >/dev/null 2>&1
    ARR_MODE=(mask); set_item_state 0 FALSE >/dev/null 2>&1
    set_item_state 0 TRUE >/dev/null 2>&1
done
user_verbs=$(grep '^systemctl --user ' "$TRACE" | sed -E 's/^(.*)-- demo\.service$/\1-- UNIT/')
check 'systemd user verb trace is language-invariant' "$(printf '%s\n' "$user_verbs" | sed -n '1,3p' | tr '\n' '|' )" 'systemctl --user disable -- UNIT|systemctl --user mask -- UNIT|systemctl --user unmask -- UNIT|'

# Language can change after inventory without changing category membership.
LANG_UI=en; init_categories; collect_items
categories_en=$(for i in "${!ARR_NAME[@]}"; do item_category "$i"; done | sort | tr '\n' ' ')
LANG_UI=es; init_categories
categories_es=$(for i in "${!ARR_NAME[@]}"; do item_category "$i"; done | sort | tr '\n' ' ')
check 'category membership is language-invariant' "$categories_en|$categories_es" "$categories_en|$categories_en"


# Systemd batch: compare only machine-side effects and results, not localized diagnostics.
: > "$TRACE"
IDX=(0 1 2)
ARR_KIND=(systemd_system systemd_system systemd_system)
ARR_RAW=(example.service example-static.service other.service)
ARR_MODE=(enable mask enable)
ARR_STATUS=(TRUE TRUE FALSE)
SELECTED_IDS=([0]="x" [1]="" [2]="")
declare -A SYS_RESULT SYS_ERROR
SYS_RESULT=(); SYS_ERROR=()
LANG_UI=en; init_categories; apply_systemd_system_batch IDX SYS_RESULT SYS_ERROR >/dev/null 2>&1; rc_en=$?
systemd_trace_en=$(grep '^systemctl ' "$TRACE" | sed 's#^systemctl ##')
systemd_result_en=$(for u in example.service example-static.service other.service; do printf '%s=%s\n' "$u" "${SYS_RESULT[$u]:-MISSING}"; done)
: > "$TRACE"
SELECTED_IDS=([0]="x" [1]="" [2]="")
SYS_RESULT=(); SYS_ERROR=()
LANG_UI=es; init_categories; apply_systemd_system_batch IDX SYS_RESULT SYS_ERROR >/dev/null 2>&1; rc_es=$?
systemd_trace_es=$(grep '^systemctl ' "$TRACE" | sed 's#^systemctl ##')
systemd_result_es=$(for u in example.service example-static.service other.service; do printf '%s=%s\n' "$u" "${SYS_RESULT[$u]:-MISSING}"; done)
check 'systemd batch return code is language-invariant' "$rc_en/$rc_es" '0/0'
check 'systemd batch command trace is language-invariant' "$systemd_trace_en" "$systemd_trace_es"
check 'systemd batch result map is language-invariant' "$systemd_result_en" "$systemd_result_es"

# Cron: same requested transition must produce identical persisted content.
cat > "$CRONTAB_FILE" <<'CRON'
SHELL=/bin/bash
*/5 * * * * /usr/bin/example --foo && echo ok
CRON
ARR_KIND=(cron_user); ARR_MODE=(''); ARR_STATUS=(TRUE); ARR_RAW=(2)
LANG_UI=en; set_item_state 0 FALSE >/dev/null 2>&1; cron_en=$(cat "$CRONTAB_FILE"); rc_en=$?
cat > "$CRONTAB_FILE" <<'CRON'
SHELL=/bin/bash
*/5 * * * * /usr/bin/example --foo && echo ok
CRON
LANG_UI=es; set_item_state 0 FALSE >/dev/null 2>&1; cron_es=$(cat "$CRONTAB_FILE"); rc_es=$?
check 'cron disable return code is language-invariant' "$rc_en/$rc_es" '0/0'
check 'cron disable persisted content is language-invariant' "$cron_en" "$cron_es"

# System autostart override: use a fixture path so the test never touches /etc.
SYS_DESKTOP="$TMP/system.desktop"
cat > "$SYS_DESKTOP" <<'DESK'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/example
Hidden=false
X-GNOME-Autostart-enabled=true
X-Custom=preserve
DESK
FIXTURE_SYS_SCRIPT="$TMP/system-script.sh"
cp "$SCRIPT" "$FIXTURE_SYS_SCRIPT"
mkdir -p "$TMP/etc/xdg/autostart" "$HOME_FAKE/.config/autostart"
cp "$SYS_DESKTOP" "$TMP/etc/xdg/autostart/system.desktop"
for lang in en es; do
    rm -f "$HOME_FAKE/.config/autostart/system.desktop"
    SCRIPT="$FIXTURE_SYS_SCRIPT" HOME="$HOME_FAKE" PATH="$BIN:$PATH" TEST_LANG="$lang" bash -c '
        set -u
        # shellcheck source=../script/Autostart_Manager.sh
        source "$SCRIPT"
        ARR_KIND=(system_autostart); ARR_RAW=("$XDG_CONFIG_DIRS/autostart/system.desktop"); ARR_MODE=(''); ARR_STATUS=(TRUE)
        LANG_UI="$TEST_LANG"
        set_item_state 0 FALSE
    ' >/dev/null 2>&1
    cp "$HOME_FAKE/.config/autostart/system.desktop" "$TMP/override-$lang"
done
check 'system autostart override is language-invariant' "$(cmp -s "$TMP/override-en" "$TMP/override-es"; echo $?)" 0


# The language switch must not rewrite the process locale variables.
LANG=C.UTF-8 LC_ALL=C.UTF-8 LC_MESSAGES=C.UTF-8 LANG_UI=en
before_locale="$LC_ALL|$LC_MESSAGES|$LANG"
LANG_UI=es
init_categories
LANG_UI=en
init_categories
after_locale="$LC_ALL|$LC_MESSAGES|$LANG"
check 'language changes do not mutate locale environment' "$after_locale" "$before_locale"

# PolicyKit failure codes are machine outcomes; wording may change, outcome must not.
cat > "$BIN/pkexec" <<'SH'
#!/bin/bash
printf 'pkexec %s\n' "$*" >> "${TRACE:?}"
exit "${PKEXEC_RC:-0}"
SH
chmod +x "$BIN/pkexec"
# shellcheck disable=SC2034  # IDX and SYS_ERROR are passed by name (nameref)
for fail_rc in 124 126 127; do
    export PKEXEC_RC="$fail_rc" TRACE="$TRACE" LANG_UI=en
    IDX=(0)
    ARR_KIND=(systemd_system); ARR_RAW=(example.service); ARR_MODE=(enable); ARR_STATUS=(TRUE)
    SELECTED_IDS=([0]="x"); SYS_RESULT=(); SYS_ERROR=(); PKEXEC_BATCH_ERROR=''
    apply_systemd_system_batch IDX SYS_RESULT SYS_ERROR >/dev/null 2>&1; batch_en=$?; result_en="${SYS_RESULT[example.service]:-MISSING}"
    SELECTED_IDS=([0]="x"); SYS_RESULT=(); SYS_ERROR=(); PKEXEC_BATCH_ERROR=''
    LANG_UI=es; apply_systemd_system_batch IDX SYS_RESULT SYS_ERROR >/dev/null 2>&1; batch_es=$?; result_es="${SYS_RESULT[example.service]:-MISSING}"
    check "pkexec failure $fail_rc return code is language-invariant" "$batch_en/$batch_es" "$fail_rc/$fail_rc"
    check "pkexec failure $fail_rc result map is language-invariant" "$result_en/$result_es" 'FAIL/FAIL'
done

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
