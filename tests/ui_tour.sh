#!/bin/bash
# UI tour and aesthetic scorecard for the Zenity interface.
#   bash tests/ui_tour.sh run OUT_DIR [en|es] [ZENITY_BINARY] [browse|apply]
#       Runs the real program with the real Zenity under Xvfb, answers like a
#       scripted user, screenshots every dialog and records its arguments.
#   bash tests/ui_tour.sh score DIR...
#       Scores captured tours (dialogs as the user really sees them).
#   bash tests/ui_tour.sh static [SCRIPT]
#       Scores every dialog call of the script in both languages, no display needed.
# Rubric (weights add up to 100): Zenity acceptance 30, title present 10, title style 10,
# specific button labels 15, readable text 10, list fits its width 10, list height
# balanced 10, window fits a 1366x768 screen 5.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF="${BASH_SOURCE[0]}"
mode=${1:-}; [[ $# -gt 0 ]] && shift

scorer() { UI_TOUR_ROOT="$ROOT_DIR" python3 - "$@" <<'PY'
import glob, os, re, sys, unicodedata
from pathlib import Path
try:
    from PIL import ImageFont
except ImportError:
    ImageFont = None

WEIGHTS = {'accept': 30, 'title': 10, 'style': 10, 'labels': 15, 'text': 10, 'fit': 10, 'balance': 10, 'screen': 5}
NAMES = {'accept': 'Zenity accepts the dialog', 'title': 'Dialog has a title', 'style': 'Title starts with a pictograph',
         'labels': 'Question has specific buttons', 'text': 'Text is easy to read', 'fit': 'List fits its width',
         'balance': 'List height is balanced', 'screen': 'Window fits 1366x768'}
FONT = None
if ImageFont:
    for candidate in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', '/usr/share/fonts/dejavu/DejaVuSans.ttf'):
        if os.path.exists(candidate):
            FONT = ImageFont.truetype(candidate, 13); break

def load_fit(script):
    """FIT_GTK3/FIT_GTK4 of the program: base, line, menu row, checklist row (px)."""
    src = Path(script).read_text(encoding='utf-8')
    return {int(g): tuple(int(x) for x in v.split()) for g, v in re.findall(r'^FIT_GTK([34])=\(([0-9 ]+)\)', src, re.M)}

FIT = load_fit(Path(os.environ['UI_TOUR_ROOT']) / 'script' / 'Autostart_Manager.sh')

def px(text):
    if FONT is None: return len(text) * 7.4
    return sum(FONT.getlength(c) if ord(c) < 0x2000 else 20 for c in text)

def pictograph(c):
    return ord(c) >= 0x1F000 or unicodedata.category(c) in ('So', 'Sk') and ord(c) > 0x2000

def plain(text):
    return re.sub(r'<[^>]+>', '', text).replace('\\n', '\n')

FAILS, TAG = [], ['']
def new_stats(): return {k: [0, 0] for k in WEIGHTS}
def add(stats, key, ok, applicable=True):
    if applicable:
        stats[key][1] += 1; stats[key][0] += 1 if ok else 0
        if not ok: FAILS.append((key, TAG[0]))

def judge(stats, d):
    """d: kind, opts, accepted, columns, rows, hidden."""
    o = d['opts']
    add(stats, 'accept', d['accepted'])
    add(stats, 'title', 'title' in o)
    if 'title' in o: add(stats, 'style', bool(o['title']) and pictograph(o['title'][0]))
    if d['kind'] == '--question':
        add(stats, 'labels', 'ok-label' in o and 'cancel-label' in o)
    if 'text' in o:
        lines = plain(o['text']).split('\n')
        usable = (int(o['width']) if o.get('width', '').isdigit() else 420) - 44
        wrapped = sum(max(1, -(-int(px(l)) // usable)) for l in lines)
        add(stats, 'text', wrapped <= 14 and max(len(l) for l in lines) <= 240)
    width = int(o['width']) if o.get('width', '').isdigit() else None
    height = int(o['height']) if o.get('height', '').isdigit() else None
    if width and height:
        add(stats, 'screen', width <= 1280 and height <= 700)
    elif width:
        add(stats, 'screen', width <= 1280)
    if d['rows'] is not None and d['columns']:
        cols = d['columns']; n = len(cols); hidden = {int(x) - 1 for x in o.get('hide-column', '').split(',') if x.isdigit()}
        check = d['kind'] == '--checklist'
        total = 24
        for j in range(n):
            if j in hidden: continue
            if check and j == 0: total += 66; continue
            cells = [r[j] for r in d['rows'] if j < len(r)]
            total += max([px(cols[j]) + 22] + [px(c) + 14 for c in cells])
        if width: add(stats, 'fit', total <= width)
        if height:
            base, line, menu_row, check_row = FIT[4 if d.get('major', 3) >= 4 else 3]
            area = height - (base + line * (len(plain(o['text']).split('\n')) if 'text' in o else 1))
            need = (check_row if check else menu_row) * len(d['rows'])
            add(stats, 'balance', area > 0 and need >= 0.6 * area and (need <= area + 4 or height >= 600))

def total(stats):
    got = den = 0.0
    for k, w in WEIGHTS.items():
        num, n = stats[k]
        if n: got += w * num / n; den += w
    return 100.0 * got / den if den else 0.0

def report(label, stats, details=True):
    print(f'\nUI aesthetic scorecard - {label}')
    for k, w in WEIGHTS.items():
        num, n = stats[k]
        value = f'{100.0 * num / n:5.1f} %  ({num}/{n})' if n else '  n/a'
        print(f'  {NAMES[k]:34s} weight {w:2d}   {value}')
    print(f'  {"TOTAL":34s} {total(stats):5.1f} / 100')
    for k in WEIGHTS:
        num, n = stats[k]
        print(f'METRIC {k} {100.0 * num / n:.1f}' if n else f'METRIC {k} n/a')
    print(f'SCORE {label} {total(stats):.1f}')
    if details and os.environ.get('UI_SCORE_DETAILS') == '1':
        for key, tag in sorted(set(FAILS)):
            print(f'    - {NAMES[key]}: {tag}')
        FAILS.clear()

def parse_tour(path):
    raw = Path(path).read_bytes().decode('utf-8').split('\0')[:-1]
    kind, opts, columns, rows, after = '', {}, [], None, False
    for a in raw:
        if after: rows.append(a); continue
        if a == '--': after = True; rows = []; continue
        if a in ('--info', '--question', '--warning', '--error', '--list', '--entry'): kind = a
        if a == '--checklist': kind = '--checklist'
        if a.startswith('--') and '=' in a:
            k, v = a[2:].split('=', 1)
            if k == 'column': columns.append(v)
            else: opts[k] = v
    if rows is not None and columns:
        n = len(columns); rows = [rows[i:i + n] for i in range(0, len(rows), n)]
    return {'kind': kind, 'opts': opts, 'columns': columns, 'rows': rows}

def tour_major(d):
    try: return int(re.match(r'(\d+)\.', (Path(d) / 'zenity.version').read_text()).group(1))
    except (OSError, AttributeError): return 3

def score_tours(dirs):
    results = []
    for d in dirs:
        stats = new_stats()
        for f in sorted(glob.glob(os.path.join(d, '*.args'))):
            dlg = parse_tour(f); dlg['major'] = tour_major(d); TAG[0] = os.path.basename(f)[:-5] + ' ' + dlg['kind'] + ' ' + dlg['opts'].get('title', '(no title)')
            rc = Path(f[:-5] + '.rc').read_text().strip() if os.path.exists(f[:-5] + '.rc') else ''
            dlg['accepted'] = 'REJECTED' not in rc
            judge(stats, dlg)
        results.append((os.path.basename(d.rstrip('/')), stats)); report(os.path.basename(d.rstrip('/')), stats)
    if len(results) > 1:
        merged = new_stats()
        for _, st in results:
            for k in merged: merged[k][0] += st[k][0]; merged[k][1] += st[k][1]
        report('ALL TOURS', merged)

def catalog(src):
    rx = re.compile(r"MSG_(ES|EN)\[([A-Za-z0-9_]+)\]='((?:[^'\\]|\\.)*)'")
    cat = {}
    for lang, key, raw in rx.findall(src):
        cat[(lang, key)] = raw.replace('\\n', '\n').replace("\\'", "'")
    return cat

TEXT_VARS = {'menu_text': 'menu_text', 'list_text': 'checklist_text', 'browse_text': 'browse_text'}   # shell variable -> message key

def resolve(expr, lang, cat):
    m = re.fullmatch(r'"?\$\(msg ([a-z_0-9]+)(?: .*)?\)"?', expr.strip())
    if m and (lang, m.group(1)) in cat:
        return re.sub(r'%[sd]', 'SAMPLE', cat[(lang, m.group(1))])
    v = re.fullmatch(r'"?\$([a-z_]+)"?', expr.strip())
    if v and (lang, TEXT_VARS.get(v.group(1), '')) in cat:
        return re.sub(r'%[sd]', 'SAMPLE', cat[(lang, TEXT_VARS[v.group(1)])])
    if re.fullmatch(r'"\$cat_icon \$cat_label"', expr.strip()):
        return '\U0001F680 Sample'
    return expr.strip().strip('"')

def shell_words(stmt):
    words, cur, quote, depth, i = [], '', False, 0, 0
    while i < len(stmt):
        c = stmt[i]
        if c == '\\' and i + 1 < len(stmt): cur += stmt[i:i + 2]; i += 2; continue
        if stmt.startswith('$(', i): depth += 1; cur += '$('; i += 2; continue
        if c == ')' and depth: depth -= 1
        elif c == '"' and depth == 0: quote = not quote
        elif c.isspace() and not quote and depth == 0:
            if cur: words.append(cur); cur = ''
            i += 1; continue
        cur += c; i += 1
    if cur: words.append(cur)
    return words

def static_score(script):
    src = Path(script).read_text(encoding='utf-8')
    cat = catalog(src)
    allowed = set()
    compat = Path(script).parent.parent / 'tests' / 'test_zenity_compat.sh'
    if compat.exists():
        m = re.search(r"COMMON_OPTIONS='([^']*)'", compat.read_text(encoding='utf-8'))
        if m: allowed = set(m.group(1).split())
    lines = src.split('\n'); calls = []; i = 0; first_line = {}
    while i < len(lines):
        line = lines[i]
        if re.search(r'\bzen --', line) and not line.lstrip().startswith('#'):
            stmt = line; start = i + 1
            while stmt.rstrip().endswith('\\') and i + 1 < len(lines):
                i += 1; stmt = stmt.rstrip()[:-1] + ' ' + lines[i].strip()
            calls.append(stmt); first_line[id(stmt)] = start
        i += 1
    stats = new_stats()
    for st in calls:
        kinds = re.findall(r'(?<![\w-])--(info|question|warning|error|list|entry|checklist)\b', st)
        kind = '--checklist' if 'checklist' in kinds else ('--' + kinds[0] if kinds else '')
        used = set(re.findall(r'(?<![\w-])(--[a-z][a-z-]*)', re.sub(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'', '""', st))) - {'--'}
        accepted = (not allowed) or used <= allowed
        for lang in ('EN', 'ES'):
            o = {}
            TAG[0] = f'line {first_line[id(st)]} {lang} {kind}'
            for word in shell_words(st[re.search(r'\bzen --', st).start():]):
                m = re.fullmatch(r'--([a-z-]+)=(.*)', word, re.S)
                if not m: continue
                key, val = m.groups()
                o[key] = resolve(val, lang, cat) if key in ('title', 'text', 'ok-label', 'cancel-label') else val.strip('"')
            judge(stats, {'kind': kind, 'opts': o, 'accepted': accepted, 'columns': [], 'rows': None})
    print(f'(static analysis of {len(calls)} dialog calls, EN and ES)')
    report(os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(script)))) + ' script', stats)

mode = sys.argv[1]
if mode == 'score': score_tours(sys.argv[2:])
elif mode == 'static': static_score(sys.argv[2])
PY
}

case "$mode" in
    score)  scorer score "$@"; exit $? ;;
    static) scorer static "${1:-$ROOT_DIR/script/Autostart_Manager.sh}"; exit $? ;;
    run) ;;
    *) sed -n '2,14p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# ---------------------------------------------------------------- run
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
OUT=${1:?usage: ui_tour.sh run OUT_DIR [en|es] [ZENITY_BINARY] [browse|apply]}
LANG_TOUR=${2:-en}
ZENITY_REAL=${3:-$(command -v zenity)}
SCENARIO=${4:-browse}
as_user=(); (( EUID == 0 )) && as_user=(runuser -u nobody --)

mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
W=$(mktemp -d -p /tmp uit.XXXX); SYS_ROOT=$(mktemp -d -p /tmp e.XXX)
trap 'rm -rf "$W" "$SYS_ROOT"' EXIT; chmod 777 "$W"; chmod 755 "$SYS_ROOT"
STAGE="$W/out"; mkdir -p "$STAGE"; chmod 777 "$STAGE"
HOME_F="$W/home"; SYS_F="$SYS_ROOT/autostart"; BIN="$W/bin"
mkdir -p "$HOME_F/.config/autostart" "$SYS_F" "$BIN"

entry() {   # entry <dir> <file> <name> <comment> <exec> [extra lines...]
    local dir="$1" file="$2" name="$3" comment="$4" exec="$5"; shift 5
    { printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nExec=%s\n' "$name" "$comment" "$exec"; printf '%s\n' "$@"; } > "$dir/$file"
}
entry "$HOME_F/.config/autostart" redshift-gtk.desktop "Redshift" "Adjust the color temperature of your screen" "redshift-gtk" "X-GNOME-Autostart-enabled=true"
entry "$HOME_F/.config/autostart" dropbox.desktop "Dropbox" "Sync your files" "dropbox start -i" "X-GNOME-Autostart-enabled=true"
entry "$HOME_F/.config/autostart" syncthing-start.desktop "Syncthing Start" "Start Syncthing in the background" "syncthing serve --no-browser" "X-GNOME-Autostart-enabled=true"
entry "$HOME_F/.config/autostart" steam.desktop "Steam" "Application for managing and playing games" "/usr/games/steam -silent" "X-GNOME-Autostart-enabled=false"
entry "$SYS_F" polkit-gnome-authentication-agent-1.desktop "PolicyKit Authentication Agent" "PolicyKit Authentication Agent" "/usr/lib/policykit-1-gnome/polkit-gnome-authentication-agent-1" "X-GNOME-Autostart-enabled=true" "OnlyShowIn=GNOME;Unity;X-Cinnamon;"
entry "$SYS_F" nm-applet.desktop "Network" "Manage your network connections" "nm-applet" "X-GNOME-Autostart-enabled=true"
entry "$SYS_F" blueman.desktop "Blueman Applet" "Bluetooth management applet" "blueman-applet" "X-GNOME-Autostart-enabled=true"
entry "$SYS_F" mintupdate.desktop "Update Manager" "Linux Mint update manager" "mintupdate-launcher" "X-GNOME-Autostart-enabled=true"
entry "$SYS_F" mintwelcome.desktop "Welcome Screen" "Introduction to Linux Mint" "mintwelcome-launcher" "X-GNOME-Autostart-enabled=true"
printf '#!/bin/bash\nexit 0\n' > "$BIN/systemctl"
# shellcheck disable=SC2016  # the fake crontab is written verbatim into a file
printf '#!/bin/bash\n[[ "${1:-}" == -l ]] && { printf "SHELL=/bin/bash\\n0 3 * * * /usr/bin/backup --daily\\n*/15 * * * * /usr/bin/notify-check\\n"; exit 0; }\nexit 0\n' > "$BIN/crontab"
printf '#!/bin/bash\nexit 0\n' > "$BIN/pgrep"; printf '#!/bin/bash\nexit 0\n' > "$BIN/xdg-open"
printf '#!/bin/bash\nexit 0\n' > "$BIN/xed"   # first editor for X-Cinnamon: opening an item never starts a real one
chmod +x "$BIN"/*

# One scripted answer per dialog, in the order the program shows them (the wrapper below documents the tokens).
# The rows of the systemd categories depend on the machine, so the tours only use the ones the fixture controls:
# category 1 (nine autostart entries) and category 3 (two cron jobs).
case "$SCENARIO" in
    browse)   # navigation only, nothing is changed; the language is switched at the end
        ANSWERS=(
            ID:3        # menu: Scheduled Tasks
            EXTRA:2     # checklist: Open / view source
            FIRST       # source list: first cron job
            OK          # information: cron is edited with crontab -e
            EXTRA:1     # checklist: Search / filter
            TEXT:zzz    # filter that matches nothing
            YES         # nothing found: clear the filter
            CANCEL      # checklist: back to the menu
            ID:1        # menu: Startup Applications
            EXTRA:2     # checklist: Open / view source
            FIRST       # source list: first entry (opens the fake editor, no dialog)
            CANCEL      # checklist: back to the menu
            ID:L        # menu: switch language
            CANCEL      # menu in the other language: exit
        ) ;;
    apply)    # changes: a critical entry, nothing to apply, and a batch where one change fails
        ANSWERS=(
            ID:1                  # menu: Startup Applications
            UNCHECK:PolicyKit     # checklist: disable the critical agent
            YES                   # critical confirmation
            OK                    # result: all applied
            KEEP                  # checklist: OK with nothing changed
            OK                    # information: nothing to apply
            'UNCHECK:Welcome;Update'   # checklist: disable two entries; the override of the first cannot be written
            OK                    # result: partly applied
            OK                    # warning: what failed
            CANCEL                # checklist: back to the menu
            CANCEL                # menu: exit
        ) ;;
    *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
# An override that cannot be written: a directory sits where the entry's override file would go.
[[ "$SCENARIO" == apply ]] && mkdir "$HOME_F/.config/autostart/mintwelcome.desktop"
printf '%s\n' "${ANSWERS[@]}" > "$W/answers"; echo 0 > "$W/count"; echo 0 > "$W/ans"

cat > "$W/zenity" <<'WRAP'
#!/bin/bash
# Test double: records the call, screenshots the real Zenity window, then answers.
# A dialog Zenity rejects (exit 255) is returned as-is so the program uses its own fallback.
# Tokens: ID:x (print x) TEXT:x (print x) FIRST (print the first row's first cell) YES|OK (exit 0)
#   EXTRA:n (print the label of the n-th --extra-button, exit 1) KEEP (checked rows as they are)
#   UNCHECK1 (all but the first checked row) UNCHECK:a;b (all but rows whose name contains a or b)
#   anything else, CANCEL included: exit 1
set -u
if [[ "${1:-}" == --version ]]; then   # not a dialog: pass through and record it for the scorer
    "$ZENITY_REAL" --version | tee "$TOUR_OUT/zenity.version"
    exit "${PIPESTATUS[0]}"
fi
n=$(( $(cat "$TOUR_W/count") + 1 )); echo "$n" > "$TOUR_W/count"
nn=$(printf '%02d' "$n"); printf '%s\0' "$@" > "$TOUR_OUT/$nn.args"
"$ZENITY_REAL" --timeout=40 "$@" >/dev/null 2>&1 &
zpid=$!
failures=0
for _ in $(seq 1 40); do
    sleep 0.3
    kill -0 "$zpid" 2>/dev/null || { wait "$zpid"; echo "$?" > "$TOUR_OUT/$nn.rc"; break; }
    import -display "$DISPLAY" -window root "$TOUR_OUT/$nn.png" 2>/dev/null || { failures=$((failures + 1)); (( failures >= 12 )) && break; continue; }
    deviation=$(identify -format '%[fx:standard_deviation]' "$TOUR_OUT/$nn.png" 2>/dev/null) || continue
    awk -v d="$deviation" 'BEGIN { exit !(d > 0.001) }' && { sleep 0.6; import -display "$DISPLAY" -window root "$TOUR_OUT/$nn.png" 2>/dev/null; break; }
done
if kill -0 "$zpid" 2>/dev/null; then kill "$zpid" 2>/dev/null; wait "$zpid" 2>/dev/null; echo shown > "$TOUR_OUT/$nn.rc"; fi
if [[ "$(cat "$TOUR_OUT/$nn.rc" 2>/dev/null)" == 255 ]]; then echo "REJECTED by Zenity" >> "$TOUR_OUT/$nn.rc"; exit 255; fi
a_n=$(( $(cat "$TOUR_W/ans") + 1 )); echo "$a_n" > "$TOUR_W/ans"
ans=$(sed -n "${a_n}p" "$TOUR_W/answers")
case "$ans" in
    ID:*)   printf '%s' "${ans#ID:}"; exit 0 ;;
    TEXT:*) printf '%s' "${ans#TEXT:}"; exit 0 ;;
    YES|OK) exit 0 ;;
    FIRST)
        after=0
        for a in "$@"; do
            (( after )) && { printf '%s' "$a"; exit 0; }
            [[ "$a" == -- ]] && after=1
        done
        exit 1 ;;
    EXTRA:*)
        k=0
        for a in "$@"; do
            [[ "$a" == --extra-button=* ]] || continue
            k=$((k + 1))
            (( k == ${ans#EXTRA:} )) && { printf '%s' "${a#--extra-button=}"; exit 1; }
        done
        exit 1 ;;
    KEEP|UNCHECK1|UNCHECK:*)
        ncol=0; sep='|'; after=0; row=(); out=(); first=1
        for a in "$@"; do
            if (( after )); then row+=("$a"); continue; fi
            [[ "$a" == -- ]] && { after=1; continue; }
            [[ "$a" == --column=* ]] && ncol=$((ncol + 1))
            [[ "$a" == --separator=* ]] && sep="${a#--separator=}"
        done
        for ((i = 0; i < ${#row[@]}; i += ncol)); do
            [[ "${row[i]}" == TRUE ]] || continue
            if [[ "$ans" == UNCHECK1 && $first -eq 1 ]]; then first=0; continue; fi
            if [[ "$ans" == UNCHECK:* ]]; then
                skip=0; IFS=';' read -ra names <<< "${ans#UNCHECK:}"
                for name in "${names[@]}"; do [[ "${row[i+3]}" == *"$name"* ]] && skip=1; done
                (( skip )) && continue
            fi
            out+=("${row[i+1]}")
        done
        (IFS="$sep"; printf '%s' "${out[*]}"); exit 0 ;;
esac
exit 1
WRAP
chmod 755 "$W/zenity"; chmod -R a+rwX "$W"

env_run=(env HOME="$HOME_F" XDG_CONFIG_HOME="$HOME_F/.config" XDG_CONFIG_DIRS="$SYS_ROOT" XDG_CURRENT_DESKTOP=X-Cinnamon PATH="$W:$BIN:$PATH"
    AUTOSTART_MANAGER_LANG="$LANG_TOUR" LANG=C.UTF-8 LC_ALL=C.UTF-8 TOUR_W="$W" TOUR_OUT="$STAGE" ZENITY_REAL="$ZENITY_REAL")
timeout -k 2 240 "${as_user[@]}" "${env_run[@]}" xvfb-run -a -s '-screen 0 1366x768x24' bash "$SCRIPT" >"$STAGE/program.out" 2>&1
rc=$?
cp -a "$STAGE"/. "$OUT"/
echo "tour finished: rc=$rc dialogs=$(cat "$W/count") scenario=$SCENARIO lang=$LANG_TOUR"
