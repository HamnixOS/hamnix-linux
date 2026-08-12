#!/usr/bin/env bash
# tests/linux/steam_scroll_why.sh — WHY DOES STEAM NOT SCROLL WHEN EVERYTHING
# BELOW IT DOES?
#
# docs/steam_namespace.md §12.2c proved, in ONE X session, that eight wheel
# notches moved an `xterm` 471 px and Steam's store page 0 of 564400. Below the
# X server everything is measured and works. This file is the harness for the
# three questions that pass named, all of which have to be asked INSIDE a
# running Steam session:
#
#   1. WHAT DOES STEAM ASK THE X SERVER FOR, AND WHAT DOES THE SERVER HAND IT?
#      `tests/linux/x11_record_trace.c` is attached over RECORD before Steam
#      draws anything. It decodes every XISelectEvents (which window, which
#      device, which event bits) AND every event the server DELIVERS, with the
#      recipient's client id -- so "Steam never asked" and "Steam asked, was
#      told, and did nothing" are different lines rather than the same silence.
#      (`XIGetSelectedEvents` cannot answer the first: the server filters it
#      with SameClient(). See that file's header.)
#   2. WHICH WINDOW IS UNDER THE POINTER? `xdotool getmouselocation` and
#      `xwininfo`, out of the namespace's own /usr/bin, so the answer is a
#      window id that can be matched against the trace.
#   3. DOES FIREFOX SCROLL IN THE SAME SESSION? It is in the same image, it is
#      the other browser engine, and it reads the same XI2 valuator. Firefox
#      scrolling while Steam does not points at Steam; Firefox failing too
#      points at something both engines need.
#
# NOTHING IS TYPED AT THE GUEST. Every guest-side action is scheduled by
# rc.boot and announced on the serial console, and the host waits for the
# marker. This is not tidiness: hamsh's console line editor drops typed
# characters (docs/steam_namespace.md §12.3), and in the first pass of this
# very file `cat /n/distro/tmp/rectrace.log` was executed as `cat /n/dist`,
# `spawn debian { /bin/sh /tmp/xlook.sh a }` as `spawn debian { /bin/s`, and a
# hand-typed re-run of the tracer TRUNCATED the log the boot-time one had
# already filled. Pointer, wheel, keys and screendumps all go in over QMP,
# which is reliable, and the console is only ever read.
#
# It boots like `steam_login_drive.sh` -- HAMLINUX_DISTRO_RO=1, a private
# build/image, session scripts appended as a second cpio segment, the VM left
# UP with a QMP socket -- because navigating Steam to a scrollable page needs
# eyes on the framebuffer between clicks.
#
# Usage: steam_scroll_why.sh boot        # blocks until SSW-LOGIN, leaves VM up
#        steam_scroll_why.sh wait <marker> [tries]
#        steam_scroll_why.sh slice <begin> <end>
#        steam_scroll_why.sh reap
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${SSW_WORK:-$HOME/.hamnix-build/steamscrollwhy/run}"
IMG=build/image
QMP="$IMG/qmpssw.sock"
LOG="$WORK/console.log"
mkdir -p "$WORK"

case "${1:-}" in
boot)
    export HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none
    export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
    mkdir -p "$TMPDIR"

    # THE TRACER IS A NAMESPACE BINARY, NOT A HAMNIX ONE. It is compiled on the
    # dev host against the host's libX11/libXtst headers and RUN against the
    # namespace's own libraries -- the same trick scripts/ns_xwayland.sh uses
    # in the other direction. Bookworm is glibc 2.36 and trixie is newer, so
    # the symbol versions are checked here rather than discovered as
    # `version GLIBC_2.38 not found` on a serial console four minutes into a
    # boot.
    TRACE_BIN="$WORK/x11_record_trace"
    echo "[ssw] compiling the RECORD tracer for the namespace"
    cc -O2 -o "$TRACE_BIN" tests/linux/x11_record_trace.c -lX11 -lXtst || {
        echo "FAIL cannot compile the tracer (need libx11-dev libxtst-dev)"; exit 1; }
    BADSYM="$(objdump -T "$TRACE_BIN" | grep -oE 'GLIBC_2\.[0-9]+' |
              sort -uV | awk -F. '$2 > 36')"
    [ -z "$BADSYM" ] || { echo "FAIL the tracer needs $BADSYM; bookworm is 2.36"; exit 1; }

    cat > "$WORK/rc.boot" <<'RC'
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

cp /etc/hamnix-x11session.sh /n/distro/tmp/x11session.sh
cp /etc/x11-record-trace /n/distro/tmp/rectrace
cp /etc/ssw-trace.sh /n/distro/tmp/trace.sh
cp /etc/ssw-look.sh /n/distro/tmp/xlook.sh
cp /etc/ssw-ff.sh /n/distro/tmp/ff.sh

echo '[gui] starting wsyswl on /n/distro/run/wayland-0'
/bin/wsyswl /n/distro/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[gui] launching Steam in the Debian namespace'
spawn debian { /bin/sh /tmp/x11session.sh /usr/local/bin/hamnix-steam }

# THE TRACER GOES IN IMMEDIATELY, and waits for the server itself rather than
# being scheduled by a sleep here: RECORD only ever sees requests made AFTER it
# attaches, so "started too late" is silently the same log as "Steam never
# asked for anything" -- the one answer this must not be able to give by
# accident. Its own first line says how long it waited, and every line it
# prints is stamped.
sleep 5
spawn debian { /bin/sh /tmp/trace.sh }

sleep 200
echo 'SSW-LOGIN'
# The host now has this whole window to navigate Steam to a scrollable page and
# take the wheel measurements, and it leaves the pointer parked over that page.
sleep 480
echo 'SSW-XLOOK-A'
spawn debian { /bin/sh /tmp/xlook.sh a }
sleep 30
cat /n/distro/tmp/xlook.a.txt
echo 'SSW-XLOOK-A-END'

# FIREFOX, IN THE SAME SESSION, ON THE SAME SERVER. Not through
# /etc/de-ns-run: that shim delegates to /usr/local/bin/hamnix-x11session when
# one is installed, and this image HAS one -- which would start a second
# Xwayland on :0 and pull the display out from under Steam. /tmp/ff.sh sets the
# same environment and starts no server at all.
echo 'SSW-FF-LAUNCH'
spawn debian { /bin/sh /tmp/ff.sh }
sleep 240
echo 'SSW-FF-READY'
sleep 420
echo 'SSW-XLOOK-B'
spawn debian { /bin/sh /tmp/xlook.sh b }
sleep 30
cat /n/distro/tmp/xlook.b.txt
echo 'SSW-XLOOK-B-END'
echo 'SSW-DUMP'
cat /n/distro/tmp/rectrace.log
echo 'SSW-DUMP-END'
sleep 3000
RC

    STAGE="$WORK/seg"
    rm -rf "$STAGE"; mkdir -p "$STAGE/etc"
    cp tests/linux/hamnix_x11session.sh "$STAGE/etc/hamnix-x11session.sh"
    cp "$TRACE_BIN"                     "$STAGE/etc/x11-record-trace"

    # THE LOADER, NOT THE BINARY, IS WHAT IS EXECUTED. The Hamnix image has no
    # `chmod`, and nothing here can promise that a `cp` across the namespace
    # boundary kept the x bit -- so the tracer is run as an ARGUMENT to
    # ld-linux, which needs no execute permission on it at all.
    #
    # >> AND NEVER >. The first pass of this file truncated the log with `>`
    # from a second, hand-started tracer, and destroyed the capture of Steam's
    # store window being created. Appending costs nothing and cannot do that.
    cat > "$STAGE/etc/ssw-trace.sh" <<'TR'
#!/bin/sh
LOG=/tmp/rectrace.log
export DISPLAY=:0
i=0
while [ $i -lt 300 ]; do
    xdpyinfo >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
done
if ! xdpyinfo >/dev/null 2>&1; then
    echo "rt: ssw-trace: NO X SERVER on :0 after ${i}s -- NOTHING WAS TRACED" | tee -a "$LOG"
    exit 1
fi
echo "rt: ssw-trace: X server on :0 after ${i}s; attaching" | tee -a "$LOG"
# `rt: ` on every line so the trace can be pulled back out of a serial console
# that Steam is also writing to, and `tee` so it is both live on that console
# and kept in a file for one bulk dump at the end.
exec /lib64/ld-linux-x86-64.so.2 /tmp/rectrace 2>&1 |
    sed -u 's/^/rt: /' | tee -a "$LOG"
TR

    cat > "$STAGE/etc/ssw-look.sh" <<'LK'
#!/bin/sh
# ssw-look.sh <tag> -- where is the pointer, and what is under it?
export DISPLAY=:0
OUT="/tmp/xlook.${1:-now}.txt"
{
    echo "== getmouselocation"
    xdotool getmouselocation --shell 2>&1
    W=$(xdotool getmouselocation --shell 2>/dev/null | sed -n 's/^WINDOW=//p')
    R=$(xwininfo -root 2>/dev/null | sed -n 's/.*Window id: \([0-9a-fx]*\).*/\1/p')
    echo "== root is $R; the window under the pointer and its ancestors"
    n=0
    while [ -n "$W" ] && [ "$W" != "0" ] && [ "$n" -lt 12 ]; do
        n=$((n+1))
        printf -- '-- [%s] window %s  (hex ' "$n" "$W"
        printf '0x%x)\n' "$W" 2>/dev/null || echo '?)'
        xwininfo -id "$W" 2>&1 | sed -n '2,9p'
        xprop -id "$W" WM_CLASS WM_NAME _NET_WM_NAME 2>&1
        P=$(xwininfo -id "$W" -tree 2>/dev/null |
            sed -n 's/^ *Parent window id: \([0-9a-fx]*\).*/\1/p')
        case "$P" in 0x0|"") break ;; esac
        [ "$P" = "$R" ] && { echo "-- its parent is the ROOT window $R"; break; }
        W=$P
    done
    echo "== xlsclients"
    xlsclients -l 2>&1
    echo "== the whole tree"
    xwininfo -root -tree 2>&1
} > "$OUT" 2>&1
echo "ssw-look: wrote $OUT"
LK

    # FIREFOX, WITH THE SAME ENVIRONMENT AND NO SERVER OF ITS OWN.
    # file:///etc/services because it is thousands of lines of plain text in
    # every Debian: a page whose only possible reason to change is that it
    # scrolled. A remote page would put the network in the middle of a
    # measurement about input.
    cat > "$STAGE/etc/ssw-ff.sh" <<'FF'
#!/bin/sh
# NOTHING IS REDIRECTED TO A FILE. The first version of this sent Firefox's
# output to /tmp/ff.log inside the namespace, Firefox never drew a window, and
# the only way to read the reason was a console command -- which is the one
# thing this harness cannot do reliably. Everything goes to the serial console.
export DISPLAY=:0
export MOZ_ENABLE_WAYLAND=0
_u=$(id -u 2>/dev/null || echo 0)
if [ -d "/run/user/$_u" ]; then XDG_RUNTIME_DIR="/run/user/$_u"; else XDG_RUNTIME_DIR=/run; fi
export XDG_RUNTIME_DIR
HOME=/home/live
[ -d "$HOME" ] || HOME=/root
export HOME
echo "ssw-ff: uid=$_u HOME=$HOME XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR DISPLAY=$DISPLAY"
if : > "$HOME/.ssw-probe" 2>/dev/null; then
    echo "ssw-ff: $HOME is writable"; rm -f "$HOME/.ssw-probe"
else
    echo "ssw-ff: WARNING $HOME is NOT writable by uid $_u; Firefox needs a profile directory"
fi
mkdir -p /tmp/ffprof 2>/dev/null
echo "ssw-ff: /usr/bin/firefox is:"
cat /usr/bin/firefox 2>&1 | sed 's/^/ssw-ff:   /'
echo "ssw-ff: starting firefox"
# -profile with a fresh directory, because a profile lock left by an earlier
# run makes Firefox exit with a dialog nobody can click. -no-remote so it
# never tries to hand the URL to an instance that is not there.
/usr/bin/firefox -no-remote -profile /tmp/ffprof --new-window file:///etc/services 2>&1 |
    sed 's/^/ssw-ff: /'
echo "ssw-ff: firefox exited $?"
FF

    ( cd "$STAGE" && find etc -print0 | cpio -0 -o -H newc --quiet ) | gzip \
        > "$WORK/seg.cpio.gz"

    echo "[ssw] staging the initramfs"
    HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }
    cat "$WORK/seg.cpio.gz" >> "$IMG/initramfs.cpio.gz"
    echo "[ssw] appended the session scripts + tracer as a second cpio segment"

    rm -f "$QMP"
    : > "$LOG"
    ( timeout 6000 scripts/hamlinux_vm.sh script \
        -qmp "unix:$QMP,server,nowait" </dev/null > "$LOG" 2>&1 ) &
    echo $! > "$WORK/vm.pid"
    for _ in $(seq 1 150); do [ -S "$QMP" ] && break; sleep 0.2; done
    echo "[ssw] VM up; qmp $QMP, console log $LOG"
    ;;
wait)
    m="${2:?marker}"; n="${3:-300}"
    for _ in $(seq 1 "$n"); do
        grep -aq "$m" "$LOG" && { echo "[ssw] $m"; exit 0; }
        sleep 2
    done
    echo "[ssw] TIMED OUT waiting for $m"; exit 1
    ;;
slice)
    sed -n "/${2:?begin}/,/${3:?end}/p" "$LOG" | tr -d '\r' |
        sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
    ;;
reap)
    python3 tests/linux/qmp_input.py "$QMP" quit 2>/dev/null
    sleep 1
    [ -f "$WORK/vm.pid" ] && kill "$(cat "$WORK/vm.pid")" 2>/dev/null
    sleep 1
    [ -f "$WORK/vm.pid" ] && kill -9 "$(cat "$WORK/vm.pid")" 2>/dev/null
    rm -f "$WORK/vm.pid"
    echo "[ssw] reaped"
    ;;
*)
    sed -n '1,50p' "$0" | sed -n 's/^# //p'
    exit 2
    ;;
esac
