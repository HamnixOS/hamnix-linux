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
# AND THE SECOND CLIENT, WHICH IS THE ONE THAT MATTERS FOR STEAM
# ==============================================================
# `xev` reads CORE X events. **Chromium does not** -- and Chromium is the whole
# of Steam's user interface, and Firefox's fallback. It calls `XISelectEvents`
# and reads the wheel off an XInput2 SCROLL VALUATOR. Core button 4/5 and the
# XI2 smooth-scroll valuator are two different paths out of the same X server,
# fed from the same `wl_pointer.axis`, and one can be dead while the other
# works -- so a gate that only ever asks `xev` can be green while the program
# whose scrolling is in question sees nothing. `tests/linux/xi2_scroll_probe.c`
# is a second client, on its own window, at its own pixel, asking the XI2
# question in the same run. Its assertions are 7-10 below.
#
# AND THE VERSION THAT ACTUALLY SHIPS
# ===================================
# This file used to run against the DEV HOST's Xwayland only (trixie, 24.1.6),
# while the Debian namespace ships **22.1.9** (bookworm) -- so for the whole of
# the hunt above it was measuring a newer server than the distribution has, and
# that gap was the last standing hypothesis for why the gate was green and
# Steam still did not scroll. It is now closed rather than argued about:
# `scripts/ns_xwayland.sh` lifts the namespace's own Xwayland out of
# `build/image/distro.ext4` with `debugfs` (no mount, no root, no write, about
# a second) and this file runs EVERY assertion below against it as a separate
# arm. The recorded answer, so the next reader does not spend a pass on it
# again: **22.1.9 and 24.1.6 behave identically here, on both the core and the
# XI2 path.** The version was not the difference. The arm stays because the
# only reason we know that is that it runs.
#
# Entirely offscreen: HAMFB_FILE for the framebuffer, a file of 24-byte
# `struct input_event` records for the mouse (the same rule
# tests/linux/de_mouse_chrome.sh sets -- no wsys ring is ever written by
# hand), and a private display per arm. No VM, no GPU, no Steam. Host Vulkan is
# forced to the software ICD.
#
# Env:
#   WHEEL_ARMS=ns|host|both   which Xwayland(s) to run against (default both)
#   WHEEL_DISPLAY=:87         the first display number; arms take :N, :N+1
#   WHEEL_WORK=<dir>          scratch (default a mktemp under $TMPDIR)
#   WHEEL_KEEP=1              keep it
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${WHEEL_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" wlwheel.XXXXXX)}"
mkdir -p "$WORK"
KEEP="${WHEEL_KEEP:-0}"
GEOM="${HAMFB_GEOM:-1280x800}"
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"
ARMS="${WHEEL_ARMS:-both}"

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

for t in xev python3 cc; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

# ---- built ONCE, used by every arm ---------------------------------------
for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" \
        >"$WORK/$name.build.log" 2>&1 || {
        bad "could not build $src"; tail -20 "$WORK/$name.build.log" >&2
        done_report; exit 1; }
done
ok "the compositor and the Wayland server both build"

cc -O1 -o "$WORK/xi2probe" tests/linux/xi2_scroll_probe.c -lX11 -lXi \
    >"$WORK/xi2probe.build.log" 2>&1 || {
    bad "could not build tests/linux/xi2_scroll_probe.c (need libx11-dev, libxi-dev)"
    tail -10 "$WORK/xi2probe.build.log" >&2; done_report; exit 1; }
ok "the XInput2 probe -- the client shaped like Chromium -- builds"

# ---- THE MOUSE, as a file of evdev records -------------------------------
# `struct input_event` is { struct timeval (16), __u16 type, __u16 code,
# __s32 value } -- 24 bytes on x86-64. EV_ABS 0/1 for position (the tablet
# range QEMU advertises, 0..32767 across the screen) and EV_REL code 8
# (REL_WHEEL) for the wheel, which is byte for byte what a real mouse
# delivers and what wsysd's pump_input parses.
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

# ---- which Xwayland(s) ---------------------------------------------------
# THE NAMESPACE'S OWN FIRST, because it is the one that ships. If the image is
# not on this machine the arm is SKIPPED BY NAME and counted as neither a pass
# nor a failure -- a version arm that silently becomes the host arm again is
# the exact shape of blind spot this file grew the arm to close.
XWAYLANDS=""
if [ "$ARMS" = ns ] || [ "$ARMS" = both ]; then
    NSXW="$(scripts/ns_xwayland.sh 2>"$WORK/nsxw.log")"
    if [ -n "$NSXW" ] && [ -x "$NSXW" ]; then
        XWAYLANDS="$XWAYLANDS namespace:$NSXW"
        info "$(sed -n 's/^ns_xwayland: //p' "$WORK/nsxw.log" | head -1)"
    else
        info "SKIPPED the namespace arm: $(tail -1 "$WORK/nsxw.log")"
    fi
fi
if [ "$ARMS" = host ] || [ "$ARMS" = both ]; then
    if command -v Xwayland >/dev/null; then
        XWAYLANDS="$XWAYLANDS host:$(command -v Xwayland)"
    else
        info "SKIPPED the host arm: no Xwayland on this host"
    fi
fi
[ -n "$XWAYLANDS" ] || { bad "no Xwayland to run against at all"; done_report; exit 1; }

# ==========================================================================
# ONE ARM: the whole stack, one Xwayland, one display.
# ==========================================================================
# THE TWO WINDOWS ARE SMALL AND NEAR THE TOP-LEFT ON PURPOSE. A rootful
# Xwayland's X screen is not the same size on both versions -- 22.1.9 still
# takes it from the wl_output (1280x800 here) and 24.x does not, so it comes up
# at its own default (640x480). Both windows have to fit in the smaller of
# those, or the arm that "fails" is really an arm whose client was off the edge
# of the screen.
run_arm() {                     # run_arm <label> <xwayland> <display>
    local label="$1" XW="$2" DISPNUM="$3"
    local W="$WORK/$label"
    mkdir -p "$W"
    local armpids=""

    export HAMWSYS="$W/wsys.shm" HAMWSYS_BB="$W/wsys.bb" HAMWSYS_IMG="$W/wsys.img"
    export HAMFB_FILE="$W/fb.raw" HAMFB_GEOM="$GEOM"

    : >"$W/input.evdev"
    export HAMWSYSD_INPUT="$W/input.evdev"
    ev() { python3 "$EVDEV_PY" "$W/input.evdev" "$FBW" "$FBH" "$@"; }

    "$WORK/wsysd.elf" </dev/null >"$W/wsysd.log" 2>&1 &
    armpids="$armpids $!"; PIDS="$PIDS $!"
    local _
    for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    [ -s "$HAMFB_FILE" ] || { bad "[$label] wsysd never produced a framebuffer"
                              cat "$W/wsysd.log"; return 1; }
    grep -q "input from $W/input.evdev only" "$W/wsysd.log" \
        && ok "[$label] wsysd took its input from the test's evdev file and opened no real device" \
        || bad "[$label] wsysd did not honour HAMWSYSD_INPUT -- it may be reading this host's mouse"

    "$WORK/wsyswl.elf" "$W/wayland-0" </dev/null >"$W/wsyswl.log" 2>&1 &
    armpids="$armpids $!"; PIDS="$PIDS $!"
    for _ in $(seq 1 60); do [ -S "$W/wayland-0" ] && break; sleep 0.1; done
    [ -S "$W/wayland-0" ] || { bad "[$label] wsyswl never created its socket"
                               cat "$W/wsyswl.log"; return 1; }
    export XDG_RUNTIME_DIR="$W" WAYLAND_DISPLAY=wayland-0

    local XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
    [ -e "$XSOCK" ] && { bad "[$label] display $DISPNUM is in use; set WHEEL_DISPLAY"; return 1; }
    "$XW" -shm -noreset "$DISPNUM" >"$W/xw.log" 2>&1 &
    armpids="$armpids $!"; PIDS="$PIDS $!"
    for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
    [ -S "$XSOCK" ] || { bad "[$label] Xwayland never came up on $DISPNUM"
                         tail -20 "$W/xw.log"; return 1; }
    export DISPLAY="$DISPNUM"
    ok "[$label] wsyswl is serving and $("$XW" -version 2>&1 | head -1) is on it at $DISPNUM"

    # stdbuf, and it is not a detail: these clients' stdout is a FILE here, so
    # libc block-buffers it and four kilobytes of events sit unwritten while
    # this script reads an empty log and reports a dead pointer.
    local XEVX=20 XEVY=20 XEVW=240 XEVH=180
    local XIX=20  XIY=240 XIW=240 XIH=180
    stdbuf -oL xev -geometry "${XEVW}x${XEVH}+${XEVX}+${XEVY}" >"$W/xev.log" 2>&1 &
    armpids="$armpids $!"; PIDS="$PIDS $!"
    stdbuf -oL "$WORK/xi2probe" "$XIX" "$XIY" "$XIW" "$XIH" >"$W/xi2.log" 2>&1 &
    armpids="$armpids $!"; PIDS="$PIDS $!"
    sleep 3
    [ -s "$W/xev.log" ] || { bad "[$label] xev produced nothing -- it never mapped a window"
                             tail -10 "$W/xw.log"; return 1; }
    grep -q '^XI2 selected' "$W/xi2.log" || {
        bad "[$label] the XI2 probe never selected -- this server may not speak XInput2"
        sed 's/^/wheel:      /' "$W/xi2.log" | tail -5; return 1; }
    info "[$label] $(grep '^XI2 screen' "$W/xi2.log" | head -1)"
    grep -q '^XI2 have-scroll-valuator' "$W/xi2.log" \
        && ok "[$label] the X server offers a smooth-scroll valuator at all -- $(grep -c '^XI2 have-scroll-valuator' "$W/xi2.log") of them" \
        || bad "[$label] NO device on this server declares an XIScrollClass, so no Chromium-shaped client can ever see a wheel here"

    local AIMX=$((XEVX + XEVW / 2)) AIMY=$((XEVY + XEVH / 2))
    local XIAX=$((XIX + XIW / 2))  XIAY=$((XIY + XIH / 2))

    # grep -c PRINTS 0 and EXITS 1 when it matches nothing, so the usual
    # `|| echo 0` fallback appends a SECOND line and every later [ ] test dies
    # with "integer expression expected". Take grep's own number, ignore its
    # status.
    count()  { grep -c "$1" "$W/xev.log" 2>/dev/null | head -1; }
    xi2c()   { grep -c "$1" "$W/xi2.log" 2>/dev/null | head -1; }
    # xev prints the button number on the `state 0x0, button 5, same_screen ...`
    # line two lines BELOW the `ButtonPress event, ...` header, so the two
    # cannot be matched on one line and a plain `grep -c "button 5,"` counts the
    # release as well and doubles every number. Pair them: arm on the
    # ButtonPress header, read the number off the next line that carries one.
    btn_presses() {
        awk -v b="$1" '
            /^ButtonPress event/ { p = 1; next }
            /button [0-9]+,/     { if (p && $0 ~ ("button " b ",")) n++; p = 0 }
            END                  { print n + 0 }' "$W/xev.log" 2>/dev/null
    }
    # The SUM of the smooth-scroll deltas, which is what carries the sign. A
    # count of scroll events cannot tell up from down.
    xi2_scroll_sum() {
        awk '/^XI2 scroll /{s += $4} END{printf "%d\n", s * 1000}' "$W/xi2.log"
    }

    # ---- 2. THE CONTROL: is the pointer alive at all? --------------------
    local M0 M1
    M0="$(count MotionNotify)"
    ev "move:$AIMX:$AIMY"; sleep 1
    ev "move:$((AIMX + 20)):$((AIMY + 20))"; sleep 1.5
    M1="$(count MotionNotify)"
    if [ "$M1" -gt "$M0" ]; then
        ok "[$label] CONTROL: an evdev MOVE reaches the X client ($M0 -> $M1 MotionNotify)"
    else
        bad "[$label] CONTROL: no MotionNotify at all -- the POINTER is dead, so this arm cannot say anything about the wheel"
        info "wsyswl said:"; sed 's/^/wheel:      /' "$W/wsyswl.log" | tail -10
        return 1
    fi

    # ---- 3+6. WHEEL DOWN -------------------------------------------------
    # evdev REL_WHEEL is POSITIVE away from the hand, which is scrolling up, so
    # down is -1. Four notches, one at a time, spaced so the compositor's 16 ms
    # poll sees them as four events and not one accumulated blob.
    local D0 U0 D1 U1 D2 U2
    D0="$(btn_presses 5)"; U0="$(btn_presses 4)"
    local i
    for i in 1 2 3 4; do ev "wheel:-1"; sleep 0.4; done
    sleep 1.5
    D1="$(btn_presses 5)"; U1="$(btn_presses 4)"
    if [ "$D1" -gt "$D0" ]; then
        ok "[$label] an evdev WHEEL DOWN reaches the X client as button 5 ($D0 -> $D1)"
    else
        bad "[$label] THE DEFECT: four evdev REL_WHEEL records and the client got NO button 5 -- the wheel is not connected to anything"
        info "wsyswl said:"; sed 's/^/wheel:      /' "$W/wsyswl.log" | tail -10
    fi
    if [ "$U1" = "$U0" ]; then
        ok "[$label] and wheel DOWN did not also arrive as button 4 -- the direction is not being invented"
    else
        bad "[$label] wheel down produced $((U1 - U0)) button-4 presses as well -- the axis sign is being lost"
    fi
    if [ "$((D1 - D0))" = 4 ]; then
        ok "[$label] four notches produced exactly four button-5 presses"
    else
        bad "[$label] four notches produced $((D1 - D0)) button-5 presses -- the wheel is connected but the count is wrong"
    fi

    # ---- 4+5. WHEEL UP, and the sign ------------------------------------
    for i in 1 2 3; do ev "wheel:1"; sleep 0.4; done
    sleep 1.5
    D2="$(btn_presses 5)"; U2="$(btn_presses 4)"
    if [ "$U2" -gt "$U1" ]; then
        ok "[$label] an evdev WHEEL UP reaches the X client as button 4 ($U1 -> $U2)"
    else
        bad "[$label] wheel UP produced no button 4 -- the server is not distinguishing the two directions"
    fi
    if [ "$D2" = "$D1" ]; then
        ok "[$label] THE SIGN IS RIGHT: up is button 4 and down is button 5, and neither leaks into the other"
    else
        bad "[$label] wheel UP produced $((D2 - D1)) button-5 presses -- the wheel scrolls BACKWARDS, which looks like it works"
    fi
    if [ "$((U2 - U1))" = 3 ]; then
        ok "[$label] three notches up produced exactly three button-4 presses"
    else
        bad "[$label] three notches up produced $((U2 - U1)) button-4 presses"
    fi

    # ---- 7-10. THE XInput2 CLIENT ---------------------------------------
    # Aim at the OTHER window. XI2 and core selections on one window are not
    # interchangeable -- a client that selects XI2 stops getting core events --
    # so the two questions are asked of two clients at two pixels, and the move
    # to the second one is its own control.
    local P0 P1 B0 B1 S0 S1
    P0="$(xi2c '^XI2 motion')"
    ev "move:$XIAX:$XIAY"; sleep 1
    ev "move:$((XIAX + 20)):$((XIAY + 10))"; sleep 1.5
    P1="$(xi2c '^XI2 motion')"
    if [ "$P1" -gt "$P0" ]; then
        ok "[$label] CONTROL: the pointer reaches the XInput2 client too ($P0 -> $P1 XI_Motion)"
    else
        bad "[$label] CONTROL: the XInput2 client sees no motion at its own window -- this arm cannot say anything about XI2 scrolling"
        return 1
    fi

    B0="$(xi2c '^XI2 button')"; S0="$(xi2_scroll_sum)"
    for i in 1 2 3 4; do ev "wheel:-1"; sleep 0.4; done
    sleep 1.5
    B1="$(xi2c '^XI2 button')"; S1="$(xi2_scroll_sum)"
    if [ "$((B1 - B0))" = 4 ]; then
        ok "[$label] the XInput2 client got exactly four XI_ButtonPress for four notches"
    else
        bad "[$label] the XInput2 client got $((B1 - B0)) XI_ButtonPress for four notches"
    fi
    # THE ONE A CHROMIUM-SHAPED CLIENT ACTUALLY READS. Xwayland turns the axis
    # into BOTH a legacy button and a smooth-scroll valuator delta, and they can
    # come apart: a client that only reads the valuator sees nothing at all
    # while `xev` reports a perfectly healthy button 5. The first report of a
    # valuator is a BASELINE and not a scroll (xi2_scroll_probe.c), so four
    # notches move it three times, and it is the SUM that is asserted -- a count
    # cannot tell up from down.
    if [ "$S1" -gt "$S0" ]; then
        ok "[$label] and the SMOOTH-SCROLL VALUATOR moved with it, downward ($S0 -> $S1 milli-units) -- what Steam's CEF and Firefox actually read"
    else
        bad "[$label] THE XI2 SMOOTH-SCROLL VALUATOR NEVER MOVED ($S0 -> $S1) -- core button 5 arrives and a Chromium-shaped client still sees no wheel"
    fi
    S0="$S1"
    for i in 1 2 3; do ev "wheel:1"; sleep 0.4; done
    sleep 1.5
    S1="$(xi2_scroll_sum)"
    if [ "$S1" -lt "$S0" ]; then
        ok "[$label] and the valuator runs the OTHER way for wheel up ($S0 -> $S1) -- the smooth path has the sign too"
    else
        bad "[$label] the smooth-scroll valuator did not reverse for wheel up ($S0 -> $S1) -- smooth scrolling goes one way only, or backwards"
    fi

    # This arm's own processes, down now: the next arm needs the display, the
    # framebuffer and the shm segment to itself, and a leaked wsysd polling an
    # evdev file forever is exactly the kind of thing NORTH_STAR.md's standing
    # constraints are about.
    local p
    for p in $armpids; do kill "$p" 2>/dev/null; done
    sleep 0.5
    for p in $armpids; do kill -9 "$p" 2>/dev/null; done
    return 0
}

DISPBASE="${WHEEL_DISPLAY:-:87}"
DN="${DISPBASE#:}"
for entry in $XWAYLANDS; do
    label="${entry%%:*}"; xw="${entry#*:}"
    echo "wheel: ===== arm: $label ($xw) on :$DN"
    run_arm "$label" "$xw" ":$DN"
    DN=$((DN + 1))
done

done_report
