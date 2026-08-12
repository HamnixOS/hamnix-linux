#!/bin/sh
# steam-look — the X server's own account of what Steam's window is doing,
# read from a SECOND `enter debian { }` while the session is up.
#
# hamnix_xdiag.sh answers "is there a window and is anything managing it".
# This answers the next question: DOES IT CHANGE. Every subcommand is
# repeatable, and the interesting result is the difference between two runs.
#
#   tree      every toplevel: geometry, map state, name, class
#   shot      a per-window PIXEL FINGERPRINT -- `xwd -id <w> | md5sum`. Two
#             runs with the same digest is a window that did not repaint;
#             a changed digest is a repaint, and it is the only witness on
#             this side of the namespace that does not require believing a
#             screenshot.
#   focus     _NET_ACTIVE_WINDOW, the input focus, and the pointer position
#             as the X SERVER sees it -- which is the fact that says whether
#             a pointer event crossed the wsys -> Wayland -> X boundary at all
#   xtest     type into whatever has focus with XTEST (xdotool). This is the
#             CONTROL for the whole outside path: XTEST is injected inside the
#             X server, so if these characters appear and the ones QEMU's
#             keyboard sends do not, the break is upstream of X and is ours.
#   logs      Steam's own account of where it stopped
set -u
export DISPLAY=:0

tops() {
    xwininfo -root -children 2>/dev/null \
        | sed -n 's/^ *\(0x[0-9a-f]*\) .*/\1/p'
}

case "${1:-tree}" in
tree)
    echo "look: === root children"
    xwininfo -root -children 2>&1 | sed -n '/children/,$p' | head -40
    echo "look: === each toplevel"
    for w in $(tops); do
        g="$(xwininfo -id "$w" 2>/dev/null \
             | sed -n 's/.*-geometry \([0-9x+-]*\).*/\1/p')"
        m="$(xwininfo -id "$w" 2>/dev/null \
             | sed -n 's/ *Map State: *//p')"
        n="$(xprop -id "$w" WM_NAME 2>/dev/null | sed 's/.*= //')"
        c="$(xprop -id "$w" WM_CLASS 2>/dev/null | sed 's/.*= //')"
        echo "look: $w ${g:-?} ${m:-?} name=${n:-none} class=${c:-none}"
    done
    ;;
shot)
    # THE REPAINT WITNESS. Per window, not just the root: a root digest
    # changes when the clock in any other client ticks, and would report a
    # repaint Steam never did.
    for w in $(tops); do
        d="$(xwd -id "$w" 2>/dev/null | md5sum | cut -c1-12)"
        n="$(xprop -id "$w" WM_NAME 2>/dev/null | sed 's/.*= //')"
        echo "look: shot $w ${d:-FAILED} ${n:-none}"
    done
    echo "look: shot root $(xwd -root 2>/dev/null | md5sum | cut -c1-12)"
    ;;
focus)
    echo "look: _NET_ACTIVE_WINDOW $(xprop -root _NET_ACTIVE_WINDOW 2>&1 | sed 's/.*= //')"
    echo "look: _NET_CLIENT_LIST $(xprop -root _NET_CLIENT_LIST 2>&1 | sed 's/.*= //')"
    # xdotool asks the server for the focus window and its name; without it,
    # xwininfo cannot be asked "who has focus" at all.
    if command -v xdotool >/dev/null 2>&1; then
        f="$(xdotool getwindowfocus 2>/dev/null)"
        echo "look: input focus ${f:-NONE} name=$(xdotool getwindowname "${f:-0}" 2>/dev/null)"
        echo "look: pointer $(xdotool getmouselocation 2>/dev/null)"
    else
        echo "look: no xdotool -- cannot ask the server who has focus"
    fi
    ;;
xtest)
    shift
    if ! command -v xdotool >/dev/null 2>&1; then
        echo "look: no xdotool -- the XTEST control cannot be run"; exit 1
    fi
    # Click first, then type, exactly as the outside path is asked to do.
    if [ "${1:-}" = click ]; then
        xdotool mousemove "$2" "$3" click 1
        echo "look: XTEST click at $2,$3"
        shift 3
    fi
    [ -n "${1:-}" ] && { xdotool type --delay 120 "$1"; echo "look: XTEST typed '$1'"; }
    ;;
logs)
    for f in /.steam/debian-installation/logs/cef_log.txt \
             /home/live/.steam/steam/logs/console-linux.txt \
             /home/live/.steam/steam/logs/webhelper-linux.txt \
             /tmp/xwayland.log /tmp/wm.log; do
        [ -f "$f" ] || continue
        echo "look: === tail $f"
        tail -25 "$f" 2>&1
    done
    echo "look: === wsyswl counters"
    cat /run/wsyswl-state 2>&1 | head -30
    echo "look: === processes"
    ps ax 2>/dev/null | grep -i -E 'steam|Xwayland|jwm' | grep -v grep \
        | cut -c1-140 | head -20
    ;;
*)
    echo "look: unknown subcommand ${1:-}" >&2; exit 2 ;;
esac
echo "look: done ${1:-tree}"
