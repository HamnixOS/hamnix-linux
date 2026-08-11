#!/bin/sh
# hamnix-x11session — an X11 session inside the Debian namespace, on top of
# the Hamnix Wayland server.
#
# wsyswl (Adder, outside this namespace) put its socket at /run/wayland-0 in
# THIS tree. Xwayland is an X server that is itself a Wayland client, so it
# connects there and every X11 program in here -- including Steam, whose UI is
# X11-only CEF -- gets a screen without anything knowing about wsys.
#
#   -shm     the pure-pixman screen. The default glamor path wants GL on the
#            Wayland side and there is none.
#   -noreset the server would otherwise reset when its last client exits and
#            take the Wayland surface down with it.
set -u
export XDG_RUNTIME_DIR=/run
export WAYLAND_DISPLAY=wayland-0
# $HOME, and why "/" is not acceptable. hamsh hands an entering program the
# placeholder "/" when it has not resolved a passwd entry, and "/" IS a
# directory, so a plain `[ -d "$HOME" ]` guard accepts it -- and Steam then
# installs a 2.5 GB client into /.steam at the root of the namespace. Reject
# the placeholder explicitly.
case "${HOME:-}" in
    ""|"/") HOME=/home/live ;;
esac
[ -d "$HOME" ] || mkdir -p "$HOME" 2>/dev/null || HOME=/root
export HOME

echo "hamnix-x11session: wayland socket $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" >&2
ls -l "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" >&2 || echo "hamnix-x11session: NO WAYLAND SOCKET" >&2

# THE NAMESPACE'S /tmp IS ON DISK AND SURVIVES REBOOTS. enter_root deliberately
# does not carry the Hamnix tmpfs across (a Debian program's /tmp must be the
# subtree's own -- see user/linux-syscalls.c), so /tmp here is the ext4's, and
# an X server killed by a power cut leaves its lock behind for ever after. The
# second boot then gets
#   Fatal server error: Server is already active for display 0
# and Xwayland never starts.
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null

# HOW BIG IS THE X SCREEN? A ROOTFUL Xwayland does not take its size from the
# wl_output: bookworm's 22.1.9 happens to, and 24.1.6 comes up 640x480 no
# matter what the compositor advertises (measured -- tests/linux/x11_geom_probe.sh).
# So the X screen size of this whole session would otherwise be a property of
# the Xwayland version rather than of the display. wsyswl publishes the real
# geometry as a file beside its socket, which is the one name that crosses the
# namespace boundary; read it and tell Xwayland.
#
# -geometry ONLY EXISTS FROM XWAYLAND 23.1. Bookworm ships 22.1.9, which does
# not know the option and dies with `Unrecognized option: -geometry` -- and
# 22.1.9 is exactly the version that does not need it, because rootful
# Xwayland took its size from the wl_output until 23.1 stopped doing that. So
# ASK the server what it accepts rather than assuming either behaviour.
SW=""; SH=""; GEOMOPT=""
if [ -r "$XDG_RUNTIME_DIR/hamnix-screen" ]; then
    read -r SW SH < "$XDG_RUNTIME_DIR/hamnix-screen" || true
fi
case "${SW:-}:${SH:-}" in
    [1-9]*:[1-9]*)
        if Xwayland -help 2>&1 | grep -q -- '-geometry'; then
            GEOMOPT="-geometry ${SW}x${SH}"
            echo "hamnix-x11session: screen ${SW}x${SH} from $XDG_RUNTIME_DIR/hamnix-screen, passed as -geometry" >&2
        else
            echo "hamnix-x11session: screen ${SW}x${SH} from $XDG_RUNTIME_DIR/hamnix-screen; this Xwayland has no -geometry, so it must take the size from the wl_output" >&2
        fi ;;
    *)
        # Not fatal -- an older wsyswl does not publish it -- but say so,
        # because the alternative is an X screen whose size nobody chose.
        echo "hamnix-x11session: WARNING no $XDG_RUNTIME_DIR/hamnix-screen; the X screen size is Xwayland's own default, not the display's" >&2 ;;
esac

# shellcheck disable=SC2086
Xwayland -shm -noreset $GEOMOPT :0 >/tmp/xwayland.log 2>&1 &
XWPID=$!
# WAIT FOR THE SERVER, NOT FOR THE SOCKET. The stale socket above outlived the
# server that made it, so `[ -S /tmp/.X11-unix/X0 ]` reported an X server that
# was not running -- and this script then said "Xwayland up" and exec'd Steam
# into a display that did not exist. xdpyinfo actually connects.
i=0
while [ $i -lt 60 ]; do
    DISPLAY=:0 xdpyinfo >/dev/null 2>&1 && break
    kill -0 "$XWPID" 2>/dev/null || break
    i=$((i+1)); sleep 0.25
done
if DISPLAY=:0 xdpyinfo >/dev/null 2>&1; then
    echo "hamnix-x11session: Xwayland up ($(DISPLAY=:0 xdpyinfo | grep 'dimensions:'))" >&2
else
    echo "hamnix-x11session: Xwayland FAILED TO START" >&2
    tail -8 /tmp/xwayland.log >&2
    exit 1
fi

export DISPLAY=:0

# THE WINDOW MANAGER, AND WHY THE DEFAULT IS NOW `none`.
#
# matchbox was the reason every Steam window read `IsUnMapped`. Measured, in
# one boot each, with a `xterm` in the session as a control and `xev -root` as
# the X server's own witness:
#
#   matchbox running : root has ONE child, matchbox's own 5x5 check window.
#   no WM at all     : root has ten children and
#                      0x1a00015 "Sign in to Steam" ("steamwebhelper" "steam")
#                      700x440+290+180   Map State: IsViewable
#                      -- and xev -root recorded 23 CreateNotify and 2
#                      MapNotify, one for the control xterm and one for that.
#
# So Steam DOES issue MapWindow, and matchbox -- a single-window handheld WM
# that takes over every MapRequest -- is what kept the result off the screen.
# The other eight windows stay unmapped in BOTH arms and are supposed to:
# they are Chromium's clipboard window, the launcher's 1x1 IPC windows and
# steamwebhelper's 10x10 hidden helpers.
#
# HAMNIX_X11_WM names one by name (`matchbox`, or any command on PATH) for
# anyone who wants the old behaviour back; `none` is the default because an
# override-redirect-heavy application does not need a window manager and this
# one is actively harmful.
WM="${HAMNIX_X11_WM:-none}"
case "$WM" in
    none)
        echo "hamnix-x11session: no window manager (HAMNIX_X11_WM=none) -- a MapWindow takes effect directly" >&2 ;;
    matchbox)
        matchbox-window-manager -use_titlebar no >/tmp/mbwm.log 2>&1 &
        echo "hamnix-x11session: matchbox started -- NOTE it unmaps Steam's toplevel" >&2
        sleep 1 ;;
    *)
        "$WM" >/tmp/wm.log 2>&1 &
        echo "hamnix-x11session: window manager $WM started" >&2
        sleep 1 ;;
esac

# A SESSION BUS. Steam's steam-runtime-launcher-service exits on startup
# without one ("Can't find session bus"), and retries until it disables
# itself. dbus-launch comes from dbus-x11, which is not pulled in by `dbus`.
# A SYSTEM BUS as well: Steam's CEF asks for /run/dbus/system_bus_socket and
# logs a connect failure per subprocess without one.
#
# WAITING FOR THE SOCKET IS NOT WAITING FOR THE SERVER -- AGAIN. The namespace's
# /run is on the ext4 and survives reboots (the same trap as /tmp/.X0-lock,
# docs/steam_namespace.md §10), so the FIRST boot's dbus-daemon leaves
# /run/dbus/system_bus_socket behind for ever. On every later boot the old
# `[ ! -S ... ]` guard saw a socket, skipped starting the daemon, and every
# CEF process in Steam then logged
#     Failed to connect to socket /run/dbus/system_bus_socket: Connection refused
# -- measured, build/steamprobe/steamA.boot.log. A socket file is not a server.
# Ask the bus whether it is there, and clear the corpse if it is not.
#
# HOW TO ASK. dbus-daemon --system writes its pid to /run/dbus/pid, so a live
# bus is a socket AND a process that still exists; that needs no tools beyond
# the shell, which is why the check is written this way. (`dbus-send` IS in
# the image after all -- an earlier note here said it was not, and a ping check
# built on that belief answered "no bus" unconditionally. It is used below
# only as a second opinion, never as the check.)
#
# AND THE BUS DOES COME UP. Measured: with the corpse cleared and the daemon
# started in the FOREGROUND of a background job, /run/dbus/pid names a live
# process and `dbus-send --system ... GetId` returns a real reply. So "the
# namespace has no system D-Bus" is retired; what is left are the SERVICES on
# it that Debian has no daemon for -- CEF still logs
# `org.freedesktop.UPower ... was not provided by any .service files`.
bus_alive() {
    [ -S /run/dbus/system_bus_socket ] || return 1
    [ -r /run/dbus/pid ] || return 1
    read -r bpid < /run/dbus/pid 2>/dev/null || return 1
    [ -n "${bpid:-}" ] && [ -d "/proc/$bpid" ]
}
if command -v dbus-daemon >/dev/null 2>&1; then
    mkdir -p /run/dbus
    if ! bus_alive; then
        [ -e /run/dbus/system_bus_socket ] && \
            echo "hamnix-x11session: stale /run/dbus/system_bus_socket (no live dbus-daemon); removing" >&2
        rm -f /run/dbus/system_bus_socket /run/dbus/pid
        # A machine id, because an mmdebstrap root has none and libdbus refuses
        # to start without one ("unable to determine the machine uuid").
        command -v dbus-uuidgen >/dev/null 2>&1 && dbus-uuidgen --ensure 2>/dev/null
        # Keep its complaint. "No system bus" with no reason attached is how
        # this went unexamined for a whole pass.
        # --nofork in a background job rather than --fork: the daemon then
        # cannot exit before its complaint reaches the log, and this is the
        # form that was actually measured to come up.
        dbus-daemon --system --nofork --print-address >/tmp/dbus-system.log 2>&1 &
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            bus_alive && break
            sleep 0.3
        done
    fi
    if bus_alive; then
        echo "hamnix-x11session: system bus live on /run/dbus/system_bus_socket (pid $(cat /run/dbus/pid 2>/dev/null))" >&2
        command -v dbus-send >/dev/null 2>&1 && dbus-send --system \
            --dest=org.freedesktop.DBus --print-reply /org/freedesktop/DBus \
            org.freedesktop.DBus.GetId 2>&1 | sed 's/^/hamnix-x11session:   GetId: /' >&2
    else
        echo "hamnix-x11session: WARNING no system bus -- CEF will log a connect failure per subprocess" >&2
        [ -s /tmp/dbus-system.log ] && sed 's/^/hamnix-x11session:   dbus-daemon: /' /tmp/dbus-system.log >&2
    fi
fi
if command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    echo "hamnix-x11session: session bus ${DBUS_SESSION_BUS_ADDRESS:-none}" >&2
fi

# Software rasterisation, deliberately and by name. QEMU's plain virtio-gpu
# offers no virgl, so the DRI driver would fall back anyway; saying so here
# means a slow frame is not mistaken for a broken driver.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe

echo "hamnix-x11session: exec $*" >&2
exec "$@"
