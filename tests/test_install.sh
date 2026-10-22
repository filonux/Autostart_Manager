#!/bin/bash
# --install: files, manifest, idempotence, refusals and failure recovery,
# always against a throwaway HOME.
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
SCRIPT_VERSION=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SH=$(command -v bash)
MOCK="$TMP/mock"
mkdir -p "$MOCK"
for tool in zenity systemctl crontab pgrep xdg-open pkexec; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$tool" "$TMP" > "$MOCK/$tool"
    chmod +x "$MOCK/$tool"
done

MOCK_PATH="$MOCK:$PATH"

pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

OUT="" ERR="" RC=0
# run HOME [VAR=VALUE ...] -- ARGS...   (a fresh environment; PATH holds the mocks)
run() {
    local home="$1"; shift
    local -a envs=()
    while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    env -i PATH="${RUN_PATH:-$MOCK_PATH}" HOME="$home" LANG=C.UTF-8 AUTOSTART_MANAGER_TEST=1 \
        "${envs[@]}" "$SH" "${RUN_SCRIPT:-$SCRIPT}" "$@" > "$TMP/out" 2> "$TMP/err"
    RC=$?
    OUT=$(<"$TMP/out"); ERR=$(<"$TMP/err")
}

# Call a function of the script in a subshell that sourced it.
in_script() {
    ( export PATH="$MOCK_PATH" AUTOSTART_MANAGER_TEST=1 LANG=C.UTF-8 LC_ALL=C.UTF-8
      # shellcheck source=../script/Autostart_Manager.sh
      source "$SCRIPT"
      "$@" )
}

new_home() { local h="$TMP/$1"; mkdir -p "$h"; printf '%s' "$h"; }
modes() { stat -c '%a' -- "$@" | tr '\n' ' '; }
manifest_dirs() { awk -F'\t' -v h="$1/" '$1 == "D" { sub(h, "", $3); print $3 }' "$2" | sort | tr '\n' ' '; }

# --- first install (home with a space) -----------------------------------
H=$(new_home 'home one')
M="$H/.local/share/autostart-manager/install.manifest"
BIN="$H/.local/bin/autostart-manager"
DESK="$H/.local/share/applications/autostart-manager.desktop"
ICON="$H/.local/share/icons/hicolor/128x128/apps/autostart-manager.png"
run "$H" -- --install
dialogs=$([[ -e "$TMP/calls.log" ]] && echo shown || echo none)
check 'install: the script declares a x.y.z version' "$([[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo yes || echo no)" yes
check 'install: first run succeeds' "$RC" 0
check 'install: first run reports the version' "$OUT" "$(printf 'Autostart Manager %s installed for your user:\n  ~/.local/bin/autostart-manager\n  ~/.local/share/applications/autostart-manager.desktop\n  ~/.local/share/icons/hicolor/128x128/apps/autostart-manager.png' "$SCRIPT_VERSION")"
check 'install: the installed program is identical to the source' "$(cmp -s "$SCRIPT" "$BIN" && echo same)" same
check 'install: modes are 755, 644, 644 and 600' "$(modes "$BIN" "$DESK" "$ICON" "$M")" '755 644 644 600 '
check 'install: the icon is a 128x128 PNG' "$(python3 - "$ICON" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read(24)
print('ok' if d[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', d[16:24]) == (128, 128) else 'bad')
PY
)" ok
check 'install: the icon is the embedded one' "$(cmp -s <(in_script embedded_icon_b64 | base64 -d) "$ICON" && echo same)" same
check 'install: the launcher passes the desktop validator' "$(in_script desktop_validate "$DESK" && echo valid)" valid
if command -v desktop-file-validate >/dev/null 2>&1; then
    check 'install: the launcher passes desktop-file-validate without hints' "$(desktop-file-validate "$DESK" 2>&1)" ''
elif [[ "${REQUIRE_DESKTOP_VALIDATE:-0}" == 1 ]]; then
    check 'install: desktop-file-validate is installed (REQUIRE_DESKTOP_VALIDATE=1)' missing installed
else
    printf 'SKIP: desktop-file-validate (package desktop-file-utils) is not installed.\n'
fi
# Two main categories would list the launcher twice in the application menu.
check 'install: the launcher belongs to one main menu category' "$(python3 - "$DESK" <<'PY'
import sys
main = {'AudioVideo', 'Audio', 'Video', 'Development', 'Education', 'Game', 'Graphics',
        'Network', 'Office', 'Science', 'Settings', 'System', 'Utility'}
line = next(l for l in open(sys.argv[1], encoding='utf-8') if l.startswith('Categories='))
print(len(main & set(line.strip()[11:].split(';'))))
PY
)" 1
check 'install: the manifest lists the three files with their SHA-256' "$(
    n=0 bad=0
    while IFS=$'\t' read -r kind hash path; do
        [[ "$kind" == F ]] || continue
        n=$((n + 1))
        [[ "$(sha256sum -- "$path" | cut -d' ' -f1)" == "$hash" ]] || bad=$((bad + 1))
    done < "$M"
    echo "$n/$bad")" '3/0'
check 'install: the manifest records exactly the directories it created' "$(manifest_dirs "$H" "$M")" \
    '.local .local/bin .local/share .local/share/applications .local/share/autostart-manager .local/share/icons .local/share/icons/hicolor .local/share/icons/hicolor/128x128 .local/share/icons/hicolor/128x128/apps '
check 'install: new directories are private (0700)' "$(find "$H/.local" -type d -printf '%m\n' | sort -u | tr '\n' ' ')" '700 '
check 'install: no dialog is shown' "$dialogs" none

# --- second run: nothing changes ----------------------------------------
before=$(find "$H" -printf '%p|%i|%m|%T@\n' | sort)
run "$H" -- --install
check 'install: a second run succeeds' "$RC" 0
check 'install: a second run says it is up to date' "$OUT" "Autostart Manager $SCRIPT_VERSION is already installed and up to date; nothing changed."
check 'install: a second run changes nothing' "$(find "$H" -printf '%p|%i|%m|%T@\n' | sort | cmp -s - <(printf '%s\n' "$before") && echo same)" same
check 'install: no temporary files are left behind' "$(find "$H" -name '*.tmp.*' | wc -l)" 0
run "$H" -- --lang es --install
check 'install: messages follow --lang' "$OUT" "Autostart Manager $SCRIPT_VERSION ya está instalado y al día; no se ha cambiado nada."

# --- reinstall from a different script -----------------------------------
sed 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$SCRIPT" > "$TMP/newer.sh"
RUN_SCRIPT="$TMP/newer.sh" run "$H" -- --install
check 'install: reinstall from another script succeeds' "$RC" 0
check 'install: reinstall replaces the program' "$(cmp -s "$TMP/newer.sh" "$BIN" && echo same)" same
check 'install: reinstall keeps the directories it created' "$(manifest_dirs "$H" "$M" | wc -w)" 9
check 'install: reinstall updates the manifest hash' "$(awk -F'\t' -v p="$BIN" '$3 == p { print $2 }' "$M")" "$(sha256sum "$BIN" | cut -d' ' -f1)"
printf '# edited\n' >> "$BIN"
run "$H" -- --install
check 'install: a modified copy owned by the manifest is replaced' "$(cmp -s "$SCRIPT" "$BIN" && echo same)" same
RUN_SCRIPT="$BIN" run "$H" -- --install
check 'install: the installed copy can reinstall itself' "$RC/$OUT" "0/Autostart Manager $SCRIPT_VERSION is already installed and up to date; nothing changed."
# The manifest is current here, so only the content comparison can notice an edit.
tampered=''
for f in "$BIN" "$DESK" "$ICON"; do
    cp -- "$f" "$TMP/original"
    printf '# edited\n' >> "$f"
    run "$H" -- --install
    cmp -s "$TMP/original" "$f" || tampered+="${f##*/} "
done
check 'install: a tampered file is restored while the manifest is current' "$tampered" ''
chmod 600 "$BIN"
run "$H" -- --install
check 'install: a changed mode is repaired' "$(modes "$BIN")" '755 '

# --- existing directories are left alone ---------------------------------
H2=$(new_home 'home two')
mkdir -p "$H2/.local/share" "$H2/.local/bin"
chmod 755 "$H2/.local/share"
chmod 750 "$H2/.local/bin"
run "$H2" -- --install
check 'install: existing directories keep their modes' "$(modes "$H2/.local/share" "$H2/.local/bin")" '755 750 '
check 'install: existing directories are not recorded' "$(manifest_dirs "$H2" "$H2/.local/share/autostart-manager/install.manifest")" \
    '.local/share/applications .local/share/autostart-manager .local/share/icons .local/share/icons/hicolor .local/share/icons/hicolor/128x128 .local/share/icons/hicolor/128x128/apps '

# --- refusals write nothing ----------------------------------------------
H3=$(new_home 'home three')
mkdir -p "$H3/.local/bin"
printf 'my own tool\n' > "$H3/.local/bin/autostart-manager"
run "$H3" -- --install
check 'install: a foreign file makes it fail' "$RC" 1
check 'install: a foreign file is reported' "$ERR" "A file that Autostart Manager did not install already exists; leaving it untouched: ~/.local/bin/autostart-manager"
check 'install: a foreign file is never overwritten' "$(<"$H3/.local/bin/autostart-manager")" 'my own tool'
check 'install: a refused install writes nothing else' "$(find "$H3" -mindepth 1 | wc -l)" 3

H4=$(new_home 'home four')
mkdir -p "$H4/.local/share/applications"
printf 'my launcher\n' > "$H4/.local/share/applications/autostart-manager.desktop"
run "$H4" -- --install
check 'install: conflicts are detected before anything is written' "$RC/$(find "$H4/.local" -name 'autostart-manager' | wc -l)" '1/0'

H5=$(new_home 'home five')
mkdir -p "$H5/.local/bin"
ln -s /nonexistent "$H5/.local/bin/autostart-manager"
run "$H5" -- --install
check 'install: a symbolic link is refused and kept' "$RC/$(readlink "$H5/.local/bin/autostart-manager")" '1//nonexistent'
check 'install: the symbolic link refusal is explained' "$ERR" 'Not a regular file (symbolic link?); leaving it untouched: ~/.local/bin/autostart-manager'

H6=$(new_home 'home six')
mkdir -p "$H6/.local/bin"
cp "$SCRIPT" "$H6/.local/bin/autostart-manager"
run "$H6" -- --install
check 'install: an identical existing file is adopted' "$RC/$(awk -F'\t' '$1 == "F"' "$H6/.local/share/autostart-manager/install.manifest" | wc -l)" '0/3'

run 'relative/home' -- --install
check 'install: a relative HOME is refused' "$RC/$ERR" '1/HOME must be an absolute path.'
check 'install: a missing HOME is refused' "$(env -u HOME PATH="$MOCK_PATH" AUTOSTART_MANAGER_TEST=1 "$SH" "$SCRIPT" --install 2>&1 >/dev/null; echo "rc=$?")" "$(printf 'HOME must be an absolute path.\nrc=1')"
run "$TMP/bad"$'\n'"home" -- --install
check 'install: control characters in the path are refused' "$RC" 1
check 'install: nothing is created for a refused path' "$([[ -e "$TMP/bad" ]] && echo created || echo none)" none
try_as_root() {
    # shellcheck disable=SC2329  # called by install_main
    install_is_root() { return 0; }
    HOME="$TMP/rootless" AUTOSTART_MANAGER_TEST=0 install_main
}
check 'install: root is refused outside the test harness' "$(in_script try_as_root 2>&1; echo "rc=$?")" "$(printf 'Installing and uninstalling are per-user only: run them without sudo or root.\nrc=1')"
check 'install: a refused root install creates nothing' "$([[ -e "$TMP/rootless" ]] && echo created || echo none)" none
run "$H" -- --install extra
check 'install: arguments after --install are rejected' "$RC/$ERR" '2/Unrecognized argument: extra. Use --help to see usage.'

# --- environment ---------------------------------------------------------
H7=$(new_home 'home seven')
run "$H7" XDG_DATA_HOME="$TMP/xdg data" -- --install
check 'install: an absolute XDG_DATA_HOME is honored' "$(find "$TMP/xdg data" -type f | sort | sed "s#$TMP/xdg data/##" | tr '\n' ' ')" \
    'applications/autostart-manager.desktop autostart-manager/install.manifest icons/hicolor/128x128/apps/autostart-manager.png '
check 'install: the program stays in ~/.local/bin' "$([[ -x "$H7/.local/bin/autostart-manager" ]] && echo yes)" yes
H8=$(new_home 'home eight')
run "$H8" XDG_DATA_HOME=relative/share -- --install
check 'install: a relative XDG_DATA_HOME is ignored' "$RC/$([[ -f "$H8/.local/share/autostart-manager/install.manifest" ]] && echo default)" '0/default'

H9=$(new_home 'home nine')
run "$H9" -- --install
# shellcheck disable=SC2088  # the message shows a literal ~
check 'install: a PATH without ~/.local/bin gets a hint' "$ERR" "$(printf '~/.local/bin is not in your PATH: the menu launcher works anyway, but add that directory to your PATH to run "autostart-manager" from a terminal.')"
H10=$(new_home 'home ten')
RUN_PATH="$H10/.local/bin:$MOCK_PATH" run "$H10" -- --install
check 'install: no hint when ~/.local/bin is in PATH' "$ERR" ''

# --- zenity is optional for installing -----------------------------------
NOZEN="$TMP/nozen"
mkdir -p "$NOZEN"
for tool in awk base64 basename cat chmod cp cut dirname grep head locale mkdir mktemp mv rm sed sort stat sha256sum tr; do
    ln -s "$(command -v "$tool")" "$NOZEN/$tool"
done
printf '#!/bin/sh\nexit 0\n' > "$NOZEN/apt-get"
chmod +x "$NOZEN/apt-get"
H11=$(new_home 'home eleven')
RUN_PATH="$NOZEN" run "$H11" -- --install
check 'install: works without zenity' "$RC/$([[ -x "$H11/.local/bin/autostart-manager" ]] && echo installed)" '0/installed'
check 'install: a missing zenity is reported with the install command' "$(grep -c 'sudo apt install zenity' <<< "$ERR")" 1

# --- an interrupted install can be finished ------------------------------
H12=$(new_home 'home twelve')
mkdir -p "$H12/.local/share"
: > "$H12/.local/share/icons"
run "$H12" -- --install
check 'install: a failing step stops with a hint' "$RC/${ERR##*$'\n'}" '1/Installation did not complete. Run --install again to finish it.'
check 'install: the manifest is written before the files' "$(awk -F'\t' '$1 == "F"' "$H12/.local/share/autostart-manager/install.manifest" | wc -l)" 3
rm -f "$H12/.local/share/icons"
run "$H12" -- --install
check 'install: running it again finishes the job' "$RC/$([[ -f "$H12/.local/share/icons/hicolor/128x128/apps/autostart-manager.png" ]] && echo icon)" '0/icon'

# --- launcher quoting ------------------------------------------------------
# shellcheck disable=SC2016  # literal $ and backtick are the point
HW=$(new_home 'we ird "q" $d \b `t` %p')
run "$HW" -- --install
check 'install: a hostile HOME installs' "$RC" 0
check 'install: the launcher Exec round-trips the install path' "$(python3 - "$HW/.local/share/applications/autostart-manager.desktop" "$HW/.local/bin/autostart-manager" <<'PY'
import re, sys
raw = next(l for l in open(sys.argv[1], encoding='utf-8') if l.startswith('Exec=')).rstrip('\n')[5:]
value = re.sub(r'\\(.)', lambda m: {'s': ' ', 'n': '\n', 't': '\t', 'r': '\r', '\\': '\\'}.get(m.group(1), m.group(0)), raw)
assert value.startswith('"') and value.endswith('"'), value
out, i, inner = [], 0, value[1:-1]
while i < len(inner):
    c = inner[i]
    if c == '\\':
        out.append(inner[i + 1]); i += 2
    elif c in '"`$':
        sys.exit('unescaped ' + c)
    else:
        out.append(c); i += 1
print('ok' if ''.join(out).replace('%%', '%') == sys.argv[2] else 'bad')
PY
)" ok

# --- help ------------------------------------------------------------------
run "$H" -- --help
check 'install: the English help documents --install and --uninstall' "$(grep -cE -- '^ {6}--(un)?install ' <<< "$OUT")" 2
run "$H" -- --lang es --help
check 'install: the Spanish help documents --install and --uninstall' "$(grep -cE -- '^ {6}--(un)?install ' <<< "$OUT")" 2

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
