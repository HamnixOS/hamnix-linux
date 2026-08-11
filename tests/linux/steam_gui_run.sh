#!/usr/bin/env bash
# tests/linux/steam_gui_run.sh — put a 32-bit graphical Debian program on the
# Hamnix desktop, and screendump what is actually scanned out.
#
# The window path for a Steam-class application is four hops and every one of
# them is somebody else's code:
#
#   32-bit X11 client -> Xwayland -> wsyswl (user/wsyswl.ad, the Adder Wayland
#   server) -> the wsys v2 blit surface -> wsysd -> /dev/fb -> scanout
#
# Xwayland runs INSIDE the Debian namespace and wsyswl runs OUTSIDE it, so the
# two have to meet on a socket both can name. They do: wsyswl is told to put
# its socket at /n/distro/run/wayland-0, which the namespace -- whose root IS
# that tree -- sees as /run/wayland-0. That is the whole trick, and it is why
# nothing had to be bound across the boundary.
#
# Usage: tests/linux/steam_gui_run.sh <ns-command> [out.png] [seconds]
#   e.g. tests/linux/steam_gui_run.sh /usr/local/bin/hamnix-gl out.png 60
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

NSCMD="${1:?usage: steam_gui_run.sh <ns-command> [out.png] [seconds]}"
OUT="${2:-build/steamprobe/gui.png}"
WAIT="${3:-70}"
DIAGAT="${4:-$((WAIT - 40))}"
WORK="$(dirname "$OUT")"; mkdir -p "$WORK"
PPM="${OUT%.png}.ppm"
LOG="${OUT%.png}.boot.log"
SOCK=build/image/mon.sock
IMG=build/image

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }

# The session script goes into the image the same way the probe does: with
# debugfs, because rebuilding a 2 GB namespace to change 1.7 KB is absurd.
# debugfs `rm` only unlinks, so the fsck afterwards is not optional.
echo "[gui] planting the session scripts in the namespace image"
# THE RM AND THE WRITE MUST BE SEPARATE debugfs RUNS, with an fsck between.
# Doing both in one session leaves the new directory entry carrying the OLD
# inode's type: the file came out mode 0140755 (a symlink) with size 0, and
# the only symptom was `hamsh: command not found` on a path that plainly
# existed. Verify what landed afterwards, not merely the name -- the
# zero-length version passed a name check happily.
#
# CHECK THE TYPE, NOT A SIZE THRESHOLD. The original guard was `size > 100`,
# which is a proxy for "not the zero-length symlink" and it misfires the moment
# a legitimately small file is planted: an 81-byte env file was rejected as
# "did not land" when it had landed perfectly. Ask for the thing that was
# actually wrong -- the inode type -- and require only that the size matches
# the file that was written.
plant() {   # plant <host-file> <path-in-namespace>
    /sbin/debugfs -w -R "rm $2" "$IMG/distro.ext4" >/dev/null 2>&1
    /sbin/e2fsck -fy "$IMG/distro.ext4" >/dev/null 2>&1
    /sbin/debugfs -w "$IMG/distro.ext4" >/dev/null 2>&1 <<EOF
write $1 $2
sif $2 mode 0100755
EOF
    /sbin/e2fsck -fy "$IMG/distro.ext4" >/dev/null 2>&1
    st=$(/sbin/debugfs -R "stat $2" "$IMG/distro.ext4" 2>/dev/null)
    sz=$(printf '%s\n' "$st" | sed -n 's/.*Size: \([0-9]*\).*/\1/p' | head -1)
    want=$(stat -c %s "$1")
    printf '%s\n' "$st" | grep -q 'Type: regular' \
        || { echo "$2 did not land as a regular file" >&2
             printf '%s\n' "$st" | head -3 >&2; exit 1; }
    [ "${sz:-0}" = "$want" ] \
        || { echo "$2 did not land (size=${sz:-0}, expected $want)" >&2; exit 1; }
    echo "[gui]   $2 ($sz bytes)"
}
plant tests/linux/hamnix_x11session.sh /usr/local/bin/hamnix-x11session
plant tests/linux/hamnix_xdiag.sh       /usr/local/bin/hamnix-xdiag

# WHICH EXPERIMENT. See the header of hamnix_x11session.sh for why this is a
# planted FILE and not an exported variable: an rc's environment does not
# survive `spawn debian { ... }`, so a knob passed that way would silently run
# the default and the log would describe an experiment that never happened.
WM="${HAMNIX_X11_WM:-matchbox}"
XTRACE="${HAMNIX_X11_XTRACE:-0}"
cat > "$WORK/session.env" <<ENV
# planted by tests/linux/steam_gui_run.sh
HAMNIX_X11_WM=$WM
HAMNIX_X11_XTRACE=$XTRACE
ENV
plant "$WORK/session.env" /usr/local/etc/hamnix-x11session.env
echo "[gui] experiment: window manager=$WM  xtrace=$XTRACE"

# xtrace is not in the image's package set and adding it to
# scripts/hamlinux_distro.sh means a 2 GB rebuild to gain 96 KB. Fetch the
# BOOKWORM binary (1.4.0-1+b1, Depends: libc6 >= 2.17 -- trixie's 1.4.0-1.1
# wants 2.38 and will not run in there) and plant it as a tarball. Nothing is
# installed on the host; the deb is unpacked into build/ and never executed.
if [ "$XTRACE" = 1 ]; then
    BUNDLE=build/xtrace/xtrace-bundle.tar.gz
    if [ ! -s "$BUNDLE" ]; then
        mkdir -p build/xtrace/x
        curl -sfL -o build/xtrace/xtrace.deb \
          'http://deb.debian.org/debian/pool/main/x/xtrace/xtrace_1.4.0-1%2bb1_amd64.deb' \
          || { echo "could not fetch xtrace" >&2; exit 1; }
        dpkg-deb -x build/xtrace/xtrace.deb build/xtrace/x
        ( cd build/xtrace/x && tar czf ../xtrace-bundle.tar.gz usr/bin/xtrace usr/share/xtrace )
    fi
    plant "$BUNDLE" /usr/local/lib/xtrace-bundle.tar.gz
fi

cat > "$WORK/rc.boot" <<RC
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
# See etc/rc.boot.linux: without these, bash process substitution -- which
# Steam's runtime setup.sh uses -- fails with "/dev/fd/63: No such file".
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
# POSIX shared memory; Chromium (which is Steam's UI) cannot start without it.
mkdir /dev/shm
bind '#t' /dev/shm

ifconfig eth0 10.0.2.15 netmask 255.255.255.0
ifconfig gw 10.0.2.2
ifconfig dns 10.0.2.3
# Loopback: Steam's own IPC binds 127.0.0.1, and nothing else brings lo up.
HAMNIX_IFACE='lo'
export HAMNIX_IFACE
ifconfig lo 127.0.0.1 netmask 255.0.0.0
HAMNIX_IFACE='eth0'
export HAMNIX_IFACE

source '/etc/rc.d/rc.5'
sleep 3

bind '#distro' /n/distro
debian = ns clean {
    bind '#distro' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#s' /srv
    bind '#/' /n
}

# The Wayland server's socket is placed INSIDE the Debian tree, so a client
# whose root is that tree finds it at the ordinary /run/wayland-0.
echo '[gui] starting wsyswl on /n/distro/run/wayland-0'
/bin/wsyswl /n/distro/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[gui] launching $NSCMD in the Debian namespace'
spawn debian { $NSCMD }
sleep $DIAGAT
echo '[gui] --- x diagnostics'
enter debian { /usr/local/bin/hamnix-xdiag }
sleep 900
RC

echo "[gui] staging an image with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

rm -f "$SOCK" "$PPM"
echo "[gui] booting; screendump at ${WAIT}s"
( sleep $((WAIT + 25)) ) | timeout $((WAIT + 20)) \
    scripts/hamlinux_vm.sh script --timeout $((WAIT + 15)) > "$LOG" 2>&1 &
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
echo "--- guest console (wsyswl / namespace lines) ---"
grep -aiE 'wsyswl|\[gui\]|xwayland|steam|glx|vk|error|fail' "$LOG" | tail -40
