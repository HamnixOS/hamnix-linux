#!/usr/bin/env bash
# tests/linux/wsyswl_wheel.sh — DOES THE SCROLL WHEEL REACH A CLIENT?
#
# THE DEFECT THIS GATES
# =====================
# `user/wsysd.ad` has had the whole wheel since the input pump was written:
# evdev `EV_REL`/`REL_WHEEL` accumulates into `ptr_dz` (pump_input), the
# routed line gets kind `'s'` for scroll, and `route_pointer` writes the delta
# as the FIFTH field of `<kind> <x> <y> <buttons> <dz>`. `user/wsyswl.ad`'s
# `handle_ptr_line` parsed the first four fields and stopped, and the file had
# no `wl_pointer.axis` in it at all -- so every Wayland client behind this
# compositor, and through Xwayland every X11 client too, had a dead wheel.
#
# It was found by driving the real thing rather than by reading. Steam's store
# page, in the VM, on QEMU's own virtio-tablet: eight wheel-down events over
# the page changed **0 of 564400 pixels**, while a press-move-release DRAG of
# the same page's scrollbar with the same pointer moved 96% of them. The page
# was scrollable and the wheel was not connected to it.
# `docs/steam_namespace.md` §12 has the measurement.
#
# WHAT IS MEASURED, AND WHY IT IS THE X SERVER THAT IS ASKED
# ==========================================================
# `xev` prints the events the X SERVER delivered to its window. An X11 wheel
# is `ButtonPress`/`ButtonRelease` on buttons 4 (up) and 5 (down), which
# Xwayland synthesises from `wl_pointer.axis`. So "xev printed button 5" is
# the whole chain in one line:
#
#   evdev record -> wsysd pump_input -> /dev/wsys/<wid>/pointer
#     -> wsyswl handle_ptr_line -> wl_pointer.axis -> Xwayland -> the client
#
#   1. wsysd, wsyswl and Xwayland all come up, offscreen.
#   2. CONTROL: a plain evdev MOVE reaches the client as MotionNotify. A dead
#      pointer would otherwise look exactly like a dead wheel, and this test
#      would report the wrong defect.
#   3. wheel DOWN arrives as button 5.
#   4. wheel UP arrives as button 4 -- so 3 is not satisfied by a server that
#      turns every axis event into the same button.
#   5. THE SIGN: down is 5 and up is 4 and not the other way round. A wheel
#      that scrolls backwards works and is wrong, which is worse than one
#      that is dead because nothing about it looks broken.
#   6. the count is right: four notches down produce four button-5 presses,
#      not one and not forty.
#
# Entirely offscreen: HAMFB_FILE for the framebuffer, a file of 24-byte
# `struct input_event` records for the mouse (the same rule
# tests/linux/de_mouse_chrome.sh sets -- no wsys ring is ever written by
# hand), and the HOST's Xwayland on a private display. No VM, no GPU, no
# Steam. Host Vulkan is forced to the software ICD.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${WHEEL_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wlwheel.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${WHEEL_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"

pass=0; fail=0
ok()   { echo "wheel: PASS $*"; pass=$((pass+1)); }
bad()  { echo "wheel: FAIL $*"; fail=$((fail+1)); }
info() { echo "wheel: INFO $*"; }

PIDS=""
cleanup() {
    for p in $PIDS; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null; done
    sleep 0.4
    for p in $PIDS; do [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null; done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
done_report() { echo "wheel: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

for t in Xwayland xev python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor and the Wayland server both build"

# ---- THE MOUSE, as a file of evdev records -------------------------------
# `struct input_event` is { struct timeval (16), __u16 type, __u16 code,
# __s32 value } -- 24 bytes on x86-64. EV_ABS 0/1 for position (the tablet
# range QEMU advertises, 0..32767 across the screen) and EV_REL code 8
# (REL_WHEEL) for the wheel, which is byte for byte what a real mouse
# delivers and what wsysd's pump_input parses.
: >"$WORK/input.evdev"
export HAMWSYSD_INPUT="$WORK/input.evdev"
EVDEV_PY="$WORK/evdev.py"
cat >"$EVDEV_PY" <<'PY'
import struct, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
recs = []
for tok in sys.argv[4:]:
    kind, *a = tok.split(':')
    if kind == 'move':
        x, y = int(a[0]), int(a[1])
        recs += [(3, 0, x * 32768 // W), (3, 1, y * 32768 // H), (0, 0, 0)]
    elif kind == 'wheel':
        recs += [(2, 8, int(a[0])), (0, 0, 0)]
    else:
        sys.exit('unknown token %s' % tok)
with open(path, 'ab') as f:
    for t, c, v in recs:
        f.write(struct.pack('<qqHHi', 0, 0, t, c, v))
PY
ev() { python3 "$EVDEV_PY" "$WORK/input.evdev" "$FBW" "$FBH" "$@"; }

# ---- the compositor ------------------------------------------------------
"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"
                          cat "$WORK/wsysd.log"; done_report; exit 1; }
grep -q "input from $WORK/input.evdev only" "$WORK/wsysd.log" \
    && ok "wsysd took its input from the test's evdev file and opened no real device" \
    || bad "wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's mouse"

# ---- the Wayland server and a rootful Xwayland on it ---------------------
"$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null >"$WORK/wsyswl.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 60); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"
                              cat "$WORK/wsyswl.log"; done_report; exit 1; }
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0

DISPNUM="${WHEEL_DISPLAY:-:87}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is in use; set WHEEL_DISPLAY" >&2; exit 1; }
Xwayland -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never came up on $DISPNUM"
                     tail -20 "$WORK/xw.log"; done_report; exit 1; }
export DISPLAY="$DISPNUM"
ok "wsyswl is serving and a rootful Xwayland is on it at $DISPNUM"

# xev's own window. Rootful Xwayland presents the whole X screen as ONE
# wl_surface at 0,0, so an X coordinate IS a screen coordinate here and the
# pointer can be aimed at this rectangle directly.
XEVX=100; XEVY=100; XEVW=500; XEVH=400
# stdbuf, and it is not a detail: xev's stdout is a FILE here, so libc
# block-buffers it and four kilobytes of events sit unwritten while this
# script reads an empty log and reports a dead pointer.
stdbuf -oL xev -geometry "${XEVW}x${XEVH}+${XEVX}+${XEVY}" >"$WORK/xev.log" 2>&1 &
PIDS="$PIDS $!"
sleep 3
[ -s "$WORK/xev.log" ] || { bad "xev produced nothing -- it never mapped a window"
                            tail -10 "$WORK/xw.log"; done_report; exit 1; }

AIMX=$((XEVX + XEVW / 2)); AIMY=$((XEVY + XEVH / 2))
# grep -c PRINTS 0 and EXITS 1 when it matches nothing, so the usual
# `|| echo 0` fallback appends a SECOND line and every later [ ] test dies
# with "integer expression expected". Take grep's own number, ignore its
# status.
count() { grep -c "$1" "$WORK/xev.log" 2>/dev/null | head -1; }

# ---- 2. THE CONTROL: is the pointer alive at all? ------------------------
M0="$(count MotionNotify)"
ev "move:$AIMX:$AIMY"; sleep 1
ev "move:$((AIMX + 20)):$((AIMY + 20))"; sleep 1.5
M1="$(count MotionNotify)"
if [ "$M1" -gt "$M0" ]; then
    ok "CONTROL: an evdev MOVE reaches the X client ($M0 -> $M1 MotionNotify)"
else
    bad "CONTROL: no MotionNotify at all -- the POINTER is dead, so this file cannot say anything about the wheel"
    info "wsyswl said:"; sed 's/^/wheel:      /' "$WORK/wsyswl.log" | tail -10
    done_report; exit 1
fi

# xev prints the button number on the `state 0x0, button 5, same_screen ...`
# line two lines BELOW the `ButtonPress event, ...` header, so the two cannot
# be matched on one line and a plain `grep -c "button 5,"` counts the release
# as well and doubles every number. Pair them: arm on the ButtonPress header,
# read the number off the next line that carries one.
btn_presses() {   # btn_presses <button-number>
    awk -v b="$1" '
        /^ButtonPress event/ { p = 1; next }
        /button [0-9]+,/     { if (p && $0 ~ ("button " b ",")) n++; p = 0 }
        END                  { print n + 0 }' "$WORK/xev.log" 2>/dev/null
}

# ---- 3+6. WHEEL DOWN -----------------------------------------------------
# evdev REL_WHEEL is POSITIVE away from the hand, which is scrolling up, so
# down is -1. Four notches, one at a time, spaced so the compositor's 16 ms
# poll sees them as four events and not one accumulated blob.
D0="$(btn_presses 5)"; U0="$(btn_presses 4)"
for _ in 1 2 3 4; do ev "wheel:-1"; sleep 0.4; done
sleep 1.5
D1="$(btn_presses 5)"; U1="$(btn_presses 4)"
if [ "$D1" -gt "$D0" ]; then
    ok "an evdev WHEEL DOWN reaches the X client as button 5 ($D0 -> $D1)"
else
    bad "THE DEFECT: four evdev REL_WHEEL records and the client got NO button 5 -- the wheel is not connected to anything"
    info "wsyswl said:"; sed 's/^/wheel:      /' "$WORK/wsyswl.log" | tail -10
fi
if [ "$U1" = "$U0" ]; then
    ok "and wheel DOWN did not also arrive as button 4 -- the direction is not being invented"
else
    bad "wheel down produced $((U1 - U0)) button-4 presses as well -- the axis sign is being lost"
fi
if [ "$((D1 - D0))" = 4 ]; then
    ok "four notches produced exactly four button-5 presses"
else
    bad "four notches produced $((D1 - D0)) button-5 presses -- the wheel is connected but the count is wrong"
fi

# ---- 4+5. WHEEL UP, and the sign ----------------------------------------
for _ in 1 2 3; do ev "wheel:1"; sleep 0.4; done
sleep 1.5
D2="$(btn_presses 5)"; U2="$(btn_presses 4)"
if [ "$U2" -gt "$U1" ]; then
    ok "an evdev WHEEL UP reaches the X client as button 4 ($U1 -> $U2)"
else
    bad "wheel UP produced no button 4 -- the server is not distinguishing the two directions"
fi
if [ "$D2" = "$D1" ]; then
    ok "THE SIGN IS RIGHT: up is button 4 and down is button 5, and neither leaks into the other"
else
    bad "wheel UP produced $((D2 - D1)) button-5 presses -- the wheel scrolls BACKWARDS, which looks like it works"
fi
if [ "$((U2 - U1))" = 3 ]; then
    ok "three notches up produced exactly three button-4 presses"
else
    bad "three notches up produced $((U2 - U1)) button-4 presses"
fi

done_report
