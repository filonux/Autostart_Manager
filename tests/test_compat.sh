#!/bin/bash
# Distribution compatibility: install hints follow the host package manager and
# the missing-dependency messages stay correct in both UI languages.
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
BASH_BIN=$(command -v bash)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

mkdir -p "$TMP/bin" "$TMP/home/.config" "$TMP/etc/xdg"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/zenity"; chmod +x "$TMP/bin/zenity"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_CONFIG_DIRS="$TMP/etc/xdg"
export AUTOSTART_MANAGER_TEST=1 PATH="$TMP/bin:$PATH"
# shellcheck source=../script/Autostart_Manager.sh
source "$SCRIPT"

# A PATH that only knows the given stub commands (name:exit_status for apt-cache).
stub_path() {
    local dir name
    dir=$(mktemp -d -p "$TMP")
    for name in "$@"; do
        printf '#!/bin/bash\nexit %s\n' "${name#*:}" > "$dir/${name%%:*}"
        chmod +x "$dir/${name%%:*}"
    done
    printf '%s' "$dir"
}
hint() {   # hint <dependency> <stub...>
    local dep="$1" dir; shift
    dir=$(stub_path "$@")
    ( PATH="$dir"; install_command "$dep" )
}

check 'hint: apt installs zenity' "$(hint zenity apt-get:0)" 'sudo apt install zenity'
check 'hint: apt prefers the pkexec package when the index has it' "$(hint pkexec apt-get:0 apt-cache:0)" 'sudo apt install pkexec'
check 'hint: apt falls back to policykit-1 when the index lacks pkexec' "$(hint pkexec apt-get:0 apt-cache:1)" 'sudo apt install policykit-1'
check 'hint: apt falls back to policykit-1 without apt-cache' "$(hint pkexec apt-get:0)" 'sudo apt install policykit-1'
check 'hint: dnf installs zenity' "$(hint zenity dnf:0)" 'sudo dnf install zenity'
check 'hint: dnf installs polkit for pkexec' "$(hint pkexec dnf:0)" 'sudo dnf install polkit'
check 'hint: yum installs polkit for pkexec' "$(hint pkexec yum:0)" 'sudo yum install polkit'
check 'hint: rpm-ostree layers zenity' "$(hint zenity rpm-ostree:0)" 'rpm-ostree install zenity'
check 'hint: zypper installs zenity' "$(hint zenity zypper:0)" 'sudo zypper install zenity'
check 'hint: pacman installs polkit for pkexec' "$(hint pkexec pacman:0)" 'sudo pacman -S polkit'
check 'hint: apk installs zenity' "$(hint zenity apk:0)" 'sudo apk add zenity'
check 'hint: xbps installs zenity' "$(hint zenity xbps-install:0)" 'sudo xbps-install zenity'
check 'hint: eopkg installs polkit for pkexec' "$(hint pkexec eopkg:0)" 'sudo eopkg install polkit'
check 'hint: emerge uses the Gentoo category for zenity' "$(hint zenity emerge:0)" 'sudo emerge --ask gnome-extra/zenity'
check 'hint: emerge uses the Gentoo category for pkexec' "$(hint pkexec emerge:0)" 'sudo emerge --ask sys-auth/polkit'
check 'hint: nix installs zenity from nixpkgs' "$(hint zenity nix-env:0)" 'nix-env -iA nixpkgs.zenity'
check 'hint: apt wins when several managers exist' "$(hint zenity dnf:0 apt-get:0 pacman:0)" 'sudo apt install zenity'

unknown_status=0
( PATH="$(stub_path)"; install_command zenity >/dev/null ) || unknown_status=$?
check 'hint: an unknown package manager reports failure' "$unknown_status" 1

dep_msg() {   # dep_msg <language> <dependency> <stub...>
    local lang="$1" dep="$2" dir; shift 2
    dir=$(stub_path "$@")
    ( PATH="$dir"; LANG_UI="$lang"; dependency_message "$dep" )
}
check 'message: English zenity text carries the command' "$(dep_msg en zenity dnf:0)" '"zenity" is not installed. Install it with:  sudo dnf install zenity'
check 'message: Spanish zenity text carries the command' "$(dep_msg es zenity dnf:0)" 'Falta "zenity". Instálalo con:  sudo dnf install zenity'
check 'message: Spanish pkexec text carries the command' "$(dep_msg es pkexec pacman:0)" 'No se encontró "pkexec". Instálalo con:  sudo pacman -S polkit'
check 'message: English pkexec text carries the command' "$(dep_msg en pkexec zypper:0)" '"pkexec" is not installed, so administrator permission cannot be requested. Install it with:  sudo zypper install polkit'
check 'message: English generic zenity text without a known manager' "$(dep_msg en zenity)" '"zenity" is not installed. Install the "zenity" package with your distribution package manager.'
check 'message: Spanish generic pkexec text without a known manager' "$(dep_msg es pkexec)" 'No se encontró "pkexec". Instala el paquete polkit con el gestor de paquetes de tu distribución.'

# End to end: the real script without zenity must print the matching command.
run_without_zenity() {   # run_without_zenity <language> <stub...>
    local lang="$1" dir; shift
    dir=$(stub_path "$@")
    PATH="$dir" AUTOSTART_MANAGER_LANG="$lang" "$BASH_BIN" "$SCRIPT" 2>&1
    printf 'rc=%s\n' "$?"
}
out=$(run_without_zenity en dnf:0)
check 'startup without zenity prints the dnf command in English' "$(grep -c 'sudo dnf install zenity' <<< "$out")" 1
check 'startup without zenity exits with status 1' "$(grep -c '^rc=1$' <<< "$out")" 1
out=$(run_without_zenity es pacman:0)
check 'startup without zenity prints the pacman command in Spanish' "$(grep -c 'Falta "zenity".*sudo pacman -S zenity' <<< "$out")" 1

# Bash guard: a mutated copy with an impossible minimum must refuse to run.
too_old="$TMP/too-old.sh"
sed 's/BASH_VERSINFO\[0\] < 4 ||/BASH_VERSINFO[0] < 99 ||/' "$SCRIPT" > "$too_old"
check 'bash guard test mutates the script' "$(cmp -s "$SCRIPT" "$too_old" && echo same || echo changed)" changed
guard_rc=0; guard_out=$("$BASH_BIN" "$too_old" --version 2>&1) || guard_rc=$?
check 'bash guard refuses an older Bash with status 1' "$guard_rc" 1
check 'bash guard states the requirement in English and Spanish' \
    "$(grep -c 'requires Bash 4.4 or newer' <<< "$guard_out")/$(grep -c 'requiere Bash 4.4 o superior' <<< "$guard_out")" 1/1
check 'bash guard lets the running Bash through' "$("$BASH_BIN" "$SCRIPT" --version)" "Autostart Manager $VERSION"

# Editors: the desktop's native editor is preferred, the generic order follows.
first_editor() {   # first_editor <XDG_CURRENT_DESKTOP value>
    XDG_CURRENT_DESKTOP="$1" set_editor_list; printf '%s' "${EDITOR_LIST[0]}"
}
check 'editor: KDE prefers kate' "$(first_editor KDE)" kate
check 'editor: GNOME prefers gnome-text-editor' "$(first_editor GNOME)" gnome-text-editor
check 'editor: a GNOME derivative list prefers gnome-text-editor' "$(first_editor ubuntu:GNOME)" gnome-text-editor
check 'editor: Budgie prefers gnome-text-editor' "$(first_editor Budgie:GNOME)" gnome-text-editor
check 'editor: XFCE prefers mousepad' "$(first_editor XFCE)" mousepad
check 'editor: MATE prefers pluma' "$(first_editor MATE)" pluma
check 'editor: Cinnamon prefers xed' "$(first_editor X-Cinnamon)" xed
check 'editor: LXQt prefers featherpad' "$(first_editor LXQt)" featherpad
check 'editor: LXDE prefers leafpad' "$(first_editor LXDE)" leafpad
check 'editor: Pantheon prefers the elementary editor' "$(first_editor Pantheon)" io.elementary.code
check 'editor: COSMIC prefers cosmic-edit' "$(first_editor COSMIC)" cosmic-edit
check 'editor: desktop matching ignores case' "$(first_editor kde)" kate
check 'editor: an unknown desktop keeps the generic order' "$(first_editor Unknown)" xed
check 'editor: no desktop keeps the generic order' "$(first_editor '')" xed

pick_with() {   # pick_with <XDG_CURRENT_DESKTOP value> <stub...>
    local desktop="$1" dir; shift
    dir=$(stub_path "$@")
    ( PATH="$dir"; XDG_CURRENT_DESKTOP="$desktop"; pick_editor )
}
check 'pick_editor finds pluma on a MATE-style system' "$(pick_with MATE pluma:0 geany:0)" pluma
check 'pick_editor falls back to geany when it is the only editor' "$(pick_with GNOME geany:0)" geany
check 'pick_editor prefers the desktop editor over the generic order' "$(pick_with KDE xed:0 kate:0)" kate
check 'pick_editor uses xdg-open when no editor is installed' "$(pick_with GNOME)" xdg-open

printf '\n%d tests: %d passed, %d failed\n' "$((pass + fail))" "$pass" "$fail"
(( fail == 0 ))
