<p align="center">
  <img src="assets/icon.png" width="120" alt="Icono de Autostart Manager">
</p>

<h1 align="center">Autostart Manager</h1>

<p align="center">
  Un solo panel para ver y controlar <b>todo</b> lo que arranca contigo en Linux Mint Cinnamon.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/licencia-GPLv3-blue.svg" alt="Licencia GPLv3">
  <img src="https://img.shields.io/badge/bash-%3E%3D5.2-4EAA25.svg?logo=gnubash&logoColor=white" alt="Bash 5.2+">
  <img src="https://img.shields.io/badge/plataforma-Linux%20Mint%2022.3%20Cinnamon-87CF3E.svg" alt="Linux Mint 22.3 Cinnamon">
  <img src="https://img.shields.io/badge/idioma-Español-red.svg" alt="Idioma: Español">
</p>

---

## ¿Qué es?


<img width="676" height="450" alt="1 autostart_manager" src="https://github.com/user-attachments/assets/d884195b-1cae-4c0a-9735-d8bbb3be21c9" />
<img width="1100" height="630" alt="2 programas_inicio" src="https://github.com/user-attachments/assets/7bfb5633-0ea4-48fc-8311-972502d476b3" />
<img width="458" height="285" alt="3 filtrado_programas" src="https://github.com/user-attachments/assets/927840be-73f6-4c38-a95e-432252a27a6e" />
<img width="1097" height="625" alt="4 procesos_segundoplano" src="https://github.com/user-attachments/assets/ce874d41-8839-45fa-948c-2198f110d249" />
<img width="1102" height="630" alt="5 servicios_linuxmint" src="https://github.com/user-attachments/assets/b35e5144-0982-4d88-b29b-89f99e26f71b" />
<img width="1098" height="624" alt="6 todas_pestañas" src="https://github.com/user-attachments/assets/c3d9e6b2-befe-40a3-b8e9-9ead39667a8b" />


**Autostart Manager** es un script de Bash con interfaz gráfica (vía `zenity`) que junta en **una sola tabla** las cinco formas distintas que tiene Linux de arrancar cosas automáticamente:

1. Aplicaciones de autostart de **usuario** (`~/.config/autostart`)
2. Aplicaciones de autostart del **sistema** (`/etc/xdg/autostart`)
3. Servicios **systemd de usuario** (`systemctl --user`)
4. Servicios **systemd del sistema** (`systemctl`)
5. Tareas de **cron** del usuario (`crontab -l`)

Desde esa tabla puedes activar o desactivar cualquier elemento con una casilla, filtrar por nombre, y abrir el archivo de origen para editarlo o simplemente inspeccionarlo. Nada de tocar cinco herramientas distintas ni recordar la sintaxis de `systemctl`.

## Índice

- [¿Qué es?](#qué-es-esto)
- [¿Por qué usarlo?](#por-qué-usarlo)
- [Funciones](#funciones)
- [Requisitos](#requisitos)
- [Instalación](#instalación)
- [Uso](#uso)
- [Compatibilidad](#compatibilidad)
- [Idioma y hoja de ruta](#idioma-y-hoja-de-ruta)
- [Contribuir](#contribuir)
- [Licencia](#licencia)

---

## ¿Por qué usarlo?

La ventaja principal es simple: **normalmente no existe un solo lugar donde ver todo lo que arranca con tu sesión**. Una app puede estar en `~/.config/autostart`, otra ser un servicio `systemd --user`, otra un daemon del sistema, y encima puede haber una tarea de `cron` que ni recordabas. Para desactivar cada una hace falta un comando distinto (y a veces sudo), y es fácil dejar cosas a medias o tocar algo que no debías por no tener claro qué estás editando.

Autostart Manager junta todo eso en la misma tabla, con el mismo estado (activado/desactivado) y la misma acción (marcar/desmarcar), sin importar qué mecanismo haya por debajo. Y no es solo una lista bonita: incorpora protecciones para que no te dispares en el pie:

- **Nunca borra ni sobrescribe archivos del sistema.** Para desactivar autostart de sistema crea un *override* en tu carpeta de usuario (tal como especifica el estándar XDG), en vez de tocar `/etc/xdg/autostart` directamente.
- **Avisa antes de desactivar algo crítico** (NetworkManager, el agente de PolicyKit, el gestor de sesión, `dbus`, etc.), con una confirmación extra que se puede cancelar sin aplicar ningún otro cambio de esa pantalla.
- **Una sola contraseña por tanda de cambios.** Si desactivas varios servicios del sistema a la vez, `pkexec` se llama una única vez para todos, no una vez por servicio.
- **Detecta si un elemento no aplica a tu escritorio actual** (por ejemplo, algo con `OnlyShowIn=GNOME` en una sesión Cinnamon) y lo indica junto al elemento, aunque su casilla diga "activado".
- **Avisa si lo ejecutas como root por error**, algo fácil de hacer sin querer y que gestionaría el autostart y el cron de *root* en vez de los tuyos.

## Funciones

| | |
|---|---|
| 👤 ⚙️ ⏰ | Vista unificada de autostart de usuario, autostart de sistema, systemd (usuario y sistema) y cron, con un icono distinto por tipo |
| ☑️ | Activar / desactivar cada elemento marcando o desmarcando su casilla |
| 🔎 | Filtro de texto en vivo (busca en tipo, nombre, estado y origen a la vez) |
| 🌐 | Nombres traducidos: si un `.desktop` trae `Name[es]=`, se muestra ese en vez del genérico `Name=` |
| ⚠️ | Nota automática cuando un elemento tiene `OnlyShowIn=`/`NotShowIn=` y no aplica a tu escritorio actual |
| 🔐 | Cambios en servicios/autostart del sistema vía `pkexec`, agrupados en una sola petición de contraseña |
| 🛑 | Confirmación extra antes de desactivar servicios o agentes considerados críticos |
| 📄 | Botón para abrir/ver el archivo de origen de cualquier elemento con tu editor de texto disponible |
| 🧯 | Aviso y confirmación si detecta que el script se ejecuta como root |
| 🧩 | Degradación ordenada: si falta `systemd` o `cron`, simplemente omite esas secciones sin errores |

## Requisitos

**Obligatorio:**
- `zenity` — es lo que dibuja toda la interfaz. En Linux Mint suele venir preinstalado; si no: `sudo apt install zenity`.

**Opcionales** (si faltan, esas secciones simplemente no aparecen en la tabla, sin errores):
- `systemd` — para ver y gestionar servicios `systemctl` / `systemctl --user`.
- `cron` / `crontab` — para ver y gestionar tareas programadas del usuario.
- `policykit-1` (con un agente de autenticación gráfico activo) — necesario solo si vas a activar/desactivar servicios o autostart **del sistema**, ya que ahí se pide contraseña de administrador vía `pkexec`. En una instalación estándar de Cinnamon ya está presente.
- Un editor de texto para la opción "abrir archivo": `xed` (el de Mint por defecto), `gedit`, `gnome-text-editor`, `kate` o `mousepad`. Si no encuentra ninguno, recurre a `xdg-open`.

No hace falta instalar nada más: es un único script en Bash puro, sin dependencias de Python, Node ni librerías externas.

## Instalación

Descarga este repositorio (botón verde **Code ▸ Download ZIP** en GitHub, o clonándolo con `git`) y, dentro de la carpeta `autostart_manager`, dale permisos de ejecución:

```bash
cd autostart_manager
chmod +x script/Autostart_Manager.sh
./script/Autostart_Manager.sh
```

**Para tenerlo a mano como cualquier otra app** (opcional), tienes dos caminos:

- Usar [**Scriptya**](https://github.com/filonux/Scriptya), otra herramienta del mismo autor: convierte cualquier script en una app independiente con su propio icono, integrada en el menú de Cinnamon y/o en el escritorio, y de paso deja lanzarlo, actualizarlo o desinstalarlo desde un único menú.
- Copiarlo a mano a tu carpeta de binarios de usuario y crear un lanzador:

```bash
mkdir -p ~/.local/bin
cp script/Autostart_Manager.sh ~/.local/bin/autostart-manager
chmod +x ~/.local/bin/autostart-manager
```

Con `~/.local/bin` en tu `PATH` (viene así por defecto en Mint), a partir de ahí puedes abrirlo desde cualquier terminal simplemente escribiendo:

```bash
autostart-manager
```

## Uso

1. **Al abrirlo**, te pregunta si quieres aplicar un filtro inicial (puedes dejarlo vacío para ver todo).
2. **Aparece la tabla principal** con una fila por cada elemento encontrado: tipo, nombre, estado (✅ activado / ⛔ desactivado) y origen (ruta del archivo o nombre de la unidad).
3. **Marca o desmarca** las casillas de lo que quieras activar o desactivar. Puedes cambiar varias a la vez.
4. Pulsa **Aceptar** para aplicar los cambios marcados. Si alguno afecta a un servicio del sistema, se te pedirá la contraseña de administrador una sola vez para todos.
5. Si intentas desactivar algo marcado como crítico, verás una confirmación adicional antes de que se aplique nada.
6. Al terminar, se muestra un resumen de qué cambió y qué falló (si algo falló).
7. Después puedes elegir **abrir el archivo de origen** de cualquier elemento para inspeccionarlo o editarlo con tu editor de texto.
8. El botón **"Filtrar..."** dentro de la tabla te permite escribir una palabra para reducir la lista (por tipo, nombre, estado u origen) en cualquier momento.

> ⚠️ Limitación heredada de Zenity: si tocas casillas y luego pulsas "Filtrar..." **sin haber pulsado antes Aceptar**, esos cambios sin aplicar se pierden al refrescar la tabla. El script te avisa de esto en el propio diálogo de filtro.

## Compatibilidad

Desarrollado y probado en **Linux Mint 22.3 (Cinnamon)**, sobre base Ubuntu 24.04 / Bash 5.2.

Fuera de ese entorno:

- Debería funcionar igual en otras ediciones de Mint (MATE, Xfce) y en cualquier distro basada en Ubuntu/Debian con `zenity` instalado, ya que la detección de escritorio (`OnlyShowIn`/`NotShowIn`) se hace de forma dinámica leyendo `XDG_CURRENT_DESKTOP`, no está hardcodeada a Cinnamon.
- Requiere **sesión gráfica X11**. La apertura de archivos del sistema con permisos elevados (`edit_file_root`) propaga `DISPLAY`/`XAUTHORITY` manualmente a `pkexec`, algo pensado para X11; en **Wayland** puede no funcionar igual de bien.
- No depende de Cinnamon en el código: usa Bash + `zenity` + herramientas estándar de XDG/systemd/cron, así que en teoría corre en cualquier escritorio Linux con esas piezas disponibles. Sin embargo, solo se ha verificado formalmente en el entorno indicado arriba.

## Idioma y hoja de ruta

Por ahora, tanto este README como todos los textos, botones y mensajes de la interfaz (`zenity`) están **únicamente en español**.

Si el proyecto genera interés (estrellas, issues, uso real), se preparará una **versión en inglés** de la interfaz y de esta documentación. Ideas para más adelante, sin fecha comprometida:

- [ ] Traducción completa de la interfaz y del README al inglés (internacionalización de los textos de `zenity`)
- [ ] Detección automática de idioma según el `locale` del sistema
- [ ] Empaquetado como `.deb` / entrada en el menú de aplicaciones
- [ ] Vista de historial de cambios aplicados (qué se activó/desactivó y cuándo)

Si te interesa alguna de estas ideas (o falta alguna), abre un issue — ayuda a priorizar.

## Contribuir

Los reportes de errores, ideas y *pull requests* son bienvenidos. Antes de abrir uno, echa un vistazo a [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) para conocer el estilo de código esperado y cómo probar tus cambios antes de enviarlos.

Para reportar un fallo o pedir una función, usa las plantillas de issue del repositorio (se abren automáticamente al crear uno nuevo). Si vas a tratar algo relacionado con seguridad (por ejemplo, algo relacionado con los cambios que usan `pkexec`), consulta primero [`.github/SECURITY.md`](.github/SECURITY.md) en vez de abrir un issue público.

## Licencia

Distribuido bajo la licencia **GNU General Public License v3.0 (GPLv3)**. Consulta el archivo [`LICENSE`](LICENSE) para el texto completo.

---

<p align="center">
Copyright © 2026 Filonux
</p>
