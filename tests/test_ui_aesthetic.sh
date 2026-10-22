#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT_DIR/script/Autostart_Manager.sh"
TMP=$(mktemp -d)
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

if ! python3 -c 'import PIL' 2>/dev/null; then
    if [[ "${REQUIRE_PILLOW:-0}" == 1 ]]; then
        printf 'FAIL: Pillow is required\n1 tests: 0 passed, 1 failed\n'; exit 1
    fi
    printf 'SKIP: Pillow (python3-pil) is not installed.\n'; exit 0
fi

AESTHETIC_OUT="${AESTHETIC_OUT_DIR:-$TMP}"
mkdir -p "$AESTHETIC_OUT"
cat > "$TMP/zenity" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$TMP/zenity"
for lang in en es; do
    LANG_UI="$lang" AUTOSTART_MANAGER_LANG="$lang" PATH="$TMP:$PATH" AUTOSTART_MANAGER_TEST=1 bash -c 'source "$1"; init_categories; for i in 1 2 3 4 5; do printf "%s|%s\n" "${CATEGORY_ICON[$i]}" "${CATEGORY_LABEL[$i]}"; done' _ "$SCRIPT" > "$AESTHETIC_OUT/categories_$lang.txt"
done
python3 - "$SCRIPT" "$AESTHETIC_OUT" "$AESTHETIC_OUT/categories_en.txt" "$AESTHETIC_OUT/categories_es.txt" <<'PY'
import re, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

script = Path(sys.argv[1]); outdir = Path(sys.argv[2]); en_cats = Path(sys.argv[3]).read_text(encoding='utf-8').splitlines(); es_cats = Path(sys.argv[4]).read_text(encoding='utf-8').splitlines(); outdir.mkdir(parents=True, exist_ok=True)
s = script.read_text(encoding='utf-8')
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 13)
bold = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 14)
rx = re.compile(r"MSG_(ES|EN)\[([A-Za-z0-9_]+)\]='((?:[^'\\]|\\.)*)'")
catalog = {}
for lang, key, raw in rx.findall(s):
    catalog[(lang, key)] = raw.replace(r'\n', '\n').replace(r'\\', '\\')

def text(lang, key): return catalog[(lang, key)]
def width(s, f=font): return max((f.getlength(x) for x in s.splitlines()), default=0)
def wrap_lines(s, limit, f=font):
    result=[]
    for raw in s.splitlines() or ['']:
        if not raw:
            result.append(''); continue
        line=''
        for word in raw.split():
            candidate = word if not line else line+' '+word
            if not line or f.getlength(candidate) <= limit:
                line=candidate
            else:
                result.append(line); line=word
        result.append(line)
    return result

fail=[]
for lang in ('ES','EN'):
    dialogs={
      'root_text':(440,300), 'critical_text':(470,320), 'failure_text':(510,300),
      'checklist_text':(1020,160), 'browse_text':(940,60), 'filter_text':(420,90),
    }
    for key,(w,h) in dialogs.items():
        t=re.sub(r'%s','SENTINEL',text(lang,key))
        wrapped=wrap_lines(t,w)
        if any(width(line)>w+1 for line in wrapped): fail.append(f'{lang}:{key}:horizontal')
        if len(wrapped)*(font.size+4)>h: fail.append(f'{lang}:{key}:vertical')

    W,H=680,420
    im=Image.new('RGB',(W,H),'white'); d=ImageDraw.Draw(im)
    placements=[
      ('title',(18,16),text(lang,'main_title'),bold,(18,10,662,42)),
      ('body',(18,52),text(lang,'menu_text'),font,(18,45,662,78)),
      ('cat_header',(24,92),text(lang,'category_col'),bold,(24,86,340,112)),
      ('sum_header',(360,92),text(lang,'summary_col'),bold,(360,86,662,112)),
      ('lang',(24,365),text(lang,'lang_switch'),font,(18,350,420,402)),
      ('hint',(430,365),text(lang,'lang_hint'),font,(420,350,662,402)),
    ]
    for name,(x,y),t,f,region in placements:
        d.text((x,y),t,font=f,fill='black')
        bb=d.textbbox((x,y),t,font=f)
        x0,y0,x1,y1=region
        if bb[0]<x0 or bb[1]<y0 or bb[2]>x1 or bb[3]>y1:
            fail.append(f'{lang}:{name}:bbox={bb}')
    cats = es_cats if lang == 'ES' else en_cats
    if len(cats) != 5: fail.append(f'{lang}:category-label-count')
    for i, item in enumerate(cats[:5]):
        icon, cat_label = item.split('|', 1)
        y=122+i*32
        # DejaVu does not provide the color-emoji glyphs used by GTK/Zenity;
        # use a fixed visual marker in the synthetic fixture while measuring
        # the real text width separately. This keeps the screenshot honest.
        cat='■ ' + cat_label
        summary=text(lang,'summary_item').replace('%s',str(i+1),1).replace('%s',str(i%2),1)
        if width(cat)>310: fail.append(f'{lang}:category-row')
        if width(summary)>290: fail.append(f'{lang}:summary-row')
        d.text((24,y),cat,font=font,fill='black'); d.text((360,y),summary,font=font,fill='black')
    path=outdir/f'main_{lang.lower()}.png'
    im.save(path)
    # Ensure the visual fixture is useful evidence, not a silently blank render.
    reloaded=Image.open(path).convert('RGB')
    if reloaded.size != (W,H): fail.append(f'{lang}:render-size')
    extrema=reloaded.getextrema()
    if all(lo == hi == 255 for lo,hi in extrema): fail.append(f'{lang}:blank-render')

if not (outdir/'main_en.png').exists() or not (outdir/'main_es.png').exists():
    fail.append('render-fixtures-missing')

for item in fail: print('AESTHETIC_FAIL', item)
if fail: raise SystemExit(1)
print('AESTHETIC_LAYOUT_OK')
PY
rc=$?
check 'localized dialogs fit measured layout budgets' "$rc" 0

# --- Aesthetic scorecard (rubric and tours: tests/ui_tour.sh) -----------------
TOUR="$ROOT_DIR/tests/ui_tour.sh"
metric() { awk -v k="$2" '$1 == "METRIC" && $2 == k { print $3 }' <<< "$1"; }

static_out=$(bash "$TOUR" static "$SCRIPT" 2>&1)
check 'static scorecard analyses every dialog call' \
    "$(( $(sed -n 's/^(static analysis of \([0-9]*\) dialog calls.*/\1/p' <<< "$static_out") >= 16 ))" 1
for key in accept title style labels text screen; do
    check "static scorecard: $key is 100%" "$(metric "$static_out" "$key")" 100.0
done
check 'static scorecard total is at least 99' "$(awk '/^SCORE /{ print ($NF >= 99.0) }' <<< "$static_out")" 1

# The analyser must notice regressions: drop a title, bring back --icon.
mkdir -p "$TMP/mut/script" "$TMP/mut/tests"
cp "$ROOT_DIR/tests/test_zenity_compat.sh" "$TMP/mut/tests/"
mutate_script() {   # mutate_script NEEDLE REPLACEMENT: the program with NEEDLE (exactly once) replaced
    python3 - "$SCRIPT" "$TMP/mut/script/Autostart_Manager.sh" "$1" "$2" <<'PYM'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
if src.count(sys.argv[3]) != 1: raise SystemExit('mutation pattern must occur exactly once: ' + sys.argv[3])
open(sys.argv[2], 'w', encoding='utf-8').write(src.replace(sys.argv[3], sys.argv[4], 1))
PYM
}
# shellcheck disable=SC2016  # the patterns are literal source text
mutate_script '--title="$(msg all_ok_title)" ' ''
check 'scorecard notices a dialog without title' \
    "$([[ "$(metric "$(bash "$TOUR" static "$TMP/mut/script/Autostart_Manager.sh" 2>&1)" title)" != 100.0 ]] && echo lower || echo same)" lower
mutate_script '--width=380' '--icon="dialog-information" --width=380'
check 'scorecard notices an option Zenity 3.44 rejects' \
    "$([[ "$(metric "$(bash "$TOUR" static "$TMP/mut/script/Autostart_Manager.sh" 2>&1)" accept)" != 100.0 ]] && echo lower || echo same)" lower

# Dialog text held in a variable is still analysed: 15 extra lines must lower the text score.
python3 - "$SCRIPT" "$TMP/mut/script/Autostart_Manager.sh" <<'PY2'
import sys
src = open(sys.argv[1], encoding='utf-8').read()
key = "MSG_EN[checklist_text]='"
assert key in src
open(sys.argv[2], 'w', encoding='utf-8').write(src.replace(key, key + 'x\\n' * 15, 1))
PY2
check 'scorecard reads dialog text held in a variable' \
    "$([[ "$(metric "$(bash "$TOUR" static "$TMP/mut/script/Autostart_Manager.sh" 2>&1)" text)" != 100.0 ]] && echo lower || echo same)" lower

# Balance judge: it uses the program's own constants (FIT_GTK3/FIT_GTK4) and the tour's Zenity version.
make_tour() {   # make_tour DIR ZENITY_VERSION HEIGHT ROWS: one checklist dialog with a 4-line text
    local dir="$1" ver="$2" height="$3" rows="$4" i args
    mkdir -p "$dir"
    [[ -z "$ver" ]] || printf '%s\n' "$ver" > "$dir/zenity.version"
    args=(--list --checklist '--title=📋 Test' '--text=A\nB\nC\nD' --width=1180 "--height=$height"
          --column=Active --column=ID --column=Type --column=Name --column=Status --column=Source --)
    for ((i = 1; i <= rows; i++)); do args+=(TRUE "$i" Type "Name $i" Enabled Source); done
    printf '%s\0' "${args[@]}" > "$dir/01.args"; echo shown > "$dir/01.rc"
}
fit_of() {   # fit_of MAJOR ROWS: height the program gives a 4-line checklist
    PATH="$TMP:$PATH" AUTOSTART_MANAGER_TEST=1 bash -c 'source "$1"; ZEN_MAJOR=$2; fit_height "A\nB\nC\nD" "$3" check' _ "$SCRIPT" "$1" "$2"
}
balance_of() { metric "$(bash "$TOUR" score "$1" 2>&1)" balance; }
h3=$(fit_of 3 8); h4=$(fit_of 4 3)
make_tour "$TMP/b-ok3" '' "$h3" 8
check 'balance judge accepts the height fit_height gives for Zenity 3.x' "$(balance_of "$TMP/b-ok3")" 100.0
make_tour "$TMP/b-ok4" 4.0.1 "$h4" 3
check 'balance judge accepts the height fit_height gives for Zenity 4.x' "$(balance_of "$TMP/b-ok4")" 100.0
make_tour "$TMP/b-tall" '' 600 8
check 'balance judge notices a list with too much empty space' "$([[ "$(balance_of "$TMP/b-tall")" != 100.0 ]] && echo lower || echo same)" lower
make_tour "$TMP/b-short" '' 340 8
check 'balance judge notices a list that needlessly scrolls' "$([[ "$(balance_of "$TMP/b-short")" != 100.0 ]] && echo lower || echo same)" lower
make_tour "$TMP/b-ver" 4.0.1 "$h3" 8
check 'balance judge applies the Zenity version of the tour' "$([[ "$(balance_of "$TMP/b-ver")" != 100.0 ]] && echo lower || echo same)" lower

# Real dialogs: the installed Zenity must accept and render every dialog of the tours.
if command -v zenity >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1 \
   && command -v import >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    timeout -k 2 120 bash "$TOUR" run "$TMP/tour-en" en "$(command -v zenity)" browse >/dev/null 2>&1
    timeout -k 2 120 bash "$TOUR" run "$TMP/tour-es" es "$(command -v zenity)" apply >/dev/null 2>&1
    real_out=$(bash "$TOUR" score "$TMP/tour-en" "$TMP/tour-es" 2>&1 | sed -n '/ALL TOURS/,$p')
    tour_kinds() {   # one letter per captured dialog: List, Checklist, Info, Question, Warning, Entry
        local f out=""
        for f in "$1"/*.args; do
            out+=$(tr '\0' '\n' < "$f" | awk '$0 == "--list" && k == "" { k = "L" } $0 == "--checklist" { k = "C" }
                $0 == "--info" { k = "I" } $0 == "--question" { k = "Q" } $0 == "--warning" { k = "W" } $0 == "--entry" { k = "E" }
                END { print k }')
        done
        printf '%s' "$out"
    }
    check 'real dialogs: the browse tour shows its dialogs in order' "$(tour_kinds "$TMP/tour-en")" LCLICEQCLCLCLL
    check 'real dialogs: the apply tour shows its dialogs in order' "$(tour_kinds "$TMP/tour-es")" LCQICICIWCL
    for key in accept title style labels; do
        check "real dialogs: $key is 100%" "$(metric "$real_out" "$key")" 100.0
    done
    check 'real dialogs: list height is balanced' "$(metric "$real_out" balance)" 100.0
    check 'real tour records the Zenity version' "$(grep -cE '^[0-9]+\.' "$TMP/tour-en/zenity.version")" 1
    check 'real dialogs: total is at least 95' "$(awk '/^SCORE /{ print ($NF >= 95.0) }' <<< "$real_out")" 1
elif [[ "${REQUIRE_UI_SMOKE:-0}" == 1 ]]; then
    check 'real UI tools are available for the scorecard' missing available
else
    printf 'SKIP: Zenity, Xvfb and ImageMagick are needed for the real-dialog scorecard.\n'
fi

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
