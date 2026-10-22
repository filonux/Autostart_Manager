#!/bin/bash
# MENU: Autostart Manager
# DESCRIPTION: Manage what starts with your session
# ICON: ../assets/autostart-manager.png
#
# Autostart_Manager.sh
# ---------------------------------------------------------------------------
# Graphical autostart manager for Linux desktops
#
# Copyright (C) 2026 Filonux
#
# License:
#   Autostart Manager is free software distributed under the terms of the
#   GNU General Public License version 3 (GPLv3).
#   See LICENSE.txt for the complete license text.
#
# The inventory combines:
#   - Applications from $XDG_CONFIG_HOME/autostart   (user autostart;
#                                                     default ~/.config/autostart)
#   - Applications from $XDG_CONFIG_DIRS/autostart (system autostart; default /etc/xdg)
#   - User systemd services and sockets
#   - System systemd services and sockets
#   - The user's cron table (crontab -l)
#
# Each item can be enabled or disabled from the GUI. The list can be filtered,
# and the source of each item can be opened for inspection or editing.
#
# Requirements: Bash 4.4+, zenity; optional systemd, cron/crontab, and a text
#               editor (native editor of the desktop, or xed, gedit, kate,
#               pluma, mousepad, ...; xdg-open as the last resort).
# System service changes use pkexec (PolicyKit) when administrator privileges
# are required. Dialogs use only options common to Zenity 3.44 and 4.x.
#
# Usage:  ./Autostart_Manager.sh [--install | --uninstall [--keep-config | --purge]]
#         (see --help; --install and --uninstall work per user, without root)
# ---------------------------------------------------------------------------

# Bash 4.4 is the oldest release verified against the test suite.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf 'Autostart Manager requires Bash 4.4 or newer (found %s).\nAutostart Manager requiere Bash 4.4 o superior (se encontró %s).\n' \
        "$BASH_VERSION" "$BASH_VERSION" >&2
    exit 1
fi

VERSION="2.2.0"

# A root invocation must not execute user-controlled commands from PATH. Test
# harnesses are the only exception because they deliberately inject mocks.
if [[ "$EUID" -eq 0 && "${AUTOSTART_MANAGER_TEST:-0}" != "1" ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
fi

# Bilingual UI: Spanish when the effective message locale is Spanish; English otherwise.
declare -A MSG_ES MSG_EN
msg() {
    local key="$1" lang="${LANG_UI:-en}" value
    shift
    if [[ "$lang" == "es" ]]; then value="${MSG_ES[$key]}"; else value="${MSG_EN[$key]}"; fi
    # The message tables are trusted constants, so they may act as printf formats.
    # shellcheck disable=SC2059
    if (( $# )); then printf -- "$value" "$@"; else printf '%b' "$value"; fi
}

# msg without a subshell, for loops over the inventory: the text lands in MSGV.
MSGV=""
msg_v() {
    local key="$1" lang="${LANG_UI:-en}" value
    shift
    if [[ "$lang" == "es" ]]; then value="${MSG_ES[$key]}"; else value="${MSG_EN[$key]}"; fi
    # Same trusted constants as in msg(): user data only ever arrives as arguments, never in the format.
    # shellcheck disable=SC2059
    if (( $# )); then printf -v MSGV -- "$value" "$@"; else printf -v MSGV '%b' "$value"; fi
}

MSG_ES[help_usage]='Gestor gráfico de arranque automático para escritorios Linux.\n\nUso: %s [-h|--help] [-v|--version] [-l|--toggle-language] [--lang es|en]\n       [--install | --uninstall [--keep-config | --purge]]\n\nSin argumentos, abre la interfaz gráfica (requiere zenity).\n  -h, --help              Muestra esta ayuda y termina.\n  -v, --version           Muestra la versión y termina.\n  -l, --toggle-language   Intercambia rápidamente entre español e inglés.\n      --lang es|en        Fuerza el idioma de esta ejecución.\n      --install           Instala para tu usuario (sin root): programa, lanzador e icono.\n      --uninstall         Elimina lo instalado con --install y pregunta por la copia del crontab.\n          --keep-config   Con --uninstall: conserva la copia del crontab sin preguntar.\n          --purge         Con --uninstall: borra también lo modificado y la copia del crontab.\n'
MSG_EN[help_usage]='Graphical autostart manager for Linux desktops.\n\nUsage: %s [-h|--help] [-v|--version] [-l|--toggle-language] [--lang es|en]\n       [--install | --uninstall [--keep-config | --purge]]\n\nWith no arguments, opens the graphical interface (requires zenity).\n  -h, --help              Show this help and exit.\n  -v, --version           Show the version and exit.\n  -l, --toggle-language   Quickly switch between English and Spanish.\n      --lang es|en        Force the language for this run.\n      --install           Install for your user (no root): program, launcher and icon.\n      --uninstall         Remove what --install put in place and ask about the crontab backup.\n          --keep-config   With --uninstall: keep the crontab backup without asking.\n          --purge         With --uninstall: also delete modified files and the crontab backup.\n'
MSG_ES[invalid_lang]='Idioma no válido: %s. Usa es o en.'
MSG_EN[invalid_lang]='Invalid language: %s. Use es or en.'
MSG_ES[unexpected_arg]='Argumento no reconocido: %s. Usa --help para ver el uso.'
MSG_EN[unexpected_arg]='Unrecognized argument: %s. Use --help to see usage.'
MSG_ES[missing_zenity]='Falta "zenity". Instálalo con:  %s'
MSG_EN[missing_zenity]='"zenity" is not installed. Install it with:  %s'
MSG_ES[missing_zenity_generic]='Falta "zenity". Instala el paquete "zenity" con el gestor de paquetes de tu distribución.'
MSG_EN[missing_zenity_generic]='"zenity" is not installed. Install the "zenity" package with your distribution package manager.'
MSG_ES[root_title]='⚠ Ejecutándose como root'
MSG_EN[root_title]='⚠ Running as root'
MSG_ES[root_ok]='Sí, continuar como root'
MSG_EN[root_ok]='Yes, continue as root'
MSG_ES[root_cancel]='No, salir'
MSG_EN[root_cancel]='No, exit'
MSG_ES[root_text]='Has iniciado el script como <b>root</b> (por ejemplo, con sudo).\nNo es necesario: el script solo pide la contraseña de administrador cuando la necesita.\n\nSi continúas así, el autostart de usuario y el cron que se gestionen serán los de <b>root</b>, no los de tu usuario normal.\n\n¿Quieres continuar de todas formas?'
MSG_EN[root_text]='You started the script as <b>root</b> (for example, with sudo).\nThis is not necessary: the script asks for administrator credentials only when needed.\n\nIf you continue, user autostart and cron entries managed by the script will belong to <b>root</b>, not your normal user.\n\nDo you want to continue anyway?'
MSG_ES[no_message]='(sin mensaje)'; MSG_EN[no_message]='(no message)'
MSG_ES[btn_ok]='Aceptar'; MSG_EN[btn_ok]='OK'
MSG_ES[btn_cancel]='Cancelar'; MSG_EN[btn_cancel]='Cancel'
MSG_ES[btn_yes]='Sí'; MSG_EN[btn_yes]='Yes'
MSG_ES[btn_no]='No'; MSG_EN[btn_no]='No'
MSG_ES[desktop_no_apply_only]='  [no se aplica a %s: OnlyShowIn=%s]'; MSG_EN[desktop_no_apply_only]='  [not applicable to %s: OnlyShowIn=%s]'
MSG_ES[desktop_no_apply_not]='  [no se aplica a %s: NotShowIn=%s]'; MSG_EN[desktop_no_apply_not]='  [not applicable to %s: NotShowIn=%s]'
MSG_ES[user_type]='Usuario'; MSG_EN[user_type]='User'
MSG_ES[system_type]='Sistema'; MSG_EN[system_type]='System'
MSG_ES[session_service]='Servicio de usuario'; MSG_EN[session_service]='User service'
MSG_ES[system_service]='Servicio del sistema'; MSG_EN[system_service]='System service'
MSG_ES[background]='Proceso en segundo plano'; MSG_EN[background]='Background process'
MSG_ES[critical]='CRÍTICO'; MSG_EN[critical]='CRITICAL'
MSG_ES[enabled]='✅ Activado'; MSG_EN[enabled]='✅ Enabled'
MSG_ES[disabled]='⛔ Desactivado'; MSG_EN[disabled]='⛔ Disabled'
MSG_ES[desktop_override]='  (anulado por usuario)'; MSG_EN[desktop_override]='  (overridden by user)'
MSG_ES[static_mask]='  [estático: gestionado con mask]'; MSG_EN[static_mask]='  [static: managed with mask]'
MSG_ES[cron_task]='Tarea programada'; MSG_EN[cron_task]='Scheduled task'
MSG_ES[cron_line]='línea %s del crontab'; MSG_EN[cron_line]='crontab line %s'
MSG_ES[pkexec_missing]='No se encontró "pkexec". Instálalo con:  %s'
MSG_EN[pkexec_missing]='"pkexec" is not installed, so administrator permission cannot be requested. Install it with:  %s'
MSG_ES[pkexec_missing_generic]='No se encontró "pkexec". Instala el paquete polkit con el gestor de paquetes de tu distribución.'
MSG_EN[pkexec_missing_generic]='"pkexec" is not installed, so administrator permission cannot be requested. Install the polkit package with your distribution package manager.'
MSG_ES[pkexec_timeout]='Se agotó el tiempo de espera (más de 3 minutos) para la autenticación.'
MSG_EN[pkexec_timeout]='Authentication timed out (more than 3 minutes).'
MSG_ES[pkexec_cancel]='Se canceló la ventana de contraseña de administrador.'
MSG_EN[pkexec_cancel]='The administrator password dialog was cancelled.'
MSG_ES[pkexec_fail]='La autenticación falló o no se pudo obtener el permiso necesario (contraseña incorrecta o usuario sin permisos de administrador).'
MSG_EN[pkexec_fail]='Authentication failed or the required permission could not be obtained (wrong password or a user without administrator privileges).'
MSG_ES[pkexec_unexpected]='pkexec terminó con un error inesperado (código %s).'; MSG_EN[pkexec_unexpected]='pkexec ended with an unexpected error (code %s).'
MSG_ES[pkexec_no_agent]=' No se detectó ningún agente gráfico de autenticación de PolicyKit en esta sesión. La ventana gráfica de contraseña puede no aparecer; pkexec podría recurrir a su agente textual.'
MSG_EN[pkexec_no_agent]=' No graphical PolicyKit authentication agent was detected in this session. The graphical password dialog may not appear; pkexec may fall back to its text-based agent.'
MSG_ES[cron_missing]='La tarea ya no existe en esa línea del crontab (¿se editó desde fuera?).'
MSG_EN[cron_missing]='The task no longer exists on that crontab line (was it edited outside this script?).'
MSG_ES[cron_changed]='El crontab cambió desde que se cargó la lista. No se modificó nada; la lista se recargará para que vuelvas a intentarlo.'
MSG_EN[cron_changed]='The crontab changed after the list was loaded. Nothing was modified; the list will reload so you can try again.'
MSG_ES[desktop_changed]='El archivo de autostart cambió antes de aplicar el cambio. No se modificó nada; la lista se recargará para que revises el estado actual.'
MSG_EN[desktop_changed]='The autostart file changed before the update was committed. Nothing was modified; the list will reload so you can review the current state.'
MSG_ES[target_symlink]='El archivo es un enlace simbólico, así que no se modificó. Edita directamente el destino del enlace.'
MSG_EN[target_symlink]='The file is a symbolic link, so it was not modified. Edit the link target directly.'
MSG_ES[target_not_file]='El archivo no existe o no es un archivo normal, así que no se modificó.'
MSG_EN[target_not_file]='The file is missing or is not a regular file, so it was not modified.'
MSG_ES[desktop_invalid]='El archivo .desktop no cumple la estructura requerida, así que no se modificó.'
MSG_EN[desktop_invalid]='The .desktop file has an invalid structure, so it was not modified.'
MSG_ES[desktop_untrusted_override]='El override de usuario no fue generado por este programa, así que no se modificó.'
MSG_EN[desktop_untrusted_override]='The user override was not generated by this program, so it was not modified.'
MSG_ES[lock_busy]='Otra instancia está modificando la configuración. Inténtalo de nuevo en unos segundos.'
MSG_EN[lock_busy]='Another instance is modifying the configuration. Try again in a few seconds.'
MSG_ES[unit_missing]='No se encontró el archivo de la unidad.'; MSG_EN[unit_missing]='The unit file could not be found.'
MSG_ES[untrusted_system_file]='No se abrió: el archivo no es legible y no es un archivo de sistema de confianza (de root y sin permiso de escritura para otros).'
MSG_EN[untrusted_system_file]='Not opened: the file is not readable and is not a trusted system file (owned by root and not writable by others).'
MSG_ES[cron_edit_title]='⏰ Editar cron'; MSG_EN[cron_edit_title]='⏰ Edit cron'
MSG_ES[info_title]='💬 Información'; MSG_EN[info_title]='💬 Information'
MSG_ES[cron_edit_text]='Las tareas cron se editan con:\n\n    crontab -e\n\nEjecútalo en una terminal.'
MSG_EN[cron_edit_text]='Cron tasks are edited with:\n\n    crontab -e\n\nRun it in a terminal.'
MSG_ES[browse_title]='📂 Abrir / ver elemento'; MSG_EN[browse_title]='📂 Open / view item'
MSG_ES[browse_text]='Elige el elemento cuyo origen quieres abrir o ver y pulsa Aceptar.'; MSG_EN[browse_text]='Choose the item whose source you want to open or view, then press OK.'
MSG_ES[category_missing]='Todas las categorías'; MSG_EN[category_missing]='All categories'
MSG_ES[empty_category]='No se encontraron elementos en «%s».'; MSG_EN[empty_category]='No items were found in "%s".'
MSG_ES[no_results_title]='🔍 Sin resultados'; MSG_EN[no_results_title]='🔍 No results'
MSG_ES[clear_filter]='Sí, borrar el filtro'; MSG_EN[clear_filter]='Yes, clear the filter'
MSG_ES[back]='No, volver'; MSG_EN[back]='No, go back'
MSG_ES[no_match]='Ningún elemento de «%s» coincide con el filtro «%s».\n¿Quieres borrar el filtro?'
MSG_EN[no_match]='No item in "%s" matches the filter "%s".\nDo you want to clear the filter?'
MSG_ES[checklist_text]='Marca o desmarca la casilla para activar/desactivar cada elemento.\n🔒 Crítico: revisa antes de tocarlo.\nFiltro: %s  —  mostrando %s de %s.\nAceptar aplica los cambios; Cancelar vuelve a las categorías.'
MSG_EN[checklist_text]='Check or uncheck the box to enable or disable each item.\n🔒 Critical: review it before changing it.\nFilter: %s  —  showing %s of %s.\nOK applies the changes; Cancel goes back to the categories.'
MSG_ES[col_active]='Activo'; MSG_EN[col_active]='Enabled'
MSG_ES[col_id]='ID'; MSG_EN[col_id]='ID'
MSG_ES[col_type]='Tipo'; MSG_EN[col_type]='Type'
MSG_ES[col_name]='Nombre'; MSG_EN[col_name]='Name'
MSG_ES[col_status]='Estado'; MSG_EN[col_status]='Status'
MSG_ES[col_source]='Origen'; MSG_EN[col_source]='Source'
MSG_ES[category_col]='Categoría'; MSG_EN[category_col]='Category'
MSG_ES[summary_col]='Resumen'; MSG_EN[summary_col]='Summary'
MSG_ES[find_filter]='🔍 Buscar / filtrar'; MSG_EN[find_filter]='🔍 Search / filter'
MSG_ES[open_btn]='📂 Abrir / ver origen'; MSG_EN[open_btn]='📂 Open / view source'
MSG_ES[filter_title]='🔍 Filtrar «%s»'; MSG_EN[filter_title]='🔍 Filter "%s"'
MSG_ES[filter_text]='Escribe una palabra para filtrar por nombre, estado u origen\n(déjalo vacío para ver todos).'
MSG_EN[filter_text]='Enter a word to filter by name, status, or source\n(leave blank to show all).'
MSG_ES[critical_title]='⚠ Elementos críticos'; MSG_EN[critical_title]='⚠ Critical items'
MSG_ES[critical_ok]='Sí, aplicar todos los cambios'; MSG_EN[critical_ok]='Yes, apply all changes'
MSG_ES[critical_cancel]='Cancelar todo (no cambiar nada)'; MSG_EN[critical_cancel]='Cancel all (change nothing)'
MSG_ES[critical_text]='Vas a DESACTIVAR uno o más elementos que pueden ser importantes para el sistema:\n\n%s\nAlgunos de ellos (como el agente de autenticación de PolicyKit) son necesarios para que las ventanas de contraseña de administrador funcionen correctamente en todo el sistema, no solo en este script.\n\nSi pulsas «Cancelar todo», no se aplicará NINGÚN cambio de esta pantalla y no se pedirá contraseña de administrador.\n\n¿Seguro que quieres continuar?'
MSG_EN[critical_text]='You are about to DISABLE one or more items that may be important for the system:\n\n%s\nSome of them (such as the PolicyKit authentication agent) are required for administrator password dialogs to work correctly across the system, not only in this script.\n\nIf you press "Cancel all", NO changes from this screen will be applied and no administrator password will be requested.\n\nAre you sure you want to continue?'
MSG_ES[enabled_action]='Activado'; MSG_EN[enabled_action]='Enabled'
MSG_ES[disabled_action]='Desactivado'; MSG_EN[disabled_action]='Disabled'
MSG_ES[all_ok_title]='✅ Todo correcto'; MSG_EN[all_ok_title]='✅ All good'
MSG_ES[all_ok_text]='Los cambios se aplicaron sin errores (%s en total):\n\n%s'; MSG_EN[all_ok_text]='The changes were applied without errors (%s in total):\n\n%s'
MSG_ES[applied_title]='✅ Cambios aplicados'; MSG_EN[applied_title]='✅ Changes applied'
MSG_ES[applied_text]='Los cambios se aplicaron correctamente (%s en total):\n\n%s'; MSG_EN[applied_text]='The changes were applied successfully (%s in total):\n\n%s'
MSG_ES[no_selection]='No has elegido ningún elemento.\nMarca o desmarca una casilla y pulsa Aceptar.'
MSG_EN[no_selection]='No item chosen.\nCheck or uncheck a box, then press OK.'
MSG_ES[failure_title]='⚠ Algunos cambios fallaron'; MSG_EN[failure_title]='⚠ Some changes failed'
MSG_ES[failure_text]='No se pudieron aplicar los siguientes cambios (%s en total).\n\n%s%s'; MSG_EN[failure_text]='The following changes could not be applied (%s in total).\n\n%s%s'
MSG_ES[generic_permission]='¿Has cancelado la ventana de contraseña de administrador o falta el permiso necesario?\n\n'; MSG_EN[generic_permission]='Did you cancel the administrator authentication dialog, or is the required permission missing?\n\n'
MSG_ES[no_start]='No se encontraron elementos de arranque.'; MSG_EN[no_start]='No startup items were found.'
MSG_ES[summary_item]='Elementos: %s · Desactivados: %s'; MSG_EN[summary_item]='Items: %s · Disabled: %s'
MSG_ES[search_all]='🔍 Buscar en todas las categorías'; MSG_EN[search_all]='🔍 Search all categories'
MSG_ES[menu_text]='Elige una categoría para ver y gestionar sus elementos:'; MSG_EN[menu_text]='Choose a category to view and manage its items:'
MSG_ES[main_title]='⚙ Gestor de arranque automático'; MSG_EN[main_title]='⚙ Autostart Manager'
MSG_ES[menu_exit]='Salir'; MSG_EN[menu_exit]='Exit'
MSG_ES[no_filter]='ninguno'; MSG_EN[no_filter]='none'
MSG_ES[lang_switch]='🌐 Cambiar idioma (ES ⇄ EN)'; MSG_EN[lang_switch]='🌐 Switch language (EN ⇄ ES)'
MSG_ES[lang_hint]='Selecciona y pulsa Aceptar'; MSG_EN[lang_hint]='Select, then press OK'
MSG_ES[launcher_name]='Gestor de arranque automático'; MSG_EN[launcher_name]='Autostart Manager'
MSG_ES[launcher_comment]='Gestiona lo que se inicia con la sesión'; MSG_EN[launcher_comment]='Manage what starts with your session'
MSG_ES[install_done]='Autostart Manager %s instalado para tu usuario:'; MSG_EN[install_done]='Autostart Manager %s installed for your user:'
MSG_ES[install_current]='Autostart Manager %s ya está instalado y al día; no se ha cambiado nada.'; MSG_EN[install_current]='Autostart Manager %s is already installed and up to date; nothing changed.'
MSG_ES[install_no_root]='La instalación y la desinstalación son solo para tu usuario: ejecútalas sin sudo ni root.'; MSG_EN[install_no_root]='Installing and uninstalling are per-user only: run them without sudo or root.'
MSG_ES[install_bad_home]='HOME debe ser una ruta absoluta.'; MSG_EN[install_bad_home]='HOME must be an absolute path.'
MSG_ES[install_bad_path]='No se admiten rutas con caracteres de control: %q'; MSG_EN[install_bad_path]='Refusing a path with control characters: %q'
MSG_ES[install_bad_source]='No se puede leer el script de origen: %s'; MSG_EN[install_bad_source]='Cannot read the source script: %s'
MSG_ES[install_foreign]='Ya existe un archivo que no instaló Autostart Manager; no se toca: %s'; MSG_EN[install_foreign]='A file that Autostart Manager did not install already exists; leaving it untouched: %s'
MSG_ES[install_not_regular]='No es un archivo normal (¿enlace simbólico?); no se toca: %s'; MSG_EN[install_not_regular]='Not a regular file (symbolic link?); leaving it untouched: %s'
MSG_ES[install_mismatch]='El archivo instalado no coincide con el original: %s'; MSG_EN[install_mismatch]='The installed file does not match the original: %s'
MSG_ES[install_failed]='La instalación no se completó. Repite --install para terminarla.'; MSG_EN[install_failed]='Installation did not complete. Run --install again to finish it.'
MSG_ES[install_path_hint]='%s no está en el PATH: el lanzador del menú funciona igual, pero para usar «autostart-manager» en la terminal añade ese directorio al PATH.'; MSG_EN[install_path_hint]='%s is not in your PATH: the menu launcher works anyway, but add that directory to your PATH to run "autostart-manager" from a terminal.'
MSG_ES[uninstall_done]='Autostart Manager desinstalado. Eliminado:'; MSG_EN[uninstall_done]='Autostart Manager uninstalled. Removed:'
MSG_ES[uninstall_none]='Autostart Manager no está instalado (no existe %s): no hay nada que eliminar.'; MSG_EN[uninstall_none]='Autostart Manager is not installed (%s does not exist): nothing to remove.'
MSG_ES[uninstall_modified]='Modificado desde la instalación, se conserva (--purge lo borra igualmente): %s'; MSG_EN[uninstall_modified]='Modified since installation, so it is kept (--purge deletes it anyway): %s'
MSG_ES[uninstall_failed]='No se pudo eliminar: %s'; MSG_EN[uninstall_failed]='Could not remove: %s'
MSG_ES[uninstall_ask]='¿Borrar también la copia del crontab (%s)? [s/N] '; MSG_EN[uninstall_ask]='Also delete the crontab backup (%s)? [y/N] '
MSG_ES[uninstall_state_kept]='Se conserva la copia del crontab (--purge la borra): %s'; MSG_EN[uninstall_state_kept]='The crontab backup is kept (--purge deletes it): %s'
MSG_ES[uninstall_conflict]='Usa solo una de las opciones --keep-config o --purge.'; MSG_EN[uninstall_conflict]='Use only one of --keep-config or --purge.'

# Category labels are initialized after the language is known.
init_categories() {
    if [[ "$LANG_UI" == "es" ]]; then
        CATEGORY_LABEL=([1]='Programas de Inicio' [2]='Procesos en Segundo Plano' [3]='Tareas Programadas' [4]='Servicios de Aplicaciones' [5]='Servicios del Sistema')
        CATEGORY_SHORT=([1]='Inicio' [2]='2º Plano' [3]='Programadas' [4]='Apps' [5]='Sistema')
    else
        CATEGORY_LABEL=([1]='Startup Applications' [2]='Background Processes' [3]='Scheduled Tasks' [4]='Application Services' [5]='System Services')
        CATEGORY_SHORT=([1]='Startup' [2]='Background' [3]='Scheduled' [4]='Apps' [5]='System')
    fi
    CATEGORY_ICON=([1]='🚀' [2]='🧩' [3]='⏰' [4]='📦' [5]='🔧')
}

detect_language() {
    local loc="${1:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
    loc="${loc,,}"
    [[ "$loc" == es || "$loc" == es_* || "$loc" == es.* || "$loc" == es@* ]] && echo es || echo en
}

LANG_SYSTEM="$(detect_language)"
LANG_UI="${AUTOSTART_MANAGER_LANG:-$LANG_SYSTEM}"
[[ "$LANG_UI" == es || "$LANG_UI" == en ]] || LANG_UI="$LANG_SYSTEM"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        -l|--toggle-language)
            [[ "$LANG_UI" == es ]] && LANG_UI=en || LANG_UI=es
            shift
            ;;
        --lang)
            [[ $# -ge 2 ]] || { printf '%s\n' "$(msg invalid_lang --lang)" >&2; exit 2; }
            [[ "${2:-}" == es || "${2:-}" == en ]] || { printf '%s\n' "$(msg invalid_lang "${2:-}")" >&2; exit 2; }
            LANG_UI="$2"; shift 2
            ;;
        --lang=*)
            requested_lang="${1#*=}"
            [[ "$requested_lang" == es || "$requested_lang" == en ]] || { printf '%s\n' "$(msg invalid_lang "$requested_lang")" >&2; exit 2; }
            LANG_UI="$requested_lang"
            shift
            ;;
    esac
fi

init_categories

CLI_ACTION=""   # install | uninstall: runs without the graphical interface
UNINSTALL_STATE=ask   # ask | keep | purge (--uninstall: crontab backup and modified files)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        -h|--help)
            msg help_usage "$(basename -- "$0")"
            exit 0
            ;;
        -v|--version)
            echo "Autostart Manager $VERSION"
            exit 0
            ;;
        --install)
            CLI_ACTION=install
            shift
            ;;
        --uninstall)
            CLI_ACTION=uninstall
            shift
            ;;
        '')
            ;;
        *)
            printf '%s\n' "$(msg unexpected_arg "$1")" >&2
            exit 2
            ;;
    esac
    while [[ -n "$CLI_ACTION" ]] && (( $# )); do
        case "$CLI_ACTION:$1" in
            uninstall:--keep-config|uninstall:--purge)
                wanted="${1#--}"; wanted="${wanted/keep-config/keep}"
                if [[ "$UNINSTALL_STATE" != ask && "$UNINSTALL_STATE" != "$wanted" ]]; then
                    printf '%s\n' "$(msg uninstall_conflict)" >&2
                    exit 2
                fi
                UNINSTALL_STATE="$wanted"
                ;;
            *)
                printf '%s\n' "$(msg unexpected_arg "$1")" >&2
                exit 2
                ;;
        esac
        shift
    done
fi

shopt -s nullglob
set -o pipefail

SEP=$'\x1f'   # non-printing separator that cannot collide with normal text

TMP_FILES=()  # temporary paths retained for guaranteed cleanup
trap '((${#TMP_FILES[@]})) && rm -f "${TMP_FILES[@]}"' EXIT

# Install command for a missing dependency on the host package manager.
# $1: zenity | pkexec. Prints nothing and fails when the manager is unknown.
install_command() {
    local dep="$1" pkg="$1"
    if command -v apt-get &>/dev/null; then
        if [[ "$dep" == pkexec ]]; then
            pkg=policykit-1
            apt-cache show pkexec &>/dev/null && pkg=pkexec
        fi
        printf 'sudo apt install %s' "$pkg"
        return 0
    fi
    [[ "$dep" == pkexec ]] && pkg=polkit
    if   command -v dnf &>/dev/null;        then printf 'sudo dnf install %s' "$pkg"
    elif command -v yum &>/dev/null;        then printf 'sudo yum install %s' "$pkg"
    elif command -v rpm-ostree &>/dev/null; then printf 'rpm-ostree install %s' "$pkg"
    elif command -v zypper &>/dev/null;     then printf 'sudo zypper install %s' "$pkg"
    elif command -v pacman &>/dev/null;     then printf 'sudo pacman -S %s' "$pkg"
    elif command -v apk &>/dev/null;        then printf 'sudo apk add %s' "$pkg"
    elif command -v xbps-install &>/dev/null; then printf 'sudo xbps-install %s' "$pkg"
    elif command -v eopkg &>/dev/null;      then printf 'sudo eopkg install %s' "$pkg"
    elif command -v emerge &>/dev/null;     then
        [[ "$dep" == pkexec ]] && pkg=sys-auth/polkit || pkg=gnome-extra/zenity
        printf 'sudo emerge --ask %s' "$pkg"
    elif command -v nix-env &>/dev/null;    then printf 'nix-env -iA nixpkgs.%s' "$pkg"
    else return 1
    fi
}

# Localized "dependency missing" text with the matching install command.
dependency_message() {
    local key=missing_zenity cmd
    [[ "$1" == pkexec ]] && key=pkexec_missing
    if cmd=$(install_command "$1"); then msg "$key" "$cmd"; else msg "${key}_generic"; fi
}

# --------------------------------------------------------------------------
# Initial checks
# --------------------------------------------------------------------------
if [[ -z "$CLI_ACTION" ]] && ! command -v zenity &>/dev/null; then
    printf '%s\n' "$(dependency_message zenity)" >&2
    exit 1
fi

# Zenity/GLib can reject non-ASCII option values when launched with a
# non-UTF-8 locale (common with desktop launchers that inherit a reduced
# environment). Defend against that in two layers:
#  1) Prefer an available UTF-8 locale and fall back to C.UTF-8.
#  2) zen()+ascii_safe() sanitize only GLib-parsed option values; row data
#     after "--" is deliberately left untouched so names and cron commands
#     retain their original UTF-8 text.
if [[ "$(locale charmap 2>/dev/null)" != *UTF-8* ]]; then
    lang_env="${LANG:-}"
    for cand in "${lang_env%%.*}" "${lang_env%%_*}" es_ES en_US C; do
        [[ -z "$cand" ]] && continue
        utf8_locale=$(locale -a 2>/dev/null | grep -iE "^${cand}\.utf-?8$" | head -n1)
        [[ -n "$utf8_locale" ]] && { export LC_ALL="$utf8_locale" LANG="$utf8_locale"; break; }
    done
    [[ "$(locale charmap 2>/dev/null)" != *UTF-8* ]] && export LC_ALL="C.UTF-8" LANG="C.UTF-8"
fi

# Reduce text to printable ASCII for Zenity option values when required.
# Literal substitutions happen before a C-locale tr pass, so this helper does
# not depend on the current locale.
NEED_ASCII_ZENITY=0
[[ "$(locale charmap 2>/dev/null)" != *UTF-8* ]] && NEED_ASCII_ZENITY=1

# Result in ASCII_V: loops over the inventory call this form, which forks nothing.
ASCII_V=""
ascii_safe_v() {
    local s="$1" LC_ALL=C
    s="${s//á/a}"; s="${s//é/e}"; s="${s//í/i}"; s="${s//ó/o}"; s="${s//ú/u}"
    s="${s//Á/A}"; s="${s//É/E}"; s="${s//Í/I}"; s="${s//Ó/O}"; s="${s//Ú/U}"
    s="${s//ñ/n}"; s="${s//Ñ/N}"; s="${s//¿/}"; s="${s//¡/}"
    s="${s//«/\"}"; s="${s//»/\"}"
    ASCII_V="${s//[^$'\t\n\r' -~]/}"
}

ascii_safe() {
    ascii_safe_v "$1"
    printf '%s' "$ASCII_V"
}

# Zenity wrapper:
#  1) Sanitize only GLib-parsed option values when the locale requires it;
#     data after "--" is passed unchanged.
#  2) Label every button that has no explicit label in the interface language
#     (Zenity would use the system locale, which --lang can contradict).
#  3) Suppress known harmless GTK diagnostic noise.
#  4) If Zenity returns 255 for an option-parsing failure, retry with the
#     minimal dialog type and sanitized text so the user still gets feedback.
zen() {
    local -a args=() labels=() sane=()
    local a dtype="" text="" after_options=0 has_ok=0 has_cancel=0 ok_key=btn_ok cancel_key=btn_cancel
    for a in "$@"; do
        if (( ! after_options )); then
            if [[ "$a" == -- ]]; then
                after_options=1
                args+=("$a")
                continue
            fi
            case "$a" in
                --title=*|--text=*|--ok-label=*|--cancel-label=*| \
                --entry-text=*|--column=*|--extra-button=*)
                    (( NEED_ASCII_ZENITY )) && a="${a%%=*}=$(ascii_safe "${a#*=}")" ;;
            esac
            case "$a" in
                --info|--question|--warning|--error) dtype="$a" ;;
                --text=*) text="${a#*=}" ;;
                --ok-label=*) has_ok=1 ;;
                --cancel-label=*) has_cancel=1 ;;
            esac
        fi
        args+=("$a")
    done
    [[ "$dtype" == --question ]] && { ok_key=btn_yes; cancel_key=btn_no; }
    (( has_ok )) || labels+=("--ok-label=$(msg "$ok_key")")
    # Message dialogs have a single button, so a cancel label would be unused.
    case "$dtype" in --info|--warning|--error) has_cancel=1 ;; esac
    (( has_cancel )) || labels+=("--cancel-label=$(msg "$cancel_key")")
    for a in "${labels[@]}"; do
        (( NEED_ASCII_ZENITY )) && a="${a%%=*}=$(ascii_safe "${a#*=}")"
        sane+=("$a")
    done
    args=("${sane[@]}" "${args[@]}")
    local out rc
    out=$(zenity "${args[@]}" \
        2> >(grep -Ev 'GLib-GObject-CRITICAL|a11y|accessibility bus|DRI3|libEGL' >&2))
    rc=$?
    if [[ $rc -eq 255 && -n "$dtype" ]]; then
        local fallback
        fallback=$(msg no_message)
        out=$(zenity "$dtype" --text="${text:-$fallback}" 2>/dev/null)
        rc=$?
    fi
    printf '%s' "$out"
    return "$rc"
}

# Optional tools are detected once so entire categories can be omitted
# cleanly when a minimal installation lacks systemd or cron.
SYSTEMCTL_BIN=""
trusted_systemctl_path() {
    [[ -x /usr/bin/systemctl ]] && { printf '%s\n' /usr/bin/systemctl; return; }
    [[ -x /bin/systemctl ]] && { printf '%s\n' /bin/systemctl; return; }
    return 127
}
SYSTEMCTL_BIN=$(trusted_systemctl_path 2>/dev/null || true)
HAS_SYSTEMD=0
[[ -n "$SYSTEMCTL_BIN" ]] && HAS_SYSTEMD=1
HAS_CRONTAB=0
command -v crontab &>/dev/null && HAS_CRONTAB=1

# Running the whole script as root (for example with "sudo") changes the
# identity whose autostart and cron entries are managed. Warn explicitly and
# let the user choose whether to continue. Command-line actions handle root themselves.
if [[ -z "$CLI_ACTION" && "$EUID" -eq 0 ]]; then
    if ! zen --question --title="$(msg root_title)" --width=480 \
        --ok-label="$(msg root_ok)" --cancel-label="$(msg root_cancel)" \
        --text="$(msg root_text)"; then
        exit 0
    fi
fi

# User autostart directory. The XDG Base Directory spec requires
# XDG_CONFIG_HOME to be an absolute path; relative values are ignored.
user_autostart_dir() {
    local base="${XDG_CONFIG_HOME:-}"
    [[ "$base" == /* ]] || base="$HOME/.config"
    printf '%s\n' "${base%/}/autostart"
}

# --------------------------------------------------------------------------
# Global inventory arrays
# --------------------------------------------------------------------------
ARR_TYPE=()          # user-facing type label shown in the table (with icon)
ARR_NAME=()          # display name
ARR_STATUS=()        # "TRUE" / "FALSE" current enabled state
ARR_STATUS_LABEL=()  # "✅ Enabled" / "⛔ Disabled" (localized)
ARR_SRC=()           # displayed source (path or unit)
ARR_KIND=()          # internal kind: user_autostart / system_autostart /
                      #               systemd_user / systemd_system / cron_user
ARR_RAW=()           # internal identifier used to enable/disable the item
ARR_MODE=()          # systemd only: "enable" (enable/disable) or
                      # "mask" (static/generated/indirect/masked units,
                      # which do not use enable/disable; they are managed with
                      # systemctl mask/unmask). Empty for other kinds.
ARR_CRIT=()          # 1 for a critical item (independent of the language)
ARR_DESK=()          # .desktop entries: "<user override 0|1>", a newline and the DK_KEEP lines;
                      # relabel_items translates the entry from it without reading the file.
declare -A LAST_ERR  # concrete error for the last failed item

# Window height for a Zenity list: BASE + LINE * text lines + ROW * rows, in px.
# Measured on real Zenity (PLAN.txt 14.12) with a few px of slack: GTK3 (3.x) rows are
# 23-27 px, GTK4 (4.x) rows 33-37 px (menu) and 42 px (checklist). Fields: base, line,
# menu row, checklist row.
FIT_GTK3=(110 20 27 27)
FIT_GTK4=(200 20 38 43)
ZEN_MAJOR=3

# Zenity 3.x needs a display to answer --version, so this runs once the GUI starts, in
# the main shell (a $(...) subshell would lose the result). Anything unexpected keeps 3.
detect_zenity_major() {
    local v
    v=$(zenity --version 2>/dev/null) || return 0
    [[ "$v" =~ ^([0-9]+)\. ]] && ZEN_MAJOR="${BASH_REMATCH[1]}"
    return 0
}

# $1 = dialog text ("" for none; \n escapes count as lines), $2 = rows, $3 = "check" for
# checklists. Short lists are not surrounded by empty space and long ones scroll.
fit_height() {
    local -a m=("${FIT_GTK3[@]}")
    (( ZEN_MAJOR >= 4 )) && m=("${FIT_GTK4[@]}")
    local text="${1//\\n/$'\n'}" nl row="${m[2]}"
    nl="${text//[^$'\n']/}"
    [[ "${3:-}" == check ]] && row="${m[3]}"
    local h=$(( m[0] + m[1] * (${#nl} + 1) + row * $2 ))
    (( h < 340 )) && h=340
    (( h > 600 )) && h=600
    printf '%s' "$h"
}

# An extra button's label as Zenity prints it when pressed (folded like zen folds it).
extra_label() {
    local l="$1"
    (( NEED_ASCII_ZENITY )) && l=$(ascii_safe "$l")
    printf '%s' "$l"
}

# Path as shown to the user: the home directory is abbreviated to ~.
# Both helpers have a subshell-free form (DISP_V, ESC_V) for the row loops.
DISP_V=""
display_path_v() {
    if [[ -n "${HOME:-}" && "$1" == "$HOME"/* ]]; then DISP_V="~${1#"$HOME"}"; else DISP_V="$1"; fi
}

display_path() {
    display_path_v "$1"
    printf '%s' "$DISP_V"
}

ESC_V=""
esc_markup_v() {
    # Escape &, <, and > so Zenity/Pango cannot interpret dynamic values as
    # markup. Cron commands commonly contain shell operators such as "&&".
    #
    # In Bash 5.2+, an unescaped replacement-side "&" in ${var//pat/rep} has
    # special meaning, so the replacement deliberately uses "\&".
    local s="$1"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    ESC_V="$s"
}

esc_markup() {
    esc_markup_v "$1"
    printf '%s' "$ESC_V"
}

# Type cell in TYPE_V: icon and label, plus the critical mark. $1 = label chosen by the
# caller (autostart and cron; systemd derives its own), $2 = kind, $3 = raw id, $4 = 1 if critical.
TYPE_V=""
type_cell_v() {
    local type_label="$1" kind="$2" raw="$3" crit="$4" icon=""
    case "$kind" in
        user_autostart)   icon="👤" ;;
        system_autostart) icon="🖥️" ;;
        systemd_user|systemd_system)
            if [[ "$kind" == systemd_user ]]; then msg_v session_service; else msg_v system_service; fi
            type_label="$MSGV"
            if (( crit )); then
                :
            elif is_internal_systemd_unit "$raw"; then
                icon="⚙️"
            else
                icon="📦"
                msg_v background
                type_label="$MSGV"
            fi ;;
        cron_user) icon="⏰" ;;
    esac
    if (( crit )); then
        icon="🔒"
        msg_v critical
        type_label+=" · $MSGV"
    fi
    TYPE_V="$icon $type_label"
}

# Localized "Enabled"/"Disabled" for status $1 (TRUE/FALSE), in MSGV.
status_label_v() {
    if [[ "$1" == "TRUE" ]]; then msg_v enabled; else msg_v disabled; fi
}

# $8 (optional) is the neutral .desktop data kept in ARR_DESK. The technical systemd
# identity stays in the Source column rather than in the type label.
add_item() {
    local type_label="$1" name="$2" status="$3" src="$4" kind="$5" raw="$6" mode="${7:-}" desk="${8:-}" crit=0
    case "$kind" in
        user_autostart|system_autostart) is_critical_autostart "${raw##*/}" "$name" "$raw" && crit=1 ;;
        systemd_user|systemd_system)     is_critical_unit "$raw" && crit=1 ;;
    esac
    type_cell_v "$type_label" "$kind" "$raw" "$crit"
    ARR_TYPE+=("$TYPE_V")
    ARR_NAME+=("$name")
    ARR_STATUS+=("$status")
    status_label_v "$status"
    ARR_STATUS_LABEL+=("$MSGV")
    ARR_SRC+=("$src")
    ARR_KIND+=("$kind")
    ARR_RAW+=("$raw")
    ARR_MODE+=("$mode")
    ARR_CRIT+=("$crit")
    ARR_DESK+=("$desk")
}

# Value of KEY (first match) in the [Desktop Entry] group of file $1. Per the
# Desktop Entry spec, whitespace around "=" is ignored and keys outside the
# main group do not count.
# One-slot cache for the scan: desktop_keys_load parses a file once, in the main shell,
# and desktop_key then answers from it (the $(...) callers inherit the map). The cache
# lives only inside collect_items, so a changed file is never served stale.
DK_FILE=""
declare -A DK_MAP=()
DK_NAMES=()   # every Name / Name[...] value, duplicates included (criticality checks them all)
DK_KEEP=""    # the keys that label an entry in any language (Name, Name[...], OnlyShowIn,
              # NotShowIn), one "key<US>value" per line; saved in ARR_DESK
desktop_keys_load() {
    local k v
    DK_FILE="$1"; DK_MAP=(); DK_NAMES=(); DK_KEEP=""
    while IFS=$'\037' read -r k v; do
        if [[ "$k" == $'\036N' ]]; then
            DK_NAMES+=("$v")
        else
            DK_MAP["$k"]="$v"
            case "$k" in Name|Name\[*\]|OnlyShowIn|NotShowIn) DK_KEEP+="$k"$'\037'"$v"$'\n' ;; esac
        fi
    done < <(awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        /^[[:space:]]*\[/ { in_main = ($0 ~ /^[[:space:]]*\[Desktop Entry\][[:space:]]*$/); next }
        in_main && !/^[[:space:]]*#/ {
            i = index($0, "=")
            if (i > 0) {
                if ($0 ~ /^[[:space:]]*Name(\[[^]]+\])?[[:space:]]*=/) print "\036N\037" substr($0, i + 1)
                k = trim(substr($0, 1, i - 1))
                if (!(k in seen) && index(k, "\037") == 0) { seen[k] = 1; print k "\037" trim(substr($0, i + 1)) }
            }
        }
    ' "$1" 2>/dev/null)
}

# Load the keys that desktop_keys_load saved in $2 as the cache of entry $1.
desktop_keys_restore() {
    local rest="$2" line
    DK_FILE="$1"; DK_MAP=(); DK_NAMES=(); DK_KEEP=""
    while [[ -n "$rest" ]]; do
        line="${rest%%$'\n'*}"
        rest="${rest#"$line"}"; rest="${rest#$'\n'}"
        DK_MAP["${line%%$'\037'*}"]="${line#*$'\037'}"
    done
}

# Value of key $2 of file $1 in DKV, without a subshell when the file is the one loaded.
DKV=""
desktop_key_v() {
    if [[ "$DK_FILE" == "$1" ]]; then DKV="${DK_MAP[$2]-}"; return 0; fi
    DKV=$(desktop_key_awk "$1" "$2")
}

desktop_key() {
    if [[ "$DK_FILE" == "$1" ]]; then
        [[ -n "${DK_MAP[$2]+set}" ]] && printf '%s\n' "${DK_MAP[$2]}"
        return 0
    fi
    desktop_key_awk "$1" "$2"
}

desktop_key_awk() {
    awk -v key="$2" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        BEGIN { in_main = 0 }
        /^[[:space:]]*\[/ { in_main = ($0 ~ /^[[:space:]]*\[Desktop Entry\][[:space:]]*$/); next }
        in_main && !/^[[:space:]]*#/ {
            i = index($0, "=")
            if (i > 0 && trim(substr($0, 1, i - 1)) == key) { print trim(substr($0, i + 1)); exit }
        }
    ' "$1" 2>/dev/null
}

# Result in UNESC_V. Most values hold no backslash and need no scan.
UNESC_V=""
desktop_unescape_v() {
    local value="$1" out="" c next i len
    if [[ "$value" != *\\* ]]; then UNESC_V="$value"; return 0; fi
    len=${#value}
    for ((i = 0; i < len; i++)); do
        c="${value:i:1}"
        if [[ "$c" == "\\" && $((i + 1)) -lt len ]]; then
            next="${value:i+1:1}"
            case "$next" in
                s) out+=' ' ;;
                n) out+=$'\n' ;;
                t) out+=$'\t' ;;
                r) out+=$'\r' ;;
                \\) out+=$'\\' ;;
                *) out+="\\$next" ;;
            esac
            ((i++))
        else
            out+="$c"
        fi
    done
    UNESC_V="$out"
}

desktop_unescape() {
    desktop_unescape_v "$1"
    printf '%s\n' "$UNESC_V"
}

desktop_validate() {
    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function invalid() { exit 1 }
        function validate_exec(s,    i,c,n,prev,nxt,quoted,file_codes,len,j,first_has_content) {
            len = length(s)
            i = 1
            while (i <= len && substr(s, i, 1) ~ /[[:space:]]/) i++
            if (i > len) invalid()
            if (substr(s, i, 1) == "\"") {
                first_has_content = 0
                j = i + 1
                while (j <= len) {
                    c = substr(s, j, 1)
                    if (c == "\\" && j < len) {
                        first_has_content = 1
                        j += 2
                        continue
                    }
                    if (c == "\"") break
                    c !~ /[[:space:]]/ && first_has_content = 1
                    j++
                }
                (j > len || !first_has_content) && invalid()
            }
            for (i = 1; i <= len; i++) {
                c = substr(s, i, 1)
                if (c == "\\") {
                    (i == len) && invalid()
                    i++
                    continue
                }
                if (c == "\"") { quoted = !quoted; continue }
                if (c != "%") continue
                if (i == len) invalid()
                n = substr(s, i + 1, 1)
                if (n == "%") { i++; continue }
                if (n !~ /^[fFuUickdDnNvm]$/) invalid()
                if (quoted) invalid()
                if (n ~ /^[fFuU]$/) {
                    file_codes++
                    (file_codes > 1) && invalid()
                }
                if (n ~ /^[FUi]$/) {
                    prev = (i > 1) ? substr(s, i - 1, 1) : ""
                    nxt = (i + 2 <= len) ? substr(s, i + 2, 1) : ""
                    (i > 1 && prev !~ /[[:space:]]/) && invalid()
                    (i + 2 <= len && nxt !~ /[[:space:]]/) && invalid()
                }
                i++
            }
            quoted && invalid()
        }
        /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            header = $0
            sub(/^[[:space:]]*/, "", header)
            sub(/[[:space:]]*$/, "", header)
            group = substr(header, 2, length(header) - 2)
            group ~ /[\[\]]/ && invalid()
            group ~ /[[:cntrl:]]/ && invalid()
            seen_group[group]++
            (seen_group[group] > 1) && invalid()
            main = (group == "Desktop Entry")
            if (!seen_main && !main) invalid()
            if (main) seen_main++
            current_group = group
            next
        }
        /^\[/ { invalid() }
        {
            i = index($0, "=")
            if (current_group == "" || i <= 1) invalid()
            key = trim(substr($0, 1, i - 1))
            key == "" && invalid()
            base_key = key
            if (key ~ /\[[^][]+\]$/) {
                sub(/\[[^][]+\]$/, "", base_key)
                base_key == "" && invalid()
                localized_without_base[current_group SUBSEP base_key] = 1
            } else if (key ~ /[\[\]]/) {
                invalid()
            }
            base_key !~ /^[A-Za-z0-9-]+$/ && invalid()
            pair = current_group SUBSEP key
            seen_key[pair]++
            (seen_key[pair] > 1) && invalid()
            if (main && key == "Type") {
                has_type = 1
                type_value = trim(substr($0, i + 1))
                (type_value == "" || type_value != "Application") && invalid()
            }
            if (main && key == "Name") {
                has_name = 1
                trim(substr($0, i + 1)) == "" && invalid()
            }
            if (main && key == "Exec") {
                exec_value = trim(substr($0, i + 1))
                exec_value == "" && invalid()
                has_exec = 1
                validate_exec(exec_value)
            }
            if (main && (key == "Hidden" || key == "X-GNOME-Autostart-enabled" || key == "DBusActivatable")) {
                bool_value = trim(substr($0, i + 1))
                (bool_value != "true" && bool_value != "false") && invalid()
                if (key == "DBusActivatable") dbus_activatable = bool_value
            }
            if (main && key == "OnlyShowIn") {
                n = split(trim(substr($0, i + 1)), show_tokens, ";")
                for (j = 1; j <= n; j++) {
                    token = trim(show_tokens[j])
                    if (token != "") only_show_in[token] = 1
                }
            }
            if (main && key == "NotShowIn") {
                n = split(trim(substr($0, i + 1)), hide_tokens, ";")
                for (j = 1; j <= n; j++) {
                    token = trim(hide_tokens[j])
                    if (token != "") not_show_in[token] = 1
                }
            }
        }
        END {
            for (pair in localized_without_base) {
                if (seen_key[pair] == 0) exit 1
            }
            for (token in only_show_in) {
                if (token in not_show_in) exit 1
            }
            if (seen_main != 1 || !has_type || !has_name || (!has_exec && dbus_activatable != "true")) exit 1
        }
    ' "$1" 2>/dev/null
}

# Result in NAME_V (the inventory loops call this form; get_desktop_name prints it).
NAME_V=""
get_desktop_name_v() {
    # Follow the Desktop Entry locale fallback, but keep the selected UI language
    # authoritative when the user switched away from the system locale.
    local f="$1" name="" locale locale_raw short candidate base
    local -a candidates=()
    locale_raw="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    locale="${locale_raw%%.*}"
    if [[ "$locale_raw" == *.* && "$locale_raw" == *@* ]]; then
        locale="${locale}@${locale_raw#*@}"
    fi
    short="${locale%%_*}"
    if [[ "$short" == "${LANG_UI,,}" ]]; then
        [[ -n "$locale" ]] && candidates+=("$locale")
        if [[ "$locale" == *@* ]]; then
            candidate="${locale%%@*}"
            [[ -n "$candidate" ]] && candidates+=("$candidate")
            candidate="${short}@${locale#*@}"
            [[ -n "$candidate" ]] && candidates+=("$candidate")
        fi
        candidates+=("$short")
    else
        candidates=("$LANG_UI")
    fi
    for candidate in "${candidates[@]}"; do
        desktop_key_v "$f" "Name[$candidate]"; name="$DKV"
        [[ -n "$name" ]] && break
    done
    [[ -n "$name" ]] || { desktop_key_v "$f" Name; name="$DKV"; }
    if [[ -z "$name" ]]; then
        name="${f##*/}"
        [[ "$name" == ?*.desktop ]] && name="${name%.desktop}"
    fi
    desktop_unescape_v "$name"
    NAME_V="$UNESC_V"
}

get_desktop_name() {
    get_desktop_name_v "$1"
    printf '%s\n' "$NAME_V"
}

# Result in ENABLED_V: TRUE/FALSE according to Hidden= and X-GNOME-Autostart-enabled=.
ENABLED_V=""
is_desktop_enabled_v() {
    local f="$1"
    ENABLED_V=TRUE
    desktop_key_v "$f" Hidden
    if [[ "$DKV" == true ]]; then ENABLED_V=FALSE; return 0; fi
    desktop_key_v "$f" X-GNOME-Autostart-enabled
    [[ "$DKV" == false ]] && ENABLED_V=FALSE
    return 0
}

is_desktop_enabled() {
    is_desktop_enabled_v "$1"
    echo "$ENABLED_V"
}

# Result in ENVNOTE_V (empty when the entry applies to the current desktop).
ENVNOTE_V=""
desktop_env_note_v() {
    # Add a visible note when OnlyShowIn/NotShowIn excludes the current
    # desktop environment. An entry may still be enabled while being
    # inapplicable to the active session.
    local f="$1" cur only not tok c match=0 note=""
    local -a cur_toks only_toks not_toks
    ENVNOTE_V=""
    cur="${XDG_CURRENT_DESKTOP:-}"

    desktop_key_v "$f" OnlyShowIn; only="${DKV//[ $'\t\n\v\f\r']/}"
    desktop_key_v "$f" NotShowIn; not="${DKV//[ $'\t\n\v\f\r']/}"
    [[ -n "$only" || -n "$not" ]] || return 0
    IFS=':' read -r -a cur_toks <<< "$cur"

    if [[ -n "$only" && -n "$cur" ]]; then
        IFS=';' read -r -a only_toks <<< "$only"
        for tok in "${only_toks[@]}"; do
            for c in "${cur_toks[@]}"; do
                [[ "$tok" == "$c" ]] && match=1
            done
        done
        [[ $match -eq 0 ]] && { msg_v desktop_no_apply_only "$cur" "$only"; note="$MSGV"; }
    fi
    if [[ -n "$not" && -n "$cur" ]]; then
        IFS=';' read -r -a not_toks <<< "$not"
        for tok in "${not_toks[@]}"; do
            for c in "${cur_toks[@]}"; do
                [[ "$tok" == "$c" ]] && { msg_v desktop_no_apply_not "$cur" "$not"; note="$MSGV"; }
            done
        done
    fi
    ENVNOTE_V="$note"
}

desktop_env_note() {
    desktop_env_note_v "$1"
    echo "$ENVNOTE_V"
}

# Name (NAME_V) and source cell (SRC_V) of .desktop entry $1, whose keys are loaded in DK_*;
# $2 = 1 when a user override of this system entry exists. The scan and relabel_items both use it.
SRC_V=""
desktop_cells_v() {
    get_desktop_name_v "$1"
    desktop_env_note_v "$1"
    SRC_V="$1"
    if (( ${2:-0} )); then msg_v desktop_override; SRC_V+="$MSGV"; fi
    SRC_V+="$ENVNOTE_V"
}

# --------------------------------------------------------------------------
# Map a systemctl list-unit-files state to TRUE/FALSE plus an apply mode.
# static/generated/indirect units have no enablement symlink of their own, so
# enable/disable is not applicable; masking is used when the user explicitly
# wants to block such a unit. Return 1 for states that are not actionable
# inventory entries (for example alias, transient, or bad).
# --------------------------------------------------------------------------
systemd_unit_status() {
    local -n _st_out="$2" _mode_out="$3"
    case "$1" in
        enabled)          _st_out="TRUE";  _mode_out="enable" ;;
        enabled-runtime)  _st_out="TRUE";  _mode_out="enable-runtime" ;;
        disabled)         _st_out="FALSE"; _mode_out="enable" ;;
        static|generated|indirect)
                          _st_out="TRUE";  _mode_out="mask" ;;
        masked)           _st_out="FALSE"; _mode_out="mask" ;;
        masked-runtime)   _st_out="FALSE"; _mode_out="mask-runtime" ;;
        *) return 1 ;;
    esac
}

# Source cell of systemd unit $1 (mode $2) in SRC_V: the unit, plus a note when it is managed with mask.
unit_src_v() {
    SRC_V="$1"
    [[ "$2" == "mask" ]] || return 0
    msg_v static_mask
    SRC_V+="$MSGV"
}

# --------------------------------------------------------------------------
# refresh_items(): rebuild the inventory only after a real mutation
# (ITEMS_DIRTY=1). Changing tabs or filters reuses the same inventory and does
# not need another systemctl/file scan. A successful mutation marks the data
# dirty so the next screen reflects the new state.
# --------------------------------------------------------------------------
ITEMS_DIRTY=1
refresh_items() {
    (( ITEMS_DIRTY )) || return 0
    collect_items
    ITEMS_DIRTY=0
}

# --------------------------------------------------------------------------
# Collect all startup items into the global inventory arrays
# --------------------------------------------------------------------------
collect_items() {
    ARR_TYPE=(); ARR_NAME=(); ARR_STATUS=(); ARR_STATUS_LABEL=()
    ARR_SRC=(); ARR_KIND=(); ARR_RAW=(); ARR_MODE=(); ARR_CRIT=(); ARR_DESK=()

    local f base status ovr override unit state st mode dir
    local line lineno trimmed content udir raw_xdg fd_user fd_system fd_cron
    local t_user t_system t_session t_sys_svc t_cron
    local -a system_files=() sys_dirs=()

    # systemctl and crontab run in the background (their output waits in a pipe) while
    # the .desktop files, the slowest part, are parsed.
    if (( HAS_SYSTEMD )); then
        exec {fd_user}< <("$SYSTEMCTL_BIN" --user list-unit-files --type=service,socket --no-legend 2>/dev/null)
        exec {fd_system}< <("$SYSTEMCTL_BIN" list-unit-files --type=service,socket --no-legend 2>/dev/null)
    fi
    (( HAS_CRONTAB )) && exec {fd_cron}< <(crontab -l 2>/dev/null)
    msg_v user_type; t_user="$MSGV"
    msg_v system_type; t_system="$MSGV"
    msg_v session_service; t_session="$MSGV"
    msg_v system_service; t_sys_svc="$MSGV"
    msg_v cron_task; t_cron="$MSGV"
    DK_FILE=""

    raw_xdg="${XDG_CONFIG_DIRS:-/etc/xdg}"
    while :; do
        if [[ "$raw_xdg" == *:* ]]; then
            dir="${raw_xdg%%:*}"
            raw_xdg="${raw_xdg#*:}"
        else
            dir="$raw_xdg"
            raw_xdg=""
        fi
        [[ "$dir" == /* ]] && sys_dirs+=("${dir%/}/autostart")
        [[ -n "$raw_xdg" ]] || break
    done

    # --- Record the first system entry for each basename. ---
    local -A SYS_SEEN=()
    for dir in "${sys_dirs[@]}"; do
        for f in "$dir/"*.desktop; do
            [[ -f "$f" ]] || continue
            base="${f##*/}"
            [[ -n "${SYS_SEEN[$base]:-}" ]] && continue
            SYS_SEEN["$base"]=1
            system_files+=("$f")
        done
    done

    # --- 1) User-only autostart entries. ---
    udir=$(user_autostart_dir)
    for f in "$udir/"*.desktop; do
        [[ -f "$f" ]] || continue
        base="${f##*/}"
        [[ -n "${SYS_SEEN[$base]:-}" ]] && continue
        desktop_keys_load "$f"
        is_desktop_enabled_v "$f"; status="$ENABLED_V"
        desktop_cells_v "$f" 0
        add_item "$t_user" "$NAME_V" "$status" "$SRC_V" "user_autostart" "$f" "" $'0\n'"$DK_KEEP"
    done

    # --- 2) System autostart entries, with optional user overrides. ---
    for f in "${system_files[@]}"; do
        base="${f##*/}"
        override="$udir/$base"
        # Read the display name and applicability notes from the system entry,
        # not the override. The generated override contains only activation
        # state, so it does not carry Name=. The system entry is loaded last
        # so add_item can reuse it for the criticality check.
        ovr=0
        if [[ -f "$override" ]]; then
            desktop_keys_load "$override"
            is_desktop_enabled_v "$override"; status="$ENABLED_V"
            ovr=1
            desktop_keys_load "$f"
        else
            desktop_keys_load "$f"
            is_desktop_enabled_v "$f"; status="$ENABLED_V"
        fi
        desktop_cells_v "$f" "$ovr"
        add_item "$t_system" "$NAME_V" "$status" "$SRC_V" "system_autostart" "$f" "" "$ovr"$'\n'"$DK_KEEP"
    done

    if (( HAS_SYSTEMD )); then
        # --- 3) systemd --user services (.service and .socket) ---
        # Include .socket units because socket activation can start a daemon
        # independently of the service unit's enablement state.
        while read -r unit state _; do
            [[ -z "$unit" ]] && continue
            systemd_unit_status "$state" st mode || continue
            unit_src_v "$unit" "$mode"
            add_item "$t_session" "$unit" "$st" "$SRC_V" "systemd_user" "$unit" "$mode"
        done <&"$fd_user"
        exec {fd_user}<&-

        # --- 4) System systemd services and sockets. ---
        while read -r unit state _; do
            [[ -z "$unit" ]] && continue
            systemd_unit_status "$state" st mode || continue
            unit_src_v "$unit" "$mode"
            add_item "$t_sys_svc" "$unit" "$st" "$SRC_V" "systemd_system" "$unit" "$mode"
        done <&"$fd_system"
        exec {fd_system}<&-
    fi

    if (( HAS_CRONTAB )); then
        # --- 5) User cron jobs. ---
        lineno=0
        # The "|| [[ -n "$line" ]]" branch also processes a final physical
        # line without a trailing newline.
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineno=$((lineno + 1))
            [[ -z "$line" ]] && continue
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue   # whitespace-only lines are not jobs
            if [[ "$trimmed" == \#* ]]; then
                if [[ "$trimmed" == "#DISABLED#"* ]]; then
                    content="${trimmed#\#DISABLED#}"
                    content="${content# }"
                    msg_v cron_line "$lineno"
                    add_item "$t_cron" "${content:0:60}" "FALSE" "$MSGV" "cron_user" "$lineno" "$line"
                fi
                continue
            fi
            # VAR=value lines (MAILTO=, PATH=, SHELL=, etc.) configure the
            # whole crontab rather than defining jobs. Treating them as jobs
            # could comment out global settings, so they are omitted.
            if [[ "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then
                continue
            fi
            msg_v cron_line "$lineno"
            add_item "$t_cron" "${trimmed:0:60}" "TRUE" "$MSGV" "cron_user" "$lineno" "$line"
        done <&"$fd_cron"
        exec {fd_cron}<&-
    fi
    DK_FILE=""
}

# --------------------------------------------------------------------------
# Translate the live inventory after a language switch, without scanning again: type, name,
# status and source cells are rebuilt with the scan's own helpers from the neutral data it
# kept (kind, raw id, mode, status, ARR_CRIT, ARR_DESK). If that data is missing the next
# refresh_items scans again.
# --------------------------------------------------------------------------
relabel_items() {
    (( ITEMS_DIRTY )) && return 0   # the pending scan already uses the new language
    local i n=${#ARR_KIND[@]} kind raw mode label src desk
    (( ${#ARR_CRIT[@]} == n && ${#ARR_DESK[@]} == n && ${#ARR_NAME[@]} == n )) || { ITEMS_DIRTY=1; return 0; }
    for i in "${!ARR_KIND[@]}"; do
        kind="${ARR_KIND[$i]}"; raw="${ARR_RAW[$i]}"; mode="${ARR_MODE[$i]}"
        case "$kind" in
            user_autostart|system_autostart)
                desk="${ARR_DESK[$i]}"
                [[ "$desk" == *$'\n'* ]] || { DK_FILE=""; ITEMS_DIRTY=1; return 0; }
                desktop_keys_restore "$raw" "${desk#*$'\n'}"
                desktop_cells_v "$raw" "${desk%%$'\n'*}"
                ARR_NAME[i]="$NAME_V"; src="$SRC_V"
                if [[ "$kind" == user_autostart ]]; then msg_v user_type; else msg_v system_type; fi
                label="$MSGV" ;;
            systemd_user|systemd_system)
                unit_src_v "$raw" "$mode"; src="$SRC_V"; label="" ;;
            cron_user)
                msg_v cron_line "$raw"; src="$MSGV"
                msg_v cron_task; label="$MSGV" ;;
            *) continue ;;
        esac
        type_cell_v "$label" "$kind" "$raw" "${ARR_CRIT[$i]}"; ARR_TYPE[i]="$TYPE_V"
        status_label_v "${ARR_STATUS[$i]}"; ARR_STATUS_LABEL[i]="$MSGV"
        ARR_SRC[i]="$src"
    done
    DK_FILE=""
}

# --------------------------------------------------------------------------
# Systemd units considered sensitive: disabling one triggers an extra
# confirmation before any changes from the current screen are applied.
# --------------------------------------------------------------------------
is_critical_unit() {
    local u="${1%.service}"; u="${u%.socket}"
    case "$u" in
        NetworkManager|network-manager|networking| \
        systemd-*|dbus|dbus-broker|polkit| \
        cron|cronie|ssh|sshd| \
        lightdm|gdm|gdm3|cinnamon-session*| \
        udisks2|upower|accounts-daemon)
            return 0 ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# Name-based heuristic used only for category grouping. It distinguishes
# common distribution infrastructure units from third-party services. It does
# not determine criticality; is_critical_unit() does that independently.
# --------------------------------------------------------------------------
is_internal_systemd_unit() {
    local u="${1,,}"
    u="${u%.service}"; u="${u%.socket}"
    case "$u" in
        systemd-*|dbus*|polkit*|networkmanager*|network-manager| \
        networking|wpa_supplicant*|cron|cronie| \
        anacron|atd|ssh|sshd|rsyslog*| \
        syslog|udev|udisks2*|upower|accounts-daemon*| \
        lightdm*|gdm|gdm3|sddm|cinnamon-session*|gnome-session*| \
        plymouth*|modemmanager*|bluetooth*|blueman-mechanism*|avahi-daemon*| \
        cups*|apparmor*|ufw|unattended-upgrades*|apt-daily*|fwupd*| \
        packagekit*|power-profiles-daemon*|thermald*|irqbalance*|rsync| \
        kerneloops*|getty@*|serial-getty@*|user@*|user-runtime-dir@*| \
        rtkit-daemon*|colord*|multipathd*|lvm2-*|mdmonitor*|dm-event*| \
        e2scrub*|fstrim*|blk-availability*|grub-*|kmod-*|apport*|whoopsie*| \
        speech-dispatcher*|geoclue*|switcheroo-control*|networkd-dispatcher*| \
        hddtemp*|smartd*|snapd*|ntp|ntpsec*|chrony*|lm-sensors*| \
        console-setup*|keyboard-setup*|dmesg|finalrd| \
        gpu-manager*|ubuntu-system-adjustments*|casper-md5check*|remote-fs*| \
        nfs-*|rpcbind*)
            return 0 ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# UI categories. Each inventory item belongs to exactly one category:
#   1: Startup Applications        -> user_autostart / system_autostart
#   2: Background Processes        -> systemd_user
#   3: Scheduled Tasks             -> cron_user
#   4: Application Services        -> third-party systemd units
#   5: System Services             -> internal systemd units
# Criticality is evaluated separately and does not depend on the category.
# --------------------------------------------------------------------------

# Short "[icon + category]" tag used in combined/global-search views so the
# originating category remains obvious.
CATTAG_V=""
category_tag_v() {
    item_category_v "$1"
    CATTAG_V="[${CATEGORY_ICON[$CAT_OF]} ${CATEGORY_SHORT[$CAT_OF]}] "
}

category_tag() {
    category_tag_v "$1"
    printf '%s' "$CATTAG_V"
}

# Category of item $1 in CAT_OF (empty for an unknown kind). Loops over the whole
# inventory call this one: a $(item_category ...) fork per item made the menu slow.
CAT_OF=""
item_category_v() {
    case "${ARR_KIND[$1]}" in
        user_autostart|system_autostart) CAT_OF=1 ;;
        systemd_user)                    CAT_OF=2 ;;
        cron_user)                       CAT_OF=3 ;;
        systemd_system)
            if is_internal_systemd_unit "${ARR_RAW[$1]}"; then CAT_OF=5; else CAT_OF=4; fi ;;
        *)                               CAT_OF="" ;;
    esac
}

item_category() {
    item_category_v "$1"
    [[ -n "$CAT_OF" ]] && printf '%s\n' "$CAT_OF"
    return 0
}

# Return ARR_* indices belonging to category $1, sorted by display name
# case-insensitively. The result is written through the nameref in $2.
category_indices() {
    local cat="$1" i name indices idx
    local -n _out_ref="$2"
    local -a names=()
    local -A name_to_indices=()
    for i in "${!ARR_NAME[@]}"; do
        item_category_v "$i"
        if [[ "$cat" == "ALL" || "$CAT_OF" == "$cat" ]]; then
            name="${ARR_NAME[$i]}"
            names+=("$name")
            if [[ -n "${name_to_indices[$name]+set}" ]]; then
                name_to_indices["$name"]+=" $i"
            else
                name_to_indices["$name"]="$i"
            fi
        fi
    done
    _out_ref=()
    # NUL-delimited sorting keeps display names containing newlines intact.
    (( ${#names[@]} == 0 )) && return
    while IFS= read -r -d '' name; do
        indices="${name_to_indices[$name]}"
        idx="${indices%% *}"
        _out_ref+=("$idx")
        if [[ "$indices" == *" "* ]]; then
            name_to_indices["$name"]="${indices#* }"
        else
            unset 'name_to_indices[$name]'
        fi
    done < <(printf '%s\0' "${names[@]}" | sort -z -f -s)
}

# --------------------------------------------------------------------------
# Criticality rules for autostart desktop entries. The main case is a
# PolicyKit authentication agent, because disabling it can break graphical
# administrator-authentication prompts elsewhere in the session.
# $1: desktop-entry basename
# $2: visible Name=
# $3: source file path
# --------------------------------------------------------------------------
# True when one Name= value (as written in the file) describes an authentication agent.
critical_name_value() {
    local value="$1" normalized
    [[ "$value" == *\\* ]] && { desktop_unescape_v "$value"; value="$UNESC_V"; }
    ascii_safe_v "${value,,}"
    normalized="$ASCII_V"
    if [[ "$normalized" == *policykit* && ( "$normalized" == *agent* || "$normalized" == *agente* ) ]]; then
        return 0
    fi
    if [[ "$normalized" == *polkit* && ( "$normalized" == *agent* || "$normalized" == *agente* ) ]]; then
        return 0
    fi
    [[ "$normalized" == *"authentication agent"* || "$normalized" == *"agente de autenticacion"* ]]
}

is_critical_autostart() {
    local base="${1,,}" name="${2:-}" file="${3:-}" line value
    case "$base" in
        *polkit*agent*|*polkit-gnome*|*polkit-mate*|*polkit-kde*|*xfce-polkit*|*lxpolkit*)
            return 0 ;;
    esac

    # Inspect every localized Name[...] in the source entry so criticality
    # does not depend on the selected UI language. During the scan the file is
    # already parsed (DK_NAMES); otherwise it is read here.
    if [[ -r "$file" ]]; then
        if [[ "$DK_FILE" == "$file" ]]; then
            for value in "${DK_NAMES[@]}"; do
                critical_name_value "$value" && return 0
            done
        else
            while IFS= read -r line; do
                critical_name_value "${line#*=}" && return 0
            done < <(awk '
                /^[[:space:]]*\[/ { in_main = ($0 ~ /^[[:space:]]*\[Desktop Entry\][[:space:]]*$/); next }
                in_main && !/^[[:space:]]*#/ && $0 ~ /^[[:space:]]*Name(\[[^]]+\])?[[:space:]]*=/ { print }
            ' "$file" 2>/dev/null)
        fi
    fi

    ascii_safe_v "${name,,}"
    case "$ASCII_V" in
        *policykit*agent*|*agent*policykit*|*polkit*agent*|*agent*polkit*|*"authentication agent"*|*"agente de autenticacion"*)
            return 0 ;;
    esac
    return 1
}

item_is_critical() {
    local i="$1" kind="${ARR_KIND[$1]}"
    case "$kind" in
        user_autostart) is_critical_autostart "$(basename -- "${ARR_RAW[$i]}")" "${ARR_NAME[$i]}" "${ARR_RAW[$i]}" ;;
        system_autostart) is_critical_autostart "$(basename -- "${ARR_RAW[$i]}")" "${ARR_NAME[$i]}" "${ARR_RAW[$i]}" ;;
        systemd_user|systemd_system) is_critical_unit "${ARR_RAW[$i]}" ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# Atomic file replacement.
# Data goes to a temporary file in the target's own directory (same filesystem),
# is flushed to disk, and replaces the target with rename(2): readers see the
# old or the new content, never a partial file. Symbolic links and non-regular
# targets are refused rather than followed.
# --------------------------------------------------------------------------
ATOMIC_SYNC_BIN=""

atomic_sync_file() {
    # Synchronize cached writes before the atomic rename.
    local sync_bin="$ATOMIC_SYNC_BIN"
    if [[ -z "$sync_bin" ]]; then
        if [[ -x /usr/bin/sync ]]; then
            sync_bin=/usr/bin/sync
        elif [[ -x /bin/sync ]]; then
            sync_bin=/bin/sync
        else
            return 1
        fi
    fi
    [[ -x "$sync_bin" ]] || return 1
    "$sync_bin" -- "$1"
}

atomic_default_mode() {
    # Mode for newly created files: 0666 filtered by the current umask.
    printf '%03o' $(( 8#666 & ~8#$(umask) ))
}

atomic_require_regular() {
    # Fail with a visible reason unless $1 is an existing regular file.
    if [[ -L "$1" ]]; then
        printf '%s\n' "$(msg target_symlink)" >&2
        return 1
    fi
    [[ -f "$1" ]] || { printf '%s\n' "$(msg target_not_file)" >&2; return 1; }
}

atomic_check_target() {
    # A target may be absent, but if present it must be a regular file.
    [[ -e "$1" || -L "$1" ]] || return 0
    atomic_require_regular "$1"
}

make_private_dir() {
    # Create $1 and every missing parent as 0700 (XDG rule for new directories).
    # An existing directory keeps its mode. `mkdir -m` would only cover the leaf.
    ( umask 077 && mkdir -p -- "$1" )
}

atomic_remove() {
    # Remove an existing regular file with an atomic unlink and sync its parent
    # directory on a best-effort basis. Symlinks and non-regular targets are refused.
    local target="$1" dir
    atomic_require_regular "$target" || return 1
    dir="$(dirname -- "$target")"
    rm -f -- "$target" || return 1
    atomic_sync_file "$dir" 2>/dev/null || true
}

atomic_install() {
    # Commit temp file $1 over target $2 with rename semantics. $3 sets the
    # mode for a new target; $4=force applies it to an existing target too.
    # The temp file is removed on any failure.
    local tmp="$1" target="$2" new_mode="${3:-}" force_mode="${4:-0}" dir
    dir="$(dirname -- "$target")"

    if ! atomic_check_target "$target"; then
        rm -f -- "$tmp"
        return 1
    fi

    if [[ -f "$target" && "$force_mode" != 1 ]]; then
        chmod --reference="$target" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    else
        chmod "${new_mode:-$(atomic_default_mode)}" -- "$tmp" || { rm -f -- "$tmp"; return 1; }
    fi

    # Persist cached file data before the commit. If synchronization is unavailable,
    # rename remains atomic; crash durability becomes best-effort.
    if ! atomic_sync_file "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi

    if ! mv -fT -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        return 1
    fi

    # Best-effort synchronization of the containing directory after the rename.
    atomic_sync_file "$dir" 2>/dev/null || true
}

atomic_transform() {
    # atomic_transform SOURCE EXPECTED_SHA256 DEST FILTER [ARGS...]
    # Copy SOURCE to a stable private snapshot, transform only that snapshot,
    # then require SOURCE to remain unchanged before the atomic commit.
    local source="$1" expected_hash="$2" dest="$3" tmp snapshot dir base snapshot_hash actual_hash cp_bin
    shift 3
    dir="$(dirname -- "$dest")"
    base="$(basename -- "$dest")"
    atomic_require_regular "$source" || return 1
    atomic_check_target "$dest" || return 1
    tmp=$(mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX") || return 1
    TMP_FILES+=("$tmp")
    snapshot=$(mktemp --tmpdir="$dir" ".${base}.src.XXXXXX") || {
        rm -f -- "$tmp"
        return 1
    }
    TMP_FILES+=("$snapshot")
    if [[ -x /usr/bin/cp ]]; then
        cp_bin=/usr/bin/cp
    elif [[ -x /bin/cp ]]; then
        cp_bin=/bin/cp
    else
        rm -f -- "$tmp" "$snapshot"
        return 1
    fi
    if ! "$cp_bin" -- "$source" "$snapshot"; then
        rm -f -- "$tmp" "$snapshot"
        return 1
    fi
    snapshot_hash=$(file_sha256 "$snapshot") || {
        rm -f -- "$tmp" "$snapshot"
        return 1
    }
    actual_hash=$(file_sha256 "$source") || {
        rm -f -- "$tmp" "$snapshot"
        return 1
    }
    if [[ "$snapshot_hash" != "$expected_hash" || "$actual_hash" != "$expected_hash" ]]; then
        rm -f -- "$tmp" "$snapshot"
        printf '%s\n' "$(msg desktop_changed)" >&2
        return 1
    fi
    if ! "$@" "$snapshot" > "$tmp"; then
        rm -f -- "$tmp" "$snapshot"
        return 1
    fi
    atomic_require_regular "$source" || { rm -f -- "$tmp" "$snapshot"; return 1; }
    actual_hash=$(file_sha256 "$source") || {
        rm -f -- "$tmp" "$snapshot"
        return 1
    }
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        rm -f -- "$tmp" "$snapshot"
        printf '%s\n' "$(msg desktop_changed)" >&2
        return 1
    fi
    rm -f -- "$snapshot"
    atomic_install "$tmp" "$dest"
}

atomic_write() {
    # atomic_write TARGET DATA [MODE]  (creates the parent directory if needed)
    local target="$1" data="$2" mode="${3:-}" tmp dir base
    dir="$(dirname -- "$target")"
    base="$(basename -- "$target")"
    atomic_check_target "$target" || return 1
    make_private_dir "$dir" || return 1
    tmp=$(mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX") || return 1
    TMP_FILES+=("$tmp")
    if ! printf '%s' "$data" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    atomic_install "$tmp" "$target" "$mode"
}

file_sha256() {
    # Print the SHA-256 of file $1. sha256sum starts its line with a backslash
    # when the file name has a backslash or a newline; that mark is not part of
    # the hash.
    local out
    [[ "$1" == /* ]] || set -- "./$1"
    out=$(sha256sum "$1" 2>/dev/null) || return 1
    out="${out%% *}"
    printf '%s' "${out#\\}"
}

atomic_place() {
    # atomic_place SOURCE TARGET MODE: copy regular file SOURCE over TARGET with
    # exactly MODE (creates the parent directory if needed).
    local source="$1" target="$2" mode="$3" tmp dir base
    dir="$(dirname -- "$target")"
    base="$(basename -- "$target")"
    atomic_require_regular "$source" || return 1
    atomic_check_target "$target" || return 1
    make_private_dir "$dir" || return 1
    tmp=$(mktemp --tmpdir="$dir" ".${base}.tmp.XXXXXX") || return 1
    TMP_FILES+=("$tmp")
    if ! cat -- "$source" > "$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    atomic_install "$tmp" "$target" "$mode" 1
}

# Run a command in the current shell (so TMP_FILES bookkeeping survives, which
# a $(...) subshell would lose) and keep its stderr in CAPTURED_ERR.
CAPTURED_ERR=""
capture_err() {
    local errfile rc
    errfile=$(mktemp) || { CAPTURED_ERR=""; "$@"; return; }
    TMP_FILES+=("$errfile")
    "$@" 2>"$errfile"; rc=$?
    CAPTURED_ERR=$(<"$errfile")
    rm -f -- "$errfile"
    return "$rc"
}

# Serialize read-modify-write cycles between concurrent instances with an
# advisory flock in the per-user runtime directory. Without that directory the
# command simply runs unlocked; the hash check in atomic_transform still applies.
LOCK_TIMEOUT="${AUTOSTART_MANAGER_LOCK_TIMEOUT:-10}"
[[ "$LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || LOCK_TIMEOUT=10
with_lock() {
    local dir="${XDG_RUNTIME_DIR:-}" fd rc owner mode flock_bin
    if [[ "$dir" == /* && -d "$dir" && -w "$dir" ]]; then
        if [[ -x /usr/bin/flock ]]; then
            flock_bin=/usr/bin/flock
        elif [[ -x /bin/flock ]]; then
            flock_bin=/bin/flock
        else
            "$@"
            return $?
        fi
        owner=$(/usr/bin/stat -c '%u' -- "$dir" 2>/dev/null) || { "$@"; return $?; }
        mode=$(/usr/bin/stat -c '%a' -- "$dir" 2>/dev/null) || { "$@"; return $?; }
        [[ "$owner" == "$EUID" && "$mode" == 700 ]] || { "$@"; return $?; }
        if ! { exec {fd}>>"$dir/autostart-manager.lock"; } 2>/dev/null; then
            "$@"
            return $?
        fi
        if ! "$flock_bin" -w "$LOCK_TIMEOUT" "$fd"; then
            exec {fd}>&-
            printf '%s\n' "$(msg lock_busy)" >&2
            return 1
        fi
        "$@"; rc=$?
        exec {fd}>&-
        return "$rc"
    fi
    "$@"
}

# awk filter that sets the activation state inside the [Desktop Entry] group.
#   want=TRUE   Hidden=false, and X-GNOME-Autostart-enabled=true when present.
#   want=FALSE  Hidden=true.
#   add_hidden=1 also inserts Hidden=false when enabling and the key is absent.
#   marker       a line (e.g. X-AutostartManager-Generated=true) to add once.
# A missing Hidden key is inserted at the end of the main group, never into a
# later group such as [Desktop Action ...]. Exit 3 (message on stderr) when no
# [Desktop Entry] group exists to hold the key.
DESKTOP_STATE_AWK=$(cat <<'AWK'
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function flush_group() {
    if (in_main) {
        if (!hidden_done && (want == "FALSE" || add_hidden == 1)) {
            print "Hidden=" (want == "FALSE" ? "true" : "false")
            hidden_done = 1
        }
        if (marker != "" && !marker_done) { print marker; marker_done = 1 }
    }
    printf "%s", pending
    pending = ""
}
BEGIN { in_main = 0; hidden_done = 0; pending = ""; seen_header = 0; content = 0 }
/^[[:space:]]*\[/ {
    if (!seen_header && !content) in_main = 0   # nothing before the first header
    seen_header = 1
    flush_group()
    in_main = ($0 ~ /^[[:space:]]*\[Desktop Entry\][[:space:]]*$/)
    print
    next
}
!in_main { print; next }
/^[[:space:]]*(#.*)?$/ { pending = pending $0 "\n"; next }
{
    content = 1
    printf "%s", pending
    pending = ""
    i = index($0, "=")
    key = (i > 0) ? trim(substr($0, 1, i - 1)) : ""
    if (key == "Hidden") {
        print "Hidden=" (want == "FALSE" ? "true" : "false")
        hidden_done = 1
        next
    }
    if (marker != "" && key == "X-AutostartManager-Generated") {
        print marker
        marker_done = 1
        next
    }
    if (want == "TRUE" && key == "X-GNOME-Autostart-enabled") {
        print "X-GNOME-Autostart-enabled=true"
        next
    }
    print
}
END {
    flush_group()
    if ((want == "FALSE" || add_hidden == 1) && !hidden_done) {
        print invalid_msg > "/dev/stderr"
        exit 3
    }
}
AWK
)

# Added to full copies made by this tool, so they can be told apart from
# overrides the user customized (those are only ever edited in place).
GENERATED_MARKER="X-AutostartManager-Generated=true"

desktop_set_user_state() {
    # Set the activation state of a user .desktop file in place (atomically).
    local f="$1" desired="$2" snapshot_hash
    atomic_require_regular "$f" || return 1
    desktop_validate "$f" || { printf '%s\n' "$(msg desktop_invalid)" >&2; return 1; }
    snapshot_hash=$(file_sha256 "$f") || return 1
    atomic_transform "$f" "$snapshot_hash" "$f" \
        awk -v want="$desired" -v add_hidden=0 -v marker="" -v invalid_msg="$(msg desktop_invalid)" "$DESKTOP_STATE_AWK"
}

desktop_make_override() {
    # Write a full copy of system entry $1 to user path $2 with Hidden set to
    # $3 (true|false). An enabled copy also forces X-GNOME-Autostart-enabled=true.
    local source="$1" target="$2" hidden_value="$3" want="TRUE" source_hash
    [[ "$hidden_value" == true ]] && want="FALSE"
    atomic_require_regular "$source" || return 1
    desktop_validate "$source" || { printf '%s\n' "$(msg desktop_invalid)" >&2; return 1; }
    atomic_check_target "$target" || return 1
    make_private_dir "$(dirname -- "$target")" || return 1
    source_hash=$(file_sha256 "$source") || return 1
    atomic_transform "$source" "$source_hash" "$target" \
        awk -v want="$want" -v add_hidden=1 -v marker="$GENERATED_MARKER" -v invalid_msg="$(msg desktop_invalid)" "$DESKTOP_STATE_AWK"
}

system_autostart_is_legacy_generated() {
    # Pre-marker state-only overrides from older releases have this exact shape.
    local f="$1" line n=0 ok=1
    [[ -f "$f" && ! -L "$f" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((n++))
        case "$n" in
            1) [[ "$line" == '[Desktop Entry]' ]] || ok=0 ;;
            2) [[ "$line" == 'Hidden=true' ]] || ok=0 ;;
            *) ok=0 ; break ;;
        esac
        (( ok )) || break
    done < "$f"
    (( ok && n == 2 ))
}

system_autostart_is_generated_state() {
    # New state-only overrides remain removable only while byte-for-byte minimal.
    local f="$1" content size
    [[ -f "$f" && ! -L "$f" ]] || return 1
    size=$(/usr/bin/stat -c '%s' -- "$f" 2>/dev/null) || return 1
    content=$(cat -- "$f")$'\n' || return 1
    if [[ "$size" == 62 && "$content" == $'[Desktop Entry]\nHidden=true\nX-AutostartManager-Generated=true\n' ]]; then
        return 0
    fi
    [[ "$size" == 63 && "$content" == $'[Desktop Entry]\nHidden=false\nX-AutostartManager-Generated=true\n' ]]
}

system_autostart_apply() {
    # system_autostart_apply USER_OVERRIDE SYSTEM_FILE TRUE|FALSE
    # A complete override the user customized (has Exec= or DBusActivatable=true)
    # is edited in place so the customizations survive. Generated overrides are
    # marked explicitly; the exact two-line legacy form remains recognized.
    local override="$1" sysfile="$2" desired="$3" sys_default="TRUE" full=0 generated=0 source_hash current_hash
    atomic_require_regular "$sysfile" || return 1
    source_hash=$(file_sha256 "$sysfile") || return 1
    if [[ -f "$override" && ! -L "$override" \
        && ( -n "$(desktop_key "$override" Exec)" || "$(desktop_key "$override" DBusActivatable)" == true ) ]]; then
        full=1
    fi
    if system_autostart_is_generated_state "$override"; then
        generated=1
    elif system_autostart_is_legacy_generated "$override"; then
        generated=1
    fi
    if [[ "$desired" == "FALSE" ]]; then
        if (( full )); then
            desktop_set_user_state "$override" FALSE
        elif [[ -e "$override" || -L "$override" ]]; then
            if (( generated )); then
                atomic_write "$override" $'[Desktop Entry]\nHidden=true\nX-AutostartManager-Generated=true\n'
            else
                printf '%s\n' "$(msg desktop_untrusted_override)" >&2
                return 1
            fi
        else
            atomic_write "$override" $'[Desktop Entry]\nHidden=true\nX-AutostartManager-Generated=true\n'
        fi
        return
    fi
    [[ -f "$sysfile" ]] && sys_default=$(is_desktop_enabled "$sysfile")
    if (( full )); then
        desktop_set_user_state "$override" TRUE
    elif [[ "$sys_default" == "TRUE" ]]; then
        if [[ -e "$override" || -L "$override" ]]; then
            if (( generated )); then
                current_hash=$(file_sha256 "$sysfile") || {
                    printf '%s\n' "$(msg desktop_changed)" >&2
                    return 1
                }
                if [[ "$current_hash" != "$source_hash" ]]; then
                    printf '%s\n' "$(msg desktop_changed)" >&2
                    return 1
                fi
                atomic_check_target "$override" || return 1
                atomic_remove "$override"
            else
                printf '%s\n' "$(msg desktop_untrusted_override)" >&2
                return 1
            fi
        fi
    elif [[ -f "$sysfile" ]]; then
        if [[ -e "$override" || -L "$override" ]]; then
            if (( generated )); then
                desktop_make_override "$sysfile" "$override" false
            else
                printf '%s\n' "$(msg desktop_untrusted_override)" >&2
                return 1
            fi
        else
            desktop_make_override "$sysfile" "$override" false
        fi
    elif [[ ! -e "$override" && ! -L "$override" ]]; then
        atomic_write "$override" $'[Desktop Entry]\nHidden=false\nX-AutostartManager-Generated=true\n'
    else
        printf '%s\n' "$(msg desktop_untrusted_override)" >&2
        return 1
    fi
}

state_dir() {
    # The only state the program keeps (crontab.bak); XDG_STATE_HOME if absolute.
    local base="${XDG_STATE_HOME:-}"
    [[ "$base" == /* ]] || base="$HOME/.local/state"
    printf '%s/autostart-manager' "${base%/}"
}

cron_backup() {
    # Best-effort copy ($1) of the crontab as it was before a change, kept in the
    # XDG state directory with owner-only permissions. Never blocks the change.
    local dir tmp
    dir=$(state_dir)
    make_private_dir "$dir" 2>/dev/null || return 0
    tmp=$(mktemp --tmpdir="$dir" ".crontab.tmp.XXXXXX" 2>/dev/null) || return 0
    TMP_FILES+=("$tmp")
    if cat -- "$1" > "$tmp" 2>/dev/null; then
        atomic_install "$tmp" "$dir/crontab.bak" 600 1 2>/dev/null || true
    else
        rm -f -- "$tmp"
    fi
    return 0
}

cron_apply_state() {
    # cron_apply_state LINE_NUMBER TRUE|FALSE LINE_AS_LISTED
    # Comment out / restore one crontab line, but only if the live crontab is
    # still what was listed (same line, unchanged between read and install).
    local ln="$1" desired="$2" baseline="$3"
    local work live total current current_trimmed snapshot_hash live_hash rc=0
    work=$(mktemp) || return 1
    TMP_FILES+=("$work")
    live=$(mktemp) || { rm -f -- "$work"; return 1; }
    TMP_FILES+=("$live")

    if ! crontab -l 2>/dev/null > "$work"; then
        printf '%s\n' "$(msg cron_missing)" >&2
        rc=1
    else
        total=$(grep -c '' "$work")
        snapshot_hash=$(sha256sum < "$work" | cut -d" " -f1)
        current=""
        (( ln <= total )) && current=$(sed -n "${ln}p" "$work")
        if (( ln > total )); then
            printf '%s\n' "$(msg cron_missing)" >&2
            rc=1
        elif [[ -n "$baseline" && "$current" != "$baseline" ]]; then
            printf '%s\n' "$(msg cron_changed)" >&2
            rc=1
        else
            current_trimmed="${current#"${current%%[![:space:]]*}"}"
            if [[ "$desired" == "FALSE" ]]; then
                [[ "$current_trimmed" != \#DISABLED#* ]] && sed -i "${ln}s|^|#DISABLED# |" "$work"
            elif [[ "$current" == \#DISABLED#* ]]; then
                sed -E -i "${ln}s|^#DISABLED#[[:space:]]?||" "$work"
            elif [[ "$current_trimmed" == \#DISABLED#* ]]; then
                sed -i "${ln}s|^[[:space:]]*#DISABLED#[[:space:]]\?||" "$work"
            fi
            # Re-read the live crontab right before installing; abort if it moved.
            if ! crontab -l 2>/dev/null > "$live"; then
                printf '%s\n' "$(msg cron_changed)" >&2
                rc=1
            else
                live_hash=$(sha256sum < "$live" | cut -d" " -f1)
                if [[ "$live_hash" != "$snapshot_hash" ]]; then
                    printf '%s\n' "$(msg cron_changed)" >&2
                    rc=1
                else
                    cron_backup "$live"
                    crontab "$work" 2>&1 || rc=1
                fi
            fi
        fi
    fi
    rm -f -- "$work" "$live"
    return "$rc"
}

# --------------------------------------------------------------------------
# Apply the requested state (TRUE=enable / FALSE=disable) to one item.
# Return 0 on success and 1 on failure.
# --------------------------------------------------------------------------
set_item_state() {
    local i="$1" desired="$2" kind="${ARR_KIND[$1]}" ok=0 err=""
    unset "LAST_ERR[$i]"

    case "$kind" in
        user_autostart)
            capture_err with_lock desktop_set_user_state "${ARR_RAW[$i]}" "$desired" || ok=1
            err="$CAPTURED_ERR"
            ;;

        system_autostart)
            local sysfile="${ARR_RAW[$i]}" base; base=$(basename -- "$sysfile")
            capture_err with_lock system_autostart_apply \
                "$(user_autostart_dir)/$base" "$sysfile" "$desired" || ok=1
            err="$CAPTURED_ERR"
            ;;

        systemd_user)
            local unit="${ARR_RAW[$i]}" mode="${ARR_MODE[$i]:-enable}" verb="enable" runtime=()
            case "$mode" in
                enable-runtime) runtime=(--runtime) ;;
                mask)            verb="unmask" ;;
                mask-runtime)    verb="unmask"; runtime=(--runtime) ;;
            esac
            [[ "$desired" == "FALSE" ]] && verb="disable"
            [[ "$mode" == "mask" && "$desired" == "FALSE" ]] && verb="mask"
            [[ "$mode" == "mask-runtime" && "$desired" == "FALSE" ]] && verb="mask"
            err=$("$SYSTEMCTL_BIN" --user "$verb" "${runtime[@]}" -- "$unit" 2>&1) || ok=1
            ;;

        systemd_system)
            # System units are handled later as one privileged batch so this
            # screen triggers at most one PolicyKit authentication request.
            ok=1
            ;;

        cron_user)
            capture_err with_lock cron_apply_state "${ARR_RAW[$i]}" "$desired" "${ARR_MODE[$i]:-}" || ok=1
            err="$CAPTURED_ERR"
            ;;
    esac

    (( ok )) && [[ -n "$err" ]] && LAST_ERR[$i]="$err"

    return "$ok"
}

# --------------------------------------------------------------------------
# Apply all changed system units in a single pkexec call so one "OK"
# action requires at most one administrator authentication request.
#
# timeout is used to recover control if PolicyKit hangs.
#
# $1: nameref to the ARR_* index array; every entry must be systemd_system.
# $2: nameref to an associative array receiving "OK"/"FAIL" per unit.
# $3: nameref to an associative array receiving per-unit systemctl errors.
# Global input: SELECTED_IDS, containing the requested state for each index.
# --------------------------------------------------------------------------
PKEXEC_BATCH_ERROR=""   # human-readable reason when the whole batch fails

pkexec_path() { printf '%s\n' /usr/bin/pkexec; }

PRIV_TIMEOUT_BIN=""
PRIV_SYSTEMCTL_BIN=""

privileged_systemctl_path() {
    local path="$PRIV_SYSTEMCTL_BIN"
    if [[ -z "$path" ]]; then
        if [[ -x /usr/bin/systemctl ]]; then
            path=/usr/bin/systemctl
        elif [[ -x /bin/systemctl ]]; then
            path=/bin/systemctl
        else
            return 127
        fi
    fi
    [[ -x "$path" ]] || return 127
    printf '%s\n' "$path"
}

run_privileged_batch() {
    local timeout_bin="$PRIV_TIMEOUT_BIN"
    if [[ -z "$timeout_bin" ]]; then
        if [[ -x /usr/bin/timeout ]]; then
            timeout_bin=/usr/bin/timeout
        elif [[ -x /bin/timeout ]]; then
            timeout_bin=/bin/timeout
        else
            return 127
        fi
    fi
    [[ -x "$timeout_bin" ]] || return 127
    "$timeout_bin" 180 "$(pkexec_path)" /bin/bash -s
}

apply_systemd_system_batch() {
    local -n _idx_ref="$1"
    local -n _res_ref="$2"
    local -n _err_ref="$3"
    local i unit desired mode rc batch_script batch_output line

    PKEXEC_BATCH_ERROR=""

    if [[ ! -x "$(pkexec_path)" ]]; then
        PKEXEC_BATCH_ERROR="$(dependency_message pkexec)"
        for i in "${_idx_ref[@]}"; do _res_ref["${ARR_RAW[$i]}"]="FAIL"; done
        return 1
    fi

    # Best-effort informational check for a graphical PolicyKit agent. Do not
    # abort when it is not detected: process names vary, and pkexec also has
    # an internal textual fallback unless that behavior is disabled.
    local agent_seen=1
    pgrep -f -- 'polkit.*authentication-agent|polkit-gnome|polkit-mate|polkit-kde|lxpolkit|xfce-polkit' &>/dev/null || agent_seen=0

    local systemctl_bin
    systemctl_bin=$(privileged_systemctl_path) || {
        PKEXEC_BATCH_ERROR="$(msg pkexec_fail)"
        for i in "${_idx_ref[@]}"; do _res_ref["${ARR_RAW[$i]}"]="FAIL"; done
        return 1
    }

    batch_script=$(cat <<'BASH'
#!/bin/bash
set -u
set -o pipefail
apply_unit() {
    local out rc unit="${@: -1}"
    local -a cmd=("${@:1:$(($#-1))}")
    out=$("$SYSTEMCTL_BIN" "${cmd[@]}" -- "$unit" 2>&1 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/[[:space:]]*$//')
    rc=$?
    if (( rc == 0 )); then printf 'OK\x1f%s\x1f\n' "$unit"
    else printf 'FAIL\x1f%s\x1f%s\n' "$unit" "$out"; fi
}
BASH
)
    printf -v systemctl_line 'SYSTEMCTL_BIN=%q\n' "$systemctl_bin"
    batch_script="${systemctl_line}${batch_script}"
    batch_script+=$'\n'
    for i in "${_idx_ref[@]}"; do
        unit="${ARR_RAW[$i]}"
        mode="${ARR_MODE[$i]:-enable}"
        desired="FALSE"
        [[ -n "${SELECTED_IDS[$i]:-}" ]] && desired="TRUE"
        case "$mode" in
            enable-runtime)
                [[ "$desired" == "TRUE" ]] && printf -v line 'apply_unit enable --runtime %q\n' "$unit" \
                                            || printf -v line 'apply_unit disable --runtime %q\n' "$unit"
                ;;
            mask)
                [[ "$desired" == "TRUE" ]] && printf -v line 'apply_unit unmask %q\n' "$unit" \
                                            || printf -v line 'apply_unit mask %q\n' "$unit"
                ;;
            mask-runtime)
                [[ "$desired" == "TRUE" ]] && printf -v line 'apply_unit unmask --runtime %q\n' "$unit" \
                                            || printf -v line 'apply_unit mask --runtime %q\n' "$unit"
                ;;
            *)
                [[ "$desired" == "TRUE" ]] && printf -v line 'apply_unit enable %q\n' "$unit" \
                                            || printf -v line 'apply_unit disable %q\n' "$unit"
                ;;
        esac
        batch_script+="$line"
    done

    batch_output=$(run_privileged_batch <<< "$batch_script")
    rc=$?

    if (( rc != 0 )); then
        case "$rc" in
            124) PKEXEC_BATCH_ERROR="$(msg pkexec_timeout)" ;;
            126) PKEXEC_BATCH_ERROR="$(msg pkexec_cancel)" ;;
            127) PKEXEC_BATCH_ERROR="$(msg pkexec_fail)" ;;
            *)   PKEXEC_BATCH_ERROR="$(msg pkexec_unexpected "$rc")" ;;
        esac
        if (( ! agent_seen )); then
            PKEXEC_BATCH_ERROR+="$(msg pkexec_no_agent)"
        fi
    fi

    # Parse any per-unit records returned after a partial batch failure; earlier
    # units may already have been changed successfully.
    local st u errmsg
    while IFS=$'\x1f' read -r st u errmsg; do
        [[ -n "$u" ]] || continue
        _res_ref["$u"]="$st"
        [[ "$st" == "FAIL" && -n "$errmsg" ]] && _err_ref["$u"]="$errmsg"
    done <<< "$batch_output"

    for i in "${_idx_ref[@]}"; do
        unit="${ARR_RAW[$i]}"
        [[ -z "${_res_ref[$unit]:-}" ]] && _res_ref["$unit"]="FAIL"
    done

    return "$rc"
}

# --------------------------------------------------------------------------
# File editor / viewer
# --------------------------------------------------------------------------
# Text editors in order of preference. The native editor of the current desktop
# goes first (XDG_CURRENT_DESKTOP is a colon-separated list).
EDITOR_LIST=()
set_editor_list() {
    local desktop=":${XDG_CURRENT_DESKTOP:-}:" native=()
    desktop="${desktop,,}"
    case "$desktop" in
        *:kde:*)               native=(kate kwrite) ;;
        *:gnome:*|*:budgie:*)  native=(gnome-text-editor gedit) ;;
        *:xfce:*)              native=(mousepad) ;;
        *:mate:*)              native=(pluma) ;;
        *:x-cinnamon:*)        native=(xed) ;;
        *:lxqt:*)              native=(featherpad) ;;
        *:lxde:*)              native=(leafpad) ;;
        *:pantheon:*)          native=(io.elementary.code) ;;
        *:cosmic:*)            native=(cosmic-edit) ;;
    esac
    EDITOR_LIST=("${native[@]}" xed gedit gnome-text-editor kate kwrite pluma mousepad
                 featherpad leafpad geany io.elementary.code cosmic-edit)
}

pick_editor() {
    local e
    set_editor_list
    for e in "${EDITOR_LIST[@]}"; do
        command -v "$e" &>/dev/null && { echo "$e"; return; }
    done
    echo "xdg-open"
}

is_trusted_root_chain() {
    local path="$1" cur owner mode
    [[ "$path" == /* && -e "$path" ]] || return 1

    cur="$path"
    while :; do
        owner=$(/usr/bin/stat -c '%u' -- "$cur" 2>/dev/null) || return 1
        [[ "$owner" == 0 ]] || return 1
        mode=$(/usr/bin/stat -c '%a' -- "$cur" 2>/dev/null) || return 1
        (( 8#$mode & 0022 )) && return 1
        [[ "$cur" == / ]] && return 0
        cur="${cur%/*}"
        [[ -n "$cur" ]] || cur=/
    done
}

pick_editor_root() {
    local dir e path
    set_editor_list
    for dir in /usr/local/bin /usr/bin /bin; do
        for e in "${EDITOR_LIST[@]}"; do
            path="$dir/$e"
            [[ -x "$path" && -f "$path" ]] || continue
            is_trusted_system_file "$path" || continue
            printf '%s\n' "$path"
            return 0
        done
    done
    return 1
}

is_trusted_system_file() {
    local path="$1" resolved
    [[ "$path" == /* && ( -e "$path" || -L "$path" ) ]] || return 1
    is_trusted_root_chain "$path" || return 1

    resolved=$(/usr/bin/readlink -f -- "$path" 2>/dev/null) || return 1
    [[ -f "$resolved" ]] || return 1
    is_trusted_root_chain "$resolved" || return 1
    return 0
}

edit_file() {
    local editor
    editor=$(pick_editor)
    "$editor" "$1" &>/dev/null &
}

run_pkexec() {
    "$(pkexec_path)" "$@"
}

edit_file_root() {
    # pkexec sanitizes the environment and normally does not pass DISPLAY or
    # XAUTHORITY to the privileged program, so a graphical editor would not
    # connect otherwise. Resolve editors only from root-owned, non-writable
    # system directories so the user's PATH cannot influence the privileged call.
    local editor
    [[ -x "$(pkexec_path)" ]] || { printf '%s\n' "$(dependency_message pkexec)" >&2; return 1; }
    editor=$(pick_editor_root) || return 1
    run_pkexec /usr/bin/env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
        "$editor" "$1" &>/dev/null &
}

smart_edit() {
    # System desktop entries and systemd unit files are normally readable by an
    # unprivileged user. Use pkexec only for a trusted system path when direct
    # access is unavailable.
    local f="$1"
    if [[ -r "$f" ]]; then
        edit_file "$f"
    elif is_trusted_system_file "$f"; then
        edit_file_root "$f"
    else
        printf '%s\n' "$(msg untrusted_system_file)" >&2
        return 1
    fi
}

open_item() {
    local i="$1" kind="${ARR_KIND[$1]}"
    case "$kind" in
        user_autostart)
            edit_file "${ARR_RAW[$i]}"
            ;;
        system_autostart)
            local sysfile="${ARR_RAW[$i]}" base override
            base=$(basename -- "$sysfile")
            override="$(user_autostart_dir)/$base"
            if [[ -f "$override" ]]; then
                edit_file "$override"
            else
                smart_edit "$sysfile"
            fi
            ;;
        systemd_user)
            local path
            path=$("$SYSTEMCTL_BIN" --user show -p FragmentPath --value -- "${ARR_RAW[$i]}" 2>/dev/null)
            if [[ -n "$path" ]]; then smart_edit "$path"; else
                zen --info --title="$(msg info_title)" --text="$(msg unit_missing)" --width=300
            fi
            ;;
        systemd_system)
            local path
            path=$("$SYSTEMCTL_BIN" show -p FragmentPath --value -- "${ARR_RAW[$i]}" 2>/dev/null)
            if [[ -n "$path" ]]; then smart_edit "$path"; else
                zen --info --title="$(msg info_title)" --text="$(msg unit_missing)" --width=300
            fi
            ;;
        cron_user)
            zen --info --title="$(msg cron_edit_title)" --width=420 \
                --text="$(msg cron_edit_text)"
            ;;
    esac
}

# "Open/view source" browser limited to the indices of the current tab
# ($1 is a nameref to an ARR_* index array).
browse_and_open() {
    local -n _idx_ref="$1"
    local rows=() i sel browse_text name_cell
    for i in "${_idx_ref[@]}"; do
        esc_markup_v "${ARR_NAME[$i]}"; name_cell="$ESC_V"
        display_path_v "${ARR_SRC[$i]}"; esc_markup_v "$DISP_V"
        rows+=("$i" "${ARR_TYPE[$i]}" "$name_cell" "$ESC_V")
    done
    browse_text=$(msg browse_text)
    sel=$(zen --list --title="$(msg browse_title)" --text="$browse_text" \
        --width=1000 --height="$(fit_height "$browse_text" "${#_idx_ref[@]}")" \
        --column="$(msg col_id)" --column="$(msg col_type)" --column="$(msg col_name)" --column="$(msg col_source)" \
        --print-column=1 --hide-column=1 \
        -- "${rows[@]}")
    [[ -z "$sel" || ! "$sel" =~ ^[0-9]+$ ]] && return
    open_item "$sel"
}

# --------------------------------------------------------------------------
# Render one category as a checklist. $1 is a category id or "ALL".
# OK applies the checked states and shows the result; the list stays open.
# Cancel returns to the category hub rather than terminating the program.
# --------------------------------------------------------------------------
show_category_checklist() {
    local cat="$1" FILTER="" cat_label cat_icon
    if [[ "$cat" == "ALL" ]]; then
        cat_label="$(msg category_missing)"
        cat_icon="🔍"
    else
        cat_label="${CATEGORY_LABEL[$cat]}"
        cat_icon="${CATEGORY_ICON[$cat]}"
    fi

    while true; do
        refresh_items
        local -a CAT_ALL=()
        category_indices "$cat" CAT_ALL
        if [[ ${#CAT_ALL[@]} -eq 0 ]]; then
            zen --info --title="$cat_icon $cat_label" --width=380 \
                --text="$(msg empty_category "$cat_label")"
            return
        fi

        # --- Build visible rows using the current tab filter. ---
        local rows=() shown_indices=() i haystack type_cell name_cell filter_display
        filter_display="$FILTER"
        [[ -n "$filter_display" ]] || filter_display="$(msg no_filter)"
        for i in "${CAT_ALL[@]}"; do
            if [[ -n "$FILTER" ]]; then
                haystack="${ARR_TYPE[$i],,} ${ARR_NAME[$i],,} ${ARR_SRC[$i],,} ${ARR_STATUS_LABEL[$i],,}"
                [[ "$haystack" != *"${FILTER,,}"* ]] && continue
            fi
            shown_indices+=("$i")
            # Prefix combined-view rows with their source category so the item
            # can be located again in its dedicated tab.
            type_cell="${ARR_TYPE[$i]}"
            [[ "$cat" == "ALL" ]] && { category_tag_v "$i"; type_cell="${CATTAG_V}${type_cell}"; }
            # Name and Source can contain dynamic shell syntax, so escape them
            # before passing the values to Zenity/Pango.
            esc_markup_v "${ARR_NAME[$i]}"; name_cell="$ESC_V"
            display_path_v "${ARR_SRC[$i]}"; esc_markup_v "$DISP_V"
            rows+=("${ARR_STATUS[$i]}" "$i" "$type_cell" "$name_cell" \
                   "${ARR_STATUS_LABEL[$i]}" "$ESC_V")
        done

        if [[ ${#shown_indices[@]} -eq 0 ]]; then
            if zen --question --width=400 --title="$(msg no_results_title)" \
                --ok-label="$(msg clear_filter)" --cancel-label="$(msg back)" \
                --text="$(msg no_match "$cat_label" "$(esc_markup "$FILTER")")"; then
                FILTER=""
            else
                return
            fi
            continue
        fi

        # OK applies the checked states and Cancel leaves the category. Search and Open are
        # extra buttons: Zenity 3.44 and 4.x print the label of the pressed one and exit 1,
        # whereas Cancel exits 1 with no output.
        local output rc list_text find_label open_label
        find_label=$(msg find_filter)
        open_label=$(msg open_btn)
        list_text=$(msg checklist_text "$(esc_markup "$filter_display")" "${#shown_indices[@]}" "${#CAT_ALL[@]}")
        output=$(zen --list --checklist \
            --title="$cat_icon $cat_label" \
            --text="$list_text" \
            --width=1180 --height="$(fit_height "$list_text" "${#shown_indices[@]}" check)" \
            --extra-button="$find_label" --extra-button="$open_label" \
            --column="$(msg col_active)" --column="$(msg col_id)" --column="$(msg col_type)" --column="$(msg col_name)" \
            --column="$(msg col_status)" --column="$(msg col_source)" \
            --print-column=2 --separator="$SEP" --hide-column=2 \
            -- "${rows[@]}")
        rc=$?

        if [[ $rc -ne 0 ]]; then
            case "$output" in
                "$(extra_label "$find_label")")
                    local newfilter
                    if newfilter=$(zen --entry --title="$(msg filter_title "$cat_label")" --width=460 \
                        --text="$(msg filter_text)" --entry-text="$FILTER"); then
                        FILTER="$newfilter"
                    fi
                    ;;
                "$(extra_label "$open_label")")
                    browse_and_open shown_indices
                    ;;
                *) return ;;
            esac
            continue
        fi

        # --- Rebuild the checked ID set. ---
        # Print only column 2 (the hidden ID column). Printing ALL from a Zenity
        # checklist omits the checkbox column and shifts the returned fields.
        local -A SELECTED_IDS=()
        local -a tokens
        IFS="$SEP" read -r -a tokens <<< "$output"
        local id
        for id in "${tokens[@]}"; do
            [[ "$id" =~ ^[0-9]+$ ]] && SELECTED_IDS["$id"]=1
        done

        # --- Items whose box differs from their current state. ---
        local -a pending=()
        local now
        for i in "${shown_indices[@]}"; do
            now="FALSE"
            [[ -n "${SELECTED_IDS[$i]:-}" ]] && now="TRUE"
            [[ "${ARR_STATUS[$i]}" != "$now" ]] && pending+=("$i")
        done
        if (( ${#pending[@]} == 0 )); then
            unset SELECTED_IDS
            zen --info --title="$(msg info_title)" --width=420 --text="$(msg no_selection)"
            continue
        fi

        # --- Extra confirmation before disabling sensitive items. ---
        # Cancelling it cancels every pending change from this screen, preventing
        # a later non-critical change from unexpectedly triggering authentication.
        local crit_list=()
        for i in "${pending[@]}"; do
            [[ "${ARR_STATUS[$i]}" == "TRUE" && -z "${SELECTED_IDS[$i]:-}" ]] || continue   # only disabling matters here
            item_is_critical "$i" && crit_list+=("$i")
        done
        if [[ ${#crit_list[@]} -gt 0 ]]; then
            local cw="" ci
            for ci in "${crit_list[@]}"; do cw+="• $(esc_markup "${ARR_NAME[$ci]}")\n"; done
            if ! zen --question --title="$(msg critical_title)" --width=520 \
                --ok-label="$(msg critical_ok)" --cancel-label="$(msg critical_cancel)" \
                --text="$(msg critical_text "$cw")"; then
                unset SELECTED_IDS
                continue
            fi
        fi

        # --- Apply the pending changes. ---
        # System units are collected separately and sent through one pkexec
        # batch. Reset the batch diagnostic before each pass.
        PKEXEC_BATCH_ERROR=""
        local changes=0 failures=0 summary="" fail_summary="" action
        local -a sys_batch=()
        for i in "${pending[@]}"; do
            now="FALSE"
            [[ -n "${SELECTED_IDS[$i]:-}" ]] && now="TRUE"

            if [[ "${ARR_KIND[$i]}" == "systemd_system" ]]; then
                sys_batch+=("$i")
                continue
            fi

            if set_item_state "$i" "$now"; then
                changes=$((changes + 1))
                action="$(msg disabled_action)"
                [[ "$now" == "TRUE" ]] && action="$(msg enabled_action)"
                summary+="• $action: $(esc_markup "${ARR_NAME[$i]}")\n"
            else
                failures=$((failures + 1))
                fail_summary+="• $(esc_markup "${ARR_NAME[$i]}")"
                [[ -n "${LAST_ERR[$i]:-}" ]] && fail_summary+="\n   ↳ $(esc_markup "${LAST_ERR[$i]}")"
                fail_summary+="\n"
            fi
        done

        # --- System units: one pkexec pass. ---
        if (( ${#sys_batch[@]} > 0 )); then
            local -A SYS_RESULT=() SYS_ERR=()
            local unit
            apply_systemd_system_batch sys_batch SYS_RESULT SYS_ERR
            for i in "${sys_batch[@]}"; do
                unit="${ARR_RAW[$i]}"
                now="FALSE"
                [[ -n "${SELECTED_IDS[$i]:-}" ]] && now="TRUE"
                if [[ "${SYS_RESULT[$unit]:-FAIL}" == "OK" ]]; then
                    changes=$((changes + 1))
                    action="$(msg disabled_action)"
                    [[ "$now" == "TRUE" ]] && action="$(msg enabled_action)"
                    summary+="• $action: $(esc_markup "${ARR_NAME[$i]}")\n"
                else
                    failures=$((failures + 1))
                    fail_summary+="• $(esc_markup "${ARR_NAME[$i]}")"
                    [[ -n "${SYS_ERR[$unit]:-}" ]] && fail_summary+="\n   ↳ $(esc_markup "${SYS_ERR[$unit]}")"
                    fail_summary+="\n"
                fi
            done
            unset SYS_RESULT SYS_ERR
        fi
        unset SELECTED_IDS
        (( changes > 0 || failures > 0 )) && ITEMS_DIRTY=1   # reload after failures too: external state may have changed

        # --- Report what was done, then return to this list. ---
        if (( changes > 0 && failures == 0 )); then
            zen --info --title="$(msg all_ok_title)" --width=540 \
                --text="$(msg all_ok_text "$changes" "$summary")"
        elif (( changes > 0 && failures > 0 )); then
            zen --info --title="$(msg applied_title)" --width=540 \
                --text="$(msg applied_text "$changes" "$summary")"
        fi
        if (( failures > 0 )); then
            local reason=""
            if [[ -n "$PKEXEC_BATCH_ERROR" ]]; then
                reason="$(esc_markup "$PKEXEC_BATCH_ERROR")\n\n"
            elif [[ "$fail_summary" != *"↳"* ]]; then
                # Use the generic diagnostic only when neither the batch nor an
                # individual operation supplied a concrete error.
                reason="$(msg generic_permission)"
            fi
            zen --warning --title="$(msg failure_title)" --width=560 \
                --text="$(msg failure_text "$failures" "$reason" "$fail_summary")"
        fi
        # The loop now rebuilds this list from the updated inventory.
    done
}

# --------------------------------------------------------------------------
# Main category hub. Zenity has no native tabs in the supported version, so
# a selection list opens one checklist per category and returns here on close.
# --------------------------------------------------------------------------
main_loop() {
    detect_zenity_major
    while true; do
        refresh_items
        if [[ ${#ARR_NAME[@]} -eq 0 ]]; then
            zen --info --title="$(msg main_title)" --text="$(msg no_start)" --width=300
            break
        fi

        # One pass over the inventory counts every category.
        local cat i rows=()
        local -a cat_n=(0 0 0 0 0 0) cat_dis=(0 0 0 0 0 0)
        for i in "${!ARR_NAME[@]}"; do
            item_category_v "$i"
            [[ -n "$CAT_OF" ]] || continue
            cat_n[CAT_OF]=$(( cat_n[CAT_OF] + 1 ))
            [[ "${ARR_STATUS[$i]}" == "FALSE" ]] && cat_dis[CAT_OF]=$(( cat_dis[CAT_OF] + 1 ))
        done
        for cat in 1 2 3 4 5; do
            msg_v summary_item "${cat_n[$cat]}" "${cat_dis[$cat]}"
            rows+=("$cat" "${CATEGORY_ICON[$cat]} ${CATEGORY_LABEL[$cat]}" "$MSGV")
        done
        # L is an internal action ID; the row itself is the documented GUI control.
        rows+=("L" "$(msg lang_switch)" "$(msg lang_hint)")
        rows+=("0" "$(msg search_all)" "")

        local sel rc menu_text
        menu_text=$(msg menu_text)
        sel=$(zen --list --title="$(msg main_title)" \
            --text="$menu_text" \
            --width=680 --height="$(fit_height "$menu_text" $(( ${#rows[@]} / 3 )))" \
            --cancel-label="$(msg menu_exit)" \
            --column="$(msg col_id)" --column="$(msg category_col)" --column="$(msg summary_col)" \
            --print-column=1 --hide-column=1 \
            -- "${rows[@]}")
        rc=$?
        [[ $rc -ne 0 || -z "$sel" ]] && break

        case "$sel" in
            L)
                [[ "$LANG_UI" == es ]] && LANG_UI=en || LANG_UI=es
                init_categories
                relabel_items
                ;;
            0)   show_category_checklist "ALL" ;;
            [1-5]) show_category_checklist "$sel" ;;
        esac
    done
}

# Launcher icon (128x128 PNG8, base64): the installed script needs no extra files.
# Derived from assets/autostart-manager.png; tests/test_icon.sh checks the match.
embedded_icon_b64() {
    cat <<'ICON'
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
AElFTkSuQmCC
ICON
}

# --------------------------------------------------------------------------
# User-level installation (--install). Nothing needs root. The manifest lists
# every installed file with its SHA-256 and every directory this tool created,
# so a later removal touches nothing else. It is written before the files: an
# interrupted install stays removable and can be finished by running it again.
# --------------------------------------------------------------------------
INST_BIN="" INST_DESKTOP="" INST_ICON="" INST_MANIFEST=""
INST_FILES=() INST_KNOWN_DIRS=() INST_DIRS=() INST_OLD_DIRS=()
declare -A INST_SRC=() INST_MODE=() INST_HASH=() INST_OLD_HASH=()

install_is_root() { (( EUID == 0 )); }

install_paths() {
    # Fixed per-user locations; XDG_DATA_HOME is honored only when absolute.
    local data="${XDG_DATA_HOME:-}" f d
    [[ "$data" == /* ]] || data="$HOME/.local/share"
    data="${data%/}"
    INST_BIN="$HOME/.local/bin/autostart-manager"
    INST_DESKTOP="$data/applications/autostart-manager.desktop"
    INST_ICON="$data/icons/hicolor/128x128/apps/autostart-manager.png"
    INST_MANIFEST="$data/autostart-manager/install.manifest"
    INST_FILES=("$INST_BIN" "$INST_DESKTOP" "$INST_ICON")
    INST_KNOWN_DIRS=()
    for f in "${INST_FILES[@]}" "$INST_MANIFEST"; do
        d=$(dirname -- "$f")
        while [[ "$d" != / && "$d" != "$HOME" ]]; do
            INST_KNOWN_DIRS+=("$d")
            d=$(dirname -- "$d")
        done
    done
}

# Exec value for a desktop entry: the path as one double-quoted argument.
desktop_exec_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\`/\\\`}"
    s="${s//\$/\\\$}"
    s="${s//%/%%}"
    s="${s//\\/\\\\}"
    printf '"%s"' "$s"
}

install_launcher() {
    printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Version=1.0' \
        "Name=$(LANG_UI=en msg launcher_name)" "Name[es]=$(LANG_UI=es msg launcher_name)" \
        "Comment=$(LANG_UI=en msg launcher_comment)" "Comment[es]=$(LANG_UI=es msg launcher_comment)" \
        "Exec=$(desktop_exec_quote "$INST_BIN")" 'Icon=autostart-manager' 'Terminal=false' \
        'Categories=Settings;'
}

install_missing_dirs() {
    # Directories from $1 upwards that do not exist yet, shallowest first.
    local d="$1" chain=()
    while [[ "$d" != / && ! -e "$d" && ! -L "$d" ]]; do
        chain=("$d" "${chain[@]}")
        d=$(dirname -- "$d")
    done
    (( ${#chain[@]} )) && printf '%s\n' "${chain[@]}"
    return 0
}

install_manifest_load() {
    # Read the manifest into INST_OLD_HASH / INST_OLD_DIRS; unknown paths are ignored.
    local kind field path known
    INST_OLD_HASH=() INST_OLD_DIRS=()
    [[ -f "$INST_MANIFEST" && ! -L "$INST_MANIFEST" ]] || return 0
    while IFS=$'\t' read -r kind field path || [[ -n "$kind" ]]; do
        case "$kind" in
            F)  [[ "$field" =~ ^[0-9a-f]{64}$ ]] || continue
                for known in "${INST_FILES[@]}"; do
                    [[ "$path" == "$known" ]] && INST_OLD_HASH["$path"]="$field"
                done ;;
            D)  for known in "${INST_KNOWN_DIRS[@]}"; do
                    [[ "$path" == "$known" ]] && INST_OLD_DIRS+=("$path")
                done ;;
        esac
    done < "$INST_MANIFEST"
    return 0
}

install_collect_dirs() {
    # INST_DIRS = directories recorded by an earlier install + those created now,
    # shallowest first.
    local -A seen=()
    local d p n
    for d in "${INST_OLD_DIRS[@]}"; do seen["$d"]=1; done
    for p in "${INST_FILES[@]}" "$INST_MANIFEST"; do
        while IFS= read -r d; do
            [[ -n "$d" ]] && seen["$d"]=1
        done < <(install_missing_dirs "$(dirname -- "$p")")
    done
    INST_DIRS=()
    while IFS=$'\t' read -r _ d; do
        INST_DIRS+=("$d")
    done < <(
        for d in "${!seen[@]}"; do
            n="${d//[^\/]/}"
            printf '%d\t%s\n' "${#n}" "$d"
        done | LC_ALL=C sort -t $'\t' -k1,1n -k2
    )
}

install_manifest_text() {
    local f d
    printf '%s\n' '# autostart-manager install manifest 1'
    for f in "${INST_FILES[@]}"; do printf 'F\t%s\t%s\n' "${INST_HASH[$f]}" "$f"; done
    for d in "${INST_DIRS[@]}"; do printf 'D\t-\t%s\n' "$d"; done
}

install_stage() {
    # Prepare every file to install ($1 = source script) and hash it.
    local icon desktop
    icon=$(mktemp) || return 1
    TMP_FILES+=("$icon")
    desktop=$(mktemp) || return 1
    TMP_FILES+=("$desktop")
    embedded_icon_b64 | base64 -d > "$icon" || return 1
    install_launcher > "$desktop" || return 1
    INST_SRC=() INST_MODE=() INST_HASH=()
    INST_SRC["$INST_BIN"]="$1" INST_MODE["$INST_BIN"]=755
    INST_SRC["$INST_DESKTOP"]="$desktop" INST_MODE["$INST_DESKTOP"]=644
    INST_SRC["$INST_ICON"]="$icon" INST_MODE["$INST_ICON"]=644
    local f
    for f in "${INST_FILES[@]}"; do
        INST_HASH["$f"]=$(file_sha256 "${INST_SRC[$f]}") || return 1
    done
}

install_check_targets() {
    # An existing file is replaced only if an earlier install owns it or it is identical.
    local f
    for f in "${INST_FILES[@]}"; do
        [[ -e "$f" || -L "$f" ]] || continue
        if [[ -L "$f" || ! -f "$f" ]]; then
            printf '%s\n' "$(msg install_not_regular "$(display_path "$f")")" >&2
            return 1
        fi
        [[ -n "${INST_OLD_HASH[$f]:-}" || "$(file_sha256 "$f")" == "${INST_HASH[$f]}" ]] && continue
        printf '%s\n' "$(msg install_foreign "$(display_path "$f")")" >&2
        return 1
    done
}

install_is_current() {
    local f
    [[ -f "$INST_MANIFEST" && "$(<"$INST_MANIFEST")" == "$(install_manifest_text)" ]] || return 1
    for f in "${INST_FILES[@]}"; do
        [[ -f "$f" && ! -L "$f" && "$(file_sha256 "$f")" == "${INST_HASH[$f]}" \
            && "$(stat -c '%a' -- "$f")" == "${INST_MODE[$f]}" ]] || return 1
    done
}

install_write() {
    local f
    atomic_write "$INST_MANIFEST" "$(install_manifest_text)"$'\n' 600 || return 1
    for f in "${INST_FILES[@]}"; do
        atomic_place "${INST_SRC[$f]}" "$f" "${INST_MODE[$f]}" || return 1
        if [[ "$(file_sha256 "$f")" != "${INST_HASH[$f]}" ]]; then
            printf '%s\n' "$(msg install_mismatch "$(display_path "$f")")" >&2
            return 1
        fi
    done
}

install_prepare() {
    # Checks shared by --install and --uninstall; sets the INST_* paths.
    local f
    if install_is_root && [[ "${AUTOSTART_MANAGER_TEST:-0}" != 1 ]]; then
        printf '%s\n' "$(msg install_no_root)" >&2
        return 1
    fi
    if [[ "${HOME:-}" != /* ]]; then
        printf '%s\n' "$(msg install_bad_home)" >&2
        return 1
    fi
    install_paths
    for f in "${INST_FILES[@]}" "$INST_MANIFEST" "$(state_dir)"; do
        if [[ "$f" == *[[:cntrl:]]* ]]; then
            printf '%s\n' "$(msg install_bad_path "$f")" >&2
            return 1
        fi
    done
}

install_main() {
    local src="${BASH_SOURCE[0]}" f
    install_prepare || return 1
    if [[ ! -f "$src" || ! -r "$src" ]]; then
        printf '%s\n' "$(msg install_bad_source "$src")" >&2
        return 1
    fi
    install_manifest_load
    install_stage "$src" || return 1
    install_check_targets || return 1
    install_collect_dirs
    if install_is_current; then
        printf '%s\n' "$(msg install_current "$VERSION")"
    else
        if ! install_write; then
            printf '%s\n' "$(msg install_failed)" >&2
            return 1
        fi
        printf '%s\n' "$(msg install_done "$VERSION")"
        printf '  %s\n' "$(display_path "$INST_BIN")" "$(display_path "$INST_DESKTOP")" "$(display_path "$INST_ICON")"
    fi
    command -v zenity &>/dev/null || printf '%s\n' "$(dependency_message zenity)" >&2
    case ":${PATH:-}:" in
        *":$HOME/.local/bin:"*) ;;
        *) printf '%s\n' "$(msg install_path_hint "$(display_path "$HOME/.local/bin")")" >&2 ;;
    esac
    return 0
}

uninstall_remove_files() {
    # Remove each file an earlier install recorded, unless it was modified since
    # (--purge removes it anyway). Fills UNINST_REMOVED; returns 1 if any is kept.
    local f status=0
    for f in "${INST_FILES[@]}"; do
        [[ -n "${INST_OLD_HASH[$f]:-}" && ( -e "$f" || -L "$f" ) ]] || continue
        if [[ -L "$f" || ! -f "$f" ]]; then
            printf '%s\n' "$(msg install_not_regular "$(display_path "$f")")" >&2
            status=1
        elif [[ "$UNINSTALL_STATE" != purge && "$(file_sha256 "$f")" != "${INST_OLD_HASH[$f]}" ]]; then
            printf '%s\n' "$(msg uninstall_modified "$(display_path "$f")")" >&2
            status=1
        elif atomic_remove "$f" 2>/dev/null; then
            UNINST_REMOVED+=("$f")
        else
            printf '%s\n' "$(msg uninstall_failed "$(display_path "$f")")" >&2
            status=1
        fi
    done
    return "$status"
}

uninstall_state() {
    # The crontab backup is the only state the program keeps. Without a
    # terminal there is nobody to ask, so it is kept.
    local bak answer=n
    bak="$(state_dir)/crontab.bak"
    [[ -e "$bak" || -L "$bak" ]] || return 0
    case "$UNINSTALL_STATE" in
        purge) answer=y ;;
        ask)
            if [[ -t 0 ]]; then
                printf '%s' "$(msg uninstall_ask "$(display_path "$bak")")" >&2
                read -r answer || answer=n
            fi
            answer="${answer,,}"
            ;;
    esac
    case "$answer" in
        y|yes|s|si|sí)
            if atomic_remove "$bak" 2>/dev/null; then
                UNINST_REMOVED+=("$bak")
                rmdir -- "$(state_dir)" 2>/dev/null
            else
                printf '%s\n' "$(msg uninstall_failed "$(display_path "$bak")")" >&2
                return 1
            fi
            ;;
        *) printf '%s\n' "$(msg uninstall_state_kept "$(display_path "$bak")")" >&2 ;;
    esac
    return 0
}

uninstall_main() {
    local status=0 f i
    UNINST_REMOVED=()
    install_prepare || return 1
    install_manifest_load
    uninstall_remove_files || status=1
    # The manifest goes last and only when nothing is kept, so a later
    # --uninstall --purge can still finish the job.
    if (( status == 0 )) && [[ -f "$INST_MANIFEST" && ! -L "$INST_MANIFEST" ]]; then
        if atomic_remove "$INST_MANIFEST" 2>/dev/null; then
            UNINST_REMOVED+=("$INST_MANIFEST")
        else
            printf '%s\n' "$(msg uninstall_failed "$(display_path "$INST_MANIFEST")")" >&2
            status=1
        fi
    fi
    # Directories this tool created, deepest first; rmdir only removes empty ones.
    for (( i = ${#INST_OLD_DIRS[@]} - 1; i >= 0; i-- )); do
        rmdir -- "${INST_OLD_DIRS[i]}" 2>/dev/null
    done
    uninstall_state || status=1
    if (( ${#UNINST_REMOVED[@]} )); then
        printf '%s\n' "$(msg uninstall_done)"
        for f in "${UNINST_REMOVED[@]}"; do printf '  %s\n' "$(display_path "$f")"; done
    elif (( status == 0 )); then
        printf '%s\n' "$(msg uninstall_none "$(display_path "$INST_MANIFEST")")"
    fi
    return "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "$CLI_ACTION" in
        install) install_main; exit $? ;;
        uninstall) uninstall_main; exit $? ;;
    esac
    if [[ "${AUTOSTART_MANAGER_TEST:-0}" != "1" ]]; then
        main_loop
    fi
    exit 0
fi
