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

# THE EXPERIMENT KNOBS, AND WHY THEY ARE IN A FILE RATHER THAN THE ENVIRONMENT.
# This script is exec'd through `spawn debian { ... }` from an rc, and what an
# rc exports is not what crosses a namespace entry -- so an experiment selected
# with an environment variable would silently run the DEFAULT and report on it,
# which is the exact failure shape NORTH_STAR.md exists to beat. The harness
# plants this file beside the script instead, so the setting is on disk in the
# image and can be read back afterwards.
#
#   HAMNIX_X11_WM=matchbox|none   which window manager, if any
#   HAMNIX_X11_XTRACE=0|1         proxy the display through xtrace(1) and log
#                                 every X request the session makes
[ -r /usr/local/etc/hamnix-x11session.env ] && . /usr/local/etc/hamnix-x11session.env
HAMNIX_X11_WM="${HAMNIX_X11_WM:-matchbox}"
HAMNIX_X11_XTRACE="${HAMNIX_X11_XTRACE:-0}"

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

# XTRACE: DOES THE CLIENT EVER ASK FOR THE WINDOW TO BE MAPPED?
# docs/steam_namespace.md §6.2 measured that every window Steam creates it
# leaves IsUnMapped. That single fact has two completely different causes --
# Steam never issues MapWindow, or it issues one that is refused or undone --
# and no amount of xwininfo can tell them apart, because xwininfo only ever
# sees the outcome. xtrace fakes an X server on :9, forwards to the real :0 and
# writes down every request, so the question is answered by the wire.
#
# The whole session goes through it, window manager included: a MapRequest is
# redirected TO the WM, so a trace that omitted the WM would show the request
# vanish and could not say who dropped it.
if [ "$HAMNIX_X11_XTRACE" = 1 ]; then
    if ! command -v xtrace >/dev/null 2>&1; then
        # Not in the Debian archive's default set for this image; the harness
        # plants it as a tarball rather than adding 2 GB of rebuild.
        # -C / : the tarball's members are usr/bin/xtrace and usr/share/xtrace,
        # so unpacking it at /usr puts the binary in /usr/usr/bin and the only
        # symptom is this script saying "no xtrace binary" one line later.
        if [ -f /usr/local/lib/xtrace-bundle.tar.gz ]; then
            tar xzf /usr/local/lib/xtrace-bundle.tar.gz -C / 2>/tmp/xtrace-untar.log \
                || sed 's/^/hamnix-x11session:   tar: /' /tmp/xtrace-untar.log >&2
        fi
    fi
    if command -v xtrace >/dev/null 2>&1; then
        rm -f /tmp/xtrace.log
        # -k  keep running when a client disconnects; the session outlives any
        #     one client and the launcher exits long before CEF does.
        # -m 8  truncate long lists -- an ATOM list is not what is under test
        #       and untruncated they bury the log.
        xtrace -k -d :0 -D :9 -m 8 -o /tmp/xtrace.log >/tmp/xtrace.err 2>&1 &
        i=0
        while [ $i -lt 40 ]; do
            [ -e /tmp/.X11-unix/X9 ] && break
            i=$((i+1)); sleep 0.25
        done
        if DISPLAY=:9 xdpyinfo >/dev/null 2>&1; then
            export DISPLAY=:9
            echo "hamnix-x11session: xtrace proxying :9 -> :0, log /tmp/xtrace.log" >&2
        else
            echo "hamnix-x11session: WARNING xtrace did not come up; staying on :0" >&2
            [ -s /tmp/xtrace.err ] && sed 's/^/hamnix-x11session:   xtrace: /' /tmp/xtrace.err >&2
        fi
    else
        echo "hamnix-x11session: WARNING HAMNIX_X11_XTRACE=1 but no xtrace binary" >&2
    fi
fi

# THE WINDOW MANAGER, WHICH IS OPTIONAL AND IS A SUSPECT.
# matchbox is a SINGLE-WINDOW handheld WM and it is the only thing standing
# between a client's MapRequest and the screen: SubstructureRedirect means the
# map does not happen unless the WM performs it. X11 does not require a window
# manager at all, so running with none is a control, not a degradation.
case "$HAMNIX_X11_WM" in
    none)
        echo "hamnix-x11session: NO window manager (HAMNIX_X11_WM=none) -- MapWindow takes effect directly" >&2 ;;
    matchbox)
        matchbox-window-manager -use_titlebar no >/tmp/mbwm.log 2>&1 &
        echo "hamnix-x11session: window manager matchbox" >&2
        sleep 1 ;;
    *)
        $HAMNIX_X11_WM >/tmp/wm.log 2>&1 &
        echo "hamnix-x11session: window manager $HAMNIX_X11_WM" >&2
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
# HOW TO ASK. `dbus-send` is NOT in this image, so a ping-based check answers
# "no bus" whatever the truth is -- which is the same class of lie as the
# stale socket it was meant to catch, and it fired: CEF was getting real
# replies from a bus this script had just declared dead. dbus-daemon --system
# writes its pid to /run/dbus/pid, so a live bus is a socket AND a process
# that still exists. That needs no tools beyond the shell.
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
        # A MACHINE ID, AND IT REALLY IS MISSING. An mmdebstrap root has no
        # /etc/machine-id and an EMPTY /var/lib/dbus -- verified by reading the
        # image itself with debugfs, without booting anything:
        #     debugfs -R "ls -l /var/lib/dbus" build/image/distro.ext4  ->  . ..
        # dbus-daemon refuses to start without one. `dbus-uuidgen --ensure`
        # was already being called here, with its output thrown away and its
        # exit status ignored, so if it failed nothing said so. Do both files
        # by name and REPORT, because a machine id that was not created is
        # indistinguishable from one that was until the bus fails to start.
        [ -s /etc/machine-id ] || dbus-uuidgen > /etc/machine-id 2>/tmp/dbus-uuidgen.log
        mkdir -p /var/lib/dbus
        [ -s /var/lib/dbus/machine-id ] || cp /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null
        if [ -s /etc/machine-id ] && [ -s /var/lib/dbus/machine-id ]; then
            echo "hamnix-x11session: machine id $(cat /etc/machine-id)" >&2
        else
            echo "hamnix-x11session: WARNING no machine id -- dbus-daemon will refuse to start" >&2
            [ -s /tmp/dbus-uuidgen.log ] && sed 's/^/hamnix-x11session:   dbus-uuidgen: /' /tmp/dbus-uuidgen.log >&2
        fi
        # Keep its complaint. "No system bus" with no reason attached is how
        # this went unexamined for a whole pass.
        dbus-daemon --system --fork >/tmp/dbus-system.log 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            bus_alive && break
            sleep 0.3
        done
    fi
    if bus_alive; then
        echo "hamnix-x11session: system bus live on /run/dbus/system_bus_socket (pid $(cat /run/dbus/pid 2>/dev/null))" >&2
        # AND ASK IT SOMETHING, because a socket plus a live pid is still only
        # circumstantial. dbus-send IS in this image (/usr/bin/dbus-send, from
        # the `dbus` package) -- an earlier comment here asserted it was not,
        # which is why the liveness test was reduced to file inspection.
        if command -v dbus-send >/dev/null 2>&1; then
            if dbus-send --system --dest=org.freedesktop.DBus --print-reply \
                 /org/freedesktop/DBus org.freedesktop.DBus.GetId >/tmp/dbus-ping.log 2>&1; then
                echo "hamnix-x11session: system bus ANSWERED GetId" >&2
            else
                echo "hamnix-x11session: WARNING system bus did NOT answer GetId" >&2
                sed 's/^/hamnix-x11session:   dbus-send: /' /tmp/dbus-ping.log >&2
            fi
        fi
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
