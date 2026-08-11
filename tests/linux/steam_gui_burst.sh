#!/usr/bin/env bash
# tests/linux/steam_gui_burst.sh — screendump the VM repeatedly instead of once.
#
# WHY. Steam's own launcher DOES put a window on this desktop: its console log
# says `Show window` and, four seconds later, `Destroy window` around the
# "Verifying installation..." progress dialog. A single screendump taken at a
# fixed offset misses a four-second window, and missing it is what makes
# "Steam shows nothing" look absolute when it is not.
#
# This boots whatever build/image currently holds -- steam_gui_run.sh has
# already staged the rc and planted the session scripts -- and takes a
# screendump every STEP seconds between FROM and TO, so a short-lived window
# cannot hide between two samples.
#
# Usage: tests/linux/steam_gui_burst.sh [outdir] [from] [to] [step]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

OUTDIR="${1:-build/steamprobe/burst}"
FROM="${2:-50}"
TO="${3:-95}"
STEP="${4:-3}"
SOCK=build/image/mon.sock
mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.ppm "$OUTDIR"/*.png

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }
[ -f build/image/vmlinuz ] || { echo "run steam_gui_run.sh first" >&2; exit 1; }

rm -f "$SOCK"
LIMIT=$((TO + 25))
( sleep "$LIMIT" ) | timeout "$LIMIT" \
    scripts/hamlinux_vm.sh script --timeout $((LIMIT - 5)) >"$OUTDIR/boot.log" 2>&1 &
QEMU=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done

sleep "$FROM"
t="$FROM"
while [ "$t" -le "$TO" ]; do
    printf 'screendump %s\n' "$(realpath -m "$OUTDIR/t$t.ppm")" \
        | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1
    sleep "$STEP"
    t=$((t + STEP))
done
printf 'quit\n' | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1
sleep 2
kill $QEMU 2>/dev/null
wait 2>/dev/null

# Convert, and say how much of each frame is NOT the desktop backdrop, so the
# interesting frames are findable without opening forty of them.
python3 - "$OUTDIR" <<'PY'
import glob, os, struct, sys, zlib, collections
outdir = sys.argv[1]
for ppm in sorted(glob.glob(os.path.join(outdir, '*.ppm')),
                  key=lambda p: int(''.join(c for c in os.path.basename(p) if c.isdigit()))):
    f = open(ppm, 'rb')
    if f.readline().strip() != b'P6':
        continue
    line = f.readline()
    while line.startswith(b'#'):
        line = f.readline()
    w, h = map(int, line.split())
    f.readline()
    data = f.read()
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += data[y*w*3:(y+1)*w*3]
    def chunk(tag, payload):
        c = tag + payload
        return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
           + chunk(b'IEND', b''))
    out = ppm[:-4] + '.png'
    open(out, 'wb').write(png)
    c = collections.Counter(data[i:i+3] for i in range(0, len(data), 3))
    black = c[b'\x00\x00\x00']
    top = c.most_common(1)[0]
    print("%-28s %dx%d  black=%5.1f%%  most-common=%s %5.1f%%"
          % (os.path.basename(out), w, h, 100.0*black/(w*h),
             top[0].hex(), 100.0*top[1]/(w*h)))
    os.remove(ppm)
PY
