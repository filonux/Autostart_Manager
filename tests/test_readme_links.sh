#!/bin/bash
set -uE -o pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0
check() {
    local name="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf 'PASS: %s\n' "$name"; ((pass++))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"; ((fail++))
    fi
}

python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
from urllib.parse import urlparse, unquote
import html, re, struct, sys

root = Path(sys.argv[1]).resolve()
readmes = [root / 'README.md', root / 'README.es.md']

def github_slugs(text: str):
    counts, slugs = {}, set()
    for m in re.finditer(r'^(#{1,6})\s+(.+?)\s*#*\s*$', text, re.M):
        heading = re.sub(r'<[^>]+>', '', m.group(2)).strip().lower()
        heading = ''.join(ch for ch in heading if ch.isalnum() or ch in ' _-')
        heading = re.sub(r'[ _]+', '-', heading).strip('-') or 'section'
        n = counts.get(heading, 0)
        slugs.add(heading if n == 0 else f'{heading}-{n}')
        counts[heading] = n + 1
    return slugs

errors = []
for readme in readmes:
    text = readme.read_text(encoding='utf-8')
    stripped = re.sub(r'```[^\n]*\n.*?^```\s*', '', text, flags=re.S | re.M)
    anchors = github_slugs(text)
    refs = re.findall(r'!?(?:\[[^\n\]]*\])\(\s*(<[^>]+>|[^\s)]+)(?:\s+[^)]*)?\)', stripped)
    refs += [html.unescape(m.strip()) for m in re.findall(r'\b(?:href|src)\s*=\s*["\']([^"\']+)["\']', stripped, re.I)]

    for raw in refs:
        target = raw.strip('<>')
        parsed = urlparse(target)
        if parsed.scheme or target.startswith('//'):
            if parsed.scheme in {'http', 'https', 'mailto'} or target.startswith('//'):
                continue
            errors.append(f'{readme.name}: unsupported external scheme {target}')
            continue
        path = unquote(parsed.path)
        if path:
            resolved = (readme.parent / path).resolve()
            try:
                resolved.relative_to(root)
            except ValueError:
                errors.append(f'{readme.name}: link escapes project: {target}')
                continue
            if not resolved.is_file():
                errors.append(f'{readme.name}: missing target {target}')
        frag = unquote(parsed.fragment)
        if frag and frag not in anchors:
            errors.append(f'{readme.name}: broken anchor #{frag} in {target}')

    if re.search(r'(?i)(?:\]\(|href=["\'])\s*LICENSE(?:[)#"\'\s]|$)', stripped):
        errors.append(f'{readme.name}: references LICENSE, but the shipped file is LICENSE.txt')
    if re.search(r'(?im)^\s*cd\s+autostart_manager\s*$', stripped):
        errors.append(f'{readme.name}: assumes an incorrect repository directory name')
    if not re.search(r'(?m)^git clone https://github\.com/filonux/Autostart_Manager\.git\s*$\ncd Autostart_Manager\s*$', text):
        errors.append(f'{readme.name}: clone instructions must enter Autostart_Manager')
    if not re.search(r'(?m)^\./script/Autostart_Manager\.sh --install\s*$', text):
        errors.append(f'{readme.name}: install command is incorrect')
    if not re.search(r'(?m)^\./script/Autostart_Manager\.sh --uninstall\s*$', text):
        errors.append(f'{readme.name}: uninstall command is incorrect')
    if readme.name == 'README.md' and not re.search(r'href=["\']README\.es\.md["\']|\]\(README\.es\.md\)', text):
        errors.append('README.md: missing Spanish README link')
    if readme.name == 'README.es.md' and not re.search(r'href=["\']README\.md["\']|\]\(README\.md\)', text):
        errors.append('README.es.md: missing English README link')
    if readme.name == 'README.md' and '`pkexec` is required only for operations that need administrator privileges' not in text:
        errors.append('README.md: privileged-operation requirement is inaccurate')
    if readme.name == 'README.es.md' and '`pkexec` solo es necesario para operaciones que requieran privilegios de administrador' not in text:
        errors.append('README.es.md: privileged-operation requirement is inaccurate')
    if readme.name == 'README.md' and 'a graphical PolicyKit authentication agent is needed for a graphical password prompt' not in text:
        errors.append('README.md: graphical PolicyKit agent requirement is not documented accurately')
    if readme.name == 'README.es.md' and 'un agente gráfico de PolicyKit es necesario para mostrar un diálogo gráfico de contraseña' not in text:
        errors.append('README.es.md: graphical PolicyKit agent requirement is not documented accurately')
    if readme.name == 'README.md' and '`pkexec` may fall back to a text agent' not in text:
        errors.append('README.md: text-agent fallback is not documented accurately')
    if readme.name == 'README.es.md' and '`pkexec` puede recurrir a un agente textual' not in text:
        errors.append('README.es.md: text-agent fallback is not documented accurately')

if not (root / 'LICENSE.txt').is_file():
    errors.append('project: LICENSE.txt is missing')

en = (root / 'README.md').read_text(encoding='utf-8')
es = (root / 'README.es.md').read_text(encoding='utf-8')

def fenced_blocks(text: str):
    return re.findall(r'^```[^\n]*\n(.*?)^```', text, re.M | re.S)

if fenced_blocks(en) != fenced_blocks(es):
    errors.append('README files: fenced code blocks differ')

if len(re.findall(r'^## ', en, re.M)) != len(re.findall(r'^## ', es, re.M)):
    errors.append('README files: section counts differ')

# Screenshots live in the repository, one folder per language, in the order of the program's own screens:
# menu, startup applications, background processes, application services, system services, all categories.
SHOTS = {
    'EN': ['1-menu-AutostartManager-en.png', '2-AutostartManager-startupapps-en.png',
           '3-AutostartManager-background-en.png', '4-AutostartManager-applicationservices-en.png',
           '5-AutostartManager-systemservices-en.png', '6-AutostartManager-allcategories-en.png'],
    'ES': ['1-menu-AutostartManager-es.png', '2-AutostartManager-programasinicio-es.png',
           '3-AutostartManager-procesossegplano-es.png', '4-AutostartManager-serviciosapps-es.png',
           '5-AutostartManager-serviciossistema-es.png', '6-AutostartManager-todascategorias-es.png'],
}

def png_size(path):
    with path.open('rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
        return None
    return struct.unpack('>II', head[16:24])

def attr(tag, name):
    m = re.search(rf'\b{name}="([^"]*)"', tag)
    return m.group(1) if m else None

for name, lang, text in (('README.md', 'EN', en), ('README.es.md', 'ES', es)):
    other = 'ES' if lang == 'EN' else 'EN'
    if 'user-attachments' in text:
        errors.append(f'{name}: screenshots must be the files in assets/screenshots, not GitHub attachments')
    shots = [t for t in re.findall(r'<img\b[^>]*>', text) if 'screenshots/' in (attr(t, 'src') or '')]
    sources = [attr(t, 'src') for t in shots]
    expected = [f'assets/screenshots/{lang}/{f}' for f in SHOTS[lang]]
    if any(f'screenshots/{other}/' in (s_ or '') for s_ in sources):
        errors.append(f'{name}: shows a screenshot from the {other} folder')
    if sources != expected:
        errors.append(f'{name}: screenshots must be exactly the six {lang} files in menu, startup, background, '
                      f'application services, system services, all categories order\n  expected: {expected}\n  found:    {sources}')
    folder = root / 'assets' / 'screenshots' / lang
    on_disk = sorted(f.name for f in folder.glob('*')) if folder.is_dir() else []
    if on_disk != sorted(SHOTS[lang]):
        errors.append(f'{name}: {folder.relative_to(root)} must hold exactly the six referenced screenshots, found {on_disk}')
    alts = [attr(t, 'alt') for t in shots]
    if not all(alts) or len(set(alts)) != len(alts):
        errors.append(f'{name}: every screenshot needs its own non-empty alt text')
    for tag in shots:
        src = attr(tag, 'src')
        size = png_size(root / src) if (root / src).is_file() else None
        if size is None:
            errors.append(f'{name}: {src} is missing or is not a PNG')
        elif (attr(tag, 'width'), attr(tag, 'height')) != (str(size[0]), str(size[1])):
            errors.append(f'{name}: {src} is {size[0]}x{size[1]} but declares {attr(tag, "width")}x{attr(tag, "height")}')

if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
print(f'Checked {len(readmes)} README files; all local Markdown/HTML references and anchors resolve.')
PY
check 'README link audit' "$?" 0

# Structural contract of the two READMEs. Each topic is one named check, so a failure says what broke.
readme_contract() {
    python3 - "$ROOT_DIR" "$1" <<'PY2'
from pathlib import Path
import re, subprocess, sys

root, topic = Path(sys.argv[1]), sys.argv[2]
text = {'en': (root / 'README.md').read_text(encoding='utf-8'),
        'es': (root / 'README.es.md').read_text(encoding='utf-8')}
script = (root / 'script' / 'Autostart_Manager.sh').read_text(encoding='utf-8')

def prose(t):
    return re.sub(r'^```[^\n]*\n.*?^```[ \t]*\n', '', t, flags=re.S | re.M)

def sections(t):
    """Return (heading, body) for every H2 outside code fences."""
    parts = re.split(r'(?m)^## +(.+?) *$', prose(t))
    return list(zip(parts[1::2], parts[2::2]))

def body_of(lang, heading):
    found = [b for h, b in sections(text[lang]) if h == heading]
    assert len(found) == 1, f'{lang}: section {heading!r} found {len(found)} times'
    return found[0]

EXPECTED = {
    'en': ['The problem it solves', 'What it does', 'Installation', 'Scriptya', 'Commands',
           'Compatibility', 'Language', 'Contributing', 'License'],
    'es': ['El problema que resuelve', 'Qué hace exactamente', 'Instalación', 'Scriptya', 'Comandos',
           'Compatibilidad', 'Idioma', 'Contribuir', 'Licencia'],
}
COMPAT = {'en': 'Compatibility', 'es': 'Compatibilidad'}
LANGUAGE = {'en': 'Language', 'es': 'Idioma'}

if topic == 'sections':
    for lang, expected in EXPECTED.items():
        actual = [h for h, _ in sections(text[lang])]
        assert actual == expected, f'{lang}: sections differ\nexpected={expected}\nactual={actual}'
        for h, b in sections(text[lang]):
            assert len(b.strip()) >= 100, f'{lang}: section {h!r} is empty or a stub'

elif topic == 'no-distribution':
    for lang, t in text.items():
        m = re.search(r'(?i)\bmint\b|linuxmint|linux-mint', t)
        assert not m, f'{lang}: names a specific distribution: {m.group(0)!r}'

elif topic == 'icon':
    assert (root / 'assets' / 'autostart-manager.png').is_file(), 'assets/autostart-manager.png is missing'
    for lang, t in text.items():
        assert re.match(r'<p align="center">\s*<img src="assets/autostart-manager\.png" width="140" alt="[^"]+">\s*</p>', t), \
            f'{lang}: the opening icon must be assets/autostart-manager.png at width 140'
        imgs = re.findall(r'<img\b[^>]*>', t)
        assert len(imgs) == 7, f'{lang}: expected the icon and six screenshots, found {len(imgs)} images'
        for img in imgs:
            assert re.search(r'\balt="[^"]+"', img), f'{lang}: image without alt text: {img}'

elif topic == 'icon-alternatives':
    for lang in text:
        body = body_of(lang, 'Scriptya')
        for n in range(1, 5):
            assert (root / 'assets' / f'icon{n}.png').is_file(), f'assets/icon{n}.png is missing'
        assert '`icon1.png`' in body and '`icon4.png`' in body and '`assets/`' in body, \
            f'{lang}: the Scriptya section must say that icon1.png to icon4.png in assets/ are alternatives'

elif topic == 'compatibility':
    guard = re.search(r'BASH_VERSINFO\[0\] == (\d+) && BASH_VERSINFO\[1\] < (\d+)', script)
    assert guard, 'the Bash version guard was not found in the script'
    minimum = f'{guard.group(1)}.{guard.group(2)}'
    assert minimum == '4.4', f'script requires Bash {minimum}; the contract says 4.4'
    for lang in text:
        body = body_of(lang, COMPAT[lang])
        rows = dict(re.findall(r'(?m)^\| `([a-z]+)` \| (.*?) \|$', body))
        assert re.match(re.escape(minimum) + r'\b', rows.get('bash', '')), f'{lang}: Bash minimum must be {minimum}'
        assert '3.44' in rows.get('zenity', '') and '4.x' in rows.get('zenity', ''), f'{lang}: Zenity row must name 3.44 and 4.x'
        assert 'Ubuntu 24.04' in body, f'{lang}: tested distribution Ubuntu 24.04 is not stated'

elif topic == 'version':
    version = re.search(r'(?m)^VERSION="([^"]+)"', script).group(1)
    for lang, t in text.items():
        assert f'**Autostart Manager {version}**' in t, f'{lang}: does not name version {version}'

elif topic == 'scriptya':
    for lang in text:
        body = body_of(lang, 'Scriptya')
        assert 'https://github.com/filonux/Scriptya' in body, f'{lang}: Scriptya link is missing'
        for key in ('MENU', 'DESCRIPTION', 'ICON'):
            assert f'`{key}`' in body, f'{lang}: Scriptya header key {key} is not documented'
        assert '`--install`' in body, f'{lang}: the install alternative is not mentioned'

elif topic == 'parity':
    def shape(b):
        return (len(re.findall(r'(?m)^- ', b)), len(re.findall(r'(?m)^\d+\. ', b)), len(re.findall(r'(?m)^\|', b)))
    for (he, be), (hs, bs) in zip(sections(text['en']), sections(text['es'])):
        assert shape(be) == shape(bs), f'{he!r} / {hs!r}: bullets, steps and table rows differ {shape(be)} vs {shape(bs)}'
    pre = [re.split(r'(?m)^## ', prose(t), 1)[0] for t in text.values()]
    assert shape(pre[0]) == shape(pre[1]), f'introductions differ {shape(pre[0])} vs {shape(pre[1])}'

elif topic == 'provisional':
    for lang, t in text.items():
        low = t.lower()
        assert 'until they are stored' not in low and 'until copying' not in low, f'{lang}: provisional screenshot wording'
        assert not re.search(r'(?<!\w)(?:TODO|TBD|PLACEHOLDER)(?!\w)', t), f'{lang}: provisional marker found'

elif topic == 'accuracy':
    assert 'The choice is not saved' in text['en'] and 'La elección no se guarda' in text['es'], 'language persistence claim'
    for lang, t in text.items():
        assert '`crontab -e`' in t, f'{lang}: cron editing must point to `crontab -e`'

elif topic == 'buttons':
    labels = {lang.lower(): raw.split(' ', 1)[1] for lang, raw in re.findall(r"MSG_(ES|EN)\[open_btn\]='((?:[^'\\]|\\.)*)'", script)}
    assert set(labels) == {'en', 'es'}, 'open_btn is not defined in both languages'
    for lang, t in text.items():
        assert f'**{labels[lang]}**' in t, f'{lang}: the open button is not named **{labels[lang]}**'

elif topic == 'cross-links':
    assert '[README.es.md](README.es.md)' in body_of('en', LANGUAGE['en']), 'README.md: Spanish link missing in Language'
    assert '[README.md](README.md)' in body_of('es', LANGUAGE['es']), 'README.es.md: English link missing in Idioma'

elif topic == 'commands':
    help_text = subprocess.run(['bash', str(root / 'script' / 'Autostart_Manager.sh'), '--help'],
                               check=True, capture_output=True, text=True, cwd=root).stdout
    commands = [
        '--help', '--version', '-l', '--toggle-language', '--lang en', '--lang es', '--install',
        '--uninstall', '--uninstall --keep-config', '--uninstall --purge',
    ]
    for lang, t in text.items():
        for c in commands:
            assert f'./script/Autostart_Manager.sh {c}' in t, f'{lang}: missing documented command: {c}'
    for option in ['--help', '--version', '-l|--toggle-language', '--lang es|en', '--install', '--uninstall',
                   '--keep-config', '--purge']:
        assert option in help_text, f'CLI help no longer exposes documented option: {option}'

else:
    raise SystemExit(f'unknown topic {topic}')
PY2
}

readme_contract sections;        check 'README has exactly the nine agreed sections in both languages' "$?" 0
readme_contract no-distribution; check 'README names no specific distribution' "$?" 0
readme_contract icon;            check 'README opens with the project icon at width 140' "$?" 0
readme_contract icon-alternatives; check 'README Scriptya section offers icon1 to icon4 as alternatives' "$?" 0
readme_contract compatibility;   check 'README compatibility states Ubuntu 24.04, Bash 4.4 and Zenity 3.44 or 4.x' "$?" 0
readme_contract version;         check 'README names the script version' "$?" 0
readme_contract scriptya;        check 'README Scriptya section documents the metadata header' "$?" 0
readme_contract parity;          check 'README sections have the same structure in both languages' "$?" 0
readme_contract provisional;     check 'README has no provisional text' "$?" 0
readme_contract accuracy;        check 'README language and cron statements are accurate' "$?" 0
readme_contract buttons;         check 'README names the open button with its real label' "$?" 0
readme_contract cross-links;     check 'README language sections link to each other' "$?" 0
readme_contract commands;        check 'README command reference matches the executable CLI' "$?" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
