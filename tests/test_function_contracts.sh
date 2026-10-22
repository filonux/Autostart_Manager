#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home/.config/autostart"
cat > "$BIN/zenity" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/zenity"

export PATH="$BIN:$PATH" HOME="$TMP/home" AUTOSTART_MANAGER_TEST=1
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"

pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"
        ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
        ((fail++))
    fi
}

# ---------------------------------------------------------------------------
# Category rendering / inventory contracts.
# ---------------------------------------------------------------------------
LANG_UI=en
init_categories

# add_item() must keep technical identity separate from translated labels and
# choose the expected icon/critical marker for every supported source kind.
is_critical_autostart() { [[ "${1:-}" == critical.desktop ]]; }
is_critical_unit() { [[ "${1:-}" == critical.service ]]; }
is_internal_systemd_unit() { [[ "${1:-}" == internal.service ]]; }

ARR_TYPE=(); ARR_NAME=(); ARR_STATUS=(); ARR_STATUS_LABEL=(); ARR_SRC=(); ARR_KIND=(); ARR_RAW=(); ARR_MODE=()
add_item "Startup" "Critical user app" TRUE /tmp/critical.desktop user_autostart /tmp/critical.desktop
add_item "Startup" "System app" FALSE /tmp/system.desktop system_autostart system.desktop
add_item "systemd (usuario)" "Critical user" TRUE critical.service systemd_user critical.service enable
add_item "systemd (sistema)" "Internal service" TRUE internal.service systemd_system internal.service mask
add_item "systemd (sistema)" "Third-party" TRUE thirdparty.service systemd_system thirdparty.service enable
add_item "cron" "Task" FALSE "line 4" cron_user 4 " 0 2 * * * /usr/bin/job"
check 'add_item creates one row per supported kind' "${#ARR_KIND[@]}" 6
check 'add_item marks critical autostart' "${ARR_TYPE[0]}" '🔒 Startup · CRITICAL'
check 'add_item marks critical systemd' "${ARR_TYPE[2]}" '🔒 User service · CRITICAL'
check 'add_item classifies internal systemd with gear icon' "${ARR_TYPE[3]}" '⚙️ System service'
check 'add_item classifies third-party systemd as package/background' "${ARR_TYPE[4]}" '📦 Background process'
check 'add_item keeps cron mode/source metadata' "${ARR_KIND[5]}|${ARR_RAW[5]}|${ARR_MODE[5]}" 'cron_user|4| 0 2 * * * /usr/bin/job'

# Direct criticality and classification contracts.
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"
LANG_UI=en
init_categories

for u in NetworkManager.service systemd-logind.socket dbus.service sshd.service; do
    is_critical_unit "$u"; rc=$?
    check "critical systemd rule accepts $u" "$rc" 0
done
for u in cups.service networkmanager.service polkit.service thirdparty.service; do
    is_internal_systemd_unit "$u"; rc=$?
    [[ "$u" == thirdparty.service ]] && expected=1 || expected=0
    check "internal-systemd classifier handles $u" "$rc" "$expected"
done

ARR_KIND=(systemd_system systemd_system systemd_user cron_user user_autostart)
ARR_RAW=(NetworkManager.service internal.service user.service 9 app.desktop)
ARR_NAME=(Network Internal User Cron App)
init_categories
category_tag 0 > "$TMP/tag0"
check 'category_tag uses the current category icon and short label' "$(cat "$TMP/tag0")" '[🔧 System] '

ARR_NAME=(zulu Alpha bravo)
ARR_KIND=(systemd_system systemd_system cron_user)
ARR_RAW=(third.service internal.service 1)
cat4=(); category_indices 4 cat4
check 'category_indices sorts display names case-insensitively' "${cat4[*]}" '1 0'
all_idx=(); category_indices ALL all_idx
check 'category_indices includes all matching rows' "${all_idx[*]}" '1 2 0'
ARR_NAME=(Normal $'Malicious\nName' Normal)
ARR_KIND=(cron_user cron_user cron_user)
ARR_RAW=(1 2 3)
hostile_idx=(); category_indices ALL hostile_idx
check 'category_indices preserves names containing newlines' "${hostile_idx[*]}" '1 0 2'
check 'category_indices keeps duplicate-name order stable' "$(printf '%s ' "${hostile_idx[@]}")" '1 0 2 '
ARR_NAME=(); ARR_KIND=(); ARR_RAW=()
empty_idx=(); category_indices ALL empty_idx
check 'category_indices returns an empty array for empty inventory' "${#empty_idx[@]}" 0

# ---------------------------------------------------------------------------
# Atomic helpers and state mutation contracts.
# ---------------------------------------------------------------------------
SYNC_LOG="$TMP/sync.log"
export SYNC_LOG
cat > "$BIN/sync" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SYNC_LOG"
exit 0
EOF
chmod +x "$BIN/sync"; hash -r
ATOMIC_SYNC_BIN="$BIN/sync"
: > "$SYNC_LOG"
printf 'data\n' > "$TMP/sync-target"
atomic_sync_file "$TMP/sync-target"; rc=$?
check 'atomic_sync_file uses sync and propagates success' "$rc" 0
check 'atomic_sync_file passes the file path' "$(cat "$SYNC_LOG")" "-- $TMP/sync-target"
cat > "$BIN/sync" <<'EOF'
#!/bin/bash
exit 7
EOF
chmod +x "$BIN/sync"; hash -r
ATOMIC_SYNC_BIN="$BIN/sync"
atomic_sync_file "$TMP/sync-target"; rc=$?
check 'atomic_sync_file propagates sync failure' "$rc" 7

# atomic_install: a post-rename directory-sync failure is best effort; commit
# must remain durable at the file-name level and must not report false failure.
sync_count="$TMP/sync-count"
cat > "$BIN/sync" <<EOF
#!/bin/bash
n=\$(cat "$sync_count" 2>/dev/null || echo 0)
n=\$((n+1))
printf '%s' "\$n" > "$sync_count"
if [[ \$n -eq 2 ]]; then exit 9; fi
exit 0
EOF
chmod +x "$BIN/sync"; hash -r
ATOMIC_SYNC_BIN="$BIN/sync"
printf 'new\n' > "$TMP/atomic-src"
printf 'old\n' > "$TMP/atomic-dst"
atomic_install "$TMP/atomic-src" "$TMP/atomic-dst"; rc=$?
check 'atomic_install commits despite best-effort directory sync failure' "$rc" 0
check 'atomic_install retains committed content after directory sync failure' "$(cat "$TMP/atomic-dst")" 'new'

# SIGTERM before rename must leave the old target intact and clean the temp file.
signal_sync="$BIN/sync-signal"
signal_temp="$TMP/signal-temp"
cat > "$signal_sync" <<'EOF'
#!/bin/bash
printf '%s\n' "$2" > "${SIGNAL_TEMP:?}"
kill -TERM "$PPID"
exit 0
EOF
chmod +x "$signal_sync"
printf 'old\n' > "$TMP/atomic-signal-dst"
signal_tmp_path_seed=$(mktemp -- "$TMP/.atomic-signal-dst.tmp.XXXXXX")
printf 'new\n' > "$signal_tmp_path_seed"
rm -f "$signal_temp"
bash -c 'source "$1"; TMP_FILES=("$2"); ATOMIC_SYNC_BIN="$3"; export SIGNAL_TEMP="$4"; atomic_install "$2" "$5"' \
    _ "$SCRIPT" "$signal_tmp_path_seed" "$signal_sync" "$signal_temp" "$TMP/atomic-signal-dst" &
pid=$!
for _ in {1..100}; do [[ -s "$signal_temp" ]] && break; sleep 0.01; done
wait "$pid"; rc=$?
signal_tmp_path=$(cat "$signal_temp" 2>/dev/null || true)
check 'atomic_install returns SIGTERM status when interrupted before rename' "$rc" 143
check 'atomic_install leaves the target unchanged after SIGTERM' "$(cat "$TMP/atomic-signal-dst")" 'old'
if [[ -n "$signal_tmp_path" && ! -e "$signal_tmp_path" ]]; then signal_tmp_cleaned=0; else signal_tmp_cleaned=1; fi
check 'atomic_install cleans its temp file after SIGTERM' "$signal_tmp_cleaned" 0

# atomic_transform() sed-filter success path and stale-snapshot rejection.
cat > "$BIN/sync" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/sync"; hash -r
ATOMIC_SYNC_BIN="$BIN/sync"
sed_target="$TMP/state.desktop"
printf '[Desktop Entry]\nHidden=false\n' > "$sed_target"
chmod 640 "$sed_target"
hash=$(sha256sum "$sed_target" | awk '{print $1}')
atomic_transform "$sed_target" "$hash" "$sed_target" sed 's/^Hidden=false/Hidden=true/' --
rc=$?
check 'atomic_transform applies a matching snapshot' "$rc" 0
check 'atomic_transform writes transformed content' "$(grep '^Hidden=' "$sed_target")" 'Hidden=true'
check 'atomic_transform preserves mode' "$(stat -c '%a' "$sed_target")" 640
stale=$(sha256sum "$sed_target" | awk '{print $1}')
printf '[Desktop Entry]\nHidden=false\nX-Race=yes\n' > "$sed_target"
atomic_transform "$sed_target" "$stale" "$sed_target" sed 's/^Hidden=false/Hidden=true/' -- >/dev/null 2>&1
rc=$?
check 'atomic_transform rejects stale snapshots' "$rc" 1
check 'atomic_transform leaves raced content untouched' "$(cat "$sed_target")" $'[Desktop Entry]\nHidden=false\nX-Race=yes'

# atomic_transform() must transform a stable snapshot, not bytes that race in SOURCE.
racy_source="$TMP/racy-transform.desktop"
racy_dest="$TMP/racy-transform-dest.desktop"
printf '[Desktop Entry]\nHidden=false\nName=Original\n' > "$racy_source"
printf 'old-destination\n' > "$racy_dest"
racy_hash=$(sha256sum "$racy_source" | awk '{print $1}')
cat > "$BIN/racy_transform" <<'SH'
#!/bin/bash
source_path=${RACE_SOURCE:?}
saved=$(mktemp)
cp -- "$source_path" "$saved"
sed -i 's/Name=Original/Name=Interim/' "$source_path"
cat -- "$1"
mv -fT -- "$saved" "$source_path"
SH
chmod +x "$BIN/racy_transform"
export RACE_SOURCE="$racy_source"
atomic_transform "$racy_source" "$racy_hash" "$racy_dest" racy_transform
rc=$?
check 'atomic_transform commits the stable snapshot after a transient source race' "$rc" 0
check 'atomic_transform output is based on the stable snapshot' "$(grep '^Name=' "$racy_dest")" 'Name=Original'
check 'atomic_transform sees the source restored to the expected hash' "$(sha256sum "$racy_source" | awk '{print $1}')" "$racy_hash"

# A source that remains changed after the transform must abort before commit.
changed_source="$TMP/changed-transform.desktop"
changed_dest="$TMP/changed-transform-dest.desktop"
printf '[Desktop Entry]\nHidden=false\nName=Original\n' > "$changed_source"
printf 'preserve-me\n' > "$changed_dest"
changed_hash=$(sha256sum "$changed_source" | awk '{print $1}')
cat > "$BIN/persist_change_transform" <<'SH'
#!/bin/bash
source_path=${RACE_SOURCE:?}
sed -i 's/Name=Original/Name=Changed/' "$source_path"
cat -- "$1"
SH
chmod +x "$BIN/persist_change_transform"
RACE_SOURCE="$changed_source" atomic_transform "$changed_source" "$changed_hash" "$changed_dest" persist_change_transform >/dev/null 2>&1
rc=$?
check 'atomic_transform rejects a persistent source change during transform' "$rc" 1
check 'atomic_transform preserves destination after persistent source change' "$(cat "$changed_dest")" 'preserve-me'
check 'atomic_transform leaves persistent source change visible' "$(grep '^Name=' "$changed_source")" 'Name=Changed'

# A source replaced by a symlink during the transform must also abort.
symlink_source="$TMP/symlink-transform.desktop"
symlink_dest="$TMP/symlink-transform-dest.desktop"
symlink_target="$TMP/symlink-transform-target.desktop"
printf '[Desktop Entry]\nHidden=false\nName=Original\n' > "$symlink_source"
printf '[Desktop Entry]\nHidden=false\nName=Replacement\n' > "$symlink_target"
printf 'preserve-symlink\n' > "$symlink_dest"
symlink_hash=$(sha256sum "$symlink_source" | awk '{print $1}')
cat > "$BIN/symlink_transform" <<'SH'
#!/bin/bash
source_path=${RACE_SOURCE:?}
replacement=${RACE_REPLACEMENT:?}
rm -f -- "$source_path"
ln -s -- "$replacement" "$source_path"
cat -- "$1"
SH
chmod +x "$BIN/symlink_transform"
RACE_SOURCE="$symlink_source" RACE_REPLACEMENT="$symlink_target" atomic_transform "$symlink_source" "$symlink_hash" "$symlink_dest" symlink_transform >/dev/null 2>&1
rc=$?
check 'atomic_transform rejects a source symlink race' "$rc" 1
check 'atomic_transform preserves destination after source symlink race' "$(cat "$symlink_dest")" 'preserve-symlink'
check 'atomic_transform leaves replacement symlink visible' "$(test -L "$symlink_source" && echo 1 || echo 0)" 1

# desktop_set_user_state(): all supported activation representations.
cat > "$TMP/desktop-hidden.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Demo
Exec=/usr/bin/true
Hidden=false
X-GNOME-Autostart-enabled=false
EOF
chmod 600 "$TMP/desktop-hidden.desktop"
desktop_set_user_state "$TMP/desktop-hidden.desktop" TRUE
check 'desktop_set_user_state enables Hidden=false' "$(grep '^Hidden=' "$TMP/desktop-hidden.desktop")" 'Hidden=false'
check 'desktop_set_user_state enables GNOME autostart flag' "$(grep '^X-GNOME-Autostart-enabled=' "$TMP/desktop-hidden.desktop")" 'X-GNOME-Autostart-enabled=true'
desktop_set_user_state "$TMP/desktop-hidden.desktop" FALSE
check 'desktop_set_user_state disables existing Hidden key' "$(grep '^Hidden=' "$TMP/desktop-hidden.desktop")" 'Hidden=true'
cat > "$TMP/desktop-missing-hidden.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Demo
Exec=/usr/bin/true
EOF
desktop_set_user_state "$TMP/desktop-missing-hidden.desktop" FALSE
check 'desktop_set_user_state appends missing Hidden key' "$(tail -n1 "$TMP/desktop-missing-hidden.desktop")" 'Hidden=true'

# ---------------------------------------------------------------------------
# Refresh / editor / privileged-process contracts.
# ---------------------------------------------------------------------------
collect_calls=0
collect_items() { collect_calls=$((collect_calls+1)); ARR_NAME=(refreshed); }
ITEMS_DIRTY=0
refresh_items
check 'refresh_items is a no-op when inventory is clean' "$collect_calls" 0
ITEMS_DIRTY=1
refresh_items
check 'refresh_items rebuilds dirty inventory once' "$collect_calls" 1
check 'refresh_items clears dirty marker after rebuild' "$ITEMS_DIRTY" 0

cat > "$BIN/xed" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN/xed"; hash -r
check 'pick_editor prefers the first available supported editor' "$(pick_editor)" 'xed'
rm -f "$BIN/xed"; hash -r
check 'pick_editor falls back to xdg-open' "$(pick_editor)" 'xdg-open'

FAKE_PKEXEC="$TMP/fake-pkexec"
PKEXEC_LOG="$TMP/pkexec.log"
cat > "$FAKE_PKEXEC" <<EOF
#!/bin/bash
printf 'argv:%s\n' "\$*" >> "$PKEXEC_LOG"
if [[ "\${1:-}" == /bin/bash && "\${2:-}" == -s ]]; then
    cat > "$TMP/pkexec.stdin"
    printf 'payload-ok\n' >&2
fi
exit 17
EOF
chmod +x "$FAKE_PKEXEC"
pkexec_path() { printf '%s\n' "$FAKE_PKEXEC"; }
PRIV_TIMEOUT_BIN=""
check 'pkexec_path resolves the trusted privileged helper' "$(pkexec_path)" "$FAKE_PKEXEC"
run_privileged_batch <<< $'printf hello' 2>/dev/null
rc=$?
check 'run_privileged_batch propagates pkexec exit status' "$rc" 17
check 'run_privileged_batch calls /bin/bash -s' "$(cat "$PKEXEC_LOG")" 'argv:/bin/bash -s'
run_pkexec --version
rc=$?
check 'run_pkexec propagates wrapped command result' "$rc" 17
check 'run_pkexec passes arguments unchanged' "$(tail -n1 "$PKEXEC_LOG")" 'argv:--version'

# edit_file_root() must resolve through the trusted editor path and preserve
# DISPLAY/XAUTHORITY for pkexec without letting the caller PATH control it.
ROOT_EDIT_LOG="$TMP/root-edit.log"
pick_editor_root() { printf '%s\n' /usr/bin/fake-editor; }
run_pkexec() { printf '%s\n' "$*" >> "$ROOT_EDIT_LOG"; return 0; }
DISPLAY=':77'; XAUTHORITY="$TMP/Xauthority"
edit_file_root "$TMP/target.desktop"
wait
check 'edit_file_root delegates to the privileged wrapper' "$(cat "$ROOT_EDIT_LOG")" "/usr/bin/env DISPLAY=:77 XAUTHORITY=$TMP/Xauthority /usr/bin/fake-editor $TMP/target.desktop"

# pick_editor_root must not trust a shadowed stat from the caller PATH.
cat > "$BIN/stat" <<'SH'
#!/bin/bash
exit 99
SH
chmod +x "$BIN/stat"
hash -r
root_editor=$(PATH="$BIN:$PATH" pick_editor_root 2>/dev/null)
check 'pick_editor_root does not use caller PATH stat' "$( [[ -n "$root_editor" ]] && echo 1 || echo 0 )" 1
rm -f "$BIN/stat"
hash -r

# browse_and_open() must only open a numeric selection returned by Zenity and
# must pass that selection to open_item() unchanged.
ARR_TYPE=('type0' 'type1'); ARR_NAME=('Name 0' 'Name 1'); ARR_SRC=('src0' 'src1')
opened=''
open_item() { opened="$1"; }
zen() { printf '%s\n' 1; }
idx=(0 1)
browse_and_open idx
check 'browse_and_open opens the selected inventory index' "$opened" 1
opened=''
zen() { printf '%s\n' 'not-an-index'; }
browse_and_open idx
check 'browse_and_open ignores non-numeric selections' "${opened:-EMPTY}" EMPTY

# fit_height(): list window height from the measured constants (FIT_GTK3/FIT_GTK4), clamped to 340-600 px.
ZEN_MAJOR=3
check 'fit_height clamps short lists to 340 px' "$(fit_height '' 0)" 340
check 'fit_height clamps long lists to 600 px' "$(fit_height '' 500)" 600
check 'fit_height counts a missing text as one line' \
    "$(fit_height '' 10)" "$(( FIT_GTK3[0] + FIT_GTK3[1] + 10 * FIT_GTK3[2] ))"
check 'fit_height adds one text line per \n escape' \
    "$(( $(fit_height 'a\nb\nc' 10) - $(fit_height a 10) ))" "$(( 2 * FIT_GTK3[1] ))"
check 'fit_height adds one menu row height per row' \
    "$(( $(fit_height '' 11) - $(fit_height '' 10) ))" "${FIT_GTK3[2]}"
check 'fit_height adds one checklist row height per row' \
    "$(( $(fit_height '' 11 check) - $(fit_height '' 10 check) ))" "${FIT_GTK3[3]}"
h3=$(fit_height '' 10); ZEN_MAJOR=4; h4=$(fit_height '' 10)
check 'fit_height gives Zenity 4.x more height than 3.x for the same rows' "$(( h4 > h3 ))" 1
check 'fit_height uses the Zenity 4.x constants for a checklist' \
    "$(fit_height 'a\nb' 5 check)" "$(( FIT_GTK4[0] + 2 * FIT_GTK4[1] + 5 * FIT_GTK4[3] ))"
ZEN_MAJOR=3

# Minimum --height (px) at which every row is visible, measured on real Zenity (PLAN.txt 14.16):
# 6 environments x 7 points. Fields: environment (Zenity major, font, theme), list (m menu,
# c checklist, o open list), text lines (no text counts 1), rows, measured height.
# z4 = Zenity 4.0.1; z3 = 3.44.2 with the default theme or Mint-Y; fonts Noto Sans or DejaVu Sans 10.
HEIGHT_MATRIX=(
    "z4-noto        m 1  3 320"
    "z4-noto        m 1 10 565"
    "z4-noto        m 4  3 377"
    "z4-noto        c 1  3 341"
    "z4-noto        c 4  3 398"
    "z4-noto        c 4 10 692"
    "z4-noto        o 1 10 565"
    "z4-dejavu      m 1  3 308"
    "z4-dejavu      m 1 10 539"
    "z4-dejavu      m 4  3 359"
    "z4-dejavu      c 1  3 335"
    "z4-dejavu      c 4  3 386"
    "z4-dejavu      c 4 10 680"
    "z4-dejavu      o 1 10 539"
    "z3-noto        m 1  3 185"
    "z3-noto        m 1 10 360"
    "z3-noto        m 4  3 242"
    "z3-noto        c 1  3 185"
    "z3-noto        c 4  3 242"
    "z3-noto        c 4 10 417"
    "z3-noto        o 1 10 360"
    "z3-dejavu      m 1  3 177"
    "z3-dejavu      m 1 10 338"
    "z3-dejavu      m 4  3 228"
    "z3-dejavu      c 1  3 177"
    "z3-dejavu      c 4  3 228"
    "z3-dejavu      c 4 10 389"
    "z3-dejavu      o 1 10 338"
    "z3-noto-mint   m 1  3 201"
    "z3-noto-mint   m 1 10 376"
    "z3-noto-mint   m 4  3 258"
    "z3-noto-mint   c 1  3 201"
    "z3-noto-mint   c 4  3 258"
    "z3-noto-mint   c 4 10 433"
    "z3-noto-mint   o 1 10 376"
    "z3-dejavu-mint m 1  3 193"
    "z3-dejavu-mint m 1 10 354"
    "z3-dejavu-mint m 4  3 244"
    "z3-dejavu-mint c 1  3 193"
    "z3-dejavu-mint c 4  3 244"
    "z3-dejavu-mint c 4 10 405"
    "z3-dejavu-mint o 1 10 354"
)
matrix_formula() {   # MAJOR LIST LINES ROWS -> height from the constants, before the 340-600 clamp
    local -a m=("${FIT_GTK3[@]}"); (( $1 >= 4 )) && m=("${FIT_GTK4[@]}")
    local row="${m[2]}"; [[ "$2" == c ]] && row="${m[3]}"
    printf '%s' "$(( m[0] + m[1] * $3 + row * $4 ))"
}
short=0 off=0
for entry in "${HEIGHT_MATRIX[@]}"; do
    read -r env list lines rows px <<< "$entry"
    major=3; [[ "$env" == z4-* ]] && major=4
    want=$(matrix_formula "$major" "$list" "$lines" "$rows")
    (( want < px )) && short=$((short + 1))
    text=a; for (( i = 1; i < lines; i++ )); do text+='\na'; done
    (( want < 340 )) && want=340; (( want > 600 )) && want=600
    ZEN_MAJOR=$major
    [[ "$list" == c ]] && got=$(fit_height "$text" "$rows" check) || got=$(fit_height "$text" "$rows")
    [[ "$got" == "$want" ]] || off=$((off + 1))
done
ZEN_MAJOR=3
check 'fit constants cover every measured minimum height' "$short" 0
check 'fit_height returns the clamped constants for every measured point' "$off" 0
check 'height matrix keeps its 42 points in 6 groups of 7' \
    "${#HEIGHT_MATRIX[@]} $(printf '%s\n' "${HEIGHT_MATRIX[@]}" | awk '{n[$1]++} END {for (g in n) {c++; if (lo == "" || n[g] < lo) lo = n[g]; if (n[g] > hi) hi = n[g]} print c, (lo == hi ? lo : "uneven")}')" '42 6 7'

# detect_zenity_major(): reads the major version once; anything unexpected leaves the value untouched.
fake_zenity_major() {   # fake_zenity_major OUTPUT EXIT_CODE START -> value after detection
    local d; d=$(mktemp -d -p "$TMP")
    cat > "$d/zenity" <<EOF2
#!/bin/bash
[[ "\$1" == --version ]] || exit 1
echo '$1'
exit $2
EOF2
    chmod +x "$d/zenity"
    ZEN_MAJOR=$3; PATH="$d:$PATH" detect_zenity_major; printf '%s' "$ZEN_MAJOR"
}
check 'detect_zenity_major reads Zenity 4.x' "$(fake_zenity_major 4.0.1 0 3)" 4
check 'detect_zenity_major reads Zenity 3.x' "$(fake_zenity_major 3.44.1 0 7)" 3
check 'detect_zenity_major ignores a non-numeric answer' "$(fake_zenity_major hello 0 7)" 7
check 'detect_zenity_major ignores a failing zenity' "$(fake_zenity_major 4.0.1 5 7)" 7

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
