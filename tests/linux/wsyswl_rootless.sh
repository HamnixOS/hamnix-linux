#!/usr/bin/env bash
# tests/linux/wsyswl_rootless.sh — IS AN X WINDOW A WINDOW ON THIS DESKTOP?
#
#   X11 clients -> Xwayland -rootless -> wsyswl + its XWM -> /dev/wsys
#                                     -> wsysd -> /dev/fb
#
# THE QUESTION, and it is not the one the last two passes asked.
# ==============================================================
# `wsyswl_shared_fate.sh` next door asks "when one client runs out of
# something, who else stops?" and answered it: nobody who should not, and
# rootless would not have changed that anyway, because every limit in
# `user/wsyswl.ad` is per CONNECTION and Xwayland opens exactly one either way.
# That is settled and it is not re-litigated here.
#
# This asks the question that survived, which is the project's own:
#
#     Can the Hamnix desktop MOVE ONE X WINDOW?
#
# Under rootful Xwayland it cannot, and the reason is not a bug: the entire X
# session -- every client, the window manager, its frames, Steam and all -- is
# ONE wl_surface and therefore ONE wsys window. `windows_high_water 1` for a
# whole Steam session, measured. wsysd can move that rectangle. It cannot move
# a window inside it, because there is no window inside it to move, and that
# is why a namespace needs `jwm` running inside it while Firefox -- a native
# Wayland client -- gets one wsys window per xdg_toplevel and needs nothing.
#
# So the property under test is stated as pixels and as files, not as a count:
#
#   1. TWO X CLIENTS ARE TWO WSYS WINDOWS. Two wids under /dev/wsys, each with
#      its own geometry, from ONE X display -- and `windows_high_water` above
#      one, which the rootful arm below cannot reach however many clients it
#      carries.
#
#   2. AND THEY MOVE INDEPENDENTLY. Move one with the compositor's own verb,
#      the same one the desktop uses, and require that the OTHER one does not
#      move -- in the window table AND in the framebuffer. A pair of window
#      records that both point at the same pixels would pass part 1 and is
#      exactly the success-shaped answer NORTH_STAR.md is about.
#
#   3. THE ROOTFUL ARM IS THE CONTROL, in the same script and on the same
#      compositor: the same two clients on a rootful Xwayland are ONE window.
#      That is the difference this whole piece of work buys, measured rather
#      than asserted.
#
#   4. NOTHING IS ADVERTISED THAT IS NOT BACKED. With WSYSWL_XWM unset the
#      compositor must NOT offer `xwayland_shell_v1`: a client that binds it
#      hands over surfaces that can never be paired with an X window, which is
#      a rootless display that comes up managed and empty with no error
#      anywhere. The negative is the load-bearing half.
#
# Offscreen throughout: HAMFB_FILE for the framebuffer and the HOST's Xwayland,
# so it touches no display, needs no VM, and takes about a minute.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

WORK="${RLESS_WORK:-$(mktemp -d -p "${TMPDIR:-/tmp}" rless.XXXXXX)}"
mkdir -p "$WORK"
GEOM="${HAMFB_GEOM:-1280x800}"
KEEP="${RLESS_KEEP:-0}"
SHOT="${RLESS_SHOT:-}"
# PRIVATE, all three. The wsys segment, the v2 backbuffer and the named-image
# segment each default to ONE FILE PER HOST with slots keyed by wid and no
# owner, so two runs hand each other stale slots -- an hour was once spent on
# a compositor bug that was a previous run's backbuffer.
export HAMWSYS="$WORK/wsys.shm"
export HAMWSYS_BB="$WORK/wsys.bb"
export HAMWSYS_IMG="$WORK/wsys.img"
export HAMFB_FILE="$WORK/fb.raw"
export HAMFB_GEOM="$GEOM"
# wsysd arms a real Vulkan backend on real silicon and this host's GPU belongs
# to someone. Software ICD, always, for anything offscreen.
[ -r /usr/share/vulkan/icd.d/lvp_icd.json ] && \
    export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
# ... and the same rule for Xwayland, which probes GBM on the host's real
# card before it falls back to shm.
export XWAYLAND_NO_GLAMOR=1
FBW="${GEOM%x*}"; FBH="${GEOM#*x}"

pass=0; fail=0
ok()   { echo "rless: PASS $*"; pass=$((pass+1)); }
bad()  { echo "rless: FAIL $*"; fail=$((fail+1)); }
info() { echo "rless: INFO $*"; }

KIDS=""; XWPID=""; XWPID2=""; WLPID=""; WSYSDPID=""
cleanup() {
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    done
    sleep 0.4
    for p in $KIDS $XWPID $XWPID2 $WLPID $WSYSDPID; do
        [ -n "${p:-}" ] && kill -9 "$p" 2>/dev/null
    done
    [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

for t in Xwayland xterm xwininfo python3; do
    command -v "$t" >/dev/null || { echo "need $t on the host" >&2; exit 1; }
done

for t in wsysd:user/wsysd.ad wsyswl:user/wsyswl.ad \
         wsys_poke:tests/linux/wsys_poke.ad; do
    name="${t%%:*}"; src="${t#*:}"
    scripts/hamlinux_build.sh "$src" "$WORK/$name.elf" >"$WORK/$name.build.log" 2>&1 || {
        echo "FAIL could not build $src" >&2; tail -20 "$WORK/$name.build.log" >&2; exit 1; }
done
ok "the compositor, the Wayland server and the window probe all build"

# The window table, straight out of the device every client reads:
#   "<wid> <x> <y> <w> <h> <z> <decorate> <visible> <proto> ..."
poke()     { "$WORK/wsys_poke.elf" "$@" 2>/dev/null; }
winctl()   { poke "/dev/wsys/$1/ctl"; }
st()   { sleep 1; sed -n "s/^$1 \([0-9-]*\)\$/\1/p" "$STATE" 2>/dev/null | tail -1; }

# What fraction of a rectangle is exactly one colour. Sampled every other
# pixel in both directions, which is plenty for "is this window here".
FRAC_PY="$WORK/frac.py"
cat >"$FRAC_PY" <<'PY'
import sys
W, H = int(sys.argv[1]), int(sys.argv[2])
x, y, w, h = (int(v) for v in sys.argv[3:7])
d = open(sys.argv[7], 'rb').read()
c = sys.argv[8]
want = (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
tot = hit = 0
for j in range(max(y, 0), min(y + h, H), 2):
    row = j * W * 4
    for i in range(max(x, 0), min(x + w, W), 2):
        o = row + i * 4
        if o + 3 > len(d):
            continue
        tot += 1
        if (d[o+2], d[o+1], d[o]) == want:
            hit += 1
print(0 if tot == 0 else hit * 100 // tot)
PY
colourpct() { python3 "$FRAC_PY" "$FBW" "$FBH" "$1" "$2" "$3" "$4" "$5" "$6"; }

"$WORK/wsysd.elf" </dev/null >"$WORK/wsysd.log" 2>&1 &
WSYSDPID=$!
for _ in $(seq 1 60); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
[ -s "$HAMFB_FILE" ] || { bad "wsysd never produced a framebuffer"; cat "$WORK/wsysd.log"; exit 1; }

DISPNUM="${RLESS_DISPLAY:-:84}"
XSOCK="/tmp/.X11-unix/X${DISPNUM#:}"
[ -e "$XSOCK" ] && { echo "display $DISPNUM is already in use; set RLESS_DISPLAY" >&2; exit 1; }

WSYSWL_XWM="$XSOCK" "$WORK/wsyswl.elf" "$WORK/wayland-0" </dev/null \
    >"$WORK/wsyswl.log" 2>&1 &
WLPID=$!
for _ in $(seq 1 40); do [ -S "$WORK/wayland-0" ] && break; sleep 0.1; done
[ -S "$WORK/wayland-0" ] || { bad "wsyswl never created its socket"; cat "$WORK/wsyswl.log"; exit 1; }
STATE="$WORK/wsyswl-state"
export XDG_RUNTIME_DIR="$WORK"
export WAYLAND_DISPLAY=wayland-0
ok "wsyswl is listening, and was told to manage the X display at $XSOCK"

# ---------------------------------------------------------------------------
# 0. THE NEGATIVE FIRST. wsyswl was started WITH an XWM, so it may advertise
#    xwayland_shell_v1 -- and the rootful compositor beside it may not. Both
#    halves are asserted, because "the global is there" is only evidence if
#    "the global is absent when it would be a lie" is also true.
# ---------------------------------------------------------------------------
echo "rless: === 0. is xwayland_shell_v1 advertised, and only when it is backed?"
ADV="$WORK/adv"
mkdir -p "$ADV"
# HAMWSYS is SHARED with the running wsysd on purpose: wsyswl reads the screen
# size out of /dev/wsys/screen before it will listen at all, and refuses to
# serve without one. Only the backbuffer and image segments are private, and
# this server never opens a window anyway -- it exists for one get_registry.
HAMWSYS_BB="$ADV/wsys.bb" HAMWSYS_IMG="$ADV/wsys.img" \
    "$WORK/wsyswl.elf" "$ADV/wayland-0"</dev/null >"$ADV/wsyswl.log" 2>&1 &
BAREPID=$!
for _ in $(seq 1 40); do [ -S "$ADV/wayland-0" ] && break; sleep 0.1; done
globals_of() {
    # One Wayland client, one get_registry, print every global's name. libwayland
    # is not available here, so this is 40 lines of wire protocol and no more.
    python3 - "$1" <<'PY'
import socket, struct, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
# A Wayland message is object id (4), then size<<16 | opcode (4), then args.
# wl_display@1.get_registry(new id 2)  -- opcode 1, one new_id argument
s.send(struct.pack('<III', 1, (12 << 16) | 1, 2))
# wl_display@1.sync(new id 3) -- opcode 0; its callback.done is the fence that
# says "every global has been sent", so this needs no timeout to be correct.
s.send(struct.pack('<III', 1, (12 << 16) | 0, 3))
buf = b''
names = []
try:
    while True:
        b = s.recv(65536)
        if not b:
            break
        buf += b
        done = False
        while len(buf) >= 8:
            obj, sz_op = struct.unpack('<II', buf[:8])
            size, op = sz_op >> 16, sz_op & 0xffff
            if size < 8 or len(buf) < size:
                break
            body = buf[8:size]
            buf = buf[size:]
            if obj == 2 and op == 0 and len(body) >= 8:
                ln = struct.unpack('<I', body[4:8])[0]
                names.append(body[8:8 + ln - 1].decode('ascii', 'replace'))
            if obj == 3:
                done = True
        if done:
            break
except Exception:
    pass
print('\n'.join(names))
PY
}
XWM_GLOBALS="$(globals_of "$WORK/wayland-0")"
BARE_GLOBALS="$(globals_of "$ADV/wayland-0")"
kill "$BAREPID" 2>/dev/null
if grep -qx 'xwayland_shell_v1' <<<"$XWM_GLOBALS"; then
    ok "with an XWM, xwayland_shell_v1 IS advertised"
else
    bad "with an XWM, xwayland_shell_v1 is NOT advertised -- nothing can hand over an X surface"
    info "globals were: $(tr '\n' ' ' <<<"$XWM_GLOBALS")"
fi
if grep -qx 'xwayland_shell_v1' <<<"$BARE_GLOBALS"; then
    bad "WITHOUT an XWM, xwayland_shell_v1 is still advertised -- a promise with nothing behind it"
else
    ok "without an XWM, xwayland_shell_v1 is NOT advertised (the rootful path is untouched)"
fi
if grep -qx 'xdg_wm_base' <<<"$BARE_GLOBALS"; then
    ok "the rootful compositor still advertises xdg_wm_base, wl_shm and the rest"
else
    bad "the rootful compositor lost a global it always had"
    info "globals were: $(tr '\n' ' ' <<<"$BARE_GLOBALS")"
fi

# ---------------------------------------------------------------------------
# 1. TWO X CLIENTS, ONE ROOTLESS DISPLAY, HOW MANY WSYS WINDOWS?
# ---------------------------------------------------------------------------
echo "rless: === 1. two X clients on ONE rootless Xwayland"
Xwayland -rootless -shm -noreset "$DISPNUM" >"$WORK/xw.log" 2>&1 &
XWPID=$!
for _ in $(seq 1 150); do [ -S "$XSOCK" ] && break; sleep 0.1; done
[ -S "$XSOCK" ] || { bad "Xwayland never created $XSOCK"; tail -20 "$WORK/xw.log"; exit 1; }
export DISPLAY="$DISPNUM"
# The compositor dials the display about twice a second; give it a few tries.
for _ in $(seq 1 40); do
    [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ] && break
    sleep 0.25
done
if [ "$(sed -n 's/^xwm_connected \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)" = 1 ]; then
    ok "the compositor's window manager has the X display"
else
    bad "the compositor never got an X connection -- nothing below can be asked"
    sed 's/^/rless:      /' "$WORK/wsyswl.log"
    echo "rless: $pass passed, $fail failed"; exit 1
fi

# Two clients in two colours nothing else on this screen is, so "which window
# is this" is answerable from the framebuffer and not only from a table.
COL_A=ff00ff
COL_B=00ffff
xterm -geometry 30x8+60+80  -bg "#$COL_A" -fg "#$COL_A" -T alpha -e "sleep 900" \
      >/dev/null 2>&1 &
KIDS="$KIDS $!"
sleep 3
xterm -geometry 30x8+600+400 -bg "#$COL_B" -fg "#$COL_B" -T beta -e "sleep 900" \
      >/dev/null 2>&1 &
KIDS="$KIDS $!"
sleep 4

XCHILDREN="$(xwininfo -root -children 2>/dev/null | sed -n 's/^ *\(0x[0-9a-f]*\) "[^"]*".*/\1/p' | wc -l)"
if [ "$XCHILDREN" -ge 2 ]; then
    ok "the X root has $XCHILDREN mapped children -- the window manager maps what it redirects"
else
    bad "the X root has $XCHILDREN children; a WM that redirects and never maps is matchbox's bug"
fi

MANAGED="$(st xwl_managed)"
PAIRED="$(st xwl_paired)"
WHI="$(st windows_high_water)"
UNPAIRED="$(st drop_xwl_unpaired)"
REFUSED="$(st xwm_refused)"
COMMITS="$(st commits)"
CONNS="$(st conns)"
info "xwl_managed $MANAGED  xwl_paired $PAIRED  windows_high_water $WHI  conns $CONNS"
info "commits $COMMITS  drop_xwl_unpaired $UNPAIRED  xwm_refused $REFUSED"

[ "${MANAGED:-0}" -ge 2 ] \
    && ok "the XWM has both X windows on its books" \
    || bad "the XWM manages ${MANAGED:-0} X windows, expected at least 2"
[ "${PAIRED:-0}" -ge 2 ] \
    && ok "both X windows were associated with a wl_surface" \
    || bad "only ${PAIRED:-0} associations were made -- an X window with no surface is invisible"
[ "${WHI:-0}" -ge 2 ] \
    && ok "windows_high_water is $WHI: an X toplevel is its own wsys window" \
    || bad "windows_high_water is ${WHI:-0} -- the whole X session is still one rectangle"
[ "${UNPAIRED:-1}" = 0 ] \
    && ok "no frame was thrown away for want of an association" \
    || bad "$UNPAIRED commits were dropped unpaired"
[ "${REFUSED:-1}" = 0 ] \
    && ok "the XWM refused nothing" \
    || bad "the XWM refused $REFUSED things -- see wsyswl's stderr, it names them"
# ONE Wayland connection carrying both windows, which is the fact
# docs/linux_window_manager.md 8a turns on: rootless buys addressability, NOT
# independence. Asserting it here keeps the two claims from being confused
# again by whoever reads this next.
[ "${CONNS:-0}" = 1 ] \
    && ok "and it is still ONE Wayland connection -- rootless buys addressability, not fate" \
    || info "conns is ${CONNS:-0}"

# ---------------------------------------------------------------------------
# 2. THE WINDOW TABLE, and then MOVING ONE OF THEM
# ---------------------------------------------------------------------------
echo "rless: === 2. two wids under /dev/wsys, and can wsysd move one of them?"
WIDS=""
for wid in $(seq 2 40); do
    line="$(winctl "$wid")"
    [ -n "$line" ] || continue
    set -- $line
    [ "${8:-0}" = 1 ] || continue                  # visible
    [ "${4:-0}" = "$FBW" ] && continue             # not the backdrop, if any
    WIDS="$WIDS $wid"
done
set -- $WIDS
NW=$#
if [ "$NW" -ge 2 ]; then
    ok "/dev/wsys lists $NW application windows for one X display: wids$WIDS"
else
    bad "/dev/wsys lists $NW application windows -- expected two, one per X client"
    sed 's/^/rless:      /' "$WORK/wsyswl.log" | tail -30
    echo "rless: $pass passed, $fail failed"; exit 1
fi
WA=$1; WB=$2
read -r _ AX AY AW AH _ <<<"$(winctl "$WA")"
read -r _ BX BY BW BH _ <<<"$(winctl "$WB")"
info "wid $WA at ${AX},${AY} ${AW}x${AH}   wid $WB at ${BX},${BY} ${BW}x${BH}"
if [ "$AX" != "$BX" ] || [ "$AY" != "$BY" ]; then
    ok "the two windows have different geometry -- they are two windows, not two names for one"
else
    bad "both wids report the same position; these are not independent windows"
fi

cp "$HAMFB_FILE" "$WORK/before.raw"
# Which of the two is which colour? Ask the framebuffer rather than assuming
# the wid order matches the launch order.
PA_A="$(colourpct "$AX" "$AY" "$AW" "$AH" "$WORK/before.raw" "$COL_A")"
PA_B="$(colourpct "$AX" "$AY" "$AW" "$AH" "$WORK/before.raw" "$COL_B")"
PB_A="$(colourpct "$BX" "$BY" "$BW" "$BH" "$WORK/before.raw" "$COL_A")"
PB_B="$(colourpct "$BX" "$BY" "$BW" "$BH" "$WORK/before.raw" "$COL_B")"
info "wid $WA is ${PA_A}% alpha / ${PA_B}% beta;  wid $WB is ${PB_A}% alpha / ${PB_B}% beta"
MOVER=$WA; MOVER_COL=$COL_A; STAYER=$WB; STAYER_COL=$COL_B
if [ "$PA_B" -gt "$PA_A" ]; then MOVER_COL=$COL_B; STAYER_COL=$COL_A; fi
if [ "$((PA_A + PA_B))" -lt 30 ] || [ "$((PB_A + PB_B))" -lt 30 ]; then
    bad "one of the two windows is not on the framebuffer at all (${PA_A}/${PA_B} and ${PB_A}/${PB_B} per cent)"
else
    ok "both windows' pixels are on the Hamnix framebuffer, in their own colours"
fi
read -r _ SX SY SW SH _ <<<"$(winctl "$STAYER")"

# THE MOVE. `geometry` on the window's own ctl file is what wsysd's own
# dragging writes -- the desktop moving a window, spelled as a file.
NEWX=$((AX + 220)); NEWY=$((AY + 180))
poke "/dev/wsys/$MOVER/ctl" "geometry $NEWX $NEWY $AW $AH"
sleep 2
read -r _ MX MY MW MH _ <<<"$(winctl "$MOVER")"
read -r _ TX TY TW TH _ <<<"$(winctl "$STAYER")"
if [ "$MX" = "$NEWX" ] && [ "$MY" = "$NEWY" ]; then
    ok "the compositor moved wid $MOVER to ${NEWX},${NEWY}"
else
    bad "wid $MOVER did not move: it is at ${MX},${MY}, asked for ${NEWX},${NEWY}"
fi
if [ "$TX" = "$SX" ] && [ "$TY" = "$SY" ]; then
    ok "and wid $STAYER did not move with it -- THE POINT OF THE WHOLE CHANGE"
else
    bad "wid $STAYER moved too (${SX},${SY} -> ${TX},${TY}); these share a fate they should not"
fi

# ---- AND DOES THE CLIENT KNOW? --------------------------------------------
# The move above was measured in the framebuffer and in the window table, and
# for stage one that was the whole claim. It left the X client believing it
# was still where it opened: `xwininfo` on it reported the ORIGINAL corner for
# the rest of the session, and an override-redirect menu placed at "my corner
# plus twenty" was placed against a corner that had not been true since the
# first drag. Pointer coordinates were never affected -- they are
# surface-local and Xwayland adds the origin itself -- which is exactly why
# everything LOOKED right and this was easy to leave out.
#
# So the compositor now pushes the new rectangle back as a ConfigureWindow,
# which the X server turns into the ConfigureNotify the client is waiting for.
# The evidence is the X server's own answer, asked by a different program.
MOVER_NAME=alpha
[ "$MOVER_COL" = "$COL_B" ] && MOVER_NAME=beta
XI="$(xwininfo -name "$MOVER_NAME" 2>/dev/null)"
XPX="$(sed -n 's/^ *Absolute upper-left X: *\([0-9-]*\).*/\1/p' <<<"$XI" | head -1)"
XPY="$(sed -n 's/^ *Absolute upper-left Y: *\([0-9-]*\).*/\1/p' <<<"$XI" | head -1)"
PUSHED="$(sed -n 's/^x_configure_pushed \([0-9]*\)$/\1/p' "$STATE" 2>/dev/null | tail -1)"
info "the X server says '$MOVER_NAME' is at ${XPX:-?},${XPY:-?}; x_configure_pushed ${PUSHED:-?}"
if [ "${XPX:-x}" = "$NEWX" ] && [ "${XPY:-x}" = "$NEWY" ]; then
    ok "the X client was TOLD where the desktop put it -- X and wsys agree on ${NEWX},${NEWY}"
else
    bad "the X client still thinks it is at ${XPX:-?},${XPY:-?}, not ${NEWX},${NEWY}"
fi
[ "${PUSHED:-0}" -ge 1 ] \
    && ok "and the compositor counts the pushes it made ($PUSHED)" \
    || bad "x_configure_pushed is ${PUSHED:-absent}"

cp "$HAMFB_FILE" "$WORK/after.raw"
MOVED_PCT="$(colourpct "$NEWX" "$NEWY" "$MW" "$MH" "$WORK/after.raw" "$MOVER_COL")"
STAY_PCT="$(colourpct "$SX" "$SY" "$SW" "$SH" "$WORK/after.raw" "$STAYER_COL")"
info "after the move: ${MOVED_PCT}% of the new rectangle is the moved window's colour,"
info "                ${STAY_PCT}% of the old rectangle is still the other window's colour"
[ "${MOVED_PCT:-0}" -ge 30 ] \
    && ok "the moved window's PIXELS followed it" \
    || bad "the window record moved and the pixels did not (${MOVED_PCT}%)"
[ "${STAY_PCT:-0}" -ge 30 ] \
    && ok "the other window's pixels are exactly where they were" \
    || bad "the other window's pixels changed (${STAY_PCT}%) -- one X window's move disturbed another"

if [ -n "$SHOT" ]; then
    python3 - "$WORK/after.raw" "$FBW" "$FBH" "$SHOT" <<'PY'
import sys, zlib, struct
raw = open(sys.argv[1], 'rb').read()
W, H, out = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rows = bytearray()
for y in range(H):
    rows.append(0)
    o = y * W * 4
    line = raw[o:o + W * 4]
    rows += bytes(b for i in range(W) for b in (line[i*4+2], line[i*4+1], line[i*4]))
def chunk(tag, payload):
    c = tag + payload
    return struct.pack('>I', len(payload)) + c + struct.pack('>I', zlib.crc32(c))
open(out, 'wb').write(b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b''))
print("wrote", out)
PY
    info "screenshot written to $SHOT"
fi

# ---------------------------------------------------------------------------
# 3. THE CONTROL: the same two clients, rootful, on the same compositor
# ---------------------------------------------------------------------------
echo "rless: === 3. the control -- the same two clients on a ROOTFUL Xwayland"
WIN_BEFORE="$(st windows_high_water)"
DISP2="${RLESS_DISPLAY2:-:85}"
Xwayland -shm -noreset "$DISP2" >"$WORK/xw2.log" 2>&1 &
XWPID2=$!
for _ in $(seq 1 150); do [ -S "/tmp/.X11-unix/X${DISP2#:}" ] && break; sleep 0.1; done
if [ -S "/tmp/.X11-unix/X${DISP2#:}" ]; then
    DISPLAY="$DISP2" xterm -geometry 20x5+20+20 -e "sleep 300" >/dev/null 2>&1 &
    KIDS="$KIDS $!"
    sleep 2
    DISPLAY="$DISP2" xterm -geometry 20x5+300+200 -e "sleep 300" >/dev/null 2>&1 &
    KIDS="$KIDS $!"
    sleep 4
    NW2=0
    for wid in $(seq 2 40); do
        line="$(winctl "$wid")"
        [ -n "$line" ] || continue
        set -- $line
        [ "${8:-0}" = 1 ] || continue
        NW2=$((NW2 + 1))
    done
    ROOTFUL_WINS=$((NW2 - NW))
    info "the rootful display's two clients added $ROOTFUL_WINS wsys window(s)"
    if [ "$ROOTFUL_WINS" -le 1 ]; then
        ok "rootful: two X clients are ONE wsys window -- the thing rootless fixes, measured"
    else
        bad "the rootful arm produced $ROOTFUL_WINS windows; the control does not hold"
    fi
    CONNS2="$(st conns)"
    [ "${CONNS2:-0}" -ge 2 ] \
        && ok "and two X SERVERS are two connections ($CONNS2) -- independence is bought per server" \
        || info "conns is ${CONNS2:-0} with two Xwaylands up"
else
    info "could not start the rootful control on $DISP2; skipping part 3"
fi

# ---------------------------------------------------------------------------
# 4. THE ARITHMETIC that keeps the tables honest, carried over from
#    wsyswl_shared_fate.sh because rootless is the arm that can reach them.
# ---------------------------------------------------------------------------
echo "rless: === 4. can one X display exhaust something another client needs?"
lim() { sed -n "s/.*[ ]$1=\([0-9]*\).*/\1/p" "$STATE" 2>/dev/null | tail -1; }
MAXWIN="$(lim MAXWIN)"; MAXCONN="$(lim MAXCONN)"; WINPERCONN="$(lim WINPERCONN)"
if [ -n "$MAXWIN" ] && [ -n "$MAXCONN" ] && [ -n "$WINPERCONN" ]; then
    if [ "$MAXWIN" -ge $((MAXCONN * WINPERCONN)) ]; then
        ok "MAXWIN $MAXWIN >= MAXCONN $MAXCONN * WINPERCONN $WINPERCONN"
    else
        bad "MAXWIN $MAXWIN < MAXCONN $MAXCONN * WINPERCONN $WINPERCONN -- one client can starve another of windows"
    fi
    # ROOTLESS IS THE ARM THAT SPENDS THIS BUDGET. Rootful spends ONE window
    # per X display however many clients are on it; rootless spends one per
    # toplevel, out of WINPERCONN. That is the ceiling a namespace hits first
    # and it is written down here so the next person meets it as a number
    # rather than as "the ninth window did not appear".
    info "an X display may therefore have at most WINPERCONN=$WINPERCONN toplevels on screen at once"
    # BB_SLOTS USED TO BE THE HARDER CEILING BEHIND THIS ONE and is not any
    # more: user/linux-wsys.c ties the v2 backbuffer pool to the window table
    # with a compile-time assertion, so the paint pool can never be the first
    # thing to run out. /dev/wsys/pool states it, and tests/linux/wsyswl_ceiling.sh
    # puts twelve X windows on the screen at once and checks all twelve PIXELS.
    POOL="$(poke /dev/wsys/pool)"
    if [ -n "$POOL" ]; then
        ok "and the paint pool behind it is readable: $POOL"
    else
        bad "/dev/wsys/pool does not exist -- an exhausted paint pool would be silent again"
    fi
fi

echo "rless: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
