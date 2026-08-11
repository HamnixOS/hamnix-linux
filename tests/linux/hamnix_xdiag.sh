#!/bin/sh
# hamnix-xdiag — what is actually on the X display inside the namespace.
# Run from a SECOND `enter debian { }` while the session is up; /tmp/.X11-unix
# is on the namespace's own filesystem, so :0 resolves from either entry.
#
# This is the evidence-gathering end of docs/steam_namespace.md §6. It answers,
# in order, the three things that could keep a Steam window off the screen:
# whether the X screen has a real size, whether anything is MANAGING the
# windows (EWMH), and what Steam's own CEF said while it was deciding where to
# put its browser.
export DISPLAY=:0
echo "xdiag: === xdpyinfo"
xdpyinfo 2>&1 | sed -n '1,8p'
xdpyinfo 2>&1 | grep -E 'dimensions|resolution'

echo "xdiag: === RandR, which is how CEF enumerates monitors"
xrandr --query 2>&1 | head -6

echo "xdiag: === EWMH on the root window"
# CEF asks the WM for the usable area before it places a window. Without a
# _NET_WORKAREA it has no answer, and an unanswered geometry query is the
# leading explanation for a browser created at INT32_MIN.
xprop -root _NET_SUPPORTING_WM_CHECK _NET_WORKAREA _NET_DESKTOP_GEOMETRY \
            _NET_NUMBER_OF_DESKTOPS _NET_CURRENT_DESKTOP _NET_ACTIVE_WINDOW \
            _NET_CLIENT_LIST 2>&1 | cut -c1-200
echo "xdiag: --- _NET_SUPPORTED"
xprop -root _NET_SUPPORTED 2>&1 | cut -c1-600

echo "xdiag: === window tree"
xwininfo -root -children 2>&1 | head -40

echo "xdiag: === every top-level, in full"
for w in $(xwininfo -root -children 2>/dev/null \
           | sed -n 's/^ *\(0x[0-9a-f]*\).*/\1/p'); do
    echo "xdiag: --- $w"
    xwininfo -id "$w" -all 2>&1 | grep -E \
        'Window id|Absolute upper-left|Width|Height|Map State|Override Redirect|Window type' \
        | sed 's/^/xdiag:     /'
    xprop -id "$w" WM_NAME WM_CLASS _NET_WM_WINDOW_TYPE _NET_WM_STATE 2>&1 \
        | cut -c1-140 | sed 's/^/xdiag:     /'
done

echo "xdiag: === the buses, which CEF needs one of and complains about both"
# NOT with dbus-send: it is not in this image, so a ping check reports "no bus"
# no matter what is true. A live system bus is a socket plus the pid in
# /run/dbus/pid still existing.
BPID=""
[ -r /run/dbus/pid ] && read -r BPID < /run/dbus/pid
if [ -S /run/dbus/system_bus_socket ] && [ -n "${BPID:-}" ] && [ -d "/proc/$BPID" ]; then
    echo "xdiag: system bus LIVE (dbus-daemon pid $BPID)"
else
    echo "xdiag: system bus NOT LIVE (socket: $([ -e /run/dbus/system_bus_socket ] && echo present || echo absent), pid file: ${BPID:-none})"
fi
ls -l /run/dbus/ 2>&1 | head -5
[ -s /tmp/dbus-system.log ] && sed 's/^/xdiag: dbus-daemon: /' /tmp/dbus-system.log

echo "xdiag: === Xwayland's own log"
tail -25 /tmp/xwayland.log 2>&1
echo "xdiag: === matchbox's own log"
tail -15 /tmp/mbwm.log 2>&1

echo "xdiag: === CEF: where did it put the browser, and why"
CEF=/.steam/debian-installation/logs/cef_log.txt
[ -f "$CEF" ] || CEF="$(ls -1 /home/*/.steam/*/logs/cef_log.txt 2>/dev/null | head -1)"
if [ -n "${CEF:-}" ] && [ -f "$CEF" ]; then
    echo "xdiag: --- $CEF: geometry, GPU and window lines"
    grep -a -E -i 'CreateBrowser|BrowserReady|PopupHTMLWindow|SetBounds|2147483648|gpu|viz_main|GL |ozone|x11|display' \
        "$CEF" 2>/dev/null | tail -60
    echo "xdiag: --- $CEF: last 40 lines"
    tail -40 "$CEF"
else
    echo "xdiag: NO cef_log.txt"
fi

echo "xdiag: === steamwebhelper's own log"
WH="$(ls -1 /home/*/.steam/steam/logs/webhelper-linux.txt 2>/dev/null | head -1)"
[ -n "$WH" ] && tail -40 "$WH" || echo "xdiag: NO webhelper-linux.txt"

echo "xdiag: === the client console log"
CL="$(ls -1 /home/*/.steam/steam/logs/console-linux.txt 2>/dev/null | head -1)"
[ -n "$CL" ] && tail -50 "$CL" || echo "xdiag: NO console-linux.txt"

echo "xdiag: === steam processes"
ps ax 2>/dev/null | grep -i -E "steam|Xwayland|matchbox" | grep -v grep \
    | cut -c1-160 | head -25
echo "xdiag: === end"
