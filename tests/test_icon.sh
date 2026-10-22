#!/bin/bash
set -uE -o pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ICON="$ROOT_DIR/assets/autostart-manager.png"

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

# Scriptya reads MENU, DESCRIPTION and ICON from the comment lines that directly follow the shebang.
SCRIPT_FILE="$ROOT_DIR/script/Autostart_Manager.sh"
check 'script carries the Scriptya metadata right after the shebang' "$(sed -n '2,$p' "$SCRIPT_FILE" | sed -nE '/^# [A-Z]+: /!q;s/^# ([A-Z]+): .*/\1/p' | tr '\n' ' ')" 'MENU DESCRIPTION ICON '
meta_icon=$(sed -n 's/^# ICON: //p' "$SCRIPT_FILE" | head -n1)
check 'Scriptya ICON metadata points to the launcher icon' "$(cmp -s "$ROOT_DIR/script/$meta_icon" "$ICON" && echo 1 || echo 0)" 1

if ! python3 -c 'import PIL' 2>/dev/null; then
    if [[ "${REQUIRE_PILLOW:-0}" == 1 ]]; then
        printf 'FAIL: Pillow is required\n1 tests: 0 passed, 1 failed\n'; exit 1
    fi
    printf 'SKIP: Pillow (python3-pil) is not installed.\n'; exit 0
fi

check 'custom icon exists' "$(test -f "$ICON" && echo 1 || echo 0)" 1
check 'custom icon mode is 644' "$(stat -c '%a' "$ICON")" 644

python3 - "$ICON" <<'PY'
from PIL import Image
from pathlib import Path
import sys
icon = Path(sys.argv[1])
im = Image.open(icon)
assert im.size == (1024, 1024), im.size
assert im.mode == "RGBA", im.mode
alpha = im.getchannel("A")
amin, amax = alpha.getextrema()
assert amin == 0 and amax == 255, (amin, amax)
for corner in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
    assert alpha.getpixel(corner) == 0, corner
bbox = alpha.getbbox()
assert bbox is not None
left, top, right, bottom = bbox
# The icon must fill the canvas: at least 95% of each dimension is content.
assert right - left >= 972 and bottom - top >= 972, bbox
# The icon must contain real (near-)opaque content, not a translucent full-canvas wash.
opaque = sum(alpha.histogram()[250:])
assert opaque > 100000, opaque
for size in (16, 24, 32, 48, 64, 128, 512):
    small = im.resize((size, size), Image.Resampling.LANCZOS)
    small_alpha = small.getchannel("A")
    assert small_alpha.getbbox() is not None, size
    assert sum(small_alpha.histogram()[250:]) > size, (size, sum(small_alpha.histogram()[250:]))
PY
check 'custom icon is a 1024x1024 RGBA PNG with transparency that fills the canvas' "$?" 0

# icon1 to icon4 are alternatives the user can pick instead of the main icon (Scriptya offers the header icon
# and lets the user browse to another image). icon3 is an original kept as supplied, at 512 px.
for spec in icon1:1024 icon2:1024 icon3:512 icon4:1024; do
    name=${spec%%:*} size=${spec##*:}
    icon="$ROOT_DIR/assets/$name.png"
    check "alternative icon exists: $name" "$(test -f "$icon" && echo 1 || echo 0)" 1
    check "alternative icon mode is 644: $name" "$(stat -c '%a' "$icon")" 644
    python3 - "$icon" "$size" <<'PY2'
from PIL import Image
from pathlib import Path
import sys
icon = Path(sys.argv[1])
size = int(sys.argv[2])
im = Image.open(icon)
assert im.size == (size, size), im.size
assert im.mode == "RGBA", im.mode
alpha = im.getchannel("A")
amin, amax = alpha.getextrema()
assert amin == 0 and amax == 255, (amin, amax)
for corner in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)):
    assert alpha.getpixel(corner) == 0, corner
left, top, right, bottom = alpha.getbbox()
# The artwork covers at least 80% of the canvas in each dimension (a shield is narrower than a gear).
assert right - left >= size * 0.8 and bottom - top >= size * 0.8, (left, top, right, bottom)
assert sum(alpha.histogram()[128:]) > size * size * 0.25
for small_size in (16, 24, 32, 48, 64, 128, size):
    small = im.resize((small_size, small_size), Image.Resampling.LANCZOS)
    assert small.getchannel("A").getbbox() is not None, small_size
PY2
    check "alternative icon quality: $name" "$?" 0
done

# The icon embedded in the script (installed by --install) is a small rendition of the launcher icon.
EMB=$(mktemp -d); trap 'rm -rf "$EMB"' EXIT
mkdir -p "$EMB/bin" "$EMB/home"
printf '#!/bin/bash\nexit 0\n' > "$EMB/bin/zenity"; chmod +x "$EMB/bin/zenity"
PATH="$EMB/bin:$PATH" HOME="$EMB/home" AUTOSTART_MANAGER_TEST=1 \
    bash -c 'source "$1"; embedded_icon_b64' _ "$ROOT_DIR/script/Autostart_Manager.sh" | base64 -d > "$EMB/embedded.png"
check 'embedded icon decodes to a PNG file' "$(head -c 8 "$EMB/embedded.png" | od -An -tx1 | tr -d ' \n')" 89504e470d0a1a0a
check 'embedded icon stays under 10 KB' "$(( $(stat -c '%s' "$EMB/embedded.png") < 10240 ))" 1
python3 - "$EMB/embedded.png" <<'PY4'
from PIL import Image
import sys
im = Image.open(sys.argv[1])
assert im.size == (128, 128), im.size
assert im.mode == "P" and "transparency" in im.info, (im.mode, im.info.keys())
alpha = im.convert("RGBA").getchannel("A")
assert alpha.getpixel((0, 0)) == 0 and alpha.getpixel((127, 127)) == 0
left, top, right, bottom = alpha.getbbox()
assert right - left >= 124 and bottom - top >= 124, alpha.getbbox()
PY4
check 'embedded icon is a 128x128 PNG8 with transparency that fills the canvas' "$?" 0
python3 - "$ICON" "$EMB/embedded.png" <<'PY5'
from PIL import Image, ImageChops, ImageStat
import sys
full = Image.open(sys.argv[1]).convert("RGBA").resize((128, 128), Image.Resampling.LANCZOS)
mean = ImageStat.Stat(ImageChops.difference(full, Image.open(sys.argv[2]).convert("RGBA"))).mean
assert max(mean) < 6, mean
PY5
check 'embedded icon is the launcher icon scaled down' "$?" 0

printf '\n%d tests: %d passed, %d failed\n' "$((pass+fail))" "$pass" "$fail"
(( fail == 0 ))
