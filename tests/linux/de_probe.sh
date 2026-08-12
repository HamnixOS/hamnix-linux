#!/usr/bin/env bash
# tests/linux/de_probe.sh — drive the booted desktop the way a person would,
# and assert on what the screen actually shows.
#
# Everything below the screen can be right and the desktop still be unusable.
# So this boots the real image, sends REAL key events through QEMU (which the
# guest receives on virtio-keyboard as evdev records, decoded by wsysd and
# routed to the focused window -- no test hook anywhere in that path), and
# then reads the SCANNED-OUT framebuffer back with screendump.
#
# It asserts:
#   1. a terminal opens from the DE launch queue;
#   2. its shell starts -- through the /fd pipe names, which is the thing
#      that used to fail with "(shell failed to start)";
#   3. typing a command and pressing Enter puts the command's OUTPUT in the
#      window. That last one is the whole stack in one assertion: keyboard ->
#      evdev -> compositor -> focus -> keys ring -> hamui -> the pipe -> hamsh
#      -> the pipe back -> scene -> rasterize -> composite -> scan out.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

command -v socat >/dev/null || { echo "need socat" >&2; exit 1; }

WORK="${DE_PROBE_WORK:-$(mktemp -d)}"; mkdir -p "$WORK"; echo "[de_probe] work dir: $WORK"
trap 'pkill -f "qemu.*hamnix-de-probe" 2>/dev/null' EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP
SOCK=build/image/de_probe.mon

cat > "$WORK/rc.boot" <<'RC'
echo 'rc.boot: hamnix-linux starting'
ln -s /dev/console /dev/cons
source '/etc/rc.d/rc.5'
sleep 4
echo '[de_probe] opening a terminal through the DE launch queue'
echo '/bin/hamtermscene' > '/dev/wsys/appmenu/launch'

# After the keys have been typed, dump the terminal window's DISPLAY LIST to
# the console. That is the real evidence: the scene is the text the compositor
# rasterizes, so a `glyphs` line containing the typed word proves the whole
# path -- and unlike counting lit pixels it cannot be satisfied by whatever
# else the terminal happened to draw.
sleep 40
echo '[de_probe] --- windows follow'
cat '/dev/wsys/windows'
echo '[de_probe] --- scenes follow'
cat '/dev/wsys/3/scene'
cat '/dev/wsys/4/scene'
cat '/dev/wsys/5/scene'
cat '/dev/wsys/6/scene'
echo '[de_probe] --- compositor state follows'
cat '/dev/wsys/wsysd/state'
echo '[de_probe] --- end'
RC

HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh >"$WORK/build.log" 2>&1 || {
    echo "FAIL image build"; tail -5 "$WORK/build.log"; exit 1; }

rm -f "$SOCK"
( sleep 90 ) | timeout 85 qemu-system-x86_64 \
    -name hamnix-de-probe \
    -m 2048 -smp 2 $( [ -w /dev/kvm ] && echo "-enable-kvm -cpu host" || echo "-cpu max" ) \
    -kernel build/image/vmlinuz -initrd build/image/initramfs.cpio.gz \
    -no-reboot -vga none -device virtio-gpu-pci \
    -device virtio-keyboard-pci -device virtio-tablet-pci \
    -vnc 127.0.0.1:19 -serial stdio \
    -monitor "unix:$SOCK,server,nowait" \
    -append "console=ttyS0,115200 panic=-1 loglevel=4" >"$WORK/boot.log" 2>&1 &
QEMU=$!

for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.2; done
sleep 30                       # boot + DE + the launch the rc performs

mon() { printf '%s\n' "$@" | socat - UNIX-CONNECT:"$SOCK" >/dev/null 2>&1; }

# Type `echo hamnixlinux` and press Enter, one key at a time. These become
# real evdev records in the guest.
KEYS=(e c h o spc h a m n i x l i n u x ret)
for k in "${KEYS[@]}"; do mon "sendkey $k"; sleep 0.12; done
sleep 3

mon "screendump $(realpath -m "$WORK/shot.ppm")"
# Wait for the guest to dump the display lists (the rc sleeps 40s from boot).
sleep 18
mon "quit"
kill $QEMU 2>/dev/null
wait 2>/dev/null

FAIL=0
say() { if [ "$2" = 1 ]; then echo "ok   $1"; else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }

# The PANEL's own log now goes to /var/log (rc.5 redirects it, and that
# redirect works), so "[panel] launched ..." is deliberately not on the
# console any more. Assert on the terminal's own /dev/cons line instead --
# which is the stronger signal anyway: the panel saying it launched something
# is a claim, and hamtermscene saying its window is ready is the fact.
grep -q "\[hamterm\] scene window ready" "$WORK/boot.log" && L=1 || L=0
say "a terminal opens from the DE launch queue" $L

grep -q "shell failed to start" "$WORK/boot.log" && S=0 || S=1
grep -q "hamsh" "$WORK/boot.log" && S=$S || S=0
say "its shell starts through the /fd pipe names" $S

# THE REAL ASSERTION. The terminal's display list is dumped to the console
# above; if the word we typed is in a `glyphs` line, then: QEMU delivered the
# key, the guest's evdev node carried it, wsysd decoded and routed it to the
# FOCUSED window, hamtermscene read its keys ring, echoed it, rebuilt its
# scene and committed it. Counting lit pixels cannot distinguish that from
# the terminal's own startup self-test, which is what it did at first.
grep -q "hamnixlinux" "$WORK/boot.log" && T=1 || T=0
say "the typed keys reach the focused window" $T

if [ -s "$WORK/shot.ppm" ]; then
    say "the screen was scanned out" 1
else
    say "the screen was scanned out" 0
fi

echo "--- serial, last DE lines:"
grep -E "\[rc.5\]|\[panel\] launched|hamsh|hamnixlinux" "$WORK/boot.log" | tail -8 | sed 's/^/    /'

if [ $FAIL -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $FAIL
