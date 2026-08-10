#!/usr/bin/env bash
# scripts/hamlinux_shot.sh — boot the image and take a screenshot of what the
# desktop actually looks like.
#
# The QEMU monitor's screendump captures the SCANNED-OUT surface, not our
# mapping, so it is the only evidence that separates "the compositor wrote the
# right pixels" from "the user can see them" -- a distinction this port has
# already been caught by once (every ioctl returning 0 while the display stayed
# black).
#
# Usage: scripts/hamlinux_shot.sh [out.png] [seconds-to-wait]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT="${1:-build/image/screen.png}"
WAIT="${2:-25}"
PPM="${OUT%.png}.ppm"
LOG="${OUT%.png}.boot.log"
SOCK=build/image/mon.sock

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }
[ -f build/image/vmlinuz ] || { echo "run scripts/hamlinux_image.sh first" >&2; exit 1; }

rm -f "$SOCK" "$PPM"
( sleep $((WAIT + 20)) ) | timeout $((WAIT + 15)) \
    scripts/hamlinux_vm.sh script --timeout $((WAIT + 10)) >"$LOG" 2>&1 &
QEMU=$!

# Wait for the monitor socket rather than sleeping a guess.
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
sleep "$WAIT"

printf 'screendump %s\nquit\n' "$(realpath -m "$PPM")" \
    | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1
sleep 2
kill $QEMU 2>/dev/null
wait 2>/dev/null

[ -s "$PPM" ] || { echo "no screendump; boot log tail:" >&2; tail -20 "$LOG" >&2; exit 1; }

python3 - "$PPM" "$OUT" <<'PY'
import sys, zlib, struct
f = open(sys.argv[1], 'rb')
assert f.readline().strip() == b'P6'
line = f.readline()
while line.startswith(b'#'):
    line = f.readline()
w, h = map(int, line.split())
f.readline()
data = f.read()
raw = bytearray()
for y in range(h):
    raw.append(0)
    raw += data[y * w * 3:(y + 1) * w * 3]
def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
       + chunk(b'IEND', b''))
open(sys.argv[2], 'wb').write(png)
print(f"{sys.argv[2]}  {w}x{h}")
PY
rm -f "$PPM"
