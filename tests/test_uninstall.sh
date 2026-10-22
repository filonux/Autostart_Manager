#!/bin/bash
# --uninstall: removal without leftovers, protection of user data and modified
# files, crontab backup handling; always against a throwaway HOME.
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SH=$(command -v bash)
MOCK="$TMP/mock"
mkdir -p "$MOCK"
for tool in zenity systemctl crontab pgrep xdg-open pkexec; do
    printf '#!/bin/bash\nexit 0\n' > "$MOCK/$tool"
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
# run HOME [VAR=VALUE ...] -- ARGS...   (a fresh environment, no terminal on stdin)
run() {
    local home="$1"; shift
    local -a envs=()
    while (( $# )) && [[ "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    env -i PATH="$MOCK_PATH" HOME="$home" LANG=C.UTF-8 AUTOSTART_MANAGER_TEST=1 \
        "${envs[@]}" "$SH" "${RUN_SCRIPT:-$SCRIPT}" "$@" > "$TMP/out" 2> "$TMP/err" < /dev/null
    RC=$?
    OUT=$(<"$TMP/out"); ERR=$(<"$TMP/err")
}

# ask_run HOME ANSWER [OPTION ...]: --uninstall on a pseudo-terminal that answers
# ANSWER to the question. Prints the terminal output and "rc=N".
ask_run() {
    PATH="$MOCK_PATH" python3 - "$SH" "$SCRIPT" "$@" <<'PY'
import os, pty, select, sys
sh, script, home, answer, *opts = sys.argv[1:]
env = {'PATH': os.environ['PATH'], 'HOME': home, 'LANG': 'C.UTF-8', 'AUTOSTART_MANAGER_TEST': '1'}
pid, fd = pty.fork()
if pid == 0:
    os.execve(sh, [sh, script, *opts, '--uninstall'], env)
out, sent = b'', False
while select.select([fd], [], [], 15)[0]:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
    if not sent and out.rstrip().endswith(b']'):
        os.write(fd, answer.encode() + b'\n')
        sent = True
_, status = os.waitpid(pid, 0)
print(out.decode().replace('\r', '').strip())
print('rc=%d' % (os.waitstatus_to_exitcode(status) if hasattr(os, 'waitstatus_to_exitcode') else status >> 8))
PY
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
tree() { find "$1" -mindepth 1 | LC_ALL=C sort | sed "s#^$1/##" | tr '\n' ' '; }
files() { find "$1" -type f | LC_ALL=C sort | sed "s#^$1/##" | tr '\n' ' '; }
paths() {
    BIN="$1/.local/bin/autostart-manager"
    MAN="$1/.local/share/autostart-manager/install.manifest"
    BAK="$1/.local/state/autostart-manager/crontab.bak"
}
install_into() { run "$1" -- --install; }
make_backup() { mkdir -p "$(dirname "$BAK")"; printf '* * * * * true\n' > "$BAK"; chmod 600 "$BAK"; }
state() { [[ -e "$1" ]] && echo kept || echo gone; }

# --- a plain install/uninstall cycle leaves nothing --------------------------
H=$(new_home 'home one'); paths "$H"
install_into "$H"
run "$H" -- --uninstall
check 'uninstall: a plain uninstall succeeds' "$RC" 0
check 'uninstall: it lists what it removed' "$OUT" "$(printf 'Autostart Manager uninstalled. Removed:\n  ~/.local/bin/autostart-manager\n  ~/.local/share/applications/autostart-manager.desktop\n  ~/.local/share/icons/hicolor/128x128/apps/autostart-manager.png\n  ~/.local/share/autostart-manager/install.manifest')"
check 'uninstall: nothing is left in HOME' "$(find "$H" -mindepth 1 | wc -l)" 0
check 'uninstall: a plain uninstall is silent on stderr' "$ERR" ''
install_into "$H"
run "$H" -- --lang es --uninstall
check 'uninstall: messages follow --lang' "${OUT%%$'\n'*}" 'Autostart Manager desinstalado. Eliminado:'

# --- nothing installed -------------------------------------------------------
H=$(new_home 'home none')
run "$H" -- --uninstall
check 'uninstall: with nothing installed it says so' "$RC/$OUT" '0/Autostart Manager is not installed (~/.local/share/autostart-manager/install.manifest does not exist): nothing to remove.'
check 'uninstall: with nothing installed it creates nothing' "$(find "$H" -mindepth 1 | wc -l)" 0
run "$H" -- --lang es --uninstall
check 'uninstall: the nothing-to-remove message is translated' "$OUT" 'Autostart Manager no está instalado (no existe ~/.local/share/autostart-manager/install.manifest): no hay nada que eliminar.'

# --- XDG_DATA_HOME differs between install and uninstall ------------------
H=$(new_home 'home xdg'); paths "$H"
run "$H" XDG_DATA_HOME="$TMP/xdg data" -- --install
run "$H" -- --uninstall
check 'uninstall: with another XDG_DATA_HOME it names the manifest it looked for' "$RC/$OUT" '0/Autostart Manager is not installed (~/.local/share/autostart-manager/install.manifest does not exist): nothing to remove.'
check 'uninstall: with another XDG_DATA_HOME the installed program stays' "$(state "$BIN")" kept
run "$H" XDG_DATA_HOME="$TMP/xdg data" -- --uninstall
check 'uninstall: with the install-time XDG_DATA_HOME everything goes' "$(state "$BIN")/$(state "$TMP/xdg data")/$(find "$H" -mindepth 1 | wc -l)" gone/gone/0

# --- directories: only the ones this tool created, only when empty ---------
H=$(new_home 'home dirs'); paths "$H"
mkdir -p "$H/.local/share" "$H/.local/bin"
chmod 755 "$H/.local/share"
chmod 750 "$H/.local/bin"
install_into "$H"
printf 'mine\n' > "$H/.local/share/applications/other.desktop"
run "$H" -- --uninstall
check 'uninstall: existing directories keep their modes' "$(modes "$H/.local/share" "$H/.local/bin")" '755 750 '
check 'uninstall: a user file beside ours is untouched and keeps its directory' "$(tree "$H")" \
    '.local .local/bin .local/share .local/share/applications .local/share/applications/other.desktop '

# --- modified files are kept until --purge ---------------------------------
H=$(new_home 'home modified'); paths "$H"
install_into "$H"
printf '# mine\n' >> "$BIN"
run "$H" -- --uninstall
check 'uninstall: a modified file is kept and the run reports failure' "$RC/$(state "$BIN")" '1/kept'
check 'uninstall: the modified file is explained' "$ERR" 'Modified since installation, so it is kept (--purge deletes it anyway): ~/.local/bin/autostart-manager'
check 'uninstall: the unmodified files are removed anyway' "$(grep -c '^  ~' <<< "$OUT")" 2
check 'uninstall: the manifest stays so the job can be finished' "$(files "$H")" '.local/bin/autostart-manager .local/share/autostart-manager/install.manifest '
run "$H" -- --uninstall --purge
check 'uninstall: --purge removes the modified file too' "$RC/$(find "$H" -mindepth 1 | wc -l)" '0/0'

# --- what the manifest does not own is never touched ---------------------
H=$(new_home 'home foreign'); paths "$H"
mkdir -p "$H/.local/bin"
printf 'my own tool\n' > "$BIN"
run "$H" -- --uninstall --purge
check 'uninstall: a file outside the manifest is never removed, not even with --purge' "$RC/$(<"$BIN")" '0/my own tool'
check 'uninstall: with no manifest there is nothing to remove' "$OUT" 'Autostart Manager is not installed (~/.local/share/autostart-manager/install.manifest does not exist): nothing to remove.'

H=$(new_home 'home link'); paths "$H"
install_into "$H"
printf 'target\n' > "$TMP/link-target"
rm -f "$BIN"
ln -s "$TMP/link-target" "$BIN"
run "$H" -- --uninstall --purge
check 'uninstall: a symbolic link is refused and kept' "$RC/$(readlink "$BIN")/$(<"$TMP/link-target")" "1/$TMP/link-target/target"
check 'uninstall: the symbolic link refusal is explained' "$ERR" 'Not a regular file (symbolic link?); leaving it untouched: ~/.local/bin/autostart-manager'

H=$(new_home 'home forged'); paths "$H"
install_into "$H"
printf 'victim\n' > "$TMP/victim"
mkdir -p "$TMP/victim-dir"
printf 'F\t%s\t%s\nD\t-\t%s\nD\t-\t%s\n' "$(sha256sum "$TMP/victim" | cut -d' ' -f1)" "$TMP/victim" "$TMP/victim-dir" "$H" >> "$MAN"
run "$H" -- --uninstall
check 'uninstall: manifest entries outside the install locations are ignored' "$RC/$([[ -f "$TMP/victim" && -d "$TMP/victim-dir" && -d "$H" ]] && echo safe)" '0/safe'

# --- interrupted install and self-removal --------------------------------
H=$(new_home 'home half'); paths "$H"
mkdir -p "$H/.local/share"
: > "$H/.local/share/icons"
install_into "$H"
run "$H" -- --uninstall
check 'uninstall: an interrupted install can be removed' "$RC/$(files "$H")" '0/.local/share/icons '

H=$(new_home 'home self'); paths "$H"
install_into "$H"
RUN_SCRIPT="$BIN" run "$H" -- --uninstall
check 'uninstall: the installed copy can remove itself' "$RC/$(find "$H" -mindepth 1 | wc -l)" '0/0'

# --- the crontab backup ----------------------------------------------------
H=$(new_home 'home cron'); paths "$H"
install_into "$H"; make_backup
run "$H" -- --uninstall
check 'uninstall: without a terminal the crontab backup is kept' "$RC/$(state "$BAK")" '0/kept'
check 'uninstall: the kept backup is reported' "$ERR" 'The crontab backup is kept (--purge deletes it): ~/.local/state/autostart-manager/crontab.bak'
install_into "$H"
run "$H" -- --uninstall --keep-config
check 'uninstall: --keep-config keeps the crontab backup' "$RC/$(state "$BAK")" '0/kept'
install_into "$H"
run "$H" -- --uninstall --purge
check 'uninstall: --purge deletes the crontab backup and its empty directory' "$RC/$(tree "$H")" '0/.local .local/state '
check 'uninstall: --purge lists the backup among the removed files' "$(tail -n 1 <<< "$OUT")" '  ~/.local/state/autostart-manager/crontab.bak'

install_into "$H"; make_backup
printf 'x\n' > "$(dirname "$BAK")/other"
run "$H" -- --uninstall --purge
check 'uninstall: only the backup goes; a directory with other files stays' "$(files "$H/.local/state")" 'autostart-manager/other '

H=$(new_home 'home state'); paths "$H"
run "$H" XDG_STATE_HOME="$TMP/xdg state" -- --uninstall --purge
check 'uninstall: nothing is removed when no backup exists' "$RC/$OUT" '0/Autostart Manager is not installed (~/.local/share/autostart-manager/install.manifest does not exist): nothing to remove.'
mkdir -p "$TMP/xdg state/autostart-manager"
printf 'x\n' > "$TMP/xdg state/autostart-manager/crontab.bak"
run "$H" XDG_STATE_HOME="$TMP/xdg state" -- --uninstall --purge
check 'uninstall: an absolute XDG_STATE_HOME is honored' "$RC/$(state "$TMP/xdg state/autostart-manager/crontab.bak")" '0/gone'
make_backup
run "$H" XDG_STATE_HOME=relative/state -- --uninstall --purge
check 'uninstall: a relative XDG_STATE_HOME is ignored' "$RC/$(state "$BAK")" '0/gone'

make_backup
mv "$BAK" "$TMP/real-backup"
ln -s "$TMP/real-backup" "$BAK"
run "$H" -- --uninstall --purge
check 'uninstall: a backup that is a symbolic link is refused' "$RC/$(readlink "$BAK")/$(state "$TMP/real-backup")" "1/$TMP/real-backup/kept"
check 'uninstall: the refused backup is reported' "$ERR" 'Could not remove: ~/.local/state/autostart-manager/crontab.bak'

# --- the question on a terminal ------------------------------------------
H=$(new_home 'home ask'); paths "$H"
for answer in y n '' yes; do
    install_into "$H"; make_backup
    answered=$(ask_run "$H" "$answer")
    case "$answer" in y|yes) expected=gone ;; *) expected=kept ;; esac
    check "uninstall: answering '${answer:-Enter}' to the question leaves the backup $expected" "$(state "$BAK")" "$expected"
done
check 'uninstall: the question names the backup' "$(grep -c 'Also delete the crontab backup (~/.local/state/autostart-manager/crontab.bak)? \[y/N\]' <<< "$answered")" 1
check 'uninstall: the question does not change the exit status' "${answered##*$'\n'}" 'rc=0'
install_into "$H"; make_backup
answered=$(ask_run "$H" s --lang es)
check 'uninstall: the Spanish question accepts s' "$(state "$BAK")/$(grep -c '¿Borrar también la copia del crontab' <<< "$answered")" 'gone/1'

# --- invalid invocations change nothing ------------------------------------
H=$(new_home 'home args'); paths "$H"
install_into "$H"
before=$(find "$H" -printf '%p|%i|%m|%T@\n' | sort)
conflicts=''
for args in '--keep-config --purge' '--purge --keep-config'; do
    # shellcheck disable=SC2086  # word splitting of the option list is intended
    run "$H" -- --uninstall $args
    conflicts+="$RC/$ERR;"
done
check 'uninstall: --keep-config and --purge exclude each other' "$conflicts" \
    '2/Use only one of --keep-config or --purge.;2/Use only one of --keep-config or --purge.;'
run "$H" -- --uninstall extra
check 'uninstall: unknown arguments are rejected' "$RC/$ERR" '2/Unrecognized argument: extra. Use --help to see usage.'
run "$H" -- --install --purge
check 'uninstall: --purge is rejected with --install' "$RC/$ERR" '2/Unrecognized argument: --purge. Use --help to see usage.'
run "$H" -- --purge
check 'uninstall: --purge alone is rejected' "$RC/$ERR" '2/Unrecognized argument: --purge. Use --help to see usage.'
check 'uninstall: rejected invocations change nothing' "$(find "$H" -printf '%p|%i|%m|%T@\n' | sort | cmp -s - <(printf '%s\n' "$before") && echo same)" same
run "$H" -- --uninstall --purge --purge
check 'uninstall: repeating an option is harmless' "$RC" 0

# --- refusals write nothing -------------------------------------------------
run 'relative/home' -- --uninstall
check 'uninstall: a relative HOME is refused' "$RC/$ERR" '1/HOME must be an absolute path.'
run "$TMP/bad"$'\n'"home" -- --uninstall
check 'uninstall: control characters in the path are refused' "$RC" 1
try_as_root() {
    # shellcheck disable=SC2329  # called by install_prepare
    install_is_root() { return 0; }
    HOME="$TMP/rootless" AUTOSTART_MANAGER_TEST=0 uninstall_main
}
check 'uninstall: root is refused outside the test harness' "$(in_script try_as_root 2>&1; echo "rc=$?")" \
    "$(printf 'Installing and uninstalling are per-user only: run them without sudo or root.\nrc=1')"

# --- help --------------------------------------------------------------------
run "$H" -- --help
check 'uninstall: the English help documents the three options' "$(grep -cE -- '^ {6}--uninstall |^ {10}--(keep-config|purge) ' <<< "$OUT")" 3
run "$H" -- --lang es --help
check 'uninstall: the Spanish help documents the three options' "$(grep -cE -- '^ {6}--uninstall |^ {10}--(keep-config|purge) ' <<< "$OUT")" 3

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
