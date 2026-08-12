#!/usr/bin/env bash
# tests/linux/wsys_close_button.sh — CAN YOU CLOSE A WINDOW ON THIS DESKTOP?
#
# THE QUESTION, and it is embarrassingly basic
# ============================================
# There was no close button. Not "it was broken" -- there was none, on any
# window, native or bridged, for the whole life of this compositor. The
# reason it was left out is the interesting part and is why this test is
# shaped the way it is:
#
#     The only thing wsysd could have done with the click was write
#     `close <wid>` on /dev/wsys/ctl, which DESTROYS THE WINDOW RECORD and
#     leaves the program running. An invisible xterm holding a shell. A
#     browser you cannot see and cannot quit. An editor with unsaved work and
#     nobody to ask. A button that does that is worse than no button.
#
# So the device grew a second verb, `delete <wid>`, which ASKS: a window whose
# owner set `wmdelete 1` gets the request on its own event ring, and
# user/wsyswl.ad turns that into WM_DELETE_WINDOW for an X client or
# xdg_toplevel.close for a native Wayland one. Anything that never heard of
# the verb is destroyed exactly as before.
#
# WHAT IS MEASURED
# ================
#   1. The button is DRAWN, and where the hit test says it is. Both are
#      computed here from the window's geometry, so a button painted
#      somewhere other than where it is clickable fails -- that being the
#      defect that takes a day and looks like a driver bug.
#   2. A real click on it, delivered as evdev through wsysd's own input path,
#      makes the X CLIENT EXIT. Not "the window disappeared" -- the process.
#      A window record deleted out from under a running program is the thing
#      this whole verb exists to avoid, so the evidence has to be the
#      program.
#   3. And a click one window-width to the left does NOT close it: a button
#      that is the whole title bar is not a button.
#
# Offscreen: HAMFB_FILE for the framebuffer, HAMWSYSD_INPUT for the pointer.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# THE MACHINE THIS RUNS ON IS NOT SCRATCH.
#
# It runs wsyswl, whose Wayland socket lands in $XDG_RUNTIME_DIR -- the machine's
# session directory until the helper started shadowing that as well.
#
# The names that matter are compiled into the binaries, not written here, so no
# care taken in this script can move them; the containment is the namespace.
# tests/linux/private_ns.sh has the table and the incident that bought it. This
# must come before anything that makes a file under /tmp, $WORK included, and
# before reap.sh, whose registry is itself a mktemp under /tmp.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

WORK="${CLOSE_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" close.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${CLOSE_KEEP:-0}"
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export XWAYLAND_NO_GLAMOR=1
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "close: PASS $*"; pass=$((pass+1)); }
bad()  { echo "close: FAIL $*"; fail=$((fail+1)); }
info() { echo "close: INFO $*"; }

KIDS=""; XWPID=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.4
    for p in $KIDS $XWPID $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not run when the shell is killed by a signal, so a
# gate stopped by `timeout` (TERM) or ^C (INT) skipped its cleanup entirely.
# Re-exit on those, which makes the EXIT trap above run on every path out.
trap 'exit 130' INT TERM HUP

for t in Xwayland xterm python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor, the Wayland server and the window probe all build"

poke()   { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
winctl() { poke "/dev/wsys/$1/ctl"; }

# THE POINTER, in evdev. Not a private protocol: these are 24-byte
# struct input_event records, the same ones an ABS tablet delivers, appended
# to the file wsysd was told to read. QEMU's virtio-tablet reports 0..32767
# across the screen and wsysd scales by that, so the test does the same
# arithmetic in reverse.
EVDEV="$WORK/input.evdev"
: >"$EVDEV"
export HAMWSYSD_INPUT="$EVDEV"
CLICK_PY="$WORK/click.py"
cat >"$CLICK_PY" <<'PY'
import struct, sys
path, W, H, x, y, click = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), \
                          int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
def ev(f, t, c, v):
    f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
with open(path, 'ab') as f:
    ev(f, 3, 0, x * 32768 // W)      # EV_ABS ABS_X
    ev(f, 3, 1, y * 32768 // H)      # EV_ABS ABS_Y
    ev(f, 0, 0, 0)                   # EV_SYN SYN_REPORT
    if click:
        ev(f, 1, 272, 1 if click > 0 else 0)   # EV_KEY BTN_LEFT
        ev(f, 0, 0, 0)
PY
# PRESS AND RELEASE ARE SEPARATE PUMPS, and that is not test decoration. wsysd
# keeps ONE `ptr_edge`, so a press and a release read in the same 16 ms pass
# collapse to the release and the press is never routed -- which is exactly
# what happened the first time this test was run, and would be exactly what a
# 60 Hz user could never produce.
point() { python3 "$CLICK_PY" "$EVDEV" "$FBW" "$FBH" "$1" "$2" 0; sleep 0.4; }
click() { python3 "$CLICK_PY" "$EVDEV" "$FBW" "$FBH" "$1" "$2" 0;  sleep 0.4
          python3 "$CLICK_PY" "$EVDEV" "$FBW" "$FBH" "$1" "$2" 1;  sleep 0.6
          python3 "$CLICK_PY" "$EVDEV" "$FBW" "$FBH" "$1" "$2" -1; sleep 1.2; }

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }
if grep -q "input from $EVDEV only" "$WORK/wsysd.log"; then
    ok "wsysd took its pointer from the test's evdev stream and opened no real input device"
else
    bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's real keyboard"
    sed 's/^/close:      /' "$WORK/wsysd.log" | head -20
fi

DISPNUM="${CLOSE_DISPLAY:-:88}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is already in use; set CLOSE_DISPLAY" >&2; exit 1; }

WSYSWL_XWM="$XSOCK" "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null \
    >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0

Xwayland -rootless -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
XWPID=$!
for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never created $XSOCK"; tail -20 "$WORK/xw.log"; exit 1; }
export DISPLAY="$DISPNUM"
for _ in $(seq 1 40); do
    [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] && break
    sleep 0.25
done
[ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] \
    || { bad "the compositor never got an X connection"; sed 's/^/close:      /' "$WORK/wsyswl.log"
         echo "close: $pass passed, $fail failed"; exit 1; }

# TWO clients, so that "the right one closed" is a question with an answer.
xterm -geometry 40x12 -bg '#ff00ff' -fg '#ff00ff' -T doomed  -e "sleep 900" >/dev/null 2>&1 &
XT_DOOMED=$!
sleep 3
xterm -geometry 40x12 -bg '#00ffff' -fg '#00ffff' -T bystander -e "sleep 900" >/dev/null 2>&1 &
XT_BYSTANDER=$!
KIDS="$XT_DOOMED $XT_BYSTANDER"
sleep 5

WIDS=""
for wid in $(seq 2 60); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${8:-0}" = 1 ] || continue
    [ "${7:-0}" = 1 ] || continue                  # decorated: it has a bar
    WIDS="$WIDS $wid"
done
set -- $WIDS
[ $# -ge 2 ] && ok "two decorated X windows are on the desktop: wids$WIDS" \
             || { bad "expected two decorated windows, found $#:$WIDS"
                  echo "close: $pass passed, $fail failed"; exit 1; }
WA=$1; WB=$2

# Put them somewhere with room for a title bar above and nothing overlapping.
poke "/dev/wsys/$WA/ctl" "geometry 80 120 340 200"
poke "/dev/wsys/$WB/ctl" "geometry 700 120 340 200"
sleep 2
read -r _ AX AY AW AH _ <<<"$(winctl "$WA")"
read -r _ BX BY BW BH _ <<<"$(winctl "$WB")"
info "wid $WA at ${AX},${AY} ${AW}x${AH};  wid $WB at ${BX},${BY} ${BW}x${BH}"

# ---------------------------------------------------------------------------
# 1. IS THE BUTTON THERE, AND IS IT WHERE THE HIT TEST LOOKS?
#    user/wsysd.ad: TITLEBAR_H 22, CLOSE_SZ 14, box at
#      x = ox + w - CLOSE_SZ - 3,  y = oy - TITLEBAR_H + (TITLEBAR_H-CLOSE_SZ)/2
#    The same arithmetic, from the same window geometry, in the test.
# ---------------------------------------------------------------------------
echo "close: === 1. is the close button painted where it is clickable?"
TITLEBAR_H=22; CLOSE_SZ=14
CBX=$((AX + AW - CLOSE_SZ - 3))
CBY=$((AY - TITLEBAR_H + (TITLEBAR_H - CLOSE_SZ) / 2))
info "wid $WA's close box should be at ${CBX},${CBY} ${CLOSE_SZ}x${CLOSE_SZ}"
BOXPCT="$(python3 - "$HAMFB_FILE" "$FBW" "$FBH" "$CBX" "$CBY" "$CLOSE_SZ" <<'PY'
import sys
f, W, H, x, y, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), \
                   int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
d = open(f, 'rb').read()
want = (0xCC, 0x55, 0x3B)   # user/wsysd.ad CLOSE_RGB
tot = hit = 0
for j in range(y, y + n):
    for i in range(x, x + n):
        o = (j * W + i) * 4
        if o + 3 > len(d):
            continue
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
)"
info "${BOXPCT}% of that rectangle is the close button's colour"
# Not 100: the white cross is drawn through it, which is 22 of 196 pixels.
[ "${BOXPCT:-0}" -ge 60 ] \
    && ok "the close button is painted at exactly the coordinates the hit test uses" \
    || bad "nothing is painted where the close button is clickable (${BOXPCT}%)"

# ---------------------------------------------------------------------------
# 2. A CLICK SOMEWHERE ELSE ON THE BAR MUST NOT CLOSE IT
# ---------------------------------------------------------------------------
echo "close: === 2. the negative: the rest of the title bar is not a button"
click $((AX + 20)) $((AY - TITLEBAR_H / 2))
if kill -0 "$XT_DOOMED" 2>/dev/null; then
    ok "a click on the left of the title bar left the client running"
else
    bad "a click on the title bar -- not on the button -- killed the client"
fi

# ---------------------------------------------------------------------------
# 3. AND THE BUTTON ITSELF
# ---------------------------------------------------------------------------
echo "close: === 3. the button"
BEFORE_REQ="$(sed -n 's/^close_requested \([0-9]*\)$/\1/p' "$STATE" | tail -1)"
click $((CBX + CLOSE_SZ / 2)) $((CBY + CLOSE_SZ / 2))
sleep 2

AFTER_REQ="$(sed -n 's/^close_requested \([0-9]*\)$/\1/p' "$STATE" | tail -1)"
AFTER_KILL="$(sed -n 's/^close_killed \([0-9]*\)$/\1/p' "$STATE" | tail -1)"
info "close_requested ${BEFORE_REQ:-0} -> ${AFTER_REQ:-0}, close_killed ${AFTER_KILL:-0}"
[ "${AFTER_REQ:-0}" -gt "${BEFORE_REQ:-0}" ] \
    && ok "the client was ASKED to close (WM_DELETE_WINDOW), not killed" \
    || bad "no close request was sent; close_killed is ${AFTER_KILL:-0}"

if kill -0 "$XT_DOOMED" 2>/dev/null; then
    bad "the X client is STILL RUNNING after its window's close button was pressed"
else
    ok "the X client EXITED -- the process, not just its window record"
fi
if kill -0 "$XT_BYSTANDER" 2>/dev/null; then
    ok "and the other window's client is untouched"
else
    bad "closing one window took the other client with it"
fi

sleep 1
GONE=1
line="$(winctl "$WA")"
if [ -n "$line" ]; then
    set -- $line
    [ "${8:-0}" = 1 ] && GONE=0
fi
[ "$GONE" = 1 ] \
    && ok "and wid $WA is gone from /dev/wsys" \
    || bad "wid $WA is still a visible window after its client exited"
line="$(winctl "$WB")"
[ -n "$line" ] \
    && ok "wid $WB is still there" \
    || bad "wid $WB vanished too"

echo "close: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
