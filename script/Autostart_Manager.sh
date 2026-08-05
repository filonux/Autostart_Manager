#!/bin/bash
#
# Autostart_Manager.sh
# ---------------------------------------------------------------------------
# Gestor gráfico de arranque automático para Linux Mint 22.3 (Cinnamon)
#
# Copyright (C) 2026 Filonux
#
# Licencia:
#   Autostart Manager es software libre distribuido bajo los términos de la
#   GNU General Public License versión 3 (GPLv3).
#   Consulte el archivo LICENSE para obtener el texto completo de la
#   licencia.
#
# Muestra en una sola tabla:
#   - Aplicaciones de ~/.config/autostart          (autostart de usuario)
#   - Aplicaciones de /etc/xdg/autostart            (autostart del sistema)
#   - Servicios systemd --user                      (enabled/disabled/estáticos)
#   - Servicios systemd del sistema                 (enabled/disabled/estáticos)
#   - Tareas cron del usuario (crontab -l)
#
# Permite activar/desactivar cada elemento marcando o desmarcando su casilla,
# filtrar la lista por texto, y abrir/ver el archivo de origen de cualquier
# elemento.
#
# Requisitos: zenity, systemd, (opcional) cron/crontab, un editor de texto
#             (xed, gedit, gnome-text-editor, kate o mousepad).
# Los cambios en servicios del sistema piden contraseña vía pkexec (PolicyKit).
# Iconos de diálogo: se usa --icon (--icon-name/--window-icon están obsoletas
# desde zenity 4.0 y se eliminarán en la 4.4; Mint 22.3 trae zenity 4.0.1).
#
# Uso:  ./Autostart_Manager.sh
# ---------------------------------------------------------------------------

VERSION="1.0.0"

case "${1:-}" in
    -h|--help)
        cat <<EOF
Gestor gráfico de arranque automático para Linux Mint 22.3 (Cinnamon).

Uso: $(basename -- "$0") [-h|--help] [-v|--version]

Sin argumentos, abre la interfaz gráfica (requiere zenity).
  -h, --help     Muestra esta ayuda y termina.
  -v, --version  Muestra la versión y termina.
EOF
        exit 0
        ;;
    -v|--version)
        echo "Autostart Manager $VERSION"
        exit 0
        ;;
esac

shopt -s nullglob
set -o pipefail

SEP=$'\x1f'   # separador no imprimible, para no chocar con texto normal

TMP_FILES=()  # temporales creados durante la ejecución, para limpieza garantizada
trap '((${#TMP_FILES[@]})) && rm -f "${TMP_FILES[@]}"' EXIT

# --------------------------------------------------------------------------
# Comprobaciones iniciales
# --------------------------------------------------------------------------
if ! command -v zenity &>/dev/null; then
    echo "Falta 'zenity'. Instálalo con:  sudo apt install zenity"
    exit 1
fi

# Con locale no-UTF8 (típico al lanzar desde acceso directo/atajo con
# entorno reducido), zenity/GLib aborta con "This option is not
# available..." si --title/--text/--ok-label/etc. llevan algún byte
# no-ASCII (emoji, tildes, ñ). Doble defensa:
#  1) Forzar aquí una locale UTF-8 (con C.UTF-8 de glibc como último
#     recurso, siempre presente en Mint 22.3/Ubuntu 24.04).
#  2) zen()+ascii_safe() más abajo: pase lo que pase con la locale, esas
#     opciones concretas nunca llevan un byte no-ASCII. Los datos de las
#     tablas (--list/--checklist) no sufren este bug y conservan tildes/
#     emoji sin tocar.
if [[ "$(locale charmap 2>/dev/null)" != *UTF-8* ]]; then
    for cand in "${LANG%%.*}" "${LANG%%_*}" es_ES en_US C; do
        [[ -z "$cand" ]] && continue
        utf8_locale=$(locale -a 2>/dev/null | grep -iE "^${cand}\.utf-?8$" | head -n1)
        [[ -n "$utf8_locale" ]] && { export LC_ALL="$utf8_locale" LANG="$utf8_locale"; break; }
    done
    [[ "$(locale charmap 2>/dev/null)" != *UTF-8* ]] && export LC_ALL="C.UTF-8" LANG="C.UTF-8"
fi

# Quita tildes/ñ/¿/¡/«»/emoji de un texto, dejando solo ASCII imprimible.
# Nunca falla por el locale activo (sustitución literal + tr -cd en C).
ascii_safe() {
    local s="$1"
    s="${s//á/a}"; s="${s//é/e}"; s="${s//í/i}"; s="${s//ó/o}"; s="${s//ú/u}"
    s="${s//Á/A}"; s="${s//É/E}"; s="${s//Í/I}"; s="${s//Ó/O}"; s="${s//Ú/U}"
    s="${s//ñ/n}"; s="${s//Ñ/N}"; s="${s//¿/}"; s="${s//¡/}"
    s="${s//«/\"}"; s="${s//»/\"}"
    printf '%s' "$s" | LC_ALL=C tr -cd '\11\12\15\40-\176'
}

# Envoltorio de zenity:
#  1) Pasa por ascii_safe() solo las opciones que zenity parsea con GLib
#     (title/text/labels/columnas), que son las que fallan con locale rota.
#     Todo lo demás (datos de fila tras "--") va intacto.
#  2) Filtra del terminal avisos de GTK que son ruido inofensivo (no
#     indican que algo haya fallado).
#  3) Red de seguridad: si aun asi zenity devuelve 255 (opción rechazada
#     por el parser de GLib), reintenta el mismo diálogo con el mínimo de
#     opciones posible (solo tipo + texto ya saneado) para que el usuario
#     SIEMPRE vea una respuesta, en vez de quedarse sin saber si se aplicó.
zen() {
    local -a args=()
    local a dtype="" text=""
    for a in "$@"; do
        case "$a" in
            --title=*|--text=*|--ok-label=*|--cancel-label=*| \
            --entry-text=*|--column=*|--extra-button=*)
                a="${a%%=*}=$(ascii_safe "${a#*=}")" ;;
        esac
        case "$a" in
            --info|--question|--warning|--error) dtype="$a" ;;
            --text=*) text="${a#*=}" ;;
        esac
        args+=("$a")
    done
    local out rc
    out=$(zenity "${args[@]}" \
        2> >(grep -Ev 'GLib-GObject-CRITICAL|a11y|accessibility bus|DRI3|libEGL' >&2))
    rc=$?
    if [[ $rc -eq 255 && -n "$dtype" ]]; then
        out=$(zenity "$dtype" --text="${text:-(sin mensaje)}" 2>/dev/null)
        rc=$?
    fi
    printf '%s' "$out"
    return "$rc"
}

# Disponibilidad de herramientas opcionales: evita ruido/errores si faltan
# (por ejemplo, una instalación mínima sin cron) y permite omitir secciones
# enteras de golpe en vez de fallar silenciosamente comando por comando.
HAS_SYSTEMD=0
command -v systemctl &>/dev/null && HAS_SYSTEMD=1
HAS_CRONTAB=0
command -v crontab &>/dev/null && HAS_CRONTAB=1

# Ejecutar el script entero como root (p. ej. con "sudo") es un error común:
# gestionaría el autostart/cron de ROOT, no el de tu usuario normal, y el
# script ya pide contraseña solo cuando de verdad hace falta. Avisamos y
# dejamos elegir.
if [[ "$EUID" -eq 0 ]]; then
    if ! zen --question --title="⚠ Ejecutándose como root" --width=480 \
        --icon="dialog-warning" \
        --ok-label="Sí, continuar como root" --cancel-label="No, salir" \
        --text="Has iniciado el script como <b>root</b> (por ejemplo con sudo).\nNo hace falta: el script pide contraseña solo cuando la necesita.\n\nSi continúas así, el autostart de usuario y el cron que se gestionen serán los de <b>root</b>, no los de tu usuario normal.\n\n¿Quieres continuar de todas formas?"; then
        exit 0
    fi
fi

# --------------------------------------------------------------------------
# Arrays globales con el inventario de elementos
# --------------------------------------------------------------------------
ARR_TYPE=()          # etiqueta de tipo mostrada en la tabla (con icono)
ARR_NAME=()          # nombre visible
ARR_STATUS=()        # "TRUE" / "FALSE"  (estado actual, activo o no)
ARR_STATUS_LABEL=()  # "✅ Activado" / "⛔ Desactivado"
ARR_SRC=()           # origen mostrado (ruta o unidad)
ARR_KIND=()          # tipo interno: user_autostart / system_autostart /
                      #               systemd_user / systemd_system / cron_user
ARR_RAW=()           # dato interno necesario para activar/desactivar
ARR_MODE=()          # solo systemd: "enable" (systemctl enable/disable) o
                      # "mask" (unidades static/generated/indirect/masked,
                      # que no admiten enable/disable; se gestionan con
                      # systemctl mask/unmask). Vacío para el resto.
declare -A LAST_ERR  # motivo real del último fallo por índice, ver set_item_state()

esc_markup() {
    # Escapa &, < y > para que zenity no interprete el texto como marcado
    # Pango (rompería el diálogo). Frecuente con líneas de cron que usan
    # "&&" o "&" para encadenar comandos.
    #
    # El "&" del reemplazo va escapado como "\&": en bash >= 5.2 (Mint 22.3 /
    # Ubuntu 24.04) la opción "patsub_replacement" está activada por defecto
    # y un "&" sin escapar en ${var//pat/rep} se sustituye por el texto
    # encontrado en vez de tratarse como literal, dejando sin escapar el
    # propio carácter que se quiere neutralizar.
    local s="$1"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    printf '%s' "$s"
}

add_item() {
    # Además de guardar el icono, decide el texto de "Tipo" en lenguaje
    # llano (sin la palabra "systemd", que no dice nada a un usuario medio;
    # ese detalle técnico ya queda en la columna Origen) y marca "CRÍTICO"
    # cuando aplica. Ver is_internal_systemd_unit()/is_critical_unit()/
    # is_critical_autostart() más abajo.
    local tipo="$1" name="$2" status="$3" src="$4" kind="$5" raw="$6" mode="${7:-}" icon="" crit=0
    case "$kind" in
        user_autostart)
            icon="👤"
            is_critical_autostart "$(basename -- "$raw")" "$name" && crit=1 ;;
        system_autostart)
            icon="🖥️"
            is_critical_autostart "$raw" "$name" && crit=1 ;;
        systemd_user|systemd_system)
            tipo="Servicio del sistema"
            [[ "$kind" == systemd_user ]] && tipo="Servicio de sesión"
            if is_critical_unit "$raw"; then
                crit=1
            elif is_internal_systemd_unit "$raw"; then
                icon="⚙️"
            else
                icon="📦"
                tipo="Programa en segundo plano"
            fi ;;
        cron_user) icon="⏰" ;;
    esac
    if (( crit )); then
        icon="🔒"
        tipo+=" · CRÍTICO"
    fi
    ARR_TYPE+=("$icon $tipo")
    ARR_NAME+=("$name")
    ARR_STATUS+=("$status")
    if [[ "$status" == "TRUE" ]]; then
        ARR_STATUS_LABEL+=("✅ Activado")
    else
        ARR_STATUS_LABEL+=("⛔ Desactivado")
    fi
    ARR_SRC+=("$src")
    ARR_KIND+=("$kind")
    ARR_RAW+=("$raw")
    ARR_MODE+=("$mode")
}

get_desktop_name() {
    # Intenta usar el nombre localizado (Name[es]=, Name[es_ES]=...) antes
    # que el genérico Name=, para que la tabla se vea en tu idioma si el
    # .desktop lo trae traducido.
    local f="$1" name="" locale short
    locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    locale="${locale%%.*}"      # es_ES.UTF-8 -> es_ES
    short="${locale%%_*}"       # es_ES -> es

    if [[ -n "$locale" ]]; then
        name=$(grep -m1 -E "^Name\[$locale\]=" "$f" 2>/dev/null | cut -d'=' -f2-)
    fi
    if [[ -z "$name" && -n "$short" && "$short" != "$locale" ]]; then
        name=$(grep -m1 -E "^Name\[$short\]=" "$f" 2>/dev/null | cut -d'=' -f2-)
    fi
    if [[ -z "$name" ]]; then
        name=$(grep -m1 -E '^Name=' "$f" 2>/dev/null | head -n1 | cut -d'=' -f2-)
    fi
    [[ -z "$name" ]] && name=$(basename "$f" .desktop)
    echo "$name"
}

is_desktop_enabled() {
    # Devuelve TRUE/FALSE según Hidden= y X-GNOME-Autostart-enabled=
    local f="$1" hidden gnome_en
    hidden=$(grep -m1 -E '^Hidden=' "$f" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    gnome_en=$(grep -m1 -E '^X-GNOME-Autostart-enabled=' "$f" 2>/dev/null | cut -d'=' -f2 | tr -d '[:space:]')
    if [[ "$hidden" == "true" ]]; then
        echo "FALSE"
    elif [[ "$gnome_en" == "false" ]]; then
        echo "FALSE"
    else
        echo "TRUE"
    fi
}

desktop_env_note() {
    # Si el .desktop trae OnlyShowIn=/NotShowIn= y no incluye el entorno
    # actual (Cinnamon = "X-Cinnamon"), añade una nota visible: aunque el
    # checkbox diga "Activado", ese elemento en realidad no arrancará aquí.
    local f="$1" cur only not tok c match=0 note=""
    local -a cur_toks only_toks not_toks
    cur="${XDG_CURRENT_DESKTOP:-}"
    IFS=':' read -ra cur_toks <<< "$cur"

    only=$(grep -m1 -E '^OnlyShowIn=' "$f" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')
    not=$(grep -m1 -E '^NotShowIn=' "$f" 2>/dev/null | cut -d'=' -f2- | tr -d '[:space:]')

    if [[ -n "$only" && -n "$cur" ]]; then
        IFS=';' read -ra only_toks <<< "$only"
        for tok in "${only_toks[@]}"; do
            for c in "${cur_toks[@]}"; do
                [[ "$tok" == "$c" ]] && match=1
            done
        done
        [[ $match -eq 0 ]] && note="  [no aplica a $cur: OnlyShowIn=$only]"
    fi
    if [[ -n "$not" && -n "$cur" ]]; then
        IFS=';' read -ra not_toks <<< "$not"
        for tok in "${not_toks[@]}"; do
            for c in "${cur_toks[@]}"; do
                [[ "$tok" == "$c" ]] && note="  [no aplica a $cur: NotShowIn=$not]"
            done
        done
    fi
    echo "$note"
}

# --------------------------------------------------------------------------
# Traduce el STATE de "systemctl list-unit-files" a estado TRUE/FALSE y
# modo de aplicación ($2/$3, namerefs de salida). static/generated/indirect
# no tienen symlink de habilitación propio (systemctl enable/disable no
# aplica) pero SÍ arrancan si algo las requiere, p. ej. activación por
# socket (así arranca nordvpnd, el demonio de NordVPN): para bloquearlas de
# verdad hace falta mask/unmask. Devuelve 1 si el estado no corresponde a
# un elemento de arranque real (alias, transient, bad...).
# --------------------------------------------------------------------------
systemd_unit_status() {
    local -n _st_out="$2" _mode_out="$3"
    case "$1" in
        enabled|enabled-runtime)   _st_out="TRUE";  _mode_out="enable" ;;
        disabled)                  _st_out="FALSE"; _mode_out="enable" ;;
        static|generated|indirect) _st_out="TRUE";  _mode_out="mask" ;;
        masked|masked-runtime)     _st_out="FALSE"; _mode_out="mask" ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# refresh_items(): llama a collect_items() solo si algo pudo haber cambiado
# de verdad en el sistema (ITEMS_DIRTY=1). Cambiar de pestaña o de filtro NO
# ensucia el flag: son operaciones sobre los mismos datos ya cargados, así
# que no hace falta relanzar systemctl/leer archivos de nuevo por eso.
# ITEMS_DIRTY se pone a 1 solo tras aplicar un cambio real (ver "changes" en
# show_category_checklist).
# --------------------------------------------------------------------------
ITEMS_DIRTY=1
refresh_items() {
    (( ITEMS_DIRTY )) || return 0
    collect_items
    ITEMS_DIRTY=0
}

# --------------------------------------------------------------------------
# Recolecta todos los elementos de arranque en los arrays globales
# --------------------------------------------------------------------------
collect_items() {
    ARR_TYPE=(); ARR_NAME=(); ARR_STATUS=(); ARR_STATUS_LABEL=()
    ARR_SRC=(); ARR_KIND=(); ARR_RAW=(); ARR_MODE=()

    local f base name status src_display override unit state st mode
    local line lineno trimmed content

    # --- Autostart de sistema: para saber cuáles están "sobrescritos" ---
    local -A SYS_SEEN=()
    for f in /etc/xdg/autostart/*.desktop; do
        SYS_SEEN["$(basename "$f")"]=1
    done

    # --- 1) Autostart de usuario puro (sin equivalente en el sistema) ---
    for f in "$HOME/.config/autostart/"*.desktop; do
        base=$(basename "$f")
        [[ -n "${SYS_SEEN[$base]:-}" ]] && continue
        name=$(get_desktop_name "$f")
        status=$(is_desktop_enabled "$f")
        add_item "Usuario" "$name" "$status" "$f$(desktop_env_note "$f")" "user_autostart" "$f"
    done

    # --- 2) Autostart de sistema (con posible anulación de usuario) ---
    for f in /etc/xdg/autostart/*.desktop; do
        base=$(basename "$f")
        override="$HOME/.config/autostart/$base"
        # El nombre y las notas OnlyShowIn/NotShowIn se leen siempre del
        # archivo de /etc, no del override en ~/.config/autostart: el
        # override solo contiene "Hidden=" (así lo genera este script) y no
        # trae Name=.
        name=$(get_desktop_name "$f")
        local note; note=$(desktop_env_note "$f")
        if [[ -f "$override" ]]; then
            status=$(is_desktop_enabled "$override")
            src_display="$f  (anulado por usuario)$note"
        else
            status=$(is_desktop_enabled "$f")
            src_display="$f$note"
        fi
        add_item "Sistema" "$name" "$status" "$src_display" "system_autostart" "$base"
    done

    if (( HAS_SYSTEMD )); then
        # --- 3) Servicios systemd --user (.service y .socket) ---
        # Se incluyen también las unidades .socket: algunos daemons (p. ej.
        # nordvpnd) arrancan por activación de socket aunque su .service
        # esté enmascarado, así que sin esto no se pueden bloquear de verdad.
        while read -r unit state _; do
            [[ -z "$unit" ]] && continue
            systemd_unit_status "$state" st mode || continue
            src_display="$unit"
            [[ "$mode" == "mask" ]] && src_display+="  [estático: gestionado con mask]"
            add_item "systemd (usuario)" "$unit" "$st" "$src_display" "systemd_user" "$unit" "$mode"
        done < <(systemctl --user list-unit-files --type=service,socket --no-legend 2>/dev/null)

        # --- 4) Servicios systemd del sistema (.service y .socket) ---
        while read -r unit state _; do
            [[ -z "$unit" ]] && continue
            systemd_unit_status "$state" st mode || continue
            src_display="$unit"
            [[ "$mode" == "mask" ]] && src_display+="  [estático: gestionado con mask]"
            add_item "systemd (sistema)" "$unit" "$st" "$src_display" "systemd_system" "$unit" "$mode"
        done < <(systemctl list-unit-files --type=service,socket --no-legend 2>/dev/null)
    fi

    if (( HAS_CRONTAB )); then
        # --- 5) Tareas cron del usuario ---
        lineno=0
        # El "|| [[ -n "$line" ]]" recupera la última línea aunque el
        # crontab no termine en salto de línea (si no, "read" la descarta).
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineno=$((lineno + 1))
            [[ -z "$line" ]] && continue
            trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue   # línea solo con espacios/tabs: no es una tarea
            if [[ "$trimmed" == \#* ]]; then
                if [[ "$trimmed" == "#DISABLED#"* ]]; then
                    content="${trimmed#\#DISABLED#}"
                    content="${content# }"
                    add_item "Tarea programada" "${content:0:60}" "FALSE" "crontab línea $lineno" "cron_user" "$lineno"
                fi
                continue
            fi
            # Líneas tipo VAR=valor (MAILTO=, PATH=, SHELL=...) no son tareas
            # programadas: son asignaciones de entorno para todo el crontab.
            # Si se listaran como "tarea" y el usuario las desmarca, el script
            # las comentaría y cambiaría el comportamiento de TODO el crontab
            # sin que esa fuera la intención. Se omiten de la tabla.
            if [[ "$trimmed" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then
                continue
            fi
            add_item "Tarea programada" "${trimmed:0:60}" "TRUE" "crontab línea $lineno" "cron_user" "$lineno"
        done < <(crontab -l 2>/dev/null)
    fi
}

# --------------------------------------------------------------------------
# Lista de unidades systemd "sensibles": si el usuario intenta DESACTIVAR
# alguna de estas, se pide una confirmación extra antes de aplicar.
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
# Heurística por nombre: ¿es un servicio "interno" típico de Ubuntu/Mint
# (red, sesión gráfica, impresión, hardware, mantenimiento del propio SO)
# o más bien un programa/demonio de terceros (VPN, contenedores, apps con
# servicio en segundo plano...)? Solo se usa para AGRUPAR la tabla; no
# afecta a qué se considera crítico (eso lo decide is_critical_unit).
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
# Categorías = pestañas de la interfaz. Cada elemento pertenece a una sola.
#   1: Programas de Inicio        -> user_autostart / system_autostart
#   2: Procesos en Segundo Plano  -> systemd --user (servicios de sesión)
#   3: Tareas Programadas         -> cron_user
#   4: Servicios de Aplicaciones  -> systemd sistema, de terceros
#   5: Servicios de Linux Mint    -> systemd sistema, internos del SO
# (is_critical_unit se sigue usando aparte para avisar antes de desactivar,
# sin importar en qué categoría caiga la unidad.)
# --------------------------------------------------------------------------
CATEGORY_LABEL=(
    [1]="Programas de Inicio" [2]="Procesos en Segundo Plano"
    [3]="Tareas Programadas"  [4]="Servicios de Aplicaciones"
    [5]="Servicios de Linux Mint"
)
CATEGORY_ICON=([1]="🚀" [2]="🧩" [3]="⏰" [4]="📦" [5]="🔧")
CATEGORY_SHORT=([1]="Inicio" [2]="2º Plano" [3]="Programadas" [4]="Apps" [5]="Mint")

# Etiqueta corta "[icono Categoria]" para identificar de un vistazo a qué
# pestaña pertenece cada fila cuando se muestran varias categorías juntas
# (vista "todas las pestañas" / resultados de búsqueda global).
category_tag() {
    local c; c=$(item_category "$1")
    printf '[%s %s] ' "${CATEGORY_ICON[$c]}" "${CATEGORY_SHORT[$c]}"
}

item_category() {
    case "${ARR_KIND[$1]}" in
        user_autostart|system_autostart) echo 1 ;;
        systemd_user)                    echo 2 ;;
        cron_user)                       echo 3 ;;
        systemd_system)
            is_internal_systemd_unit "${ARR_RAW[$1]}" && echo 5 || echo 4 ;;
    esac
}

# Índices de ARR_* que pertenecen a la categoría $1, ordenados alfabéticamente
# por nombre (case-insensitive). Por nameref en $2.
category_indices() {
    local cat="$1" i line
    local -n _out_ref="$2"
    local -a keys=()
    for i in "${!ARR_NAME[@]}"; do
        if [[ "$cat" == "ALL" || "$(item_category "$i")" == "$cat" ]]; then
            keys+=("${ARR_NAME[$i],,}${SEP}${i}")
        fi
    done
    _out_ref=()
    # Si "keys" esta vacio, "printf '%s\n' "${keys[@]}"" no imprime CERO
    # lineas: imprime UNA linea vacia (printf reutiliza el formato al menos
    # una vez aunque falten argumentos). Sin esta guarda, esa linea vacia
    # se colaba como un indice fantasma "" que bash resuelve como indice 0
    # (subindice vacio = 0 en aritmetica), mostrando un elemento cualquiera
    # en vez de la lista realmente vacia.
    (( ${#keys[@]} == 0 )) && return
    while IFS= read -r line; do
        _out_ref+=("${line##*"$SEP"}")
    done < <(printf '%s\n' "${keys[@]}" | sort -t"$SEP" -k1,1f -s)
}

# --------------------------------------------------------------------------
# Igual que is_critical_unit, pero para apps de autostart (usuario/sistema).
# El caso relevante es el AGENTE DE AUTENTICACIÓN DE POLICYKIT: si se
# desactiva, pkexec deja de poder mostrar/validar la ventana de contraseña
# de administrador en todo el sistema, no solo en este script.
# $1: nombre base del .desktop (p. ej. "polkit-gnome-authentication-agent-1.desktop")
# $2: nombre visible (Name=), por si el archivo se llama de otra forma
# --------------------------------------------------------------------------
is_critical_autostart() {
    local base="${1,,}" name="${2,,}"
    case "$base" in
        *polkit*agent*|*polkit-gnome*|*polkit-mate*|*polkit-kde*|*xfce-polkit*|*lxpolkit*)
            return 0 ;;
    esac
    case "$name" in
        *policykit*agent*|*polkit*agent*|*"authentication agent"*)
            return 0 ;;
    esac
    return 1
}

# --------------------------------------------------------------------------
# Aplica el nuevo estado (TRUE=activar / FALSE=desactivar) a un elemento.
# Devuelve 0 si el cambio se aplicó correctamente, 1 si falló (por ejemplo,
# contraseña de pkexec cancelada, o permisos insuficientes).
# --------------------------------------------------------------------------
set_item_state() {
    local i="$1" desired="$2" kind="${ARR_KIND[$1]}" ok=0 err=""
    unset "LAST_ERR[$i]"

    case "$kind" in
        user_autostart)
            local f="${ARR_RAW[$i]}"
            if [[ "$desired" == "FALSE" ]]; then
                if grep -q '^Hidden=' "$f"; then
                    err=$(sed -i 's/^Hidden=.*/Hidden=true/' "$f" 2>&1) || ok=1
                else
                    err=$(echo "Hidden=true" >> "$f" 2>&1) || ok=1
                fi
            else
                if grep -q '^Hidden=' "$f"; then
                    err=$(sed -i 's/^Hidden=.*/Hidden=false/' "$f" 2>&1) || ok=1
                fi
                if grep -q '^X-GNOME-Autostart-enabled=' "$f"; then
                    err=$(sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' "$f" 2>&1) || ok=1
                fi
            fi
            ;;

        system_autostart)
            local base="${ARR_RAW[$i]}"
            local override="$HOME/.config/autostart/$base"
            local sysfile="/etc/xdg/autostart/$base"
            if [[ "$desired" == "FALSE" ]]; then
                mkdir -p "$HOME/.config/autostart" || ok=1
                printf '[Desktop Entry]\nHidden=true\n' > "$override" || ok=1
            else
                # Si /etc viene deshabilitado de fábrica, no basta con
                # borrar el override: hay que forzarlo a habilitado, y con
                # una COPIA COMPLETA del .desktop (no solo Hidden=false),
                # porque al vivir en ~/.config/autostart pasa a ser el
                # ÚNICO archivo considerado para ese nombre (spec XDG); un
                # override sin Exec= no arrancaría nada.
                local sys_default="TRUE"
                [[ -f "$sysfile" ]] && sys_default=$(is_desktop_enabled "$sysfile")
                if [[ "$sys_default" == "TRUE" ]]; then
                    [[ -f "$override" ]] && { rm -f "$override" || ok=1; }
                elif [[ -f "$sysfile" ]]; then
                    mkdir -p "$HOME/.config/autostart" || ok=1
                    cp -f "$sysfile" "$override" || ok=1
                    if grep -q '^Hidden=' "$override"; then
                        sed -i 's/^Hidden=.*/Hidden=false/' "$override" || ok=1
                    else
                        printf 'Hidden=false\n' >> "$override" || ok=1
                    fi
                    if grep -q '^X-GNOME-Autostart-enabled=' "$override"; then
                        sed -i 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' "$override" || ok=1
                    fi
                else
                    mkdir -p "$HOME/.config/autostart" || ok=1
                    printf '[Desktop Entry]\nHidden=false\n' > "$override" || ok=1
                fi
            fi
            ;;

        systemd_user)
            local unit="${ARR_RAW[$i]}" mode="${ARR_MODE[$i]:-enable}" verbo="enable"
            [[ "$mode" == "mask" ]] && verbo="unmask"
            [[ "$desired" == "FALSE" ]] && verbo="disable"
            [[ "$mode" == "mask" && "$desired" == "FALSE" ]] && verbo="mask"
            err=$(systemctl --user "$verbo" -- "$unit" 2>&1) || ok=1
            ;;

        systemd_system)
            # No se gestiona aquí: todas las unidades systemd_system que
            # cambian en la misma pasada se aplican juntas en UNA sola
            # llamada a pkexec (ver apply_systemd_system_batch), para no
            # pedir la contraseña de administrador una vez por cada unidad.
            ok=1
            ;;

        cron_user)
            local ln="${ARR_RAW[$i]}" tmpcron total current current_trimmed
            tmpcron=$(mktemp) || return 1
            TMP_FILES+=("$tmpcron")
            crontab -l 2>/dev/null > "$tmpcron"
            # grep -c '' cuenta líneas aunque falte el salto de línea final
            # (wc -l las subestimaría en ese caso, dejando la última tarea
            # sin poder activarse/desactivarse).
            total=$(grep -c '' "$tmpcron")
            if (( ln <= total )); then
                current=$(sed -n "${ln}p" "$tmpcron")
                # Se compara ignorando espacios iniciales, igual que al
                # detectar el estado en collect_items(), para que una línea
                # con sangría antes de "#DISABLED#" no confunda al script.
                current_trimmed="${current#"${current%%[![:space:]]*}"}"
                if [[ "$desired" == "FALSE" ]]; then
                    [[ "$current_trimmed" != \#DISABLED#* ]] && sed -i "${ln}s|^|#DISABLED# |" "$tmpcron"
                else
                    [[ "$current_trimmed" == \#DISABLED#* ]] && sed -i "${ln}s|^[[:space:]]*#DISABLED#[[:space:]]\?||" "$tmpcron"
                fi
                err=$(crontab "$tmpcron" 2>&1) || ok=1
            else
                ok=1
                err="La tarea ya no existe en esa línea del crontab (¿se editó desde fuera?)."
            fi
            rm -f "$tmpcron"
            ;;
    esac

    (( ok )) && [[ -n "$err" ]] && LAST_ERR[$i]="$err"

    return "$ok"
}

# --------------------------------------------------------------------------
# Aplica TODOS los cambios de servicios systemd del SISTEMA en una sola
# llamada a pkexec (en vez de una por unidad), para pedir la contraseña de
# administrador como mucho una vez por cada vez que se pulsa "Aceptar".
#
# Se envuelve con "timeout" para recuperar el control si PolicyKit se queda
# colgado (agente de autenticación roto, sesión gráfica mal detectada, etc.).
#
# $1: nombre del array (nameref) con los índices ARR_* a aplicar, todos de
#     kind=systemd_system.
# $2: nombre del array asociativo (nameref) donde se deja, por unidad,
#     "OK" o "FAIL".
# $3: nombre del array asociativo (nameref) donde se deja, por unidad que
#     falló, el mensaje de error real de systemctl (stderr).
# Variable global usada: SELECTED_IDS (estado deseado de cada índice).
# --------------------------------------------------------------------------
PKEXEC_BATCH_ERROR=""   # se rellena con un motivo legible si el lote entero falla

apply_systemd_system_batch() {
    local -n _idx_ref="$1"
    local -n _res_ref="$2"
    local -n _err_ref="$3"
    local i unit desired mode tmp_script tmp_out rc

    PKEXEC_BATCH_ERROR=""

    if ! command -v pkexec &>/dev/null; then
        PKEXEC_BATCH_ERROR="No se encontró 'pkexec' (paquete policykit-1). No se puede pedir permiso de administrador."
        for i in "${_idx_ref[@]}"; do _res_ref["${ARR_RAW[$i]}"]="FAIL"; done
        return 1
    fi

    # Comprobación best-effort de que hay un agente de autenticación de
    # PolicyKit corriendo en la sesión. Es solo INFORMATIVA: si no se
    # reconoce el proceso del agente no se cancela el intento (el patrón de
    # pgrep puede no cubrir el nombre exacto del agente instalado, o este
    # puede arrancar con retraso), simplemente se recuerda para explicar
    # mejor un fallo posterior de pkexec si lo hay.
    local agent_seen=1
    pgrep -f -- 'polkit.*authentication-agent|polkit-gnome|polkit-mate|polkit-kde|lxpolkit|xfce-polkit' &>/dev/null || agent_seen=0

    tmp_script=$(mktemp) || return 1
    TMP_FILES+=("$tmp_script")
    tmp_out=$(mktemp) || { rm -f "$tmp_script"; return 1; }
    TMP_FILES+=("$tmp_out")

    {
        printf '#!/bin/bash\n'
        printf 'set -u\n'
        # Función auxiliar: aplica un verbo systemctl a una unidad y reporta
        # "OK<SEP>unidad" o "FAIL<SEP>unidad<SEP>motivo real (stderr)", para
        # no perder el motivo de cada fallo individual como antes (2>/dev/null).
        printf 'apply_unit() {\n'
        printf '    local out rc\n'
        printf '    out=$(systemctl "$1" -- "$2" 2>&1); rc=$?\n'
        printf '    out="${out//$'"'"'\\n'"'"'/ }"\n'
        printf '    if (( rc == 0 )); then printf "OK\\x1f%%s\\x1f\\n" "$2"\n'
        printf '    else printf "FAIL\\x1f%%s\\x1f%%s\\n" "$2" "$out"; fi\n'
        printf '}\n'
        for i in "${_idx_ref[@]}"; do
            unit="${ARR_RAW[$i]}"
            mode="${ARR_MODE[$i]:-enable}"
            desired="FALSE"
            [[ -n "${SELECTED_IDS[$i]:-}" ]] && desired="TRUE"
            if [[ "$mode" == "mask" ]]; then
                [[ "$desired" == "TRUE" ]] && printf 'apply_unit unmask %q\n' "$unit" \
                                            || printf 'apply_unit mask %q\n' "$unit"
            elif [[ "$desired" == "TRUE" ]]; then
                printf 'apply_unit enable %q\n' "$unit"
            else
                printf 'apply_unit disable %q\n' "$unit"
            fi
        done
    } > "$tmp_script"

    # 180s de margen de sobra para escribir la contraseña con calma.
    timeout 180 pkexec bash "$tmp_script" > "$tmp_out" 2>/dev/null
    rc=$?

    if (( rc != 0 )); then
        case "$rc" in
            124) PKEXEC_BATCH_ERROR="Se agotó el tiempo de espera (más de 3 minutos) para la autenticación." ;;
            126) PKEXEC_BATCH_ERROR="Se canceló la ventana de contraseña de administrador." ;;
            127) PKEXEC_BATCH_ERROR="La autenticación falló o no se pudo obtener el permiso (contraseña incorrecta o usuario sin permisos de administrador)." ;;
            *)   PKEXEC_BATCH_ERROR="pkexec terminó con un error inesperado (código $rc)." ;;
        esac
        if (( ! agent_seen )); then
            PKEXEC_BATCH_ERROR+=" No se detectó ningún agente de autenticación de PolicyKit en esta sesión (revisa 'Programas de Inicio' o reinicia sesión); sin él, la ventana de contraseña puede no aparecer nunca."
        fi
    fi

    # Se procesa igualmente lo que se haya alcanzado a leer, por si el
    # lote falló A MEDIAS (algunas unidades sí llegaron a aplicarse antes
    # de que algo fallara).
    local st u errmsg
    while IFS=$'\x1f' read -r st u errmsg; do
        [[ -n "$u" ]] || continue
        _res_ref["$u"]="$st"
        [[ "$st" == "FAIL" && -n "$errmsg" ]] && _err_ref["$u"]="$errmsg"
    done < "$tmp_out"

    for i in "${_idx_ref[@]}"; do
        unit="${ARR_RAW[$i]}"
        [[ -z "${_res_ref[$unit]:-}" ]] && _res_ref["$unit"]="FAIL"
    done

    rm -f "$tmp_script" "$tmp_out"
    return "$rc"
}

# --------------------------------------------------------------------------
# Editor / visor de archivos
# --------------------------------------------------------------------------
pick_editor() {
    local e
    for e in xed gedit gnome-text-editor kate mousepad; do
        command -v "$e" &>/dev/null && { echo "$e"; return; }
    done
    echo "xdg-open"
}

edit_file() {
    local editor
    editor=$(pick_editor)
    "$editor" "$1" &>/dev/null &
}

edit_file_root() {
    # pkexec sanea el entorno por seguridad y normalmente NO propaga
    # DISPLAY/XAUTHORITY al programa ejecutado, así que un editor gráfico
    # lanzado así falla con "cannot open display". Se pasan explícitamente.
    local editor
    editor=$(pick_editor)
    pkexec env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
        "$editor" "$1" &>/dev/null &
}

smart_edit() {
    # Los archivos de /etc/xdg/autostart y las unidades de systemd casi
    # siempre se pueden LEER sin privilegios (permisos 644 habituales); solo
    # se pide contraseña con pkexec si el usuario no tiene permiso de lectura.
    local f="$1"
    if [[ -r "$f" ]]; then
        edit_file "$f"
    else
        edit_file_root "$f"
    fi
}

open_item() {
    local i="$1" kind="${ARR_KIND[$1]}"
    case "$kind" in
        user_autostart)
            edit_file "${ARR_RAW[$i]}"
            ;;
        system_autostart)
            local base="${ARR_RAW[$i]}" override="$HOME/.config/autostart/${ARR_RAW[$i]}"
            if [[ -f "$override" ]]; then
                edit_file "$override"
            else
                smart_edit "/etc/xdg/autostart/$base"
            fi
            ;;
        systemd_user)
            local path
            path=$(systemctl --user show -p FragmentPath --value "${ARR_RAW[$i]}" 2>/dev/null)
            if [[ -n "$path" ]]; then smart_edit "$path"; else
                zen --info --text="No se encontró el archivo de la unidad." --width=300
            fi
            ;;
        systemd_system)
            local path
            path=$(systemctl show -p FragmentPath --value "${ARR_RAW[$i]}" 2>/dev/null)
            if [[ -n "$path" ]]; then smart_edit "$path"; else
                zen --info --text="No se encontró el archivo de la unidad." --width=300
            fi
            ;;
        cron_user)
            zen --info --title="Editar cron" --width=420 --icon="dialog-information" \
                --text="Las tareas cron se editan con:\n\n    crontab -e\n\nEjecútalo en una terminal."
            ;;
    esac
}

# Navegador de "abrir/ver origen", limitado a los índices de la pestaña
# actual ($1, nameref a un array de índices ARR_*).
browse_and_open() {
    local -n _idx_ref="$1"
    local rows=() i sel
    for i in "${_idx_ref[@]}"; do
        rows+=("$i" "${ARR_TYPE[$i]}" "$(esc_markup "${ARR_NAME[$i]}")" "$(esc_markup "${ARR_SRC[$i]}")")
    done
    sel=$(zen --list --title="Abrir / ver elemento" \
        --width=1000 --height=500 \
        --column="ID" --column="Tipo" --column="Nombre" --column="Origen" \
        --print-column=1 --hide-column=1 \
        -- "${rows[@]}")
    [[ -z "$sel" || ! "$sel" =~ ^[0-9]+$ ]] && return
    open_item "$sel"
}

# --------------------------------------------------------------------------
# Pantalla de una pestaña: checklist con solo los elementos de la categoría
# $1 ("ALL" para buscar en todas). Aplica cambios y, al cerrar/cancelar el
# checklist, hace "return" (vuelve al menú de pestañas) en vez de terminar
# el programa.
# --------------------------------------------------------------------------
show_category_checklist() {
    local cat="$1" FILTER=""
    local cat_label="${CATEGORY_LABEL[$cat]:-Todas las pestañas}"
    local cat_icon="${CATEGORY_ICON[$cat]:-🔍}"

    while true; do
        refresh_items
        local -a CAT_ALL=()
        category_indices "$cat" CAT_ALL
        if [[ ${#CAT_ALL[@]} -eq 0 ]]; then
            zen --info --width=380 --icon="dialog-information" \
                --text="No se encontraron elementos en «$cat_label»."
            return
        fi

        # --- Construir filas visibles aplicando el filtro de esta pestaña ---
        local rows=() shown_indices=() i haystack tipo_cell
        for i in "${CAT_ALL[@]}"; do
            if [[ -n "$FILTER" ]]; then
                haystack="${ARR_TYPE[$i],,} ${ARR_NAME[$i],,} ${ARR_SRC[$i],,} ${ARR_STATUS_LABEL[$i],,}"
                [[ "$haystack" != *"${FILTER,,}"* ]] && continue
            fi
            shown_indices+=("$i")
            # En la vista combinada se antepone la categoría de origen a cada
            # fila, para poder ubicarla luego en su pestaña propia.
            tipo_cell="${ARR_TYPE[$i]}"
            [[ "$cat" == "ALL" ]] && tipo_cell="$(category_tag "$i")${tipo_cell}"
            # Nombre y Origen se escapan (esc_markup): pueden traer texto
            # dinámico (líneas de cron con "&&"/"<"/">", rutas...) que
            # zenity podría interpretar como marcado Pango.
            rows+=("${ARR_STATUS[$i]}" "$i" "$tipo_cell" "$(esc_markup "${ARR_NAME[$i]}")" \
                   "${ARR_STATUS_LABEL[$i]}" "$(esc_markup "${ARR_SRC[$i]}")")
        done

        if [[ ${#shown_indices[@]} -eq 0 ]]; then
            if zen --question --width=400 --title="Sin resultados" \
                --icon="dialog-question" \
                --ok-label="Sí, borrar filtro" --cancel-label="No, volver" \
                --text="Ningún elemento de «$cat_label» coincide con el filtro «$(esc_markup "$FILTER")».\n¿Quieres borrar el filtro?"; then
                FILTER=""
            else
                return
            fi
            continue
        fi

        # NO se usa --extra-button aquí: zenity 4.0.1 (la versión de Mint
        # 22.3) tiene un bug confirmado en su propio changelog ("Fix
        # --extra-button and delete events for legacy (non-libadwaita)
        # dialogs"), corregido recién en una versión posterior. Cinnamon
        # renderiza precisamente en ese modo "legacy", así que ese botón
        # podía fallar de forma intermitente (filtro roto, y en algunos
        # casos hasta el propio "Aceptar"). Buscar/filtrar se resuelve
        # ahora tras Cancelar, con diálogos simples y sin ese bug.
        local output rc
        output=$(zen --list --checklist \
            --title="$cat_icon $cat_label" \
            --text="Marca o desmarca la casilla para activar/desactivar cada elemento.\n🔒 Crítico: revisa antes de tocarlo.\nFiltro: $(esc_markup "${FILTER:-(ninguno)}")  —  mostrando ${#shown_indices[@]} de ${#CAT_ALL[@]}.\nPulsa Aceptar para aplicar, o Cancelar para buscar/volver." \
            --width=1100 --height=600 \
            --column="Activo" --column="ID" --column="Tipo" --column="Nombre" \
            --column="Estado" --column="Origen" \
            --print-column=2 --separator="$SEP" --hide-column=2 \
            -- "${rows[@]}")
        rc=$?

        if [[ $rc -ne 0 ]]; then
            # Cancelar/cerrar: en vez de salir directo, se ofrece
            # buscar/filtrar antes de volver al menú de pestañas.
            if zen --question --width=420 --title="$cat_icon $cat_label" \
                --icon="dialog-question" \
                --ok-label="Buscar / filtrar" --cancel-label="Volver a las pestañas" \
                --text="Filtro actual: $(esc_markup "${FILTER:-(ninguno)}")\n\n¿Quieres escribir o cambiar el filtro de esta pestaña?"; then
                local newfilter newfilter_rc
                newfilter=$(zen --entry --title="Filtrar «$cat_label»" --width=460 \
                    --text="Escribe una palabra para filtrar por nombre, estado u origen\n(déjalo vacío para ver todos)." \
                    --entry-text="$FILTER")
                newfilter_rc=$?
                [[ $newfilter_rc -eq 0 ]] && FILTER="$newfilter"
                continue
            fi
            return
        fi

        # --- Reconstruir qué IDs quedaron marcados (TRUE) ---
        # Se pide solo la columna ID (--print-column=2, la misma que se
        # oculta con --hide-column=2), nunca --print-column=ALL: en el
        # --checklist de zenity, "ALL" omite la propia columna del checkbox
        # al imprimir el resultado, desplazando el resto de campos.
        local -A SELECTED_IDS=()
        local -a tokens
        IFS="$SEP" read -r -a tokens <<< "$output"
        local id
        for id in "${tokens[@]}"; do
            [[ "$id" =~ ^[0-9]+$ ]] && SELECTED_IDS["$id"]=1
        done

        # --- Aviso extra si se va a desactivar algún servicio sensible ---
        # Si el usuario cancela este aviso, se cancelan TODOS los cambios de
        # esta pantalla, no solo los críticos: así no hay ninguna combinación
        # en la que pulsar "cancelar" acabe pidiendo la contraseña de
        # administrador para el resto de cambios no críticos.
        local crit_list=() was now
        for i in "${shown_indices[@]}"; do
            was="${ARR_STATUS[$i]}"
            now="FALSE"
            [[ -n "${SELECTED_IDS[$i]:-}" ]] && now="TRUE"
            [[ "$was" != "TRUE" || "$now" != "FALSE" ]] && continue   # solo nos interesa DESACTIVAR
            [[ "${ARR_TYPE[$i]}" == *CRÍTICO* ]] && crit_list+=("$i")
        done
        if [[ ${#crit_list[@]} -gt 0 ]]; then
            local cw="" ci
            for ci in "${crit_list[@]}"; do cw+="• $(esc_markup "${ARR_NAME[$ci]}")\n"; done
            if ! zen --question --title="⚠ Elementos críticos" --width=520 \
                --icon="dialog-warning" \
                --ok-label="Sí, aplicar todos los cambios" --cancel-label="Cancelar todo (no cambiar nada)" \
                --text="Vas a DESACTIVAR elemento(s) que pueden ser importantes para el sistema:\n\n${cw}\n¿Seguro que quieres continuar?\n\nAlgunos de ellos (como el agente de autenticación de PolicyKit) son necesarios para que las ventanas de contraseña de administrador funcionen correctamente en todo el sistema, no solo en este script.\n\nSi pulsas «Cancelar todo», no se aplicará NINGÚN cambio de esta pantalla y no se pedirá contraseña de administrador."; then
                unset SELECTED_IDS
                continue
            fi
        fi

        # --- Aplicar solo lo que cambió entre los elementos mostrados ---
        # Las unidades systemd_system se recogen aparte para aplicarlas
        # TODAS JUNTAS en una sola llamada a pkexec (una sola contraseña).
        # PKEXEC_BATCH_ERROR solo se rellena/limpia dentro de
        # apply_systemd_system_batch(); se reinicia aquí para no arrastrar
        # el motivo de una pasada anterior.
        PKEXEC_BATCH_ERROR=""
        local changes=0 failures=0 summary="" fail_summary="" accion
        local -a sys_batch=()
        for i in "${shown_indices[@]}"; do
            was="${ARR_STATUS[$i]}"
            now="FALSE"
            [[ -n "${SELECTED_IDS[$i]:-}" ]] && now="TRUE"
            [[ "$was" == "$now" ]] && continue   # sin cambios en este elemento

            if [[ "${ARR_KIND[$i]}" == "systemd_system" ]]; then
                sys_batch+=("$i")
                continue
            fi

            if set_item_state "$i" "$now"; then
                changes=$((changes + 1))
                accion="Desactivado"
                [[ "$now" == "TRUE" ]] && accion="Activado"
                summary+="• $accion: $(esc_markup "${ARR_NAME[$i]}")\n"
            else
                failures=$((failures + 1))
                fail_summary+="• $(esc_markup "${ARR_NAME[$i]}")"
                [[ -n "${LAST_ERR[$i]:-}" ]] && fail_summary+="\n   ↳ $(esc_markup "${LAST_ERR[$i]}")"
                fail_summary+="\n"
            fi
        done

        # --- Unidades systemd del sistema: UNA sola pasada por pkexec ---
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
                    accion="Desactivado"
                    [[ "$now" == "TRUE" ]] && accion="Activado"
                    summary+="• $accion: $(esc_markup "${ARR_NAME[$i]}")\n"
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
        (( changes > 0 )) && ITEMS_DIRTY=1

        # --- Mensaje final: SIEMPRE se informa del resultado antes de
        # seguir, para que quede claro que "Aceptar" hizo algo (o que no
        # había nada que cambiar). ---
        if (( changes > 0 && failures == 0 )); then
            zen --info --title="✅ Todo correcto" --width=540 --icon="dialog-information" \
                --text="Todo correcto. Se aplicaron $changes cambio(s) sin errores:\n\n$summary"
        elif (( changes > 0 && failures > 0 )); then
            zen --info --title="Cambios aplicados" --width=540 --icon="dialog-information" \
                --text="Se aplicaron $changes cambio(s) correctamente:\n\n$summary"
        elif (( changes == 0 && failures == 0 )); then
            zen --info --title="✅ Todo correcto" --width=360 --icon="dialog-information" \
                --text="Todo correcto. No había cambios que aplicar."
        fi
        if (( failures > 0 )); then
            local motivo=""
            if [[ -n "$PKEXEC_BATCH_ERROR" ]]; then
                motivo="$(esc_markup "$PKEXEC_BATCH_ERROR")\n\n"
            elif [[ "$fail_summary" != *"↳"* ]]; then
                # Solo se usa esta suposición genérica si no se obtuvo ningún
                # motivo concreto (ni por lote ni por elemento individual).
                motivo="¿Cancelaste la ventana de contraseña o falta permiso?\n\n"
            fi
            zen --warning --title="Algunos cambios fallaron" --width=560 --icon="dialog-warning" \
                --text="No se pudieron aplicar $failures cambio(s).\n\n${motivo}${fail_summary}"
        fi

        if zen --question --title="Abrir elemento" --width=380 --icon="system-run" \
            --text="¿Quieres abrir/ver el origen de algún elemento de «$cat_label»?"; then
            browse_and_open shown_indices
        fi
        # El "while true" vuelve a mostrar esta misma pestaña actualizada.
    done
}

# --------------------------------------------------------------------------
# Menú principal (hub de "pestañas"): zenity no tiene pestañas nativas, así
# que se simulan con este menú de selección + una pantalla dedicada por
# categoría (show_category_checklist), volviendo aquí al cerrarla.
# --------------------------------------------------------------------------
main_loop() {
    while true; do
        refresh_items
        if [[ ${#ARR_NAME[@]} -eq 0 ]]; then
            zen --info --text="No se encontraron elementos de arranque." --width=300
            break
        fi

        local cat i n dis rows=()
        for cat in 1 2 3 4 5; do
            n=0; dis=0
            for i in "${!ARR_NAME[@]}"; do
                [[ "$(item_category "$i")" == "$cat" ]] || continue
                n=$((n + 1))
                [[ "${ARR_STATUS[$i]}" == "FALSE" ]] && dis=$((dis + 1))
            done
            rows+=("$cat" "${CATEGORY_ICON[$cat]} ${CATEGORY_LABEL[$cat]}" "$n elemento(s) · $dis desactivado(s)")
        done
        rows+=("0" "🔍 Buscar en todas las pestañas" "")

        local sel rc
        sel=$(zen --list --title="⚙ Gestor de Autostart - Linux Mint" \
            --text="Elige una pestaña para ver y gestionar sus elementos:" \
            --width=680 --height=420 --cancel-label="Salir" \
            --column="ID" --column="Pestaña" --column="Resumen" \
            --print-column=1 --hide-column=1 \
            -- "${rows[@]}")
        rc=$?
        [[ $rc -ne 0 || -z "$sel" ]] && break

        case "$sel" in
            0)   show_category_checklist "ALL" ;;
            [1-5]) show_category_checklist "$sel" ;;
        esac
    done
}

main_loop
exit 0
