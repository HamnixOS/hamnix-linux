#!/bin/sh
# hamnix-xdiag — what is actually on the X display inside the namespace.
# Run from a SECOND `enter debian { }` while the session is up; /tmp/.X11-unix
# is on the namespace's own filesystem, so :0 resolves from either entry.
export DISPLAY=:0
echo "xdiag: === xdpyinfo"
xdpyinfo 2>&1 | sed -n '1,8p'
echo "xdiag: === window tree"
xwininfo -root -children 2>&1 | head -40
echo "xdiag: === steam processes"
ps ax 2>/dev/null | grep -i -E "steam|Xwayland|matchbox" | grep -v grep | head -25
echo "xdiag: === end"
