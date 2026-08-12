#!/usr/bin/env bash
# tests/linux/steam_gui_ro.sh — steam_gui_run.sh's measurement, without writing
# to the shared namespace image.
#
# WHY THIS EXISTS BESIDE steam_gui_run.sh. That script plants its session
# scripts with `debugfs -w` into `build/image/distro.ext4`, which is a 12 GiB
# file SHARED between every worktree in this tree -- `build/` is symlinked back
# to the one checkout and is not isolated by a git worktree
# (docs/steam_namespace.md §11). Two agents doing that at once destroy each
# other's runs silently, and did.
#
# So this one writes nothing outside its own directory:
#
#   * the distro media is attached with HAMLINUX_DISTRO_RO=1 -- snapshot=on
#     plus file.locking=off -- so any number of VMs share one image and
#     nothing the guest writes survives;
#   * the session scripts go in as a SECOND CPIO SEGMENT appended to the
#     initramfs (the loader unpacks concatenated gzipped `newc` archives in
#     order), and rc.boot copies them into the namespace's /tmp at run time,
#     where the throwaway overlay catches the write;
#   * TMPDIR is on /home, because QEMU puts the snapshot overlay there and
#     /tmp on this host is a 16 GB tmpfs, i.e. the owner's RAM;
#   * the VM is ended with `quit` on its own monitor socket. Never `pkill` a
#     QEMU by pattern here: every VM in this tree has the same argv.
#
# Usage: tests/linux/steam_gui_ro.sh <ns-command> [out.png] [seconds]
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"
# REAP WHAT YOU START. This gate had no trap at all: everything it launched in
# the background survived any exit that was not the happy one -- an assertion
# that bailed early, a `timeout`, a ^C. tests/linux/reap.sh keeps a file-backed
# registry of this run's own children and kills them on every path out.
. tests/linux/reap.sh
reap_on_exit

NSCMD="${1:?usage: steam_gui_ro.sh <ns-command> [out.png] [seconds]}"
OUT="${2:-build/steamro/gui.png}"
WAIT="${3:-90}"
DIAGAT="${4:-$((WAIT - 45))}"
WORK="$(dirname "$OUT")"; mkdir -p "$WORK"
PPM="${OUT%.png}.ppm"
LOG="${OUT%.png}.boot.log"
IMG=build/image
SOCK="$IMG/mon.sock"

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }
export HAMLINUX_DISTRO_RO=1
export HAMLINUX_VNC=none
export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
mkdir -p "$TMPDIR"

cat > "$WORK/rc.boot" <<RC
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
ln -s /proc/self/fd/0 /dev/stdin
ln -s /proc/self/fd/1 /dev/stdout
ln -s /proc/self/fd/2 /dev/stderr
mkdir /dev/shm
bind '#t' /dev/shm

ifconfig eth0 10.0.2.15 netmask 255.255.255.0
ifconfig gw 10.0.2.2
ifconfig dns 10.0.2.3
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

# THE SESSION SCRIPTS, COPIED IN RATHER THAN PLANTED. They rode in on the
# initramfs's second cpio segment; the copy lands in the namespace's /tmp,
# which HAMLINUX_DISTRO_RO=1 puts in a throwaway overlay. The image has no
# chmod, so they are invoked as \`/bin/sh /tmp/x.sh\`.
cp /etc/hamnix-x11session.sh /n/distro/tmp/x11session.sh
cp /etc/hamnix-xdiag.sh /n/distro/tmp/xdiag.sh

echo '[gui] starting wsyswl on /n/distro/run/wayland-0'
/bin/wsyswl /n/distro/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[gui] launching $NSCMD in the Debian namespace'
spawn debian { $NSCMD }
sleep $DIAGAT
echo '[gui] --- x diagnostics'
enter debian { /bin/sh /tmp/xdiag.sh }
sleep 900
RC

echo "[gui] staging the initramfs with that rc"
HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

# The second cpio segment: /etc/hamnix-x11session.sh and /etc/hamnix-xdiag.sh.
STAGE="$WORK/seg"
rm -rf "$STAGE"; mkdir -p "$STAGE/etc"
cp tests/linux/hamnix_x11session.sh "$STAGE/etc/hamnix-x11session.sh"
cp tests/linux/hamnix_xdiag.sh      "$STAGE/etc/hamnix-xdiag.sh"
( cd "$STAGE" && find etc -print0 | cpio -0 -o -H newc --quiet ) | gzip \
    >> "$IMG/initramfs.cpio.gz"
echo "[gui] appended the session scripts as a second cpio segment"

rm -f "$SOCK" "$PPM"
echo "[gui] booting; screendump at ${WAIT}s"
( sleep $((WAIT + 25)) ) | timeout $((WAIT + 20)) \
    scripts/hamlinux_vm.sh script --timeout $((WAIT + 15)) > "$LOG" 2>&1 &
reap_add $!
QEMU=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
sleep "$WAIT"
if [ -S "$SOCK" ]; then
    printf 'screendump %s\n' "$(readlink -f "$PPM")" | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
    sleep 3
    printf 'quit\n' | socat - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1
fi
wait "$QEMU" 2>/dev/null
if [ -s "$PPM" ]; then
    python3 - "$PPM" "$OUT" <<'PY'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
if not d.startswith(b'P6'):
    sys.exit("not a P6 ppm")
i, f = 2, []
while len(f) < 3:
    while i < len(d) and d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    j = i
    while j < len(d) and not d[j:j+1].isspace(): j += 1
    f.append(int(d[i:j])); i = j
i += 1
W, H = f[0], f[1]
px = d[i:i + W*H*3]
rows = bytearray()
for y in range(H):
    rows.append(0)
    rows += px[y*W*3:(y+1)*W*3]
def chunk(t, p):
    c = t + p
    return struct.pack('>I', len(p)) + c + struct.pack('>I', zlib.crc32(c))
open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
print("[gui] wrote %s (%dx%d)" % (sys.argv[2], W, H))
PY
else
    echo "[gui] NO SCREENDUMP -- the VM never reached the monitor"
fi
echo "[gui] boot log: $LOG"
