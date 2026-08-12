#!/usr/bin/env bash
# tests/linux/alpine_gui_run.sh — put a GUI program from the ALPINE namespace
# on the Hamnix desktop, and screendump what is actually scanned out.
#
# This is tests/linux/steam_gui_run.sh's question asked of a different
# distribution, and the point is what does NOT change between them:
#
#   X client -> Xwayland -> wsyswl (user/wsyswl.ad) -> the wsys v2 blit surface
#            -> wsysd -> /dev/fb -> scanout
#
# Xwayland runs INSIDE the namespace and wsyswl runs OUTSIDE it; they meet on a
# socket both can name. wsyswl is told to put its socket at
# /n/alpine/run/wayland-0, which the namespace -- whose root IS that tree --
# sees as /run/wayland-0. Nothing is bound across the boundary; what crosses is
# a name. Exactly as for Debian, and with none of Debian's files.
#
# Nothing is planted with debugfs here either: scripts/hamlinux_alpine.sh bakes
# /usr/local/bin/hamnix-x11session into the image at build time.
#
# Usage: tests/linux/alpine_gui_run.sh [out.png] [seconds] [ns-command...]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# REAP WHAT YOU START. This gate had no trap at all: everything it launched in
# the background survived any exit that was not the happy one -- an assertion
# that bailed early, a `timeout`, a ^C. tests/linux/reap.sh keeps a file-backed
# registry of this run's own children and kills them on every path out.
. tests/linux/reap.sh
reap_on_exit

# A fixed VNC port means two gates cannot run at once: the second dies with
# "Failed to find an available port" before the guest is even started, and the
# failure looks nothing like a port clash in the test output. Nothing here
# needs VNC -- the screendump comes off the QEMU monitor socket.
export HAMLINUX_VNC="${HAMLINUX_VNC:-none}"

OUT="${1:-build/alpinegui/alpine.png}"
WAIT="${2:-70}"
DIAGAT="${HAMLINUX_DIAGAT:-45}"
shift 2 2>/dev/null || true
NSCMD="${*:-/usr/local/bin/hamnix-x11session xeyes -geometry 640x480+80+80}"
WORK="$(dirname "$OUT")"; mkdir -p "$WORK"
PPM="${OUT%.png}.ppm"
LOG="${OUT%.png}.boot.log"
SOCK=build/image/mon.sock
IMG=build/image

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }
[ -f "$IMG/alpine.ext4" ] || { echo "no alpine image; run scripts/hamlinux_alpine.sh" >&2; exit 1; }

cat > "$WORK/rc.boot" <<RC
echo 'rc.boot: alpine GUI'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
mkdir /dev/shm
bind '#t' /dev/shm

ifconfig eth0 10.0.2.15 netmask 255.255.255.0
ifconfig gw 10.0.2.2
ifconfig dns 10.0.2.3

source '/etc/rc.d/rc.5'
sleep 3

bind '#distro/alpine' /n/alpine
alpine = ns clean {
    bind '#distro/alpine' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}

# The Wayland server's socket goes INSIDE the Alpine tree, so a client whose
# root is that tree finds it at the ordinary /run/wayland-0.
echo '[agui] starting wsyswl on /n/alpine/run/wayland-0'
/bin/wsyswl /n/alpine/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[agui] alpine release, for the record:'
enter alpine { /bin/cat /etc/alpine-release }
echo '[agui] launching $NSCMD in the Alpine namespace'
spawn alpine { $NSCMD }
# DIAGNOSTICS, READ FROM THE HAMNIX SIDE. A spawned program's stderr reaches
# this console only if it is still attached; the X server's own complaints go
# to a FILE inside the namespace, and /n/alpine is that tree seen from out
# here. Reading it is the difference between "no window appeared" and knowing
# why -- the first version of this test printed a clean log and a blank
# desktop, which is exactly the success-shaped silence NORTH_STAR.md names.
sleep $DIAGAT
echo '[agui] --- session log (from /n/alpine/tmp/session.log)'
cat /n/alpine/tmp/session.log
echo '[agui] --- Xwayland log (from /n/alpine/tmp/xwayland.log)'
cat /n/alpine/tmp/xwayland.log
echo '[agui] --- the X client output (/n/alpine/tmp/client.log)'
cat /n/alpine/tmp/client.log
echo '[agui] --- X sockets in the namespace'
ls -l /n/alpine/tmp/.X11-unix
echo '[agui] --- end diagnostics'
sleep 900
RC

echo "[agui] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

rm -f "$SOCK" "$PPM"
echo "[agui] booting; screendump at ${WAIT}s"
( sleep $((WAIT + 25)) ) | timeout $((WAIT + 20)) \
    scripts/hamlinux_vm.sh script --timeout $((WAIT + 15)) > "$LOG" 2>&1 &
reap_add $!
QEMU=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
sleep "$WAIT"
printf 'screendump %s\nquit\n' "$(realpath -m "$PPM")" | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1
sleep 2
kill $QEMU 2>/dev/null; wait 2>/dev/null

[ -s "$PPM" ] || { echo "no screendump; log tail:"; tail -25 "$LOG"; exit 1; }
python3 - "$PPM" "$OUT" <<'PY'
import sys, zlib, struct
f = open(sys.argv[1], 'rb')
assert f.readline().strip() == b'P6'
line = f.readline()
while line.startswith(b'#'): line = f.readline()
w, h = map(int, line.split()); f.readline()
data = f.read(); raw = bytearray()
for y in range(h):
    raw.append(0); raw += data[y*w*3:(y+1)*w*3]
def chunk(t, p):
    c = t + p
    return struct.pack('>I', len(p)) + c + struct.pack('>I', zlib.crc32(c))
open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(bytes(raw), 6)) + chunk(b'IEND', b''))
print(f"{sys.argv[2]}  {w}x{h}")
PY
rm -f "$PPM"
echo "--- guest console (namespace / wsyswl / X lines) ---"
grep -aiE 'wsyswl|\[agui\]|xwayland|x11session|alpine|error|fail' "$LOG" | tail -40
