#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because it boots a machine through `scripts/hamlinux_vm.sh`.
#
# tests/linux/steam_login_drive.sh — HOW FAR DOES STEAM GET PAST ITS LOGIN
# SCREEN?
#
# THE QUESTION. `docs/steam_namespace.md` §6.2a ends at "the Sign in to Steam
# window is on the framebuffer". That is where every measurement in this tree
# stops, and "the login window renders" had quietly started standing in for
# "Steam works". A window that renders and cannot be typed into is a
# screenshot, not an application.
#
# WHAT THIS DOES DIFFERENTLY FROM steam_gui_ro.sh. That one boots, waits, and
# screendumps. This one boots the same session and then DRIVES it: the VM is
# left running with a QMP socket, and `tests/linux/qmp_input.py` puts pointer
# and key events on QEMU's own `virtio-tablet-pci` / `virtio-keyboard-pci`.
# Those arrive in the guest as /dev/input/eventN records, which is the only
# input `wsysd` has in a VM. Nothing here writes a wsys ring by hand -- the
# same rule `tests/linux/de_mouse_chrome.sh` sets for the DE chrome, applied
# to a real X11 application three servers further down:
#
#   QEMU virtio-tablet/keyboard -> /dev/input/eventN -> wsysd -> /dev/wsys/<wid>/
#     -> wsyswl (wl_pointer/wl_keyboard) -> Xwayland -> jwm -> Steam's CEF
#
# It writes nothing outside its own directory: HAMLINUX_DISTRO_RO=1 attaches
# the shared namespace media snapshot=on, the session scripts ride in on a
# second cpio segment, and the VM is ended with `quit` on its own monitor.
# See docs/steam_namespace.md §11 for why each of those is not optional.
#
# Usage: steam_login_drive.sh boot [seconds-to-login]   # leaves the VM up
#        steam_login_drive.sh <cmd> ...                 # console command
#        steam_login_drive.sh reap
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${SLD_WORK:-$HOME/.hamnix-build/steamdrive/run}"
IMG=build/image
MON="$IMG/mon.sock"
QMP="$IMG/qmp.sock"
FIFO="$WORK/console.in"
LOG="$WORK/console.log"
mkdir -p "$WORK"

case "${1:-}" in
boot)
    WAIT="${2:-360}"
    export HAMLINUX_DISTRO_RO=1 HAMLINUX_VNC=none
    export TMPDIR="${TMPDIR:-$HOME/.hamnix-build/tmp}"
    mkdir -p "$TMPDIR"

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
# A SECOND X CLIENT INTO THE SAME SESSION. This rc.boot builds the namespace by
# hand rather than sourcing /etc/rc.distros, so the shim that /etc/rc.distros
# normally copies into each tree is not in there -- and without it the only way
# to start another X program in this session is x11session.sh, which begins by
# removing /tmp/.X0-lock and would pull the running server out from under Steam.
# de-ns-run reuses an X server that is already on :0 ("an X server is already on
# :0; reusing it"), which is exactly what a comparison client needs: Firefox
# scrolling or not scrolling in the SAME session as Steam is what separates
# "our stack" from "Steam".
cp /etc/de-ns-run /n/distro/tmp/de-ns-run

echo '[gui] starting wsyswl on /n/distro/run/wayland-0'
/bin/wsyswl /n/distro/run/wayland-0 > /var/log/wsyswl.log &
sleep 2

echo '[gui] launching Steam in the Debian namespace'
spawn debian { /bin/sh /tmp/x11session.sh /usr/local/bin/hamnix-steam }
echo '[gui] rc.boot done -- the console is now interactive'
RC

    echo "[drive] staging the initramfs"
    HAMLINUX_RC="$WORK/rc.boot" scripts/hamlinux_image.sh > "$WORK/build.log" 2>&1 || {
        echo "FAIL image build"; tail -20 "$WORK/build.log"; exit 1; }

    STAGE="$WORK/seg"
    rm -rf "$STAGE"; mkdir -p "$STAGE/etc"
    cp tests/linux/hamnix_x11session.sh "$STAGE/etc/hamnix-x11session.sh"
    cp tests/linux/hamnix_xdiag.sh      "$STAGE/etc/hamnix-xdiag.sh"
    cp tests/linux/steam_look.sh        "$STAGE/etc/steam-look.sh"
    ( cd "$STAGE" && find etc -print0 | cpio -0 -o -H newc --quiet ) | gzip \
        >> "$IMG/initramfs.cpio.gz"
    echo "[drive] appended the session scripts as a second cpio segment"

    rm -f "$MON" "$QMP" "$FIFO"
    mkfifo "$FIFO"
    : > "$LOG"
    # The fifo is held open by a writer that never closes, so the guest's
    # console shell does not see EOF between commands.
    sleep infinity > "$FIFO" &
    echo $! > "$WORK/holder.pid"
    ( timeout 3000 scripts/hamlinux_vm.sh script \
        -qmp "unix:$QMP,server,nowait" < "$FIFO" > "$LOG" 2>&1 ) &
    echo $! > "$WORK/vm.pid"
    for _ in $(seq 1 100); do [ -S "$QMP" ] && break; sleep 0.2; done
    echo "[drive] VM up; qmp $QMP, console log $LOG"
    echo "[drive] waiting ${WAIT}s for the Steam login window"
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
    echo "[drive] reaped"
    ;;
*)
    # Anything else is a line for the guest console shell.
    printf '%s\n' "$*" > "$FIFO"
    ;;
esac
