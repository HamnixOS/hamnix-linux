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
#   1. WHAT DOES STEAM ASK THE X SERVER FOR? `tests/linux/x11_record_trace.c`
#      is attached to all clients over the RECORD extension before Steam draws
#      anything, and decodes every XISelectEvents: which window, which device,
#      which event bits. (`XIGetSelectedEvents` cannot answer this -- the
#      server filters it with SameClient(), so pointed at another client's
#      window it returns an empty list whether or not that client selected
#      anything. See the header of that .c file.)
#   2. WHICH WINDOW IS UNDER THE POINTER? `xdotool getmouselocation` and
#      `xwininfo -tree`, out of the namespace's own /usr/bin, so the answer is
#      a window id that can be matched against the trace.
#   3. DOES FIREFOX SCROLL IN THE SAME SESSION? It is in the same image, it is
#      the other browser engine, and it reads the same XI2 valuator. Firefox
#      scrolling while Steam does not points at Steam; Firefox failing too
#      points at something both engines need.
#
# It boots like `steam_login_drive.sh` -- HAMLINUX_DISTRO_RO=1, a private
# build/image, session scripts appended as a second cpio segment, the VM left
# UP with a QMP socket and the console on a fifo -- because navigating Steam to
# a scrollable page needs eyes on the framebuffer between clicks.
#
# Usage: steam_scroll_why.sh boot [seconds-to-login]   # leaves the VM up
#        steam_scroll_why.sh <cmd> ...                 # console command
#        steam_scroll_why.sh reap
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${SSW_WORK:-$HOME/.hamnix-build/steamscrollwhy/run}"
IMG=build/image
QMP="$IMG/qmpssw.sock"
FIFO="$WORK/console.in"
LOG="$WORK/console.log"
mkdir -p "$WORK"

case "${1:-}" in
boot)
    WAIT="${2:-360}"
    export HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none
    export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
    mkdir -p "$TMPDIR"

    # THE TRACER IS A NAMESPACE BINARY, NOT A HAMNIX ONE. It is compiled on the
    # dev host against the host's libX11/libXtst headers and RUN against the
    # namespace's own libraries -- the same trick scripts/ns_xwayland.sh uses in
    # the other direction. Bookworm is glibc 2.36 and trixie is newer, so the
    # symbol versions are checked here rather than discovered as
    # `version GLIBC_2.38 not found` on a serial console four minutes into a
    # boot.
    TRACE_SRC=tests/linux/x11_record_trace.c
    TRACE_BIN="$WORK/x11_record_trace"
    echo "[ssw] compiling the RECORD tracer for the namespace"
    cc -O2 -o "$TRACE_BIN" "$TRACE_SRC" -lX11 -lXtst || {
        echo "FAIL cannot compile $TRACE_SRC (need libx11-dev libxtst-dev)"; exit 1; }
    BADSYM="$(objdump -T "$TRACE_BIN" | grep -oE 'GLIBC_2\.[0-9]+' |
              sort -uV | awk -F. '$2 > 36')"
    if [ -n "$BADSYM" ]; then
        echo "FAIL the tracer needs $BADSYM; the namespace is bookworm (2.36)"
        exit 1
    fi

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
cp /etc/hamnix-xdiag.sh /n/distro/tmp/xdiag.sh
cp /etc/steam-look.sh /n/distro/tmp/look.sh
cp /etc/de-ns-run /n/distro/tmp/de-ns-run
cp /etc/x11-record-trace /n/distro/tmp/rectrace
cp /etc/ssw-trace.sh /n/distro/tmp/trace.sh
cp /etc/ssw-look.sh /n/distro/tmp/xlook.sh

echo '[gui] starting wsyswl on /n/distro/run/wayland-0'
/bin/wsyswl /n/distro/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[gui] launching Steam in the Debian namespace'
spawn debian { /bin/sh /tmp/x11session.sh /usr/local/bin/hamnix-steam }

# THE TRACER GOES IN AS SOON AS THERE IS A SERVER TO ATTACH TO, and it waits
# for one itself rather than being scheduled by a sleep here: RECORD only ever
# sees requests made AFTER it attaches, so "started too late" is silently the
# same log as "Steam never asked for anything", which is the one answer this
# must not be able to give by accident. /tmp/trace.sh prints the moment it
# attached, and every line it prints is stamped, so lateness is visible.
sleep 45
echo '[gui] attaching the RECORD tracer'
spawn debian { /bin/sh /tmp/trace.sh }
echo '[gui] rc.boot done -- the console is now interactive'
RC

    STAGE="$WORK/seg"
    rm -rf "$STAGE"; mkdir -p "$STAGE/etc"
    cp tests/linux/hamnix_x11session.sh "$STAGE/etc/hamnix-x11session.sh"
    cp tests/linux/hamnix_xdiag.sh      "$STAGE/etc/hamnix-xdiag.sh"
    cp tests/linux/steam_look.sh        "$STAGE/etc/steam-look.sh"
    cp "$TRACE_BIN"                     "$STAGE/etc/x11-record-trace"

    # THE LOADER, NOT THE BINARY, IS WHAT IS EXECUTED. The Hamnix image has no
    # `chmod`, and nothing here can promise that a `cp` across the namespace
    # boundary preserved the x bit -- so the tracer is run as an ARGUMENT to
    # ld-linux, which needs no execute permission on it at all. A dead
    # `Permission denied` four minutes into a boot is the expensive way to
    # learn that.
    cat > "$STAGE/etc/ssw-trace.sh" <<'TR'
#!/bin/sh
# Attach the RECORD tracer to the X session that hamnix-x11session started.
# It NEVER starts an X server: a second server on :0 would take the display
# out from under Steam, and a tracer that changes what it measures is worse
# than no tracer.
LOG=/tmp/rectrace.log
export DISPLAY=:0
i=0
while [ $i -lt 240 ]; do
    xdpyinfo >/dev/null 2>&1 && break
    i=$((i+1)); sleep 1
done
if ! xdpyinfo >/dev/null 2>&1; then
    echo "ssw-trace: NO X SERVER on :0 after ${i}s -- nothing was traced" > "$LOG"
    exit 1
fi
echo "ssw-trace: X server on :0 after ${i}s; starting the tracer" > "$LOG"
exec /lib64/ld-linux-x86-64.so.2 /tmp/rectrace >> "$LOG" 2>&1
TR

    # WHICH WINDOW IS UNDER THE POINTER, asked with the namespace's own tools.
    # Its answer goes to a FILE and is catted over the serial console on
    # demand: hamsh's console line editor drops characters under load
    # (docs/steam_namespace.md §12.3), so the guest is asked as few questions
    # as possible and each one is one short line.
    cat > "$STAGE/etc/ssw-look.sh" <<'LK'
#!/bin/sh
# ssw-look.sh [tag] -- where is the pointer, and what is under it?
export DISPLAY=:0
OUT="/tmp/xlook.${1:-now}.txt"
{
    echo "== getmouselocation"
    xdotool getmouselocation --shell 2>&1
    echo "== the window under the pointer, and its ancestors"
    W=$(xdotool getmouselocation --shell 2>/dev/null | sed -n 's/^WINDOW=//p')
    while [ -n "$W" ] && [ "$W" != "0" ]; do
        echo "-- window $W"
        xwininfo -id "$W" -stats 2>&1 | sed -n '2,12p'
        xprop -id "$W" WM_CLASS WM_NAME _NET_WM_NAME 2>&1
        W=$(xwininfo -id "$W" -tree 2>/dev/null |
            sed -n 's/^  Parent window id: \([0-9a-fx]*\).*/\1/p')
        case "$W" in 0x0|"") break ;; esac
        # The root window is its own end: stop at the child of root.
        R=$(xwininfo -root 2>/dev/null | sed -n 's/.*Window id: \([0-9a-fx]*\).*/\1/p')
        [ "$W" = "$R" ] && { echo "-- (parent is the root window $R)"; break; }
    done
    echo "== xlsclients"
    xlsclients -l 2>&1
    echo "== the whole tree"
    xwininfo -root -tree 2>&1
} > "$OUT" 2>&1
echo "ssw-look: wrote $OUT"
LK

    ( cd "$STAGE" && find etc -print0 | cpio -0 -o -H newc --quiet ) | gzip \
        > "$WORK/seg.cpio.gz"

    echo "[ssw] staging the initramfs"
    HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }
    cat "$WORK/seg.cpio.gz" >> "$IMG/initramfs.cpio.gz"
    echo "[ssw] appended the session scripts + tracer as a second cpio segment"

    rm -f "$QMP" "$FIFO"
    mkfifo "$FIFO"
    : > "$LOG"
    sleep infinity > "$FIFO" &
    echo $! > "$WORK/holder.pid"
    ( timeout 6000 scripts/hamlinux_vm.sh script \
        -qmp "unix:$QMP,server,nowait" < "$FIFO" > "$LOG" 2>&1 ) &
    echo $! > "$WORK/vm.pid"
    for _ in $(seq 1 150); do [ -S "$QMP" ] && break; sleep 0.2; done
    echo "[ssw] VM up; qmp $QMP, console log $LOG"
    echo "[ssw] waiting ${WAIT}s for the Steam login window"
    sleep "$WAIT"
    ;;
reap)
    python3 tests/linux/qmp_input.py "$QMP" quit 2>/dev/null
    sleep 1
    [ -f "$WORK/vm.pid" ] && kill "$(cat "$WORK/vm.pid")" 2>/dev/null
    [ -f "$WORK/holder.pid" ] && kill "$(cat "$WORK/holder.pid")" 2>/dev/null
    sleep 1
    [ -f "$WORK/vm.pid" ] && kill -9 "$(cat "$WORK/vm.pid")" 2>/dev/null
    rm -f "$WORK/vm.pid" "$WORK/holder.pid"
    echo "[ssw] reaped"
    ;;
*)
    printf '%s\n' "$*" > "$FIFO"
    ;;
esac
