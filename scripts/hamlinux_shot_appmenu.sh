#!/usr/bin/env bash
# scripts/hamlinux_shot_appmenu.sh — photograph the Applications menu, OPEN,
# on a booted machine.
#
# scripts/hamlinux_shot.sh photographs the desktop as it boots. The thing the
# machine's owner asked to see by eye is the MENU, which only exists after
# somebody clicks the Applications button -- so this boots the image, puts a
# REAL POINTER on that button over QMP `input-send-event` (the same hand
# tests/linux/de_appmenu_realboot.sh uses, on QEMU's virtio-tablet-pci), and
# takes the screendump three seconds later. The screendump is the SCANNED-OUT
# surface, so it is evidence about what a person can see rather than about
# what the compositor believes it wrote.
#
# Usage: scripts/hamlinux_shot_appmenu.sh <image-dir> <out.png> [settle-secs]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
. tests/linux/reap.sh
reap_on_exit

IMGDIR="${1:?usage: hamlinux_shot_appmenu.sh <image-dir> <out.png> [settle]}"
OUT="${2:?usage: hamlinux_shot_appmenu.sh <image-dir> <out.png> [settle]}"
SETTLE="${3:-40}"
PPM="${OUT%.png}.ppm"
LOG="${OUT%.png}.boot.log"
QMP="$IMGDIR/appmenu-qmp.sock"
SCREEN_W=1280; SCREEN_H=800
APPBTN_X=40; APPBTN_Y=13          # the Applications button on the top bar

mkdir -p "$(dirname "$OUT")"
rm -f "$QMP" "$PPM"
RUNTIME=$((SETTLE + 60))
( sleep "$RUNTIME" ) | HAMLINUX_VNC=none HAMLINUX_DISTRO_RO=1 \
    HAMLINUX_IMAGE_DIR="$IMGDIR" scripts/hamlinux_vm.sh script \
    --timeout "$RUNTIME" -qmp "unix:$QMP,server=on,wait=off" >"$LOG" 2>&1 &
VM=$!; reap_add "$VM"

for _ in $(seq 1 200); do [ -S "$QMP" ] && break; sleep 0.2; done
[ -S "$QMP" ] || { echo "no QMP socket" >&2; tail -20 "$LOG" >&2; exit 1; }

# Wait for the panel to say it has built its menu, rather than sleeping a
# guess -- a screenshot taken before the panel maps its bar photographs the
# absence of the thing under test and looks like a defect.
w=0
while ! grep -aq 'appmenu entries:' "$LOG"; do
    sleep 1; w=$((w+1)); [ "$w" -gt "$SETTLE" ] && break
    kill -0 "$VM" 2>/dev/null || break
done
grep -a 'appmenu entries:\|appmenu-missing' "$LOG" | tail -5
sleep 8                            # let the desktop finish its first frames

Q() { python3 tests/linux/qmp_input.py "$QMP" "$@" >>"$LOG.qmp" 2>&1; }
Q screendump "$(realpath -m "${OUT%.png}-before.ppm")"
echo "[shot-appmenu] clicking Applications at ($APPBTN_X,$APPBTN_Y)"
Q click "$APPBTN_X" "$APPBTN_Y" "$SCREEN_W" "$SCREEN_H"
sleep 4
Q screendump "$(realpath -m "$PPM")"
# AND ONE WITH A CATEGORY OPEN. The top level is seven category rows; the
# applications are in the fly-outs, which is where "the menu lists only real
# programs" is actually visible. HOVER opens one (no click -- a click on a
# category row is not what opens it), so this is a move and a wait.
CATX="${CAT_X:-60}"; CATY="${CAT_Y:-58}"
echo "[shot-appmenu] hovering the first category at ($CATX,$CATY)"
Q move "$CATX" "$CATY" "$SCREEN_W" "$SCREEN_H"
sleep 3
Q screendump "$(realpath -m "${OUT%.png}-flyout.ppm")"
sleep 1
kill "$VM" 2>/dev/null; wait "$VM" 2>/dev/null

[ -s "$PPM" ] || { echo "no screendump" >&2; tail -20 "$LOG" >&2; exit 1; }

topng() {
python3 - "$1" "$2" <<'PY'
import sys, zlib, struct
f = open(sys.argv[1], 'rb')
assert f.readline().strip() == b'P6'
line = f.readline()
while line.startswith(b'#'):
    line = f.readline()
w, h = map(int, line.split())
f.readline()
data = f.read()
raw = b''.join(b'\x00' + data[y*w*3:(y+1)*w*3] for y in range(h))
def chunk(t, d):
    c = t + d
    return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw, 9))
       + chunk(b'IEND', b''))
open(sys.argv[2], 'wb').write(png)
print("%s  %dx%d  %d bytes" % (sys.argv[2], w, h, len(png)))
PY
}
topng "$PPM" "$OUT"
for extra in before flyout; do
    [ -s "${OUT%.png}-$extra.ppm" ] && topng "${OUT%.png}-$extra.ppm" "${OUT%.png}-$extra.png"
done
rm -f "$PPM" "${OUT%.png}-before.ppm" "${OUT%.png}-flyout.ppm" "$QMP"
