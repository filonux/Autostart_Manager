#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/zenity" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$BIN/zenity"

export PATH="$BIN:$PATH" HOME="$TMP/home" AUTOSTART_MANAGER_TEST=1
mkdir -p "$HOME/.config/autostart"
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

# 1. Syntax remains valid.
bash -n "$SCRIPT"
check 'production script passes bash -n' "$?" 0

# 2. atomic_install commits via same-directory rename and preserves permissions.
ORDER_LOG="$TMP/order.log"
MV_LOG="$TMP/mv.log"
SYNC_LOG="$TMP/sync.log"
export ORDER_LOG MV_LOG SYNC_LOG

cat > "$BIN/sync" <<'SH'
#!/bin/bash
printf 'sync %s\n' "$*" >> "$SYNC_LOG"
printf 'sync\n' >> "$ORDER_LOG"
exit 0
SH
cat > "$BIN/mv" <<'SH'
#!/bin/bash
printf 'mv %s\n' "$*" >> "$MV_LOG"
printf 'mv\n' >> "$ORDER_LOG"
exec /usr/bin/mv "$@"
SH
chmod +x "$BIN/sync" "$BIN/mv"
hash -r
ATOMIC_SYNC_BIN="$BIN/sync"

printf 'new\n' > "$TMP/source"
printf 'old\n' > "$TMP/target"
chmod 640 "$TMP/target"
: > "$ORDER_LOG"
atomic_install "$TMP/source" "$TMP/target"
check 'atomic install succeeds' "$?" 0
check 'atomic sync fails when configured sync is unavailable' "$(ATOMIC_SYNC_BIN="$TMP/no-sync" atomic_sync_file "$TMP/source" >/dev/null 2>&1; echo $?)" 1
check 'atomic install commits new content' "$(cat "$TMP/target")" 'new'
check 'atomic install keeps target mode' "$(stat -c '%a' "$TMP/target")" 640
check 'atomic install performs pre-commit and post-commit syncs' "$(grep -c '^sync ' "$SYNC_LOG")" 2
check 'atomic install orders sync, rename, sync' "$(tr '\n' '|' < "$ORDER_LOG")" 'sync|mv|sync|'
check 'atomic install uses -fT rename protection' "$(grep -c -- '-fT' "$MV_LOG")" 1

# 3. A target becoming a directory cannot turn mv into "move inside directory".
printf 'source\n' > "$TMP/race-source"
printf 'old\n' > "$TMP/race-target"
cat > "$BIN/mv" <<'SH'
#!/bin/bash
rm -f -- "${@: -1}"
mkdir -p -- "${@: -1}"
exec /usr/bin/mv "$@"
SH
chmod +x "$BIN/mv"
hash -r
atomic_install "$TMP/race-source" "$TMP/race-target" >/dev/null 2>&1; rc=$?
check 'directory race aborts the atomic commit' "$rc" 1
check 'directory race does not move source into target directory' "$(test ! -e "$TMP/race-target/race-source" && echo 1 || echo 0)" 1

# Restore normal mv.
cat > "$BIN/mv" <<'SH'
#!/bin/bash
exec /usr/bin/mv "$@"
SH
chmod +x "$BIN/mv"; hash -r

# 4. atomic_write must reject symlink targets and never follow them.
printf 'sentinel\n' > "$TMP/sentinel"
ln -s "$TMP/sentinel" "$TMP/link-target"
atomic_write "$TMP/link-target" $'changed\n'; rc=$?
check 'atomic write rejects symlink target' "$rc" 1
check 'atomic write does not follow target symlink' "$(cat "$TMP/sentinel")" 'sentinel'

# 4b. Persistent deletion is a single unlink-like operation and never follows symlinks.
remove_target="$TMP/remove-target"
printf 'remove-me\n' > "$remove_target"
: > "$SYNC_LOG"
ATOMIC_SYNC_BIN="$BIN/sync" atomic_remove "$remove_target"; rc=$?
check 'atomic remove succeeds' "$rc" 0
check 'atomic remove deletes the requested file' "$(test ! -e "$remove_target" && echo 1 || echo 0)" 1
check 'atomic remove syncs the parent directory' "$(grep -c '^sync ' "$SYNC_LOG")" 1

remove_sentinel="$TMP/remove-sentinel"
printf 'keep-me\n' > "$remove_sentinel"
ln -s "$remove_sentinel" "$TMP/remove-link"
ATOMIC_SYNC_BIN="$BIN/sync" atomic_remove "$TMP/remove-link" >/dev/null 2>&1; rc=$?
check 'atomic remove rejects symlink targets' "$rc" 1
check 'atomic remove leaves symlink intact' "$(test -L "$TMP/remove-link" && echo 1 || echo 0)" 1
check 'atomic remove preserves symlink target' "$(cat "$remove_sentinel")" 'keep-me'

# 5. User desktop changes are guarded by a content snapshot.
desktop="$TMP/user.desktop"
cat > "$desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Demo
Exec=/usr/bin/demo
Hidden=false
X-GNOME-Autostart-enabled=true
X-Custom=keep
EOF
snapshot=$(sha256sum "$desktop" | awk '{print $1}')
printf 'same\n' > "$TMP/expected-state"
cat > "$BIN/sha256sum" <<SH
#!/bin/bash
count_file="$TMP/hash-count"
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
n=\$((n+1))
printf '%s' "\$n" > "\$count_file"
if [[ "\$1" == "$desktop" && "\$n" -eq 4 ]]; then
    printf 'external\n' >> "$desktop"
fi
exec /usr/bin/sha256sum "\$@"
SH
chmod +x "$BIN/sha256sum"; hash -r

: > "$TMP/hash-count"
ARR_KIND=(user_autostart); ARR_RAW=("$desktop"); ARR_MODE=(''); ARR_STATUS=(TRUE)
set_item_state 0 FALSE >/dev/null 2>&1; rc=$?
check 'desktop update aborts on concurrent modification' "$rc" 1
check 'desktop concurrent modification is reported' "${LAST_ERR[0]:-}" "$(msg desktop_changed)"
check 'desktop concurrent edit is preserved' "$(cat "$desktop")" $'[Desktop Entry]\nType=Application\nName=Demo\nExec=/usr/bin/demo\nHidden=false\nX-GNOME-Autostart-enabled=true\nX-Custom=keep\nexternal'

# 6. System override generation has the same source snapshot defense.
source="$TMP/system.desktop"
target="$TMP/override.desktop"
cat > "$source" <<'EOF'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=true
X-GNOME-Autostart-enabled=false
X-Custom=preserve
EOF
rm -f "$TMP/hash-count"
cat > "$BIN/sha256sum" <<SH
#!/bin/bash
count_file="$TMP/hash-count"
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
n=\$((n+1))
printf '%s' "\$n" > "\$count_file"
if [[ "\$1" == "$source" && "\$n" -eq 4 ]]; then
    printf '\\n# external update\\n' >> "$source"
fi
exec /usr/bin/sha256sum "\$@"
SH
chmod +x "$BIN/sha256sum"; hash -r
desktop_make_override "$source" "$target" false >/dev/null 2>&1; rc=$?
check 'system override aborts on concurrent source modification' "$rc" 1
check 'system override does not leave stale output after source race' "$(test ! -e "$target" && echo 1 || echo 0)" 1

# Restore sha256sum and verify the normal override path still works.
rm -f "$BIN/sha256sum"; hash -r
cat > "$source" <<'EOF'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=true
X-GNOME-Autostart-enabled=false
X-Custom=preserve
EOF
desktop_make_override "$source" "$target" false >/dev/null 2>&1; rc=$?
check 'system override succeeds without a race' "$rc" 0
check 'system override preserves system content' "$(grep -E '^(Exec|X-Custom)=' "$target" | tr '\n' '|')" 'Exec=/usr/bin/system-app|X-Custom=preserve|'
check 'system override enables both activation flags' "$(grep -E '^(Hidden|X-GNOME-Autostart-enabled)=' "$target" | tr '\n' '|')" 'Hidden=false|X-GNOME-Autostart-enabled=true|'

override_home="$TMP/override-home"
override_target="$override_home/.config/autostart/generated.desktop"
desktop_make_override "$source" "$override_target" false >/dev/null 2>&1; rc=$?
check 'system override creates a missing target path' "$rc" 0
check 'system override creates its parent directory privately' "$(stat -c '%a' "$override_home/.config/autostart")" 700

# sha256sum starts its output line with a backslash when the path has one; the
# stale-file check must compare plain hashes whichever side the backslash is on.
bs_dir="$TMP/back\\slash"
desktop_make_override "$source" "$bs_dir/target.desktop" false >/dev/null 2>&1; rc=$?
check 'system override works when only the target path has a backslash' "$rc/$(grep -c '^Hidden=false$' "$bs_dir/target.desktop" 2>/dev/null)" '0/1'
cp "$source" "$bs_dir/source.desktop"
desktop_make_override "$bs_dir/source.desktop" "$TMP/plain-target.desktop" false >/dev/null 2>&1; rc=$?
check 'system override works when only the source path has a backslash' "$rc/$(grep -c '^Hidden=false$' "$TMP/plain-target.desktop" 2>/dev/null)" '0/1'
cp "$source" "$bs_dir/same.desktop"
desktop_set_user_state "$bs_dir/same.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'a user entry whose path has a backslash can be enabled' "$rc/$(grep -c '^Hidden=false$' "$bs_dir/same.desktop")" '0/1'

# 6b. Enabling a system entry with an existing symlink override must not delete it.
symlink_override="$TMP/symlink-override.desktop"
symlink_target="$TMP/symlink-target"
printf 'keep-this-target\n' > "$symlink_target"
ln -s "$symlink_target" "$symlink_override"
cat > "$TMP/system-default-enabled.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Default Enabled
Exec=/usr/bin/default-enabled
Hidden=false
EOF
system_autostart_apply "$symlink_override" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'system override refuses symlink removal on enable' "$rc" 1
check 'system override keeps symlink intact' "$(test -L "$symlink_override" && echo 1 || echo 0)" 1
check 'system override does not alter symlink target' "$(cat "$symlink_target")" 'keep-this-target'

# 6c. Arbitrary user files sharing the system basename are never overwritten or deleted.
untrusted_override="$TMP/untrusted.desktop"
untrusted_before=$'[Desktop Entry]\nName=User data\nBroken line without equals\n'
printf '%s' "$untrusted_before" > "$untrusted_override"
system_autostart_apply "$untrusted_override" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'system override rejects an unmarked user file on enable' "$rc" 1
check 'system override keeps unmarked user content on enable' "$(cmp -s "$untrusted_override" <(printf '%s' "$untrusted_before") && echo 1 || echo 0)" 1
system_autostart_apply "$untrusted_override" "$source" FALSE >/dev/null 2>&1; rc=$?
check 'system override rejects an unmarked user file on disable' "$rc" 1
check 'system override keeps unmarked user content on disable' "$(cmp -s "$untrusted_override" <(printf '%s' "$untrusted_before") && echo 1 || echo 0)" 1

# A generated state-only override must survive if the system source disappears during the decision window.
race_source="$TMP/race-source.desktop"
race_override="$TMP/race-override.desktop"
cat > "$race_source" <<'EOF'
[Desktop Entry]
Type=Application
Name=Race Source
Exec=/usr/bin/race-source
Hidden=false
EOF
system_autostart_apply "$race_override" "$race_source" FALSE >/dev/null 2>&1; rc=$?
check 'race fixture creates a generated state override' "$rc" 0
cat > "$BIN/sha256sum" <<SH
#!/bin/bash
count_file="$TMP/race-hash-count"
n=\$(cat "\$count_file" 2>/dev/null || echo 0)
n=\$((n+1))
printf '%s' "\$n" > "\$count_file"
if [[ "\$1" == "$race_source" && "\$n" -eq 2 ]]; then
    rm -f -- "$race_source"
fi
exec /usr/bin/sha256sum "\$@"
SH
chmod +x "$BIN/sha256sum"; hash -r
system_autostart_apply "$race_override" "$race_source" TRUE >/dev/null 2>"$TMP/race-error"; rc=$?
check 'system override aborts when source disappears during removal check' "$rc" 1
check 'system override reports source race' "$(grep -Fxc 'The autostart file changed before the update was committed. Nothing was modified; the list will reload so you can review the current state.' "$TMP/race-error" 2>/dev/null || true)" 1
check 'generated state override survives source race' "$(test -e "$race_override" && echo 1 || echo 0)" 1
rm -f "$BIN/sha256sum"; hash -r

# New generated state-only overrides carry an explicit marker and can be removed safely.
generated_state="$TMP/generated-state.desktop"
system_autostart_apply "$generated_state" "$TMP/system-default-enabled.desktop" FALSE >/dev/null 2>&1; rc=$?
check 'new state-only override is created successfully' "$rc" 0
check 'new state-only override has a generated marker' "$(grep -Fxc 'X-AutostartManager-Generated=true' "$generated_state")" 1
system_autostart_apply "$generated_state" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'generated state-only override is safely removed' "$rc" 0
check 'generated state-only override no longer exists' "$(test ! -e "$generated_state" && echo 1 || echo 0)" 1

# Adding user content to a marked state-only override makes it untrusted.
edited_state="$TMP/edited-state.desktop"
system_autostart_apply "$edited_state" "$TMP/system-default-enabled.desktop" FALSE >/dev/null 2>&1; rc=$?
check 'edited state-only override is initially generated' "$rc" 0
printf '%s\n' 'X-Custom=user-edit' >> "$edited_state"
system_autostart_apply "$edited_state" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'edited state-only override is not deleted' "$(test -e "$edited_state" && echo 1 || echo 0)" 1
check 'edited state-only override is rejected as untrusted' "$rc" 1

# The generated marker requires the exact trailing newline as well.
no_nl_state="$TMP/no-final-newline.desktop"
printf '%s' $'[Desktop Entry]\nHidden=true\nX-AutostartManager-Generated=true' > "$no_nl_state"
system_autostart_apply "$no_nl_state" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'state-only override without final newline is rejected' "$rc" 1
check 'state-only override without final newline is preserved' "$(test -e "$no_nl_state" && echo 1 || echo 0)" 1

# The exact pre-marker two-line form remains recognized for backwards compatibility.
legacy_state="$TMP/legacy-state.desktop"
printf '%s\n' '[Desktop Entry]' 'Hidden=true' > "$legacy_state"
system_autostart_apply "$legacy_state" "$TMP/system-default-enabled.desktop" TRUE >/dev/null 2>&1; rc=$?
check 'legacy state-only override is still recognized' "$rc" 0
check 'legacy state-only override is removed when enabled' "$(test ! -e "$legacy_state" && echo 1 || echo 0)" 1

# A generated full-copy override may be edited by the user without losing ownership of its content.
full_edit_override="$TMP/full-edit.desktop"
cat > "$source" <<'EOF'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=true
X-GNOME-Autostart-enabled=false
X-Custom=system
EOF
system_autostart_apply "$full_edit_override" "$source" TRUE >/dev/null 2>&1; rc=$?
check 'generated full override is created from a disabled system entry' "$rc" 0
check 'generated full override carries its marker' "$(grep -Fxc 'X-AutostartManager-Generated=true' "$full_edit_override")" 1
sed -i 's/^X-Custom=system$/X-Custom=user-edit/' "$full_edit_override"
cat > "$source" <<'EOF'
[Desktop Entry]
Type=Application
Name=System App
Exec=/usr/bin/system-app
Hidden=false
X-GNOME-Autostart-enabled=true
X-Custom=system-new
EOF
system_autostart_apply "$full_edit_override" "$source" TRUE >/dev/null 2>&1; rc=$?
check 'edited generated full override is preserved when system becomes enabled' "$rc" 0
check 'edited generated full override keeps user content' "$(grep -Fxc 'X-Custom=user-edit' "$full_edit_override")" 1

# A valid DBus-activatable override may omit Exec= and is still complete user content.
dbus_override="$TMP/dbus-override.desktop"
cat > "$dbus_override" <<'EOF'
[Desktop Entry]
Type=Application
Name=User DBus App
DBusActivatable=true
Hidden=true
X-Custom=user-dbus
EOF
cat > "$source" <<'EOF'
[Desktop Entry]
Type=Application
Name=System DBus App
DBusActivatable=true
Hidden=false
EOF
system_autostart_apply "$dbus_override" "$source" TRUE >/dev/null 2>&1; rc=$?
check 'DBus-activatable override without Exec is treated as complete' "$rc" 0
check 'DBus-activatable override preserves user content' "$(grep -Fxc 'X-Custom=user-dbus' "$dbus_override")" 1
check 'DBus-activatable override is enabled by changing Hidden' "$(grep -Fxc 'Hidden=false' "$dbus_override")" 1

# 7. Cron backups force owner-only mode even when an older backup is too permissive.
cron_state="$TMP/state"
mkdir -p "$cron_state/autostart-manager"
old_umask=$(umask)
umask 022
printf 'old\n' > "$cron_state/autostart-manager/crontab.bak"
chmod 644 "$cron_state/autostart-manager/crontab.bak"
printf 'new\n' > "$TMP/crontab.input"
XDG_STATE_HOME="$cron_state" cron_backup "$TMP/crontab.input"
check 'cron backup overwrites existing backup content' "$(cat "$cron_state/autostart-manager/crontab.bak")" 'new'
check 'cron backup forces owner-only mode' "$(stat -c '%a' "$cron_state/autostart-manager/crontab.bak")" 600

# Existing state-directory permissions must not be changed by the backup helper.
chmod 750 "$cron_state/autostart-manager"
XDG_STATE_HOME="$cron_state" cron_backup "$TMP/crontab.input"
check 'cron backup preserves existing state-directory mode' "$(stat -c '%a' "$cron_state/autostart-manager")" 750
umask "$old_umask"

# 8. Malformed desktop structure is rejected before a mutation.
invalid="$TMP/invalid.desktop"
cat > "$invalid" <<'EOF'
[Desktop Entry]
Type=Application
Name=Demo
Hidden=false
Hidden=true
OnlyShowIn=Cinnamon;
NotShowIn=GNOME;
EOF
invalid_before=$(cat "$invalid")
desktop_set_user_state "$invalid" FALSE >/dev/null 2>&1; rc=$?
check 'duplicate/ambiguous desktop keys are rejected' "$rc" 1
cat > "$TMP/localized-no-base.desktop" <<'EOF'
[Desktop Entry]
Name[es]=Solo localizado
EOF
check 'localized desktop key without base is rejected' "$(desktop_validate "$TMP/localized-no-base.desktop" >/dev/null 2>&1; echo $?)" 1
cat > "$TMP/bad-group-name.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Bad Group
Exec=/usr/bin/example

[Bad[Group]
Key=value
EOF
check 'desktop group names reject brackets' "$(desktop_validate "$TMP/bad-group-name.desktop" >/dev/null 2>&1; echo $?)" 1
check 'invalid desktop file remains unchanged' "$(cat "$invalid")" "$invalid_before"

escaped="$TMP/escaped.desktop"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=File\sManager' 'Exec=/usr/bin/file-manager' > "$escaped"
LANG_UI=en
check 'desktop name escapes are decoded' "$(get_desktop_name "$escaped")" 'File Manager'
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Back\\slash\sand\ttab' 'Exec=/usr/bin/file-manager' > "$escaped"
check 'desktop name decodes an escaped backslash to a single backslash' "$(get_desktop_name "$escaped")" $'Back\\slash and\ttab'

created="$TMP/newdir/nested/file"
umask 022
atomic_write "$created" $'content\n' >/dev/null 2>&1; rc=$?
check 'atomic write creates a missing destination path' "$rc" 0
check 'atomic write creates the new parent with mode 700' "$(stat -c '%a' "$TMP/newdir/nested")" 700
check 'atomic write creates every missing intermediate directory with mode 700' "$(stat -c '%a' "$TMP/newdir")" 700
existing_dir="$TMP/existing-755"; mkdir "$existing_dir"; chmod 755 "$existing_dir"
atomic_write "$existing_dir/file" $'content\n' >/dev/null 2>&1
check 'atomic write never changes the mode of an existing directory' "$(stat -c '%a' "$existing_dir")" 755

# 9. PKEXEC diagnostics are documented and localized.
for lang in en es; do
    LANG_UI="$lang"
    check "$lang desktop concurrency message is non-empty" "$([[ -n "$(msg desktop_changed)" ]] && echo 1 || echo 0)" 1
done

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
