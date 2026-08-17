#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/xsnarf_ondevice.sh — the clipboard bridge on a REAL BOOT, with a
# REAL foreign X client and a REAL mouse.
#
# tests/linux/xsnarf_bridge.sh proves the protocol offscreen against Xvfb and
# xclip on the build host. This one proves the thing that is only true on
# device: that the X server inside a distribution namespace is reachable from
# OUTSIDE it by name, with nothing bound.
#
#   the namespace                     out here (root, the Hamnix side)
#   ------------------------------    ---------------------------------------
#   Xvfb :0                           /bin/xsnarfd /n/debian/tmp/.X11-unix/X0
#     socket /tmp/.X11-unix/X0   <--- the SAME INODE, by its other name
#   xterm, xdotool                    /dev/snarf, over the /srv/snarf segment
#                                     that /srv is NOT carried in to reach
#
# THE MEASUREMENT IS A MOUSE. Not "the bridge logged something": a triple-click
# in a real xterm makes xterm own PRIMARY, and the assertion is that
# `cat /dev/snarf.primary` on the Hamnix side then prints the line that was on
# that xterm's screen. Back the other way, `echo ... > /dev/snarf.primary` and
# a MIDDLE-CLICK in the xterm makes xterm ask the bridge for the bytes and feed
# them to the shell it is running, which writes them to a file inside the
# namespace that this side then reads. Both halves are the ordinary X idiom,
# performed by a Debian binary that has never heard of any of this.
#
# WHY Xvfb INSIDE THE NAMESPACE AND NOT Xwayland. /usr/local/bin/hamnix-x is
# already baked into the Debian medium and starts exactly that (it is what
# user/xbridge.ad blits), so this arm needs no compositor, no wsyswl and no
# desktop -- three things that can fail in the middle of a measurement that is
# not about them. The bridge cannot tell the difference: what it connects to is
# an X server on a unix socket at a path. tests/linux/alpine_gui_run.sh is the
# gate that the Xwayland-under-wsyswl chain comes up.
#
# NOTHING IS PLANTED WITH debugfs. The scripts go in as a SECOND CPIO SEGMENT
# (docs/steam_namespace.md §11) and rc.boot copies them into the namespace's
# /tmp at run time, where HAMLINUX_DISTRO_RO=1 puts the write in a throwaway
# overlay. The shared distro media are never written.
#
# Usage: tests/linux/xsnarf_ondevice.sh [seconds-to-wait]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

WAIT="${1:-120}"
OUT="${XSNARF_TEST_OUT:-build/xsnarf}"
mkdir -p "$OUT/cpio/etc"
LOG="$OUT/ondevice.log"
BASE="$OUT/initramfs.base.cpio.gz"

[ -f build/image/vmlinuz ] || { echo "[xsn-dev] no build/image/vmlinuz; run scripts/hamlinux_image.sh"; exit 1; }
[ -e build/image/distro.ext4 ] || { echo "[xsn-dev] no build/image/distro.ext4"; exit 1; }
if [ ! -f "$BASE" ]; then
    cp build/image/initramfs.cpio.gz "$BASE" || exit 1
    echo "[xsn-dev] kept a pristine initramfs at $BASE"
fi

# ---------------------------------------------------------------- the guest
# Runs INSIDE the Debian namespace: an X server, a window manager, and an
# xterm running a shell that prints a line and then waits to read one.
cat > "$OUT/cpio/etc/xsn_inner.sh" <<'INNER'
#!/bin/sh
exec >/tmp/xsn_inner.log 2>&1
set -x
mkdir -p /tmp/.X11-unix
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
Xvfb :0 -screen 0 800x600x24 -nolisten tcp &
i=0
while [ $i -lt 40 ]; do
    DISPLAY=:0 xdpyinfo >/dev/null 2>&1 && break
    i=$((i+1)); sleep 0.5
done
export DISPLAY=:0
xdpyinfo | head -3
matchbox-window-manager -use_titlebar no &
sleep 1
cat > /tmp/xterm_body.sh <<'EOS'
#!/bin/sh
# FORTY IDENTICAL LINES, not one. matchbox MAXIMISES the window, so the
# geometry asked for above is not where the text is -- the first run
# triple-clicked at (80,55), landed on a blank line four rows down, and pulled
# the ONE BYTE that a blank line's selection is. Which proved the mechanism
# and measured nothing. A click anywhere in the top half of the screen now
# lands on the marker.
i=0
while [ $i -lt 40 ]; do echo COPY-ME-FROM-XTERM-9f3a; i=$((i+1)); done
read x
echo "PASTED:[$x]" > /tmp/paste.out
sleep 900
EOS
chmod +x /tmp/xterm_body.sh
# -fa/-fs: this medium has fonts-dejavu-core and no xfonts-base, so the
# default bitmap font does not exist and xterm would die naming it.
xterm -fa Monospace -fs 12 -geometry 60x12+40+40 -e /tmp/xterm_body.sh &
sleep 4
XW=$(xdotool search --class xterm | head -1)
echo "xterm window $XW"
xdotool getwindowgeometry "$XW"
echo INNER-READY
sleep 900
INNER

# Runs INSIDE the namespace, once per direction. A triple-click selects the
# line (xterm takes PRIMARY); a middle-click pastes it (xterm asks the owner).
cat > "$OUT/cpio/etc/xsn_sel.sh" <<'SEL'
#!/bin/sh
export DISPLAY=:0
case "$1" in
copy)  xdotool mousemove 200 100 click --repeat 3 --delay 150 1 ;;
paste) xdotool mousemove 200 110 click 2 ;;
esac
echo "xsn_sel $1 rc=$?"
SEL

# ---------------------------------------------------------------- the boot
cat > "$OUT/cpio/etc/rc.boot" <<'RC'
echo 'rc.boot: the clipboard bridge on device'
ln -s /dev/console /dev/cons
ln -s /proc/self/fd /dev/fd
mkdir /dev/shm
bind '#t' /dev/shm

bind '#distro/debian' /n/debian
# NO `bind '#s' /srv' in this description, deliberately: the namespace does
# NOT get the clipboard segment, and the bridge still works. That absence is
# the point -- what crosses the boundary is the X socket's NAME, out here.
debian = ns clean {
    bind '#distro/debian' /
    bind '#c' /dev
    bind '#p' /proc
    bind '#/' /n
}

echo '[xsn] --- the bridge starts BEFORE any X server exists'
/bin/xsnarfd /n/debian/tmp/.X11-unix/X0 debian > /var/log/xsnarfd-debian.log &
sleep 4
echo '[xsn] bridge log with no X server yet:'
cat /var/log/xsnarfd-debian.log

cp /etc/xsn_inner.sh /n/debian/tmp/xsn_inner.sh
cp /etc/xsn_sel.sh /n/debian/tmp/xsn_sel.sh
echo '[xsn] starting an X server and an xterm INSIDE the namespace'
spawn debian { /bin/sh /tmp/xsn_inner.sh }
sleep 30
echo '[xsn] X sockets in the namespace, seen from OUT HERE:'
ls -l /n/debian/tmp/.X11-unix
echo '[xsn] bridge log after the X server came up:'
cat /var/log/xsnarfd-debian.log

echo '[xsn] --- X -> HAMNIX: a triple-click in the xterm'
enter debian { /bin/sh /tmp/xsn_sel.sh copy }
sleep 4
echo '[xsn] X-TO-HAMNIX-RESULT: (hamnix cat /dev/snarf.primary)'
cat /dev/snarf.primary
echo '[xsn] (end)'

echo '[xsn] --- HAMNIX -> X: copy out here, middle-click in there'
echo PASTE-ME-FROM-HAMNIX-9f3a > /dev/snarf.primary
sleep 3
enter debian { /bin/sh /tmp/xsn_sel.sh paste }
sleep 4
echo '[xsn] HAMNIX-TO-X-RESULT: (what the xterm shell read)'
cat /n/debian/tmp/paste.out
echo '[xsn] (end)'

echo '[xsn] --- and the CLIPBOARD is a second, independent selection'
echo CLIP-FROM-HAMNIX-9f3a > /dev/snarf
sleep 3
echo '[xsn] PRIMARY-STILL-RESULT: (after a CLIPBOARD copy)'
cat /dev/snarf.primary
echo '[xsn] (end)'

echo '[xsn] the segment the bridge and the shell share:'
ls -l /srv
echo '[xsn] --- the bridge log'
cat /var/log/xsnarfd-debian.log
echo '[xsn] --- the namespace-side log'
cat /n/debian/tmp/xsn_inner.log
echo '[xsn] DONE'
sleep 600
RC

echo "[xsn-dev] appending the rc + the two namespace scripts as a second cpio segment ..."
cp "$BASE" build/image/initramfs.cpio.gz || exit 1
( cd "$OUT/cpio" && find etc -print0 | cpio -o -H newc --null 2>/dev/null | gzip ) \
    >> build/image/initramfs.cpio.gz || exit 1

echo "[xsn-dev] booting (up to ${WAIT}s) ..."
# HAMLINUX_DISTRO_RO=1: the distro media are attached snapshot=on, so nothing
# the guest writes survives and any number of VMs share one image. VNC off --
# a fixed port makes two gates kill each other. TMPDIR on /home because QEMU
# puts the snapshot overlay there and /tmp on this host is RAM.
export TMPDIR="${TMPDIR_XSN:-$(pwd)/$OUT/tmp}"
mkdir -p "$TMPDIR"
( sleep "$((WAIT + 15))" ) | timeout "$((WAIT + 10))" \
    env HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none \
    scripts/hamlinux_vm.sh script --timeout "$WAIT" >"$LOG" 2>&1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }
# Everything printed between a marker and the next '[xsn] (end)', with hamsh's
# unprivileged-spawn notice filtered out. The markers carry no '/': they used
# to be the command itself ("hamnix cat /dev/snarf.primary:"), and sed took the
# slashes as address delimiters, so the one arm whose marker had a path in it
# reported EMPTY while the log plainly held the answer.
between() {
    sed -n "/$1/,/\[xsn\] (end)/p" "$LOG" | tr -d '\r' \
        | grep -v '^\[xsn\]' | grep -v '^rfork: ' | sed '/^$/d'
}
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi; }
has() { if grep -qaF "$2" "$LOG"; then ok "$1"; else bad "$1: not in the log: $2"; fi; }

echo
echo "[xsn-dev] assertions"
has "the rc reached the end"                    "[xsn] DONE"
has "the bridge waited for an X server that did not exist yet" \
                                                "no X server at that socket yet"
has "the X socket inside the namespace is reachable from OUT HERE" \
                                                "connected: root window"
chk "X -> HAMNIX: the xterm line is in /dev/snarf.primary" \
    "COPY-ME-FROM-XTERM-9f3a" "$(between 'X-TO-HAMNIX-RESULT')"
chk "HAMNIX -> X: the xterm shell read what was copied out here" \
    "PASTED:[PASTE-ME-FROM-HAMNIX-9f3a]" "$(between 'HAMNIX-TO-X-RESULT')"
chk "the CLIPBOARD copy did not disturb PRIMARY" \
    "PASTE-ME-FROM-HAMNIX-9f3a" "$(between 'PRIMARY-STILL-RESULT')"
has "the bridge took the X selection on the Hamnix copy" \
                                                "Hamnix -> X: owning PRIMARY"
has "the bridge pulled the X selection on the X copy" \
                                                "X -> Hamnix:"

echo
echo "[xsn-dev] SUMMARY passes=$PASS fails=$FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "[xsn-dev] --- guest console (last 60 lines)"
    tail -60 "$LOG"
    echo "[xsn-dev] RESULT: FAIL"; exit 1
fi
echo "[xsn-dev] RESULT: PASS"
