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

echo "xdiag: === the FULL tree, children included"
# -children shows top-levels only, and Chromium draws into a CHILD of its
# toplevel: a toplevel that is IsViewable with an unmapped render child looks
# exactly like a window that works, and puts no pixels anywhere.
xwininfo -root -tree 2>&1 | head -60

echo "xdiag: === every top-level, in full"
# -tree, not -children: Chromium's toplevel has a two-deep render subtree and
# the map state of THOSE is the thing that decides whether anything is drawn.
for w in $(xwininfo -root -tree 2>/dev/null \
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

echo "xdiag: === which experiment this run is"
cat /usr/local/etc/hamnix-x11session.env 2>/dev/null | sed 's/^/xdiag:     /' \
    || echo "xdiag:     no env file -- defaults (matchbox, no xtrace)"

echo "xdiag: === the X wire: is MapWindow ever REQUESTED?"
# The whole point of the trace. IsUnMapped has two causes that look identical
# from xwininfo -- nobody asked, or the ask was refused/undone -- and only the
# wire separates them. Count first, then show the requests themselves.
if [ -s /tmp/xtrace.log ]; then
    echo "xdiag:     $(wc -l < /tmp/xtrace.log) lines of trace"
    for req in MapWindow MapSubwindows UnmapWindow CreateWindow ReparentWindow \
               DestroyWindow ConfigureWindow; do
        echo "xdiag:     $req requests: $(grep -c "$req" /tmp/xtrace.log)"
    done
    echo "xdiag: --- every MapWindow / MapSubwindows, in order"
    grep -n -E 'MapWindow|MapSubwindows' /tmp/xtrace.log | cut -c1-160 | head -60
    echo "xdiag: --- every MapNotify / UnmapNotify event the server sent back"
    grep -n -E 'MapNotify|UnmapNotify|MapRequest' /tmp/xtrace.log | cut -c1-160 | head -60
    echo "xdiag: --- does anything ever DRAW? (a viewable window that is never"
    echo "xdiag:     painted into is indistinguishable from a missing one)"
    # NOTE the two flavours of PutImage. xtrace prints the MIT-SHM one as
    # `MIT-SHM-Request(130,3): PutImage`, NOT as "ShmPutImage" -- so a plain
    # grep for ShmPutImage answers 0 while hundreds of shared-memory blits are
    # going past, and a grep for PutImage counts both together. Count them
    # apart, because which of the two it is decides where to look next.
    echo "xdiag:     PutImage, core X:  $(grep -c 'Request(72): PutImage' /tmp/xtrace.log)"
    echo "xdiag:     PutImage, MIT-SHM: $(grep -c 'MIT-SHM-Request(.*): PutImage' /tmp/xtrace.log)"
    for req in CopyArea PolyFillRectangle ClearArea CreatePixmap RenderComposite; do
        echo "xdiag:     $req: $(grep -c "$req" /tmp/xtrace.log)"
    done
    echo "xdiag: --- WHICH drawable is painted into, and how often"
    # The count alone does not attribute the drawing. If nothing ever paints
    # into the innermost render window, the fault is CEF's; if that window is
    # painted hundreds of times and the screen is still black, the fault is
    # downstream of the X server and CEF is exonerated.
    grep -o 'PutImage[^ ]* drawable=0x[0-9a-f]*' /tmp/xtrace.log 2>/dev/null \
        | sed 's/.*drawable=//' | sort | uniq -c | sort -rn | head -12 \
        | sed 's/^/xdiag:     /'
    echo "xdiag: --- the last few PutImage requests in full"
    grep 'PutImage' /tmp/xtrace.log 2>/dev/null | tail -4 | cut -c1-200 \
        | sed 's/^/xdiag:     /'
    echo "xdiag: --- every protocol ERROR on the wire"
    grep -n -i -E 'Error|BadWindow|BadAccess|BadMatch|BadValue' /tmp/xtrace.log \
        | cut -c1-160 | head -40
else
    echo "xdiag:     no /tmp/xtrace.log (not tracing this run)"
    [ -s /tmp/xtrace.err ] && sed 's/^/xdiag:     xtrace stderr: /' /tmp/xtrace.err
fi

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
